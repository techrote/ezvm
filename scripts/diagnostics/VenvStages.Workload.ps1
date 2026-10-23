#requires -Version 5.1
[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$ControllerRoot,
    [Parameter(Mandatory=$true)][string]$EvidenceParent,
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{32}$')][string]$AttemptId,
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{40}$')][string]$SourceCommit,
    [Parameter(Mandatory=$true)][ValidatePattern('^[1-9][0-9]{0,14}$')][string]$RunId)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$env:PSModulePath=[IO.Path]::Combine($PSHOME,'Modules')
. (Join-Path $ControllerRoot 'poc/windows-whpx/Pilot.Common.ps1')
Import-PilotNative
$source=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$identity=Get-PilotSourceIdentity -Root $source -Repository 'https://github.com/techrote/ezvm' -ExpectedCommit $SourceCommit
$controller=Get-PilotSourceIdentity -Root $ControllerRoot -Repository 'https://github.com/techrote/runloc' -ExpectedCommit 'a71e9e1adae1fb749b2325277c4a52dff69d7b6d'
$evidence=Assert-PilotPath -Path $EvidenceParent
$root=Join-Path $evidence 'owned-candidate'
$stage=Join-Path $evidence 'owned-stage'
foreach($path in @($root,$stage)){if(Test-Path -LiteralPath $path){throw 'fresh-owned-root-required'};[void][IO.Directory]::CreateDirectory($path)}
foreach($relative in @('ezvm.ps1','src','config','manifests','guest','scripts','tools')){
    Copy-Item -LiteralPath (Join-Path $source $relative) -Destination $root -Recurse
}
Import-Module (Join-Path $root 'src/EzVm/EzVm.psd1') -Force
$clock=[Diagnostics.Stopwatch]::StartNew()
$job=$null;$seed=$null;$forced=$false;$result=$null;$errors=@()
try{
    $null=Install-EzVmQemuRuntime -Root $root
    $null=Invoke-EzVmSourceImageAcquire -Root $root
    $image=Get-EzVmVerifiedSourceImage -Root $root
    $status=Get-EzVmManagedQemuStatus -Root $root
    if(-not $status.Valid){throw 'qemu-verification-failed'}
    $recipe=Get-EzVmBaseRecipe -Root $root
    $recipe.cpus=6;$recipe.memoryMiB=4096
    $disk=Join-Path $stage 'probe.qcow2'
    $converted=Invoke-EzVmProcess -FilePath $status.QemuImg -ArgumentList @('convert','-f','qcow2','-O','qcow2',$image.path,$disk) -TimeoutSeconds 180
    if($converted.ExitCode -ne 0){throw 'diagnostic-conversion-failed'}
    $profile=[IO.File]::ReadAllText((Join-Path $root 'guest/profiles/coding-default/v1/provision.sh'))
    $matches=[regex]::Matches($profile,'(?s)<<"EZVM_PIP_BOOTSTRAP"\r?\n(.*?)\r?\nEZVM_PIP_BOOTSTRAP')
    if($matches.Count -ne 1){throw 'exact-production-bootstrap-required'}
    $bootstrap=$matches[0].Groups[1].Value.Replace("`r`n","`n")+"`n"
    $bootstrapBytes=[Text.Encoding]::UTF8.GetBytes($bootstrap)
    $hasher=[Security.Cryptography.SHA256]::Create()
    try{$bootstrapSha=([BitConverter]::ToString($hasher.ComputeHash($bootstrapBytes))).Replace('-','').ToLowerInvariant()}finally{$hasher.Dispose()}
    $id=[Guid]::NewGuid().ToString('N')
    $binding=@{attemptId=$AttemptId;buildId=$id}|ConvertTo-Json -Compress
    $script=@'
#!/bin/sh
set -eu
umask 077
exec > /dev/ttyS0 2>&1
trap 'status=$?; printf "\nVENV_STAGE_TERMINAL=%s\n" "$status"; sync; systemctl poweroff' 0
cloud-init status --wait >/var/log/venv-stage-cloud-init.log 2>&1
id venvprobe >/dev/null 2>&1 || useradd --create-home --shell /bin/sh venvprobe
python3 /usr/local/lib/ezvm-venv-stages.py
'@
    $userdata="#cloud-config`npackage_update: true`npackage_upgrade: false`npackages:`n  - python3-venv`nwrite_files:`n"
    $files=@(
        @{path='/usr/local/lib/ezvm-stage-binding.json';content=$binding;mode='0644'},
        @{path='/usr/local/lib/ezvm-stage-bootstrap.py';content=$bootstrap;mode='0644'},
        @{path='/usr/local/lib/ezvm-venv-stages.py';content=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'venv-stages.py'));mode='0644'},
        @{path='/usr/local/sbin/venv-stage-probe';content=$script;mode='0700'})
    foreach($file in $files){
        $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($file.content.Replace("`r`n","`n")))
        $userdata+="  - path: "+$file.path+"`n    owner: root:root`n    permissions: '"+$file.mode+"'`n    encoding: b64`n    content: "+$encoded+"`n"
    }
    $userdata+="runcmd:`n  - [systemd-run, --no-block, --unit=venv-stage-probe, --property=Type=oneshot, /usr/local/sbin/venv-stage-probe]`n"
    $firmware=& (Get-Module EzVm) {param($r,$s) Get-EzVmBaseFirmwarePaths -Root $r -StagingDirectory $s} $root $stage
    $serial=Join-Path $stage 'serial.private.log'
    $seed=Start-EzVmSeedServer -UserData $userdata -MetaData ("instance-id: venv-stages-"+$id+"`nlocal-hostname: venv-stages`n") -TimeoutSeconds 2700
    $command=New-EzVmBaseQemuArguments -BuildId $id -Recipe $recipe -StagingDisk $disk -FirmwareCode $firmware.Code -FirmwareVariables $firmware.Variables -SerialLog $serial -SeedHostPort $seed.Port -Accelerator tcg
    $job=New-Object RunlocPoc.OwnedProcess($status.QemuSystem,$command.Arguments,$stage,$stage,(Join-Path $stage 'process.private.log'),1048576)
    $beat=0
    while(-not $job.HasExited){
        $null=Invoke-EzVmSeedServerPending -Server $seed -MaxRequests 8
        [void]$job.Drain()
        if($clock.Elapsed.TotalSeconds -ge 2670 -or $job.OutputFailed -or $job.OutputOverflow){throw 'diagnostic-wall-or-output-failure'}
        if([IO.File]::Exists($serial) -and (Get-Item -LiteralPath $serial).Length -gt 8388608){throw 'diagnostic-serial-bound'}
        if($clock.Elapsed.TotalSeconds-$beat -ge 15){Write-Host ([DateTime]::UtcNow.ToString('o')+' VENV_STAGE_HEARTBEAT elapsed='+[Math]::Round($clock.Elapsed.TotalSeconds)+' owned='+$job.ActiveProcesses);$beat=$clock.Elapsed.TotalSeconds}
        Start-Sleep -Milliseconds 100
    }
    $drained=$job.FinishOutput(3000);[void]$job.Drain()
    if(-not [IO.File]::Exists($serial) -or (Get-Item -LiteralPath $serial).Length -gt 8388608){throw 'diagnostic-serial-unavailable'}
    $text=[IO.File]::ReadAllText($serial)
    $records=@([regex]::Matches($text,'(?m)^VENV_STAGE (\{[^\r\n]{1,8192}\})\r?$')|ForEach-Object {$_.Groups[1].Value|ConvertFrom-Json})
    $recordsPath=Join-Path $stage 'records.private.json'
    [IO.File]::WriteAllText($recordsPath,($records|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $approved=& python (Join-Path $PSScriptRoot 'venv-stages.py') --validate $recordsPath $AttemptId $id $bootstrapSha
    if($LASTEXITCODE -ne 0){throw 'diagnostic-record-oracle-rejected'}
    $parsed=($approved -join "`n")|ConvertFrom-Json
    $records=@($parsed)
    $complete=@($records|Where-Object {$_.kind -ceq 'completed' -and $_.variants -eq 8 -and $_.diagnosticOnly -eq $true -and $_.qualificationPassed -eq $false}).Count -eq 1
    $result=@{schemaVersion=1;diagnosticOnly=$true;qualificationPassed=$false;attemptId=$AttemptId;buildId=$id;bootstrapSha256=$bootstrapSha;candidate=$identity;controller=$controller;runId=([long]$RunId);workflowCommit=$SourceCommit;records=$records;probeComplete=$complete;cpus=6;accelerator='tcg';actualExit=$job.ExitCode;activeProcesses=$job.ActiveProcesses;outputComplete=$drained;serialSha256=(Get-PilotDigest $serial);qemuSha256=(Get-PilotDigest $status.QemuSystem);imageSha256=$image.sha256;elapsedSeconds=$clock.Elapsed.TotalSeconds}
    if(-not $complete -or $job.ExitCode -ne 0 -or $job.ActiveProcesses -ne 0 -or -not $drained -or $job.OutputFailed -or $job.OutputOverflow){throw 'diagnostic-incomplete'}
}finally{
    if($null -ne $job){try{
        if(-not $job.HasExited -or $job.ActiveProcesses -gt 0){$forced=$true;$job.Terminate()}
        $deadline=[DateTime]::UtcNow.AddSeconds(30)
        while($job.ActiveProcesses -gt 0 -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 100}
        if($job.ActiveProcesses -ne 0){$errors+='owned-processes-remain'}
    }catch{$errors+='owned-cleanup-unavailable'}finally{$job.Dispose()}}
    if($null -ne $seed){try{Stop-EzVmSeedServer -Server $seed}catch{$errors+='seed-cleanup-unavailable'}}
    $after=Get-PilotSourceIdentity -Root $source -Repository 'https://github.com/techrote/ezvm' -ExpectedCommit $SourceCommit
    if($after.executedTreeSha256 -cne $identity.executedTreeSha256){$errors+='source-changed'}
    if($null -eq $result){$result=@{schemaVersion=1;diagnosticOnly=$true;qualificationPassed=$false;probeComplete=$false;candidate=$identity;runId=([long]$RunId)}}
    $result.forced=$forced;$result.errors=$errors;$result.sourceUnchanged=$after.executedTreeSha256 -ceq $identity.executedTreeSha256
    Write-PilotNewJson -Path (Join-Path $evidence 'workload-result.private.json') -Value $result
    if($forced -or $errors.Count -gt 0){throw 'diagnostic-cleanup-or-source-failure'}
}
