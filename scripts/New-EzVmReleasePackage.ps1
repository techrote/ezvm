#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')),
    [AllowEmptyString()][string]$OutputDirectory = '',
    [AllowEmptyString()][string]$Version = ''
)

$ErrorActionPreference = 'Stop'
$rootPath = [IO.Path]::GetFullPath($Root)
if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) {
    throw "Release source root does not exist: $rootPath"
}
if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'Release packaging requires Git so the package is derived from reviewed tracked source only.'
}

$manifestPath = Join-Path $rootPath 'src/EzVm/EzVm.psd1'
$moduleData = Import-PowerShellDataFile -LiteralPath $manifestPath
$projectVersion = [string]$moduleData.PrivateData.EzVmVersion
if ([string]::IsNullOrWhiteSpace($Version)) { $Version = $projectVersion }
if ($Version -cne $projectVersion -or $moduleData.ModuleVersion.ToString() -cne $Version) {
    throw "Release version '$Version' must match both ModuleVersion and EzVmVersion '$projectVersion'."
}
if ($Version -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
    throw "Release version '$Version' is not a stable semantic version."
}

Import-Module (Join-Path $rootPath 'scripts/RepositoryContract.psm1') -Force -ErrorAction Stop
$null = Test-EzVmRepositoryContract -Root $rootPath

$null = & git -C $rootPath diff --quiet --ignore-submodules --
if ($LASTEXITCODE -ne 0) { throw 'Release packaging refuses modified tracked working-tree files. Commit and review the source first.' }
$null = & git -C $rootPath diff --cached --quiet --ignore-submodules --
if ($LASTEXITCODE -ne 0) { throw 'Release packaging refuses staged but uncommitted source. Commit and review it first.' }

$sourceCommit = ((& git -C $rootPath rev-parse HEAD) -join '').Trim()
if ($LASTEXITCODE -ne 0 -or $sourceCommit -cnotmatch '^[a-f0-9]{40}$') { throw 'Could not resolve the exact release source commit.' }
$sourceTree = ((& git -C $rootPath rev-parse 'HEAD^{tree}') -join '').Trim()
if ($LASTEXITCODE -ne 0 -or $sourceTree -cnotmatch '^[a-f0-9]{40}$') { throw 'Could not resolve the exact release source tree.' }

$trackedText = ((& git -C $rootPath -c core.quotepath=false ls-files --cached -z) -join [Environment]::NewLine)
if ($LASTEXITCODE -ne 0) { throw 'Could not enumerate tracked release source.' }
$tracked = @($trackedText.Split([char[]]@([char]0), [StringSplitOptions]::RemoveEmptyEntries))

$rootFiles = @('ezvm.ps1', 'README.md', 'THIRD-PARTY-NOTICES.md')
$prefixes = @('config/', 'docs/', 'guest/', 'manifests/', 'src/')
$selected = New-Object 'System.Collections.Generic.List[string]'
foreach ($relative in $tracked) {
    $include = $rootFiles -ccontains $relative
    if (-not $include) {
        foreach ($prefix in $prefixes) {
            if ($relative.StartsWith($prefix, [StringComparison]::Ordinal)) { $include = $true; break }
        }
    }
    if ($include) { $selected.Add($relative) }
}
$selected = @($selected.ToArray() | Sort-Object)

foreach ($required in @(
    'ezvm.ps1',
    'README.md',
    'THIRD-PARTY-NOTICES.md',
    'docs/GETTING-STARTED.md',
    'docs/RELEASE-v0.1.0.md',
    'docs/WHPX-QUALIFICATION.md',
    'src/EzVm/EzVm.psd1',
    'manifests/qemu-windows.json',
    'manifests/ubuntu-noble-amd64.json'
)) {
    if ($selected -cnotcontains $required) { throw "Release package is missing required tracked source '$required'." }
}

function Get-EzVmReleaseSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose(); $stream.Dispose() }
}

$files = New-Object 'System.Collections.Generic.List[object]'
foreach ($relative in $selected) {
    $absolute = Join-Path $rootPath $relative
    if (-not (Test-Path -LiteralPath $absolute -PathType Leaf)) { throw "Tracked release source disappeared: $relative" }
    $item = Get-Item -LiteralPath $absolute -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Release packaging refuses reparse-point source: $relative" }
    $files.Add([pscustomobject][ordered]@{
        path = $relative.Replace('\', '/')
        sizeBytes = [long]$item.Length
        sha256 = Get-EzVmReleaseSha256 -Path $absolute
    })
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $rootPath 'artifacts/release'
}
$outputPath = [IO.Path]::GetFullPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($outputPath)

$packageName = 'ezvm-' + $Version
$zipPath = Join-Path $outputPath ($packageName + '.zip')
$checksumPath = $zipPath + '.sha256'
if ([IO.File]::Exists($zipPath)) { [IO.File]::Delete($zipPath) }
if ([IO.File]::Exists($checksumPath)) { [IO.File]::Delete($checksumPath) }

$metadata = [pscustomobject][ordered]@{
    schemaVersion = 1
    project = 'ezvm'
    version = $Version
    sourceCommit = $sourceCommit
    sourceTree = $sourceTree
    packageRoot = $packageName
    thirdPartyBinariesIncluded = $false
    files = @($files.ToArray())
}
$utf8 = New-Object Text.UTF8Encoding($false)
$metadataBytes = $utf8.GetBytes(($metadata | ConvertTo-Json -Depth 8 -Compress) + [Environment]::NewLine)

Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
$fixedTimestamp = New-Object DateTimeOffset(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
$fileStream = [IO.File]::Open($zipPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
$archive = New-Object IO.Compression.ZipArchive($fileStream, [IO.Compression.ZipArchiveMode]::Create, $false)
try {
    foreach ($record in $files) {
        $entryName = $packageName + '/' + $record.path
        $entry = $archive.CreateEntry($entryName, [IO.Compression.CompressionLevel]::NoCompression)
        $entry.LastWriteTime = $fixedTimestamp
        try { $entry.ExternalAttributes = 0 } catch { }
        $entryStream = $entry.Open()
        try {
            $relativePlatform = $record.path.Replace('/', [IO.Path]::DirectorySeparatorChar)
            $bytes = [IO.File]::ReadAllBytes((Join-Path $rootPath $relativePlatform))
            $entryStream.Write($bytes, 0, $bytes.Length)
        }
        finally { $entryStream.Dispose() }
    }

    $metadataEntry = $archive.CreateEntry(($packageName + '/RELEASE-METADATA.json'), [IO.Compression.CompressionLevel]::NoCompression)
    $metadataEntry.LastWriteTime = $fixedTimestamp
    try { $metadataEntry.ExternalAttributes = 0 } catch { }
    $metadataStream = $metadataEntry.Open()
    try { $metadataStream.Write($metadataBytes, 0, $metadataBytes.Length) }
    finally { $metadataStream.Dispose() }
}
finally {
    $archive.Dispose()
    $fileStream.Dispose()
}

$packageSha256 = Get-EzVmReleaseSha256 -Path $zipPath
[IO.File]::WriteAllText($checksumPath, ($packageSha256 + '  ' + [IO.Path]::GetFileName($zipPath) + [Environment]::NewLine), $utf8)

return [pscustomobject][ordered]@{
    Version = $Version
    SourceCommit = $sourceCommit
    SourceTree = $sourceTree
    PackagePath = $zipPath
    ChecksumPath = $checksumPath
    PackageSha256 = $packageSha256
    FileCount = $files.Count
}
