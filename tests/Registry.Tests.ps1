function New-EzVmRegistryFixture {
    $baseFixture = New-EzVmBaseBuildFixture
    $base = Invoke-EzVmBaseBuild -Root $baseFixture.Root -Accelerator tcg -BuildTimeoutSeconds 60 -QemuStatusProvider $baseFixture.QemuStatusProvider -SourceProvider $baseFixture.SourceProvider -QemuImgRunner $baseFixture.QemuImgRunner -GuestRunner $baseFixture.GuestRunner
    $baseRunner = $baseFixture.QemuImgRunner

    $storageRunner = {
        param($argumentList)
        $arguments = @($argumentList)
        $command = $arguments[0]
        if ($command -ceq 'create' -and $arguments -ccontains '-b') {
            $destination = [IO.Path]::GetFullPath($arguments[$arguments.Count - 1])
            $backingIndex = [Array]::IndexOf($arguments, '-b')
            $backing = [string]$arguments[$backingIndex + 1]
            $payload = [pscustomobject][ordered]@{ kind = 'registry-overlay'; backing = $backing }
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
            if ($null -ne $payload -and $payload.kind -ceq 'registry-overlay') {
                $resolved = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($path)) ([string]$payload.backing)))
                $top = [pscustomobject][ordered]@{
                    filename = $path
                    format = 'qcow2'
                    'virtual-size' = [long]17179869184
                    'backing-filename' = [string]$payload.backing
                    'backing-filename-format' = 'qcow2'
                }
                $baseInfo = [pscustomobject][ordered]@{
                    filename = $resolved
                    format = 'qcow2'
                    'virtual-size' = [long]17179869184
                }
                if ($arguments -ccontains '--backing-chain') {
                    return [pscustomobject]@{ ExitCode = 0; StdOut = (@($top, $baseInfo) | ConvertTo-Json -Compress); StdErr = '' }
                }
                return [pscustomobject]@{ ExitCode = 0; StdOut = ($top | ConvertTo-Json -Compress); StdErr = '' }
            }
        }
        return & $baseRunner $arguments
    }.GetNewClosure()

    return [pscustomobject]@{
        BaseFixture = $baseFixture
        Root = $baseFixture.Root
        Paths = $baseFixture.Paths
        BaseId = $base.baseId
        StorageRunner = $storageRunner
        QemuStatusProvider = $baseFixture.QemuStatusProvider
    }
}

function Remove-EzVmRegistryFixture {
    param([object]$Fixture)
    if ($null -ne $Fixture) { Remove-EzVmBaseBuildFixture $Fixture.BaseFixture }
}

Add-EzVmTest -Name 'Registry: portable instance names accept conservative values and reject traversal and Windows devices' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'registry names'
    try {
        foreach ($name in @('agent1', 'agent.one', 'AGENT_two-3')) {
            $paths = Get-EzVmInstanceStoragePaths -Root $root -InstanceName $name
            Assert-EzVmTrue -Condition ($paths.Directory.EndsWith($name, [StringComparison]::Ordinal))
        }
        foreach ($name in @('.', '..', '../escape', 'C:escape', 'bad/name', 'bad\name', 'NUL', 'con.txt', 'COM1', 'LPT9.log')) {
            Assert-EzVmThrows -ScriptBlock {
                Get-EzVmInstanceStoragePaths -Root $root -InstanceName $name
            } -MessagePattern 'invalid|reserved|unsafe' | Out-Null
        }
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Registry: profiles and explicit resource overrides resolve predictably' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'registry profiles'
    try {
        $light = Resolve-EzVmInstanceResources -Root $root -Profile light
        Assert-EzVmEqual -Actual $light.cpus -Expected 2
        Assert-EzVmEqual -Actual $light.memoryMiB -Expected 4096

        $normal = Resolve-EzVmInstanceResources -Root $root
        Assert-EzVmEqual -Actual $normal.profile -Expected 'normal'
        Assert-EzVmEqual -Actual $normal.cpus -Expected 4
        Assert-EzVmEqual -Actual $normal.memoryMiB -Expected 8192

        $override = Resolve-EzVmInstanceResources -Root $root -Profile heavy -Cpus 6 -MemoryMiB 12288
        Assert-EzVmEqual -Actual $override.profile -Expected 'heavy'
        Assert-EzVmEqual -Actual $override.cpus -Expected 6
        Assert-EzVmEqual -Actual $override.memoryMiB -Expected 12288

        Assert-EzVmThrows -ScriptBlock { Resolve-EzVmInstanceResources -Root $root -Profile enormous } -MessagePattern 'invalid' | Out-Null
        Assert-EzVmThrows -ScriptBlock { Resolve-EzVmInstanceResources -Root $root -Profile normal -Cpus 0 } -MessagePattern 'integer from 1' | Out-Null
        Assert-EzVmThrows -ScriptBlock { Resolve-EzVmInstanceResources -Root $root -Profile normal -MemoryMiB 256 } -MessagePattern 'integer from 512' | Out-Null
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Registry: managed create persists complete relocatable intent and one-level overlay' -ScriptBlock {
    $fixture = New-EzVmRegistryFixture
    try {
        $created = New-EzVmManagedInstance -Root $fixture.Root -InstanceName 'agent-one' -BaseId $fixture.BaseId -Profile light -Cpus 3 -MemoryMiB 6144 -QemuImgRunner $fixture.StorageRunner -PortProbe { param($port) return $true }
        Assert-EzVmEqual -Actual $created.profile -Expected 'light'
        Assert-EzVmEqual -Actual $created.cpus -Expected 3
        Assert-EzVmEqual -Actual $created.memoryMiB -Expected 6144
        Assert-EzVmEqual -Actual $created.sshPort -Expected 22000
        Assert-EzVmEqual -Actual $created.chainDepth -Expected 1

        $intent = Get-EzVmInstanceIntent -Root $fixture.Root -InstanceName 'agent-one'
        Assert-EzVmEqual -Actual $intent.profile -Expected 'light'
        Assert-EzVmEqual -Actual $intent.sshPort -Expected 22000
        Assert-EzVmEqual -Actual $intent.provisioningProfile -Expected 'coding-default'
        Assert-EzVmEqual -Actual $intent.provisioningVersion -Expected 1
        $intentPath = (Get-EzVmInstanceRuntimePaths -Root $fixture.Root -InstanceName 'agent-one').Intent
        $json = [IO.File]::ReadAllText($intentPath)
        Assert-EzVmTrue -Condition ($json -notmatch [regex]::Escape([IO.Path]::GetFullPath($fixture.Root))) -Message 'Durable instance intent must not persist the checkout root.'
    }
    finally { Remove-EzVmRegistryFixture $fixture }
}

Add-EzVmTest -Name 'Registry: several instances receive unique persistent ports from one allocation authority' -ScriptBlock {
    $fixture = New-EzVmRegistryFixture
    try {
        $created = @()
        foreach ($name in @('agent-a', 'agent-b', 'agent-c', 'agent-d')) {
            $created += New-EzVmManagedInstance -Root $fixture.Root -InstanceName $name -BaseId $fixture.BaseId -Profile light -QemuImgRunner $fixture.StorageRunner -PortProbe { param($port) return $true }
        }
        Assert-EzVmEqual -Actual @($created | ForEach-Object { $_.sshPort }) -Expected @(22000, 22001, 22002, 22003)
        Assert-EzVmEqual -Actual @(Get-EzVmAllocatedSshPorts -Root $fixture.Root | Sort-Object) -Expected @(22000, 22001, 22002, 22003)
        Assert-EzVmEqual -Actual @(Get-EzVmInstanceRegistry -Root $fixture.Root).Count -Expected 4
    }
    finally { Remove-EzVmRegistryFixture $fixture }
}

Add-EzVmTest -Name 'Registry: allocation skips a real unrelated loopback listener' -ScriptBlock {
    $fixture = New-EzVmRegistryFixture
    $listener = $null
    try {
        $firstPort = $null
        for ($candidate = 30000; $candidate -lt 50000; $candidate += 2) {
            $a = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $candidate)
            $b = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, ($candidate + 1))
            try {
                $a.Server.ExclusiveAddressUse = $true
                $b.Server.ExclusiveAddressUse = $true
                $a.Start()
                $b.Start()
                $firstPort = $candidate
                $listener = $a
                $a = $null
                $b.Stop()
                $b = $null
                break
            }
            catch { }
            finally {
                if ($null -ne $a) { try { $a.Stop() } catch { } }
                if ($null -ne $b) { try { $b.Stop() } catch { } }
            }
        }
        Assert-EzVmTrue -Condition ($null -ne $firstPort) -Message 'Fixture could not reserve a consecutive loopback port pair.'

        [void][IO.Directory]::CreateDirectory($fixture.Paths.Runtime)
        $override = [pscustomobject][ordered]@{
            schemaVersion = 1
            ssh = [pscustomobject][ordered]@{ portRangeStart = $firstPort; portRangeEnd = ($firstPort + 1) }
        }
        Write-EzVmJson -Path $fixture.Paths.UserConfig -Value $override -SchemaVersion 1

        $created = New-EzVmManagedInstance -Root $fixture.Root -InstanceName 'collision-safe' -BaseId $fixture.BaseId -Profile light -QemuImgRunner $fixture.StorageRunner
        Assert-EzVmEqual -Actual $created.sshPort -Expected ($firstPort + 1)
    }
    finally {
        if ($null -ne $listener) { try { $listener.Stop() } catch { } }
        Remove-EzVmRegistryFixture $fixture
    }
}

Add-EzVmTest -Name 'Registry: allocation lock serializes competing creators and stale lock files are reusable' -ScriptBlock {
    $fixture = New-EzVmRegistryFixture
    try {
        $module = Get-Module EzVm
        $held = & $module { param($root) Enter-EzVmSshAllocationLock -Root $root -TimeoutMilliseconds 500 } $fixture.Root
        try {
            Assert-EzVmThrows -ScriptBlock {
                & $module { param($root) Enter-EzVmSshAllocationLock -Root $root -TimeoutMilliseconds 100 } $fixture.Root
            } -MessagePattern 'Timed out waiting for the ezvm SSH port-allocation lock' | Out-Null
        }
        finally { $held.Dispose() }

        $again = & $module { param($root) Enter-EzVmSshAllocationLock -Root $root -TimeoutMilliseconds 500 } $fixture.Root
        try { Assert-EzVmTrue -Condition ($null -ne $again) }
        finally { $again.Dispose() }

        $created = New-EzVmManagedInstance -Root $fixture.Root -InstanceName 'after-stale-lock' -BaseId $fixture.BaseId -Profile light -QemuImgRunner $fixture.StorageRunner -PortProbe { param($port) return $true }
        Assert-EzVmEqual -Actual $created.sshPort -Expected 22000
    }
    finally { Remove-EzVmRegistryFixture $fixture }
}

Add-EzVmTest -Name 'Registry: reconstruction survives root relocation and fails on directory-intent disagreement' -ScriptBlock {
    $fixture = New-EzVmRegistryFixture
    $relocated = $null
    try {
        $null = New-EzVmManagedInstance -Root $fixture.Root -InstanceName 'portable-agent' -BaseId $fixture.BaseId -Profile normal -QemuImgRunner $fixture.StorageRunner -PortProbe { param($port) return $true }

        $relocated = New-EzVmTestDirectory -Prefix 'registry relocated'
        Remove-Item -LiteralPath $relocated -Recurse -Force
        Copy-Item -LiteralPath $fixture.Root -Destination $relocated -Recurse -Force
        $rebuilt = @(Get-EzVmInstanceRegistry -Root $relocated)
        Assert-EzVmEqual -Actual $rebuilt.Count -Expected 1
        Assert-EzVmEqual -Actual $rebuilt[0].name -Expected 'portable-agent'
        Assert-EzVmEqual -Actual $rebuilt[0].sshPort -Expected 22000

        $intentPath = (Get-EzVmInstanceRuntimePaths -Root $relocated -InstanceName 'portable-agent').Intent
        $intent = Read-EzVmJson -Path $intentPath -SchemaVersion 1
        $intent.name = 'other-agent'
        Write-EzVmJson -Path $intentPath -Value $intent -SchemaVersion 1
        Assert-EzVmThrows -ScriptBlock { Get-EzVmInstanceRegistry -Root $relocated } -MessagePattern 'does not match managed instance' | Out-Null
    }
    finally {
        if ($null -ne $relocated) { Remove-EzVmTestDirectory -Path $relocated }
        Remove-EzVmRegistryFixture $fixture
    }
}

Add-EzVmTest -Name 'Registry: duplicate durable SSH reservations fail reconstruction instead of colliding silently' -ScriptBlock {
    $fixture = New-EzVmRegistryFixture
    try {
        $null = New-EzVmManagedInstance -Root $fixture.Root -InstanceName 'dup-one' -BaseId $fixture.BaseId -Profile light -QemuImgRunner $fixture.StorageRunner -PortProbe { param($port) return $true }
        $null = New-EzVmManagedInstance -Root $fixture.Root -InstanceName 'dup-two' -BaseId $fixture.BaseId -Profile light -QemuImgRunner $fixture.StorageRunner -PortProbe { param($port) return $true }
        $secondPath = (Get-EzVmInstanceRuntimePaths -Root $fixture.Root -InstanceName 'dup-two').Intent
        $second = Read-EzVmJson -Path $secondPath -SchemaVersion 1
        $second.sshPort = 22000
        Write-EzVmJson -Path $secondPath -Value $second -SchemaVersion 1
        Assert-EzVmThrows -ScriptBlock { Get-EzVmInstanceRegistry -Root $fixture.Root } -MessagePattern 'both reserve SSH port 22000' | Out-Null
    }
    finally { Remove-EzVmRegistryFixture $fixture }
}

Add-EzVmTest -Name 'Registry: legacy EZVM-006 intent is refused with explicit migration guidance' -ScriptBlock {
    $fixture = New-EzVmRegistryFixture
    try {
        $runtimePaths = Get-EzVmInstanceRuntimePaths -Root $fixture.Root -InstanceName 'legacy-agent'
        [void][IO.Directory]::CreateDirectory($runtimePaths.Directory)
        $legacy = [pscustomobject][ordered]@{
            schemaVersion = 1
            name = 'legacy-agent'
            baseId = $fixture.BaseId
            cpus = 2
            memoryMiB = 4096
            createdAt = [DateTime]::UtcNow.ToString('o')
        }
        Write-EzVmJson -Path $runtimePaths.Intent -Value $legacy -SchemaVersion 1
        Assert-EzVmThrows -ScriptBlock { Get-EzVmInstanceIntent -Root $fixture.Root -InstanceName 'legacy-agent' } -MessagePattern 'legacy EZVM-006 schema.*recreate or deliberately migrate' | Out-Null
    }
    finally { Remove-EzVmRegistryFixture $fixture }
}

Add-EzVmTest -Name 'Registry: multiple named instances can enter RUNNING independently with distinct durable SSH resources' -ScriptBlock {
    $fixture = New-EzVmRegistryFixture
    try {
        $one = New-EzVmManagedInstance -Root $fixture.Root -InstanceName 'run-one' -BaseId $fixture.BaseId -Profile light -QemuImgRunner $fixture.StorageRunner -PortProbe { param($port) return $true }
        $two = New-EzVmManagedInstance -Root $fixture.Root -InstanceName 'run-two' -BaseId $fixture.BaseId -Profile light -QemuImgRunner $fixture.StorageRunner -PortProbe { param($port) return $true }

        $state = [pscustomobject]@{
            Processes = New-Object 'System.Collections.Generic.List[object]'
            NextPid = 47000
        }
        $processState = $state
        $launcher = {
            param($filePath, $arguments, $workingDirectory)
            $pidValue = $processState.NextPid
            $processState.NextPid++
            $started = [DateTime]::UtcNow.ToString('o')
            $processState.Processes.Add([pscustomobject]@{
                Pid = $pidValue
                ExecutablePath = [IO.Path]::GetFullPath($filePath)
                Arguments = [string[]]@($arguments)
                StartTimeUtc = $started
            })
            return [pscustomobject]@{ Pid = $pidValue; StartTimeUtc = $started }
        }.GetNewClosure()
        $provider = {
            param($processId)
            if ($null -eq $processId) { return @($processState.Processes.ToArray()) }
            return @($processState.Processes.ToArray() | Where-Object { $_.Pid -eq [int]$processId })
        }.GetNewClosure()
        $qmp = {
            param($hostAddress, $port, $command, $timeoutMilliseconds)
            if ($command -ceq 'query-status') { return [pscustomobject]@{ status = 'running'; running = $true } }
            if ($command -ceq 'system_powerdown') { return [pscustomobject]@{} }
            throw "unexpected QMP command $command"
        }

        $s1 = Start-EzVmInstance -Root $fixture.Root -InstanceName 'run-one' -Accelerator tcg -StartupTimeoutSeconds 3 -QemuImgRunner $fixture.StorageRunner -QemuStatusProvider $fixture.QemuStatusProvider -ProcessProvider $provider -ProcessLauncher $launcher -QmpInvoker $qmp -SshPort $one.sshPort
        $s2 = Start-EzVmInstance -Root $fixture.Root -InstanceName 'run-two' -Accelerator tcg -StartupTimeoutSeconds 3 -QemuImgRunner $fixture.StorageRunner -QemuStatusProvider $fixture.QemuStatusProvider -ProcessProvider $provider -ProcessLauncher $launcher -QmpInvoker $qmp -SshPort $two.sshPort

        Assert-EzVmTrue -Condition ($s1.pid -ne $s2.pid)
        Assert-EzVmEqual -Actual (Get-EzVmInstanceStatus -Root $fixture.Root -InstanceName 'run-one' -ProcessProvider $provider).state -Expected 'RUNNING'
        Assert-EzVmEqual -Actual (Get-EzVmInstanceStatus -Root $fixture.Root -InstanceName 'run-two' -ProcessProvider $provider).state -Expected 'RUNNING'
        Assert-EzVmTrue -Condition ($one.sshPort -ne $two.sshPort)
        Assert-EzVmTrue -Condition ((@($state.Processes[0].Arguments) -join ' ') -match ('hostfwd=tcp:127\.0\.0\.1:' + $one.sshPort + '-:22'))
        Assert-EzVmTrue -Condition ((@($state.Processes[1].Arguments) -join ' ') -match ('hostfwd=tcp:127\.0\.0\.1:' + $two.sshPort + '-:22'))
    }
    finally { Remove-EzVmRegistryFixture $fixture }
}
