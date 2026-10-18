#requires -Version 5.1
# Pure planning/evidence helpers and an injectable GitHub request boundary.
function Get-EzVmPrivateQualificationRunner {
    param([Parameter(Mandatory = $true)][object]$Snapshot)
    foreach ($runner in $Snapshot.runners) {
        $labels = @($runner.labels | ForEach-Object { $_.name })
        if ($runner.status -ceq 'online' -and $runner.busy -is [bool] -and -not $runner.busy -and
            'self-hosted' -in $labels -and 'Windows' -in $labels -and
            'X64' -in $labels -and 'ezvm-whpx' -in $labels -and $runner.name -in $labels) { return $runner }
    }
    return $null
}

function Invoke-EzVmPairedQualificationDispatch {
    param(
        [Parameter(Mandatory = $true)][string]$CandidateSha,
        [Parameter(Mandatory = $true)][string]$WorkflowRef,
        [Parameter(Mandatory = $true)][scriptblock]$Request,
        [string]$ComparisonId = ([Guid]::NewGuid().ToString('N'))
    )
    if ($CandidateSha -cnotmatch '^[a-f0-9]{40}$') { throw 'An exact candidate commit SHA is required.' }
    if ($WorkflowRef -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or $WorkflowRef.Contains('..')) { throw 'Invalid workflow ref.' }
    $body = @{ ref = $WorkflowRef; inputs = @{ candidate_sha = $CandidateSha; comparison_id = $ComparisonId } }
    # Hosted dispatch does not wait for private-runner discovery or completion.
    $null = & $Request 'POST' 'repos/techrote/ezvm/actions/workflows/ezvm-012-real-release.yml/dispatches' $body
    $result = [ordered]@{ schemaVersion = 1; candidateSha = $CandidateSha; comparisonId = $ComparisonId;
        hosted = 'dispatched'; private = 'not-dispatched'; reason = ''; runner = $null }
    try {
        $snapshot = & $Request 'GET' 'repos/techrote/ezvm/actions/runners?per_page=100' $null
        if ($null -eq $snapshot -or $null -eq $snapshot.PSObject.Properties['total_count'] -or $null -eq $snapshot.PSObject.Properties['runners']) { throw 'Unknown runner inventory.' }
    }
    catch { $result.reason = 'Private availability unavailable; hosted run continues.'; return [pscustomobject]$result }
    if ($snapshot.total_count -gt 100) { $result.reason = 'Private inventory exceeds discovery bound; hosted run continues.'; return [pscustomobject]$result }
    $runner = Get-EzVmPrivateQualificationRunner -Snapshot $snapshot
    if ($null -eq $runner) { $result.reason = 'No online idle ezvm-whpx runner; hosted run continues.'; return [pscustomobject]$result }
    $result.runner = $runner.name
    $privateBody = @{ ref = $WorkflowRef; inputs = @{ candidate_sha = $CandidateSha; comparison_id = $ComparisonId; runner_name = $runner.name } }
    try {
        $null = & $Request 'POST' 'repos/techrote/ezvm/actions/workflows/ezvm-012-private-whpx.yml/dispatches' $privateBody
        $result.private = 'dispatched'
        $result.reason = 'Independent workflows; neither cancels the other.'
    }
    catch { $result.private = 'dispatch-failed'; $result.reason = 'Optional private dispatch failed; hosted run continues.' }
    return [pscustomobject]$result
}

function Get-EzVmQualificationOutcome {
    param([string[]]$Lines, [int]$ExitCode, [ValidateSet('tcg', 'whpx')][string]$Accelerator)
    $text = $Lines -join "`n"
    $complete = $text -match '(?m)EZVM012_REAL_COMPLETE_END_TO_END=PASS\s*$'
    $physical = $text -match '(?m)EZVM010_WHPX_EXECUTION=PASS\s*$'
    $reported = $text -match ('(?m)EZVM010_ACCELERATOR=' + $Accelerator + '\s*$')
    return ($ExitCode -eq 0 -and $complete -and $reported -and ($Accelerator -ceq 'tcg' -or $physical))
}
