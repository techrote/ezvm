#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$script:EzVmRepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $script:EzVmRepositoryRoot 'tests/TestHarness.ps1')
. (Join-Path $script:EzVmRepositoryRoot 'tests/QualificationComparison.Tests.ps1')
Invoke-EzVmTestSuite
