#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')][string]$Repository,
    [Parameter(Mandatory = $true)][ValidatePattern('^v[0-9]+\.[0-9]+\.[0-9]+$')][string]$Tag,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-f0-9]{40}$')][string]$CommitSha,
    [Parameter(Mandatory = $true)][string]$Token,
    [Parameter(Mandatory = $true)][string]$ReleaseNotesPath,
    [Parameter(Mandatory = $true)][string[]]$AssetPaths
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Token)) { throw 'GitHub release publication requires the workflow GITHUB_TOKEN.' }
if (-not (Test-Path -LiteralPath $ReleaseNotesPath -PathType Leaf)) { throw 'Release notes file is missing.' }

$version = $Tag.Substring(1)
$zipName = 'ezvm-' + $version + '.zip'
$checksumName = $zipName + '.sha256'
if ($AssetPaths.Count -ne 2) { throw 'Release publication requires exactly the source ZIP and its SHA-256 sidecar.' }

$assets = @{}
foreach ($assetPath in $AssetPaths) {
    $full = [IO.Path]::GetFullPath($assetPath)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Release asset is missing: $full" }
    $name = [IO.Path]::GetFileName($full)
    if ($name -cnotin @($zipName, $checksumName) -or $assets.ContainsKey($name)) {
        throw "Release assets must be exactly '$zipName' and '$checksumName', once each."
    }
    $assets[$name] = $full
}
if ($assets.Count -ne 2 -or -not $assets.ContainsKey($zipName) -or -not $assets.ContainsKey($checksumName)) {
    throw 'Release asset set is incomplete.'
}

function Get-EzVmPublishedAssetSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose(); $stream.Dispose() }
}

$zipDigest = Get-EzVmPublishedAssetSha256 -Path $assets[$zipName]
$sidecar = [IO.File]::ReadAllText($assets[$checksumName], (New-Object Text.UTF8Encoding($false, $true))).Trim()
$expectedSidecar = $zipDigest + '  ' + $zipName
if ($sidecar -cne $expectedSidecar) { throw 'Release checksum sidecar does not match the exact ZIP bytes; refusing publication.' }

$headers = @{
    Authorization = 'Bearer ' + $Token
    Accept = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent' = 'ezvm-release-publisher'
}
$api = 'https://api.github.com/repos/' + $Repository
$escapedTag = [Uri]::EscapeDataString($Tag)

try {
    $existing = Invoke-RestMethod -Uri ($api + '/releases/tags/' + $escapedTag) -Headers $headers -Method Get -ErrorAction Stop
    if ($null -ne $existing) {
        throw "GitHub release '$Tag' already exists. Refusing to mutate an existing draft or published release automatically."
    }
}
catch {
    $status = $null
    try { $status = [int]$_.Exception.Response.StatusCode } catch { }
    if ($status -ne 404) { throw }
}

$notes = [IO.File]::ReadAllText([IO.Path]::GetFullPath($ReleaseNotesPath), (New-Object Text.UTF8Encoding($false, $true)))
$newLine = [Environment]::NewLine
$body = 'Release commit: ' + $CommitSha + $newLine + 'Release tag: ' + $Tag + $newLine + $newLine + $notes
$payload = @{
    tag_name = $Tag
    target_commitish = $CommitSha
    name = 'ezvm ' + $version
    body = $body
    draft = $true
    prerelease = $false
    generate_release_notes = $false
} | ConvertTo-Json -Depth 4

$release = Invoke-RestMethod -Uri ($api + '/releases') -Headers $headers -Method Post -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($payload))
if ($null -eq $release -or [string]::IsNullOrWhiteSpace([string]$release.upload_url) -or -not [bool]$release.draft) {
    throw 'GitHub did not return the expected draft release upload endpoint.'
}

$uploadBase = ([string]$release.upload_url) -replace '\{\?name,label\}$', ''
try {
    foreach ($name in @($zipName, $checksumName)) {
        $full = $assets[$name]
        $uploadUri = $uploadBase + '?name=' + [Uri]::EscapeDataString($name)
        $contentType = if ($name -ceq $zipName) { 'application/zip' } else { 'text/plain' }
        $bytes = [IO.File]::ReadAllBytes($full)
        $uploaded = Invoke-RestMethod -Uri $uploadUri -Headers $headers -Method Post -ContentType $contentType -Body $bytes
        if ($null -eq $uploaded -or [string]$uploaded.name -cne $name -or [long]$uploaded.size -ne [long]$bytes.Length) {
            throw "GitHub did not confirm the exact release asset '$name'."
        }
    }
}
catch {
    throw [InvalidOperationException]::new(
        "Release asset upload failed; GitHub release $Tag remains a draft and must not be presented as published. $($_.Exception.Message)",
        $_.Exception)
}

$publishPayload = @{ draft = $false } | ConvertTo-Json -Compress
$published = Invoke-RestMethod -Uri ($api + '/releases/' + [long]$release.id) -Headers $headers -Method Patch -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($publishPayload))
if ($null -eq $published -or [bool]$published.draft -or [string]$published.tag_name -cne $Tag) {
    throw 'GitHub did not confirm publication of the completed release; inspect the retained release state.'
}

return [pscustomobject][ordered]@{
    Tag = $Tag
    CommitSha = $CommitSha
    ReleaseId = [long]$published.id
    HtmlUrl = [string]$published.html_url
    PackageSha256 = $zipDigest
    AssetCount = 2
    Published = $true
}
