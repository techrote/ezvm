#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BaselineRoot,
    [Parameter(Mandatory = $true)][string]$ExpectedCommit,
    [Parameter(Mandatory = $true)][ValidateSet(5, 7)][int]$ExpectedMajor,
    [Parameter(Mandatory = $true)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$baselineCommit = 'd5265c804d0d8494d8171482a85aca563b181e05'
$baseline = [IO.Path]::GetFullPath($BaselineRoot)
$output = [IO.Path]::GetFullPath($OutputDirectory)
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Standard-user ACL qualification requires Windows; no capability PASS is emitted.' }
if ($PSVersionTable.PSVersion.Major -ne $ExpectedMajor) { throw 'Wrong PowerShell engine for the requested lane.' }
if ($ExpectedMajor -eq 5 -and $PSVersionTable.PSVersion.Minor -ne 1) { throw 'Windows PowerShell 5.1 is required.' }
if ($ExpectedMajor -eq 7) {
    $tooling = Get-Content -LiteralPath (Join-Path $root 'tests/tooling.json') -Raw | ConvertFrom-Json
    if ($PSVersionTable.PSVersion.ToString() -cne $tooling.powerShell7.version) { throw 'The repository-pinned PowerShell 7 version is required.' }
}
if (Test-Path -LiteralPath $output) { throw 'ACL evidence directory must be new; prior receipts are never overwritten.' }
[void][IO.Directory]::CreateDirectory($output)

function Get-AclQualificationSource {
    param([string]$Path, [string]$Expected)
    $head = ((& git -C $Path rev-parse HEAD) -join '').Trim()
    if ($LASTEXITCODE -ne 0 -or $head -cne $Expected -or $head -cnotmatch '^[a-f0-9]{40}$') { throw 'ACL source does not match its expected immutable commit.' }
    $gitRoot = ((& git -C $Path rev-parse --show-toplevel) -join '').Trim()
    if ($LASTEXITCODE -ne 0 -or -not [string]::Equals([IO.Path]::GetFullPath($gitRoot), $Path, [StringComparison]::OrdinalIgnoreCase)) { throw 'ACL source must be the checkout root.' }
    $state = @(& git -C $Path status --porcelain --untracked-files=all)
    if ($LASTEXITCODE -ne 0 -or $state.Count -ne 0) { throw 'ACL qualification refuses dirty, staged or untracked source.' }
    $tree = ((& git -C $Path rev-parse 'HEAD^{tree}') -join '').Trim()
    if ($LASTEXITCODE -ne 0 -or $tree -cnotmatch '^[a-f0-9]{40}$') { throw 'Cannot identify ACL source tree.' }
    return [pscustomobject]@{ commit = $head; tree = $tree; keysSha256 = (Get-FileHash -LiteralPath (Join-Path $Path 'src/EzVm/Keys.ps1') -Algorithm SHA256).Hash.ToLowerInvariant() }
}

function Get-AclQualificationToken {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $adminGroup = @($identity.Groups | Where-Object { $_.Value -ceq 'S-1-5-32-544' }).Count -ne 0
    $privilegeRows = @(& (Join-Path $env:SystemRoot 'System32/whoami.exe') /priv /fo csv /nh)
    if ($LASTEXITCODE -ne 0) { throw 'Could not observe the test process privileges.' }
    $privileges = @([regex]::Matches(($privilegeRows -join "`n"), '"(Se[A-Za-z]+Privilege)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    if ($privileges -cnotcontains 'SeChangeNotifyPrivilege') { throw 'Privilege observation was empty or unrecognized.' }
    $special = @($privileges | Where-Object { $_ -cin @('SeSecurityPrivilege', 'SeTakeOwnershipPrivilege', 'SeBackupPrivilege', 'SeRestorePrivilege') })
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or $adminGroup -or $special.Count -ne 0) {
        throw 'ACL qualification requires an ordinary account without administrator membership or audit/ownership/backup/restore privileges; no elevation or privilege adjustment is attempted.'
    }
    return [pscustomobject]@{ administratorMember = $false; specialPrivilegesPresent = @($special); observedPrivileges = $privileges }
}

$requiredFailures = @(
    'Security: actual Windows key generation and staged copy-from preserve destination on failure',
    'Security: Windows private ACL removes pre-existing broad explicit ACEs',
    'Private ACL: inherited broad file access is removed and repeated protection preserves bytes',
    'Private ACL: directory broad ACEs are removed and protected reapplication remains private'
)
$clock = [Diagnostics.Stopwatch]::StartNew()
$receipt = [ordered]@{ schemaVersion = 1; kind = 'ezvm-private-dacl-regression'; outcome = 'failed';
    startedAt = [DateTime]::UtcNow.ToString('o'); powerShellVersion = $PSVersionTable.PSVersion.ToString();
    candidate = $null; baseline = $null; token = $null; baselineCases = @(); fixedRequiredCases = @();
    fullSuite = $null; sourceUnchanged = $false; reason = ''; exitCode = 1 }
$exitCode = 1
try {
    $receipt.candidate = Get-AclQualificationSource -Path $root -Expected $ExpectedCommit
    $receipt.baseline = Get-AclQualificationSource -Path $baseline -Expected $baselineCommit
    $receipt.token = Get-AclQualificationToken
    # Execute the historical public module and its original tests. New inherited
    # ACE controls use the same historical module, not a mock of Set-Acl.
    $script:EzVmRepositoryRoot = $baseline
    . (Join-Path $baseline 'tests/TestHarness.ps1')
    Import-Module (Join-Path $baseline 'src/EzVm/EzVm.psd1') -Force -ErrorAction Stop
    foreach ($testFile in @(Get-ChildItem -LiteralPath (Join-Path $baseline 'tests') -Filter '*.Tests.ps1' -File | Sort-Object Name)) { . $testFile.FullName }
    . (Join-Path $root 'tests/PrivateAcl.Tests.ps1')
    $baselineCases = New-Object 'System.Collections.Generic.List[object]'
    foreach ($name in $requiredFailures) {
        $tests = @($script:EzVmTestCases | Where-Object { $_.Name -ceq $name })
        if ($tests.Count -ne 1 -or $tests[0].SkipReason) { throw 'A required legacy ACL reproduction is missing or skipped.' }
        $caught = $null
        $caseClock = [Diagnostics.Stopwatch]::StartNew()
        try { & $tests[0].Body $tests[0].Data | Out-Null } catch { $caught = $_ }
        if ($null -eq $caught -or $caught.Exception.Message -cnotmatch 'SeSecurityPrivilege') {
            throw ('Legacy ACL case did not reproduce the required privilege failure: ' + $name + '. ' + $(if ($caught) { $caught.Exception.Message } else { 'Unexpected success.' }))
        }
        $failureMessage = & (Get-Module EzVm) { param($m) Protect-EzVmDiagnosticText -Text $m } $caught.Exception.Message
        $baselineCases.Add([pscustomobject]@{ name = $name; outcome = 'expected-failure'; signature = 'SeSecurityPrivilege'; message = $failureMessage; elapsedSeconds = $caseClock.Elapsed.TotalSeconds })
        $receipt.baselineCases = $baselineCases.ToArray()
        Write-Host ('EXPECTED_LEGACY_FAILURE ' + $name + ': SeSecurityPrivilege')
    }
    Remove-Module EzVm -Force
    # A terminating failure in either real entry point fails the qualification.
    # Marker checks additionally ensure all required cases actually executed.
    & (Join-Path $root 'scripts/Test-Repository.ps1') -Root $root
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $logPath = Join-Path $output 'fixed-suite.log'
    & (Join-Path $root 'tests/Run-Tests.ps1') 6>&1 | ForEach-Object {
        $line = [string]$_
        $lines.Add($line)
        [IO.File]::AppendAllText($logPath, ($line + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
        Write-Host $line
    }
    foreach ($name in $requiredFailures) {
        if ($lines -cnotcontains ('PASS ' + $name)) { throw ('The corrected full suite did not pass required ACL case: ' + $name) }
    }
    $summary = @($lines | Where-Object { $_ -cmatch '^RESULT: [0-9]+ passed, 0 failed, 0 skipped, [0-9]+ total\.$' })
    if ($summary.Count -ne 1) { throw 'Standard-user suite needs one successful summary with no failed or skipped cases.' }
    $receipt.fullSuite = $summary[0]
    $receipt.fixedRequiredCases = $requiredFailures
    $afterToken = Get-AclQualificationToken
    if (($afterToken | ConvertTo-Json -Compress) -cne ($receipt.token | ConvertTo-Json -Compress)) { throw 'Test process privileges changed during qualification.' }
    $afterSource = Get-AclQualificationSource -Path $root -Expected $ExpectedCommit
    $afterBaseline = Get-AclQualificationSource -Path $baseline -Expected $baselineCommit
    if (($afterSource | ConvertTo-Json -Compress) -cne ($receipt.candidate | ConvertTo-Json -Compress) -or
        ($afterBaseline | ConvertTo-Json -Compress) -cne ($receipt.baseline | ConvertTo-Json -Compress)) { throw 'Tested source changed during qualification.' }
    $receipt.sourceUnchanged = $true
    $receipt.outcome = 'pass'
    $exitCode = 0
}
catch { $receipt.reason = $_.Exception.Message; Write-Host ('ACL_QUALIFICATION_FAILED=' + $receipt.reason) }
finally {
    $receipt.exitCode = $exitCode
    $receipt.elapsedSeconds = $clock.Elapsed.TotalSeconds
    $receipt.endedAt = [DateTime]::UtcNow.ToString('o')
    [IO.File]::WriteAllText((Join-Path $output 'receipt.json'), ($receipt | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
}
exit $exitCode
