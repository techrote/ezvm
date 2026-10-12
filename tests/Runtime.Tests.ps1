function New-EzVmRuntimeFixture {
    $baseFixture = New-EzVmBaseBuildFixture
    $baseResult = Invoke-EzVmBaseBuild -Root $baseFixture.Root -Accelerator tcg -BuildTimeoutSeconds 60 -QemuStatusProvider $baseFixture.QemuStatusProvider -SourceProvider $baseFixture.SourceProvider -QemuImgRunner $baseFixture.QemuImgRunner -GuestRunner $baseFixture.GuestRunner
    $state = [pscustomobject]@{
        Processes = New-Object 'System.Collections.Generic.List[object]'
        QmpCalls = New-Object 'System.Collections.Generic.List[string]'
        LaunchCount = 0
        NextPid = 41000
        QmpReady = $true
        PowerdownExits = $true
        QmpFailure = $null
    }
    $baseRunner = $baseFixture.QemuImgRunner

    $storageRunner = {
        param($argumentList)
        $arguments = @($argumentList)
        $command = $arguments[0]
        if ($command -ceq 'create') {
            $destination = [IO.Path]::GetFullPath($arguments[$arguments.Count - 1])
            $backingIndex = [Array]::IndexOf($arguments, '-b')
            $backing = $arguments[$backingIndex + 1]
            $payload = [pscustomobject][ordered]@{ kind = 'runtime-overlay'; backing = $backing }
            [IO.File]::WriteAllText($destination, ($payload | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
            return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
        }
        if ($command -ceq 'info') {
            $path = [IO.Path]::GetFullPath($arguments[$arguments.Count - 1])
            $payload = $null
            try {
                $text = [IO.File]::ReadAllText($path)
                if ($text.StartsWith('{', [StringComparison]::Ordinal)) { $payload = $text | ConvertFrom-Json -ErrorAction Stop }
            } catch { $payload = $null }
            if ($null -ne $payload -and $payload.kind -ceq 'runtime-overlay') {
                $resolved = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($path)) ([string]$payload.backing)))
                $top = [pscustomobject][ordered]@{
                    filename = $path
                    format = 'qcow2'
                    'virtual-size' = [long]17179869184
                    'backing-filename' = [string]$payload.backing
                    'backing-filename-format' = 'qcow2'
                }
                $base = [pscustomobject][ordered]@{
                    filename = $resolved
                    format = 'qcow2'
                    'virtual-size' = [long]17179869184
                }
                if ($arguments -ccontains '--backing-chain') {
                    return [pscustomobject]@{ ExitCode = 0; StdOut = (@($top, $base) | ConvertTo-Json -Compress); StdErr = '' }
                }
                return [pscustomobject]@{ ExitCode = 0; StdOut = ($top | ConvertTo-Json -Compress); StdErr = '' }
            }
        }
        return & $baseRunner $arguments
    }.GetNewClosure()

    $instanceName = 'runtime-agent'
    $null = New-EzVmInstanceIntent -Root $baseFixture.Root -InstanceName $instanceName -BaseId $baseResult.baseId -Cpus 2 -MemoryMiB 2048 -QemuImgRunner $storageRunner
    $guard = New-EzVmStorageLifecycleGuard -State 'proven-safe' -Source 'runtime fixture has no QEMU owner'
    $overlay = New-EzVmInstanceOverlay -Root $baseFixture.Root -InstanceName $instanceName -BaseId $baseResult.baseId -LifecycleGuard $guard -QemuImgRunner $storageRunner

    $qemuStatusProvider = {
        param($fixtureRoot)
        $paths = Get-EzVmPaths -Root $fixtureRoot
        [pscustomobject]@{
            Valid = $true
            Reason = 'runtime fixture managed QEMU'
            QemuSystem = Join-Path $paths.Qemu 'qemu-system-x86_64.exe'
            QemuImg = Join-Path $paths.Qemu 'qemu-img.exe'
        }
    }

    $processState = $state
    $launcher = {
        param($filePath, $arguments, $workingDirectory)
        $processState.LaunchCount++
        $pidValue = $processState.NextPid
        $processState.NextPid++
        $started = [DateTime]::UtcNow.ToString('o')
        $processState.Processes.Add([pscustomobject]@{
            Pid = $pidValue
            ExecutablePath = [IO.Path]::GetFullPath($filePath)
            Arguments = [string[]]@($arguments)
            StartTimeUtc = $started
        })
        [pscustomobject]@{ Pid = $pidValue; StartTimeUtc = $started }
    }.GetNewClosure()

    $provider = {
        param($processId)
        if ($null -eq $processId) { return @($processState.Processes.ToArray()) }
        return @($processState.Processes.ToArray() | Where-Object { $_.Pid -eq [int]$processId })
    }.GetNewClosure()

    $qmp = {
        param($pipeName, $command, $timeoutMilliseconds)
        $processState.QmpCalls.Add($command)
        if ($null -ne $processState.QmpFailure) { throw [InvalidOperationException]::new([string]$processState.QmpFailure) }
        if ($command -ceq 'query-status') {
            if (-not $processState.QmpReady) { throw 'synthetic QMP not ready' }
            return [pscustomobject]@{ status = 'running'; running = $true }
        }
        if ($command -ceq 'system_powerdown') {
            if ($processState.PowerdownExits) { $processState.Processes.Clear() }
            return [pscustomobject]@{}
        }
        throw "unexpected fixture QMP command $command"
    }.GetNewClosure()

    return [pscustomobject]@{
        BaseFixture = $baseFixture
        Root = $baseFixture.Root
        Paths = $baseFixture.Paths
        BaseId = $baseResult.baseId
        InstanceName = $instanceName
        Overlay = $overlay.Disk
        StorageRunner = $storageRunner
        QemuStatusProvider = $qemuStatusProvider
        ProcessLauncher = $launcher
        ProcessProvider = $provider
        QmpInvoker = $qmp
        State = $state
    }
}

function Remove-EzVmRuntimeFixture {
    param([object]$Fixture)
    if ($null -ne $Fixture) { Remove-EzVmBaseBuildFixture $Fixture.BaseFixture }
}

function Start-EzVmRuntimeFixtureInstance {
    param([object]$Fixture, [string]$Accelerator = 'whpx', [int]$Timeout = 3)
    return Start-EzVmInstance -Root $Fixture.Root -InstanceName $Fixture.InstanceName -Accelerator $Accelerator -StartupTimeoutSeconds $Timeout -QemuImgRunner $Fixture.StorageRunner -QemuStatusProvider $Fixture.QemuStatusProvider -ProcessProvider $Fixture.ProcessProvider -ProcessLauncher $Fixture.ProcessLauncher -QmpInvoker $Fixture.QmpInvoker
}

function Get-EzVmRuntimeFixtureState {
    param([object]$Fixture)
    $path = (Get-EzVmInstanceRuntimePaths -Root $Fixture.Root -InstanceName $Fixture.InstanceName).Runtime
    return Read-EzVmJson -Path $path -SchemaVersion 1
}

function Set-EzVmRuntimeFixtureBacking {
    param([object]$Fixture, [string]$Backing)
    $payload = [IO.File]::ReadAllText($Fixture.Overlay) | ConvertFrom-Json -ErrorAction Stop
    $payload.backing = $Backing
    [IO.File]::WriteAllText($Fixture.Overlay, ($payload | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
}

Add-EzVmTest -Name 'Runtime: QEMU arguments are explicit headless WHPX with host-local named-pipe QMP' -ScriptBlock {
    $fixture = New-EzVmRuntimeFixture
    try {
        $intent = Get-EzVmInstanceIntent -Root $fixture.Root -InstanceName $fixture.InstanceName
        $runtimePaths = Get-EzVmInstanceRuntimePaths -Root $fixture.Root -InstanceName $fixture.InstanceName
        [void][IO.Directory]::CreateDirectory($runtimePaths.Logs)
        $firmware = Get-EzVmRuntimeFirmwarePaths -Root $fixture.Root -InstanceName $fixture.InstanceName
        $pipe = 'ezvm-qmp-' + $fixture.InstanceName + '-' + ('a' * 32)
        $args = New-EzVmRuntimeQemuArguments -InstanceName $fixture.InstanceName -Intent $intent -Disk $fixture.Overlay -FirmwareCode $firmware.Code -FirmwareVariables $firmware.Variables -SerialLog (Join-Path $runtimePaths.Logs 'serial with spaces.log') -QemuLog (Join-Path $runtimePaths.Logs 'qemu with spaces.log') -QmpPipe $pipe -Accelerator whpx
        $joined = ' ' + ($args -join ' ') + ' '
        Assert-EzVmTrue -Condition ($joined -match ' -machine q35 ')
        Assert-EzVmTrue -Condition ($joined -match ' -accel whpx ')
        Assert-EzVmTrue -Condition ($joined -match ' -display none ')
        Assert-EzVmTrue -Condition ($joined -match 'virtio-blk-pci,drive=osdisk')
        Assert-EzVmTrue -Condition ($joined -match 'virtio-net-pci,netdev=net0')
        Assert-EzVmTrue -Condition ($joined -match ('pipe,id=qmp,path=' + [regex]::Escape($pipe)))
        Assert-EzVmTrue -Condition ($joined -notmatch 'qmp.*tcp:') -Message 'Management channel must not be TCP/LAN exposed.'
        Assert-EzVmTrue -Condition ($joined -notmatch 'tcg') -Message 'Normal WHPX arguments must not silently degrade to TCG.'
        $diskToken = @($args | Where-Object { $_ -match '^if=none,id=osdisk' })[0]
        Assert-EzVmTrue -Condition ($diskToken -match 'file=.*runtime-agent\\disk\.qcow2$')
        Assert-EzVmTrue -Condition ($joined -match 'readonly=on.*edk2-x86_64-code\.fd')
    }
    finally { Remove-EzVmRuntimeFixture $fixture }
}

Add-EzVmTest -Name 'Runtime: explicit TCG is visible and does not alter WHPX default' -ScriptBlock {
    $fixture = New-EzVmRuntimeFixture
    try {
        $intent = Get-EzVmInstanceIntent -Root $fixture.Root -InstanceName $fixture.InstanceName
        $runtimePaths = Get-EzVmInstanceRuntimePaths -Root $fixture.Root -InstanceName $fixture.InstanceName
        [void][IO.Directory]::CreateDirectory($runtimePaths.Logs)
        $firmware = Get-EzVmRuntimeFirmwarePaths -Root $fixture.Root -InstanceName $fixture.InstanceName
        $pipe = 'ezvm-qmp-' + $fixture.InstanceName + '-' + ('b' * 32)
        $args = New-EzVmRuntimeQemuArguments -InstanceName $fixture.InstanceName -Intent $intent -Disk $fixture.Overlay -FirmwareCode $firmware.Code -FirmwareVariables $firmware.Variables -SerialLog (Join-Path $runtimePaths.Logs 'serial.log') -QemuLog (Join-Path $runtimePaths.Logs 'qemu.log') -QmpPipe $pipe -Accelerator tcg
        $joined = ' ' + ($args -join ' ') + ' '
        Assert-EzVmTrue -Condition ($joined -match ' -accel tcg,thread=multi ')
        Assert-EzVmTrue -Condition ($joined -match ' -cpu max ')
        Assert-EzVmTrue -Condition ($joined -notmatch ' -accel whpx ')
    }
    finally { Remove-EzVmRuntimeFixture $fixture }
}

Add-EzVmTest -Name 'Runtime: valid start transitions CREATED to RUNNING with durable process evidence' -ScriptBlock {
    $fixture = New-EzVmRuntimeFixture
    try {
        $before = Get-EzVmInstanceStatus -Root $fixture.Root -InstanceName $fixture.InstanceName -ProcessProvider $fixture.ProcessProvider
        Assert-EzVmEqual -Actual $before.state -Expected 'CREATED'
        $started = Start-EzVmRuntimeFixtureInstance -Fixture $fixture
        Assert-EzVmEqual -Actual $started.state -Expected 'RUNNING'
        Assert-EzVmEqual -Actual $started.accelerator -Expected 'whpx'
        Assert-EzVmEqual -Actual $fixture.State.LaunchCount -Expected 1
        $runtime = Get-EzVmRuntimeFixtureState -Fixture $fixture
        Assert-EzVmEqual -Actual $runtime.state -Expected 'RUNNING'
        Assert-EzVmTrue -Condition ($runtime.argumentFingerprint -match '^[a-f0-9]{64}$')
        Assert-EzVmTrue -Condition ($runtime.qemuExecutable -match 'qemu-system-x86_64\.exe$')
        Assert-EzVmTrue -Condition ($runtime.qmpPipe -match '^ezvm-qmp-runtime-agent-')
        Assert-EzVmTrue -Condition ([IO.Path]::IsPathRooted($runtime.serialLog))
        Assert-EzVmTrue -Condition ([IO.Path]::IsPathRooted($runtime.qemuLog))
        $status = Get-EzVmInstanceStatus -Root $fixture.Root -InstanceName $fixture.InstanceName -ProcessProvider $fixture.ProcessProvider
        Assert-EzVmEqual -Actual $status.state -Expected 'RUNNING'
        Assert-EzVmEqual -Actual $status.pid -Expected $started.pid
    }
    finally { Remove-EzVmRuntimeFixture $fixture }
}

Add-EzVmTest -Name 'Runtime: duplicate start refuses before launching another QEMU' -ScriptBlock {
    $fixture = New-EzVmRuntimeFixture
    try {
        $null = Start-EzVmRuntimeFixtureInstance -Fixture $fixture
        Assert-EzVmThrows -ScriptBlock { Start-EzVmRuntimeFixtureInstance -Fixture $fixture } -MessagePattern "cannot start from lifecycle state 'RUNNING'" | Out-Null
        Assert-EzVmEqual -Actual $fixture.State.LaunchCount -Expected 1
    }
    finally { Remove-EzVmRuntimeFixture $fixture }
}

Add-EzVmTest -Name 'Runtime: backing-chain failure prevents QEMU launch' -ScriptBlock {
    $fixture = New-EzVmRuntimeFixture
    try {
        Set-EzVmRuntimeFixtureBacking -Fixture $fixture -Backing '..\..\..\outside.qcow2'
        Assert-EzVmThrows -ScriptBlock { Start-EzVmRuntimeFixtureInstance -Fixture $fixture } -MessagePattern 'outside|escapes|missing' | Out-Null
        Assert-EzVmEqual -Actual $fixture.State.LaunchCount -Expected 0
        Assert-EzVmEqual -Actual $fixture.State.Processes.Count -Expected 0
    }
    finally { Remove-EzVmRuntimeFixture $fixture }
}

Add-EzVmTest -Name 'Runtime: graceful stop sends system_powerdown and records STOPPED' -ScriptBlock {
    $fixture = New-EzVmRuntimeFixture
    try {
        $null = Start-EzVmRuntimeFixtureInstance -Fixture $fixture
        $stopped = Stop-EzVmInstance -Root $fixture.Root -InstanceName $fixture.InstanceName -ShutdownTimeoutSeconds 3 -ProcessProvider $fixture.ProcessProvider -QmpInvoker $fixture.QmpInvoker
        Assert-EzVmEqual -Actual $stopped.state -Expected 'STOPPED'
        Assert-EzVmTrue -Condition (-not $stopped.alreadyStopped)
        Assert-EzVmTrue -Condition ($fixture.State.QmpCalls -ccontains 'system_powerdown')
        $runtime = Get-EzVmRuntimeFixtureState -Fixture $fixture
        Assert-EzVmEqual -Actual $runtime.state -Expected 'STOPPED'
        Assert-EzVmTrue -Condition (-not [string]::IsNullOrWhiteSpace($runtime.stoppedAt))
        $status = Get-EzVmInstanceStatus -Root $fixture.Root -InstanceName $fixture.InstanceName -ProcessProvider $fixture.ProcessProvider
        Assert-EzVmEqual -Actual $status.state -Expected 'STOPPED'
        $guard = Get-EzVmInstanceStorageLifecycleGuard -Root $fixture.Root -InstanceName $fixture.InstanceName -ProcessProvider $fixture.ProcessProvider
        Assert-EzVmEqual -Actual $guard.state -Expected 'proven-safe'
    }
    finally { Remove-EzVmRuntimeFixture $fixture }
}

Add-EzVmTest -Name 'Runtime: stop timeout never silently kills QEMU' -ScriptBlock {
    $fixture = New-EzVmRuntimeFixture
    try {
        $null = Start-EzVmRuntimeFixtureInstance -Fixture $fixture
        $fixture.State.PowerdownExits = $false
        Assert-EzVmThrows -ScriptBlock {
            Stop-EzVmInstance -Root $fixture.Root -InstanceName $fixture.InstanceName -ShutdownTimeoutSeconds 1 -ProcessProvider $fixture.ProcessProvider -QmpInvoker $fixture.QmpInvoker
        } -MessagePattern 'was not killed.*STOPPING' | Out-Null
        Assert-EzVmEqual -Actual $fixture.State.Processes.Count -Expected 1
        Assert-EzVmEqual -Actual (Get-EzVmRuntimeFixtureState -Fixture $fixture).state -Expected 'STOPPING'
    }
    finally { Remove-EzVmRuntimeFixture $fixture }
}

Add-EzVmTest -Name 'Runtime: stale PID and reused unrelated executable are not treated as the VM' -ScriptBlock {
    $fixture = New-EzVmRuntimeFixture
    try {
        $started = Start-EzVmRuntimeFixtureInstance -Fixture $fixture
        $fixture.State.Processes.Clear()
        $stale = Get-EzVmInstanceStatus -Root $fixture.Root -InstanceName $fixture.InstanceName -ProcessProvider $fixture.ProcessProvider
        Assert-EzVmEqual -Actual $stale.state -Expected 'STALE'
        Assert-EzVmTrue -Condition ($stale.reason -match 'no longer exists')

        $runtime = Get-EzVmRuntimeFixtureState -Fixture $fixture
        $fixture.State.Processes.Add([pscustomobject]@{
            Pid = [int]$runtime.pid
            ExecutablePath = 'C:\Windows\System32\notepad.exe'
            Arguments = @('unrelated')
            StartTimeUtc = [string]$runtime.processStartTimeUtc
        })
        $reused = Get-EzVmInstanceStatus -Root $fixture.Root -InstanceName $fixture.InstanceName -ProcessProvider $fixture.ProcessProvider
        Assert-EzVmEqual -Actual $reused.state -Expected 'STALE'
        Assert-EzVmTrue -Condition ($reused.reason -match 'not the recorded QEMU executable')
        $guard = Get-EzVmInstanceStorageLifecycleGuard -Root $fixture.Root -InstanceName $fixture.InstanceName -ProcessProvider $fixture.ProcessProvider
        Assert-EzVmEqual -Actual $guard.state -Expected 'unknown'
    }
    finally { Remove-EzVmRuntimeFixture $fixture }
}

Add-EzVmTest -Name 'Runtime: mismatched launch fingerprint is STALE and storage remains fail-closed' -ScriptBlock {
    $fixture = New-EzVmRuntimeFixture
    try {
        $null = Start-EzVmRuntimeFixtureInstance -Fixture $fixture
        $process = $fixture.State.Processes[0]
        $process.Arguments = [string[]](@($process.Arguments) + @('-unexpected-token'))
        $status = Get-EzVmInstanceStatus -Root $fixture.Root -InstanceName $fixture.InstanceName -ProcessProvider $fixture.ProcessProvider
        Assert-EzVmEqual -Actual $status.state -Expected 'STALE'
        Assert-EzVmTrue -Condition ($status.reason -match 'fingerprint')
        Assert-EzVmEqual -Actual (Get-EzVmInstanceStorageLifecycleGuard -Root $fixture.Root -InstanceName $fixture.InstanceName -ProcessProvider $fixture.ProcessProvider).state -Expected 'unknown'
    }
    finally { Remove-EzVmRuntimeFixture $fixture }
}

Add-EzVmTest -Name 'Runtime: corrupted runtime.json returns UNKNOWN instead of trusting process metadata' -ScriptBlock {
    $fixture = New-EzVmRuntimeFixture
    try {
        $null = Start-EzVmRuntimeFixtureInstance -Fixture $fixture
        $runtimePath = (Get-EzVmInstanceRuntimePaths -Root $fixture.Root -InstanceName $fixture.InstanceName).Runtime
        [IO.File]::WriteAllText($runtimePath, '{"schemaVersion":1,"broken":', (New-Object Text.UTF8Encoding($false)))
        $status = Get-EzVmInstanceStatus -Root $fixture.Root -InstanceName $fixture.InstanceName -ProcessProvider $fixture.ProcessProvider
        Assert-EzVmEqual -Actual $status.state -Expected 'UNKNOWN'
        Assert-EzVmTrue -Condition ($status.reason -match 'runtime.json is corrupt')
        Assert-EzVmThrows -ScriptBlock {
            Stop-EzVmInstance -Root $fixture.Root -InstanceName $fixture.InstanceName -ShutdownTimeoutSeconds 1 -ProcessProvider $fixture.ProcessProvider -QmpInvoker $fixture.QmpInvoker
        } -MessagePattern "cannot be stopped safely from lifecycle state 'UNKNOWN'" | Out-Null
        Assert-EzVmEqual -Actual $fixture.State.Processes.Count -Expected 1
    }
    finally { Remove-EzVmRuntimeFixture $fixture }
}

Add-EzVmTest -Name 'Runtime: untracked QEMU owner makes missing runtime evidence UNKNOWN' -ScriptBlock {
    $fixture = New-EzVmRuntimeFixture
    try {
        $runtimePaths = Get-EzVmInstanceRuntimePaths -Root $fixture.Root -InstanceName $fixture.InstanceName
        $intent = Get-EzVmInstanceIntent -Root $fixture.Root -InstanceName $fixture.InstanceName
        [void][IO.Directory]::CreateDirectory($runtimePaths.Logs)
        $firmware = Get-EzVmRuntimeFirmwarePaths -Root $fixture.Root -InstanceName $fixture.InstanceName
        $args = New-EzVmRuntimeQemuArguments -InstanceName $fixture.InstanceName -Intent $intent -Disk $fixture.Overlay -FirmwareCode $firmware.Code -FirmwareVariables $firmware.Variables -SerialLog (Join-Path $runtimePaths.Logs 'serial-untracked.log') -QemuLog (Join-Path $runtimePaths.Logs 'qemu-untracked.log') -QmpPipe ('ezvm-qmp-' + $fixture.InstanceName + '-' + ('c' * 32)) -Accelerator whpx
        $fixture.State.Processes.Add([pscustomobject]@{
            Pid = 49999
            ExecutablePath = Join-Path $fixture.Paths.Qemu 'qemu-system-x86_64.exe'
            Arguments = [string[]]$args
            StartTimeUtc = [DateTime]::UtcNow.ToString('o')
        })
        $status = Get-EzVmInstanceStatus -Root $fixture.Root -InstanceName $fixture.InstanceName -ProcessProvider $fixture.ProcessProvider
        Assert-EzVmEqual -Actual $status.state -Expected 'UNKNOWN'
        Assert-EzVmTrue -Condition ($status.reason -match 'without matching active runtime ownership evidence')
        Assert-EzVmEqual -Actual (Get-EzVmInstanceStorageLifecycleGuard -Root $fixture.Root -InstanceName $fixture.InstanceName -ProcessProvider $fixture.ProcessProvider).state -Expected 'unknown'
    }
    finally { Remove-EzVmRuntimeFixture $fixture }
}

Add-EzVmTest -Name 'Runtime: startup timeout leaves STARTING ownership evidence and does not kill QEMU' -ScriptBlock {
    $fixture = New-EzVmRuntimeFixture
    try {
        $fixture.State.QmpReady = $false
        Assert-EzVmThrows -ScriptBlock { Start-EzVmRuntimeFixtureInstance -Fixture $fixture -Timeout 1 } -MessagePattern 'startup timeout.*still owns the disk.*STARTING' | Out-Null
        Assert-EzVmEqual -Actual $fixture.State.Processes.Count -Expected 1
        Assert-EzVmEqual -Actual (Get-EzVmRuntimeFixtureState -Fixture $fixture).state -Expected 'STARTING'
    }
    finally { Remove-EzVmRuntimeFixture $fixture }
}

Add-EzVmTest -Name 'Runtime: lifecycle lock refuses concurrent mutation and stale lock file is reusable' -ScriptBlock {
    $fixture = New-EzVmRuntimeFixture
    try {
        $module = Get-Module EzVm
        $held = & $module { param($root, $name) Enter-EzVmInstanceLifecycleLock -Root $root -InstanceName $name -TimeoutMilliseconds 500 } $fixture.Root $fixture.InstanceName
        try {
            Assert-EzVmThrows -ScriptBlock {
                & $module { param($root, $name) Enter-EzVmInstanceLifecycleLock -Root $root -InstanceName $name -TimeoutMilliseconds 100 } $fixture.Root $fixture.InstanceName
            } -MessagePattern 'Timed out waiting for lifecycle lock' | Out-Null
        }
        finally { $held.Dispose() }

        $again = & $module { param($root, $name) Enter-EzVmInstanceLifecycleLock -Root $root -InstanceName $name -TimeoutMilliseconds 500 } $fixture.Root $fixture.InstanceName
        try { Assert-EzVmTrue -Condition ($null -ne $again) }
        finally { $again.Dispose() }
    }
    finally { Remove-EzVmRuntimeFixture $fixture }
}

Add-EzVmTest -Name 'Runtime: argument fingerprint changes on launch-affecting token changes' -ScriptBlock {
    $a = Get-EzVmArgumentFingerprint -ArgumentList @('-machine', 'q35', '-accel', 'whpx')
    $b = Get-EzVmArgumentFingerprint -ArgumentList @('-machine', 'q35', '-accel', 'tcg,thread=multi')
    Assert-EzVmTrue -Condition ($a -match '^[a-f0-9]{64}$')
    Assert-EzVmTrue -Condition ($b -match '^[a-f0-9]{64}$')
    Assert-EzVmTrue -Condition ($a -cne $b)
}
