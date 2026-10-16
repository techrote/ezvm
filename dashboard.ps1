[CmdletBinding()]
param(
    [string]$Config = '',
    [switch]$Once,
    [switch]$Json,
    [switch]$Demo
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$python = Join-Path $root 'runtime\dashboard\venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python)) {
    throw 'Run scripts\Setup-Dashboard.ps1 -Python <path-to-Python-3.11-or-newer> first.'
}
$arguments = @('-X', 'utf8', (Join-Path $root 'dashboard\main.py'), '--root', $root)
if ($Config) { $arguments += @('--config', [IO.Path]::GetFullPath($Config)) }
if ($Once) { $arguments += '--once' }
if ($Json) { $arguments += '--json' }
if ($Demo) { $arguments += '--demo' }
& $python @arguments
exit $LASTEXITCODE
