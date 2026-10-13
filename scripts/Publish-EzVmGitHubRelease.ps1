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
if ($AssetPaths.Count -eq 0) { throw 'Release publication requires at least one asset.' }

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
        throw "GitHub release '$Tag' already exists. Refusing to mutate an already published release automatically."
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
    name = 'ezvm ' + $Tag.Substring(1)
    body = $body
    draft = $false
    prerelease = $false
    generate_release_notes = $false
} | ConvertTo-Json -Depth 4

$release = Invoke-RestMethod -Uri ($api + '/releases') -Headers $headers -Method Post -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($payload))
if ($null -eq $release -or [string]::IsNullOrWhiteSpace([string]$release.upload_url)) {
    throw 'GitHub did not return a release upload endpoint.'
}

$uploadBase = ([string]$release.upload_url) -replace '\{\?name,label\}$', ''
foreach ($assetPath in $AssetPaths) {
    $full = [IO.Path]::GetFullPath($assetPath)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "Release asset is missing: $full"
    }
    $name = [IO.Path]::GetFileName($full)
    if ($name -cnotmatch '^ezvm-[0-9]+\.[0-9]+\.[0-9]+\.zip(?:\.sha256)?$') {
        throw "Release asset name is outside the reviewed package contract: $name"
    }
    $uploadUri = $uploadBase + '?name=' + [Uri]::EscapeDataString($name)
    $contentType = if ($name.EndsWith('.zip', [StringComparison]::OrdinalIgnoreCase)) { 'application/zip' } else { 'text/plain' }
    $bytes = [IO.File]::ReadAllBytes($full)
    $null = Invoke-RestMethod -Uri $uploadUri -Headers $headers -Method Post -ContentType $contentType -Body $bytes
}

return [pscustomobject][ordered]@{
    Tag = $Tag
    CommitSha = $CommitSha
    ReleaseId = [long]$release.id
    HtmlUrl = [string]$release.html_url
    AssetCount = $AssetPaths.Count
}
