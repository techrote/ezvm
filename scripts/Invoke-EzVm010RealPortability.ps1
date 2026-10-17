#requires -Version 5.1
[CmdletBinding()]
param([string]$Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')), [switch]$SecurityQualification, [switch]$ReleaseQualification, [switch]$TcgTimerCheckWorkaround)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($TcgTimerCheckWorkaround -and -not $ReleaseQualification) {
    throw 'The TCG timer workaround is restricted to explicit disposable release qualification.'
}
if ($ReleaseQualification) { $SecurityQualification = $true }
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'EZVM-010 real qualification requires Windows and the reviewed managed Windows QEMU runtime.'
}

$sourceRoot = [IO.Path]::GetFullPath($Root)
$work = Join-Path ([IO.Path]::GetTempPath()) ('ezvm010 qualification ' + [Guid]::NewGuid().ToString('N'))
$rootA = Join-Path $work 'root A with spaces'
$rootB = Join-Path $work 'moved root B with spaces'
$heldRootA = Join-Path $work 'source root A held for relocation'
$rootARenamed = $false
[void][IO.Directory]::CreateDirectory($rootA)
# A fresh qualification root must never incorporate an existing user's runtime.
foreach ($relative in @('ezvm.ps1', 'src', 'config', 'manifests', 'guest', 'scripts', 'tests', 'docs', 'README.md', 'AGENTS.md', 'THIRD-PARTY-NOTICES.md', '.github', '.gitattributes', '.gitignore')) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot $relative) -Destination $rootA -Recurse -Force
}
# Opt-in fixture adjustment is confined to this freshly created copy, never the
# checkout, vendor image, a published base, or an owner's runtime.
. (Join-Path $PSScriptRoot 'TcgQualification.ps1')
if ($TcgTimerCheckWorkaround) {
    $templatePath = Join-Path $rootA 'guest/base-cloud-init/user-data.yaml'
    $template = [IO.File]::ReadAllText($templatePath)
    $effective = New-EzVmTcgTimerQualificationSeed -Template $template
    $originalHash = (Get-FileHash -LiteralPath $templatePath -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($templatePath, $effective, (New-Object Text.UTF8Encoding($false)))
    $effectiveHash = (Get-FileHash -LiteralPath $templatePath -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Host ('EZVM012_TCG_FIXTURE=opt-in-no_timer_check; originalTemplateSha256=' + $originalHash + '; effectiveTemplateSha256=' + $effectiveHash)
    Write-Host 'EZVM012_TCG_FIXTURE_LIMIT=The initial vendor-image boot is unmodified; subsequent prepared-base boots use the compatibility option.'
}
$Root = $rootA
Import-Module (Join-Path $Root 'src/EzVm/EzVm.psd1') -Force -ErrorAction Stop
$active = New-Object 'System.Collections.Generic.List[string]'
$sourceName = 'ezvm010-source'
$cloneName = 'ezvm010-stateful'
$importName = 'ezvm010-imported'
$secondaryName = 'ezvm012-secondary'
$freshName = 'ezvm012-fresh'
$sentinel = 'EZVM010_SOURCE_' + [Guid]::NewGuid().ToString('N')
$restartSentinel = 'EZVM012_RESTART_' + [Guid]::NewGuid().ToString('N')
$cloneSentinel = 'EZVM010_CLONE_' + [Guid]::NewGuid().ToString('N')
$authSentinel = 'EZVM010_SYNTHETIC_AUTH_' + [Guid]::NewGuid().ToString('N')
$outboundSentinel = 'EZVM010_SYNTHETIC_OUTBOUND_KEY_FIXTURE_' + [Guid]::NewGuid().ToString('N')

function Invoke-EzVm010Image {
    param([Parameter(Mandatory = $true)][string[]]$Arguments, [switch]$AllowDifferent)
    $tool = Get-EzVmQemuToolPath -Root $Root -Name 'qemu-img.exe'
    $result = Invoke-EzVmProcess -FilePath $tool -ArgumentList $Arguments -WorkingDirectory (Split-Path -Parent $tool) -TimeoutSeconds 120
    if ([int]$result.ExitCode -ne 0 -and -not ($AllowDifferent -and [int]$result.ExitCode -eq 1)) {
        throw "Real qemu-img check failed: exit=$($result.ExitCode); $($result.StdErr)"
    }
    return $result
}

function Assert-EzVm010SameImage {
    param([string]$First, [string]$Second, [switch]$Different)
    $compared = Invoke-EzVm010Image -Arguments @('compare', '-f', 'qcow2', '-F', 'qcow2', $First, $Second) -AllowDifferent
    $expected = if ($Different) { 1 } else { 0 }
    if ([int]$compared.ExitCode -ne $expected) { throw "Real guest-visible image comparison expected exit $expected; received $($compared.ExitCode)." }
}

function Assert-EzVm010Refused {
    param([string]$Description, [scriptblock]$Action, [string]$Pattern)
    $rejected = $false
    try { $null = & $Action }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw }
        $rejected = $true
        Write-Host ('EZVM010_EXPECTED_REFUSAL=' + $Description + ': ' + $_.Exception.Message)
    }
    if (-not $rejected) { throw "Expected refusal did not occur: $Description" }
}

function Get-EzVm010Disk {
    param([string]$Name)
    return (Get-EzVmInstanceStoragePaths -Root $Root -InstanceName $Name).Disk
}

function Invoke-EzVm010Guest {
    param([string]$Name, [string]$Script, [int]$TimeoutSeconds = 120)
    $result = Invoke-EzVmExec -Root $Root -InstanceName $Name -Command @('sh', '-lc', $Script) -TimeoutSeconds $TimeoutSeconds
    if ([int]$result.ExitCode -ne 0) {
        throw "Real portability guest check '$Name' failed: exit=$($result.ExitCode); stdout=<$($result.StdOut)> stderr=<$($result.StdErr)>"
    }
    return [string]$result.StdOut
}

function Start-EzVm010Guest {
    param([string]$Name)
    if (-not $active.Contains($Name)) { $active.Add($Name) }
    Write-Host ('EZVM010_STEP=guest_start; instance=' + $Name + '; at=' + [DateTime]::UtcNow.ToString('o') + '; root=' + $Root)
    try {
        $ready = Start-EzVmReadyInstance -Root $Root -InstanceName $Name -Accelerator tcg -ReadyTimeoutSeconds 900
        if ($ready.state -cne 'READY' -or $ready.accelerator -cne 'tcg' -or $ready.sshHost -cne '127.0.0.1') {
            throw "Guest '$Name' did not reach coding READY under explicit TCG and localhost-only SSH."
        }
    }
    catch {
        Write-Host ('EZVM010_STEP=guest_start_failed; instance=' + $Name + '; at=' + [DateTime]::UtcNow.ToString('o'))
        throw
    }
    Write-Host ('EZVM010_STEP=guest_ready; instance=' + $Name + '; at=' + [DateTime]::UtcNow.ToString('o'))
    if ($TcgTimerCheckWorkaround) {
        $timerEvidence = (Invoke-EzVm010Guest -Name $Name -Script (Get-EzVmTcgTimerQualificationProbe) -TimeoutSeconds 60).Trim()
        if ($timerEvidence -cnotmatch '^EZVM012_TCG_TIMER_COMPATIBILITY=PASS; clocksource=[a-z0-9_-]+; before=[0-9.]+; after=[0-9.]+$') {
            throw 'Authenticated guest omitted the required TCG timer compatibility evidence.'
        }
        Write-Host ('EZVM012_TCG_INSTANCE=' + $Name + '; ' + $timerEvidence)
    }
}

function Stop-EzVm010Guest {
    param([string]$Name)
    $stopped = Stop-EzVmInstance -Root $Root -InstanceName $Name -ShutdownTimeoutSeconds 120
    if ($stopped.state -cne 'STOPPED') { throw "Guest '$Name' did not stop cleanly." }
    [void]$active.Remove($Name)
}

function Assert-EzVm012Doctor {
    param([switch]$RequireManagedQemu)
    $report = Get-EzVmDoctorReport -Root $Root
    if ([bool]$report.whpxExecutionTested) { throw 'doctor must not claim WHPX execution without an actual accelerator run.' }
    $hostCheck = @($report.checks | Where-Object { $_.name -ceq 'host-os' })
    $managed = @($report.checks | Where-Object { $_.name -ceq 'managed-qemu' })
    if ($hostCheck.Count -ne 1 -or $managed.Count -ne 1) { throw 'doctor omitted required host or managed-QEMU evidence.' }
    if ($RequireManagedQemu) {
        if ($managed[0].status -cne 'ready') { throw 'doctor did not validate the reviewed managed QEMU runtime after bootstrap/relocation.' }
    }
    elseif ($managed[0].status -ceq 'ready') {
        throw 'Fresh release qualification root unexpectedly contained a pre-bootstrapped QEMU runtime.'
    }
    Write-Host ('EZVM012_DOCTOR=status=' + $report.status + '; host=' + $hostCheck[0].status + '; managed-qemu=' + $managed[0].status + '; whpxExecutionTested=' + $report.whpxExecutionTested)
    return $report
}

function Get-EzVm010GuestFacts {
    param([string]$Name)
    $script = @'
set -eu
fixture_sha256() {
  if test -f "$1"; then sha256sum "$1" | cut -d ' ' -f1; fi
}
jq -n --arg machineId "$(cat /etc/machine-id)" \
  --arg hostKey "$(cut -d ' ' -f2 /etc/ssh/ssh_host_ed25519_key.pub)" \
  --rawfile authorizedKeys /home/coder/.ssh/authorized_keys \
  --arg authFixtureSha256 "$(fixture_sha256 /home/coder/.config/ezvm-portability-fixture/auth.json)" \
  --arg outboundFixtureSha256 "$(fixture_sha256 /home/coder/.ssh/id_ezvm_portability_fixture)" \
  --slurpfile identity /etc/ezvm/identity.json \
  --slurpfile ready /var/lib/ezvm/ready.json \
  '{machineId:$machineId,hostKey:$hostKey,authorizedKeys:$authorizedKeys,authFixtureSha256:$authFixtureSha256,outboundFixtureSha256:$outboundFixtureSha256,identity:$identity[0],ready:$ready[0]}'
'@
    $facts = (Invoke-EzVm010Guest -Name $Name -Script $script -TimeoutSeconds 60) | ConvertFrom-Json -ErrorAction Stop
    $intent = Get-EzVmInstanceIntent -Root $Root -InstanceName $Name
    $access = Get-EzVmSshAccessState -Root $Root -InstanceName $Name -RequireReady
    if ($facts.machineId -cnotmatch '^[a-f0-9]{32}$' -or [string]::IsNullOrWhiteSpace([string]$facts.hostKey)) {
        throw 'Guest machine/SSH identity evidence was malformed.'
    }
    $controllerKey = [IO.File]::ReadAllText((Get-EzVmSshPaths -Root $Root).ControllerPublicKey).Trim()
    $expectedAuthorizedKeys = [string]::Join(' ', @($controllerKey -split ' ' | Select-Object -First 2)) + "`n"
    if ($facts.authorizedKeys -cne $expectedAuthorizedKeys) {
        throw 'Guest inbound authorized_keys did not contain exactly the destination controller public key.'
    }
    foreach ($document in @($facts.identity, $facts.ready)) {
        if ($document.instanceName -cne $Name -or $document.baseId -cne $intent.baseId -or $document.cloudInstanceId -cne $access.cloudInstanceId -or $document.provisioningDigest -cne $access.provisioningDigest) {
            throw 'Copied guest identity or readiness did not match destination intent and accepted access.'
        }
    }
    if ($facts.ready.provisioningState -cne 'complete') { throw 'Destination guest did not report completed coding provisioning.' }
    return $facts
}

function Assert-EzVm010NewIdentity {
    param([object]$Original, [object]$Copy)
    if ($Original.identity.cloudInstanceId -ceq $Copy.identity.cloudInstanceId -or $Original.machineId -ceq $Copy.machineId -or $Original.hostKey -ceq $Copy.hostKey) {
        throw 'A reset or copied guest retained source cloud, machine or SSH host identity.'
    }
}

function Assert-EzVm010PreservedSyntheticState {
    param([object]$Original, [object]$Copy)
    foreach ($field in @('authFixtureSha256', 'outboundFixtureSha256')) {
        if ($Original.$field -cnotmatch '^[a-f0-9]{64}$' -or $Original.$field -cne $Copy.$field) {
            throw 'A copied guest changed the bytes of its synthetic auth or outbound SSH fixture.'
        }
    }
}

try {
    Write-Host ('EZVM010_STARTED_AT=' + [DateTime]::UtcNow.ToString('o'))
    Write-Host ('EZVM010_QUALIFICATION_ROOT=' + $work)
    Write-Host 'EZVM010_ACCELERATOR=tcg'
    Write-Host 'EZVM010_WHPX_EXECUTION=SKIP: GitHub-hosted qualification uses explicit TCG; no WHPX execution PASS is claimed.'
    if ($ReleaseQualification) {
        $null = Assert-EzVm012Doctor
        Write-Host 'EZVM012_REAL_FRESH_ROOT_DOCTOR=PASS'
    }
    $bootstrap = Install-EzVmQemuRuntime -Root $Root
    Write-Host ('EZVM010_REAL_QEMU=' + $bootstrap.version)
    if ($ReleaseQualification) {
        $null = Assert-EzVm012Doctor -RequireManagedQemu
        Write-Host 'EZVM012_REAL_BOOTSTRAP_DOCTOR=PASS'
    }

    Write-Host 'EZVM010_STEP=tiny_real_images'
    $tinyInput = Join-Path $work 'tiny pristine.qcow2'
    $null = Invoke-EzVm010Image -Arguments @('create', '-f', 'qcow2', $tinyInput, '64M')
    $tinySource = Import-EzVmManagedInstance -Root $Root -InstanceName 'tiny-source' -ImagePath $tinyInput -Profile light
    $tinySourceDisk = Get-EzVm010Disk -Name 'tiny-source'
    $tinyBase = Test-EzVmPreparedBase -Root $Root -BaseId $tinySource.baseId
    Assert-EzVm010SameImage -First $tinySourceDisk -Second $tinyBase.Image
    # The documented qemu-img bench writer supplies exactly one 4KiB non-zero
    # fixture write. This is a content fixture, not a performance qualification.
    $null = Invoke-EzVm010Image -Arguments @('bench', '-w', '-c', '1', '-d', '1', '-s', '4096', '--pattern=90', '-f', 'qcow2', $tinySourceDisk)
    Assert-EzVm010SameImage -First $tinySourceDisk -Second $tinyBase.Image -Different
    $tinyFresh = Copy-EzVmManagedInstance -Root $Root -SourceInstanceName 'tiny-source' -DestinationInstanceName 'tiny-fresh' -Mode fresh
    $tinyCopy = Copy-EzVmManagedInstance -Root $Root -SourceInstanceName 'tiny-source' -DestinationInstanceName 'tiny-stateful' -Mode stateful
    Assert-EzVm010SameImage -First (Get-EzVm010Disk 'tiny-fresh') -Second $tinyBase.Image
    Assert-EzVm010SameImage -First (Get-EzVm010Disk 'tiny-stateful') -Second $tinySourceDisk
    if ($tinyFresh.baseId -cne $tinySource.baseId -or $tinyCopy.baseId -ceq $tinySource.baseId) {
        throw 'Fresh/stateful clone base identities did not express their documented baseline semantics.'
    }
    $tinyExport = Export-EzVmManagedInstance -Root $Root -InstanceName 'tiny-source' -DestinationDirectory (Join-Path $work 'tiny export')
    $exportInfo = (Invoke-EzVm010Image -Arguments @('info', '--output=json', '-f', 'qcow2', $tinyExport.Image)).StdOut | ConvertFrom-Json
    if ($null -ne $exportInfo.PSObject.Properties['backing-filename'] -and -not [string]::IsNullOrWhiteSpace([string]$exportInfo.'backing-filename')) { throw 'Export retained a backing dependency.' }
    Assert-EzVm010SameImage -First $tinyExport.Image -Second $tinySourceDisk
    $tinyImported = Import-EzVmManagedInstance -Root $Root -InstanceName 'tiny-imported' -ImagePath $tinyExport.Image -ManifestPath $tinyExport.ManifestPath -Profile light
    Assert-EzVm010SameImage -First (Get-EzVm010Disk 'tiny-imported') -Second $tinySourceDisk
    $sourceDigest = Get-EzVmFileDigest -Path $tinySourceDisk -Algorithm SHA256
    $exportDigest = Get-EzVmFileDigest -Path $tinyExport.Image -Algorithm SHA256
    if ($tinyExport.Manifest.imageSha256 -cne $exportDigest -or [long]$tinyExport.Manifest.virtualSizeBytes -ne 67108864 -or $tinyExport.Manifest.source.instance.name -cne 'tiny-source' -or $tinyExport.Manifest.source.instance.baseId -cne $tinySource.baseId) {
        throw 'Export manifest does not match independent image digest, size and source identity.'
    }
    Assert-EzVm010Refused -Description 'export destination already exists' -Pattern 'exist|overwrite' -Action {
        Export-EzVmManagedInstance -Root $Root -InstanceName 'tiny-source' -DestinationDirectory $tinyExport.Directory
    }
    if ((Get-EzVmFileDigest -Path $tinySourceDisk -Algorithm SHA256) -cne $sourceDigest -or (Get-EzVmFileDigest -Path $tinyExport.Image -Algorithm SHA256) -cne $exportDigest) {
        throw 'Failed export changed source or existing destination data.'
    }
    $null = Reset-EzVmManagedInstance -Root $Root -InstanceName 'tiny-source'
    Assert-EzVm010SameImage -First $tinySourceDisk -Second $tinyBase.Image
    Assert-EzVm010SameImage -First (Get-EzVm010Disk 'tiny-stateful') -Second $tinyExport.Image
    Assert-EzVm010SameImage -First (Get-EzVm010Disk 'tiny-stateful') -Second $tinySourceDisk -Different
    # A fresh clone/reset of a sensitive baseline restores that snapshot's
    # content, not the clean prepared base that originally preceded it.
    $null = Invoke-EzVm010Image -Arguments @('bench', '-w', '-c', '1', '-d', '1', '-s', '4096', '-o', '4096', '--pattern=91', '-f', 'qcow2', (Get-EzVm010Disk 'tiny-stateful'))
    Assert-EzVm010SameImage -First (Get-EzVm010Disk 'tiny-stateful') -Second $tinyExport.Image -Different
    $null = Copy-EzVmManagedInstance -Root $Root -SourceInstanceName 'tiny-stateful' -DestinationInstanceName 'tiny-snapshot-fresh' -Mode fresh
    Assert-EzVm010SameImage -First (Get-EzVm010Disk 'tiny-snapshot-fresh') -Second $tinyExport.Image
    $snapshotReset = Reset-EzVmManagedInstance -Root $Root -InstanceName 'tiny-stateful'
    if (-not $snapshotReset.sensitiveState -or $snapshotReset.baseId -cne $tinyCopy.baseId) { throw 'Sensitive snapshot reset did not report its existing baseline.' }
    Assert-EzVm010SameImage -First (Get-EzVm010Disk 'tiny-stateful') -Second $tinyExport.Image
    foreach ($name in @('tiny-source', 'tiny-fresh', 'tiny-stateful', 'tiny-imported', 'tiny-snapshot-fresh')) {
        $intent = Get-EzVmInstanceIntent -Root $Root -InstanceName $name
        $chain = Test-EzVmInstanceStorage -Root $Root -InstanceName $name -BaseId $intent.baseId
        if ($chain.ChainDepth -ne 1 -or [IO.Path]::IsPathRooted($chain.BackingReference)) { throw 'Tiny managed instance violated one relative backing level.' }
    }
    $external = Join-Path $work 'external backing.qcow2'
    $null = Invoke-EzVm010Image -Arguments @('create', '-f', 'qcow2', '-F', 'qcow2', '-b', $tinyInput, $external)
    Assert-EzVm010Refused -Description 'import external backing' -Pattern 'backing|standalone' -Action {
        Import-EzVmManagedInstance -Root $Root -InstanceName 'bad-external' -ImagePath $external
    }
    $malformed = Join-Path $work 'malformed.qcow2'
    [IO.File]::WriteAllText($malformed, 'not a QCOW2 image', (New-Object Text.UTF8Encoding($false)))
    Assert-EzVm010Refused -Description 'import malformed image' -Pattern 'QCOW2|header|format|truncated' -Action {
        Import-EzVmManagedInstance -Root $Root -InstanceName 'bad-malformed' -ImagePath $malformed
    }
    Write-Host 'EZVM010_REAL_TINY_RESET_FRESH_STATEFUL_INDEPENDENCE=PASS'
    Write-Host 'EZVM010_REAL_SENSITIVE_BASELINE_RESET_AND_FRESH=PASS'
    Write-Host 'EZVM010_REAL_STANDALONE_EXPORT_IMPORT=PASS'
    Write-Host 'EZVM010_REAL_UNSAFE_IMPORT_REFUSAL=PASS'
    Write-Host 'EZVM010_REAL_FAILED_EXPORT_PRESERVES_DATA=PASS'

    Write-Host 'EZVM010_STEP=prepare_real_guest'
    $source = Invoke-EzVmSourceImageAcquire -Root $Root
    Write-Host ('EZVM010_REAL_SOURCE_SHA256=' + $source.sha256)
    Write-Host ('EZVM010_STEP=base_build_started; at=' + [DateTime]::UtcNow.ToString('o'))
    $base = Invoke-EzVmBaseBuild -Root $Root -Accelerator tcg -BuildTimeoutSeconds 2400
    Write-Host ('EZVM010_STEP=base_build_completed; at=' + [DateTime]::UtcNow.ToString('o') + '; base=' + $base.baseId)
    $prepared = Test-EzVmPreparedBase -Root $Root -BaseId $base.baseId
    if ($prepared.Manifest.build.accelerator -cne 'tcg') { throw 'Base build did not record explicit TCG.' }
    $sourceCreate = @{ Root = $Root; InstanceName = $sourceName; BaseId = $base.baseId }
    if (-not $ReleaseQualification) { $sourceCreate.Profile = 'light' }
    $created = New-EzVmManagedInstance @sourceCreate
    if ($ReleaseQualification -and $created.profile -cne 'normal') { throw 'Release qualification did not create the normal default coding instance.' }
    Start-EzVm010Guest -Name $sourceName
    $sourceIntent = Get-EzVmInstanceIntent -Root $Root -InstanceName $sourceName
    if ($ReleaseQualification) {
        $secondary = New-EzVmManagedInstance -Root $Root -InstanceName $secondaryName -BaseId $base.baseId -Profile light
        if ([int]$secondary.sshPort -eq [int]$sourceIntent.sshPort -or $secondary.identityGeneration -ceq $sourceIntent.identityGeneration) {
            throw 'Second release instance did not receive unique durable resources.'
        }
        Start-EzVm010Guest -Name $secondaryName
        $sourceRunning = Get-EzVmInstanceStatus -Root $Root -InstanceName $sourceName
        $secondaryRunning = Get-EzVmInstanceStatus -Root $Root -InstanceName $secondaryName
        if ($sourceRunning.state -cne 'RUNNING' -or $secondaryRunning.state -cne 'RUNNING' -or
            [int]$sourceRunning.qmpPort -eq [int]$secondaryRunning.qmpPort -or
            [int]$sourceRunning.pid -eq [int]$secondaryRunning.pid) {
            throw 'Two real release guests were not concurrently RUNNING with distinct process/QMP resources.'
        }
        $sourceConcurrent = (Invoke-EzVm010Guest -Name $sourceName -Script "printf '%s' EZVM012_SOURCE_CONCURRENT").Trim()
        $secondaryConcurrent = (Invoke-EzVm010Guest -Name $secondaryName -Script "printf '%s' EZVM012_SECONDARY_CONCURRENT").Trim()
        if ($sourceConcurrent -cne 'EZVM012_SOURCE_CONCURRENT' -or $secondaryConcurrent -cne 'EZVM012_SECONDARY_CONCURRENT') {
            throw 'Concurrent release guests did not both execute authenticated commands.'
        }
        Stop-EzVm010Guest -Name $secondaryName
        Write-Host 'EZVM012_REAL_TWO_CONCURRENT_READY_GUESTS=PASS'
    }
    if ($SecurityQualification) {
        Write-Host 'EZVM011_STEP=real_host_transfer_and_diagnosis'
        $transferInput = Join-Path $work 'synthetic input [spaces].bin'
        $transferOutput = Join-Path $work 'synthetic output [spaces].bin'
        $bytes = New-Object byte[] 4096
        for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [byte]($i % 251) }
        [IO.File]::WriteAllBytes($transferInput, $bytes)
        $null = Invoke-EzVmCopyToGuest -Root $Root -InstanceName $sourceName -HostPath $transferInput -GuestPath '/home/coder/workspace/ezvm011-transfer.bin' -TimeoutSeconds 120
        [IO.File]::WriteAllText($transferOutput, 'old host output must survive a failed transfer')
        $oldOutputDigest = Get-EzVmFileDigest -Path $transferOutput -Algorithm SHA256
        Assert-EzVm010Refused -Description 'failed copy preserves destination' -Pattern 'copy-from failed' -Action {
            Invoke-EzVmCopyFromGuest -Root $Root -InstanceName $sourceName -GuestPath '/home/coder/workspace/ezvm011-does-not-exist' -HostPath $transferOutput -TimeoutSeconds 120
        }
        if ((Get-EzVmFileDigest -Path $transferOutput -Algorithm SHA256) -cne $oldOutputDigest) { throw 'Failed SCP changed existing host bytes.' }
        $null = Invoke-EzVmCopyFromGuest -Root $Root -InstanceName $sourceName -GuestPath '/home/coder/workspace/ezvm011-transfer.bin' -HostPath $transferOutput -TimeoutSeconds 120
        if ((Get-EzVmFileDigest -Path $transferOutput -Algorithm SHA256) -cne (Get-EzVmFileDigest -Path $transferInput -Algorithm SHA256)) { throw 'Real binary SCP round trip changed bytes.' }
        Assert-EzVm010Refused -Description 'managed runtime cannot be an SCP destination' -Pattern 'managed runtime' -Action {
            Invoke-EzVmCopyFromGuest -Root $Root -InstanceName $sourceName -GuestPath '/home/coder/workspace/ezvm011-transfer.bin' -HostPath (Get-EzVmInstanceRuntimePaths -Root $Root -InstanceName $sourceName).Intent
        }
        $diagnosis = Get-EzVmInstanceDiagnosis -Root $Root -InstanceName $sourceName -CheckImage
        if ($diagnosis.lifecycleState -cne 'RUNNING' -or $diagnosis.imageCheck -cne 'refused' -or $diagnosis.repairsPerformed) { throw 'Running diagnosis reached offline image checking or changed state.' }
        Write-Host 'EZVM011_REAL_SCP_ROUNDTRIP_AND_FAILED_DESTINATION_PRESERVATION=PASS'
        Write-Host 'EZVM011_REAL_RUNNING_DIAGNOSIS_AND_RUNTIME_TRANSFER_REFUSAL=PASS'
    }
    # These are clearly synthetic persistence fixtures, never vendor credentials
    # or a usable private SSH key. Only their independent SHA-256 digests enter
    # the evidence, and copied inbound access is checked separately above.
    $fixtureScript = @'
set -eu
umask 077
mkdir -p /home/coder/.config/ezvm-portability-fixture /home/coder/.ssh
printf '%s\n' '__WORKSPACE_SENTINEL__' > /home/coder/workspace/ezvm010-source.txt
printf '%s\n' '{"fixture":"synthetic-only","sentinel":"__AUTH_SENTINEL__"}' > /home/coder/.config/ezvm-portability-fixture/auth.json
printf '%s\n' '__OUTBOUND_SENTINEL__' > /home/coder/.ssh/id_ezvm_portability_fixture
sync
'@
    $fixtureScript = $fixtureScript.Replace('__WORKSPACE_SENTINEL__', $sentinel).Replace('__AUTH_SENTINEL__', $authSentinel).Replace('__OUTBOUND_SENTINEL__', $outboundSentinel)
    $null = Invoke-EzVm010Guest -Name $sourceName -Script $fixtureScript
    $sourceFacts = Get-EzVm010GuestFacts -Name $sourceName
    if ($ReleaseQualification) {
        $null = Invoke-EzVm010Guest -Name $sourceName -Script ("set -eu; printf '%s\n' '" + $restartSentinel + "' > /home/coder/workspace/ezvm012-restart.txt; sync")
        Stop-EzVm010Guest -Name $sourceName
        Start-EzVm010Guest -Name $sourceName
        $restartFacts = Get-EzVm010GuestFacts -Name $sourceName
        Assert-EzVm010PreservedSyntheticState -Original $sourceFacts -Copy $restartFacts
        if ($restartFacts.machineId -cne $sourceFacts.machineId -or $restartFacts.hostKey -cne $sourceFacts.hostKey -or
            $restartFacts.identity.cloudInstanceId -cne $sourceFacts.identity.cloudInstanceId) {
            throw 'Normal stop/restart changed stable guest identity.'
        }
        $restartCheck = (Invoke-EzVm010Guest -Name $sourceName -Script 'set -eu; cat /home/coder/workspace/ezvm010-source.txt; cat /home/coder/workspace/ezvm012-restart.txt').Trim() -replace '\r\n', [string][char]10
        if ($restartCheck -cne ($sentinel + [char]10 + $restartSentinel)) { throw 'Normal stop/restart lost mutable guest state.' }
        Write-Host 'EZVM012_REAL_STOP_RESTART_PERSISTENCE=PASS'
    }
    foreach ($operation in @('reset', 'stateful-clone', 'export', 'portability')) {
        Assert-EzVm010Refused -Description ('running source ' + $operation) -Pattern 'running|stopped|ownership|lifecycle|active' -Action {
            switch ($operation) {
                'reset' { Reset-EzVmManagedInstance -Root $Root -InstanceName $sourceName }
                'stateful-clone' { Copy-EzVmManagedInstance -Root $Root -SourceInstanceName $sourceName -DestinationInstanceName 'running-copy-must-fail' -Mode stateful }
                'export' { Export-EzVmManagedInstance -Root $Root -InstanceName $sourceName -DestinationDirectory (Join-Path $work 'running export must fail') }
                'portability' { Test-EzVmPortableBundle -Root $Root }
            }
        }
    }
    Write-Host 'EZVM010_REAL_RUNNING_OPERATIONS_REFUSE=PASS'
    Stop-EzVm010Guest -Name $sourceName

    Write-Host 'EZVM010_STEP=copy_export_import'
    $fresh = $null
    if ($ReleaseQualification) {
        $fresh = Copy-EzVmManagedInstance -Root $Root -SourceInstanceName $sourceName -DestinationInstanceName $freshName -Mode fresh
        $freshIntent = Get-EzVmInstanceIntent -Root $Root -InstanceName $freshName
        if ($fresh.baseId -cne $sourceIntent.baseId -or $freshIntent.identityGeneration -ceq $sourceIntent.identityGeneration -or
            [int]$freshIntent.sshPort -eq [int]$sourceIntent.sshPort) {
            throw 'Real fresh clone did not preserve the clean baseline while allocating new identity/resources.'
        }
    }
    $clone = Copy-EzVmManagedInstance -Root $Root -SourceInstanceName $sourceName -DestinationInstanceName $cloneName -Mode stateful
    $export = Export-EzVmManagedInstance -Root $Root -InstanceName $sourceName -DestinationDirectory (Join-Path $work 'Ubuntu export')
    $imported = Import-EzVmManagedInstance -Root $Root -InstanceName $importName -ImagePath $export.Image -ManifestPath $export.ManifestPath -Profile light
    foreach ($destination in @($clone, $imported)) {
        $intent = Get-EzVmInstanceIntent -Root $Root -InstanceName $destination.name
        $chain = Test-EzVmInstanceStorage -Root $Root -InstanceName $destination.name -BaseId $intent.baseId
        if ($chain.ChainDepth -ne 1 -or $intent.baseId -ceq $sourceIntent.baseId -or $intent.identityGeneration -ceq $sourceIntent.identityGeneration -or [int]$intent.sshPort -eq [int]$sourceIntent.sshPort) {
            throw 'Real copied instance did not receive independent storage, identity and resources.'
        }
    }
    if ($ReleaseQualification) {
        Start-EzVm010Guest -Name $freshName
        $freshFacts = Get-EzVm010GuestFacts -Name $freshName
        Assert-EzVm010NewIdentity -Original $sourceFacts -Copy $freshFacts
        $null = Invoke-EzVm010Guest -Name $freshName -Script 'set -eu; test ! -e /home/coder/workspace/ezvm010-source.txt; test ! -e /home/coder/workspace/ezvm012-restart.txt; test ! -e /home/coder/.config/ezvm-portability-fixture/auth.json; test ! -e /home/coder/.ssh/id_ezvm_portability_fixture'
        Stop-EzVm010Guest -Name $freshName
        Write-Host 'EZVM012_REAL_FRESH_CLONE_PRISTINE_READY=PASS'
    }

    Write-Host 'EZVM010_STEP=reset_source_ready'
    $reset = Reset-EzVmManagedInstance -Root $Root -InstanceName $sourceName
    if ($reset.baseId -cne $sourceIntent.baseId -or $reset.identityGeneration -ceq $sourceIntent.identityGeneration) { throw 'Reset did not preserve its base and regenerate its identity.' }
    Start-EzVm010Guest -Name $sourceName
    $resetFacts = Get-EzVm010GuestFacts -Name $sourceName
    Assert-EzVm010NewIdentity -Original $sourceFacts -Copy $resetFacts
    $null = Invoke-EzVm010Guest -Name $sourceName -Script 'set -eu; test ! -e /home/coder/workspace/ezvm010-source.txt; test ! -e /home/coder/workspace/ezvm012-restart.txt; test ! -e /home/coder/.config/ezvm-portability-fixture/auth.json; test ! -e /home/coder/.ssh/id_ezvm_portability_fixture'
    Stop-EzVm010Guest -Name $sourceName
    Write-Host 'EZVM010_REAL_RESET_PRISTINE_READY=PASS'

    Write-Host 'EZVM010_STEP=stateful_clone_ready'
    Start-EzVm010Guest -Name $cloneName
    $cloneFacts = Get-EzVm010GuestFacts -Name $cloneName
    Assert-EzVm010NewIdentity -Original $sourceFacts -Copy $cloneFacts
    Assert-EzVm010PreservedSyntheticState -Original $sourceFacts -Copy $cloneFacts
    $preserved = Invoke-EzVm010Guest -Name $cloneName -Script 'set -eu; cat /home/coder/workspace/ezvm010-source.txt; if test -e /home/coder/workspace/ezvm012-restart.txt; then cat /home/coder/workspace/ezvm012-restart.txt; fi'
    $expectedCloneSource = if ($ReleaseQualification) { $sentinel + [char]10 + $restartSentinel } else { $sentinel }
    if (($preserved.Trim() -replace '\r\n', [string][char]10) -cne $expectedCloneSource) { throw 'Stateful clone lost source workspace data after source reset.' }
    $null = Invoke-EzVm010Guest -Name $cloneName -Script ("set -eu; printf '%s\n' '" + $cloneSentinel + "' > /home/coder/workspace/ezvm010-clone.txt; sync")
    Stop-EzVm010Guest -Name $cloneName
    Write-Host 'EZVM010_REAL_STATEFUL_NEW_IDENTITY_AND_CONTENT=PASS'

    Write-Host 'EZVM010_STEP=imported_guest_ready'
    Start-EzVm010Guest -Name $importName
    $importFacts = Get-EzVm010GuestFacts -Name $importName
    Assert-EzVm010NewIdentity -Original $sourceFacts -Copy $importFacts
    Assert-EzVm010NewIdentity -Original $cloneFacts -Copy $importFacts
    Assert-EzVm010PreservedSyntheticState -Original $sourceFacts -Copy $importFacts
    $preserved = Invoke-EzVm010Guest -Name $importName -Script 'set -eu; test ! -e /home/coder/workspace/ezvm010-clone.txt; cat /home/coder/workspace/ezvm010-source.txt; if test -e /home/coder/workspace/ezvm012-restart.txt; then cat /home/coder/workspace/ezvm012-restart.txt; fi'
    $expectedImported = if ($ReleaseQualification) { $sentinel + [char]10 + $restartSentinel } else { $sentinel }
    if (($preserved.Trim() -replace '\r\n', [string][char]10) -cne $expectedImported) { throw 'Imported guest did not preserve exactly the exported source state.' }
    Stop-EzVm010Guest -Name $importName
    Write-Host 'EZVM010_REAL_IMPORTED_NEW_IDENTITY_AND_CONTENT=PASS'

    Write-Host 'EZVM010_STEP=complete_cold_relocation'
    $before = Test-EzVmPortableBundle -Root $Root
    if (-not $before.Valid) { throw 'Stopped source bundle failed portability validation.' }
    $cloneIntentBefore = Get-Content -LiteralPath (Get-EzVmInstanceRuntimePaths -Root $Root -InstanceName $cloneName).Intent -Raw
    $cloneChainBefore = Test-EzVmInstanceStorage -Root $Root -InstanceName $cloneName -BaseId $clone.baseId
    [void][IO.Directory]::CreateDirectory($rootB)
    # Copy the entire prepared source/runtime root, including stopped metadata,
    # keys, locks, firmware and logs. No metadata deletion or rebase shortcut.
    foreach ($entry in Get-ChildItem -LiteralPath $rootA -Force) {
        Copy-Item -LiteralPath $entry.FullName -Destination $rootB -Recurse -Force
    }
    $Root = $rootB
    Import-Module (Join-Path $Root 'src/EzVm/EzVm.psd1') -Force -ErrorAction Stop
    # The complete source root was proven stopped before copying. Keep it
    # recoverable but unavailable at its original path throughout B's checks,
    # so neither loaded defaults nor stale absolute paths can fall back to A.
    [IO.Directory]::Move($rootA, $heldRootA)
    $rootARenamed = $true
    Write-Host ('EZVM010_STEP=source_root_unavailable; at=' + [DateTime]::UtcNow.ToString('o') + '; saved=' + $heldRootA)
    if ((Test-Path -LiteralPath $rootA) -or -not [string]::Equals((Get-EzVmRoot), $rootB, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Cold relocation requires the original root to be unavailable and the loaded module default to resolve to root B.'
    }
    if ($ReleaseQualification) {
        $null = Assert-EzVm012Doctor -RequireManagedQemu
        Write-Host 'EZVM012_REAL_RELOCATED_DOCTOR=PASS'
    }
    $moved = Test-EzVmPortableBundle -Root $Root
    $cloneChainAfter = Test-EzVmInstanceStorage -Root $Root -InstanceName $cloneName -BaseId $clone.baseId
    if (-not $moved.Valid -or [int]$moved.InstanceCount -ne [int]$before.InstanceCount -or $cloneChainAfter.BackingReference -cne $cloneChainBefore.BackingReference) {
        throw 'Complete stopped relocation did not preserve the registry and relative backing relationship.'
    }
    if ((Get-Content -LiteralPath (Get-EzVmInstanceRuntimePaths -Root $Root -InstanceName $cloneName).Intent -Raw) -cne $cloneIntentBefore) { throw 'Relocation changed durable instance intent.' }
    Start-EzVm010Guest -Name $cloneName
    $movedFacts = Get-EzVm010GuestFacts -Name $cloneName
    Assert-EzVm010PreservedSyntheticState -Original $cloneFacts -Copy $movedFacts
    if ($movedFacts.machineId -cne $cloneFacts.machineId -or $movedFacts.hostKey -cne $cloneFacts.hostKey -or $movedFacts.identity.cloudInstanceId -cne $cloneFacts.identity.cloudInstanceId) {
        throw 'A normal relocated restart unexpectedly changed stable guest identity.'
    }
    $preserved = Invoke-EzVm010Guest -Name $cloneName -Script 'set -eu; cat /home/coder/workspace/ezvm010-source.txt; if test -e /home/coder/workspace/ezvm012-restart.txt; then cat /home/coder/workspace/ezvm012-restart.txt; fi; cat /home/coder/workspace/ezvm010-clone.txt'
    $expectedRelocated = if ($ReleaseQualification) { $sentinel + [char]10 + $restartSentinel + [char]10 + $cloneSentinel } else { $sentinel + [char]10 + $cloneSentinel }
    if (($preserved.Trim() -replace '\r\n', [string][char]10) -cne $expectedRelocated) { throw 'Relocated guest did not preserve source and independent clone changes.' }
    $runtime = Get-Content -LiteralPath (Get-EzVmInstanceRuntimePaths -Root $Root -InstanceName $cloneName).Runtime -Raw | ConvertFrom-Json
    if (-not ([string]$runtime.qemuExecutable).StartsWith($rootB + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Relocated launch retained the old absolute QEMU path.' }
    Stop-EzVm010Guest -Name $cloneName
    $finalBundle = Test-EzVmPortableBundle -Root $Root
    if (-not $finalBundle.Valid) { throw 'Final stopped relocated bundle failed validation.' }
    Write-Host 'EZVM010_REAL_COLD_RELOCATION_READY=PASS'
    Write-Host 'EZVM010_REAL_RELATIVE_BACKING_AND_RUNTIME_REGENERATION=PASS'
    Write-Host 'EZVM010_REAL_GRACEFUL_STOP=PASS'
    Write-Host ('EZVM010_REAL_BASE=' + $base.baseId)
    Write-Host ('EZVM010_REAL_EXPORTED_SHA256=' + (Get-EzVmFileDigest -Path $export.Image -Algorithm SHA256))
    if ($SecurityQualification) { Write-Host 'EZVM011_REAL_COMPLETE_SECURITY_AND_PORTABILITY=PASS' }
    if ($ReleaseQualification) {
        Write-Host 'EZVM012_REAL_RELOCATED_DOCTOR_AND_RESTART=PASS'
        Write-Host 'EZVM012_REAL_COMPLETE_END_TO_END=PASS'
    }
    Write-Host ('EZVM010_COMPLETED_AT=' + [DateTime]::UtcNow.ToString('o'))
}
catch {
    Write-Host 'EZVM010_REAL_DIAGNOSTICS_BEGIN'
    Write-Host ('EZVM010_FAILED_AT=' + [DateTime]::UtcNow.ToString('o'))
    # Read only host-side state and controlled QEMU logs. Serial output is
    # diagnostic evidence, never a substitute for authenticated guest READY.
    # Do not inspect seed data, key files or guest credential contents here.
    foreach ($name in @($sourceName, $cloneName, $importName, $secondaryName, $freshName)) {
        try {
            $runtimePaths = Get-EzVmInstanceRuntimePaths -Root $Root -InstanceName $name
            foreach ($path in @($runtimePaths.Runtime, (Join-Path $runtimePaths.Directory 'access.json'))) {
                if (Test-Path -LiteralPath $path -PathType Leaf) {
                    Write-Host ('STATE_FILE=' + $path)
                    Get-Content -LiteralPath $path -Raw | Write-Host
                }
            }
            if (Test-Path -LiteralPath $runtimePaths.Logs -PathType Container) {
                $logs = Get-ChildItem -LiteralPath $runtimePaths.Logs -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match '^(serial|qemu)-[a-f0-9]+\.log$' } |
                    Sort-Object LastWriteTimeUtc
                foreach ($log in $logs) {
                    $tailLines = if ($log.Name.StartsWith('serial-', [StringComparison]::Ordinal)) { 500 } else { 100 }
                    Write-Host ('LOG_TAIL=' + $log.FullName + '; lines=' + $tailLines)
                    Get-Content -LiteralPath $log.FullName -Tail $tailLines -ErrorAction SilentlyContinue | ForEach-Object {
                        $line = [string]$_
                        if ($line.Length -gt 4096) { $line = $line.Substring(0, 4096) + ' [diagnostic line truncated]' }
                        Write-Host $line
                    }
                }
            }
        }
        catch { Write-Host ('DIAGNOSTIC_ERROR=' + $_.Exception.Message) }
    }
    Write-Host 'EZVM010_REAL_DIAGNOSTICS_END'
    throw
}
finally {
    foreach ($name in @($active.ToArray())) {
        try { $null = Stop-EzVmInstance -Root $Root -InstanceName $name -ShutdownTimeoutSeconds 30 }
        catch { Write-Host ('EZVM010_GRACEFUL_CLEANUP_ERROR=' + $name + ': ' + $_.Exception.Message) }
    }
    if ($rootARenamed) {
        try {
            # One metadata-only restoration attempt, after B's diagnostics and
            # bounded guest cleanup. Directory.Move refuses an occupied name;
            # never remove either root or overwrite recovery evidence.
            [IO.Directory]::Move($heldRootA, $rootA)
            $rootARenamed = $false
            Write-Host ('EZVM010_STEP=source_root_restored; at=' + [DateTime]::UtcNow.ToString('o'))
        }
        catch {
            Write-Host ('EZVM010_SOURCE_ROOT_RESTORE_ERROR=source preserved at ' + $heldRootA + ': ' + $_.Exception.Message)
        }
    }
}
