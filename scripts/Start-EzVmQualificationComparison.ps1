#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CandidateSha,
    [string]$WorkflowRef = 'main'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'QualificationComparison.ps1')
if (-not (Get-Command gh -CommandType Application -ErrorAction SilentlyContinue)) { throw 'Use an existing authenticated host GitHub CLI; this script does not enroll credentials.' }
$request = {
    param($Method, $Path, $Body)
    if ($Method -eq 'GET') {
        $raw = & gh api $Path
        if ($LASTEXITCODE -ne 0) { throw 'Private runner inventory request failed.' }
        return (($raw -join "`n") | ConvertFrom-Json)
    }
    $payload = Join-Path ([IO.Path]::GetTempPath()) ('ezvm-dispatch-' + [Guid]::NewGuid().ToString('N') + '.json')
    try {
        [IO.File]::WriteAllText($payload, ($Body | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
        $null = & gh api --method POST $Path --input $payload
        if ($LASTEXITCODE -ne 0) { throw 'Workflow dispatch failed.' }
    }
    finally { if (Test-Path -LiteralPath $payload -PathType Leaf) { Remove-Item -LiteralPath $payload } }
}
$result = Invoke-EzVmPairedQualificationDispatch -CandidateSha $CandidateSha -WorkflowRef $WorkflowRef -Request $request
$result | ConvertTo-Json -Depth 5
# A private failure is reported explicitly and never cancels the hosted run.
