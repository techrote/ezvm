#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourceRoot,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [string]$ExpectedSourceCommit = '',
    [ValidateSet(16, 128)][int]$FileMiB = 128,
    [ValidateRange(2, 8)][int]$Rounds = 4,
    [ValidateRange(0, 2000)][int]$SmallFileCount = 1000,
    [int]$OrderSeed = 284217,
    [switch]$AllowNonWindowsSmoke
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2.0
if (($Rounds % 2) -ne 0) { throw 'Rounds must be even so each provider occupies each trial position equally.' }
$shaWindowsHost = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
if (-not $shaWindowsHost -and -not $AllowNonWindowsSmoke) { throw 'Windows is required. A non-Windows smoke run cannot qualify the Windows provider change.' }
if ($PSVersionTable.PSVersion.Major -notin @(5, 7)) { throw 'Use Windows PowerShell 5.1 or the repository-pinned PowerShell 7.' }
if ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -ne 1) { throw 'The desktop comparison requires PowerShell 5.1.' }

function Get-ShaProvenanceDigest {
    param([string]$Path)
    $stream = $hash = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $hash = [Security.Cryptography.SHA256]::Create()
        return ([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    }
    finally { if ($hash) { $hash.Dispose() }; if ($stream) { $stream.Dispose() } }
}

function New-ShaBenchmarkProvider {
    param([ValidateSet('legacy', 'candidate')][string]$Variant, [ValidateSet('SHA256', 'SHA512')][string]$Algorithm)
    if ($Variant -eq 'legacy') { return [Security.Cryptography.HashAlgorithm]::Create($Algorithm) }
    if ($PSVersionTable.PSEdition -eq 'Desktop' -and [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        if ($Algorithm -eq 'SHA256') { return [Security.Cryptography.SHA256Cng]::new() }
        return [Security.Cryptography.SHA512Cng]::new()
    }
    if ($Algorithm -eq 'SHA256') { return [Security.Cryptography.SHA256]::Create() }
    return [Security.Cryptography.SHA512]::Create()
}

function Get-BalancedSchedule {
    param([int]$Count, [int]$Seed)
    $random = [Random]::new($Seed)
    for ($pair = 0; $pair -lt ($Count / 2); $pair++) {
        $first = @('legacy', 'candidate')
        if ($random.Next(2) -eq 1) { $first = @('candidate', 'legacy') }
        [pscustomobject]@{ round = 2 * $pair + 1; order = $first }
        [pscustomobject]@{ round = 2 * $pair + 2; order = @($first[1], $first[0]) }
    }
}

function Get-ShaSourceIdentity {
    param([string]$Root)
    $head = ((& git -C $Root rev-parse HEAD) -join '').Trim()
    if ($LASTEXITCODE -ne 0 -or $head -cnotmatch '^[a-f0-9]{40}$') { throw 'Cannot identify the source commit.' }
    $tree = ((& git -C $Root rev-parse 'HEAD^{tree}') -join '').Trim()
    if ($LASTEXITCODE -ne 0 -or $tree -cnotmatch '^[a-f0-9]{40}$') { throw 'Cannot identify the source tree.' }
    $dirty = @(& git -C $Root status --porcelain --untracked-files=all)
    if ($LASTEXITCODE -ne 0 -or $dirty.Count -ne 0) { throw 'The benchmark needs a clean tracked checkout, including its own published script.' }
    if ($ExpectedSourceCommit -and $head -cne $ExpectedSourceCommit) { throw 'Source HEAD does not match ExpectedSourceCommit.' }
    $files = @(Get-ChildItem -LiteralPath (Join-Path $Root 'src/EzVm') -File -Recurse | Sort-Object FullName | ForEach-Object {
        [pscustomobject]@{ path = $_.FullName.Substring($Root.Length + 1).Replace('\', '/'); sha256 = Get-ShaProvenanceDigest $_.FullName }
    })
    return [pscustomobject]@{ commit = $head; tree = $tree; moduleFiles = $files;
        downloadTestsSha256 = Get-ShaProvenanceDigest (Join-Path $Root 'tests/Download.Tests.ps1');
        harnessSha256 = Get-ShaProvenanceDigest (Join-Path $Root 'tests/TestHarness.ps1') }
}

function Invoke-ShaFileTrial {
    param([string]$Variant, [string]$Algorithm, [int]$Round, [int]$Position, [string]$Phase = 'measured')
    $stream = $hash = $null
    $process = [Diagnostics.Process]::GetCurrentProcess()
    $process.Refresh()
    $cpuBefore = $process.TotalProcessorTime.TotalMilliseconds
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        # Keep these exact open/share semantics identical to Get-EzVmFileDigest.
        $stream = [IO.File]::Open($bulkPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $hash = New-ShaBenchmarkProvider -Variant $Variant -Algorithm $Algorithm
        if ($null -eq $hash) { throw 'Requested hash provider is unavailable.' }
        $provider = $hash.GetType().AssemblyQualifiedName
        $digest = ([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
        $bytesRead = $stream.Position
    }
    finally {
        if ($hash) { $hash.Dispose() }; if ($stream) { $stream.Dispose() }
        $clock.Stop(); $process.Refresh()
        $cpuMs = $process.TotalProcessorTime.TotalMilliseconds - $cpuBefore
        $process.Dispose()
    }
    if ($bytesRead -ne $fileBytes -or $digest -cne $knownDigests[$Algorithm]) { throw 'Fresh full-file read or independent known digest check failed.' }
    $row = [pscustomobject]@{ phase = $Phase; variant = $Variant; algorithm = $Algorithm; round = $Round; position = $Position;
        provider = $provider; bytesRead = $bytesRead; digest = $digest; wallMilliseconds = $clock.Elapsed.TotalMilliseconds;
        cpuMilliseconds = $cpuMs; mibPerSecond = $FileMiB / $clock.Elapsed.TotalSeconds }
    [void]$fileTrials.Add($row)
    Write-Host ('SHA_FILE_TRIAL=' + ($row | ConvertTo-Json -Compress))
}

function Import-ShaVariantModule {
    param([string]$Variant)
    if ($script:shaActiveModule) { Remove-Module -ModuleInfo $script:shaActiveModule -Force; $script:shaActiveModule = $null }
    $script:shaActiveModule = Import-Module -Name $modulePaths[$Variant] -PassThru -Force -Global -DisableNameChecking
    if ($null -eq $script:shaActiveModule) { throw 'Temporary module import failed.' }
    return $script:shaActiveModule
}

function Invoke-ShaPayloadTrial {
    param([string]$Variant, [int]$Round, [int]$Position, [string]$Phase = 'measured')
    $module = Import-ShaVariantModule $Variant
    $process = [Diagnostics.Process]::GetCurrentProcess()
    $process.Refresh(); $cpuBefore = $process.TotalProcessorTime.TotalMilliseconds
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try { & $module { param($runtime, $manifest) Assert-EzVmQemuPayloadIntegrity -RuntimeDirectory $runtime -ManifestPath $manifest } $runtimePath $manifestPath }
    finally {
        $clock.Stop(); $process.Refresh()
        $cpuMs = $process.TotalProcessorTime.TotalMilliseconds - $cpuBefore
        $process.Dispose()
    }
    $row = [pscustomobject]@{ phase = $Phase; variant = $Variant; algorithm = 'SHA256'; round = $Round; position = $Position;
        outcome = 'pass'; payloadFileCount = $SmallFileCount + 4; payloadBytes = $fileBytes + 4096L * ($SmallFileCount + 3);
        wallMilliseconds = $clock.Elapsed.TotalMilliseconds; cpuMilliseconds = $cpuMs }
    [void]$payloadTrials.Add($row)
    Write-Host ('SHA_PAYLOAD_TRIAL=' + ($row | ConvertTo-Json -Compress))
}

function Get-TrialSummary {
    param([object[]]$Rows)
    foreach ($group in @($Rows | Where-Object { $_.phase -eq 'measured' } | Group-Object algorithm, variant)) {
        $wall = @($group.Group.wallMilliseconds | Sort-Object)
        $cpu = @($group.Group.cpuMilliseconds | Sort-Object)
        $n = $wall.Count
        [pscustomobject]@{ algorithm = $group.Group[0].algorithm; variant = $group.Group[0].variant; trials = $n;
            medianWallMilliseconds = ($wall[($n / 2) - 1] + $wall[$n / 2]) / 2;
            minWallMilliseconds = $wall[0]; maxWallMilliseconds = $wall[$n - 1];
            medianCpuMilliseconds = ($cpu[($n / 2) - 1] + $cpu[$n / 2]) / 2 }
    }
}

$SourceRoot = [IO.Path]::GetFullPath($SourceRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $OutputDirectory) { throw 'OutputDirectory must be new; prior receipts are never overwritten.' }
if ($OutputDirectory.StartsWith($SourceRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Keep benchmark evidence outside the checkout.' }
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$work = Join-Path ([IO.Path]::GetTempPath()) ('ezvm-sha-preflight-' + [Guid]::NewGuid().ToString('N'))
$ownerToken = [Guid]::NewGuid().ToString('N')
$fileTrials = New-Object 'System.Collections.Generic.List[object]'
$payloadTrials = New-Object 'System.Collections.Generic.List[object]'
$negativeControls = New-Object 'System.Collections.Generic.List[object]'
$regressions = New-Object 'System.Collections.Generic.List[object]'
$script:shaActiveModule = $null
$modulePaths = @{}
$receipt = [ordered]@{ schemaVersion = 1; kind = 'ezvm-sha-provider-preflight'; outcome = 'failed';
    scope = 'Controlled synthetic Windows file and QEMU inventory hashing; no QEMU execution, guest, WHPX or full release qualification.';
    startedAt = [DateTime]::UtcNow.ToString('o'); source = $null; benchmarkSha256 = Get-ShaProvenanceDigest $PSCommandPath;
    environment = [ordered]@{ windows = $shaWindowsHost; osVersion = [Environment]::OSVersion.VersionString;
        powerShellVersion = $PSVersionTable.PSVersion.ToString(); edition = $PSVersionTable.PSEdition;
        clrVersion = [Environment]::Version.ToString(); process64Bit = [Environment]::Is64BitProcess;
        logicalProcessors = [Environment]::ProcessorCount; cpuModel = $null };
    parameters = [ordered]@{ fileMiB = $FileMiB; rounds = $Rounds; smallFileCount = $SmallFileCount; orderSeed = $OrderSeed;
        streamMode = 'Open / Read / Share.Read'; contentPattern = 'Bytes 0..255 repeated; fixed independent SHA256/SHA512 expectations';
        fileAttributes = ''; knownDigests = $null; cachePolicy = 'One recorded warmup per provider; OS caches are not flushed.';
        ordering = 'Random seeded AB/BA pairs; each provider occupies each position equally.' };
    moduleVariants = @(); fileTrials = @(); fileSummary = @(); payloadTrials = @(); payloadSummary = @();
    negativeControls = @(); existingDownloadTests = @(); sourceUnchanged = $false; fixtureRemoved = $false; reason = ''; exitCode = 1 }
if (-not $shaWindowsHost) { $receipt.scope = 'NON-WINDOWS SMOKE ONLY. No Windows provider or Windows performance evidence.' }
$exitCode = 1
try {
    $receipt.source = Get-ShaSourceIdentity $SourceRoot
    if ($shaWindowsHost) { $receipt.environment.cpuModel = @(Get-CimInstance Win32_Processor | ForEach-Object { $_.Name.Trim() }) }
    if ($PSVersionTable.PSVersion.Major -eq 7) {
        $tooling = Get-Content -LiteralPath (Join-Path $SourceRoot 'tests/tooling.json') -Raw | ConvertFrom-Json
        if ($PSVersionTable.PSVersion.ToString() -cne $tooling.powerShell7.version) { throw 'The PowerShell 7 comparison must use the repository-pinned version.' }
    }
    [void][IO.Directory]::CreateDirectory($work)
    [IO.File]::WriteAllText((Join-Path $work 'owner.txt'), $ownerToken)
    $runtimePath = Join-Path $work 'synthetic-runtime'
    [void][IO.Directory]::CreateDirectory($runtimePath)
    $bulkPath = Join-Path $runtimePath 'bulk.bin'
    $fileBytes = 1MB * [long]$FileMiB
    $knownDigests = if ($FileMiB -eq 128) { @{
        SHA256 = 'a626d17da2e502f5b4b8e3ebd23f0bf9daef6255688d8e0bb482b3ae3794a682';
        SHA512 = 'c0948e653e8baca2b4eb0a6f46ba83ad7e806ca6ecac3bce2abd1d6dd2799bbf99be906d03b103a59acd9e55e1cd9780931ec2627807bbcb59dbfdc59fb2befe'
    } } else { @{
        SHA256 = '341aacac661ccb210720bedaa9ead5d668fe5ea41a73532fc147c71e34040df1';
        SHA512 = '3f8349df130ba8deb450e2907e0d5814103a01490fde3d9d7b5c1083a8ca6ed44757e51bdb70767cdce3c7dfafaccc526a7f2798a07208ecdfbac14e82ed88e9'
    } }
    $receipt.parameters.knownDigests = $knownDigests
    # Public, deterministic bytes 0..255 repeated. Expected digests were independently
    # calculated with Python hashlib. The fixture is neither sparse nor compressed.
    $buffer = New-Object byte[] (1MB)
    [Array]::Copy([byte[]](0..255), 0, $buffer, 0, 256)
    for ($filled = 256; $filled -lt $buffer.Length; $filled *= 2) { [Array]::Copy($buffer, 0, $buffer, $filled, $filled) }
    $writer = [IO.File]::Open($bulkPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { for ($i = 0; $i -lt $FileMiB; $i++) { $writer.Write($buffer, 0, $buffer.Length) }; $writer.Flush($true) }
    finally { $writer.Dispose() }
    $bulkAttributes = [IO.File]::GetAttributes($bulkPath)
    if (($bulkAttributes -band ([IO.FileAttributes]::Compressed -bor [IO.FileAttributes]::SparseFile)) -ne 0) { throw 'Controlled benchmark input must be an ordinary uncompressed, nonsparse file.' }
    $receipt.parameters.fileAttributes = $bulkAttributes.ToString()
    foreach ($algorithm in @('SHA256', 'SHA512')) {
        foreach ($variant in @('legacy', 'candidate')) { Invoke-ShaFileTrial $variant $algorithm 0 0 'warmup' }
        $scheduleSeed = $OrderSeed
        if ($algorithm -eq 'SHA512') { $scheduleSeed++ }
        foreach ($trial in @(Get-BalancedSchedule $Rounds $scheduleSeed)) {
            for ($position = 0; $position -lt 2; $position++) { Invoke-ShaFileTrial $trial.order[$position] $algorithm $trial.round ($position + 1) }
        }
    }

    $oldFactory = '$algorithmInstance = [Security.Cryptography.HashAlgorithm]::Create($Algorithm)'
    $newFactory = @'
$algorithmInstance = if ($PSVersionTable.PSEdition -eq 'Desktop' -and [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            if ($Algorithm -eq 'SHA256') { [Security.Cryptography.SHA256Cng]::new() } else { [Security.Cryptography.SHA512Cng]::new() }
        } else {
            if ($Algorithm -eq 'SHA256') { [Security.Cryptography.SHA256]::Create() } else { [Security.Cryptography.SHA512]::Create() }
        }
'@
    $sourceModule = Join-Path $SourceRoot 'src/EzVm'
    $sourceDownload = [IO.File]::ReadAllText((Join-Path $sourceModule 'Download.ps1'))
    if ([regex]::Matches($sourceDownload, [regex]::Escape($oldFactory)).Count -ne 1) { throw 'Expected exactly one original factory; do not silently benchmark an already modified implementation.' }
    if ($sourceDownload.Contains("`r`n")) { $newFactory = $newFactory.Replace("`r`n", "`n").Replace("`n", "`r`n") }
    $candidateDownload = $sourceDownload.Replace($oldFactory, $newFactory)
    foreach ($variant in @('legacy', 'candidate')) {
        $variantRoot = Join-Path $work $variant
        [void][IO.Directory]::CreateDirectory($variantRoot)
        Copy-Item -LiteralPath $sourceModule -Destination $variantRoot -Recurse
        $modulePaths[$variant] = Join-Path $variantRoot 'EzVm/EzVm.psd1'
        $copyDownload = Join-Path $variantRoot 'EzVm/Download.ps1'
        if ($variant -eq 'candidate') { [IO.File]::WriteAllText($copyDownload, $candidateDownload, (New-Object Text.UTF8Encoding($false))) }
        $changed = New-Object 'System.Collections.Generic.List[string]'
        foreach ($original in @(Get-ChildItem -LiteralPath $sourceModule -File -Recurse)) {
            $relative = $original.FullName.Substring($sourceModule.Length + 1)
            if ((Get-ShaProvenanceDigest $original.FullName) -cne (Get-ShaProvenanceDigest (Join-Path (Join-Path $variantRoot 'EzVm') $relative))) { [void]$changed.Add($relative.Replace('\', '/')) }
        }
        if (($variant -eq 'legacy' -and $changed.Count -ne 0) -or
            ($variant -eq 'candidate' -and ($changed.Count -ne 1 -or $changed[0] -cne 'Download.ps1'))) { throw 'Temporary variant changed files outside the algorithm factory source.' }
        if ($variant -eq 'candidate' -and [IO.File]::ReadAllText($copyDownload).Replace($newFactory, $oldFactory) -cne $sourceDownload) { throw 'Candidate changed text outside the algorithm factory.' }
        $provider = New-ShaBenchmarkProvider $variant 'SHA256'
        try { $payloadProvider = $provider.GetType().AssemblyQualifiedName } finally { $provider.Dispose() }
        $receipt.moduleVariants += [pscustomobject]@{ variant = $variant; payloadSha256Provider = $payloadProvider; changedFiles = @($changed.ToArray()); downloadSha256 = Get-ShaProvenanceDigest $copyDownload;
            integritySha256 = Get-ShaProvenanceDigest (Join-Path $variantRoot 'EzVm/QemuIntegrity.ps1') }
    }

    $smallBytes = New-Object byte[] 4096
    [Array]::Copy($buffer, 0, $smallBytes, 0, $smallBytes.Length)
    foreach ($name in @('qemu-system-x86_64.exe', 'qemu-img.exe', 'dependency.dll')) { [IO.File]::WriteAllBytes((Join-Path $runtimePath $name), $smallBytes) }
    for ($i = 0; $i -lt $SmallFileCount; $i++) {
        $directory = Join-Path $runtimePath ('data/' + ($i % 10))
        [void][IO.Directory]::CreateDirectory($directory)
        [IO.File]::WriteAllBytes((Join-Path $directory ('file-{0:D4}.bin' -f $i)), $smallBytes)
    }
    $manifestPath = Join-Path $work 'synthetic-manifest.json'
    [IO.File]::WriteAllText($manifestPath, '{"schemaVersion":1,"fixture":"synthetic payload; no executable or guest"}', (New-Object Text.UTF8Encoding($false)))
    $module = Import-ShaVariantModule 'legacy'
    & $module {
        param($runtime, $manifest)
        $manifestDigest = Get-EzVmFileDigest -Path $manifest -Algorithm SHA256
        $inventoryDigest = Write-EzVmQemuPayloadInventory -RuntimeDirectory $runtime -ManifestDigest $manifestDigest
        Write-EzVmJson -Path (Join-Path $runtime 'ezvm-provenance.json') -Value ([pscustomobject]@{
            schemaVersion = 1; manifestSha256 = $manifestDigest; payloadManifestSha256 = $inventoryDigest })
    } $runtimePath $manifestPath
    $inventoryBefore = Get-ShaProvenanceDigest (Join-Path $runtimePath 'ezvm-payload.json')
    $provenanceBefore = Get-ShaProvenanceDigest (Join-Path $runtimePath 'ezvm-provenance.json')
    foreach ($variant in @('legacy', 'candidate')) { Invoke-ShaPayloadTrial $variant 0 0 'warmup' }
    foreach ($trial in @(Get-BalancedSchedule $Rounds ($OrderSeed + 2))) {
        for ($position = 0; $position -lt 2; $position++) { Invoke-ShaPayloadTrial $trial.order[$position] $trial.round ($position + 1) }
    }

    foreach ($variant in @('legacy', 'candidate')) {
        $module = Import-ShaVariantModule $variant
        # Seed a successful same-module use before tampering: a cached earlier
        # success must not authorize changed bytes on the next invocation.
        & $module { param($r, $m) Assert-EzVmQemuPayloadIntegrity -RuntimeDirectory $r -ManifestPath $m } $runtimePath $manifestPath
        # Change bytes, preserve size and restore timestamp; fresh validation must fail.
        $dependency = Join-Path $runtimePath 'dependency.dll'
        $originalTimestamp = [IO.File]::GetLastWriteTimeUtc($dependency)
        $tampered = [byte[]]$smallBytes.Clone(); $tampered[0] = $tampered[0] -bxor 90
        $caught = $null
        try {
            [IO.File]::WriteAllBytes($dependency, $tampered)
            [IO.File]::SetLastWriteTimeUtc($dependency, $originalTimestamp)
            if ((Get-Item -LiteralPath $dependency).Length -ne 4096 -or [IO.File]::GetLastWriteTimeUtc($dependency) -ne $originalTimestamp) { throw 'Tamper control did not preserve size and timestamp.' }
            try { & $module { param($r, $m) Assert-EzVmQemuPayloadIntegrity -RuntimeDirectory $r -ManifestPath $m } $runtimePath $manifestPath }
            catch { $caught = $_ }
            if ($null -eq $caught -or $caught.Exception.Message -notmatch 'payload digest or size mismatch') { throw 'Same-size, same-time changed bytes were not rejected by the production validator.' }
        }
        finally { [IO.File]::WriteAllBytes($dependency, $smallBytes); [IO.File]::SetLastWriteTimeUtc($dependency, $originalTimestamp) }
        & $module { param($r, $m) Assert-EzVmQemuPayloadIntegrity -RuntimeDirectory $r -ManifestPath $m } $runtimePath $manifestPath
        [void]$negativeControls.Add([pscustomobject]@{ variant = $variant; case = 'same-size same-timestamp byte mutation'; rejected = $true; restoredPayloadPass = $true })

        # Execute the unchanged first-party download tests against this temporary module.
        $script:EzVmRepositoryRoot = $SourceRoot
        . (Join-Path $SourceRoot 'tests/TestHarness.ps1')
        . (Join-Path $SourceRoot 'tests/Download.Tests.ps1')
        if ($script:EzVmTestCases.Count -lt 7 -or @($script:EzVmTestCases | Where-Object { $_.SkipReason }).Count -ne 0) { throw 'Expected the existing download tests with no skips.' }
        Invoke-EzVmTestSuite
        foreach ($algorithm in @('SHA256', 'sha256', 'SHA512', 'sha512')) {
            $provider = New-ShaBenchmarkProvider 'legacy' $algorithm
            try { $expected = ([BitConverter]::ToString($provider.ComputeHash($smallBytes))).Replace('-', '').ToLowerInvariant() }
            finally { $provider.Dispose() }
            $observed = & $module { param($p, $a) Get-EzVmFileDigest -Path $p -Algorithm $a } $dependency $algorithm
            if ($observed -cne $expected) { throw 'The production hash function lost case-insensitive algorithm compatibility.' }
        }
        [void]$regressions.Add([pscustomobject]@{ variant = $variant; source = 'tests/Download.Tests.ps1'; passed = $script:EzVmTestCases.Count;
            failed = 0; skipped = 0; algorithmCaseChecks = 4 })
    }
    if ((Get-ShaProvenanceDigest (Join-Path $runtimePath 'ezvm-payload.json')) -cne $inventoryBefore -or
        (Get-ShaProvenanceDigest (Join-Path $runtimePath 'ezvm-provenance.json')) -cne $provenanceBefore) { throw 'Read-only validation changed a trust receipt.' }
    Invoke-ShaFileTrial 'candidate' 'SHA256' 0 0 'final-byte-check'
    if ((Get-ShaSourceIdentity $SourceRoot | ConvertTo-Json -Depth 8 -Compress) -cne ($receipt.source | ConvertTo-Json -Depth 8 -Compress)) { throw 'Original checkout/module/test source changed during measurement.' }
    $receipt.sourceUnchanged = $true
    $receipt.outcome = if ($shaWindowsHost) { 'pass' } else { 'non-windows-smoke-pass' }
    $exitCode = 0
}
catch { $receipt.reason = $_.Exception.Message; Write-Host ('SHA_PREFLIGHT_FAILED=' + $receipt.reason); Write-Host $_.ScriptStackTrace }
finally {
    if ($script:shaActiveModule) { Remove-Module -ModuleInfo $script:shaActiveModule -Force; $script:shaActiveModule = $null }
    try {
        if (Test-Path -LiteralPath $work) {
            $ownerPath = Join-Path $work 'owner.txt'
            if (-not [IO.File]::Exists($ownerPath) -or [IO.File]::ReadAllText($ownerPath) -cne $ownerToken) { throw 'Owned fixture marker is missing; refusing cleanup.' }
            Remove-Item -LiteralPath $work -Recurse -Force
        }
        $receipt.fixtureRemoved = -not (Test-Path -LiteralPath $work)
    }
    catch { $receipt.reason += ' Cleanup: ' + $_.Exception.Message; $receipt.outcome = 'failed'; $exitCode = 1 }
    $receipt.fileTrials = @($fileTrials.ToArray()); $receipt.fileSummary = @(Get-TrialSummary @($fileTrials.ToArray()))
    $receipt.payloadTrials = @($payloadTrials.ToArray()); $receipt.payloadSummary = @(Get-TrialSummary @($payloadTrials.ToArray()))
    $receipt.negativeControls = @($negativeControls.ToArray()); $receipt.existingDownloadTests = @($regressions.ToArray())
    $receipt.endedAt = [DateTime]::UtcNow.ToString('o'); $receipt.exitCode = $exitCode
    $receiptPath = Join-Path $OutputDirectory 'receipt.json'
    [IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding($false)))
    Write-Host ('SHA_PREFLIGHT_SUMMARY=' + ([pscustomobject]@{ outcome = $receipt.outcome; file = $receipt.fileSummary; payload = $receipt.payloadSummary; reason = $receipt.reason } | ConvertTo-Json -Depth 6 -Compress))
    Write-Host ('SHA_PREFLIGHT_RECEIPT_SHA256=' + (Get-ShaProvenanceDigest $receiptPath))
}
exit $exitCode
