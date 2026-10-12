function New-EzVmSshTestIntent {
    param(
        [string]$Name = 'ssh-agent',
        [string]$BaseId = ('base-' + ('a' * 64)),
        [int]$Cpus = 4,
        [int]$MemoryMiB = 8192
    )
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        name = $Name
        baseId = $BaseId
        profile = $(if ($Cpus -eq 4 -and $MemoryMiB -eq 8192) { 'normal' } elseif ($Cpus -eq 2 -and $MemoryMiB -eq 4096) { 'light' } else { 'custom' })
        cpus = $Cpus
        memoryMiB = $MemoryMiB
        sshPort = 22001
        createdAt = '2026-10-12T00:00:00.0000000Z'
        provisioningProfile = 'ezvm-core'
        provisioningVersion = 1
    }
}

function ConvertTo-EzVmSshTestBase64 {
    param([AllowEmptyString()][string]$Text = '')
    return [Convert]::ToBase64String((New-Object Text.UTF8Encoding($false)).GetBytes($Text))
}

Add-EzVmTest -Name 'SSH: QEMU networking binds hostfwd to loopback and constructs guestfwd NoCloud endpoint' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'ssh qemu args [spaces]'
    try {
        $intent = New-EzVmSshTestIntent
        $dir = Join-Path $root 'runtime args'
        [void][IO.Directory]::CreateDirectory($dir)
        $args = New-EzVmRuntimeQemuArguments -InstanceName $intent.name -Intent $intent -Disk (Join-Path $dir 'disk.qcow2') -FirmwareCode (Join-Path $dir 'code.fd') -FirmwareVariables (Join-Path $dir 'vars.fd') -SerialLog (Join-Path $dir 'serial log.txt') -QemuLog (Join-Path $dir 'qemu log.txt') -QmpPort 32123 -Accelerator whpx -SshPort 22017 -SeedHostPort 43111 -SeedGuestAddress '10.0.2.100' -SeedGuestPort 8000
        $netIndex = [Array]::IndexOf($args, '-netdev')
        Assert-EzVmTrue -Condition ($netIndex -ge 0)
        $netdev = $args[$netIndex + 1]
        Assert-EzVmTrue -Condition ($netdev -match 'hostfwd=tcp:127\.0\.0\.1:22017-:22')
        Assert-EzVmTrue -Condition ($netdev -match 'guestfwd=tcp:10\.0\.2\.100:8000-tcp:127\.0\.0\.1:43111')
        Assert-EzVmTrue -Condition ($netdev -notmatch 'hostfwd=tcp:(?!127\.0\.0\.1)') -Message 'SSH host forwarding must never omit the loopback bind.'
        $smbiosIndex = [Array]::IndexOf($args, '-smbios')
        Assert-EzVmTrue -Condition ($smbiosIndex -ge 0)
        Assert-EzVmEqual -Actual $args[$smbiosIndex + 1] -Expected 'type=1,serial=ds=nocloud;s=http://10.0.2.100:8000/'
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'SSH: instance NoCloud seed contains public authorization and exact identity but no private key' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'ssh seed'
    try {
        $intent = New-EzVmSshTestIntent
        $publicKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEzvmFixturePublicKey0123456789= ezvm-controller'
        $seed = New-EzVmInstanceSeedData -Root $root -InstanceName $intent.name -Intent $intent -ControllerPublicKey $publicKey
        Assert-EzVmEqual -Actual $seed.Profile -Expected 'normal'
        Assert-EzVmTrue -Condition ($seed.UserData -match [regex]::Escape($publicKey))
        Assert-EzVmTrue -Condition ($seed.UserData -match '"instanceName":"ssh-agent"')
        Assert-EzVmTrue -Condition ($seed.UserData -match [regex]::Escape($intent.baseId))
        Assert-EzVmTrue -Condition ($seed.UserData -match '"profile":"normal"')
        Assert-EzVmTrue -Condition ($seed.UserData -match '/var/lib/ezvm/ready\.json')
        Assert-EzVmTrue -Condition ($seed.MetaData -match 'instance-id:.*ezvm-ssh-agent-')
        Assert-EzVmTrue -Condition (($seed.UserData + $seed.MetaData) -notmatch '(?i)PRIVATE KEY')
        Assert-EzVmThrows -ScriptBlock {
            New-EzVmInstanceSeedData -Root $root -InstanceName $intent.name -Intent $intent -ControllerPublicKey '-----BEGIN OPENSSH PRIVATE KEY-----'
        } -MessagePattern 'must never receive private-key material' | Out-Null
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'SSH: command argv uses scoped strict host-key checking and preserves remote argument boundaries' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'ssh argv'
    try {
        $paths = Get-EzVmSshPaths -Root $root -InstanceName 'ssh-agent'
        $args = New-EzVmSshCommandArguments -PrivateKey $paths.ControllerPrivateKey -KnownHosts $paths.InstanceKnownHosts -Port 22001 -Batch -RemoteCommand @('printf', 'a b', "x'y", '')
        Assert-EzVmTrue -Condition ($args -ccontains 'StrictHostKeyChecking=yes')
        Assert-EzVmTrue -Condition ($args -ccontains 'UpdateHostKeys=no')
        Assert-EzVmTrue -Condition ($args -ccontains 'HostKeyAlgorithms=ssh-ed25519')
        Assert-EzVmTrue -Condition ($args -ccontains 'HashKnownHosts=no')
        Assert-EzVmTrue -Condition ($args -notcontains 'StrictHostKeyChecking=no')
        Assert-EzVmTrue -Condition ($args -ccontains ('UserKnownHostsFile=' + $paths.InstanceKnownHosts))
        Assert-EzVmTrue -Condition ($args -ccontains 'BatchMode=yes')
        Assert-EzVmEqual -Actual $args[$args.Count - 2] -Expected 'coder@127.0.0.1'
        $remote = $args[$args.Count - 1]
        $module = Get-Module EzVm
        $quotedSingle = & $module { ConvertTo-EzVmPosixArgument -Value "x'y" }
        Assert-EzVmTrue -Condition ($remote -match "'a b'")
        Assert-EzVmTrue -Condition ($remote.Contains($quotedSingle)) -Message 'Single quotes must be encoded without losing the argv boundary.'
        Assert-EzVmTrue -Condition ($remote.EndsWith("''", [StringComparison]::Ordinal))
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'SSH: launch-local candidate may accept a new key without weakening managed trust' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'ssh candidate argv'
    try {
        $paths = Get-EzVmSshPaths -Root $root -InstanceName 'ssh-agent'
        $candidate = Join-Path $paths.KnownHostsDirectory '.candidate'
        $args = New-EzVmSshCommandArguments -PrivateKey $paths.ControllerPrivateKey -KnownHosts $candidate -Port 22009 -Batch -AcceptNewHostKey -RemoteCommand @('true')
        Assert-EzVmTrue -Condition ($args -ccontains 'StrictHostKeyChecking=accept-new')
        Assert-EzVmTrue -Condition ($args -notcontains 'StrictHostKeyChecking=no')
        Assert-EzVmTrue -Condition ($args -ccontains 'UpdateHostKeys=no')
        Assert-EzVmTrue -Condition ($args -ccontains 'HostKeyAlgorithms=ssh-ed25519')
        Assert-EzVmTrue -Condition ($args -ccontains 'HashKnownHosts=no')
        Assert-EzVmTrue -Condition ($args -ccontains ('UserKnownHostsFile=' + [IO.Path]::GetFullPath($candidate)))
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'SSH: scp argv preserves host paths containing spaces as one token' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'scp spaces'
    try {
        $paths = Get-EzVmSshPaths -Root $root -InstanceName 'ssh-agent'
        $hostPath = Join-Path $root 'host file with spaces.txt'
        $remote = 'coder@127.0.0.1:/tmp/guest file.txt'
        $args = New-EzVmScpCommandArguments -PrivateKey $paths.ControllerPrivateKey -KnownHosts $paths.InstanceKnownHosts -Port 22002 -Source $hostPath -Destination $remote
        $separator = [Array]::IndexOf($args, '--')
        Assert-EzVmTrue -Condition ($separator -ge 0)
        Assert-EzVmEqual -Actual $args[$separator + 1] -Expected $hostPath
        Assert-EzVmEqual -Actual $args[$separator + 2] -Expected $remote
        Assert-EzVmTrue -Condition ($args -ccontains 'StrictHostKeyChecking=yes')
        Assert-EzVmTrue -Condition ($args -notcontains 'StrictHostKeyChecking=no')
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'SSH: known-hosts state is bundle-scoped and one file per managed instance' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'known hosts'
    try {
        $paths = Get-EzVmSshPaths -Root $root -InstanceName 'agent-one'
        $runtime = Get-EzVmPaths -Root $root
        Assert-EzVmTrue -Condition ($paths.InstanceKnownHosts.StartsWith($runtime.Keys, [StringComparison]::OrdinalIgnoreCase))
        Assert-EzVmTrue -Condition ($paths.InstanceKnownHosts -match 'known-hosts[\\/]+agent-one\.known_hosts$')
        Assert-EzVmTrue -Condition ($paths.ControllerPrivateKey.StartsWith($runtime.Keys, [StringComparison]::OrdinalIgnoreCase))
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'SSH: readiness bootstraps trust through ssh accept-new only in the launch-local candidate' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'ssh accept new readiness'
    try {
        $paths = Get-EzVmSshPaths -Root $root -InstanceName 'ssh-agent'
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($paths.AccessState))
        $intent = New-EzVmSshTestIntent
        $access = [pscustomobject][ordered]@{
            schemaVersion = 1
            instanceName = 'ssh-agent'
            launchId = ('d' * 32)
            sshHost = '127.0.0.1'
            sshPort = 22079
            sshUser = 'coder'
            state = 'PROVISIONING'
            cloudInstanceId = 'ezvm-ssh-agent-123456789abc'
            profile = 'normal'
            readyAt = ''
        }
        $identity = [pscustomobject]@{ PrivateKey = (Join-Path $root 'unused-key') }
        $tooling = [pscustomobject]@{ Ssh = 'unused-ssh' }
        $identityJson = [pscustomobject][ordered]@{
            schemaVersion = 1
            instanceName = 'ssh-agent'
            baseId = $intent.baseId
            profile = 'normal'
            cloudInstanceId = 'ezvm-ssh-agent-123456789abc'
        } | ConvertTo-Json -Compress
        $nl = [Environment]::NewLine
        $readyOutput = 'EZVM_IDENTITY_B64=' + (ConvertTo-EzVmSshTestBase64 $identityJson) + $nl + 'EZVM_CLOUD_B64=' + (ConvertTo-EzVmSshTestBase64 'status: done') + $nl + 'EZVM_READY=1' + $nl
        $module = Get-Module EzVm
        $observed = & $module {
            param($r, $i, $a, $id, $tools, $output)
            $state = [pscustomobject]@{ AcceptNew = $false; StrictBypass = $false }
            $sshOutput = $output
            $runner = {
                param($exe, $arguments, $timeout)
                $state.AcceptNew = $arguments -ccontains 'StrictHostKeyChecking=accept-new'
                $state.StrictBypass = $arguments -contains 'StrictHostKeyChecking=no'
                $knownOption = @($arguments | Where-Object { $_ -like 'UserKnownHostsFile=*' } | Select-Object -First 1)
                if ($knownOption.Count -ne 1) { throw 'fixture did not receive one candidate known-hosts path' }
                $candidatePath = ([string]$knownOption[0]).Substring('UserKnownHostsFile='.Length)
                [IO.File]::WriteAllText($candidatePath, ('[127.0.0.1]:22079 ssh-ed25519 CCCC' + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
                return [pscustomobject]@{ ExitCode = 0; StdOut = $sshOutput; StdErr = '' }
            }.GetNewClosure()
            $ready = Wait-EzVmSshReady -Root $r -InstanceName 'ssh-agent' -Intent $i -Access $a -Identity $id -Tooling $tools -TimeoutSeconds 2 -PortProbe { param($hostAddress, $port) return $true } -SshRunner $runner
            return [pscustomobject]@{ Ready = $ready; AcceptNew = $state.AcceptNew; StrictBypass = $state.StrictBypass }
        } $root $intent $access $identity $tooling $readyOutput

        Assert-EzVmEqual -Actual $observed.Ready.state -Expected 'READY'
        Assert-EzVmEqual -Actual $observed.AcceptNew -Expected $true
        Assert-EzVmEqual -Actual $observed.StrictBypass -Expected $false
        $managed = [IO.File]::ReadAllText($paths.InstanceKnownHosts)
        Assert-EzVmTrue -Condition ($managed.Contains('[127.0.0.1]:22079 ssh-ed25519 CCCC'))
        $temporary = @(Get-ChildItem -LiteralPath $paths.KnownHostsDirectory -Filter '*.candidate' -File -ErrorAction SilentlyContinue)
        Assert-EzVmEqual -Actual $temporary.Count -Expected 0
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'SSH: changed host key remains staged until authenticated identity proof then replaces only scoped trust' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'host key rotation'
    try {
        $paths = Get-EzVmSshPaths -Root $root -InstanceName 'ssh-agent'
        [void][IO.Directory]::CreateDirectory($paths.KnownHostsDirectory)
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($paths.AccessState))
        $oldLine = '[127.0.0.1]:22001 ssh-ed25519 AAAA'
        $newLine = '[127.0.0.1]:22077 ssh-ed25519 BBBB'
        [IO.File]::WriteAllText($paths.InstanceKnownHosts, ($oldLine + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))

        $intent = New-EzVmSshTestIntent
        $access = [pscustomobject][ordered]@{
            schemaVersion = 1
            instanceName = 'ssh-agent'
            launchId = ('a' * 32)
            sshHost = '127.0.0.1'
            sshPort = 22077
            sshUser = 'coder'
            state = 'PROVISIONING'
            cloudInstanceId = 'ezvm-ssh-agent-123456789abc'
            profile = 'normal'
            readyAt = ''
        }
        $identity = [pscustomobject]@{ PrivateKey = (Join-Path $root 'unused-key') }
        $tooling = [pscustomobject]@{ Ssh = 'unused-ssh'; Keyscan = 'unused-keyscan' }
        $identityJson = [pscustomobject][ordered]@{
            schemaVersion = 1
            instanceName = 'ssh-agent'
            baseId = $intent.baseId
            profile = 'normal'
            cloudInstanceId = 'ezvm-ssh-agent-123456789abc'
        } | ConvertTo-Json -Compress
        $nl = [Environment]::NewLine
        $readyOutput = 'EZVM_IDENTITY_B64=' + (ConvertTo-EzVmSshTestBase64 $identityJson) + $nl + 'EZVM_CLOUD_B64=' + (ConvertTo-EzVmSshTestBase64 'status: done') + $nl + 'EZVM_READY=1' + $nl

        $module = Get-Module EzVm
        $candidate = & $module {
            param($r, $line)
            New-EzVmCandidateKnownHosts -Root $r -InstanceName 'ssh-agent' -LaunchId ('b' * 32) -Port 22077 -ScannedLine $line
        } $root $newLine
        try {
            Assert-EzVmEqual -Actual $candidate.Changed -Expected $true
            Assert-EzVmTrue -Condition ([IO.File]::ReadAllText($paths.InstanceKnownHosts).Contains('ssh-ed25519 AAAA')) -Message 'Observed key rotation must not overwrite existing trust before identity proof.'
        }
        finally { Remove-Item -LiteralPath $candidate.Candidate -Force -ErrorAction SilentlyContinue }

        $ready = & $module {
            param($r, $i, $a, $id, $tools, $line, $output)
            $scanLine = $line
            $sshOutput = $output
            $scanner = { param($port, $timeout) return $scanLine }.GetNewClosure()
            $runner = { param($exe, $arguments, $timeout) return [pscustomobject]@{ ExitCode = 0; StdOut = $sshOutput; StdErr = '' } }.GetNewClosure()
            Wait-EzVmSshReady -Root $r -InstanceName 'ssh-agent' -Intent $i -Access $a -Identity $id -Tooling $tools -TimeoutSeconds 2 -PortProbe { param($hostAddress, $port) return $true } -HostKeyScanner $scanner -SshRunner $runner
        } $root $intent $access $identity $tooling $newLine $readyOutput
        Assert-EzVmEqual -Actual $ready.state -Expected 'READY'
        $managed = [IO.File]::ReadAllText($paths.InstanceKnownHosts)
        Assert-EzVmTrue -Condition ($managed.Contains('ssh-ed25519 BBBB'))
        Assert-EzVmTrue -Condition (-not $managed.Contains('ssh-ed25519 AAAA'))
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'SSH: failed identity proof cannot promote a changed host key' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'host key failed proof'
    try {
        $paths = Get-EzVmSshPaths -Root $root -InstanceName 'ssh-agent'
        [void][IO.Directory]::CreateDirectory($paths.KnownHostsDirectory)
        [IO.File]::WriteAllText($paths.InstanceKnownHosts, ('[127.0.0.1]:22001 ssh-ed25519 AAAA' + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
        $intent = New-EzVmSshTestIntent
        $access = [pscustomobject][ordered]@{
            schemaVersion = 1
            instanceName = 'ssh-agent'
            launchId = ('c' * 32)
            sshHost = '127.0.0.1'
            sshPort = 22078
            sshUser = 'coder'
            state = 'PROVISIONING'
            cloudInstanceId = 'ezvm-ssh-agent-123456789abc'
            profile = 'normal'
            readyAt = ''
        }
        $wrong = [pscustomobject][ordered]@{
            schemaVersion = 1
            instanceName = 'wrong-agent'
            baseId = $intent.baseId
            profile = 'normal'
            cloudInstanceId = 'ezvm-ssh-agent-123456789abc'
        } | ConvertTo-Json -Compress
        $nl = [Environment]::NewLine
        $wrongOutput = 'EZVM_IDENTITY_B64=' + (ConvertTo-EzVmSshTestBase64 $wrong) + $nl + 'EZVM_CLOUD_B64=' + (ConvertTo-EzVmSshTestBase64 'status: done') + $nl + 'EZVM_READY=1' + $nl
        $module = Get-Module EzVm
        Assert-EzVmThrows -ScriptBlock {
            & $module {
                param($r, $i, $a, $output)
                $id = [pscustomobject]@{ PrivateKey = (Join-Path $r 'unused-key') }
                $tools = [pscustomobject]@{ Ssh = 'unused-ssh'; Keyscan = 'unused-keyscan' }
                $sshOutput = $output
                $runner = { param($exe, $arguments, $timeout) return [pscustomobject]@{ ExitCode = 0; StdOut = $sshOutput; StdErr = '' } }.GetNewClosure()
                Wait-EzVmSshReady -Root $r -InstanceName 'ssh-agent' -Intent $i -Access $a -Identity $id -Tooling $tools -TimeoutSeconds 2 -PortProbe { param($hostAddress, $port) return $true } -HostKeyScanner { param($port, $timeout) return '[127.0.0.1]:22078 ssh-ed25519 BBBB' } -SshRunner $runner
            } $root $intent $access $wrongOutput
        } -MessagePattern 'identity mismatch' | Out-Null
        $managed = [IO.File]::ReadAllText($paths.InstanceKnownHosts)
        Assert-EzVmTrue -Condition ($managed.Contains('ssh-ed25519 AAAA'))
        Assert-EzVmTrue -Condition (-not $managed.Contains('ssh-ed25519 BBBB'))
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'SSH: readiness rejects authenticated identity mismatch' -ScriptBlock {
    $expected = New-EzVmSshTestIntent
    $wrong = [pscustomobject][ordered]@{
        schemaVersion = 1
        instanceName = 'other-agent'
        baseId = $expected.baseId
        profile = 'normal'
        cloudInstanceId = 'ezvm-ssh-agent-123456789abc'
    } | ConvertTo-Json -Compress
    $nl = [Environment]::NewLine
    $output = 'EZVM_IDENTITY_B64=' + (ConvertTo-EzVmSshTestBase64 $wrong) + $nl + 'EZVM_CLOUD_B64=' + (ConvertTo-EzVmSshTestBase64 'status: done') + $nl + 'EZVM_READY=1' + $nl
    Assert-EzVmThrows -ScriptBlock {
        ConvertFrom-EzVmReadinessProbe -StdOut $output -ExpectedInstanceName 'ssh-agent' -ExpectedBaseId $expected.baseId -ExpectedProfile 'normal' -ExpectedCloudInstanceId 'ezvm-ssh-agent-123456789abc'
    } -MessagePattern 'identity mismatch' | Out-Null
}

Add-EzVmTest -Name 'SSH: readiness distinguishes cloud-init incomplete and failed states from READY' -ScriptBlock {
    $intent = New-EzVmSshTestIntent
    $identity = [pscustomobject][ordered]@{
        schemaVersion = 1
        instanceName = 'ssh-agent'
        baseId = $intent.baseId
        profile = 'normal'
        cloudInstanceId = 'ezvm-ssh-agent-123456789abc'
    } | ConvertTo-Json -Compress
    $identity64 = ConvertTo-EzVmSshTestBase64 $identity
    $nl = [Environment]::NewLine

    $runningOutput = 'EZVM_IDENTITY_B64=' + $identity64 + $nl + 'EZVM_CLOUD_B64=' + (ConvertTo-EzVmSshTestBase64 'status: running') + $nl + 'EZVM_READY=0' + $nl
    $running = ConvertFrom-EzVmReadinessProbe -StdOut $runningOutput -ExpectedInstanceName 'ssh-agent' -ExpectedBaseId $intent.baseId -ExpectedProfile 'normal' -ExpectedCloudInstanceId 'ezvm-ssh-agent-123456789abc'
    Assert-EzVmEqual -Actual $running.Ready -Expected $false
    Assert-EzVmEqual -Actual $running.CloudDone -Expected $false

    $failedOutput = 'EZVM_IDENTITY_B64=' + $identity64 + $nl + 'EZVM_CLOUD_B64=' + (ConvertTo-EzVmSshTestBase64 'status: error') + $nl + 'EZVM_READY=0' + $nl
    Assert-EzVmThrows -ScriptBlock {
        ConvertFrom-EzVmReadinessProbe -StdOut $failedOutput -ExpectedInstanceName 'ssh-agent' -ExpectedBaseId $intent.baseId -ExpectedProfile 'normal' -ExpectedCloudInstanceId 'ezvm-ssh-agent-123456789abc'
    } -MessagePattern 'cloud-init reports failed' | Out-Null

    $readyOutput = 'EZVM_IDENTITY_B64=' + $identity64 + $nl + 'EZVM_CLOUD_B64=' + (ConvertTo-EzVmSshTestBase64 'status: done') + $nl + 'EZVM_READY=1' + $nl
    $ready = ConvertFrom-EzVmReadinessProbe -StdOut $readyOutput -ExpectedInstanceName 'ssh-agent' -ExpectedBaseId $intent.baseId -ExpectedProfile 'normal' -ExpectedCloudInstanceId 'ezvm-ssh-agent-123456789abc'
    Assert-EzVmEqual -Actual $ready.Ready -Expected $true
}

Add-EzVmTest -Name 'SSH: readiness wait has a bounded total timeout when TCP never opens' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'ssh readiness timeout'
    try {
        $intent = New-EzVmSshTestIntent
        $access = [pscustomobject][ordered]@{
            schemaVersion = 1
            instanceName = 'ssh-agent'
            launchId = ('a' * 32)
            sshHost = '127.0.0.1'
            sshPort = 22001
            sshUser = 'coder'
            state = 'PROVISIONING'
            cloudInstanceId = 'ezvm-ssh-agent-123456789abc'
            profile = 'normal'
            readyAt = ''
        }
        $identity = [pscustomobject]@{ PrivateKey = (Join-Path $root 'unused-key') }
        $tooling = [pscustomobject]@{ Ssh = 'unused-ssh'; Keyscan = 'unused-keyscan' }
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $module = Get-Module EzVm
        Assert-EzVmThrows -ScriptBlock {
            & $module {
                param($r, $i, $a, $id, $tools)
                Wait-EzVmSshReady -Root $r -InstanceName 'ssh-agent' -Intent $i -Access $a -Identity $id -Tooling $tools -TimeoutSeconds 1 -PortProbe { param($hostAddress, $port) return $false }
            } $root $intent $access $identity $tooling
        } -MessagePattern 'did not reach authenticated SSH READY within 1 seconds' | Out-Null
        $clock.Stop()
        Assert-EzVmTrue -Condition ($clock.Elapsed.TotalSeconds -lt 4) -Message 'Readiness timeout must remain bounded.'
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'SSH: exec process result preserves remote non-zero exit and reserves 255 for transport failure' -ScriptBlock {
    $module = Get-Module EzVm
    $resolved = & $module {
        Resolve-EzVmExecProcessResult -Result ([pscustomobject]@{ ExitCode = 37; StdOut = 'partial output'; StdErr = 'remote error' })
    }
    Assert-EzVmEqual -Actual $resolved.exitCode -Expected 37
    Assert-EzVmEqual -Actual $resolved.stdout -Expected 'partial output'
    Assert-EzVmEqual -Actual $resolved.stderr -Expected 'remote error'
    Assert-EzVmThrows -ScriptBlock {
        & $module {
            Resolve-EzVmExecProcessResult -Result ([pscustomobject]@{ ExitCode = 255; StdOut = ''; StdErr = 'host key failure' })
        }
    } -MessagePattern 'transport/authentication failed' | Out-Null
}

Add-EzVmTest -Name 'SSH: configured port allocation skips collisions and stays inside the reviewed range' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'ssh ports'
    try {
        $port = Get-EzVmAvailableSshPort -Root $root -PortProbe { param($candidate) return $candidate -eq 22003 }
        Assert-EzVmEqual -Actual $port -Expected 22003
        Assert-EzVmThrows -ScriptBlock {
            Get-EzVmAvailableSshPort -Root $root -PortProbe { param($candidate) return $false }
        } -MessagePattern 'No (?:unreserved )?loopback SSH port is available.*22000-22999' | Out-Null
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'SSH: missing OpenSSH tools produce concrete remediation' -ScriptBlock {
    $module = Get-Module EzVm
    Assert-EzVmThrows -ScriptBlock {
        & $module {
            Assert-EzVmOpenSshTools -Tooling ([pscustomobject]@{
                Valid = $false
                Missing = @('ssh.exe', 'scp.exe')
                Reason = 'Missing required OpenSSH application(s): ssh.exe, scp.exe.'
            })
        }
    } -MessagePattern 'Install the Windows OpenSSH Client.*ssh\.exe.*scp\.exe.*ssh-keygen\.exe' | Out-Null
}

Add-EzVmTest -Name 'SSH: implementation never disables strict host-key checking' -ScriptBlock {
    $source = [IO.File]::ReadAllText((Join-Path $script:EzVmRepositoryRoot 'src/EzVm/Ssh.ps1'))
    Assert-EzVmTrue -Condition ($source -notmatch 'StrictHostKeyChecking=no') -Message 'Managed SSH must never use the global host-key bypass.'
    Assert-EzVmTrue -Condition ($source -match 'StrictHostKeyChecking=yes')
    Assert-EzVmTrue -Condition ($source -match 'UpdateHostKeys=no')
    Assert-EzVmTrue -Condition ($source -match 'UserKnownHostsFile=')
    Assert-EzVmTrue -Condition ($source -match "'accept-new'") -Message 'Launch-local candidate bootstrap must use OpenSSH accept-new rather than disabling verification.'
    Assert-EzVmTrue -Condition ($source -notmatch 'ssh-keyscan') -Message 'Windows ssh-keyscan is not a supported trust bootstrap because affected Win32 builds can negotiate an unavailable KEX.'
}


Add-EzVmTest -Name 'SSH: a newly generated controller key is removed if Windows ACL hardening fails' -ScriptBlock {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return }
    $root = New-EzVmCheckoutFixture -Prefix 'controller key acl failure'
    try {
        $tooling = [pscustomobject]@{
            Valid = $true
            Ssh = 'fake-ssh'
            Scp = 'fake-scp'
            Keygen = 'fake-keygen'
            Missing = @()
            Reason = 'fixture'
        }
        $runner = {
            param($exe, $arguments, $timeout)
            if ($exe -ceq 'fake-keygen') {
                $index = [Array]::IndexOf([object[]]$arguments, '-f')
                if ($index -lt 0) { throw 'fixture did not receive key destination' }
                $private = [string]$arguments[$index + 1]
                [IO.File]::WriteAllText($private, 'fixture-private', (New-Object Text.UTF8Encoding($false)))
                [IO.File]::WriteAllText(($private + '.pub'), 'ssh-ed25519 AAAA fixture', (New-Object Text.UTF8Encoding($false)))
                return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
            }
            return [pscustomobject]@{ ExitCode = 5; StdOut = ''; StdErr = 'fixture ACL failure' }
        }
        Assert-EzVmThrows -ScriptBlock {
            Get-EzVmControllerSshIdentity -Root $root -Tooling $tooling -ProcessRunner $runner
        } -MessagePattern 'Failed to restrict.*private-key ACL' | Out-Null
        $paths = Get-EzVmSshPaths -Root $root
        Assert-EzVmTrue -Condition (-not (Test-Path -LiteralPath $paths.ControllerPrivateKey)) -Message 'Unsafe freshly generated private key must be removed.'
        Assert-EzVmTrue -Condition (-not (Test-Path -LiteralPath $paths.ControllerPublicKey)) -Message 'Orphan public half from failed fresh generation must also be removed.'
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}


Add-EzVmTest -Name 'SSH: seed server lifetime cannot pre-empt READY deadline' -ScriptBlock {
    $module = Get-Module EzVm
    $short = & $module { Get-EzVmSeedServerLifetimeSeconds -ReadyTimeoutSeconds 1 }
    $normal = & $module { Get-EzVmSeedServerLifetimeSeconds -ReadyTimeoutSeconds 60 }
    $maximum = & $module { Get-EzVmSeedServerLifetimeSeconds -ReadyTimeoutSeconds 3600 }

    Assert-EzVmEqual -Actual $short -Expected 31
    Assert-EzVmEqual -Actual $normal -Expected 90
    Assert-EzVmEqual -Actual $maximum -Expected 3630
    Assert-EzVmTrue -Condition ($short -gt 1 -and $normal -gt 60 -and $maximum -gt 3600) -Message 'The subordinate seed server deadline must outlive the enclosing READY deadline.'
}


Add-EzVmTest -Name 'SSH: readiness grants slow TCG SSH probes a bounded per-attempt budget' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'ssh slow readiness'
    try {
        $paths = Get-EzVmSshPaths -Root $root -InstanceName 'ssh-agent'
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($paths.AccessState))
        $intent = New-EzVmSshTestIntent
        $access = [pscustomobject][ordered]@{
            schemaVersion = 1
            instanceName = 'ssh-agent'
            launchId = ('d' * 32)
            sshHost = '127.0.0.1'
            sshPort = 22080
            sshUser = 'coder'
            state = 'PROVISIONING'
            cloudInstanceId = 'ezvm-ssh-agent-123456789abc'
            profile = 'normal'
            readyAt = ''
        }
        $identity = [pscustomobject]@{ PrivateKey = (Join-Path $root 'unused-key') }
        $tooling = [pscustomobject]@{ Ssh = 'unused-ssh' }
        $identityJson = [pscustomobject][ordered]@{
            schemaVersion = 1
            instanceName = 'ssh-agent'
            baseId = $intent.baseId
            profile = 'normal'
            cloudInstanceId = 'ezvm-ssh-agent-123456789abc'
        } | ConvertTo-Json -Compress
        $nl = [Environment]::NewLine
        $readyOutput = 'EZVM_IDENTITY_B64=' + (ConvertTo-EzVmSshTestBase64 $identityJson) + $nl + 'EZVM_CLOUD_B64=' + (ConvertTo-EzVmSshTestBase64 'status: done') + $nl + 'EZVM_READY=1' + $nl
        $module = Get-Module EzVm
        $observed = & $module {
            param($r, $i, $a, $id, $tools, $output)
            $state = [pscustomobject]@{ ProcessTimeout = 0; ConnectTimeout = '' }
            $sshOutput = $output
            $runner = {
                param($exe, $arguments, $timeout)
                $state.ProcessTimeout = $timeout
                $state.ConnectTimeout = @($arguments | Where-Object { $_ -like 'ConnectTimeout=*' } | Select-Object -First 1)[0]
                $knownOption = @($arguments | Where-Object { $_ -like 'UserKnownHostsFile=*' } | Select-Object -First 1)
                if ($knownOption.Count -ne 1) { throw 'fixture did not receive one candidate known-hosts path' }
                $candidatePath = ([string]$knownOption[0]).Substring('UserKnownHostsFile='.Length)
                [IO.File]::WriteAllText($candidatePath, ('[127.0.0.1]:22080 ssh-ed25519 DDDD' + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
                return [pscustomobject]@{ ExitCode = 0; StdOut = $sshOutput; StdErr = '' }
            }.GetNewClosure()
            $ready = Wait-EzVmSshReady -Root $r -InstanceName 'ssh-agent' -Intent $i -Access $a -Identity $id -Tooling $tools -TimeoutSeconds 120 -PortProbe { param($hostAddress, $port) return $true } -SshRunner $runner
            return [pscustomobject]@{ Ready = $ready; ProcessTimeout = $state.ProcessTimeout; ConnectTimeout = $state.ConnectTimeout }
        } $root $intent $access $identity $tooling $readyOutput

        Assert-EzVmEqual -Actual $observed.Ready.state -Expected 'READY'
        Assert-EzVmEqual -Actual $observed.ProcessTimeout -Expected 30
        Assert-EzVmEqual -Actual $observed.ConnectTimeout -Expected 'ConnectTimeout=15'
        Assert-EzVmTrue -Condition ([IO.File]::ReadAllText($paths.InstanceKnownHosts).Contains('[127.0.0.1]:22080 ssh-ed25519 DDDD'))
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}
