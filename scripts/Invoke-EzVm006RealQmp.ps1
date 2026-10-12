#requires -Version 5.1
[CmdletBinding()]
param([string]$Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')))

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Import-Module (Join-Path $Root 'src/EzVm/EzVm.psd1') -Force -ErrorAction Stop

$bootstrap = Install-EzVmQemuRuntime -Root $Root
$qemu = [IO.Path]::GetFullPath($bootstrap.qemuSystem)
$qemuRoot = Split-Path -Parent $qemu
$launchId = [Guid]::NewGuid().ToString('N')
$pipeName = 'ezvm-qmp-smoke-' + $launchId
$arguments = @(
    '-name', 'guest=ezvm-qmp-smoke',
    '-machine', 'none',
    '-accel', 'tcg,thread=multi',
    '-display', 'none',
    '-monitor', 'none',
    '-chardev', ('pipe,id=qmp,path=' + $pipeName),
    '-mon', 'chardev=qmp,mode=control,pretty=off',
    '-no-user-config',
    '-nodefaults'
)
$module = Get-Module EzVm
$launch = $null
try {
    $launch = & $module {
        param($file, $argumentTokens, $working)
        Start-EzVmRuntimeProcess -FilePath $file -ArgumentList ([string[]]$argumentTokens) -WorkingDirectory $working
    } $qemu (,([string[]]$arguments)) $qemuRoot

    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    $query = $null
    $lastError = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $query = Invoke-EzVmQmpCommand -PipeName $pipeName -Command 'query-status' -TimeoutMilliseconds 1000
            break
        }
        catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Milliseconds 100
        }
    }
    if ($null -eq $query) { throw "Real QMP named-pipe handshake did not become ready: $lastError" }

    $snapshots = @(& $module {
        param($pidValue)
        Get-EzVmObservedQemuProcesses -ProcessId ([Nullable[int]]$pidValue) -ProcessProvider $null
    } $launch.Pid)
    if ($snapshots.Count -ne 1) { throw "Expected exactly one real QEMU process snapshot, got $($snapshots.Count)." }
    $snapshot = $snapshots[0]
    if (-not (Test-Path -LiteralPath $snapshot.ExecutablePath -PathType Leaf)) { throw 'Real QEMU process executable path was not readable.' }
    if ([IO.Path]::GetFullPath($snapshot.ExecutablePath) -cne $qemu) { throw "Observed QEMU executable mismatch: $($snapshot.ExecutablePath)" }

    $expectedFingerprint = Get-EzVmArgumentFingerprint -ArgumentList $arguments
    $observedFingerprint = Get-EzVmArgumentFingerprint -ArgumentList ([string[]]$snapshot.Arguments)
    if ($observedFingerprint -cne $expectedFingerprint) { throw 'Real Windows process argv fingerprint did not round-trip through Win32_Process.' }

    $null = Invoke-EzVmQmpCommand -PipeName $pipeName -Command 'system_powerdown' -TimeoutMilliseconds 3000
    Write-Host 'EZVM006_REAL_QMP_POWERDOWN_REQUEST=PASS'

    Start-Sleep -Milliseconds 500
    $remaining = @(& $module {
        param($pidValue)
        Get-EzVmObservedQemuProcesses -ProcessId ([Nullable[int]]$pidValue) -ProcessProvider $null
    } $launch.Pid)
    if ($remaining.Count -gt 0) {
        # machine=none has no guest OS to complete an ACPI shutdown. The quit
        # command is test cleanup only; production Stop-EzVmInstance never
        # converts a powerdown timeout into quit/kill.
        $null = Invoke-EzVmQmpCommand -PipeName $pipeName -Command 'quit' -TimeoutMilliseconds 3000
    }

    $exitDeadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([DateTime]::UtcNow -lt $exitDeadline) {
        $left = @(& $module {
            param($pidValue)
            Get-EzVmObservedQemuProcesses -ProcessId ([Nullable[int]]$pidValue) -ProcessProvider $null
        } $launch.Pid)
        if ($left.Count -eq 0) { break }
        Start-Sleep -Milliseconds 100
    }
    $left = @(& $module {
        param($pidValue)
        Get-EzVmObservedQemuProcesses -ProcessId ([Nullable[int]]$pidValue) -ProcessProvider $null
    } $launch.Pid)
    if ($left.Count -ne 0) { throw 'Real QEMU smoke process did not exit after QMP cleanup.' }

    Write-Host ('EZVM006_REAL_QMP_PIPE=' + $pipeName)
    Write-Host ('EZVM006_REAL_PID=' + $launch.Pid)
    Write-Host ('EZVM006_REAL_ARGV_SHA256=' + $expectedFingerprint)
    Write-Host 'EZVM006_REAL_QMP_HOST_SCOPE=WINDOWS_NAMED_PIPE'
    Write-Host 'EZVM006_WHPX_EXECUTION=SKIP: hosted qualification uses explicit TCG; no WHPX runtime PASS is claimed.'
}
finally {
    if ($null -ne $launch -and $null -ne $launch.Process) {
        try {
            if (-not $launch.Process.HasExited) { $launch.Process.Kill() }
        } catch { }
        $launch.Process.Dispose()
    }
}
