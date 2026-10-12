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
$qmpHost = '127.0.0.1'
$qmpPort = & $module { Get-EzVmEphemeralLoopbackPort }
$arguments = @(
    '-name', 'guest=ezvm-qmp-smoke',
    '-machine', 'none',
    '-accel', 'tcg,thread=multi',
    '-display', 'none',
    '-monitor', 'none',
    '-qmp', ('tcp:127.0.0.1:' + $qmpPort + ',server=on,wait=off,nodelay=on'),
    '-no-user-config',
    '-nodefaults'
)
$module = Get-Module EzVm
$launch = $null
$stderrTask = $null
$stdoutTask = $null
try {
    # Use the same tokenized argument construction as production but redirect
    # this bounded smoke process so startup errors from the reviewed QEMU build
    # become actionable qualification evidence.
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $qemu
    $start.WorkingDirectory = $qemuRoot
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    if ($null -ne $start.PSObject.Properties['ArgumentList']) {
        foreach ($argument in $arguments) { $start.ArgumentList.Add($argument) }
    }
    else {
        $escaped = New-Object 'System.Collections.Generic.List[string]'
        foreach ($argument in $arguments) {
            $escaped.Add((& $module { param($value) ConvertTo-EzVmWindowsArgument -Argument $value } $argument))
        }
        $start.Arguments = [string]::Join(' ', $escaped.ToArray())
    }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    if (-not $process.Start()) { throw 'The operating system did not create the real QEMU smoke process.' }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $launch = [pscustomobject]@{
        Process = $process
        Pid = $process.Id
        StartTimeUtc = $process.StartTime.ToUniversalTime().ToString('o')
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    $query = $null
    $lastError = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($null -ne $launch.Process -and $launch.Process.HasExited) {
            $stderr = ''
            $stdout = ''
            if ($null -ne $stderrTask -and $stderrTask.Wait(3000)) { $stderr = $stderrTask.Result.Trim() }
            if ($null -ne $stdoutTask -and $stdoutTask.Wait(3000)) { $stdout = $stdoutTask.Result.Trim() }
            throw "Real QEMU smoke process exited before QMP became ready with code $($launch.Process.ExitCode). stderr=<$stderr> stdout=<$stdout>"
        }
        try {
            $query = & $module { param($hostAddress, $port) Invoke-EzVmQmpCommand -HostAddress $hostAddress -Port $port -Command 'query-status' -TimeoutMilliseconds 1000 } $qmpHost $qmpPort
            break
        }
        catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Milliseconds 100
        }
    }
    if ($null -eq $query) { throw "Real loopback QMP handshake did not become ready: $lastError" }

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

    $null = & $module { param($hostAddress, $port) Invoke-EzVmQmpCommand -HostAddress $hostAddress -Port $port -Command 'system_powerdown' -TimeoutMilliseconds 3000 } $qmpHost $qmpPort
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
        $null = & $module { param($hostAddress, $port) Invoke-EzVmQmpCommand -HostAddress $hostAddress -Port $port -Command 'quit' -TimeoutMilliseconds 3000 } $qmpHost $qmpPort
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

    Write-Host ('EZVM006_REAL_QMP_ENDPOINT=' + $qmpHost + ':' + $qmpPort)
    Write-Host ('EZVM006_REAL_PID=' + $launch.Pid)
    Write-Host ('EZVM006_REAL_ARGV_SHA256=' + $expectedFingerprint)
    Write-Host 'EZVM006_REAL_QMP_HOST_SCOPE=127.0.0.1_ONLY'
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
