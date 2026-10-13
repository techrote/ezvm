function Get-EzVmInstanceDiagnosis {
    [CmdletBinding()]
    param([string]$Root = $script:EzVmDefaultRoot,
        [Parameter(Mandatory = $true)][string]$InstanceName,
        [switch]$CheckImage, [scriptblock]$ProcessProvider, [scriptblock]$QemuImgRunner)

    Assert-EzVmStorageInstanceName -Name $InstanceName
    $paths = Get-EzVmPaths -Root $Root
    $runtimePaths = Get-EzVmInstanceRuntimePaths -Root $Root -InstanceName $InstanceName
    $findings = New-Object 'System.Collections.Generic.List[object]'
    $artifacts = New-Object 'System.Collections.Generic.List[string]'
    $state = 'UNKNOWN'
    $imageCheck = if ($CheckImage) { 'refused' } else { 'not-requested' }
    $intent = $null
    $lock = $null
    function Add-Finding {
        param([string]$Code, [string]$Message, [string]$Remediation)
        if ($findings.Count -lt 32) {
            $findings.Add([pscustomobject][ordered]@{ code = $Code; message = (Protect-EzVmDiagnosticText $Message -MaximumCharacters 2048); remediation = $Remediation })
        }
    }
    try {
        $null = Assert-EzVmSafePath -Path $runtimePaths.Directory -Description 'Diagnosed instance'
        if (-not [IO.File]::Exists($runtimePaths.Intent)) {
            $state = 'ABSENT'
            Add-Finding 'instance_missing' 'No durable instance intent exists.' 'Use list to find the exact name. Preserve any stray disk or directory; do not infer an instance or delete it from its filename.'
        }
        else {
            try { $intent = Get-EzVmInstanceIntent -Root $Root -InstanceName $InstanceName }
            catch { Add-Finding 'intent_invalid' $_.Exception.Message 'Restore the matching durable instance.json from a known backup. Do not synthesize new metadata over an existing disk.' }
            if ($null -ne $intent) {
                $status = Get-EzVmInstanceStatus -Root $Root -InstanceName $InstanceName -ProcessProvider $ProcessProvider
                $state = $status.state
                if ($state -cin @('STALE', 'UNKNOWN')) {
                    Add-Finding 'ownership_unproven' $status.reason 'Keep the disk and runtime metadata unchanged. Identify all QEMU owners using status and Windows process inspection. A missing/reused PID is not proof of clean shutdown; do not delete runtime.json or force a storage operation.'
                }
                elseif ($state -cin @('STARTING', 'STOPPING')) {
                    Add-Finding 'lifecycle_incomplete' $status.reason 'Inspect the bounded QEMU logs under this instance. Use stop only while process identity is proven; a timeout does not authorize killing QEMU or copying its disk.'
                }
                $baseDirectory = Join-Path $paths.Bases $intent.baseId
                $baseImage = Join-Path $baseDirectory 'base.qcow2'
                $baseManifest = Join-Path $baseDirectory 'manifest.json'
                $null = Assert-EzVmSafePath -Path $baseImage -Description 'Diagnosed base'
                if (-not [IO.File]::Exists($baseImage) -or -not [IO.File]::Exists($baseManifest)) {
                    Add-Finding 'base_missing' ('The recorded immutable base is incomplete: ' + $intent.baseId) 'Restore that exact base directory, image and manifest from the complete bundle. Do not substitute a different base, edit baseId, or use unsafe rebase.'
                }
                else {
                    try { $null = Read-EzVmPreparedBaseManifest -Path $baseManifest }
                    catch { Add-Finding 'base_provenance_invalid' $_.Exception.Message 'Preserve the image and manifest. Restore their matching reviewed pair; changing a digest to match unexplained bytes is not recovery.' }
                }
                if (Test-Path -LiteralPath $runtimePaths.Operation) {
                    Add-Finding 'interrupted_reset' 'A lifecycle-operation.json barrier is present; startup and transformations remain blocked.' 'Preserve the journal, original/target intent, disk backups and reset archive together. Follow docs/TROUBLESHOOTING.md; deleting only the journal or retrying reset can lose the original state.'
                }
                $accessPath = Join-Path $runtimePaths.Directory 'access.json'
                if ([IO.File]::Exists($accessPath)) {
                    try {
                        $access = Read-EzVmJson -Path $accessPath -SchemaVersion 2
                        Assert-EzVmSshAccessState -Access $access -ExpectedName $InstanceName
                        if ($access.state -cne 'READY' -or $state -cne 'RUNNING') {
                            Add-Finding 'guest_not_currently_ready' 'Stored SSH readiness does not establish current usable guest access.' 'For a running guest inspect cloud-init status, the ezvm-instance-finalize service and provisioning-failed through a trusted diagnostic session. Preserve known_hosts; do not bypass SSH host-key checking or replace a failure with a READY marker.'
                        }
                        elseif ($access.baseId -cne $intent.baseId -or $access.cloudInstanceId -cne (Get-EzVmGuestCloudInstanceId -Intent $intent)) {
                            Add-Finding 'ssh_identity_mismatch' 'Stored SSH identity does not match durable intent.' 'Preserve existing managed trust and investigate the guest/controller pairing. A later supported start must prove the exact identity again before trust can change.'
                        }
                    }
                    catch { Add-Finding 'ssh_state_invalid' $_.Exception.Message 'Preserve scoped known_hosts and controller keys. A supported stopped/restart cycle must regenerate access; do not hand-edit READY or disable strict checking.' }
                }
                if ($state -cin @('CREATED', 'STOPPED')) {
                    if (-not (Test-EzVmLoopbackPortAvailable -Port ([int]$intent.sshPort))) {
                        Add-Finding 'port_collision' ('Reserved loopback SSH port is occupied: ' + $intent.sshPort) 'Identify the unrelated listener or duplicate running bundle. Stop the correct owner; do not silently redirect the instance to another port.'
                    }
                }
                if ($CheckImage -and $state -cin @('CREATED', 'STOPPED')) {
                    # Only the explicit deep inspection takes a coordination lock.
                    # No metadata is repaired, no image is written or force-opened.
                    $lock = Enter-EzVmInstanceLifecycleLock -Root $Root -InstanceName $InstanceName
                    $guard = Get-EzVmInstanceStorageLifecycleGuard -Root $Root -InstanceName $InstanceName -ProcessProvider $ProcessProvider
                    Assert-EzVmStorageLifecycleGuard -LifecycleGuard $guard -Operation 'Diagnostic image inspection'
                    $current = Get-EzVmInstanceIntent -Root $Root -InstanceName $InstanceName
                    if (($current | ConvertTo-Json -Depth 8 -Compress) -cne ($intent | ConvertTo-Json -Depth 8 -Compress)) { throw 'Instance intent changed during diagnosis; inspect again.' }
                    try {
                        # Validate raw dependency headers before qemu-img traversal.
                        Assert-EzVmSnapshotSourceHeaders -Root $Root -SourceIntent $intent
                        $integrity = Test-EzVmStoppedImageIntegrity -Root $Root -InstanceName $InstanceName -BaseId $intent.baseId -LifecycleGuard $guard -QemuImgRunner $QemuImgRunner
                        if (-not $integrity.Healthy) {
                            $imageCheck = 'failed'
                            Add-Finding 'image_integrity_failed' ('qemu-img check failed: exit=' + $integrity.ExitCode + '; corruptions=' + $integrity.Corruptions + '; leaks=' + $integrity.Leaks) 'Preserve a stopped independent backup. No repair was attempted; assess the damage before any explicit specialist repair on a copy.'
                        }
                        else { $imageCheck = 'passed' }
                    }
                    catch {
                        $imageCheck = 'failed'
                        $detail = $_.Exception.Message
                        $code = if ($detail -match 'digest|provenance') { 'base_or_tool_integrity_mismatch' } elseif ($detail -match 'backing|chain') { 'backing_chain_invalid' } elseif ($detail -match 'dirty|corrupt') { 'image_dirty_or_corrupt' } else { 'image_inspection_failed' }
                        Add-Finding $code $detail 'Preserve the original disk and provenance. Restore missing exact bundle components or rebuild verified tools as indicated. Never commit/rebase automatically or alter hashes to obtain a pass.'
                    }
                }
                elseif ($CheckImage) { Add-Finding 'image_check_refused' 'Offline image checking requires positively proven stopped ownership.' 'Resolve ownership and obtain a clean stop first. Diagnosis does not force-open an image or change STALE/UNKNOWN into STOPPED.' }
            }
        }
        # Shallow bounded inventory of recoverable artifacts, never their contents
        # or paths supplied by a journal. Unknown files are not deletion targets.
        foreach ($directory in @($runtimePaths.Directory, $paths.Bases, $paths.Runtime)) {
            $null = Assert-EzVmSafePath -Path $directory -Description 'Recovery artifact directory'
            if (-not [IO.Directory]::Exists($directory)) { continue }
            $visited = 0
            foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
                if (++$visited -gt 128) { Add-Finding 'artifact_listing_bounded' 'Recovery inventory stopped at 128 entries in one directory.' 'Inspect this directory separately; no entries were removed.'; break }
                $name = [IO.Path]::GetFileName($entry)
                if ($name -match '^\.(?:build|publish|snapshot|reset|disk-backup|disk-reset|qemu-stage|qemu-extractor)-[a-f0-9]+(?:\.qcow2)?$') {
                    $null = Assert-EzVmSafePath -Path $entry -Description 'Recovery artifact'
                    $artifacts.Add((Get-EzVmStorageRelativePath -FromDirectory $paths.Root -TargetPath $entry))
                }
            }
        }
        if ($artifacts.Count -gt 0) { Add-Finding 'staging_artifacts_present' 'Recoverable staging or backup artifacts remain; they can contain sensitive guest state.' 'Keep these artifacts until the transaction and data are reconciled. External export staging is beside its requested destination and is intentionally not searched outside the bundle.' }
    }
    catch { Add-Finding 'diagnosis_blocked' $_.Exception.Message 'Restore a regular local layout and inspect the preserved evidence. No automatic repair or recursive cleanup was attempted.' }
    finally { if ($null -ne $lock) { $lock.Dispose() } }
    return [pscustomobject][ordered]@{
        schemaVersion = 1; instanceName = $InstanceName; lifecycleState = $state
        status = $(if ($findings.Count -eq 0) { 'observed' } else { 'attention' })
        imageCheck = $imageCheck; repairsPerformed = $false
        findings = @($findings.ToArray()); recoveryArtifacts = @($artifacts.ToArray())
        scope = 'Host-side diagnosis only; not guest attestation, continuous readiness or authorization to mutate images.'
    }
}
