#requires -Version 5.1
[CmdletBinding()]
param([string]$Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')))

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Import-Module (Join-Path $Root 'src/EzVm/EzVm.psd1') -Force -ErrorAction Stop

$instanceName = 'ezvm007-real-ssh'
$started = $false
$hostSource = $null
$hostRoundTrip = $null

try {
    $tooling = Get-EzVmOpenSshTools
    if (-not $tooling.Valid) {
        throw "Real SSH qualification requires Windows OpenSSH tooling. $($tooling.Reason)"
    }

    $bootstrap = Install-EzVmQemuRuntime -Root $Root
    $source = Invoke-EzVmSourceImageAcquire -Root $Root
    Write-Host ('EZVM007_REAL_QEMU=' + $bootstrap.version)
    Write-Host ('EZVM007_REAL_SOURCE_SHA256=' + $source.sha256)

    $base = Invoke-EzVmBaseBuild -Root $Root -Accelerator tcg -BuildTimeoutSeconds 2400
    $acceptedBase = Test-EzVmPreparedBase -Root $Root -BaseId $base.baseId
    if ($acceptedBase.Manifest.build.accelerator -cne 'tcg') {
        throw 'Prepared base qualification did not record explicit TCG execution.'
    }

    $null = New-EzVmInstanceIntent -Root $Root -InstanceName $instanceName -BaseId $base.baseId -Cpus 2 -MemoryMiB 4096
    $guard = New-EzVmStorageLifecycleGuard -State 'proven-safe' -Source 'fresh EZVM-007 hosted qualification instance has no QEMU owner'
    $overlay = New-EzVmInstanceOverlay -Root $Root -InstanceName $instanceName -BaseId $base.baseId -LifecycleGuard $guard
    if ($overlay.ChainDepth -ne 1) { throw 'Real SSH qualification overlay violated the one-level chain contract.' }

    $ready = Start-EzVmReadyInstance -Root $Root -InstanceName $instanceName -Accelerator tcg -ReadyTimeoutSeconds 900
    $started = $true
    if ($ready.state -cne 'READY') { throw "Instance did not reach READY: $($ready.state)" }
    if ($ready.sshHost -cne '127.0.0.1') { throw "SSH host scope was not loopback: $($ready.sshHost)" }
    if ([int]$ready.sshPort -lt 22000 -or [int]$ready.sshPort -gt 22999) {
        throw "SSH port $($ready.sshPort) escaped the configured allocation range."
    }

    $identityExec = Invoke-EzVmExec -Root $Root -InstanceName $instanceName -Command @('sh', '-lc', 'printf "EZVM007_EXEC_USER=%s\n" "$(id -un)"; printf "EZVM007_EXEC_READY=%s\n" "$(test -f /var/lib/ezvm/ready.json && echo 1 || echo 0)"') -TimeoutSeconds 60
    if ($identityExec.exitCode -ne 0 -or $identityExec.stdout -notmatch 'EZVM007_EXEC_USER=coder' -or $identityExec.stdout -notmatch 'EZVM007_EXEC_READY=1') {
        throw "Authenticated exec evidence was incomplete. exit=$($identityExec.exitCode) stdout=<$($identityExec.stdout)> stderr=<$($identityExec.stderr)>"
    }

    $failureExec = Invoke-EzVmExec -Root $Root -InstanceName $instanceName -Command @('sh', '-lc', 'printf "EZVM007_REMOTE_FAILURE\n" >&2; exit 23') -TimeoutSeconds 60
    if ($failureExec.exitCode -ne 23 -or $failureExec.stderr -notmatch 'EZVM007_REMOTE_FAILURE') {
        throw "Remote non-zero exit propagation failed. exit=$($failureExec.exitCode) stderr=<$($failureExec.stderr)>"
    }

    $hostSource = Join-Path $env:RUNNER_TEMP 'ezvm007 host source with spaces.txt'
    $hostRoundTrip = Join-Path $env:RUNNER_TEMP 'ezvm007 host round trip with spaces.txt'
    $payload = 'EZVM007_FILE_TRANSFER_' + [Guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($hostSource, $payload, (New-Object Text.UTF8Encoding($false)))
    $null = Invoke-EzVmCopyToGuest -Root $Root -InstanceName $instanceName -HostPath $hostSource -GuestPath '/tmp/ezvm007-transfer.txt' -TimeoutSeconds 60
    $null = Invoke-EzVmCopyFromGuest -Root $Root -InstanceName $instanceName -GuestPath '/tmp/ezvm007-transfer.txt' -HostPath $hostRoundTrip -TimeoutSeconds 60
    $returned = [IO.File]::ReadAllText($hostRoundTrip, (New-Object Text.UTF8Encoding($false, $true)))
    if ($returned -cne $payload) { throw 'Real scp round-trip changed the transferred file payload.' }

    $stopped = Stop-EzVmInstance -Root $Root -InstanceName $instanceName -ShutdownTimeoutSeconds 120
    $started = $false
    if ($stopped.state -cne 'STOPPED') { throw "Real guest did not stop cleanly: $($stopped.state)" }

    Write-Host ('EZVM007_REAL_BASE=' + $base.baseId)
    Write-Host ('EZVM007_REAL_SSH_ENDPOINT=127.0.0.1:' + $ready.sshPort)
    Write-Host 'EZVM007_REAL_AUTHENTICATED_IDENTITY=PASS'
    Write-Host 'EZVM007_REAL_CLOUD_INIT_READY=PASS'
    Write-Host 'EZVM007_REAL_EXEC_EXIT_PROPAGATION=PASS'
    Write-Host 'EZVM007_REAL_SCP_ROUNDTRIP=PASS'
    Write-Host 'EZVM007_REAL_GRACEFUL_STOP=PASS'
    Write-Host 'EZVM007_WHPX_EXECUTION=SKIP: GitHub-hosted runner qualification uses explicit TCG; no WHPX runtime PASS is claimed.'
}
catch {
    Write-Host 'EZVM007_REAL_DIAGNOSTICS_BEGIN'
    try {
        $runtimePaths = Get-EzVmInstanceRuntimePaths -Root $Root -InstanceName $instanceName
        foreach ($path in @($runtimePaths.Runtime, (Join-Path $runtimePaths.Directory 'access.json'))) {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                Write-Host ('STATE_FILE=' + $path)
                Get-Content -LiteralPath $path -Raw | Write-Host
            }
        }
        if (Test-Path -LiteralPath $runtimePaths.Logs -PathType Container) {
            Get-ChildItem -LiteralPath $runtimePaths.Logs -File -ErrorAction SilentlyContinue | ForEach-Object {
                Write-Host ('LOG_TAIL=' + $_.FullName)
                Get-Content -LiteralPath $_.FullName -Tail 200 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
            }
        }
    } catch { Write-Host ('DIAGNOSTIC_ERROR=' + $_.Exception.Message) }
    Write-Host 'EZVM007_REAL_DIAGNOSTICS_END'
    throw
}
finally {
    if ($started) {
        try { $null = Stop-EzVmInstance -Root $Root -InstanceName $instanceName -ShutdownTimeoutSeconds 30 } catch { }
    }
    foreach ($path in @($hostSource, $hostRoundTrip)) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
}
