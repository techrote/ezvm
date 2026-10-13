function Write-EzVmQemuPayloadInventory {
    param([string]$RuntimeDirectory, [string]$ManifestDigest)
    $files = New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in @(Get-EzVmSafeTree -Path $RuntimeDirectory | Sort-Object FullName)) {
        if ($entry -isnot [IO.FileInfo]) { continue }
        $relative = (Get-EzVmStorageRelativePath -FromDirectory $RuntimeDirectory -TargetPath $entry.FullName).Replace('\', '/')
        if ($relative -cin @('ezvm-provenance.json', 'ezvm-payload.json')) { throw 'Extraction unexpectedly supplied an ezvm trust receipt.' }
        $files.Add([pscustomobject][ordered]@{ path = $relative; sizeBytes = [long]$entry.Length; sha256 = (Get-EzVmFileDigest -Path $entry.FullName -Algorithm SHA256) })
    }
    if ($files.Count -eq 0) { throw 'QEMU extraction produced an empty payload inventory.' }
    $inventory = [pscustomobject][ordered]@{ schemaVersion = 1; manifestSha256 = $ManifestDigest; files = @($files.ToArray()) }
    $path = Join-Path $RuntimeDirectory 'ezvm-payload.json'
    Write-EzVmJson -Path $path -Value $inventory
    return Get-EzVmFileDigest -Path $path -Algorithm SHA256
}

function Assert-EzVmQemuPayloadIntegrity {
    param([Parameter(Mandatory = $true)][string]$RuntimeDirectory,
        [Parameter(Mandatory = $true)][string]$ManifestPath)
    $null = Assert-EzVmSafePath -Path $RuntimeDirectory -Description 'Managed QEMU runtime'
    $receipt = Read-EzVmJson -Path (Join-Path $RuntimeDirectory 'ezvm-provenance.json')
    $manifestDigest = Get-EzVmFileDigest -Path $ManifestPath -Algorithm SHA256
    if ($receipt.manifestSha256 -cne $manifestDigest) { throw 'Managed QEMU provenance does not match the reviewed manifest.' }
    $property = $receipt.PSObject.Properties['payloadManifestSha256']
    if ($null -eq $property -or $property.Value -isnot [string] -or $property.Value -cnotmatch '^[a-f0-9]{64}$') {
        throw 'Managed QEMU lacks a verified payload inventory. Stop all guests, preserve this legacy runtime outside runtime/qemu, then bootstrap from reviewed pins; never generate a receipt from unverified installed bytes.'
    }
    $inventoryPath = Join-Path $RuntimeDirectory 'ezvm-payload.json'
    if ((Get-EzVmFileDigest -Path $inventoryPath -Algorithm SHA256) -cne $property.Value) { throw 'Managed QEMU payload inventory digest mismatch. Preserve the runtime and rebuild it from reviewed provider artifacts.' }
    $inventory = Read-EzVmJson -Path $inventoryPath
    Assert-EzVmRuntimeFields -Value $inventory -Expected @('schemaVersion', 'manifestSha256', 'files') -Description 'QEMU payload inventory'
    if ($inventory.manifestSha256 -cne $manifestDigest -or $inventory.files -isnot [array] -or $inventory.files.Count -lt 2 -or $inventory.files.Count -gt 20000) { throw 'QEMU payload inventory has invalid provenance or entry count.' }
    $expected = @{}
    foreach ($file in $inventory.files) {
        Assert-EzVmRuntimeFields -Value $file -Expected @('path', 'sizeBytes', 'sha256') -Description 'QEMU payload entry'
        if ($file.path -isnot [string] -or $file.path.Length -gt 512 -or $file.path -match '[\\:\x00-\x1f]' -or
            $file.path.StartsWith('/') -or @($file.path -split '/' | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0 -or
            $file.path -iin @('ezvm-provenance.json', 'ezvm-payload.json') -or $expected.ContainsKey($file.path)) {
            throw 'QEMU payload inventory contains an unsafe or duplicate path.'
        }
        Assert-EzVmRuntimeInteger -Value $file.sizeBytes -Description 'QEMU payload size' -Minimum 0 -Maximum 9223372036854775807
        if ($file.sha256 -isnot [string] -or $file.sha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'QEMU payload entry has an invalid digest.' }
        $expected[$file.path] = $file
    }
    foreach ($required in @('qemu-system-x86_64.exe', 'qemu-img.exe')) {
        if (-not $expected.ContainsKey($required)) { throw 'QEMU inventory omits required executables.' }
    }
    $observed = @{}
    foreach ($entry in @(Get-EzVmSafeTree -Path $RuntimeDirectory)) {
        if ($entry -isnot [IO.FileInfo]) { continue }
        $relative = (Get-EzVmStorageRelativePath -FromDirectory $RuntimeDirectory -TargetPath $entry.FullName).Replace('\', '/')
        if ($relative -cin @('ezvm-provenance.json', 'ezvm-payload.json')) { continue }
        if (-not $expected.ContainsKey($relative) -or $observed.ContainsKey($relative)) { throw 'Managed QEMU contains an unrecorded or ambiguous payload file; refusing execution.' }
        $record = $expected[$relative]
        if ($record.path -cne $relative -or [long]$record.sizeBytes -ne $entry.Length -or
            (Get-EzVmFileDigest -Path $entry.FullName -Algorithm SHA256) -cne $record.sha256) {
            throw 'Managed QEMU payload digest or size mismatch; refusing execution before version probing.'
        }
        $observed[$relative] = $true
    }
    if ($observed.Count -ne $expected.Count) { throw 'Managed QEMU payload is incomplete; restore it from verified provider artifacts.' }
}
