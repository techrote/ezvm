function Assert-EzVmManifestFields {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if ($Value -isnot [pscustomobject]) {
        throw "$Description must be a JSON object."
    }
    $actual = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($name in $actual) {
        if ($Expected -cnotcontains $name) { throw "$Description contains unknown field '$name'." }
    }
    foreach ($name in $Expected) {
        if ($actual -cnotcontains $name) { throw "$Description is missing required field '$name'." }
    }
}

function Assert-EzVmManifestString {
    param([AllowNull()][object]$Value, [string]$Description)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
        throw "$Description must be a non-empty string."
    }
}

function Get-EzVmSourceImageManifest {
    [CmdletBinding()]
    param(
        [string]$Root = $script:EzVmDefaultRoot,
        [string]$ManifestPath
    )

    $paths = Get-EzVmPaths -Root $Root
    if (-not $PSBoundParameters.ContainsKey('ManifestPath')) {
        $ManifestPath = $paths.UbuntuManifest
    }
    $manifest = Read-EzVmJson -Path $ManifestPath -SchemaVersion 1
    Assert-EzVmManifestFields -Value $manifest -Expected @(
        'schemaVersion', 'provider', 'release', 'codename', 'architecture',
        'publication', 'url', 'filename', 'sha256'
    ) -Description 'Ubuntu source-image manifest'
    foreach ($field in @('provider', 'release', 'codename', 'architecture', 'publication', 'url', 'filename', 'sha256')) {
        Assert-EzVmManifestString -Value $manifest.$field -Description "Ubuntu source-image manifest field '$field'"
    }

    if ($manifest.release -cne '24.04' -or $manifest.codename -cne 'noble') {
        throw "Ubuntu source-image manifest must pin the 24.04 LTS Noble release."
    }
    if ($manifest.architecture -cne 'amd64') {
        throw "Ubuntu source-image manifest architecture must be 'amd64' for ezvm v0.1."
    }
    if ($manifest.publication -cnotmatch '^[0-9]{8}$') {
        throw "Ubuntu source-image publication must be a dated YYYYMMDD released-image identity."
    }
    if ($manifest.filename -cne 'ubuntu-24.04-server-cloudimg-amd64.img') {
        throw "Ubuntu source-image filename does not match the v0.1 Noble amd64 contract."
    }
    Assert-EzVmArtifactDigest -Algorithm 'SHA256' -ExpectedDigest $manifest.sha256

    $uri = $null
    if (-not [Uri]::TryCreate($manifest.url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -cne 'https') {
        throw 'Ubuntu source-image URL must be an absolute HTTPS URL.'
    }
    $expectedSuffix = '/releases/noble/release-' + $manifest.publication + '/' + $manifest.filename
    if ($uri.Host -cne 'cloud-images.ubuntu.com' -or -not $uri.AbsolutePath.EndsWith($expectedSuffix, [StringComparison]::Ordinal)) {
        throw "Ubuntu source-image URL must use the official dated Noble release directory '$expectedSuffix', not a mutable current/daily alias."
    }
    return $manifest
}

function Get-EzVmSourceImageProvenancePath {
    param([Parameter(Mandatory = $true)][string]$ImagePath)
    return $ImagePath + '.provenance.json'
}

function Invoke-EzVmSourceImageAcquire {
    [CmdletBinding()]
    param(
        [string]$Root = $script:EzVmDefaultRoot,
        [string]$ManifestPath,
        [scriptblock]$Downloader
    )

    $paths = Get-EzVmPaths -Root $Root
    $manifestArguments = @{ Root = $Root }
    if ($PSBoundParameters.ContainsKey('ManifestPath')) { $manifestArguments.ManifestPath = $ManifestPath }
    $manifest = Get-EzVmSourceImageManifest @manifestArguments
    if (-not $PSBoundParameters.ContainsKey('ManifestPath')) { $ManifestPath = $paths.UbuntuManifest }

    $artifactArguments = @{
        Url = $manifest.url
        FileName = $manifest.filename
        Algorithm = 'SHA256'
        ExpectedDigest = $manifest.sha256
        DestinationDirectory = $paths.SourceImages
    }
    if ($null -ne $Downloader) { $artifactArguments.Downloader = $Downloader }
    $artifact = Get-EzVmVerifiedArtifact @artifactArguments

    # Verify once more at the authoritative path before recording trust metadata.
    $observed = Get-EzVmFileDigest -Path $artifact.Path -Algorithm 'SHA256'
    if ($observed -cne $manifest.sha256) {
        throw 'Verified Ubuntu source-image cache changed before provenance could be recorded. Remove the cache entry and retry.'
    }

    $manifestDigest = Get-EzVmFileDigest -Path $ManifestPath -Algorithm 'SHA256'
    $provenancePath = Get-EzVmSourceImageProvenancePath -ImagePath $artifact.Path
    $provenance = $null
    if (Test-Path -LiteralPath $provenancePath -PathType Leaf) {
        try { $provenance = Read-EzVmJson -Path $provenancePath -SchemaVersion 1 } catch { $provenance = $null }
    }
    $provenanceMatches = $false
    if ($null -ne $provenance) {
        $requiredProperties = @('manifestSha256', 'sha256', 'filename')
        $present = @($provenance.PSObject.Properties | ForEach-Object { $_.Name })
        if (@($requiredProperties | Where-Object { $present -cnotcontains $_ }).Count -eq 0) {
            $provenanceMatches =
                $provenance.manifestSha256 -ceq $manifestDigest -and
                $provenance.sha256 -ceq $manifest.sha256 -and
                $provenance.filename -ceq $manifest.filename
        }
    }

    if (-not $provenanceMatches) {
        $value = [pscustomobject][ordered]@{
            schemaVersion = 1
            manifestSha256 = $manifestDigest
            provider = $manifest.provider
            release = $manifest.release
            codename = $manifest.codename
            architecture = $manifest.architecture
            publication = $manifest.publication
            url = $manifest.url
            filename = $manifest.filename
            sha256 = $manifest.sha256
            sizeBytes = [long](Get-Item -LiteralPath $artifact.Path).Length
            recordedAt = [DateTime]::UtcNow.ToString('o')
        }
        Write-EzVmJson -Path $provenancePath -Value $value -SchemaVersion 1
    }

    return [pscustomobject][ordered]@{
        path = $artifact.Path
        provenancePath = $provenancePath
        sha256 = $manifest.sha256
        publication = $manifest.publication
        downloaded = [bool]$artifact.Downloaded
        immutable = $true
    }
}

function Get-EzVmVerifiedSourceImage {
    [CmdletBinding()]
    param([string]$Root = $script:EzVmDefaultRoot)

    $paths = Get-EzVmPaths -Root $Root
    $manifest = Get-EzVmSourceImageManifest -Root $Root
    $path = Join-Path $paths.SourceImages $manifest.filename
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Ubuntu source image is not acquired. Run '.\ezvm.ps1 base acquire' first."
    }
    $observed = Get-EzVmFileDigest -Path $path -Algorithm 'SHA256'
    if ($observed -cne $manifest.sha256) {
        throw "Ubuntu source image cache failed SHA256 verification. Re-run '.\ezvm.ps1 base acquire' to replace the corrupt cache entry."
    }
    return [pscustomobject][ordered]@{
        path = $path
        sha256 = $observed
        publication = $manifest.publication
        provenancePath = Get-EzVmSourceImageProvenancePath -ImagePath $path
    }
}
