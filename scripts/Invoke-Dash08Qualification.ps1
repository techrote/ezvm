#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [Parameter(Mandatory = $true)][ValidateSet(5, 7)][int]$ExpectedMajor
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2.0
$script:EzVmRepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or [IntPtr]::Size -ne 8) { throw 'DASH-08 mandatory process qualification requires Windows x64.' }
if ($PSVersionTable.PSVersion.Major -ne $ExpectedMajor) { throw 'The executing PowerShell engine does not match the requested lane.' }
$tooling = Get-Content -Raw -LiteralPath (Join-Path $script:EzVmRepositoryRoot 'tests/tooling.json') | ConvertFrom-Json
if ($ExpectedMajor -eq 7 -and $PSVersionTable.PSVersion.ToString() -cne $tooling.powerShell7.version) { throw 'The executing PowerShell 7 version does not match tests/tooling.json.' }
$head = ((git -C $script:EzVmRepositoryRoot rev-parse HEAD) -join '').Trim()
if ($LASTEXITCODE -ne 0 -or $head -cnotmatch '^[a-f0-9]{40}$') { throw 'Cannot identify qualification commit.' }
$tree = ((git -C $script:EzVmRepositoryRoot rev-parse 'HEAD^{tree}') -join '').Trim()
if ($LASTEXITCODE -ne 0 -or $tree -cnotmatch '^[a-f0-9]{40}$') { throw 'Cannot identify qualification tree.' }
$dirty = @(git -C $script:EzVmRepositoryRoot status --porcelain --untracked-files=normal)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -ne 0) { throw 'Qualification requires a clean exact checkout; no dirty source can qualify.' }
$sourcePaths = @('src/EzVm/Runtime.ps1', 'src/EzVm/RuntimeProcess.cs', 'src/EzVm/Keys.ps1', 'src/EzVm/Ssh.ps1', 'tests/TestHarness.ps1', 'tests/Dash08Lifecycle.Tests.ps1', 'tests/fixtures/Dash08ProcessScenario.ps1', 'tests/fixtures/Dash08VmLifetime.cs', 'tests/fixtures/Dash08QmpServer.cs', 'scripts/Invoke-Dash08Qualification.ps1')
$digests = [ordered]@{}
foreach ($relative in $sourcePaths) { $digests[$relative] = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $script:EzVmRepositoryRoot $relative)).Hash.ToLowerInvariant() }
. (Join-Path $script:EzVmRepositoryRoot 'tests/TestHarness.ps1')
Import-Module (Join-Path $script:EzVmRepositoryRoot 'src/EzVm/EzVm.psd1') -Force
foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $script:EzVmRepositoryRoot 'tests') -Filter '*.Tests.ps1' -File | Sort-Object Name)) { . $file.FullName }
$tests = @($script:EzVmTestCases | Where-Object { $_.Name -like 'DASH-08-*' })
if ($tests.Count -eq 0) { throw 'No DASH-08 tests discovered; refusing empty success.' }
$cases = New-Object 'System.Collections.Generic.List[object]'
$failureCount = 0
$receipt = [ordered]@{
    schemaVersion = 1; issue = 'DASH-08'; sourceRevision = $head; sourceTree = $tree
    cleanCheckout = $true; sourceSha256 = $digests; powerShell = $PSVersionTable.PSVersion.ToString()
    os = [Environment]::OSVersion.ToString(); processArchitectureBits = ([IntPtr]::Size * 8)
    startedAt = [DateTime]::UtcNow.ToString('o'); endedAt = $null; softwarePass = $false
    originalIssueAcceptance = $false; standardUserWhpxExecuted = $false
    physicalCase = [ordered]@{ id = 'DASH-08-T04'; result = 'SKIP'; reason = 'GitHub-hosted native process fixtures do not qualify a standard-user Windows/WHPX guest. Parent #34 and provision gate remain held.' }
    tests = @(); failed = 0
}
try {
    foreach ($test in $tests) {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $record = [ordered]@{ name = $test.Name; result = 'FAIL'; elapsedMilliseconds = 0; measurements = @(); error = $null }
        try {
            if ($test.SkipReason) { throw ('Mandatory Windows software case was skipped: ' + $test.SkipReason) }
            $messages = @(& $test.Body $test.Data 6>&1)
            foreach ($message in $messages) { Write-Host ([string]$message) }
            $record.measurements = @($messages | ForEach-Object { [string]$_ } | Where-Object { $_ -like 'DASH08_MEASUREMENT*' })
            $record.result = 'PASS'
            Write-Host ('PASS ' + $test.Name)
        }
        catch {
            $failureCount++
            $record.error = & (Get-Module EzVm) { param($text) Protect-EzVmDiagnosticText -Text $text } $_.Exception.Message
            Write-Host ('FAIL ' + $test.Name + ': ' + $record.error)
            Write-Host $_.ScriptStackTrace
        }
        $record.elapsedMilliseconds = $clock.ElapsedMilliseconds
        $cases.Add([pscustomobject]$record)
    }
    foreach ($relative in $sourcePaths) {
        $after = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $script:EzVmRepositoryRoot $relative)).Hash.ToLowerInvariant()
        if ($after -cne $digests[$relative]) { throw ('Source changed during qualification: ' + $relative) }
    }
    $dirty = @(git -C $script:EzVmRepositoryRoot status --porcelain --untracked-files=normal)
    if ($LASTEXITCODE -ne 0 -or $dirty.Count -ne 0) { throw 'Source checkout changed during qualification.' }
    $receipt.softwarePass = $failureCount -eq 0
}
finally {
    $receipt.tests = @($cases.ToArray())
    $receipt.failed = $failureCount
    $receipt.endedAt = [DateTime]::UtcNow.ToString('o')
    [void][IO.Directory]::CreateDirectory($OutputDirectory)
    $path = Join-Path $OutputDirectory ('dash08-powershell-' + $ExpectedMajor + '.json')
    [IO.File]::WriteAllText($path, (($receipt | ConvertTo-Json -Depth 10) + "`n"), [Text.UTF8Encoding]::new($false))
    Get-FileHash -Algorithm SHA256 -LiteralPath $path
    Write-Host ('DASH08_RESULT tests=' + $tests.Count + ';failures=' + $failureCount + ';T04=SKIP;issueAcceptance=false')
}
if (-not $receipt.softwarePass) { throw ('DASH-08 qualification failed: ' + $failureCount + ' software case(s).') }
