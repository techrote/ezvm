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
        $Root = 'fixture-root'; $active = New-Object 'Collections.Generic.List[string]'; $Accelerator = 'whpx'; $QualificationCpus = 0
        function Start-EzVmReadyInstance { param($Root, $InstanceName, $Accelerator, $ReadyTimeoutSeconds) [pscustomobject]@{ state = 'READY'; accelerator = $Accelerator; sshHost = '127.0.0.1' } }
        Start-EzVm010Guest -Name fixture
        function Start-EzVmReadyInstance { [pscustomobject]@{ state = 'READY'; accelerator = 'tcg'; sshHost = '127.0.0.1' } }
        $refused = $false
        try { Start-EzVm010Guest -Name fixture } catch { $refused = $true }
        Assert-EzVmTrue $refused
    }
}

Add-EzVmTest -Name 'Qualification CPUs: every real READY start requires requested intent and authenticated online count' -ScriptBlock {
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:EzVmRepositoryRoot 'scripts/Invoke-EzVm010RealPortability.ps1'), [ref]$null, [ref]$null)
    $function = $ast.Find({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Start-EzVm010Guest' }, $true)
    & {
        Invoke-Expression $function.Extent.Text
        $Root = 'fixture-root'; $active = New-Object 'Collections.Generic.List[string]'; $Accelerator = 'whpx'; $QualificationCpus = 8
        function Start-EzVmReadyInstance { [pscustomobject]@{ state = 'READY'; accelerator = 'whpx'; sshHost = '127.0.0.1' } }
        function Get-EzVmInstanceIntent { [pscustomobject]@{ cpus = 8 } }
        function Invoke-EzVm010Guest { '8' }
        Start-EzVm010Guest -Name ezvm010-source
        function Invoke-EzVm010Guest { '4' }
        $null = Assert-EzVmThrows { Start-EzVm010Guest -Name ezvm010-source } -MessagePattern 'CPU count'
        function Invoke-EzVm010Guest { '8' }
        function Get-EzVmInstanceIntent { [pscustomobject]@{ cpus = 4 } }
        $null = Assert-EzVmThrows { Start-EzVm010Guest -Name ezvm010-source } -MessagePattern 'CPU count'
    }
}

Add-EzVmTest -Name 'Qualification diagnostics: retain bounded base serial evidence without reading seeds or unrelated stages' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'base diagnostic retention'
    try {
        $bases = (Get-EzVmPaths -Root $root).Bases
        $stage = Join-Path $bases ('.build-' + ('a' * 32))
        [void][IO.Directory]::CreateDirectory((Join-Path $stage 'seed'))
        [IO.File]::WriteAllText((Join-Path $stage 'serial.log'), ('DISCARDED_HEAD' + "`n" + (('x' * 5000) + "`n") + ((1..196 | ForEach-Object { 'SERIAL_' + $_ }) -join "`n") + "`nEZVM012_REAL_COMPLETE_END_TO_END=PASS`nnoise`rEZVM010_WHPX_EXECUTION=PASS"))
        [IO.File]::WriteAllText((Join-Path $stage 'failure.json'), ('DISCARDED_BYTE_HEAD' + ('q' * 300000) + "`n" + '{"message":"EXPECTED_BASE_FAILURE"}'))
        [IO.File]::WriteAllText((Join-Path $stage 'seed/user-data'), 'EXCLUDED_SEED_SENTINEL')
        $other = Join-Path $bases '.build-unrelated'
        [void][IO.Directory]::CreateDirectory($other)
        [IO.File]::WriteAllText((Join-Path $other 'serial.log'), 'EXCLUDED_STAGE_SENTINEL')
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:EzVmRepositoryRoot 'scripts/Invoke-EzVm010RealPortability.ps1'), [ref]$null, [ref]$null)
        $function = $ast.Find({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Write-EzVm010BaseDiagnostics' }, $true)
        $output = & {
            Invoke-Expression $function.Extent.Text
            Write-EzVm010BaseDiagnostics -DiagnosticRoot $root
        } 6>&1 | Out-String
        Assert-EzVmTrue ($output -match 'EXPECTED_BASE_FAILURE' -and $output -match 'SERIAL_196')
        Assert-EzVmTrue ($output -match '\[diagnostic line truncated\]')
        Assert-EzVmTrue ($output -notmatch 'DISCARDED_HEAD|DISCARDED_BYTE_HEAD|EXCLUDED_SEED_SENTINEL|EXCLUDED_STAGE_SENTINEL')
        Assert-EzVmTrue ($output.Length -lt 20000)
        Assert-EzVmTrue ($output -match 'BASE_LOG_LINE=EZVM012_REAL_COMPLETE_END_TO_END=PASS')
        Assert-EzVmTrue ($output -notmatch '(?m)^EZVM012_REAL_COMPLETE_END_TO_END=PASS\r?$')
        Assert-EzVmTrue ($output -match 'BASE_LOG_LINE=EZVM010_WHPX_EXECUTION=PASS')
        Assert-EzVmTrue ($output.Replace("`r", "`n") -notmatch '(?m)^EZVM010_WHPX_EXECUTION=PASS$')
        Assert-EzVmEqual ([IO.File]::ReadAllText((Join-Path $stage 'seed/user-data'))) 'EXCLUDED_SEED_SENTINEL'
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Qualification diagnostics: redirected stages and linked files refuse without exposing target content' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'base diagnostic links'
    $outside = New-EzVmTestDirectory -Prefix 'excluded diagnostic target'
    $stageLink = $null
    $fileLink = $null
    try {
        $bases = (Get-EzVmPaths -Root $root).Bases
        [void][IO.Directory]::CreateDirectory($bases)
        $target = Join-Path $outside 'secret.txt'
        [IO.File]::WriteAllText($target, 'EXCLUDED_LINK_TARGET')
        $stage = Join-Path $bases ('.build-' + ('a' * 32))
        [void][IO.Directory]::CreateDirectory($stage)
        $fileLink = Join-Path $stage 'serial.log'
        $kind = if ($script:EzVmIsWindowsHost) { 'HardLink' } else { 'SymbolicLink' }
        New-Item -ItemType $kind -Path $fileLink -Target $target | Out-Null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:EzVmRepositoryRoot 'scripts/Invoke-EzVm010RealPortability.ps1'), [ref]$null, [ref]$null)
        $function = $ast.Find({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Write-EzVm010BaseDiagnostics' }, $true)
        $refusalOutput = & {
            Invoke-Expression $function.Extent.Text
            Assert-EzVmThrows { Write-EzVm010BaseDiagnostics -DiagnosticRoot $root } -MessagePattern 'hard-linked|reparse point' | Out-Null
        } 6>&1 | Out-String
        Assert-EzVmTrue ($refusalOutput -notmatch 'EXCLUDED_LINK_TARGET')
        Remove-Item -LiteralPath $fileLink -Force
        $stageLink = Join-Path $bases ('.build-' + ('b' * 32))
        $kind = if ($script:EzVmIsWindowsHost) { 'Junction' } else { 'SymbolicLink' }
        New-Item -ItemType $kind -Path $stageLink -Target $outside | Out-Null
        $refusalOutput = & {
            Invoke-Expression $function.Extent.Text
            Assert-EzVmThrows { Write-EzVm010BaseDiagnostics -DiagnosticRoot $root } -MessagePattern 'reparse point' | Out-Null
        } 6>&1 | Out-String
        Assert-EzVmTrue ($refusalOutput -notmatch 'EXCLUDED_LINK_TARGET')
        Assert-EzVmEqual ([IO.File]::ReadAllText($target)) 'EXCLUDED_LINK_TARGET'
    }
    finally {
        if ($null -ne $fileLink -and [IO.File]::Exists($fileLink)) { [IO.File]::Delete($fileLink) }
        if ($null -ne $stageLink -and [IO.Directory]::Exists($stageLink)) { [IO.Directory]::Delete($stageLink) }
        Remove-EzVmTestDirectory -Path $root
        Remove-EzVmTestDirectory -Path $outside
    }
}
