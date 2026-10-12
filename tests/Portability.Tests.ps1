function Write-EzVmPortabilityStoppedState {
    param([object]$Fixture)
    $paths = Get-EzVmInstanceRuntimePaths -Root $Fixture.Root -InstanceName $Fixture.Intent.name
    $now = [DateTime]::UtcNow.ToString('o')
    $runtime = [pscustomobject][ordered]@{
        schemaVersion = 1; instanceName = $Fixture.Intent.name; state = 'STOPPED'; pid = 49999
        processStartTimeUtc = $now; qemuExecutable = Join-Path $Fixture.Paths.Qemu 'qemu-system-x86_64.exe'
        argumentFingerprint = 'a' * 64; launchId = 'b' * 32; qmpHost = '127.0.0.1'; qmpPort = 32111
        accelerator = 'tcg'; startedAt = $now; lastObservedAt = $now; stoppedAt = $now
        qemuLog = Join-Path $paths.Logs 'qemu.log'; serialLog = Join-Path $paths.Logs 'serial.log'
    }
    Write-EzVmJson -Path $paths.Runtime -Value $runtime -SchemaVersion 1
    return $runtime
}

Add-EzVmTest -Name 'Portability: explicit fresh and stateful clones have independent intent resources ports and provenance' -ScriptBlock {
    $fixture = New-EzVmSnapshotFixture
    try {
        $paths = Get-EzVmInstanceRuntimePaths -Root $fixture.Root -InstanceName $fixture.Intent.name
        $fixture.Intent.profile = 'custom'; $fixture.Intent.cpus = 3; $fixture.Intent.memoryMiB = 2560
        Write-EzVmJson -Path $paths.Intent -Value $fixture.Intent -SchemaVersion 2
        $sourceDigest = Get-EzVmFileDigest -Path $fixture.Disk -Algorithm SHA256
        $fresh = Copy-EzVmManagedInstance -Root $fixture.Root -SourceInstanceName $fixture.Intent.name -DestinationInstanceName 'fresh-destination' -Mode FRESH -QemuImgRunner $fixture.Runner -ProcessProvider { @() } -PortProbe { $true }
        $stateful = Copy-EzVmManagedInstance -Root $fixture.Root -SourceInstanceName $fixture.Intent.name -DestinationInstanceName 'stateful-destination' -Mode STATEFUL -QemuImgRunner $fixture.Runner -QemuStatusProvider $fixture.QemuStatusProvider -ProcessProvider { @() } -PortProbe { $true }
        Assert-EzVmEqual $fresh.mode 'fresh'
        Assert-EzVmEqual $stateful.mode 'stateful'
        Assert-EzVmEqual $fresh.baseId $fixture.Intent.baseId
        Assert-EzVmTrue ($stateful.baseId -cne $fixture.Intent.baseId)
        Assert-EzVmEqual @($fresh.sshPort, $stateful.sshPort) @(22001, 22002)
        foreach ($copy in @($fresh, $stateful)) {
            Assert-EzVmEqual $copy.profile 'custom'
            Assert-EzVmEqual $copy.cpus 3
            Assert-EzVmEqual $copy.memoryMiB 2560
            Assert-EzVmEqual $copy.chainDepth 1
            Assert-EzVmTrue ($copy.identityGeneration -cne $fixture.Intent.identityGeneration)
            $copyPaths = Get-EzVmInstanceRuntimePaths -Root $fixture.Root -InstanceName $copy.name
            $origin = Read-EzVmJson -Path $copyPaths.Origin -SchemaVersion 1
            Assert-EzVmEqual $origin.sourceInstance.name $fixture.Intent.name
            Assert-EzVmEqual $origin.baseId $copy.baseId
            Assert-EzVmTrue ([IO.File]::ReadAllText($copyPaths.Origin) -notmatch [regex]::Escape($fixture.Root))
            Assert-EzVmEqual (Get-EzVmSnapshotFixturePayload $copyPaths.Disk).data ''
        }
        $derived = Test-EzVmPreparedBase -Root $fixture.Root -BaseId $stateful.baseId -QemuImgRunner $fixture.Runner
        Assert-EzVmEqual $derived.Manifest.kind 'derived'
        Assert-EzVmEqual (Get-EzVmSnapshotFixturePayload $derived.Image).data 'source workspace sentinel and synthetic auth state'
        Assert-EzVmEqual (Get-EzVmSnapshotFixturePayload $fixture.Base.Image).data 'baseline guest bytes'
        Assert-EzVmEqual (Get-EzVmFileDigest -Path $fixture.Disk -Algorithm SHA256) $sourceDigest
    }
    finally { Remove-EzVmSnapshotFixture $fixture }
}

Add-EzVmTest -Name 'Portability: reset keeps baseline resources reservation and prior SSH trust while rotating identity and clearing stale state' -ScriptBlock {
    $fixture = New-EzVmSnapshotFixture
    try {
        $paths = Get-EzVmInstanceRuntimePaths -Root $fixture.Root -InstanceName $fixture.Intent.name
        $ssh = Get-EzVmSshPaths -Root $fixture.Root -InstanceName $fixture.Intent.name
        $null = Write-EzVmPortabilityStoppedState $fixture
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($ssh.InstanceKnownHosts))
        [IO.File]::WriteAllText($ssh.InstanceKnownHosts, 'previous promoted host identity')
        [IO.File]::WriteAllText($ssh.AccessState, '{"oldAccess":true}')
        [IO.File]::WriteAllText($paths.FirmwareVariables, 'old mutable UEFI')
        $baseHash = Get-EzVmFileDigest -Path $fixture.Base.Image -Algorithm SHA256
        $observed = [pscustomobject]@{ JournalBeforeMove = $false }
        $state = $observed; $operation = $paths.Operation
        $mover = {
            param($source, $destination)
            if ($source.EndsWith('disk.qcow2')) {
                $journal = Read-EzVmJson -Path $operation -SchemaVersion 1
                $state.JournalBeforeMove = $journal.phase -ceq 'prepared' -and $journal.targetIntent.identityGeneration -cne $journal.originalIntent.identityGeneration
            }
            [IO.File]::Move($source, $destination)
        }.GetNewClosure()
        $reset = Reset-EzVmManagedInstance -Root $fixture.Root -InstanceName $fixture.Intent.name -QemuImgRunner $fixture.Runner -ProcessProvider { @() } -FileMover $mover
        $intent = Get-EzVmInstanceIntent -Root $fixture.Root -InstanceName $fixture.Intent.name
        Assert-EzVmTrue $observed.JournalBeforeMove
        Assert-EzVmEqual $reset.state 'CREATED'
        Assert-EzVmEqual $reset.resetBaseline 'imported'
        Assert-EzVmEqual $reset.sensitiveState $true
        Assert-EzVmEqual @($reset.recoveryArtifact).Count 0
        foreach ($field in @('name', 'baseId', 'profile', 'cpus', 'memoryMiB', 'sshPort', 'createdAt', 'provisioningProfile', 'provisioningVersion')) {
            Assert-EzVmEqual $intent.$field $fixture.Intent.$field
        }
        Assert-EzVmTrue ($intent.identityGeneration -cne $fixture.Intent.identityGeneration)
        foreach ($path in @($paths.Runtime, $paths.FirmwareVariables, $ssh.AccessState, $paths.Operation)) { Assert-EzVmEqual (Test-Path -LiteralPath $path) $false }
        Assert-EzVmEqual ([IO.File]::ReadAllText($ssh.InstanceKnownHosts)) 'previous promoted host identity'
        Assert-EzVmEqual (Get-EzVmSnapshotFixturePayload $paths.Disk).data ''
        Assert-EzVmEqual (Get-EzVmFileDigest -Path $fixture.Base.Image -Algorithm SHA256) $baseHash
        Assert-EzVmEqual (@(Get-ChildItem -LiteralPath $paths.Directory -Force | Where-Object { $_.Name -match '^\.(disk-backup|reset)-' }).Count) 0
    }
    finally { Remove-EzVmSnapshotFixture $fixture }
}

Add-EzVmTest -Name 'Portability: failed reset disk promotion restores source and retains a startup recovery barrier' -ScriptBlock {
    $fixture = New-EzVmSnapshotFixture
    try {
        $before = Get-EzVmFileDigest -Path $fixture.Disk -Algorithm SHA256
        $mover = {
            param($source, $destination)
            if ([IO.Path]::GetFileName($source).StartsWith('.disk-replacement-')) { throw 'injected replacement publication failure' }
            [IO.File]::Move($source, $destination)
        }
        Assert-EzVmThrows {
            Reset-EzVmManagedInstance -Root $fixture.Root -InstanceName $fixture.Intent.name -QemuImgRunner $fixture.Runner -ProcessProvider { @() } -FileMover $mover
        } -MessagePattern 'Startup is blocked.*injected replacement' | Out-Null
        Assert-EzVmEqual (Get-EzVmFileDigest -Path $fixture.Disk -Algorithm SHA256) $before
        Assert-EzVmEqual (Get-EzVmInstanceIntent -Root $fixture.Root -InstanceName $fixture.Intent.name).identityGeneration $fixture.Intent.identityGeneration
        Assert-EzVmEqual (Get-EzVmInstanceStatus -Root $fixture.Root -InstanceName $fixture.Intent.name -ProcessProvider { @() }).state 'UNKNOWN'
        $fixture.State.Calls.Clear()
        Assert-EzVmThrows { Start-EzVmInstance -Root $fixture.Root -InstanceName $fixture.Intent.name -QemuImgRunner $fixture.Runner -ProcessProvider { @() } } -MessagePattern 'cannot start.*UNKNOWN' | Out-Null
        Assert-EzVmEqual $fixture.State.Calls.Count 0
    }
    finally { Remove-EzVmSnapshotFixture $fixture }
}

Add-EzVmTest -Name 'Portability: interrupted reset metadata preserves original disk intent and archived state and refuses repeat mutations' -ScriptBlock {
    $fixture = New-EzVmSnapshotFixture
    try {
        $paths = Get-EzVmInstanceRuntimePaths -Root $fixture.Root -InstanceName $fixture.Intent.name
        $ssh = Get-EzVmSshPaths -Root $fixture.Root -InstanceName $fixture.Intent.name
        $null = Write-EzVmPortabilityStoppedState $fixture
        [IO.File]::WriteAllText($ssh.AccessState, 'old access evidence')
        $original = Get-EzVmFileDigest -Path $fixture.Disk -Algorithm SHA256
        $mover = {
            param($source, $destination)
            if ([IO.Path]::GetFileName($source) -ceq 'access.json') { throw 'injected metadata archive failure' }
            [IO.File]::Move($source, $destination)
        }
        Assert-EzVmThrows { Reset-EzVmManagedInstance -Root $fixture.Root -InstanceName $fixture.Intent.name -QemuImgRunner $fixture.Runner -ProcessProvider { @() } -FileMover $mover } -MessagePattern 'Startup is blocked.*injected metadata' | Out-Null
        $journal = Read-EzVmJson -Path $paths.Operation -SchemaVersion 1
        Assert-EzVmEqual $journal.phase 'disk-replaced'
        Assert-EzVmEqual $journal.originalIntent.identityGeneration $fixture.Intent.identityGeneration
        Assert-EzVmTrue ($journal.targetIntent.identityGeneration -cne $fixture.Intent.identityGeneration)
        Assert-EzVmEqual (Get-EzVmFileDigest -Path (Join-Path $paths.Directory $journal.originalDisk) -Algorithm SHA256) $original
        Assert-EzVmTrue (Test-Path -LiteralPath (Join-Path (Join-Path $paths.Directory $journal.archivedState) 'runtime.json'))
        $fixture.State.Calls.Clear()
        foreach ($operation in @(
            { Reset-EzVmManagedInstance -Root $fixture.Root -InstanceName $fixture.Intent.name -QemuImgRunner $fixture.Runner -ProcessProvider { @() } },
            { Copy-EzVmManagedInstance -Root $fixture.Root -SourceInstanceName $fixture.Intent.name -DestinationInstanceName 'recovery-clone' -Mode fresh -QemuImgRunner $fixture.Runner -ProcessProvider { @() } },
            { Export-EzVmManagedInstance -Root $fixture.Root -InstanceName $fixture.Intent.name -DestinationDirectory (Join-Path $fixture.Root 'recovery-export') -QemuImgRunner $fixture.Runner -ProcessProvider { @() } },
            { Test-EzVmPortableBundle -Root $fixture.Root -QemuImgRunner $fixture.Runner -ProcessProvider { @() } }
        )) { Assert-EzVmThrows $operation -MessagePattern 'lifecycle state is.*unknown' | Out-Null }
        Assert-EzVmEqual $fixture.State.Calls.Count 0
    }
    finally { Remove-EzVmSnapshotFixture $fixture }
}

Add-EzVmTest -Name 'Portability: schema1 intent reads preserve bytes and explicit reset upgrades identity once' -ScriptBlock {
    $fixture = New-EzVmSnapshotFixture
    try {
        $paths = Get-EzVmInstanceRuntimePaths -Root $fixture.Root -InstanceName $fixture.Intent.name
        $legacy = $fixture.Intent | Select-Object -Property * -ExcludeProperty identityGeneration
        $legacy.schemaVersion = 1
        Write-EzVmJson -Path $paths.Intent -Value $legacy -SchemaVersion 1
        $before = Get-EzVmFileDigest -Path $paths.Intent -Algorithm SHA256
        Assert-EzVmEqual (Get-EzVmInstanceIntent -Root $fixture.Root -InstanceName $fixture.Intent.name).schemaVersion 1
        Assert-EzVmEqual (Get-EzVmFileDigest -Path $paths.Intent -Algorithm SHA256) $before
        $reset = Reset-EzVmManagedInstance -Root $fixture.Root -InstanceName $fixture.Intent.name -QemuImgRunner $fixture.Runner -ProcessProvider { @() }
        Assert-EzVmTrue ($reset.identityGeneration -cmatch '^[a-f0-9]{32}$')
        $current = Get-EzVmInstanceIntent -Root $fixture.Root -InstanceName $fixture.Intent.name
        Assert-EzVmEqual $current.schemaVersion 2
        Assert-EzVmEqual $current.createdAt $legacy.createdAt
        Assert-EzVmEqual $current.identityGeneration $reset.identityGeneration
    }
    finally { Remove-EzVmSnapshotFixture $fixture }
}

Add-EzVmTest -Name 'Portability: running stale and ambiguous sources refuse all storage operations without changing source bytes' -ScriptBlock {
    foreach ($kind in @('running', 'stale', 'unknown')) {
        $fixture = New-EzVmRuntimeFixture
        try {
            $null = Start-EzVmRuntimeFixtureInstance $fixture
            $provider = $fixture.ProcessProvider
            if ($kind -ceq 'stale') { $fixture.State.Processes.Clear() }
            if ($kind -ceq 'unknown') { $provider = { throw 'process evidence unavailable' } }
            $before = Get-EzVmFileDigest -Path $fixture.Overlay -Algorithm SHA256
            $neverImage = { throw 'unexpected qemu-img invocation' }
            foreach ($operation in @(
                { Reset-EzVmManagedInstance -Root $fixture.Root -InstanceName $fixture.InstanceName -QemuImgRunner $neverImage -ProcessProvider $provider },
                { Copy-EzVmManagedInstance -Root $fixture.Root -SourceInstanceName $fixture.InstanceName -DestinationInstanceName 'fresh-refused' -Mode fresh -QemuImgRunner $neverImage -ProcessProvider $provider },
                { Copy-EzVmManagedInstance -Root $fixture.Root -SourceInstanceName $fixture.InstanceName -DestinationInstanceName 'stateful-refused' -Mode stateful -QemuImgRunner $neverImage -ProcessProvider $provider },
                { Export-EzVmManagedInstance -Root $fixture.Root -InstanceName $fixture.InstanceName -DestinationDirectory (Join-Path $fixture.Root 'refused-export') -QemuImgRunner $neverImage -ProcessProvider $provider }
            )) { Assert-EzVmThrows $operation -MessagePattern 'requires positively proven stopped' | Out-Null }
            Assert-EzVmEqual (Get-EzVmFileDigest -Path $fixture.Overlay -Algorithm SHA256) $before
        }
        finally { Remove-EzVmRuntimeFixture $fixture }
    }
}

Add-EzVmTest -Name 'Portability: external backing refuses every new public source operation before qemu-img traversal' -ScriptBlock {
    $fixture = New-EzVmSnapshotFixture
    try {
        Write-EzVmSnapshotFixtureImage -Path $fixture.Disk -Backing '../../outside.qcow2' -Data 'preserve me'
        $before = Get-EzVmFileDigest -Path $fixture.Disk -Algorithm SHA256
        foreach ($operation in @(
            { Reset-EzVmManagedInstance -Root $fixture.Root -InstanceName $fixture.Intent.name -QemuImgRunner $fixture.Runner -ProcessProvider { @() } },
            { Copy-EzVmManagedInstance -Root $fixture.Root -SourceInstanceName $fixture.Intent.name -DestinationInstanceName 'bad-fresh' -Mode fresh -QemuImgRunner $fixture.Runner -ProcessProvider { @() } },
            { Copy-EzVmManagedInstance -Root $fixture.Root -SourceInstanceName $fixture.Intent.name -DestinationInstanceName 'bad-stateful' -Mode stateful -QemuImgRunner $fixture.Runner -ProcessProvider { @() } },
            { Export-EzVmManagedInstance -Root $fixture.Root -InstanceName $fixture.Intent.name -DestinationDirectory (Join-Path $fixture.Root 'bad-export') -QemuImgRunner $fixture.Runner -QemuStatusProvider $fixture.QemuStatusProvider -ProcessProvider { @() } },
            { Test-EzVmPortableBundle -Root $fixture.Root -QemuImgRunner $fixture.Runner -ProcessProvider { @() } }
        )) { Assert-EzVmThrows $operation -MessagePattern 'does not exactly match' | Out-Null }
        Assert-EzVmEqual $fixture.State.Calls.Count 0
        Assert-EzVmEqual (Get-EzVmFileDigest -Path $fixture.Disk -Algorithm SHA256) $before
    }
    finally { Remove-EzVmSnapshotFixture $fixture }
}

Add-EzVmTest -Name 'Portability: public import consumes discovered export sidecar and preserves source on corrupt sidecar refusal' -ScriptBlock {
    $fixture = New-EzVmSnapshotFixture
    try {
        $export = Export-EzVmManagedInstance -Root $fixture.Root -InstanceName $fixture.Intent.name -DestinationDirectory (Join-Path $fixture.Root 'portable export') -QemuImgRunner $fixture.Runner -QemuStatusProvider $fixture.QemuStatusProvider -ProcessProvider { @() }
        $import = Import-EzVmManagedInstance -Root $fixture.Root -InstanceName 'import-destination' -ImagePath $export.Image -Profile light -QemuImgRunner $fixture.Runner -QemuStatusProvider $fixture.QemuStatusProvider -PortProbe { $true }
        $origin = Read-EzVmJson -Path (Get-EzVmInstanceRuntimePaths -Root $fixture.Root -InstanceName $import.name).Origin -SchemaVersion 1
        Assert-EzVmEqual $origin.operation 'import'
        Assert-EzVmEqual $origin.sourceInstance $null
        Assert-EzVmEqual $origin.snapshot.source.exportManifest.source.instance.name $fixture.Intent.name
        Assert-EzVmEqual $origin.snapshot.source.exportManifestSha256 (Get-EzVmFileDigest -Path $export.ManifestPath -Algorithm SHA256)
        Assert-EzVmEqual $import.sourceKind 'imported'
        Assert-EzVmTrue ($import.identityGeneration -cne $fixture.Intent.identityGeneration)
        $before = Get-EzVmFileDigest -Path $export.Image -Algorithm SHA256
        [IO.File]::WriteAllText($export.ManifestPath, '{"schemaVersion":1,"invalid":true}')
        $fixture.State.Calls.Clear()
        Assert-EzVmThrows { Import-EzVmManagedInstance -Root $fixture.Root -InstanceName 'corrupt-import' -ImagePath $export.Image -QemuImgRunner $fixture.Runner -QemuStatusProvider $fixture.QemuStatusProvider } -MessagePattern 'field' | Out-Null
        Assert-EzVmEqual $fixture.State.Calls.Count 0
        Assert-EzVmEqual (Get-EzVmFileDigest -Path $export.Image -Algorithm SHA256) $before
        Assert-EzVmEqual (Test-Path -LiteralPath (Get-EzVmInstanceRuntimePaths -Root $fixture.Root -InstanceName 'corrupt-import').Directory) $false
    }
    finally { Remove-EzVmSnapshotFixture $fixture }
}

Add-EzVmTest -Name 'Portability: duplicate destinations refuse before copy import or source inspection' -ScriptBlock {
    $fixture = New-EzVmSnapshotFixture
    try {
        $before = Get-EzVmFileDigest -Path $fixture.Disk -Algorithm SHA256
        $fixture.State.Calls.Clear()
        Assert-EzVmThrows { Copy-EzVmManagedInstance -Root $fixture.Root -SourceInstanceName 'missing-source' -DestinationInstanceName $fixture.Intent.name.ToUpperInvariant() -Mode stateful -QemuImgRunner $fixture.Runner } -MessagePattern 'already exists' | Out-Null
        Assert-EzVmThrows { Import-EzVmManagedInstance -Root $fixture.Root -InstanceName $fixture.Intent.name -ImagePath 'does-not-exist.qcow2' -QemuImgRunner $fixture.Runner } -MessagePattern 'already exists' | Out-Null
        Assert-EzVmEqual $fixture.State.Calls.Count 0
        Assert-EzVmEqual (Get-EzVmFileDigest -Path $fixture.Disk -Algorithm SHA256) $before
    }
    finally { Remove-EzVmSnapshotFixture $fixture }
}

Add-EzVmTest -Name 'Portability: sensitive snapshots never become the implicit prepared baseline' -ScriptBlock {
    $fixture = New-EzVmSnapshotFixture
    try {
        Assert-EzVmThrows { New-EzVmManagedInstance -Root $fixture.Root -InstanceName 'implicit-sensitive' -QemuImgRunner $fixture.Runner -PortProbe { $true } } -MessagePattern 'No published prepared base' | Out-Null
        $explicit = New-EzVmManagedInstance -Root $fixture.Root -InstanceName 'explicit-sensitive' -BaseId $fixture.Base.BaseId -QemuImgRunner $fixture.Runner -PortProbe { $true }
        Assert-EzVmEqual $explicit.baseId $fixture.Base.BaseId
        Assert-EzVmEqual $explicit.baseSelection 'explicit'
    }
    finally { Remove-EzVmSnapshotFixture $fixture }
}

Add-EzVmTest -Name 'Portability: complete cold root relocation retains intent relative backing stopped history and scoped keys' -ScriptBlock {
    $fixture = New-EzVmSnapshotFixture
    $moved = New-EzVmTestDirectory -Prefix 'relocated complete root'
    try {
        $null = Write-EzVmPortabilityStoppedState $fixture
        $ssh = Get-EzVmSshPaths -Root $fixture.Root -InstanceName $fixture.Intent.name
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($ssh.InstanceKnownHosts))
        [IO.File]::WriteAllText($ssh.InstanceKnownHosts, 'complete root scoped trust')
        $before = Test-EzVmPortableBundle -Root $fixture.Root -QemuImgRunner $fixture.Runner -ProcessProvider { @() }
        Assert-EzVmEqual $before.Valid $true
        foreach ($entry in @(Get-ChildItem -LiteralPath $fixture.Root -Force)) { Copy-Item -LiteralPath $entry.FullName -Destination $moved -Recurse -Force }
        $after = Test-EzVmPortableBundle -Root $moved -QemuImgRunner $fixture.Runner -ProcessProvider { @() }
        Assert-EzVmEqual $after.InstanceCount 1
        Assert-EzVmEqual $after.Instances[0].state 'STOPPED'
        Assert-EzVmEqual $after.Instances[0].chainDepth 1
        $originalPaths = Get-EzVmInstanceRuntimePaths -Root $fixture.Root -InstanceName $fixture.Intent.name
        $movedPaths = Get-EzVmInstanceRuntimePaths -Root $moved -InstanceName $fixture.Intent.name
        Assert-EzVmEqual (Get-EzVmFileDigest -Path $movedPaths.Intent -Algorithm SHA256) (Get-EzVmFileDigest -Path $originalPaths.Intent -Algorithm SHA256)
        Assert-EzVmEqual (Get-EzVmFileDigest -Path $movedPaths.Runtime -Algorithm SHA256) (Get-EzVmFileDigest -Path $originalPaths.Runtime -Algorithm SHA256)
        $chain = Test-EzVmInstanceStorage -Root $moved -InstanceName $fixture.Intent.name -BaseId $fixture.Intent.baseId -QemuImgRunner $fixture.Runner
        Assert-EzVmTrue ($chain.ResolvedBackingPath.StartsWith($moved, [StringComparison]::Ordinal))
        Assert-EzVmEqual (Get-EzVmSnapshotFixturePayload $movedPaths.Disk).backing (Get-EzVmSnapshotFixturePayload $originalPaths.Disk).backing
        Assert-EzVmEqual ([IO.File]::ReadAllText((Get-EzVmSshPaths -Root $moved -InstanceName $fixture.Intent.name).InstanceKnownHosts)) 'complete root scoped trust'
    }
    finally { Remove-EzVmSnapshotFixture $fixture; Remove-EzVmTestDirectory -Path $moved }
}

Add-EzVmTest -Name 'Portability: cold bundle refuses an active base builder and unreadable QEMU ownership' -ScriptBlock {
    $fixture = New-EzVmSnapshotFixture
    try {
        foreach ($executable in @((Join-Path $fixture.Paths.Qemu 'qemu-system-x86_64.exe'), '')) {
            $process = [pscustomobject]@{ Pid = 40999; ExecutablePath = $executable; Arguments = @('-name', 'ezvm-base-builder'); StartTimeUtc = [DateTime]::UtcNow.ToString('o') }
            $provider = { @($process) }.GetNewClosure()
            Assert-EzVmThrows { Test-EzVmPortableBundle -Root $fixture.Root -QemuImgRunner $fixture.Runner -ProcessProvider $provider } -MessagePattern 'requires every managed QEMU|ownership is unavailable' | Out-Null
        }
        Assert-EzVmEqual $fixture.State.Calls.Count 0
    }
    finally { Remove-EzVmSnapshotFixture $fixture }
}

Add-EzVmTest -Name 'Portability: stale seed intent cannot launch after reset changed generation' -ScriptBlock {
    $fixture = New-EzVmRuntimeFixture
    try {
        $expected = Get-EzVmInstanceIntent -Root $fixture.Root -InstanceName $fixture.InstanceName
        $current = Get-EzVmInstanceIntent -Root $fixture.Root -InstanceName $fixture.InstanceName
        $current.identityGeneration = [Guid]::NewGuid().ToString('N')
        Write-EzVmJson -Path (Get-EzVmInstanceRuntimePaths -Root $fixture.Root -InstanceName $fixture.InstanceName).Intent -Value $current -SchemaVersion 2
        Assert-EzVmThrows { Start-EzVmInstance -Root $fixture.Root -InstanceName $fixture.InstanceName -ExpectedIntent $expected -QemuImgRunner $fixture.StorageRunner -QemuStatusProvider $fixture.QemuStatusProvider -ProcessProvider $fixture.ProcessProvider -ProcessLauncher $fixture.ProcessLauncher -QmpInvoker $fixture.QmpInvoker } -MessagePattern 'intent changed while preparing' | Out-Null
        Assert-EzVmEqual $fixture.State.LaunchCount 0
    }
    finally { Remove-EzVmRuntimeFixture $fixture }
}

Add-EzVmTest -Name 'Portability: relocated metadata cannot hide original-root active stale or unrecorded owners' -ScriptBlock {
    $fixture = New-EzVmRuntimeFixture
    $moved = New-EzVmTestDirectory -Prefix 'relocated ownership'
    try {
        $null = Start-EzVmRuntimeFixtureInstance $fixture
        $owner = $fixture.State.Processes[0]
        foreach ($entry in @(Get-ChildItem -LiteralPath $fixture.Root -Force)) { Copy-Item -LiteralPath $entry.FullName -Destination $moved -Recurse -Force }
        $movedPaths = Get-EzVmInstanceRuntimePaths -Root $moved -InstanceName $fixture.InstanceName
        foreach ($state in @('RUNNING', 'STALE', 'UNKNOWN')) {
            if ($state -ceq 'STALE') { $fixture.State.Processes.Clear() }
            if ($state -ceq 'UNKNOWN') {
                $fixture.State.Processes.Add($owner)
                $runtime = Read-EzVmJson -Path $movedPaths.Runtime -SchemaVersion 1
                $runtime.state = 'STOPPED'; $runtime.stoppedAt = [DateTime]::UtcNow.ToString('o')
                Write-EzVmJson -Path $movedPaths.Runtime -Value $runtime -SchemaVersion 1
            }
            Assert-EzVmEqual (Get-EzVmInstanceStatus -Root $moved -InstanceName $fixture.InstanceName -ProcessProvider $fixture.ProcessProvider).state $state
            $neverImage = { throw 'unexpected qemu-img traversal of owned storage' }
            Assert-EzVmThrows { Test-EzVmPortableBundle -Root $moved -QemuImgRunner $neverImage -ProcessProvider $fixture.ProcessProvider } -MessagePattern 'requires positively proven stopped' | Out-Null
            Assert-EzVmThrows { Reset-EzVmManagedInstance -Root $moved -InstanceName $fixture.InstanceName -QemuImgRunner $neverImage -ProcessProvider $fixture.ProcessProvider } -MessagePattern 'requires positively proven stopped' | Out-Null
        }
    }
    finally { Remove-EzVmRuntimeFixture $fixture; Remove-EzVmTestDirectory -Path $moved }
}

Add-EzVmTest -Name 'Portability: lifecycle guards reject coerced schema and redirected lock directories before any outside write' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'portability lock guard'
    $outside = New-EzVmTestDirectory -Prefix 'portability outside'
    $link = $null
    try {
        $module = Get-Module EzVm
        foreach ($schema in @('1', $true, 1.0)) {
            $guard = [pscustomobject]@{ schemaVersion = $schema; state = 'proven-safe'; source = 'invalid typed schema' }
            Assert-EzVmThrows { & $module { param($g) Assert-EzVmStorageLifecycleGuard -LifecycleGuard $g -Operation 'test mutation' } $guard } -MessagePattern 'unsupported lifecycle-guard schema' | Out-Null
        }
        $paths = Get-EzVmPaths -Root $root
        [void][IO.Directory]::CreateDirectory($paths.Runtime)
        $link = $paths.Locks
        $linkType = if ($script:EzVmIsWindowsHost) { 'Junction' } else { 'SymbolicLink' }
        $null = New-Item -ItemType $linkType -Path $link -Target $outside -ErrorAction Stop
        foreach ($function in @('Enter-EzVmInstanceLifecycleLock', 'Enter-EzVmQmpAllocationLock')) {
            Assert-EzVmThrows { & $module { param($r, $f) if ($f -ceq 'Enter-EzVmInstanceLifecycleLock') { $lock = & $f -Root $r -InstanceName 'safe-name' } else { $lock = & $f -Root $r }; $lock.Dispose() } $root $function } -MessagePattern 'reparse point' | Out-Null
        }
        Assert-EzVmEqual (@(Get-ChildItem -LiteralPath $outside -Force).Count) 0
    }
    finally {
        if ($null -ne $link -and (Test-Path -LiteralPath $link)) { [IO.Directory]::Delete($link) }
        Remove-EzVmTestDirectory -Path $root
        Remove-EzVmTestDirectory -Path $outside
    }
}
