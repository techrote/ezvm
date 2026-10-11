[CmdletBinding()]
param([string]$Root = ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'RepositoryContract.psm1') -Force -ErrorAction Stop
$result = Test-EzVmRepositoryContract -Root $Root
Write-Host ('PASS repository contract: {0} tracked files, {1} JSON files, {2} PowerShell files; PowerShell {3}.' -f $result.TrackedFiles, $result.JsonFiles, $result.PowerShellFiles, $PSVersionTable.PSVersion)
