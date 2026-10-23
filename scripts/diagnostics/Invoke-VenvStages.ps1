#requires -Version 5.1
[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$ControllerRoot,
    [Parameter(Mandatory=$true)][string]$EvidenceParent,
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{32}$')][string]$AttemptId,
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{40}$')][string]$SourceCommit,
    [Parameter(Mandatory=$true)][ValidatePattern('^[1-9][0-9]{0,14}$')][string]$RunId)
$ErrorActionPreference='Stop';$env:PSModulePath=[IO.Path]::Combine($PSHOME,'Modules')
. (Join-Path $ControllerRoot 'poc/windows-whpx/Pilot.Common.ps1')
Import-PilotNative
$source=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$evidence=Assert-PilotPath -Path $EvidenceParent
$before=Get-PilotSourceIdentity -Root $source -Repository 'https://github.com/techrote/ezvm' -ExpectedCommit $SourceCommit
$controllerBefore=Get-PilotSourceIdentity -Root $ControllerRoot -Repository 'https://github.com/techrote/runloc' -ExpectedCommit 'a71e9e1adae1fb749b2325277c4a52dff69d7b6d'
$clock=[Diagnostics.Stopwatch]::StartNew();$job=$null;$errors=@();$forced=$false;$timeout=$false;$summary=$null
$exitCode=$null;$empty=$false;$drained=$false;$sourceSame=$false;$controllerSame=$false
try{
    $exe=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $arguments=Get-PilotPowerShellArguments -TargetScript (Join-Path $PSScriptRoot 'VenvStages.Workload.ps1') -NamedParameters @{ControllerRoot=$ControllerRoot;EvidenceParent=$evidence;AttemptId=$AttemptId;SourceCommit=$SourceCommit;RunId=$RunId}
    $job=New-Object RunlocPoc.OwnedProcess($exe,$arguments,$source,$evidence,(Join-Path $evidence 'supervisor.private.log'),8388608)
    $beat=0
    while(-not $job.HasExited){
        [void]$job.Drain()
        if($clock.Elapsed.TotalSeconds -ge 2700){$timeout=$true;break}
        if($job.OutputFailed -or $job.OutputOverflow){$errors+='workload-output-incomplete';break}
        if($clock.Elapsed.TotalSeconds-$beat -ge 15){Write-Host ([DateTime]::UtcNow.ToString('o')+' VENV_STAGE_SUPERVISOR_HEARTBEAT elapsed='+[Math]::Round($clock.Elapsed.TotalSeconds)+' owned='+$job.ActiveProcesses+'; diagnostic-only, no new guest stage inferred');$beat=$clock.Elapsed.TotalSeconds}
        Start-Sleep -Milliseconds 100
    }
}catch{$errors+='workload-start-or-observation-failed'}finally{
    if($null -ne $job){
        try{
            if(-not $job.HasExited -or $job.ActiveProcesses -gt 0){$forced=$true;$job.Terminate()}
            $wait=[Diagnostics.Stopwatch]::StartNew()
            while((-not $job.HasExited -or $job.ActiveProcesses -gt 0) -and $wait.Elapsed.TotalSeconds -lt 30){Start-Sleep -Milliseconds 100}
            $empty=$job.HasExited -and $job.ActiveProcesses -eq 0
            if($job.HasExited){$exitCode=$job.ExitCode}
            $drained=$job.FinishOutput(3000);[void]$job.Drain()
            if($job.OutputFailed -or $job.OutputOverflow){$errors+='workload-output-incomplete'}
        }catch{$errors+='owned-workload-cleanup-unavailable'}
        finally{try{$job.Dispose()}catch{$errors+='job-disposal-unavailable'}}
    }
    try{$after=Get-PilotSourceIdentity -Root $source -Repository 'https://github.com/techrote/ezvm' -ExpectedCommit $SourceCommit;$sourceSame=$after.executedTreeSha256 -ceq $before.executedTreeSha256}catch{$errors+='candidate-audit-unavailable'}
    try{$controllerAfter=Get-PilotSourceIdentity -Root $ControllerRoot -Repository 'https://github.com/techrote/runloc' -ExpectedCommit 'a71e9e1adae1fb749b2325277c4a52dff69d7b6d';$controllerSame=$controllerAfter.executedTreeSha256 -ceq $controllerBefore.executedTreeSha256}catch{$errors+='controller-audit-unavailable'}
    try{
        $path=Join-Path $evidence 'workload-result.private.json'
        if(-not [IO.File]::Exists($path) -or (Get-Item -LiteralPath $path).Length -gt 1048576){throw 'result-unavailable'}
        $summary=[IO.File]::ReadAllText($path)|ConvertFrom-Json
        if($summary.diagnosticOnly -ne $true -or $summary.qualificationPassed -ne $false -or $summary.attemptId -cne $AttemptId -or $summary.errors.Count -ne 0 -or $summary.forced -or -not $summary.sourceUnchanged){throw 'result-binding-or-cleanup'}
    }catch{$summary=$null;$errors+='workload-result-unavailable-or-invalid'}
    $complete=$null -ne $summary -and $summary.probeComplete -and $summary.actualExit -eq 0 -and $summary.activeProcesses -eq 0 -and $summary.outputComplete -and $exitCode -eq 0 -and $empty -and $drained -and -not $forced -and -not $timeout -and $sourceSame -and $controllerSame -and $errors.Count -eq 0
    $public=@{schemaVersion=1;diagnosticOnly=$true;qualificationPassed=$false;attemptId=$AttemptId;runId=([long]$RunId);workflowCommit=$SourceCommit;candidate=$before;controller=$controllerBefore;probeComplete=$complete;actualExit=$exitCode;ownedProcessesEmpty=$empty;outputComplete=$drained;forced=$forced;timedOut=$timeout;sourceUnchanged=$sourceSame;controllerUnchanged=$controllerSame;errors=$errors;elapsedSeconds=$clock.Elapsed.TotalSeconds}
    if($null -ne $summary){foreach($key in @('buildId','bootstrapSha256','records','serialSha256','qemuSha256','imageSha256','cpus','accelerator')){$public[$key]=$summary.$key}}
    Write-PilotNewJson -Path (Join-Path $evidence 'venv-stage-result.json') -Value $public
}
if(-not $complete){throw 'diagnostic-not-complete-no-qualification'}
