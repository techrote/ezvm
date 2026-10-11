[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$script:EzVmRepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'TestHarness.ps1')
Import-Module (Join-Path $script:EzVmRepositoryRoot 'src/EzVm/EzVm.psd1') -Force -ErrorAction Stop

$testFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' -File | Sort-Object Name)
if ($testFiles.Count -eq 0) { throw 'No *.Tests.ps1 files were discovered.' }
foreach ($testFile in $testFiles) { . $testFile.FullName }
Invoke-EzVmTestSuite
