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
        provisioningProfile = 'coding-default'
        provisioningVersion = 1
    }
}

function ConvertTo-EzVmSshTestBase64 {
    param([AllowEmptyString()][string]$Text = '')
    return [Convert]::ToBase64String((New-Object Text.UTF8Encoding($false)).GetBytes($Text))
}


function Get-EzVmSshTestCloudId {
    param([object]$Intent)
    $module = Get-Module EzVm
    return & $module { param($i) Get-EzVmGuestCloudInstanceId -Intent $i } $Intent
}

function New-EzVmSshTestAccess {
    param([string]$Root, [object]$Intent, [int]$Port = 22001, [string]$LaunchId = ('a' * 32))
    $coding = Get-EzVmCodingProfile -Root $Root
    $Intent.sshPort = $Port
    $path = (Get-EzVmSshPaths -Root $Root -InstanceName $Intent.name).AccessState
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    return [pscustomobject][ordered]@{
        schemaVersion = 2
        instanceName = $Intent.name
        baseId = $Intent.baseId
        launchId = $LaunchId
        sshHost = '127.0.0.1'
        sshPort = $Port
        sshUser = 'coder'
        state = 'PROVISIONING'
        cloudInstanceId = Get-EzVmSshTestCloudId -Intent $Intent
        profile = $Intent.profile
        provisioningProfile = $coding.Name
        provisioningVersion = $coding.Version
        provisioningDigest = $coding.Digest
        readyAt = ''
    }
}

function New-EzVmSshTestLaunch {
    param([string]$Root, [object]$Intent, [object]$Access)
    # Readiness publication reconciles real durable launch records. Only the
    # operating-system process observation is replaced by this test fixture.
    $module = Get-Module EzVm
    return & $module {
        param($r, $i, $a)
        $paths = Get-EzVmInstanceRuntimePaths -Root $r -InstanceName $i.name
        Write-EzVmJson -Path $paths.Intent -Value $i -SchemaVersion ([int]$i.schemaVersion)
        $arguments = [string[]]@('-name', ('guest=ezvm-' + $i.name))
        $now = [DateTime]::UtcNow.ToString('o')
        $executable = Join-Path (Get-EzVmPaths -Root $r).Qemu 'qemu-system-x86_64.exe'
        $runtime = [pscustomobject][ordered]@{
            schemaVersion = 1
            instanceName = $i.name
            state = 'RUNNING'
            pid = 41000
            processStartTimeUtc = $now
            qemuExecutable = $executable
            argumentFingerprint = Get-EzVmArgumentFingerprint -ArgumentList $arguments
            launchId = $a.launchId
            qmpHost = '127.0.0.1'
            qmpPort = 32001
            accelerator = 'tcg'
            startedAt = $now
            lastObservedAt = $now
            stoppedAt = ''
            qemuLog = Join-Path $paths.Directory 'qemu.log'
            serialLog = Join-Path $paths.Directory 'serial.log'
        }
        Write-EzVmRuntimeStateFile -Root $r -InstanceName $i.name -Runtime $runtime
        $state = [pscustomobject]@{ Processes = New-Object 'System.Collections.Generic.List[object]'; Observations = 0 }
        $state.Processes.Add([pscustomobject]@{
            Pid = $runtime.pid
            ExecutablePath = $executable
            Arguments = $arguments
            StartTimeUtc = $now
        })
        $provider = {
            param($processId)
            $state.Observations++
            if ($null -eq $processId) { return @($state.Processes.ToArray()) }
            return @($state.Processes.ToArray() | Where-Object { $_.Pid -eq [int]$processId })
        }.GetNewClosure()
        return [pscustomobject]@{ Paths = $paths; Runtime = $runtime; State = $state; ProcessProvider = $provider }
    } $Root $Intent $Access
}

function New-EzVmSshTestIdentityJson {
    param([object]$Intent, [string]$InstanceName = '')
    $coding = Get-EzVmCodingProfile -Root $script:EzVmRepositoryRoot
    if ($InstanceName.Length -eq 0) { $InstanceName = $Intent.name }
    return [pscustomobject][ordered]@{
        schemaVersion = 2
        instanceName = $InstanceName
        baseId = $Intent.baseId
        profile = $Intent.profile
        cloudInstanceId = Get-EzVmSshTestCloudId -Intent $Intent
        provisioningProfile = $coding.Name
        provisioningVersion = $coding.Version
        provisioningDigest = $coding.Digest
    } | ConvertTo-Json -Compress
}

function New-EzVmSshTestProbe {
    param(
        [string]$IdentityBase64,
        [string]$CloudStatus = 'status: done',
        [string]$CloudExit = '0',
        [bool]$Ready = $true,
        [string]$ProfileCheck = '',
        [string]$ProfileError = ''
    )
    $marker = ''
    if ($Ready) {
        $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($IdentityBase64)) | ConvertFrom-Json
        $decoded | Add-Member -NotePropertyName provisioningState -NotePropertyValue 'complete'
        $marker = ConvertTo-EzVmSshTestBase64 ($decoded | ConvertTo-Json -Compress)
    }
    if ($ProfileCheck.Length -eq 0) { $ProfileCheck = if ($Ready) { 'pass' } else { 'pending' } }
    return [string]::Join([Environment]::NewLine, @(
        ('EZVM_IDENTITY_B64=' + $IdentityBase64),
        ('EZVM_CLOUD_B64=' + (ConvertTo-EzVmSshTestBase64 $CloudStatus)),
        ('EZVM_CLOUD_EXIT=' + $CloudExit),
        ('EZVM_READY_B64=' + $marker),
        ('EZVM_PROFILE_CHECK=' + $ProfileCheck),
        ('EZVM_PROFILE_ERROR_B64=' + (ConvertTo-EzVmSshTestBase64 $ProfileError))
    )) + [Environment]::NewLine
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
        Assert-EzVmTrue -Condition ($seed.UserData -match [regex]::Escape(($publicKey -split ' ')[1]))
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
        $knownPath = $paths.InstanceKnownHosts
        if ($script:EzVmIsWindowsHost) { $knownPath = $knownPath.Replace('\', '/') }
        Assert-EzVmTrue -Condition ($args -ccontains ('UserKnownHostsFile="' + $knownPath + '"'))
        Assert-EzVmEqual -Actual $args[[Array]::IndexOf($args, '-i') + 1] -Expected $paths.ControllerPrivateKey
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
        $knownPath = [IO.Path]::GetFullPath($candidate)
        if ($script:EzVmIsWindowsHost) { $knownPath = $knownPath.Replace('\', '/') }
        Assert-EzVmTrue -Condition ($args -ccontains ('UserKnownHostsFile="' + $knownPath + '"'))
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
        Assert-EzVmEqual -Actual $args[[Array]::IndexOf($args, '-i') + 1] -Expected $paths.ControllerPrivateKey
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

Add-EzVmTest -Name 'SSH: configuration path quoting preserves literal syntax and refuses hidden expansion' -ScriptBlock {
    $module = Get-Module EzVm
    $path = 'trust "quoted" ; StrictHostKeyChecking=no # %h'
    $encoded = & $module { param($p) ConvertTo-EzVmOpenSshConfigPath -Path $p -ExpandTokens } $path
    Assert-EzVmEqual -Actual $encoded -Expected '"trust \"quoted\" ; StrictHostKeyChecking=no # %%h"'
    $slashPath = 'trust\literal'
    $encodedSlash = & $module { param($p) ConvertTo-EzVmOpenSshConfigPath -Path $p -ExpandTokens } $slashPath
    $expectedSlash = if ($script:EzVmIsWindowsHost) { '"trust/literal"' } else { '"trust\\literal"' }
    Assert-EzVmEqual -Actual $encodedSlash -Expected $expectedSlash
    foreach ($bad in @("trust`nStrictHostKeyChecking=no", "trust`rnext", ('trust' + [char]0 + 'next'), 'trust${HOME}')) {
        Assert-EzVmThrows -ScriptBlock {
            & $module { param($p) ConvertTo-EzVmOpenSshConfigPath -Path $p -ExpandTokens } $bad
        } -MessagePattern 'OpenSSH.*paths' | Out-Null
    }
    foreach ($kind in @('ssh', 'scp')) {
        Assert-EzVmThrows -ScriptBlock {
            if ($kind -ceq 'ssh') { New-EzVmSshCommandArguments -PrivateKey 'unused' -KnownHosts 'trust${HOME}' -Port 22001 }
            else { New-EzVmScpCommandArguments -PrivateKey 'unused' -KnownHosts 'trust${HOME}' -Port 22001 -Source 'source' -Destination 'destination' }
        } -MessagePattern 'Move the bundle' | Out-Null
    }
}

$sshParserCommand = @(Get-Command -Name 'ssh' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
$sshParserSkip = if ($sshParserCommand.Count -eq 0) { 'The real OpenSSH client is unavailable; configuration-parser regression requires ssh.' } else { '' }
$sshParserPath = if ($sshParserCommand.Count -eq 0) { '' } else { $sshParserCommand[0].Source }
Add-EzVmTest -Name 'SSH: real OpenSSH parses SSH and SCP trust paths as one literal filename' -Data $sshParserPath -SkipReason $sshParserSkip -ScriptBlock {
    param($sshPath)
    $root = New-EzVmTestDirectory -Prefix 'ssh parser [spaces]'
    $socket = [Net.Sockets.Socket]::new([Net.Sockets.AddressFamily]::InterNetwork, [Net.Sockets.SocketType]::Stream, [Net.Sockets.ProtocolType]::Tcp)
    try {
        # Hold a loopback port without listening. The real client expands its
        # configuration, then receives a refusal; no SSH server is contacted.
        $socket.Bind([Net.IPEndPoint]::new([Net.IPAddress]::Loopback, 0))
        $port = ([Net.IPEndPoint]$socket.LocalEndPoint).Port
        $config = Join-Path $root 'empty config'
        [IO.File]::WriteAllText($config, '')
        $privateKey = Join-Path $root 'unused private key'
        $knownHosts = Join-Path $root 'known hosts literal %h'
        $expected = [IO.Path]::GetFullPath($knownHosts)
        if ($script:EzVmIsWindowsHost) { $expected = $expected.Replace('\', '/') }
        $sshArguments = New-EzVmSshCommandArguments -PrivateKey $privateKey -KnownHosts $knownHosts -Port $port -Batch -ConnectTimeoutSeconds 1
        $scpArguments = New-EzVmScpCommandArguments -PrivateKey $privateKey -KnownHosts $knownHosts -Port $port -Source 'unused source' -Destination 'coder@127.0.0.1:/unused'
        $scpOption = @($scpArguments | Where-Object { $_ -like 'UserKnownHostsFile=*' })
        Assert-EzVmEqual -Actual $scpOption.Count -Expected 1
        Assert-EzVmTrue -Condition ($sshArguments -ccontains $scpOption[0])
        $common = @('-vvv', '-F', $config, '-p', [string]$port, '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=1')
        $injected = $expected + ' " ; StrictHostKeyChecking=no # extra %h'
        $module = Get-Module EzVm
        $injectedOption = 'UserKnownHostsFile=' + (& $module { param($p) ConvertTo-EzVmOpenSshConfigPath -Path $p -ExpandTokens } $injected)
        $cases = @(
            [pscustomobject]@{ Name = 'SSH'; Arguments = (@('-vvv', '-F', $config) + $sshArguments); Expected = $expected },
            [pscustomobject]@{ Name = 'SCP'; Arguments = ($common + @('-o', $scpOption[0], 'coder@127.0.0.1')); Expected = $expected },
            [pscustomobject]@{ Name = 'quoted config syntax'; Arguments = ($common + @('-o', $injectedOption, 'coder@127.0.0.1')); Expected = $injected }
        )
        foreach ($case in $cases) {
            $result = Invoke-EzVmProcess -FilePath $sshPath -ArgumentList $case.Arguments -WorkingDirectory $root -TimeoutSeconds 6
            Assert-EzVmEqual -Actual $result.ExitCode -Expected 255 -Message $case.Name
            # ssh -G flattens multiple paths into the same displayed line. A
            # literal percent forces this expansion diagnostic, which reveals
            # each actual parsed filename and catches the original split path.
            $expanded = @($result.StdErr -split '\r?\n' | Where-Object { $_ -match 'expanded UserKnownHostsFile' })
            Assert-EzVmEqual -Actual $expanded.Count -Expected 1 -Message "$($case.Name): $($result.StdErr)"
            Assert-EzVmTrue -Condition ($expanded[0].EndsWith((" -> '" + $case.Expected + "'"), [StringComparison]::Ordinal)) -Message "$($case.Name) did not preserve the complete literal trust path: $($expanded[0])"
            Assert-EzVmTrue -Condition ($result.StdErr -match 'Connection refused') -Message "$($case.Name) must stop at the reserved, non-listening port: $($result.StdErr)"
        }
    }
    finally {
        $socket.Dispose()
        Remove-EzVmTestDirectory -Path $root
    }
}

Add-EzVmTest -Name 'SSH: readiness bootstraps trust through ssh accept-new only in the launch-local candidate' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'ssh accept new readiness'
    try {
        $paths = Get-EzVmSshPaths -Root $root -InstanceName 'ssh-agent'
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($paths.AccessState))
        $intent = New-EzVmSshTestIntent
        $access = New-EzVmSshTestAccess -Root $root -Intent $intent -Port 22079 -LaunchId ('d' * 32)
        $launch = New-EzVmSshTestLaunch -Root $root -Intent $intent -Access $access
        $identity = [pscustomobject]@{ PrivateKey = (Join-Path $root 'unused-key') }
        $tooling = [pscustomobject]@{ Ssh = 'unused-ssh' }
        $identityJson = New-EzVmSshTestIdentityJson -Intent $intent -InstanceName 'ssh-agent'
        $nl = [Environment]::NewLine
        $readyOutput = New-EzVmSshTestProbe -IdentityBase64 (ConvertTo-EzVmSshTestBase64 $identityJson) -CloudStatus 'status: done' -Ready:$true
        $module = Get-Module EzVm
        $observed = & $module {
            param($r, $i, $a, $id, $tools, $output, $processProvider)
            $state = [pscustomobject]@{ AcceptNew = $false; StrictBypass = $false }
            $sshOutput = $output
            $candidatePath = Join-Path (Get-EzVmSshPaths -Root $r -InstanceName 'ssh-agent').KnownHostsDirectory ('.ssh-agent.' + $a.launchId + '.candidate')
            $candidateOption = 'UserKnownHostsFile=' + (ConvertTo-EzVmOpenSshConfigPath -Path $candidatePath -ExpandTokens)
            $runner = {
                param($exe, $arguments, $timeout)
                $state.AcceptNew = $arguments -ccontains 'StrictHostKeyChecking=accept-new'
                $state.StrictBypass = $arguments -contains 'StrictHostKeyChecking=no'
                if ($arguments -cnotcontains $candidateOption) { throw 'fixture did not receive the expected candidate known-hosts path' }
                [IO.File]::WriteAllText($candidatePath, ('[127.0.0.1]:22079 ssh-ed25519 CCCC' + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
                return [pscustomobject]@{ ExitCode = 0; StdOut = $sshOutput; StdErr = '' }
            }.GetNewClosure()
            $ready = Wait-EzVmSshReady -Root $r -InstanceName 'ssh-agent' -Intent $i -Access $a -Identity $id -Tooling $tools -TimeoutSeconds 2 -PortProbe { param($hostAddress, $port) return $true } -SshRunner $runner -ProcessProvider $processProvider
            return [pscustomobject]@{ Ready = $ready; AcceptNew = $state.AcceptNew; StrictBypass = $state.StrictBypass }
        } $root $intent $access $identity $tooling $readyOutput $launch.ProcessProvider

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
        $access = New-EzVmSshTestAccess -Root $root -Intent $intent -Port 22077 -LaunchId ('a' * 32)
        $launch = New-EzVmSshTestLaunch -Root $root -Intent $intent -Access $access
        $identity = [pscustomobject]@{ PrivateKey = (Join-Path $root 'unused-key') }
        $tooling = [pscustomobject]@{ Ssh = 'unused-ssh'; Keyscan = 'unused-keyscan' }
        $identityJson = New-EzVmSshTestIdentityJson -Intent $intent -InstanceName 'ssh-agent'
        $nl = [Environment]::NewLine
        $readyOutput = New-EzVmSshTestProbe -IdentityBase64 (ConvertTo-EzVmSshTestBase64 $identityJson) -CloudStatus 'status: done' -Ready:$true

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
            param($r, $i, $a, $id, $tools, $line, $output, $processProvider)
            $scanLine = $line
            $sshOutput = $output
            $scanner = { param($port, $timeout) return $scanLine }.GetNewClosure()
            $runner = { param($exe, $arguments, $timeout) return [pscustomobject]@{ ExitCode = 0; StdOut = $sshOutput; StdErr = '' } }.GetNewClosure()
            Wait-EzVmSshReady -Root $r -InstanceName 'ssh-agent' -Intent $i -Access $a -Identity $id -Tooling $tools -TimeoutSeconds 2 -PortProbe { param($hostAddress, $port) return $true } -HostKeyScanner $scanner -SshRunner $runner -ProcessProvider $processProvider
        } $root $intent $access $identity $tooling $newLine $readyOutput $launch.ProcessProvider
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
        $access = New-EzVmSshTestAccess -Root $root -Intent $intent -Port 22078 -LaunchId ('c' * 32)
        $launch = New-EzVmSshTestLaunch -Root $root -Intent $intent -Access $access
        $wrong = New-EzVmSshTestIdentityJson -Intent $intent -InstanceName 'wrong-agent'
        $nl = [Environment]::NewLine
        $wrongOutput = New-EzVmSshTestProbe -IdentityBase64 (ConvertTo-EzVmSshTestBase64 $wrong) -CloudStatus 'status: done' -Ready:$true
        $module = Get-Module EzVm
        Assert-EzVmThrows -ScriptBlock {
            & $module {
                param($r, $i, $a, $output, $processProvider)
                $id = [pscustomobject]@{ PrivateKey = (Join-Path $r 'unused-key') }
                $tools = [pscustomobject]@{ Ssh = 'unused-ssh'; Keyscan = 'unused-keyscan' }
                $sshOutput = $output
                $runner = { param($exe, $arguments, $timeout) return [pscustomobject]@{ ExitCode = 0; StdOut = $sshOutput; StdErr = '' } }.GetNewClosure()
                Wait-EzVmSshReady -Root $r -InstanceName 'ssh-agent' -Intent $i -Access $a -Identity $id -Tooling $tools -TimeoutSeconds 2 -PortProbe { param($hostAddress, $port) return $true } -HostKeyScanner { param($port, $timeout) return '[127.0.0.1]:22078 ssh-ed25519 BBBB' } -SshRunner $runner -ProcessProvider $processProvider
            } $root $intent $access $wrongOutput $launch.ProcessProvider
        } -MessagePattern 'identity mismatch' | Out-Null
        $managed = [IO.File]::ReadAllText($paths.InstanceKnownHosts)
        Assert-EzVmTrue -Condition ($managed.Contains('ssh-ed25519 AAAA'))
        Assert-EzVmTrue -Condition (-not $managed.Contains('ssh-ed25519 BBBB'))
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'SSH: readiness rejects authenticated identity mismatch' -ScriptBlock {
    $expected = New-EzVmSshTestIntent
    $wrong = New-EzVmSshTestIdentityJson -Intent $expected -InstanceName 'other-agent'
    $nl = [Environment]::NewLine
    $output = New-EzVmSshTestProbe -IdentityBase64 (ConvertTo-EzVmSshTestBase64 $wrong) -CloudStatus 'status: done' -Ready:$true
    Assert-EzVmThrows -ScriptBlock {
        ConvertFrom-EzVmReadinessProbe -StdOut $output -ExpectedInstanceName 'ssh-agent' -ExpectedBaseId $expected.baseId -ExpectedProfile 'normal' -ExpectedCloudInstanceId (Get-EzVmSshTestCloudId -Intent $expected) -ExpectedProvisioningProfile 'coding-default' -ExpectedProvisioningVersion 1 -ExpectedProvisioningDigest (Get-EzVmCodingProfile).Digest
    } -MessagePattern 'identity mismatch' | Out-Null
}

Add-EzVmTest -Name 'SSH: readiness distinguishes cloud-init incomplete and failed states from READY' -ScriptBlock {
    $intent = New-EzVmSshTestIntent
    $identity = New-EzVmSshTestIdentityJson -Intent $intent -InstanceName 'ssh-agent'
    $identity64 = ConvertTo-EzVmSshTestBase64 $identity
    $nl = [Environment]::NewLine

    $runningOutput = New-EzVmSshTestProbe -IdentityBase64 $identity64 -CloudStatus 'status: running' -Ready:$false
    $running = ConvertFrom-EzVmReadinessProbe -StdOut $runningOutput -ExpectedInstanceName 'ssh-agent' -ExpectedBaseId $intent.baseId -ExpectedProfile 'normal' -ExpectedCloudInstanceId (Get-EzVmSshTestCloudId -Intent $intent) -ExpectedProvisioningProfile 'coding-default' -ExpectedProvisioningVersion 1 -ExpectedProvisioningDigest (Get-EzVmCodingProfile).Digest
    Assert-EzVmEqual -Actual $running.Ready -Expected $false
    Assert-EzVmEqual -Actual $running.CloudDone -Expected $false

    $failedOutput = New-EzVmSshTestProbe -IdentityBase64 $identity64 -CloudStatus 'status: error' -Ready:$false
    Assert-EzVmThrows -ScriptBlock {
        ConvertFrom-EzVmReadinessProbe -StdOut $failedOutput -ExpectedInstanceName 'ssh-agent' -ExpectedBaseId $intent.baseId -ExpectedProfile 'normal' -ExpectedCloudInstanceId (Get-EzVmSshTestCloudId -Intent $intent) -ExpectedProvisioningProfile 'coding-default' -ExpectedProvisioningVersion 1 -ExpectedProvisioningDigest (Get-EzVmCodingProfile).Digest
    } -MessagePattern 'cloud-init reports failed' | Out-Null

    $readyOutput = New-EzVmSshTestProbe -IdentityBase64 $identity64 -CloudStatus 'status: done' -Ready:$true
    $ready = ConvertFrom-EzVmReadinessProbe -StdOut $readyOutput -ExpectedInstanceName 'ssh-agent' -ExpectedBaseId $intent.baseId -ExpectedProfile 'normal' -ExpectedCloudInstanceId (Get-EzVmSshTestCloudId -Intent $intent) -ExpectedProvisioningProfile 'coding-default' -ExpectedProvisioningVersion 1 -ExpectedProvisioningDigest (Get-EzVmCodingProfile).Digest
    Assert-EzVmEqual -Actual $ready.Ready -Expected $true
}

Add-EzVmTest -Name 'SSH: readiness wait has a bounded total timeout when TCP never opens' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'ssh readiness timeout'
    try {
        $intent = New-EzVmSshTestIntent
        $access = New-EzVmSshTestAccess -Root $root -Intent $intent -Port 22001 -LaunchId ('a' * 32)
        $launch = New-EzVmSshTestLaunch -Root $root -Intent $intent -Access $access
        $identity = [pscustomobject]@{ PrivateKey = (Join-Path $root 'unused-key') }
        $tooling = [pscustomobject]@{ Ssh = 'unused-ssh'; Keyscan = 'unused-keyscan' }
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $module = Get-Module EzVm
        Assert-EzVmThrows -ScriptBlock {
            & $module {
                param($r, $i, $a, $id, $tools, $processProvider)
                Wait-EzVmSshReady -Root $r -InstanceName 'ssh-agent' -Intent $i -Access $a -Identity $id -Tooling $tools -TimeoutSeconds 1 -PortProbe { param($hostAddress, $port) return $false } -ProcessProvider $processProvider
            } $root $intent $access $identity $tooling $launch.ProcessProvider
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
        $access = New-EzVmSshTestAccess -Root $root -Intent $intent -Port 22080 -LaunchId ('d' * 32)
        $launch = New-EzVmSshTestLaunch -Root $root -Intent $intent -Access $access
        $identity = [pscustomobject]@{ PrivateKey = (Join-Path $root 'unused-key') }
        $tooling = [pscustomobject]@{ Ssh = 'unused-ssh' }
        $identityJson = New-EzVmSshTestIdentityJson -Intent $intent -InstanceName 'ssh-agent'
        $nl = [Environment]::NewLine
        $readyOutput = New-EzVmSshTestProbe -IdentityBase64 (ConvertTo-EzVmSshTestBase64 $identityJson) -CloudStatus 'status: done' -Ready:$true
        $module = Get-Module EzVm
        $observed = & $module {
            param($r, $i, $a, $id, $tools, $output, $processProvider)
            $state = [pscustomobject]@{ ProcessTimeout = 0; ConnectTimeout = '' }
            $sshOutput = $output
            $candidatePath = Join-Path (Get-EzVmSshPaths -Root $r -InstanceName 'ssh-agent').KnownHostsDirectory ('.ssh-agent.' + $a.launchId + '.candidate')
            $candidateOption = 'UserKnownHostsFile=' + (ConvertTo-EzVmOpenSshConfigPath -Path $candidatePath -ExpandTokens)
            $runner = {
                param($exe, $arguments, $timeout)
                $state.ProcessTimeout = $timeout
                $state.ConnectTimeout = @($arguments | Where-Object { $_ -like 'ConnectTimeout=*' } | Select-Object -First 1)[0]
                if ($arguments -cnotcontains $candidateOption) { throw 'fixture did not receive the expected candidate known-hosts path' }
                [IO.File]::WriteAllText($candidatePath, ('[127.0.0.1]:22080 ssh-ed25519 DDDD' + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
                return [pscustomobject]@{ ExitCode = 0; StdOut = $sshOutput; StdErr = '' }
            }.GetNewClosure()
            $ready = Wait-EzVmSshReady -Root $r -InstanceName 'ssh-agent' -Intent $i -Access $a -Identity $id -Tooling $tools -TimeoutSeconds 120 -PortProbe { param($hostAddress, $port) return $true } -SshRunner $runner -ProcessProvider $processProvider
            return [pscustomobject]@{ Ready = $ready; ProcessTimeout = $state.ProcessTimeout; ConnectTimeout = $state.ConnectTimeout }
        } $root $intent $access $identity $tooling $readyOutput $launch.ProcessProvider

        Assert-EzVmEqual -Actual $observed.Ready.state -Expected 'READY'
        Assert-EzVmTrue -Condition ($observed.ProcessTimeout -ge 118 -and $observed.ProcessTimeout -le 120) -Message 'The live profile check must fit within the caller total deadline.'
        Assert-EzVmEqual -Actual $observed.ConnectTimeout -Expected 'ConnectTimeout=15'
        Assert-EzVmTrue -Condition ([IO.File]::ReadAllText($paths.InstanceKnownHosts).Contains('[127.0.0.1]:22080 ssh-ed25519 DDDD'))
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}
