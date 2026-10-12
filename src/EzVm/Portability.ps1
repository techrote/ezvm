function Assert-EzVmInstanceOrigin {
    param([object]$Origin, [string]$ExpectedBaseId)
    Assert-EzVmRuntimeFields -Value $Origin -Expected @(
        'schemaVersion', 'operation', 'baseId', 'createdAt', 'sourceInstance', 'snapshot', 'sensitiveState'
    ) -Description 'Instance origin'
    Assert-EzVmRuntimeInteger -Value $Origin.schemaVersion -Description 'Instance origin schemaVersion' -Minimum 1 -Maximum 1
    if (@('fresh-clone', 'stateful-clone', 'import') -cnotcontains [string]$Origin.operation) { throw 'Instance origin operation is unsupported.' }
    if ($Origin.baseId -isnot [string] -or $Origin.baseId -cne $ExpectedBaseId) { throw 'Instance origin disagrees with the destination base identity.' }
    Assert-EzVmRuntimeTimestamp -Value $Origin.createdAt -Description 'Instance origin createdAt'
    if ($Origin.sensitiveState -isnot [bool]) { throw 'Instance origin sensitiveState must be a boolean.' }
    if ($Origin.operation -ceq 'import') {
        if ($null -ne $Origin.sourceInstance) { throw 'An imported origin must obtain source identity from its validated export provenance.' }
    }
    else {
        if ($null -eq $Origin.sourceInstance) { throw 'A cloned origin requires the source instance intent.' }
        Assert-EzVmInstanceIntent -Intent $Origin.sourceInstance -ExpectedName ([string]$Origin.sourceInstance.name)
    }
    if ($Origin.operation -ceq 'fresh-clone') {
        if ($null -ne $Origin.snapshot) { throw 'A fresh clone must not claim a newly captured stateful snapshot.' }
        if ($Origin.sourceInstance.baseId -cne $ExpectedBaseId) { throw 'Fresh clone must retain its source immutable baseline.' }
    }
    else {
        Assert-EzVmSnapshotBaseManifest -Manifest $Origin.snapshot
        if ($Origin.snapshot.baseId -cne $ExpectedBaseId -or -not $Origin.sensitiveState) { throw 'Snapshot origin must bind its sensitive baseline.' }
        $kind = if ($Origin.operation -ceq 'import') { 'imported' } else { 'derived' }
        if ($Origin.snapshot.kind -cne $kind) { throw 'Snapshot origin kind disagrees with the lifecycle operation.' }
        if ($kind -ceq 'derived' -and
            ($Origin.sourceInstance | ConvertTo-Json -Depth 8 -Compress) -cne ($Origin.snapshot.source.instance | ConvertTo-Json -Depth 8 -Compress)) {
            throw 'Stateful clone source intent disagrees with its snapshot provenance.'
        }
    }
}

function Get-EzVmInstanceOrigin {
    param([string]$Root, [object]$Intent)
    $paths = Get-EzVmPaths -Root $Root
    $runtime = Get-EzVmInstanceRuntimePaths -Root $Root -InstanceName $Intent.name
    if (-not (Test-Path -LiteralPath $runtime.Origin)) { return $null }
    $null = Assert-EzVmStorageManagedPath -Path $runtime.Origin -ContainmentRoot $runtime.Directory -SafetyRoot $paths.Root -Description 'Instance origin' -RequireFile
    if ((Get-Item -LiteralPath $runtime.Origin -Force).Length -gt 131072) { throw 'Instance origin exceeds the supported 128-KiB bound.' }
    $origin = Read-EzVmJson -Path $runtime.Origin -SchemaVersion 1
    Assert-EzVmInstanceOrigin -Origin $origin -ExpectedBaseId $Intent.baseId
    return $origin
}

function New-EzVmInstanceOrigin {
    param([string]$Operation, [string]$BaseId, [AllowNull()][object]$SourceInstance,
        [AllowNull()][object]$Snapshot, [bool]$SensitiveState)
    $origin = [pscustomobject][ordered]@{
        schemaVersion = 1; operation = $Operation; baseId = $BaseId
        createdAt = [DateTime]::UtcNow.ToString('o')
        sourceInstance = $SourceInstance; snapshot = $Snapshot; sensitiveState = $SensitiveState
    }
    Assert-EzVmInstanceOrigin -Origin $origin -ExpectedBaseId $BaseId
    return $origin
}

function Assert-EzVmPortabilityDestination {
    param([string]$Root, [string]$InstanceName)
    Assert-EzVmStorageInstanceName -Name $InstanceName
    $paths = Get-EzVmPaths -Root $Root
    $destination = Get-EzVmInstanceRuntimePaths -Root $Root -InstanceName $InstanceName
    $null = Assert-EzVmStorageManagedPath -Path $destination.Directory -ContainmentRoot $paths.Instances -SafetyRoot $paths.Root -Description 'Destination instance'
    $lock = Enter-EzVmSshAllocationLock -Root $Root
    try {
        foreach ($intent in @(Get-EzVmInstanceRegistry -Root $Root)) {
            if ([string]::Equals($intent.name, $InstanceName, [StringComparison]::OrdinalIgnoreCase)) { throw "Destination instance '$InstanceName' already exists. Choose a new name; portability never replaces an existing instance." }
        }
        if (Test-Path -LiteralPath $destination.Directory) { throw "Destination directory '$($destination.Directory)' already exists. Reconcile it before retrying." }
    }
    finally { $lock.Dispose() }
}

function Reset-EzVmManagedInstance {
    [CmdletBinding()]
    param([string]$Root = $script:EzVmDefaultRoot,
        [Parameter(Mandatory = $true)][string]$InstanceName,
        [scriptblock]$QemuImgRunner, [scriptblock]$ProcessProvider, [scriptblock]$FileMover)

    $lock = Enter-EzVmInstanceLifecycleLock -Root $Root -InstanceName $InstanceName
    $journalWritten = $false
    try {
        $paths = Get-EzVmPaths -Root $Root
        $runtime = Get-EzVmInstanceRuntimePaths -Root $Root -InstanceName $InstanceName
        $ssh = Get-EzVmSshPaths -Root $Root -InstanceName $InstanceName
        $intent = Get-EzVmInstanceIntent -Root $Root -InstanceName $InstanceName
        $null = Get-EzVmCodingProfile -Root $Root -Name $intent.provisioningProfile -Version $intent.provisioningVersion
        $guard = Get-EzVmInstanceStorageLifecycleGuard -Root $Root -InstanceName $InstanceName -ProcessProvider $ProcessProvider
        Assert-EzVmStorageLifecycleGuard -LifecycleGuard $guard -Operation 'Instance reset'
        $null = Get-EzVmInstanceOrigin -Root $Root -Intent $intent
        Assert-EzVmSnapshotSourceHeaders -Root $Root -SourceIntent $intent
        $base = Test-EzVmPreparedBase -Root $Root -BaseId $intent.baseId -QemuImgRunner $QemuImgRunner
        $null = Test-EzVmInstanceStorage -Root $Root -InstanceName $InstanceName -BaseId $intent.baseId -QemuImgRunner $QemuImgRunner
        $operationId = [Guid]::NewGuid().ToString('N')
        $backupName = '.disk-backup-' + $operationId + '.qcow2'
        $backup = Join-Path $runtime.Directory $backupName
        $archiveName = '.reset-' + $operationId
        $archive = Join-Path $runtime.Directory $archiveName
        # Retain previously promoted SSH trust until a complete new READY proof
        # replaces it. Removing access.json prevents that old trust authorizing
        # access to a partly initialized reset guest.
        $files = @($runtime.Runtime, $runtime.FirmwareVariables, $ssh.AccessState)
        foreach ($path in @($files) + @($runtime.Operation, $archive, $backup)) {
            $null = Assert-EzVmStorageManagedPath -Path $path -ContainmentRoot $paths.Runtime -SafetyRoot $paths.Root -Description 'Reset state path'
            if ((Test-Path -LiteralPath $path) -and -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Reset expected a regular file at '$path'." }
        }
        $targetFields = [ordered]@{}
        foreach ($property in $intent.PSObject.Properties) { $targetFields[$property.Name] = $property.Value }
        $targetFields['schemaVersion'] = 2
        $targetFields['identityGeneration'] = [Guid]::NewGuid().ToString('N')
        $target = [pscustomobject]$targetFields
        Assert-EzVmInstanceIntent -Intent $target -ExpectedName $InstanceName
        $journal = [pscustomobject][ordered]@{
            schemaVersion = 1; operation = 'reset'; operationId = $operationId; instanceName = $InstanceName
            phase = 'prepared'; createdAt = [DateTime]::UtcNow.ToString('o')
            originalIntent = $intent; targetIntent = $target; originalDisk = $backupName; archivedState = $archiveName
        }
        Write-EzVmJson -Path $runtime.Operation -Value $journal -SchemaVersion 1
        $journalWritten = $true
        # The journal exists before the first disk rename. A crash at any later
        # point cannot make a partly reset instance look safe to start.
        $null = Reset-EzVmInstanceOverlayStorage -Root $Root -InstanceName $InstanceName -BaseId $intent.baseId -LifecycleGuard $guard -QemuImgRunner $QemuImgRunner -FileMover $FileMover -PreserveBackup -RecoveryPath $backup
        $journal.phase = 'disk-replaced'
        Write-EzVmJson -Path $runtime.Operation -Value $journal -SchemaVersion 1
        [void][IO.Directory]::CreateDirectory($archive)
        foreach ($path in $files) {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $null = Assert-EzVmStorageManagedPath -Path $path -ContainmentRoot $paths.Runtime -SafetyRoot $paths.Root -Description 'Reset stale state' -RequireFile
                Move-EzVmStorageFile -Source $path -Destination (Join-Path $archive ([IO.Path]::GetFileName($path))) -Mover $FileMover
            }
        }
        Write-EzVmJson -Path $runtime.Intent -Value $target -SchemaVersion 2
        $journal.phase = 'metadata-replaced'
        Write-EzVmJson -Path $runtime.Operation -Value $journal -SchemaVersion 1
        # Commit the reset before best-effort deletion of now-unneeded recovery
        # material. A cleanup problem remains visible in the returned result.
        Remove-Item -LiteralPath $runtime.Operation -Force -ErrorAction Stop
        $journalWritten = $false
        $artifacts = New-Object 'System.Collections.Generic.List[string]'
        try { Remove-Item -LiteralPath $backup -Force -ErrorAction Stop } catch { $artifacts.Add($backup) }
        try {
            foreach ($file in @(Get-ChildItem -LiteralPath $archive -File -Force -ErrorAction Stop)) {
                $null = Assert-EzVmStorageManagedPath -Path $file.FullName -ContainmentRoot $archive -SafetyRoot $paths.Root -Description 'Reset archived state' -RequireFile
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            }
            [IO.Directory]::Delete($archive, $false)
        }
        catch { $artifacts.Add($archive) }
        return [pscustomobject][ordered]@{
            name = $InstanceName; state = 'CREATED'; baseId = [string]$intent.baseId
            identityGeneration = [string]$target.identityGeneration
            resetBaseline = $(if ($base.Manifest.schemaVersion -eq 2) { [string]$base.Manifest.kind } else { 'prepared' })
            sensitiveState = ($base.Manifest.schemaVersion -eq 2)
            recoveryArtifact = [string[]]$artifacts.ToArray()
        }
    }
    catch {
        if ($journalWritten) {
            throw [InvalidOperationException]::new("Reset did not finish. Startup is blocked by '$($runtime.Operation)'. Preserve the journal, original intent, '$backup', and '$archive' for explicit recovery; do not delete evidence or retry disk replacement blindly. $($_.Exception.Message)", $_.Exception)
        }
        throw
    }
    finally { $lock.Dispose() }
}

function Copy-EzVmManagedInstance {
    [CmdletBinding()]
    param([string]$Root = $script:EzVmDefaultRoot,
        [Parameter(Mandatory = $true)][string]$SourceInstanceName,
        [Parameter(Mandatory = $true)][string]$DestinationInstanceName,
        [Parameter(Mandatory = $true)][ValidateSet('fresh', 'stateful')][string]$Mode,
        [scriptblock]$QemuImgRunner, [scriptblock]$QemuStatusProvider, [scriptblock]$ProcessProvider, [scriptblock]$PortProbe)

    $Mode = $Mode.ToLowerInvariant()
    Assert-EzVmStorageInstanceName -Name $SourceInstanceName
    Assert-EzVmPortabilityDestination -Root $Root -InstanceName $DestinationInstanceName
    $lock = Enter-EzVmInstanceLifecycleLock -Root $Root -InstanceName $SourceInstanceName
    try {
        $intent = Get-EzVmInstanceIntent -Root $Root -InstanceName $SourceInstanceName
        $null = Get-EzVmCodingProfile -Root $Root -Name $intent.provisioningProfile -Version $intent.provisioningVersion
        $guard = Get-EzVmInstanceStorageLifecycleGuard -Root $Root -InstanceName $SourceInstanceName -ProcessProvider $ProcessProvider
        Assert-EzVmStorageLifecycleGuard -LifecycleGuard $guard -Operation 'Instance clone'
        $null = Get-EzVmInstanceOrigin -Root $Root -Intent $intent
        Assert-EzVmSnapshotSourceHeaders -Root $Root -SourceIntent $intent
        $sourceBase = Test-EzVmPreparedBase -Root $Root -BaseId $intent.baseId -QemuImgRunner $QemuImgRunner
        $null = Test-EzVmInstanceStorage -Root $Root -InstanceName $SourceInstanceName -BaseId $intent.baseId -QemuImgRunner $QemuImgRunner
        if ($Mode -ceq 'stateful') {
            $base = New-EzVmDerivedBase -Root $Root -SourceIntent $intent -LifecycleGuard $guard -QemuImgRunner $QemuImgRunner -QemuStatusProvider $QemuStatusProvider
            $origin = New-EzVmInstanceOrigin -Operation 'stateful-clone' -BaseId $base.BaseId -SourceInstance $intent -Snapshot $base.OperationProvenance -SensitiveState $true
        }
        else {
            $base = $sourceBase
            $origin = New-EzVmInstanceOrigin -Operation 'fresh-clone' -BaseId $base.BaseId -SourceInstance $intent -Snapshot $null -SensitiveState ($base.Manifest.schemaVersion -eq 2)
        }
    }
    finally { $lock.Dispose() }
    # Snapshot is immutable now. Release source lock before allocation to keep
    # allocation -> instance as the single lock ordering used by create/start.
    $created = New-EzVmManagedInstance -Root $Root -InstanceName $DestinationInstanceName -BaseId $base.BaseId -Profile $intent.profile -Cpus $intent.cpus -MemoryMiB $intent.memoryMiB -Origin $origin -QemuImgRunner $QemuImgRunner -PortProbe $PortProbe
    $created | Add-Member -NotePropertyName mode -NotePropertyValue $Mode
    $created | Add-Member -NotePropertyName sourceName -NotePropertyValue $SourceInstanceName
    $created | Add-Member -NotePropertyName sensitiveState -NotePropertyValue $origin.sensitiveState
    return $created
}

function Export-EzVmManagedInstance {
    [CmdletBinding()]
    param([string]$Root = $script:EzVmDefaultRoot,
        [Parameter(Mandatory = $true)][string]$InstanceName,
        [Parameter(Mandatory = $true)][string]$DestinationDirectory,
        [scriptblock]$QemuImgRunner, [scriptblock]$QemuStatusProvider, [scriptblock]$ProcessProvider)
    $lock = Enter-EzVmInstanceLifecycleLock -Root $Root -InstanceName $InstanceName
    try {
        $intent = Get-EzVmInstanceIntent -Root $Root -InstanceName $InstanceName
        $guard = Get-EzVmInstanceStorageLifecycleGuard -Root $Root -InstanceName $InstanceName -ProcessProvider $ProcessProvider
        Assert-EzVmStorageLifecycleGuard -LifecycleGuard $guard -Operation 'Instance export'
        $null = Get-EzVmInstanceOrigin -Root $Root -Intent $intent
        return Export-EzVmInstanceStorage -Root $Root -SourceIntent $intent -LifecycleGuard $guard -DestinationDirectory $DestinationDirectory -QemuImgRunner $QemuImgRunner -QemuStatusProvider $QemuStatusProvider
    }
    finally { $lock.Dispose() }
}

function Import-EzVmManagedInstance {
    [CmdletBinding()]
    param([string]$Root = $script:EzVmDefaultRoot,
        [Parameter(Mandatory = $true)][string]$InstanceName,
        [Parameter(Mandatory = $true)][string]$ImagePath,
        [AllowEmptyString()][string]$ManifestPath = '',
        [AllowEmptyString()][string]$Profile = '',
        [AllowNull()][Nullable[int]]$Cpus = $null,
        [AllowNull()][Nullable[int]]$MemoryMiB = $null,
        [scriptblock]$QemuImgRunner, [scriptblock]$QemuStatusProvider, [scriptblock]$PortProbe)
    Assert-EzVmPortabilityDestination -Root $Root -InstanceName $InstanceName
    $null = Resolve-EzVmInstanceResources -Root $Root -Profile $Profile -Cpus $Cpus -MemoryMiB $MemoryMiB
    if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
        $sidecar = Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ImagePath))) 'manifest.json'
        if (Test-Path -LiteralPath $sidecar) { $ManifestPath = $sidecar }
    }
    $base = Import-EzVmStandaloneBase -Root $Root -ImagePath $ImagePath -ManifestPath $ManifestPath -QemuImgRunner $QemuImgRunner -QemuStatusProvider $QemuStatusProvider
    $origin = New-EzVmInstanceOrigin -Operation 'import' -BaseId $base.BaseId -SourceInstance $null -Snapshot $base.OperationProvenance -SensitiveState $true
    $created = New-EzVmManagedInstance -Root $Root -InstanceName $InstanceName -BaseId $base.BaseId -Profile $Profile -Cpus $Cpus -MemoryMiB $MemoryMiB -Origin $origin -QemuImgRunner $QemuImgRunner -PortProbe $PortProbe
    $created | Add-Member -NotePropertyName sourceKind -NotePropertyValue 'imported'
    $created | Add-Member -NotePropertyName sensitiveState -NotePropertyValue $true
    return $created
}

function Test-EzVmPortableBundle {
    [CmdletBinding()]
    param([string]$Root = $script:EzVmDefaultRoot, [scriptblock]$QemuImgRunner, [scriptblock]$ProcessProvider)
    $paths = Get-EzVmPaths -Root $Root
    $allocation = Enter-EzVmSshAllocationLock -Root $Root
    $locks = New-Object 'System.Collections.Generic.List[object]'
    try {
        $intents = @(Get-EzVmInstanceRegistry -Root $Root | Sort-Object name)
        foreach ($intent in $intents) { $locks.Add((Enter-EzVmInstanceLifecycleLock -Root $Root -InstanceName $intent.name)) }
        # Includes base-build QEMU guests, which do not have ordinary instance
        # metadata but still make a complete-root copy unsafe.
        foreach ($process in @(Get-EzVmObservedQemuProcesses -ProcessProvider $ProcessProvider)) {
            if ([string]::IsNullOrWhiteSpace([string]$process.ExecutablePath)) { throw 'Cannot prove a cold bundle while QEMU executable ownership is unavailable.' }
            if (Test-EzVmStoragePathInside -Path $process.ExecutablePath -Directory $paths.Qemu) { throw 'Cold portability requires every managed QEMU guest, including base builders, to be stopped.' }
        }
        $items = New-Object 'System.Collections.Generic.List[object]'
        foreach ($intent in $intents) {
            $guard = Get-EzVmInstanceStorageLifecycleGuard -Root $Root -InstanceName $intent.name -ProcessProvider $ProcessProvider
            Assert-EzVmStorageLifecycleGuard -LifecycleGuard $guard -Operation 'Cold portability validation'
            $null = Get-EzVmInstanceOrigin -Root $Root -Intent $intent
            Assert-EzVmSnapshotSourceHeaders -Root $Root -SourceIntent $intent
            $storage = Test-EzVmInstanceStorage -Root $Root -InstanceName $intent.name -BaseId $intent.baseId -QemuImgRunner $QemuImgRunner
            $status = Get-EzVmInstanceStatus -Root $Root -InstanceName $intent.name -ProcessProvider $ProcessProvider
            $items.Add([pscustomobject][ordered]@{ name = [string]$intent.name; baseId = [string]$intent.baseId; state = [string]$status.state; chainDepth = [int]$storage.ChainDepth })
        }
        return [pscustomobject][ordered]@{ Valid = $true; Root = $paths.Root; InstanceCount = $items.Count; Instances = @($items.ToArray()) }
    }
    finally {
        for ($index = $locks.Count - 1; $index -ge 0; $index--) { $locks[$index].Dispose() }
        $allocation.Dispose()
    }
}
