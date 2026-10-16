[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Python)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$environment = Join-Path $root 'runtime\dashboard\venv'
$interpreter = Join-Path $environment 'Scripts\python.exe'
if (-not (Test-Path -LiteralPath $interpreter)) {
    & $Python -m venv $environment
    if ($LASTEXITCODE -ne 0) { throw 'Dashboard virtual environment creation failed.' }
}
& $interpreter -m pip install --disable-pip-version-check --only-binary=:all: --require-hashes -r (Join-Path $root 'dashboard\requirements.txt')
if ($LASTEXITCODE -ne 0) { throw 'Dashboard dependency verification/install failed. Existing environment retained.' }
Write-Output 'Dashboard dependencies ready. Run .\dashboard.ps1. No VM or worker was started.'
