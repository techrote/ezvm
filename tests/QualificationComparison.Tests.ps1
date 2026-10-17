. (Join-Path $script:EzVmRepositoryRoot 'scripts/QualificationComparison.ps1')

function New-QualificationRunnerFixture {
    param([string]$Status = 'online', [bool]$Busy = $false)
    [pscustomobject]@{ total_count = 1; runners = @([pscustomobject]@{ name = 'fixture-whpx'; status = $Status; busy = $Busy;
        labels = @('self-hosted', 'Windows', 'X64', 'ezvm-whpx', 'fixture-whpx') | ForEach-Object { [pscustomobject]@{ name = $_ } } }) }
}

Add-EzVmTest -Name 'Qualification comparison: offline private runner still dispatches hosted exactly once' -ScriptBlock {
    $calls = New-Object Collections.Generic.List[object]
    $request = { param($Method, $Path, $Body) $calls.Add(@{ method = $Method; path = $Path; body = $Body }); if ($Method -eq 'GET') { New-QualificationRunnerFixture -Status offline } }
    $r = Invoke-EzVmPairedQualificationDispatch -CandidateSha ('a' * 40) -WorkflowRef main -Request $request
    Assert-EzVmEqual $r.hosted 'dispatched'
    Assert-EzVmEqual $r.private 'not-dispatched'
    Assert-EzVmEqual @($calls | Where-Object method -eq 'POST').Count 1
    Assert-EzVmEqual $calls[0].method 'POST'
}

Add-EzVmTest -Name 'Qualification comparison: online dedicated runner receives same SHA and comparison ID independently' -ScriptBlock {
    $calls = New-Object Collections.Generic.List[object]
    $request = { param($Method, $Path, $Body) $calls.Add(@{ method = $Method; path = $Path; body = $Body }); if ($Method -eq 'GET') { New-QualificationRunnerFixture } }
    $r = Invoke-EzVmPairedQualificationDispatch -CandidateSha ('b' * 40) -WorkflowRef main -Request $request -ComparisonId pair1
    $posts = @($calls | Where-Object method -eq 'POST')
    Assert-EzVmEqual $r.private 'dispatched'
    Assert-EzVmEqual $posts.Count 2
    Assert-EzVmEqual $posts[0].body.inputs.candidate_sha $posts[1].body.inputs.candidate_sha
    Assert-EzVmEqual $posts[0].body.inputs.comparison_id $posts[1].body.inputs.comparison_id
    Assert-EzVmEqual $posts[1].body.inputs.runner_name 'fixture-whpx'
    Assert-EzVmTrue ($posts[0].path -ne $posts[1].path)
}

Add-EzVmTest -Name 'Qualification comparison: busy private runner cannot stall hosted dispatch' -ScriptBlock {
    $request = { param($Method, $Path, $Body) if ($Method -eq 'GET') { New-QualificationRunnerFixture -Busy $true } }
    $r = Invoke-EzVmPairedQualificationDispatch -CandidateSha ('a' * 40) -WorkflowRef main -Request $request
    Assert-EzVmEqual $r.hosted 'dispatched'
    Assert-EzVmEqual $r.private 'not-dispatched'
}

Add-EzVmTest -Name 'Qualification comparison: private inventory errors are unknown and never cancel hosted' -ScriptBlock {
    $request = { param($Method, $Path, $Body) if ($Method -eq 'GET') { throw 'simulated API unavailable' } }
    $r = Invoke-EzVmPairedQualificationDispatch -CandidateSha ('a' * 40) -WorkflowRef main -Request $request
    Assert-EzVmEqual $r.hosted 'dispatched'
    Assert-EzVmEqual $r.private 'not-dispatched'
    Assert-EzVmTrue ($r.reason -match 'unavailable')
}

Add-EzVmTest -Name 'Qualification comparison: absent registration and malformed inventory fail closed only for private lane' -ScriptBlock {
    foreach ($snapshot in @([pscustomobject]@{ total_count = 0; runners = @() }, [pscustomobject]@{ unexpected = @() })) {
        $request = { param($Method, $Path, $Body) if ($Method -eq 'GET') { $snapshot } }
        $r = Invoke-EzVmPairedQualificationDispatch -CandidateSha ('a' * 40) -WorkflowRef main -Request $request
        Assert-EzVmEqual $r.hosted 'dispatched'
        Assert-EzVmEqual $r.private 'not-dispatched'
    }
}

Add-EzVmTest -Name 'Qualification comparison: generic Windows runner without unique label is not selected' -ScriptBlock {
    $snapshot = New-QualificationRunnerFixture
    $snapshot.runners[0].labels = @('self-hosted', 'Windows', 'X64', 'ezvm-whpx') | ForEach-Object { [pscustomobject]@{ name = $_ } }
    Assert-EzVmTrue ($null -eq (Get-EzVmPrivateQualificationRunner $snapshot))
}

Add-EzVmTest -Name 'Qualification comparison: optional dispatch error preserves hosted success and reports failure' -ScriptBlock {
    $request = { param($Method, $Path, $Body) if ($Method -eq 'GET') { New-QualificationRunnerFixture }; if ($Path -match 'private-whpx.yml') { throw 'simulated private dispatch failure' } }
    $r = Invoke-EzVmPairedQualificationDispatch -CandidateSha ('a' * 40) -WorkflowRef main -Request $request
    Assert-EzVmEqual $r.hosted 'dispatched'
    Assert-EzVmEqual $r.private 'dispatch-failed'
}

Add-EzVmTest -Name 'Qualification comparison: hosted failure is not reported as successful dispatch' -ScriptBlock {
    $request = { throw 'hosted refused' }
    $failed = $false
    try { $null = Invoke-EzVmPairedQualificationDispatch -CandidateSha ('a' * 40) -WorkflowRef main -Request $request } catch { $failed = $true }
    Assert-EzVmTrue $failed
}

Add-EzVmTest -Name 'Qualification comparison: invalid candidate is refused before any request' -ScriptBlock {
    $calls = New-Object Collections.Generic.List[object]
    $request = { $calls.Add('unexpected') }
    $failed = $false
    try { $null = Invoke-EzVmPairedQualificationDispatch -CandidateSha main -WorkflowRef main -Request $request } catch { $failed = $true }
    Assert-EzVmTrue $failed
    Assert-EzVmEqual $calls.Count 0
}

Add-EzVmTest -Name 'Qualification evidence: PASS prose with failed exit never qualifies' -ScriptBlock {
    $lines = @('EZVM010_ACCELERATOR=whpx', 'EZVM012_REAL_COMPLETE_END_TO_END=PASS', 'EZVM010_WHPX_EXECUTION=PASS')
    Assert-EzVmTrue (-not (Get-EzVmQualificationOutcome $lines 1 whpx))
    Assert-EzVmTrue (Get-EzVmQualificationOutcome $lines 0 whpx)
    Assert-EzVmTrue (-not (Get-EzVmQualificationOutcome $lines[0..1] 0 whpx))
    Assert-EzVmTrue (-not (Get-EzVmQualificationOutcome $lines 0 tcg))
}

Add-EzVmTest -Name 'Qualification accelerator: real guest-start function checks requested effective accelerator' -ScriptBlock {
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:EzVmRepositoryRoot 'scripts/Invoke-EzVm010RealPortability.ps1'), [ref]$null, [ref]$null)
    $function = $ast.Find({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Start-EzVm010Guest' }, $true)
    & {
        Invoke-Expression $function.Extent.Text
        $Root = 'fixture-root'; $active = New-Object 'Collections.Generic.List[string]'; $Accelerator = 'whpx'
        function Start-EzVmReadyInstance { param($Root, $InstanceName, $Accelerator, $ReadyTimeoutSeconds) [pscustomobject]@{ state = 'READY'; accelerator = $Accelerator; sshHost = '127.0.0.1' } }
        Start-EzVm010Guest -Name fixture
        function Start-EzVmReadyInstance { [pscustomobject]@{ state = 'READY'; accelerator = 'tcg'; sshHost = '127.0.0.1' } }
        $refused = $false
        try { Start-EzVm010Guest -Name fixture } catch { $refused = $true }
        Assert-EzVmTrue $refused
    }
}
