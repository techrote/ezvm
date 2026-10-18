function Get-EzVmQemuOverlay {
    param([object]$Manifest)
    $property = $Manifest.PSObject.Properties['whpxResetOverlay']
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-EzVmEffectiveQemuVersion {
    param([object]$Manifest)
    $overlay = Get-EzVmQemuOverlay -Manifest $Manifest
    if ($null -ne $overlay) { return $overlay.version }
    return $Manifest.qemu.version
}

function Get-EzVmEffectiveQemuVersionPrefix {
    param([object]$Manifest)
    $overlay = Get-EzVmQemuOverlay -Manifest $Manifest
    if ($null -ne $overlay) { return $overlay.expectedVersionPrefix }
    return $Manifest.qemu.expectedVersionPrefix
}

function Assert-EzVmQemuOverlayManifest {
    param([object]$Overlay, [object]$Manifest)
    Assert-EzVmQemuManifestFields -Value $Overlay -Expected @(
        'version', 'expectedVersionPrefix', 'artifact', 'baseProviderDigest',
        'basePayloadSha256', 'installedPayloadSha256', 'qemuSourceCommit', 'qemuSourceTree', 'buildManifestSha256', 'files'
    ) -Description 'WHPX reset overlay'
    foreach ($name in @('version', 'expectedVersionPrefix')) {
        Assert-EzVmQemuManifestString -Value $Overlay.$name -Description "WHPX overlay $name"
    }
    if ($Overlay.version -cne '11.1.2' -or $Overlay.expectedVersionPrefix -cne $Overlay.version) {
        throw 'WHPX reset overlay requires the reviewed QEMU 11.1.2 version.'
    }
    foreach ($name in @('basePayloadSha256', 'installedPayloadSha256', 'buildManifestSha256')) {
        if ($Overlay.$name -isnot [string] -or $Overlay.$name -cnotmatch '^[a-f0-9]{64}$') { throw "Invalid WHPX overlay $name." }
    }
    foreach ($name in @('qemuSourceCommit', 'qemuSourceTree')) {
        if ($Overlay.$name -isnot [string] -or $Overlay.$name -cnotmatch '^[a-f0-9]{40}$') { throw "Invalid WHPX overlay $name." }
    }
    if ($Overlay.baseProviderDigest -isnot [string] -or $Overlay.baseProviderDigest -cne $Manifest.qemu.digest) {
        throw 'WHPX overlay is not bound to this original provider artifact.'
    }
    Assert-EzVmQemuArtifactDescriptor -Artifact $Overlay.artifact -Description 'WHPX reset overlay artifact' -RequiredAlgorithm 'SHA256' -RequiredHost 'github.com'
    $uri = [Uri]$Overlay.artifact.url
    if ($uri.UserInfo -or $uri.Query -or $uri.Fragment -or -not $uri.IsDefaultPort -or
        $uri.AbsolutePath -cnotmatch '^/techrote/ezvm/releases/download/qemu-whpx-[A-Za-z0-9._-]+/qemu-whpx-[A-Za-z0-9._-]+\.zip$' -or
        [Uri]::UnescapeDataString(($uri.AbsolutePath -split '/')[-1]) -cne $Overlay.artifact.filename) {
        throw 'WHPX overlay requires an exact reviewed techrote/ezvm release asset URL.'
    }
    $allowed = @('qemu-system-x86_64.exe', 'qemu-img.exe', 'libglib-2.0-0.dll', 'libiconv-2.dll',
        'libintl-8.dll', 'libpcre2-8-0.dll', 'libslirp-0.dll', 'libwinpthread-1.dll', 'libzstd.dll', 'zlib1.dll')
    if ($Overlay.files -isnot [array] -or $Overlay.files.Count -ne $allowed.Count) { throw 'WHPX overlay must contain exactly ten reviewed files.' }
    $seen = @{}; $total = [long]0
    foreach ($file in $Overlay.files) {
        Assert-EzVmQemuManifestFields -Value $file -Expected @('name', 'sizeBytes', 'sha256') -Description 'WHPX overlay file'
        if ($file.name -isnot [string] -or $allowed -cnotcontains $file.name -or $seen.ContainsKey($file.name)) { throw 'Unsafe, duplicate or unreviewed WHPX overlay filename.' }
        Assert-EzVmQemuManifestInteger -Value $file.sizeBytes -Description 'WHPX overlay file size'
        if ($file.sizeBytes -gt 100MB -or $file.sha256 -isnot [string] -or $file.sha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'Invalid WHPX overlay file size or digest.' }
        $total += [long]$file.sizeBytes; $seen[$file.name] = $true
    }
    if ($total -gt 200MB) { throw 'WHPX overlay exceeds its bounded payload size.' }
}

function Get-EzVmQemuCanonicalRecordDigest {
    param([System.Collections.IDictionary]$Files)
    $records = New-Object 'System.Collections.Generic.SortedDictionary[string,string]' ([StringComparer]::Ordinal)
    foreach ($relative in $Files.Keys) {
        $file = $Files[$relative]
        $records.Add($relative, ($relative + [char]0 + ([long]$file.sizeBytes).ToString([Globalization.CultureInfo]::InvariantCulture) + [char]0 + $file.sha256 + "`n"))
    }
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes([string]::Join('', @($records.Values)))))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}

function Get-EzVmQemuBasePayloadDigest {
    param([string]$Directory)
    $files = @{}
    foreach ($entry in @(Get-EzVmSafeTree -Path $Directory)) {
        if ($entry -isnot [IO.FileInfo]) { continue }
        Assert-EzVmSingleLinkFile -Path $entry.FullName
        $relative = (Get-EzVmStorageRelativePath -FromDirectory $Directory -TargetPath $entry.FullName).Replace('\', '/')
        if ($relative -iin @('ezvm-provenance.json', 'ezvm-payload.json')) { throw 'Original provider extraction contains an unexpected trust receipt.' }
        if ($files.ContainsKey($relative)) { throw 'Original provider payload contains a duplicate or case-ambiguous path.' }
        $digest = Get-EzVmFileDigest -Path $entry.FullName -Algorithm SHA256
        $files[$relative] = @{sizeBytes=[long]$entry.Length;sha256=$digest}
    }
    if ($files.Count -lt 2) { throw 'Original provider payload is incomplete.' }
    return Get-EzVmQemuCanonicalRecordDigest -Files $files
}

function Expand-EzVmQemuOverlay {
    param([string]$ArchivePath, [string]$Destination, [object]$Overlay)
    $null = Assert-EzVmSafePath -Path $ArchivePath -Description 'WHPX overlay archive'
    Assert-EzVmSingleLinkFile -Path $ArchivePath
    $null = Assert-EzVmSafePath -Path $Destination -Description 'WHPX overlay staging'
    if (Test-Path -LiteralPath $Destination) { throw 'WHPX overlay staging already exists.' }
    Add-Type -AssemblyName System.IO.Compression
    $archiveStream = [IO.File]::Open($ArchivePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $archive = $null
    try {
        $archive = New-Object IO.Compression.ZipArchive($archiveStream, [IO.Compression.ZipArchiveMode]::Read, $true)
        if ($archive.Entries.Count -ne $Overlay.files.Count) { throw 'WHPX overlay archive has an unexpected entry count.' }
        $expected = @{}; foreach ($file in $Overlay.files) { $expected[$file.name] = $file }
        $seen = @{}
        # Inspect every central-directory name/size before writing any entry.
        foreach ($entry in $archive.Entries) {
            if (-not $expected.ContainsKey($entry.FullName) -or $seen.ContainsKey($entry.FullName) -or
                $entry.FullName -cne $expected[$entry.FullName].name -or $entry.Length -ne $expected[$entry.FullName].sizeBytes) {
                throw 'WHPX overlay archive has unsafe, duplicate, extra or incorrectly sized entries.'
            }
            $seen[$entry.FullName] = $true
        }
        [void][IO.Directory]::CreateDirectory($Destination)
        foreach ($entry in $archive.Entries) {
            $target = Assert-EzVmSafePath -Path (Join-Path $Destination $entry.FullName) -Description 'WHPX overlay file'
            $source = $entry.Open(); $output = $null
            try {
                $output = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                $buffer = New-Object byte[] 1048576; $total = [long]0
                while (($count = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $total += $count
                    if ($total -gt $expected[$entry.FullName].sizeBytes) { throw 'WHPX overlay entry exceeded its declared size.' }
                    $output.Write($buffer, 0, $count)
                }
                if ($total -ne $expected[$entry.FullName].sizeBytes) { throw 'WHPX overlay entry is truncated.' }
            }
            finally { if ($output) { $output.Dispose() }; $source.Dispose() }
        }
        foreach ($file in $Overlay.files) {
            $path = Join-Path $Destination $file.name
            Assert-EzVmSingleLinkFile -Path $path
            if ((Get-EzVmFileDigest -Path $path -Algorithm SHA256) -cne $file.sha256) { throw 'WHPX overlay extracted file digest mismatch.' }
        }
    }
    finally { if ($archive) { $archive.Dispose() }; $archiveStream.Dispose() }
}

function Install-EzVmQemuOverlayFiles {
    param([string]$ProviderStage, [string]$OverlayStage, [object]$Overlay)
    if ((Get-EzVmQemuBasePayloadDigest -Directory $ProviderStage) -cne $Overlay.basePayloadSha256) {
        throw 'WHPX overlay original provider payload inventory mismatch.'
    }
    foreach ($file in $Overlay.files) {
        $source = Assert-EzVmSafePath -Path (Join-Path $OverlayStage $file.name) -Description 'Verified overlay file'
        Assert-EzVmSingleLinkFile -Path $source
        if ((Get-Item -LiteralPath $source -Force).Length -ne $file.sizeBytes -or (Get-EzVmFileDigest -Path $source -Algorithm SHA256) -cne $file.sha256) { throw 'WHPX overlay file changed before installation.' }
        $target = Assert-EzVmSafePath -Path (Join-Path $ProviderStage $file.name) -Description 'Owned provider staging file'
        if (Test-Path -LiteralPath $target) { Assert-EzVmSingleLinkFile -Path $target }
    }
    # No replacement begins until every input and existing destination is checked.
    foreach ($file in $Overlay.files) { [IO.File]::Copy((Join-Path $OverlayStage $file.name), (Join-Path $ProviderStage $file.name), $true) }
}
