#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Repository', 'ControlPlane')][string]$Check,
    [Parameter(Mandatory = $true)][ValidateSet(5, 7)][int]$ExpectedMajor
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ($PSVersionTable.PSVersion.Major -ne $ExpectedMajor) {
    throw "Expected PowerShell major $ExpectedMajor, found $($PSVersionTable.PSVersion)."
}
if ($ExpectedMajor -eq 5 -and $PSVersionTable.PSVersion.Minor -ne 1) {
    throw 'The supported Windows PowerShell contract is 5.1.'
}
if ($ExpectedMajor -eq 7) {
    $tooling = Get-Content -LiteralPath (Join-Path $root 'tests/tooling.json') -Raw | ConvertFrom-Json
    if ($PSVersionTable.PSVersion.ToString() -cne $tooling.powerShell7.version) {
        throw "CI must execute the pinned current PowerShell $($tooling.powerShell7.version) runtime."
    }
}
$PSVersionTable | Format-Table | Out-Host
if ($Check -eq 'Repository') { & (Join-Path $PSScriptRoot 'Test-Repository.ps1') -Root $root }
else { & (Join-Path $root 'tests/Run-Tests.ps1') }
# Negative fixtures intentionally exercise native failures. Only the suite's
# terminating errors decide this check, not a leftover LASTEXITCODE from a fixture.
exit 0
