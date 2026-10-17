#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Root = '',
    [ValidateSet('tcg', 'whpx')][string]$Accelerator = 'whpx',
    [string]$ExpectedCommit = '',
    [string]$ComparisonId = '',
    [switch]$PreflightOnly
)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Join-Path $PSScriptRoot '..' }
$sourceRoot = [IO.Path]::GetFullPath($Root)
. (Join-Path $PSScriptRoot 'QualificationComparison.ps1')
$head = ((& git -C $sourceRoot rev-parse HEAD) -join '').Trim()
if ($LASTEXITCODE -ne 0 -or $head -cnotmatch '^[a-f0-9]{40}$') { throw 'Pilot needs an exact Git checkout.' }
$gitRoot = ((& git -C $sourceRoot rev-parse --show-toplevel) -join '').Trim()
if (-not [string]::Equals([IO.Path]::GetFullPath($gitRoot), $sourceRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Pilot root must be the checkout root.' }
if ($ExpectedCommit -and $head -cne $ExpectedCommit) { throw 'Pilot checkout does not match expected commit.' }
& git -C $sourceRoot diff --quiet
if ($LASTEXITCODE -ne 0) { throw 'Pilot refuses modified tracked source; owner patches must not be copied in.' }
& git -C $sourceRoot diff --cached --quiet
if ($LASTEXITCODE -ne 0) { throw 'Pilot refuses staged source changes.' }
$tree = ((& git -C $sourceRoot rev-parse 'HEAD^{tree}') -join '').Trim()
$runDir = Join-Path $sourceRoot ('runtime\qualification-pilot\' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($runDir)
$clock = [Diagnostics.Stopwatch]::StartNew()
$receipt = [ordered]@{ schemaVersion = 1; sourceCommit = $head; sourceTree = $tree; accelerator = $Accelerator;
    comparisonId = $ComparisonId; startedAt = [DateTime]::UtcNow.ToString('o'); preflightOnly = [bool]$PreflightOnly;
    outcome = 'blocked'; phase = 'preflight'; reason = ''; elapsedSeconds = 0; exitCode = $null; vmQualificationStarted = $false }
$log = Join-Path $runDir 'qualification.log'
$exitCode = 2
try {
    Import-Module (Join-Path $sourceRoot 'src/EzVm/EzVm.psd1') -Force
    # Synthetic file only: no key generation or access to existing controller keys.
    $probeDir = Join-Path $runDir 'synthetic-acl-probe'
    [void][IO.Directory]::CreateDirectory($probeDir)
    $probe = Join-Path $probeDir 'not-a-key.txt'
    [IO.File]::WriteAllText($probe, 'Synthetic qualification ACL preflight; no credential.')
    & (Get-Module EzVm) { param($Directory, $File) Set-EzVmPrivateAcl -Path $Directory -Directory; Set-EzVmPrivateAcl -Path $File } $probeDir $probe
    $receipt.phase = 'host-preflight'
    $os = Get-CimInstance Win32_OperatingSystem
    $receipt.host = @{ os = $os.Caption; version = $os.Version; logicalCpu = [Environment]::ProcessorCount;
        availableMemoryBytes = [long]$os.FreePhysicalMemory * 1KB; user = [Security.Principal.WindowsIdentity]::GetCurrent().Name }
    if ([long]$receipt.host.availableMemoryBytes -lt 16GB) { throw 'Pilot requires at least 16 GiB available host RAM; no allocations changed.' }
    $volume = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot([IO.Path]::GetTempPath()))
    if ($volume.AvailableFreeSpace -lt 60GB) { throw 'Pilot requires at least 60 GiB free on the temporary-work volume.' }
    if ($PreflightOnly) { $receipt.outcome = 'preflight-pass'; $exitCode = 0 }
    else {
        $receipt.phase = 'full-qualification'
        $receipt.vmQualificationStarted = $true
        $command = Join-Path $sourceRoot 'scripts/Invoke-EzVm010RealPortability.ps1'
        & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $command -Root $sourceRoot -ReleaseQualification -Accelerator $Accelerator 2>&1 | ForEach-Object {
            $line = [DateTime]::UtcNow.ToString('o') + ' ' + [string]$_
            [IO.File]::AppendAllText($log, $line + [Environment]::NewLine)
            Write-Output $line
        }
        $exitCode = $LASTEXITCODE
        $receipt.exitCode = $exitCode
        if (Get-EzVmQualificationOutcome -Lines ([IO.File]::ReadAllLines($log)) -ExitCode $exitCode -Accelerator $Accelerator) {
            $receipt.outcome = 'pass'
        }
        else { $receipt.outcome = 'failed'; if ($exitCode -eq 0) { $exitCode = 1 } }
    }
}
catch {
    $receipt.reason = $_.Exception.Message
    if ($receipt.vmQualificationStarted) { $receipt.outcome = 'failed' }
    Write-Host ('PILOT_BLOCKED_OR_FAILED=' + $receipt.reason)
}
finally {
    $receipt.elapsedSeconds = $clock.Elapsed.TotalSeconds
    $receipt.endedAt = [DateTime]::UtcNow.ToString('o')
    $receipt.exitCode = $exitCode
    $after = ((& git -C $sourceRoot rev-parse HEAD) -join '').Trim()
    $changes = @(& git -C $sourceRoot status --porcelain --untracked-files=no)
    if ($after -cne $head -or $LASTEXITCODE -ne 0 -or $changes.Count) { $receipt.outcome = 'failed'; $receipt.reason = 'Tested source changed during qualification.'; $exitCode = 1; $receipt.exitCode = 1 }
    [IO.File]::WriteAllText((Join-Path $runDir 'receipt.json'), ($receipt | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    Write-Host ('PILOT_RECEIPT=' + (Join-Path $runDir 'receipt.json'))
    Write-Host ('PILOT_OUTCOME=' + $receipt.outcome + '; elapsedSeconds=' + $receipt.elapsedSeconds)
}
exit $exitCode
