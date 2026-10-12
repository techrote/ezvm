function New-EzVmPortabilityIdentityTestIntent {
    param([string]$Name = 'ssh-agent', [string]$Generation = ('b' * 32))
    $intent = New-EzVmSshTestIntent -Name $Name
    $intent.schemaVersion = 2
    $intent | Add-Member -NotePropertyName identityGeneration -NotePropertyValue $Generation
    return $intent
}

function Get-EzVmPortabilitySeedFile {
    param([string]$UserData, [string]$Path)
    $pattern = '(?m)^  - path: ' + [regex]::Escape($Path) + '\n    owner: root:root\n    permissions: ''[0-7]+''\n    encoding: b64\n    content: (?<data>[A-Za-z0-9+/=]+)$'
    $match = [regex]::Match($UserData, $pattern)
    if (-not $match.Success) { throw "Seed lacks encoded file '$Path'." }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($match.Groups['data'].Value))
}

function Invoke-EzVmPortabilityIdentityWaitFixture {
    param([string]$Root, [object]$Intent, [object[]]$Outputs)
    $access = New-EzVmSshTestAccess -Root $Root -Intent $Intent
    $launch = New-EzVmSshTestLaunch -Root $Root -Intent $Intent -Access $access
    $access.state = 'READY'
    $access.readyAt = [DateTime]::UtcNow.ToString('o')
    $paths = Get-EzVmSshPaths -Root $Root -InstanceName $Intent.name
    [void][IO.Directory]::CreateDirectory($paths.KnownHostsDirectory)
    $managedText = '[127.0.0.1]:22001 ssh-ed25519 AAAA' + [Environment]::NewLine
    [IO.File]::WriteAllText($paths.InstanceKnownHosts, $managedText)
    $module = Get-Module EzVm
    return & $module {
        param($r, $i, $a, $responses, $managed, $old, $processProvider)
        $observed = [pscustomobject]@{ Calls = 0; Scans = 0; PrematurePromotion = $false; StrictBypass = $false; Ready = $null; Error = '' }
        $scanner = {
            param($port, $timeout)
            $observed.Scans++
            return '[127.0.0.1]:22001 ssh-ed25519 ' + $(if ($observed.Scans -eq 1) { 'BBBB' } else { 'CCCC' })
        }.GetNewClosure()
        $runner = {
            param($exe, $arguments, $timeout)
            if ([IO.File]::ReadAllText($managed) -cne $old) { $observed.PrematurePromotion = $true }
            if ($arguments -contains 'StrictHostKeyChecking=no') { $observed.StrictBypass = $true }
            $index = [Math]::Min($observed.Calls, $responses.Count - 1)
            $observed.Calls++
            return $responses[$index]
        }.GetNewClosure()
        try {
            $observed.Ready = Wait-EzVmSshReady -Root $r -InstanceName $i.name -Intent $i -Access $a -Identity ([pscustomobject]@{ PrivateKey = (Join-Path $r 'unused-key') }) -Tooling ([pscustomobject]@{ Ssh = 'unused-ssh' }) -TimeoutSeconds 2 -PortProbe { $true } -HostKeyScanner $scanner -SshRunner $runner -ProcessProvider $processProvider
        }
        catch { $observed.Error = $_.Exception.Message }
        return $observed
    } $Root $Intent $access $Outputs $paths.InstanceKnownHosts $managedText $launch.ProcessProvider
}

function Invoke-EzVmPortabilityPublicationRaceFixture {
    param([string]$Root, [string]$Change, [switch]$BeforeWait)
    $intent = New-EzVmPortabilityIdentityTestIntent
    $access = New-EzVmSshTestAccess -Root $Root -Intent $intent
    $launch = New-EzVmSshTestLaunch -Root $Root -Intent $intent -Access $access
    $proof = New-EzVmSshTestProbe -IdentityBase64 (ConvertTo-EzVmSshTestBase64 (New-EzVmSshTestIdentityJson -Intent $intent))
    $module = Get-Module EzVm
    return & $module {
        param($r, $i, $a, $fixture, $output, $change, $beforeWait)
        $paths = Get-EzVmSshPaths -Root $r -InstanceName $i.name
        [void][IO.Directory]::CreateDirectory($paths.KnownHostsDirectory)
        [IO.File]::WriteAllText($paths.InstanceKnownHosts, "[127.0.0.1]:22001 ssh-ed25519 AAAA`n")
        $observed = [pscustomobject]@{ Calls = 0; Changed = $false; Ready = $null; Error = ''; Intent = ''; Runtime = ''; Access = ''; Trust = '' }
        $runtimeModule = Get-Module EzVm
        $interleave = {
            & $runtimeModule {
                param($r, $i, $a, $fixture, $paths, $observed, $change)
                # A concurrent lifecycle operation must be able to obtain this lock
                # while SSH is outstanding, then publish its own durable state.
                $lock = Enter-EzVmInstanceLifecycleLock -Root $r -InstanceName $i.name -TimeoutMilliseconds 200
                try {
                    $currentIntent = Get-EzVmInstanceIntent -Root $r -InstanceName $i.name
                    $currentRuntime = Get-EzVmRuntimeStateFile -Root $r -InstanceName $i.name
                    $currentAccess = $a | ConvertTo-Json -Depth 8 | ConvertFrom-Json
                    if ($change -ceq 'reset') { $currentIntent.identityGeneration = 'c' * 32 }
                    if ($change -ceq 'intent') { $currentIntent.cpus = 3; $currentIntent.profile = 'custom' }
                    if (@('reset', 'restart') -ccontains $change) {
                        $currentRuntime.launchId = 'd' * 32
                        $currentRuntime.pid++
                        $fixture.State.Processes[0].Pid = $currentRuntime.pid
                        $currentAccess.launchId = $currentRuntime.launchId
                    }
                    if ($change -ceq 'stopped') {
                        $currentRuntime.state = 'STOPPED'
                        $currentRuntime.stoppedAt = [DateTime]::UtcNow.ToString('o')
                    }
                    if (@('stopped', 'missing') -ccontains $change) { $fixture.State.Processes.Clear() }
                    if ($change -ceq 'journal') { [IO.File]::WriteAllText($fixture.Paths.Operation, '{"schemaVersion":1}') }
                    $currentAccess.cloudInstanceId = Get-EzVmGuestCloudInstanceId -Intent $currentIntent
                    $currentAccess.profile = $currentIntent.profile
                    $currentAccess.state = 'READY'
                    $currentAccess.readyAt = [DateTime]::UtcNow.ToString('o')
                    Write-EzVmJson -Path $fixture.Paths.Intent -Value $currentIntent -SchemaVersion 2
                    Write-EzVmRuntimeStateFile -Root $r -InstanceName $i.name -Runtime $currentRuntime
                    Write-EzVmSshAccessState -Root $r -InstanceName $i.name -Access $currentAccess
                    [IO.File]::WriteAllText($paths.InstanceKnownHosts, "[127.0.0.1]:22001 ssh-ed25519 CCCC`n")
                    $observed.Intent = [IO.File]::ReadAllText($fixture.Paths.Intent)
                    $observed.Runtime = [IO.File]::ReadAllText($fixture.Paths.Runtime)
                    $observed.Access = [IO.File]::ReadAllText($paths.AccessState)
                    $observed.Trust = [IO.File]::ReadAllText($paths.InstanceKnownHosts)
                    $observed.Changed = $true
                }
                finally { $lock.Dispose() }
            } $r $i $a $fixture $paths $observed $change
        }.GetNewClosure()
        $runner = {
            param($exe, $arguments, $timeout)
            $observed.Calls++
            & $interleave
            return [pscustomobject]@{ ExitCode = 0; StdOut = $output; StdErr = '' }
        }.GetNewClosure()
        if ($beforeWait) { & $interleave }
        try {
            $observed.Ready = Wait-EzVmSshReady -Root $r -InstanceName $i.name -Intent $i -Access $a -Identity ([pscustomobject]@{ PrivateKey = 'unused' }) -Tooling ([pscustomobject]@{ Ssh = 'unused' }) -TimeoutSeconds 3 -PortProbe { $true } -HostKeyScanner { '[127.0.0.1]:22001 ssh-ed25519 BBBB' } -SshRunner $runner -ProcessProvider $fixture.ProcessProvider
        }
        catch { $observed.Error = $_.Exception.Message }
        return [pscustomobject]@{
            Observed = $observed
            Intent = [IO.File]::ReadAllText($fixture.Paths.Intent)
            Runtime = [IO.File]::ReadAllText($fixture.Paths.Runtime)
            Access = [IO.File]::ReadAllText($paths.AccessState)
            Trust = [IO.File]::ReadAllText($paths.InstanceKnownHosts)
            Candidates = @(Get-ChildItem -LiteralPath $paths.KnownHostsDirectory -Filter '*.candidate' -File -Force).Count
        }
    } $Root $intent $access $launch $proof $Change ([bool]$BeforeWait)
}

Add-EzVmTest -Name 'Portability identity: successful stale SSH proof cannot overwrite concurrent lifecycle state or trust' -ScriptBlock {
    foreach ($change in @('reset', 'restart', 'intent', 'stopped', 'missing', 'journal')) {
        $root = New-EzVmCheckoutFixture -Prefix ('readiness publication ' + $change)
        try {
            $result = Invoke-EzVmPortabilityPublicationRaceFixture -Root $root -Change $change
            Assert-EzVmEqual -Actual $result.Observed.Calls -Expected 1 -Message $change
            Assert-EzVmTrue -Condition $result.Observed.Changed -Message "The $change interleaving must complete while the SSH proof is outstanding."
            Assert-EzVmEqual -Actual $result.Observed.Ready -Expected $null -Message $change
            Assert-EzVmTrue -Condition ($result.Observed.Error -match 'before SSH access publication.*Refusing stale readiness') -Message "$change must reject publication: $($result.Observed.Error)"
            Assert-EzVmEqual -Actual $result.Intent -Expected $result.Observed.Intent -Message "$change must preserve current intent."
            Assert-EzVmEqual -Actual $result.Runtime -Expected $result.Observed.Runtime -Message "$change must preserve current runtime."
            Assert-EzVmEqual -Actual $result.Access -Expected $result.Observed.Access -Message "$change must preserve current access."
            Assert-EzVmEqual -Actual $result.Trust -Expected $result.Observed.Trust -Message "$change must preserve current trust."
            Assert-EzVmEqual -Actual $result.Candidates -Expected 0 -Message $change
        }
        finally { Remove-EzVmTestDirectory -Path $root }
    }
}

Add-EzVmTest -Name 'Portability identity: stale initial PROVISIONING cannot invalidate a replacement launch READY' -ScriptBlock {
    foreach ($change in @('reset', 'restart')) {
        $root = New-EzVmCheckoutFixture -Prefix ('readiness initial publication ' + $change)
        try {
            $result = Invoke-EzVmPortabilityPublicationRaceFixture -Root $root -Change $change -BeforeWait
            Assert-EzVmEqual -Actual $result.Observed.Calls -Expected 0
            Assert-EzVmEqual -Actual $result.Observed.Ready -Expected $null
            Assert-EzVmTrue -Condition ($result.Observed.Error -match 'changed before SSH access publication.*Refusing stale readiness') -Message "$change must reject stale initial publication: $($result.Observed.Error)"
            Assert-EzVmEqual -Actual $result.Intent -Expected $result.Observed.Intent
            Assert-EzVmEqual -Actual $result.Runtime -Expected $result.Observed.Runtime
            Assert-EzVmEqual -Actual $result.Access -Expected $result.Observed.Access
            Assert-EzVmEqual -Actual $result.Trust -Expected $result.Observed.Trust
            Assert-EzVmEqual -Actual ($result.Access | ConvertFrom-Json).state -Expected 'READY'
            Assert-EzVmEqual -Actual $result.Candidates -Expected 0
        }
        finally { Remove-EzVmTestDirectory -Path $root }
    }
}

Add-EzVmTest -Name 'Portability identity: schema 1 cloud identity remains unchanged and schema 2 generation separates reset identity' -ScriptBlock {
    $module = Get-Module EzVm
    $legacy = New-EzVmSshTestIntent
    $legacyId = & $module { param($i) Get-EzVmGuestCloudInstanceId -Intent $i } $legacy
    Assert-EzVmEqual -Actual $legacyId -Expected 'ezvm-ssh-agent-de80abc68f36'
    $first = New-EzVmPortabilityIdentityTestIntent
    $reset = New-EzVmPortabilityIdentityTestIntent -Generation ('c' * 32)
    $other = New-EzVmPortabilityIdentityTestIntent -Name 'other-agent'
    $identities = @($legacy, $first, $reset, $other | ForEach-Object {
        & $module { param($i) Get-EzVmGuestCloudInstanceId -Intent $i } $_
    })
    Assert-EzVmEqual -Actual (@($identities | Select-Object -Unique).Count) -Expected 4
    Assert-EzVmEqual -Actual $first.createdAt -Expected $reset.createdAt
    Assert-EzVmEqual -Actual $first.baseId -Expected $reset.baseId
    $uuid = & $module { param($i) Get-EzVmGuestMachineUuid -Intent $i } $first
    Assert-EzVmTrue -Condition ($uuid -cmatch '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$')
    Assert-EzVmEqual -Actual (& $module { param($i) Get-EzVmGuestMachineUuid -Intent $i } $first) -Expected $uuid
    Assert-EzVmTrue -Condition ((& $module { param($i) Get-EzVmGuestMachineUuid -Intent $i } $reset) -cne $uuid)
}

Add-EzVmTest -Name 'Portability identity: malformed identity generations refuse before seed generation' -ScriptBlock {
    foreach ($generation in @('', ('a' * 31), ('a' * 33), ('A' * 32), ('x' * 32), 'abc;reboot', $null, 123)) {
        $intent = New-EzVmPortabilityIdentityTestIntent
        $intent.identityGeneration = $generation
        Assert-EzVmThrows -ScriptBlock {
            New-EzVmInstanceSeedData -Root $script:EzVmRepositoryRoot -InstanceName $intent.name -Intent $intent -ControllerPublicKey 'ssh-ed25519 AAAA'
        } -MessagePattern 'identityGeneration.*32 lowercase' | Out-Null
    }
}

Add-EzVmTest -Name 'Portability identity: cache policy uses system configuration without degrading cloud-config user data' -ScriptBlock {
    # cloud-init 26.1 schema-cloud-config-v1.json rejects unknown top-level
    # properties. manual_cache_clean is a system setting, not a user-data key.
    foreach ($intent in @((New-EzVmSshTestIntent), (New-EzVmPortabilityIdentityTestIntent))) {
        $seed = New-EzVmInstanceSeedData -Root $script:EzVmRepositoryRoot -InstanceName $intent.name -Intent $intent -ControllerPublicKey 'ssh-ed25519 AAAA'
        Assert-EzVmTrue -Condition ($seed.UserData -cnotmatch '(?m)^manual_cache_clean:') -Message 'Unsupported user-data keys cause cloud-init status 2 before identity initialization.'
        $policy = Get-EzVmPortabilitySeedFile -UserData $seed.UserData -Path '/etc/cloud/cloud.cfg.d/99-ezvm-identity.cfg'
        Assert-EzVmEqual -Actual $policy -Expected "manual_cache_clean: false`n"
        if ($intent.schemaVersion -eq 2) {
            $finalizer = Get-EzVmPortabilitySeedFile -UserData $seed.UserData -Path '/usr/local/sbin/ezvm-instance-finalize'
            Assert-EzVmTrue -Condition ($finalizer.Contains('EZVM_GUEST_CLOUD_INIT_EXIT=%s') -and $finalizer.Contains('EZVM_GUEST_FINALIZE_FAILED=stage=%s;exit=%s'))
            Assert-EzVmTrue -Condition ($finalizer.IndexOf('stage=cloud-init') -lt $finalizer.IndexOf('cloud-init status --wait'))
            Assert-EzVmTrue -Condition ($finalizer.IndexOf('stage=identity') -lt $finalizer.IndexOf('/usr/local/sbin/ezvm-instance-identity'))
            Assert-EzVmTrue -Condition ($finalizer.IndexOf('stage=reboot') -lt $finalizer.IndexOf('systemctl reboot'))
            Assert-EzVmTrue -Condition (-not $finalizer.Contains('cat /var/log/ezvm-cloud-init-status.log')) -Message 'Diagnostics must not dump cloud-init output or user-data.'
            $unit = Get-EzVmPortabilitySeedFile -UserData $seed.UserData -Path '/etc/systemd/system/ezvm-instance-finalize.service'
            Assert-EzVmTrue -Condition ($unit.Contains('StandardOutput=journal+console') -and $unit.Contains('StandardError=journal+console'))
        }
    }
}

Add-EzVmTest -Name 'Portability identity: source relocation preserves seed identity and persistent first-boot finalization' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'identity relocated root [spaces]'
    try {
        $intent = New-EzVmPortabilityIdentityTestIntent
        $original = New-EzVmInstanceSeedData -Root $script:EzVmRepositoryRoot -InstanceName $intent.name -Intent $intent -ControllerPublicKey 'ssh-ed25519 AAAA omitted-comment'
        $moved = New-EzVmInstanceSeedData -Root $root -InstanceName $intent.name -Intent $intent -ControllerPublicKey 'ssh-ed25519 AAAA omitted-comment'
        Assert-EzVmEqual -Actual $moved.UserData -Expected $original.UserData
        Assert-EzVmEqual -Actual $moved.MetaData -Expected $original.MetaData
        Assert-EzVmTrue -Condition ($moved.UserData.Contains('ssh_deletekeys: true'))
        Assert-EzVmTrue -Condition ($moved.UserData.Contains('systemctl, start, --no-block, ezvm-instance-finalize.service'))
        $unit = Get-EzVmPortabilitySeedFile -UserData $moved.UserData -Path '/etc/systemd/system/ezvm-instance-finalize.service'
        Assert-EzVmTrue -Condition ($unit.Contains('After=cloud-final.service') -and $unit.Contains('Wants=cloud-final.service'))
        # cloud-init 26.1 cloud-final.service is After=multi-user.target.
        # Target Wants adds an implicit After edge to its member: installing
        # finalization under multi-user would close a cycle on every reboot.
        Assert-EzVmTrue -Condition ($unit -cmatch '(?m)^WantedBy=cloud-init\.target$')
        Assert-EzVmTrue -Condition ($unit -cnotmatch '(?m)^(After|Before|WantedBy|RequiredBy)=.*multi-user\.target')
        Assert-EzVmTrue -Condition ($unit -cnotmatch '(?m)^After=.*cloud-init\.target') -Message 'A member of cloud-init.target must not wait for that target itself.'
        $finalizer = Get-EzVmPortabilitySeedFile -UserData $moved.UserData -Path '/usr/local/sbin/ezvm-instance-finalize'
        Assert-EzVmTrue -Condition ($finalizer.IndexOf('systemctl reboot') -lt $finalizer.IndexOf('ezvm-coding-profile provision'))
        Assert-EzVmTrue -Condition ($finalizer.Contains('cloud-init status --wait'))
        $initializer = Get-EzVmPortabilitySeedFile -UserData $moved.UserData -Path '/usr/local/sbin/ezvm-instance-identity'
        $config64 = [regex]::Match($initializer, "base64.b64decode\('(?<data>[A-Za-z0-9+/=]+)'\)").Groups['data'].Value
        $config = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($config64)) | ConvertFrom-Json
        Assert-EzVmEqual -Actual $config.cloudInstanceId -Expected $moved.CloudInstanceId
        Assert-EzVmEqual -Actual $config.controllerPublicKey -Expected 'ssh-ed25519 AAAA'
        Assert-EzVmEqual -Actual $config.machineId -Expected $config.machineUuid.Replace('-', '')
        Assert-EzVmTrue -Condition ($initializer.IndexOf('hardware_uuid !=') -lt $initializer.IndexOf('private_bytes =')) -Message 'Copied finalizer must check destination hardware before identity mutation.'
        Assert-EzVmTrue -Condition (-not $moved.UserData.Contains([string][char]13))
        Assert-EzVmTrue -Condition (-not $initializer.Contains('omitted-comment'))
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Portability identity: generation-aware QEMU and NoCloud agree and legacy no-reboot remains compatible' -ScriptBlock {
    $root = New-EzVmTestDirectory -Prefix 'identity argv'
    try {
        foreach ($intent in @((New-EzVmSshTestIntent), (New-EzVmPortabilityIdentityTestIntent))) {
            $argv = New-EzVmRuntimeQemuArguments -InstanceName $intent.name -Intent $intent -Disk (Join-Path $root 'disk.qcow2') -FirmwareCode (Join-Path $root 'code.fd') -FirmwareVariables (Join-Path $root 'vars.fd') -SerialLog (Join-Path $root 'serial.log') -QemuLog (Join-Path $root 'qemu.log') -QmpPort 32001 -Accelerator tcg -SshPort 22001 -SeedHostPort 43001
            $uuidIndex = [Array]::IndexOf($argv, '-uuid')
            if ($intent.schemaVersion -eq 2) {
                $module = Get-Module EzVm
                $uuid = & $module { param($i) Get-EzVmGuestMachineUuid -Intent $i } $intent
                Assert-EzVmTrue -Condition ($uuidIndex -ge 0)
                Assert-EzVmEqual -Actual $argv[$uuidIndex + 1] -Expected $uuid
                Assert-EzVmTrue -Condition ($argv -notcontains '-no-reboot')
                $smbios = $argv[[Array]::IndexOf($argv, '-smbios') + 1]
                Assert-EzVmTrue -Condition ($smbios.Contains('i=' + (Get-EzVmSshTestCloudId -Intent $intent) + ';'))
            }
            else {
                Assert-EzVmEqual -Actual $uuidIndex -Expected -1
                Assert-EzVmTrue -Condition ($argv -contains '-no-reboot')
            }
        }
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Portability identity: copied complete source identity remains a strict readiness rejection' -ScriptBlock {
    $source = New-EzVmPortabilityIdentityTestIntent
    $destination = New-EzVmPortabilityIdentityTestIntent -Generation ('c' * 32)
    $copied = New-EzVmSshTestProbe -IdentityBase64 (ConvertTo-EzVmSshTestBase64 (New-EzVmSshTestIdentityJson -Intent $source))
    Assert-EzVmThrows -ScriptBlock {
        ConvertFrom-EzVmCodingTestProbe -StdOut $copied -Intent $destination
    } -MessagePattern 'identity mismatch.*cloudInstanceId' | Out-Null
}

Add-EzVmTest -Name 'Portability identity: pending initialization cannot preserve cached READY or promote copied host trust' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'identity pending'
    try {
        $intent = New-EzVmPortabilityIdentityTestIntent
        $pending = [pscustomobject]@{ ExitCode = 75; StdOut = 'EZVM_GUEST_IDENTITY_PENDING=' + (Get-EzVmSshTestCloudId -Intent $intent); StdErr = '' }
        $observed = Invoke-EzVmPortabilityIdentityWaitFixture -Root $root -Intent $intent -Outputs @($pending)
        Assert-EzVmTrue -Condition ($observed.Error -match 'did not reach authenticated SSH READY.*destination guest identity initialization is pending')
        Assert-EzVmEqual -Actual $observed.PrematurePromotion -Expected $false
        Assert-EzVmEqual -Actual $observed.StrictBypass -Expected $false
        Assert-EzVmTrue -Condition ($observed.Calls -gt 0)
        $paths = Get-EzVmSshPaths -Root $root -InstanceName $intent.name
        $access = Read-EzVmJson -Path $paths.AccessState -SchemaVersion 2
        Assert-EzVmEqual -Actual $access.state -Expected 'PROVISIONING'
        Assert-EzVmEqual -Actual $access.readyAt -Expected ''
        Assert-EzVmTrue -Condition ([IO.File]::ReadAllText($paths.InstanceKnownHosts).Contains('ssh-ed25519 AAAA'))
        Assert-EzVmEqual -Actual (@(Get-ChildItem -LiteralPath $paths.KnownHostsDirectory -Force -File | Where-Object { $_.Name.EndsWith('.candidate') }).Count) -Expected 0
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Portability identity: pending source key and reboot transport rotate only unpromoted candidates before full proof' -ScriptBlock {
    foreach ($firstExit in @(75, 255, -1)) {
        $root = New-EzVmCheckoutFixture -Prefix ('identity key transition ' + $firstExit)
        try {
            $intent = New-EzVmPortabilityIdentityTestIntent
            $pendingText = if ($firstExit -eq 75) { 'EZVM_GUEST_IDENTITY_PENDING=' + (Get-EzVmSshTestCloudId -Intent $intent) } else { '' }
            $first = [pscustomobject]@{ ExitCode = $firstExit; StdOut = $pendingText; StdErr = 'transient bootstrap' }
            $proof = New-EzVmSshTestProbe -IdentityBase64 (ConvertTo-EzVmSshTestBase64 (New-EzVmSshTestIdentityJson -Intent $intent))
            $second = [pscustomobject]@{ ExitCode = 0; StdOut = $proof; StdErr = '' }
            $observed = Invoke-EzVmPortabilityIdentityWaitFixture -Root $root -Intent $intent -Outputs @($first, $second)
            Assert-EzVmEqual -Actual $observed.Error -Expected ''
            Assert-EzVmEqual -Actual $observed.Ready.state -Expected 'READY'
            Assert-EzVmEqual -Actual $observed.Scans -Expected 2
            Assert-EzVmEqual -Actual $observed.PrematurePromotion -Expected $false
            Assert-EzVmEqual -Actual $observed.StrictBypass -Expected $false
            Assert-EzVmTrue -Condition ([IO.File]::ReadAllText((Get-EzVmSshPaths -Root $root -InstanceName $intent.name).InstanceKnownHosts).Contains('ssh-ed25519 CCCC'))
        }
        finally { Remove-EzVmTestDirectory -Path $root }
    }
}

Add-EzVmTest -Name 'Portability identity: persistent Windows SSH disconnects expire without promoting READY or trust' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'identity Windows disconnect'
    try {
        $intent = New-EzVmPortabilityIdentityTestIntent
        # Even copied proof bytes are unusable when the client did not receive
        # successful remote exit status before the channel closed.
        $copiedProof = New-EzVmSshTestProbe -IdentityBase64 (ConvertTo-EzVmSshTestBase64 (New-EzVmSshTestIdentityJson -Intent $intent))
        $disconnect = [pscustomobject]@{ ExitCode = -1; StdOut = $copiedProof; StdErr = 'Connection to 127.0.0.1 closed by remote host.' }
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $observed = Invoke-EzVmPortabilityIdentityWaitFixture -Root $root -Intent $intent -Outputs @($disconnect)
        $clock.Stop()
        Assert-EzVmTrue -Condition ($observed.Error -match 'did not reach authenticated SSH READY within 2 seconds.*SSH authentication/transport is not ready.*closed by remote host')
        Assert-EzVmTrue -Condition ($clock.Elapsed.TotalSeconds -lt 5) -Message 'Repeated disconnects must remain inside the existing bounded readiness wait.'
        Assert-EzVmTrue -Condition ($observed.Calls -gt 1)
        # The loop may allocate one final candidate before observing that less
        # than one second remains for another probe; it must never reuse one.
        Assert-EzVmTrue -Condition ($observed.Scans -ge $observed.Calls -and $observed.Scans -le ($observed.Calls + 1)) -Message 'Each disconnected attempt must discard its unpromoted candidate.'
        Assert-EzVmEqual -Actual $observed.Ready -Expected $null
        Assert-EzVmEqual -Actual $observed.PrematurePromotion -Expected $false
        Assert-EzVmEqual -Actual $observed.StrictBypass -Expected $false
        $paths = Get-EzVmSshPaths -Root $root -InstanceName $intent.name
        $access = Read-EzVmJson -Path $paths.AccessState -SchemaVersion 2
        Assert-EzVmEqual -Actual $access.state -Expected 'PROVISIONING'
        Assert-EzVmEqual -Actual $access.readyAt -Expected ''
        Assert-EzVmEqual -Actual ([IO.File]::ReadAllText($paths.InstanceKnownHosts)) -Expected ('[127.0.0.1]:22001 ssh-ed25519 AAAA' + [Environment]::NewLine)
        Assert-EzVmEqual -Actual (@(Get-ChildItem -LiteralPath $paths.KnownHostsDirectory -Force -File | Where-Object { $_.Name.EndsWith('.candidate') }).Count) -Expected 0
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Portability identity: nontransport SSH exit codes remain fatal despite complete proof bytes' -ScriptBlock {
    foreach ($exitCode in @(1, 70, 254, -2)) {
        $root = New-EzVmCheckoutFixture -Prefix ('identity fatal SSH exit ' + $exitCode)
        try {
            $intent = New-EzVmPortabilityIdentityTestIntent
            $proof = New-EzVmSshTestProbe -IdentityBase64 (ConvertTo-EzVmSshTestBase64 (New-EzVmSshTestIdentityJson -Intent $intent))
            $failure = [pscustomobject]@{ ExitCode = $exitCode; StdOut = $proof; StdErr = 'probe failed' }
            $observed = Invoke-EzVmPortabilityIdentityWaitFixture -Root $root -Intent $intent -Outputs @($failure)
            Assert-EzVmTrue -Condition ($observed.Error -match ('exited unexpectedly with code ' + [regex]::Escape([string]$exitCode)))
            Assert-EzVmEqual -Actual $observed.Calls -Expected 1
            Assert-EzVmEqual -Actual $observed.Ready -Expected $null
            Assert-EzVmEqual -Actual $observed.PrematurePromotion -Expected $false
            Assert-EzVmEqual -Actual $observed.StrictBypass -Expected $false
            $paths = Get-EzVmSshPaths -Root $root -InstanceName $intent.name
            Assert-EzVmEqual -Actual (Read-EzVmJson -Path $paths.AccessState -SchemaVersion 2).state -Expected 'PROVISIONING'
            Assert-EzVmEqual -Actual ([IO.File]::ReadAllText($paths.InstanceKnownHosts)) -Expected ('[127.0.0.1]:22001 ssh-ed25519 AAAA' + [Environment]::NewLine)
            Assert-EzVmEqual -Actual (@(Get-ChildItem -LiteralPath $paths.KnownHostsDirectory -Force -File | Where-Object { $_.Name.EndsWith('.candidate') }).Count) -Expected 0
        }
        finally { Remove-EzVmTestDirectory -Path $root }
    }
}

Add-EzVmTest -Name 'Portability identity: malformed or wrong-generation pending token cannot bypass strict evidence' -ScriptBlock {
    $intent = New-EzVmPortabilityIdentityTestIntent
    $token = 'EZVM_GUEST_IDENTITY_PENDING=' + (Get-EzVmSshTestCloudId -Intent $intent)
    foreach ($case in @(
        [pscustomobject]@{ ExitCode = 75; StdOut = 'EZVM_GUEST_IDENTITY_PENDING=source'; StdErr = '' },
        [pscustomobject]@{ ExitCode = 75; StdOut = ($token + "`nEZVM_PROFILE_CHECK=pass"); StdErr = '' },
        [pscustomobject]@{ ExitCode = 0; StdOut = $token; StdErr = '' }
    )) {
        $root = New-EzVmCheckoutFixture -Prefix 'bad identity pending'
        try {
            $observed = Invoke-EzVmPortabilityIdentityWaitFixture -Root $root -Intent $intent -Outputs @($case)
            Assert-EzVmTrue -Condition ($observed.Error -match 'exited unexpectedly|unexpected or duplicate readiness protocol')
            Assert-EzVmEqual -Actual $observed.Calls -Expected 1
            Assert-EzVmEqual -Actual $observed.PrematurePromotion -Expected $false
            Assert-EzVmTrue -Condition ([IO.File]::ReadAllText((Get-EzVmSshPaths -Root $root -InstanceName $intent.name).InstanceKnownHosts).Contains('ssh-ed25519 AAAA'))
        }
        finally { Remove-EzVmTestDirectory -Path $root }
    }
}

Add-EzVmTest -Name 'Portability identity: initialized destination still rejects wrong identity and live profile failures' -ScriptBlock {
    $intent = New-EzVmPortabilityIdentityTestIntent
    foreach ($kind in @('wrong-identity', 'missing-tool')) {
        $root = New-EzVmCheckoutFixture -Prefix $kind
        try {
            $identity = New-EzVmSshTestIdentityJson -Intent $intent
            if ($kind -ceq 'wrong-identity') {
                $document = $identity | ConvertFrom-Json
                $document.instanceName = 'copied-source'
                $identity = $document | ConvertTo-Json -Compress
                $proof = New-EzVmSshTestProbe -IdentityBase64 (ConvertTo-EzVmSshTestBase64 $identity)
            }
            else { $proof = New-EzVmSshTestProbe -IdentityBase64 (ConvertTo-EzVmSshTestBase64 $identity) -ProfileCheck failed -ProfileError 'missing required command: rg' }
            $observed = Invoke-EzVmPortabilityIdentityWaitFixture -Root $root -Intent $intent -Outputs @([pscustomobject]@{ ExitCode = 0; StdOut = $proof; StdErr = '' })
            Assert-EzVmTrue -Condition ($observed.Error -match 'identity mismatch|missing required command: rg')
            Assert-EzVmEqual -Actual $observed.Calls -Expected 1
            Assert-EzVmEqual -Actual $observed.PrematurePromotion -Expected $false
        }
        finally { Remove-EzVmTestDirectory -Path $root }
    }
}

Add-EzVmTest -Name 'Portability identity: host-generated gate precedes copied readiness and refuses unsafe expected identities' -ScriptBlock {
    $module = Get-Module EzVm
    $intent = New-EzVmPortabilityIdentityTestIntent
    $remote = & $module {
        param($i)
        Get-EzVmReadinessRemoteScript -ProvisioningDigest ('a' * 64) -ExpectedCloudInstanceId (Get-EzVmGuestCloudInstanceId -Intent $i) -ExpectedMachineUuid (Get-EzVmGuestMachineUuid -Intent $i)
    } $intent
    Assert-EzVmTrue -Condition ($remote.IndexOf('guest-identity.json') -lt $remote.IndexOf('identity_b64='))
    Assert-EzVmTrue -Condition ($remote.Contains('initializedBootId') -and $remote.Contains('product_uuid'))
    Assert-EzVmTrue -Condition ($remote.Contains('exit 75') -and $remote.Contains('EZVM_GUEST_IDENTITY_PENDING='))
    Assert-EzVmThrows -ScriptBlock {
        & $module { Get-EzVmReadinessRemoteScript -ProvisioningDigest ('a' * 64) -ExpectedCloudInstanceId 'x;reboot' -ExpectedMachineUuid ('a' * 32) }
    } -MessagePattern 'requires the exact destination' | Out-Null
}

Add-EzVmTest -Name 'Portability identity: SSH allocation refuses a redirected lock directory before creating outside state' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'ssh lock redirection'
    $outside = New-EzVmTestDirectory -Prefix 'ssh lock outside'
    $link = $null
    try {
        $paths = Get-EzVmPaths -Root $root
        [void][IO.Directory]::CreateDirectory($paths.Runtime)
        $link = $paths.Locks
        $linkType = if ($script:EzVmIsWindowsHost) { 'Junction' } else { 'SymbolicLink' }
        $null = New-Item -ItemType $linkType -Path $link -Target $outside -ErrorAction Stop
        $module = Get-Module EzVm
        Assert-EzVmThrows -ScriptBlock {
            & $module { param($r) $lock = Enter-EzVmSshAllocationLock -Root $r; $lock.Dispose() } $root
        } -MessagePattern 'reparse point' | Out-Null
        Assert-EzVmEqual -Actual (@(Get-ChildItem -LiteralPath $outside -Force).Count) -Expected 0
    }
    finally {
        if ($null -ne $link -and (Test-Path -LiteralPath $link)) { [IO.Directory]::Delete($link) }
        Remove-EzVmTestDirectory -Path $root
        Remove-EzVmTestDirectory -Path $outside
    }
}
