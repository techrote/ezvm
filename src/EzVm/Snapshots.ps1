function Get-EzVmQcow2HeaderInteger {
    param([byte[]]$Bytes, [int]$Offset, [int]$Length, [string]$Description)
    if ($Offset -lt 0 -or $Length -lt 1 -or $Offset + $Length -gt $Bytes.Length) {
        throw "QCOW2 header is truncated at $Description."
    }
    # All accepted lengths/offsets fit signed Int64. Reject rather than round
    # oversized on-disk uint64 values through PowerShell's numeric conversion.
    if ($Length -eq 8 -and $Bytes[$Offset] -ge 128) {
        throw "QCOW2 $Description exceeds the supported integer range."
    }
    [long]$value = 0
    for ($index = 0; $index -lt $Length; $index++) {
        $value = ($value -shl 8) -bor [long]$Bytes[$Offset + $index]
    }
    return $value
}

function Read-EzVmQcow2Header {
    param([IO.Stream]$Stream, [AllowEmptyString()][string]$ExpectedBacking = '')

    # Inspect only the bounded first cluster, before qemu-img can follow any
    # filename supplied by an imported image. This is a format preflight, not a
    # replacement for qemu-img's later full structural/integrity check.
    if (-not $Stream.CanSeek -or $Stream.Length -lt 72) { throw 'QCOW2 header is truncated.' }
    $Stream.Position = 0
    $prefix = New-Object byte[] 104
    # Select Int64 before bounding the file length; an Int32 first operand
    # makes PowerShell narrow even a multi-GiB stream before Min can run.
    $prefixLength = [int][Math]::Min([long]$prefix.Length, [long]$Stream.Length)
    $read = 0
    while ($read -lt $prefixLength) {
        $count = $Stream.Read($prefix, $read, $prefixLength - $read)
        if ($count -eq 0) { throw 'QCOW2 header read ended unexpectedly.' }
        $read += $count
    }
    if ($prefix[0] -ne 0x51 -or $prefix[1] -ne 0x46 -or $prefix[2] -ne 0x49 -or $prefix[3] -ne 0xfb) {
        throw 'Image does not contain the QCOW2 magic header; filename extensions are not trusted.'
    }
    $version = Get-EzVmQcow2HeaderInteger $prefix 4 4 'version'
    if (@(2, 3) -notcontains $version) { throw "Unsupported QCOW2 header version '$version'." }
    $clusterBits = Get-EzVmQcow2HeaderInteger $prefix 20 4 'cluster bits'
    if ($clusterBits -lt 9 -or $clusterBits -gt 21) { throw 'QCOW2 cluster size is outside the supported 512-byte through 2-MiB range.' }
    $clusterSize = [int](1 -shl [int]$clusterBits)
    if ($Stream.Length -lt $clusterSize) { throw 'QCOW2 first cluster is truncated.' }
    $header = New-Object byte[] $clusterSize
    $Stream.Position = 0
    $read = 0
    while ($read -lt $header.Length) {
        $count = $Stream.Read($header, $read, $header.Length - $read)
        if ($count -eq 0) { throw 'QCOW2 first-cluster read ended unexpectedly.' }
        $read += $count
    }
    $virtualSize = Get-EzVmQcow2HeaderInteger $header 24 8 'virtual size'
    if ($virtualSize -le 0) { throw 'QCOW2 virtual size must be positive.' }
    if ((Get-EzVmQcow2HeaderInteger $header 32 4 'encryption method') -ne 0) {
        throw 'Encrypted QCOW2 images are unsupported; supply an unencrypted standalone export.'
    }
    if ((Get-EzVmQcow2HeaderInteger $header 60 4 'internal snapshot count') -ne 0 -or
        (Get-EzVmQcow2HeaderInteger $header 64 8 'internal snapshot offset') -ne 0) {
        throw 'QCOW2 internal snapshots are unsupported; export the intended stopped disk state to a standalone image.'
    }
    $headerLength = 72
    if ($version -eq 3) {
        if ($prefixLength -lt 104) { throw 'QCOW2 version 3 header is truncated.' }
        $incompatible = Get-EzVmQcow2HeaderInteger $header 72 8 'incompatible features'
        if ($incompatible -ne 0) {
            throw 'QCOW2 dirty, corrupt, external-data or unsupported incompatible features are refused before opening the image with QEMU.'
        }
        $compatible = Get-EzVmQcow2HeaderInteger $header 80 8 'compatible features'
        if ($compatible -ne 0 -and $compatible -ne 1) { throw 'QCOW2 image uses unsupported compatible features.' }
        if ((Get-EzVmQcow2HeaderInteger $header 88 8 'auto-clear features') -ne 0) {
            throw 'QCOW2 external-data, bitmap or unsupported auto-clear features are refused.'
        }
        if ((Get-EzVmQcow2HeaderInteger $header 96 4 'refcount order') -gt 6) { throw 'QCOW2 refcount order is invalid.' }
        $headerLength = [int](Get-EzVmQcow2HeaderInteger $header 100 4 'header length')
        if (@(104, 112) -notcontains $headerLength) { throw 'QCOW2 version 3 header has an unsupported length.' }
        for ($index = 104; $index -lt $headerLength; $index++) {
            if ($header[$index] -ne 0) { throw 'QCOW2 optional header fields are unsupported unless zero.' }
        }
    }
    $backingOffset = Get-EzVmQcow2HeaderInteger $header 8 8 'backing offset'
    $backingLength = Get-EzVmQcow2HeaderInteger $header 16 4 'backing filename length'
    $hasBacking = $backingOffset -ne 0 -or $backingLength -ne 0
    if ($hasBacking -and [string]::IsNullOrEmpty($ExpectedBacking)) {
        throw 'Standalone QCOW2 must have no backing file; external backing references are refused before QEMU inspection.'
    }
    if (-not $hasBacking -and -not [string]::IsNullOrEmpty($ExpectedBacking)) {
        throw 'Managed QCOW2 overlay is missing its expected backing reference.'
    }
    $backing = ''
    $extensionLimit = $clusterSize
    if ($hasBacking) {
        if ($backingOffset -lt $headerLength + 8 -or $backingLength -lt 1 -or $backingLength -gt 1023 -or
            $backingOffset -gt $clusterSize -or $backingLength -gt $clusterSize - $backingOffset) {
            throw 'QCOW2 backing filename has malformed or out-of-cluster bounds.'
        }
        $encoding = New-Object Text.UTF8Encoding($false, $true)
        try { $backing = $encoding.GetString($header, [int]$backingOffset, [int]$backingLength) }
        catch { throw 'QCOW2 backing filename is not valid UTF-8.' }
        if ($backing -match '[\x00-\x1f\x7f]' -or $backing -cne $ExpectedBacking) {
            throw 'QCOW2 backing filename does not exactly match the intended relocation-safe managed base reference.'
        }
        $extensionLimit = [int]$backingOffset
    }
    $offset = $headerLength
    $ended = $false
    $backingFormat = ''
    $seen = New-Object 'System.Collections.Generic.HashSet[long]'
    while ($offset + 8 -le $extensionLimit) {
        $type = Get-EzVmQcow2HeaderInteger $header $offset 4 'extension type'
        $length = Get-EzVmQcow2HeaderInteger $header ($offset + 4) 4 'extension length'
        $offset += 8
        if ($type -eq 0) {
            if ($length -ne 0) { throw 'QCOW2 extension terminator has a nonzero length.' }
            $ended = $true
            break
        }
        if (-not $seen.Add($type)) { throw 'QCOW2 contains duplicate header extensions.' }
        if ($length -gt $extensionLimit - $offset) { throw 'QCOW2 header extension exceeds its bounded first-cluster area.' }
        # Feature labels do not change image semantics. The only filename-bearing
        # extension admitted is the literal qcow2 format for an expected backing.
        if ($type -eq 0xe2792acaL) {
            if (-not $hasBacking -or $length -ne 5) { throw 'QCOW2 backing-format extension is invalid for this image.' }
            $backingFormat = [Text.Encoding]::ASCII.GetString($header, $offset, [int]$length)
            if ($backingFormat -cne 'qcow2') { throw 'QCOW2 managed backing format must be explicitly qcow2.' }
        }
        elseif ($type -eq 0x6803f857L) {
            if ($length -eq 0 -or ($length % 48) -ne 0) { throw 'QCOW2 feature-name extension has an invalid length.' }
        }
        else { throw ('QCOW2 unsupported or external-data/encryption header extension 0x{0:x8} is refused.' -f $type) }
        $paddedLength = $length + ((8 - ($length % 8)) % 8)
        if ($paddedLength -gt $extensionLimit - $offset) { throw 'QCOW2 header extension padding exceeds the first-cluster area.' }
        $offset += [int]$paddedLength
    }
    if (-not $ended) { throw 'QCOW2 header extension area lacks a bounded terminator.' }
    if ($hasBacking -and $backingFormat -cne 'qcow2') { throw 'QCOW2 overlay lacks its explicit qcow2 backing-format extension.' }
    return [pscustomobject][ordered]@{
        Version = [int]$version
        VirtualSizeBytes = $virtualSize
        BackingReference = $backing
        ClusterSizeBytes = $clusterSize
    }
}

function Test-EzVmQcow2Header {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowEmptyString()][string]$ExpectedBacking = ''
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    $null = Assert-EzVmStorageManagedPath -Path $fullPath -ContainmentRoot ([IO.Path]::GetPathRoot($fullPath)) -SafetyRoot ([IO.Path]::GetPathRoot($fullPath)) -Description 'QCOW2 header input' -RequireFile
    $stream = $null
    try {
        $stream = New-Object IO.FileStream($fullPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        return Read-EzVmQcow2Header -Stream $stream -ExpectedBacking $ExpectedBacking
    }
    finally { if ($null -ne $stream) { $stream.Dispose() } }
}

function Assert-EzVmSnapshotString {
    param([AllowNull()][object]$Value, [string]$Description, [int]$MaximumLength = 4096)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value) -or
        $Value.Length -gt $MaximumLength -or $Value -match '[\x00-\x1f\x7f]') {
        throw "$Description must be a bounded nonempty text string without control characters."
    }
}

function Assert-EzVmSnapshotDigest {
    param([AllowNull()][object]$Value, [string]$Description)
    if ($Value -isnot [string] -or $Value -cnotmatch '^[a-f0-9]{64}$') {
        throw "$Description must be exactly 64 lowercase hexadecimal SHA-256 characters."
    }
}

function Assert-EzVmSnapshotQemuProvenance {
    param([object]$Value)
    Assert-EzVmRuntimeFields -Value $Value -Expected @('manifestSha256', 'qemuSystemVersion', 'qemuImgVersion', 'providerBuild') -Description 'Snapshot QEMU provenance'
    Assert-EzVmSnapshotDigest -Value $Value.manifestSha256 -Description 'Snapshot QEMU manifestSha256'
    foreach ($field in @('qemuSystemVersion', 'qemuImgVersion', 'providerBuild')) {
        Assert-EzVmSnapshotString -Value $Value.$field -Description "Snapshot QEMU $field"
    }
}

function Assert-EzVmSnapshotSourceProvenance {
    param([object]$Value)
    Assert-EzVmRuntimeFields -Value $Value -Expected @('instance', 'overlaySha256', 'baseManifestSha256', 'baseKind') -Description 'Snapshot source provenance'
    Assert-EzVmInstanceIntent -Intent $Value.instance -ExpectedName ([string](Get-EzVmRuntimeProperty $Value.instance 'name'))
    Assert-EzVmSnapshotDigest -Value $Value.overlaySha256 -Description 'Snapshot source overlaySha256'
    Assert-EzVmSnapshotDigest -Value $Value.baseManifestSha256 -Description 'Snapshot source baseManifestSha256'
    if ($Value.baseKind -isnot [string] -or @('prepared', 'derived', 'imported') -cnotcontains $Value.baseKind) { throw 'Snapshot source baseKind is invalid.' }
}

function Assert-EzVmExportManifest {
    param([object]$Manifest)
    Assert-EzVmRuntimeFields -Value $Manifest -Expected @(
        'schemaVersion', 'kind', 'imageFilename', 'imageSha256', 'virtualSizeBytes', 'exportedAt',
        'sensitiveState', 'guestIdentityResetRequired', 'source', 'qemu'
    ) -Description 'Export manifest'
    Assert-EzVmRuntimeInteger -Value $Manifest.schemaVersion -Description 'Export manifest schemaVersion' -Minimum 1 -Maximum 1
    if ($Manifest.kind -isnot [string] -or $Manifest.kind -cne 'ezvm-standalone-export' -or
        $Manifest.imageFilename -isnot [string] -or $Manifest.imageFilename -cne 'disk.qcow2') { throw 'Export manifest kind or image filename is invalid.' }
    Assert-EzVmSnapshotDigest -Value $Manifest.imageSha256 -Description 'Export imageSha256'
    Assert-EzVmRuntimeInteger -Value $Manifest.virtualSizeBytes -Description 'Export virtualSizeBytes' -Minimum 1 -Maximum ([long]::MaxValue)
    Assert-EzVmRuntimeTimestamp -Value $Manifest.exportedAt -Description 'Export exportedAt'
    foreach ($field in @('sensitiveState', 'guestIdentityResetRequired')) {
        if ($Manifest.$field -isnot [bool] -or -not $Manifest.$field) { throw "Export manifest $field must be true." }
    }
    Assert-EzVmSnapshotSourceProvenance -Value $Manifest.source
    Assert-EzVmSnapshotQemuProvenance -Value $Manifest.qemu
}

function Assert-EzVmSnapshotBaseManifest {
    param([object]$Manifest)
    Assert-EzVmRuntimeFields -Value $Manifest -Expected @(
        'schemaVersion', 'baseId', 'baseSha256', 'virtualSizeBytes', 'builtAt', 'kind',
        'sensitiveState', 'guestIdentityResetRequired', 'source', 'qemu'
    ) -Description 'Snapshot-base manifest'
    Assert-EzVmRuntimeInteger -Value $Manifest.schemaVersion -Description 'Snapshot manifest schemaVersion' -Minimum 2 -Maximum 2
    Assert-EzVmSnapshotDigest -Value $Manifest.baseSha256 -Description 'Snapshot baseSha256'
    if ($Manifest.baseId -isnot [string] -or $Manifest.baseId -cne ('base-' + $Manifest.baseSha256)) {
        throw 'Snapshot-base ID must be content-addressed by its complete image SHA-256.'
    }
    Assert-EzVmRuntimeInteger -Value $Manifest.virtualSizeBytes -Description 'Snapshot virtualSizeBytes' -Minimum 1 -Maximum ([long]::MaxValue)
    Assert-EzVmRuntimeTimestamp -Value $Manifest.builtAt -Description 'Snapshot builtAt'
    foreach ($field in @('sensitiveState', 'guestIdentityResetRequired')) {
        if ($Manifest.$field -isnot [bool] -or -not $Manifest.$field) { throw "Snapshot manifest $field must be true." }
    }
    Assert-EzVmSnapshotQemuProvenance -Value $Manifest.qemu
    if ($Manifest.kind -isnot [string]) { throw 'Snapshot-base kind must be a string.' }
    if ($Manifest.kind -ceq 'derived') { Assert-EzVmSnapshotSourceProvenance -Value $Manifest.source }
    elseif ($Manifest.kind -ceq 'imported') {
        Assert-EzVmRuntimeFields -Value $Manifest.source -Expected @('filename', 'imageSha256', 'exportManifestSha256', 'exportManifest') -Description 'Imported-base source provenance'
        Assert-EzVmSnapshotString -Value $Manifest.source.filename -Description 'Import source filename' -MaximumLength 255
        if ($Manifest.source.filename -match '[/\\:]' -or @('.', '..') -ccontains $Manifest.source.filename) { throw 'Import source provenance must contain a filename without an absolute or relative directory path.' }
        Assert-EzVmSnapshotDigest -Value $Manifest.source.imageSha256 -Description 'Import source imageSha256'
        if ($null -eq $Manifest.source.exportManifest) {
            if ($Manifest.source.exportManifestSha256 -isnot [string] -or $Manifest.source.exportManifestSha256.Length -ne 0) { throw 'An import without an export manifest must record an empty exportManifestSha256.' }
        }
        else {
            Assert-EzVmSnapshotDigest -Value $Manifest.source.exportManifestSha256 -Description 'Import source exportManifestSha256'
            Assert-EzVmExportManifest -Manifest $Manifest.source.exportManifest
            if ($Manifest.source.exportManifest.imageSha256 -cne $Manifest.source.imageSha256 -or
                $Manifest.source.exportManifest.virtualSizeBytes -ne $Manifest.virtualSizeBytes) {
                throw 'Imported-base provenance disagrees with its export source digest or virtual size.'
            }
        }
    }
    else { throw 'Snapshot-base kind must be derived or imported; it is not a clean prepared base.' }
}

function Read-EzVmSnapshotExportManifest {
    param([string]$Path)
    $stream = $null
    try {
        $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        if ($stream.Length -gt 65536) { throw 'Import export manifest exceeds 64 KiB.' }
        $bytes = New-Object byte[] ([int]$stream.Length)
        $read = 0
        while ($read -lt $bytes.Length) {
            $count = $stream.Read($bytes, $read, $bytes.Length - $read)
            if ($count -eq 0) { throw 'Import export manifest was truncated while reading.' }
            $read += $count
        }
    }
    finally { if ($null -ne $stream) { $stream.Dispose() } }
    $encoding = New-Object Text.UTF8Encoding($false, $true)
    $manifest = ConvertFrom-EzVmJsonText -Text ($encoding.GetString($bytes)) -SchemaVersion 1 -Description 'Import export manifest'
    Assert-EzVmExportManifest -Manifest $manifest
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $digest = [BitConverter]::ToString($hasher.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $hasher.Dispose() }
    return [pscustomobject]@{ Manifest = $manifest; Digest = $digest }
}

function Get-EzVmSnapshotQemuProvenance {
    param([string]$Root, [scriptblock]$QemuStatusProvider)
    $paths = Get-EzVmPaths -Root $Root
    $manifest = Get-EzVmQemuManifest -Root $Root
    $status = if ($null -ne $QemuStatusProvider) { & $QemuStatusProvider $Root $manifest }
        else { Get-EzVmManagedQemuStatus -Root $Root -Manifest $manifest -ManifestPath $paths.QemuManifest }
    if ($null -eq $status -or (Get-EzVmRuntimeProperty $status 'Valid') -ne $true) {
        throw "Snapshot operations require the validated managed QEMU runtime. Run '.\ezvm.ps1 bootstrap' and retry. $([string](Get-EzVmRuntimeProperty $status 'Reason'))"
    }
    $value = [pscustomobject][ordered]@{
        manifestSha256 = Get-EzVmFileDigest -Path $paths.QemuManifest -Algorithm SHA256
        qemuSystemVersion = [string]$status.QemuSystemVersion
        qemuImgVersion = [string]$status.QemuImgVersion
        providerBuild = [string]$manifest.qemu.providerBuild
    }
    Assert-EzVmSnapshotQemuProvenance -Value $value
    return $value
}

function Test-EzVmStandaloneSnapshot {
    param([string]$Root, [string]$Path, [scriptblock]$QemuImgRunner, [switch]$CheckIntegrity)
    $header = Test-EzVmQcow2Header -Path $Path
    $info = Get-EzVmStorageImageInfo -Root $Root -Path $Path -QemuImgRunner $QemuImgRunner
    Assert-EzVmStandaloneQcow2 -Info $info -Description 'Standalone snapshot'
    $size = Get-EzVmStorageInteger -Object $info -Name 'virtual-size' -Description 'Standalone snapshot'
    if ($size -ne $header.VirtualSizeBytes) { throw 'QCOW2 header and qemu-img virtual sizes disagree.' }
    foreach ($field in @('data-file', 'full-backing-filename', 'backing-filename-format')) {
        if (-not [string]::IsNullOrEmpty([string](Get-EzVmStorageProperty $info $field))) { throw "Standalone snapshot contains unexpected dependency field '$field'." }
    }
    if ($CheckIntegrity) {
        $result = Invoke-EzVmStorageQemuImg -Root $Root -ArgumentList @('check', '--output=json', '-f', 'qcow2', [IO.Path]::GetFullPath($Path)) -Runner $QemuImgRunner -TimeoutSeconds 1800
        $report = ConvertFrom-EzVmStorageJson -Text $result.StdOut -Description 'Standalone snapshot integrity check'
        if ($report -isnot [pscustomobject] -or [string](Get-EzVmStorageProperty $report 'format') -cne 'qcow2') { throw 'Snapshot qemu-img check did not return a QCOW2 report.' }
        foreach ($field in @('check-errors', 'corruptions', 'leaks')) {
            $count = Get-EzVmStorageInteger -Object $report -Name $field -Description 'Snapshot integrity check' -Optional:($field -cne 'check-errors')
            if ($count -ne 0) { throw "Standalone snapshot integrity check reports $field=$count; no repair was attempted." }
        }
    }
    return [pscustomobject]@{ VirtualSizeBytes = $size; Info = $info }
}

function Assert-EzVmSnapshotSourceHeaders {
    param([string]$Root, [object]$SourceIntent)
    Assert-EzVmInstanceIntent -Intent $SourceIntent -ExpectedName ([string](Get-EzVmRuntimeProperty $SourceIntent 'name'))
    $paths = Get-EzVmPaths -Root $Root
    $storage = Get-EzVmInstanceStoragePaths -Root $Root -InstanceName $SourceIntent.name
    $null = Assert-EzVmStorageManagedPath -Path $storage.Disk -ContainmentRoot $paths.Instances -SafetyRoot $paths.Root -Description 'Snapshot source overlay' -RequireFile
    $basePath = Join-Path (Join-Path $paths.Bases $SourceIntent.baseId) 'base.qcow2'
    $null = Assert-EzVmStorageManagedPath -Path $basePath -ContainmentRoot $paths.Bases -SafetyRoot $paths.Root -Description 'Snapshot source base' -RequireFile
    $relative = Get-EzVmStorageRelativePath -FromDirectory $storage.Directory -TargetPath $basePath
    $null = Test-EzVmQcow2Header -Path $storage.Disk -ExpectedBacking $relative
    $null = Test-EzVmQcow2Header -Path $basePath
}

function Get-EzVmSnapshotSource {
    param([string]$Root, [object]$SourceIntent, [object]$LifecycleGuard, [scriptblock]$QemuImgRunner)
    Assert-EzVmStorageLifecycleGuard -LifecycleGuard $LifecycleGuard -Operation 'Stopped-instance snapshot'
    Assert-EzVmSnapshotSourceHeaders -Root $Root -SourceIntent $SourceIntent
    $storage = Get-EzVmInstanceStoragePaths -Root $Root -InstanceName $SourceIntent.name
    $integrity = Test-EzVmStoppedImageIntegrity -Root $Root -InstanceName $SourceIntent.name -BaseId $SourceIntent.baseId -LifecycleGuard $LifecycleGuard -QemuImgRunner $QemuImgRunner
    if (-not $integrity.Healthy) { throw 'Source overlay integrity check failed; stopped source data was preserved and no repair was attempted.' }
    $base = Test-EzVmPreparedBase -Root $Root -BaseId $SourceIntent.baseId -QemuImgRunner $QemuImgRunner
    $provenance = [pscustomobject][ordered]@{
        instance = $SourceIntent
        overlaySha256 = Get-EzVmFileDigest -Path $storage.Disk -Algorithm SHA256
        baseManifestSha256 = Get-EzVmFileDigest -Path $base.ManifestPath -Algorithm SHA256
        baseKind = $(if ($base.Manifest.schemaVersion -eq 1) { 'prepared' } else { [string]$base.Manifest.kind })
    }
    Assert-EzVmSnapshotSourceProvenance -Value $provenance
    return [pscustomobject]@{ Disk = $storage.Disk; VirtualSizeBytes = [long]$base.Manifest.virtualSizeBytes; Provenance = $provenance }
}

function Convert-EzVmSnapshotImage {
    param([string]$Root, [string]$Source, [string]$Destination, [long]$VirtualSizeBytes, [scriptblock]$QemuImgRunner)
    if (Test-Path -LiteralPath $Destination) { throw 'Snapshot candidate already exists; refusing overwrite.' }
    $null = Invoke-EzVmStorageQemuImg -Root $Root -ArgumentList @('convert', '-f', 'qcow2', '-O', 'qcow2', [IO.Path]::GetFullPath($Source), [IO.Path]::GetFullPath($Destination)) -Runner $QemuImgRunner -TimeoutSeconds 1800
    $candidate = Test-EzVmStandaloneSnapshot -Root $Root -Path $Destination -QemuImgRunner $QemuImgRunner -CheckIntegrity
    if ($candidate.VirtualSizeBytes -ne $VirtualSizeBytes) { throw 'Standalone conversion changed the guest virtual size; source data was preserved.' }
    return $candidate
}

function New-EzVmSnapshotStage {
    param([string]$Root)
    $paths = Get-EzVmPaths -Root $Root
    $null = Assert-EzVmStorageManagedPath -Path $paths.Bases -ContainmentRoot $paths.Runtime -SafetyRoot $paths.Root -Description 'Snapshot staging root'
    [void][IO.Directory]::CreateDirectory($paths.Bases)
    $stage = Join-Path $paths.Bases ('.snapshot-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($stage)
    return $stage
}

function Write-EzVmSnapshotFailure {
    param([string]$StagingDirectory, [string]$Operation, [object]$Failure)
    try {
        $message = [string]$Failure.Exception.Message
        if ($message.Length -gt 4096) { $message = $message.Substring(0, 4096) }
        Write-EzVmJson -Path (Join-Path $StagingDirectory 'failure.json') -Value ([pscustomobject][ordered]@{
            schemaVersion = 1; operation = $Operation; failedAt = [DateTime]::UtcNow.ToString('o'); message = $message; sensitiveState = $true
        })
    }
    catch { }
}

function Publish-EzVmSnapshotBase {
    param([string]$Root, [string]$StagingDirectory, [string]$ImagePath, [object]$Manifest, [scriptblock]$QemuImgRunner, [scriptblock]$DirectoryMover)
    Assert-EzVmSnapshotBaseManifest -Manifest $Manifest
    $paths = Get-EzVmPaths -Root $Root
    $candidate = Join-Path $StagingDirectory 'candidate'
    [void][IO.Directory]::CreateDirectory($candidate)
    $image = Join-Path $candidate 'base.qcow2'
    [IO.File]::Move($ImagePath, $image)
    $manifestPath = Join-Path $candidate 'manifest.json'
    Write-EzVmJson -Path $manifestPath -Value $Manifest -SchemaVersion 2
    foreach ($path in @($image, $manifestPath)) {
        [IO.File]::SetAttributes($path, ((Get-Item -LiteralPath $path -Force).Attributes -bor [IO.FileAttributes]::ReadOnly))
    }
    $accepted = Test-EzVmPreparedBaseDirectory -Root $Root -Directory $candidate -BaseId $Manifest.baseId -QemuImgRunner $QemuImgRunner
    $final = Join-Path $paths.Bases $Manifest.baseId
    if (Test-Path -LiteralPath $final) {
        $existing = Test-EzVmPreparedBase -Root $Root -BaseId $Manifest.baseId -QemuImgRunner $QemuImgRunner
        # A content-addressed identity never changes its first immutable manifest.
        # The caller persists this operation's provenance with destination intent.
        $existing | Add-Member -NotePropertyName Reused -NotePropertyValue $true
        $existing | Add-Member -NotePropertyName OperationProvenance -NotePropertyValue $Manifest
        return $existing
    }
    Move-EzVmDirectoryAtomically -Source $candidate -Destination $final -Mover $DirectoryMover
    return [pscustomobject][ordered]@{
        BaseId = $Manifest.baseId; Directory = $final; Image = Join-Path $final 'base.qcow2'
        ManifestPath = Join-Path $final 'manifest.json'; Manifest = $Manifest; ReadOnly = $true
        Reused = $false; OperationProvenance = $Manifest
    }
}

function New-EzVmDerivedBase {
    [CmdletBinding()]
    param(
        [string]$Root = $script:EzVmDefaultRoot,
        [Parameter(Mandatory = $true)][object]$SourceIntent,
        [Parameter(Mandatory = $true)][AllowNull()][object]$LifecycleGuard,
        [scriptblock]$QemuImgRunner, [scriptblock]$QemuStatusProvider, [scriptblock]$DirectoryMover
    )
    Assert-EzVmStorageLifecycleGuard -LifecycleGuard $LifecycleGuard -Operation 'Stateful clone snapshot'
    $qemu = Get-EzVmSnapshotQemuProvenance -Root $Root -QemuStatusProvider $QemuStatusProvider
    $source = Get-EzVmSnapshotSource -Root $Root -SourceIntent $SourceIntent -LifecycleGuard $LifecycleGuard -QemuImgRunner $QemuImgRunner
    $stage = New-EzVmSnapshotStage -Root $Root
    try {
        $flat = Join-Path $stage 'standalone.qcow2'
        $null = Convert-EzVmSnapshotImage -Root $Root -Source $source.Disk -Destination $flat -VirtualSizeBytes $source.VirtualSizeBytes -QemuImgRunner $QemuImgRunner
        if ((Get-EzVmFileDigest -Path $source.Disk -Algorithm SHA256) -cne $source.Provenance.overlaySha256) { throw 'Snapshot source changed during conversion; refusing inconsistent publication.' }
        $digest = Get-EzVmFileDigest -Path $flat -Algorithm SHA256
        $manifest = [pscustomobject][ordered]@{
            schemaVersion = 2; baseId = 'base-' + $digest; baseSha256 = $digest
            virtualSizeBytes = $source.VirtualSizeBytes; builtAt = [DateTime]::UtcNow.ToString('o'); kind = 'derived'
            sensitiveState = $true; guestIdentityResetRequired = $true; source = $source.Provenance; qemu = $qemu
        }
        $result = Publish-EzVmSnapshotBase -Root $Root -StagingDirectory $stage -ImagePath $flat -Manifest $manifest -QemuImgRunner $QemuImgRunner -DirectoryMover $DirectoryMover
        try { Remove-Item -LiteralPath $stage -Recurse -Force } catch { }
        return $result
    }
    catch {
        Write-EzVmSnapshotFailure -StagingDirectory $stage -Operation 'derive' -Failure $_
        throw [InvalidOperationException]::new("Stateful snapshot failed. Source data is preserved; sensitive recoverable staging remains at '$stage'. $($_.Exception.Message)", $_.Exception)
    }
}

function Export-EzVmInstanceStorage {
    [CmdletBinding()]
    param(
        [string]$Root = $script:EzVmDefaultRoot,
        [Parameter(Mandatory = $true)][object]$SourceIntent,
        [Parameter(Mandatory = $true)][AllowNull()][object]$LifecycleGuard,
        [Parameter(Mandatory = $true)][string]$DestinationDirectory,
        [scriptblock]$QemuImgRunner, [scriptblock]$QemuStatusProvider, [scriptblock]$DirectoryMover
    )
    Assert-EzVmStorageLifecycleGuard -LifecycleGuard $LifecycleGuard -Operation 'Instance export'
    $paths = Get-EzVmPaths -Root $Root
    $destination = [IO.Path]::GetFullPath($DestinationDirectory)
    if (Test-EzVmStoragePathInside -Path $destination -Directory $paths.Runtime) { throw 'Export destination must be outside managed runtime state.' }
    $null = Assert-EzVmStorageManagedPath -Path $destination -ContainmentRoot ([IO.Path]::GetPathRoot($destination)) -SafetyRoot ([IO.Path]::GetPathRoot($destination)) -Description 'Export destination'
    if (Test-Path -LiteralPath $destination) { throw 'Export destination already exists; choose a new directory. No image or manifest is overwritten.' }
    $parent = [IO.Path]::GetDirectoryName($destination)
    if (-not [IO.Directory]::Exists($parent)) { throw 'Export parent directory must already exist.' }
    $qemu = Get-EzVmSnapshotQemuProvenance -Root $Root -QemuStatusProvider $QemuStatusProvider
    $source = Get-EzVmSnapshotSource -Root $Root -SourceIntent $SourceIntent -LifecycleGuard $LifecycleGuard -QemuImgRunner $QemuImgRunner
    $stage = Join-Path $parent ('.ezvm-export-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($stage)
    try {
        $image = Join-Path $stage 'disk.qcow2'
        $null = Convert-EzVmSnapshotImage -Root $Root -Source $source.Disk -Destination $image -VirtualSizeBytes $source.VirtualSizeBytes -QemuImgRunner $QemuImgRunner
        if ((Get-EzVmFileDigest -Path $source.Disk -Algorithm SHA256) -cne $source.Provenance.overlaySha256) { throw 'Export source changed during conversion; refusing inconsistent publication.' }
        $digest = Get-EzVmFileDigest -Path $image -Algorithm SHA256
        $manifest = [pscustomobject][ordered]@{
            schemaVersion = 1; kind = 'ezvm-standalone-export'; imageFilename = 'disk.qcow2'
            imageSha256 = $digest; virtualSizeBytes = $source.VirtualSizeBytes; exportedAt = [DateTime]::UtcNow.ToString('o')
            sensitiveState = $true; guestIdentityResetRequired = $true; source = $source.Provenance; qemu = $qemu
        }
        Assert-EzVmExportManifest -Manifest $manifest
        $manifestPath = Join-Path $stage 'manifest.json'
        Write-EzVmJson -Path $manifestPath -Value $manifest
        Assert-EzVmExportManifest -Manifest (Read-EzVmJson -Path $manifestPath)
        if ((Get-EzVmFileDigest -Path $image -Algorithm SHA256) -cne $digest) { throw 'Export candidate changed before publication.' }
        Move-EzVmDirectoryAtomically -Source $stage -Destination $destination -Mover $DirectoryMover
        return [pscustomobject][ordered]@{
            Directory = $destination; Image = Join-Path $destination 'disk.qcow2'
            ManifestPath = Join-Path $destination 'manifest.json'; Manifest = $manifest
            SensitiveState = $true; Warning = 'This export may contain guest source code, credentials and saved agent authentication. It has not been uploaded or shared.'
        }
    }
    catch {
        Write-EzVmSnapshotFailure -StagingDirectory $stage -Operation 'export' -Failure $_
        throw [InvalidOperationException]::new("Export failed. Source data is preserved; sensitive recoverable staging remains at '$stage'. $($_.Exception.Message)", $_.Exception)
    }
}

function Import-EzVmStandaloneBase {
    [CmdletBinding()]
    param(
        [string]$Root = $script:EzVmDefaultRoot,
        [Parameter(Mandatory = $true)][string]$ImagePath,
        [AllowEmptyString()][string]$ManifestPath,
        [scriptblock]$QemuImgRunner, [scriptblock]$QemuStatusProvider, [scriptblock]$DirectoryMover
    )
    $paths = Get-EzVmPaths -Root $Root
    $source = [IO.Path]::GetFullPath($ImagePath)
    if (Test-EzVmStoragePathInside -Path $source -Directory $paths.Runtime) {
        throw 'Import refuses source images inside managed runtime state. Export the positively stopped instance first, then import its standalone export.'
    }
    $null = Assert-EzVmStorageManagedPath -Path $source -ContainmentRoot ([IO.Path]::GetPathRoot($source)) -SafetyRoot ([IO.Path]::GetPathRoot($source)) -Description 'Standalone import source' -RequireFile
    $exportManifest = $null
    $exportManifestDigest = ''
    if (-not [string]::IsNullOrWhiteSpace($ManifestPath)) {
        $sidecar = [IO.Path]::GetFullPath($ManifestPath)
        $null = Assert-EzVmStorageManagedPath -Path $sidecar -ContainmentRoot ([IO.Path]::GetPathRoot($sidecar)) -SafetyRoot ([IO.Path]::GetPathRoot($sidecar)) -Description 'Import export-manifest source' -RequireFile
        $sidecarResult = Read-EzVmSnapshotExportManifest -Path $sidecar
        $exportManifest = $sidecarResult.Manifest
        $exportManifestDigest = $sidecarResult.Digest
    }
    # FileShare.None proves exclusive source-file access on the supported Windows
    # host. QEMU never opens the caller's file: only our immutable staged copy.
    $inputStream = $null
    $outputStream = $null
    $stage = $null
    try {
        $inputStream = New-Object IO.FileStream($source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        $header = Read-EzVmQcow2Header -Stream $inputStream
        $stage = New-EzVmSnapshotStage -Root $Root
        $copy = Join-Path $stage 'source.qcow2'
        $inputStream.Position = 0
        $outputStream = New-Object IO.FileStream($copy, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $inputStream.CopyTo($outputStream)
        $outputStream.Flush($true)
        $outputStream.Dispose(); $outputStream = $null
        $inputStream.Position = 0
        $hasher = [Security.Cryptography.SHA256]::Create()
        try { $sourceDigest = [BitConverter]::ToString($hasher.ComputeHash($inputStream)).Replace('-', '').ToLowerInvariant() }
        finally { $hasher.Dispose() }
        $copyDigest = Get-EzVmFileDigest -Path $copy -Algorithm SHA256
        if ($copyDigest -cne $sourceDigest) { throw 'Import source changed during staged copy; refusing inconsistent data.' }
        $inputStream.Dispose(); $inputStream = $null
        if ($null -ne $exportManifest -and ($exportManifest.imageSha256 -cne $sourceDigest -or $exportManifest.virtualSizeBytes -ne $header.VirtualSizeBytes)) {
            throw 'Import bytes or virtual size do not match the supplied export manifest.'
        }
        $qemu = Get-EzVmSnapshotQemuProvenance -Root $Root -QemuStatusProvider $QemuStatusProvider
        $null = Test-EzVmStandaloneSnapshot -Root $Root -Path $copy -QemuImgRunner $QemuImgRunner -CheckIntegrity
        $flat = Join-Path $stage 'standalone.qcow2'
        $null = Convert-EzVmSnapshotImage -Root $Root -Source $copy -Destination $flat -VirtualSizeBytes $header.VirtualSizeBytes -QemuImgRunner $QemuImgRunner
        if ((Get-EzVmFileDigest -Path $copy -Algorithm SHA256) -cne $copyDigest) { throw 'Import conversion changed its source copy; no base was published.' }
        $digest = Get-EzVmFileDigest -Path $flat -Algorithm SHA256
        $manifest = [pscustomobject][ordered]@{
            schemaVersion = 2; baseId = 'base-' + $digest; baseSha256 = $digest
            virtualSizeBytes = $header.VirtualSizeBytes; builtAt = [DateTime]::UtcNow.ToString('o'); kind = 'imported'
            sensitiveState = $true; guestIdentityResetRequired = $true
            source = [pscustomobject][ordered]@{ filename = [IO.Path]::GetFileName($source); imageSha256 = $sourceDigest; exportManifestSha256 = $exportManifestDigest; exportManifest = $exportManifest }
            qemu = $qemu
        }
        $result = Publish-EzVmSnapshotBase -Root $Root -StagingDirectory $stage -ImagePath $flat -Manifest $manifest -QemuImgRunner $QemuImgRunner -DirectoryMover $DirectoryMover
        try { Remove-Item -LiteralPath $stage -Recurse -Force } catch { }
        return $result
    }
    catch {
        if ($null -ne $stage) {
            Write-EzVmSnapshotFailure -StagingDirectory $stage -Operation 'import' -Failure $_
            throw [InvalidOperationException]::new("Import failed. The source image was not modified; sensitive recoverable staging remains at '$stage'. $($_.Exception.Message)", $_.Exception)
        }
        throw
    }
    finally {
        if ($null -ne $outputStream) { $outputStream.Dispose() }
        if ($null -ne $inputStream) { $inputStream.Dispose() }
    }
}
