function New-EzVmDoctorCheck {
    param(
        [string]$Name,
        [ValidateSet('ready', 'supported-but-not-configured', 'unsupported', 'unknown')][string]$Status,
        [string]$Message,
        [string]$Remediation = ''
    )
    return [pscustomobject][ordered]@{
        name = $Name
        status = $Status
        message = $Message
        remediation = $Remediation
    }
}

function Resolve-EzVmDoctorOverallStatus {
    param([object[]]$Checks)
    if (@($Checks | Where-Object { $_.status -ceq 'unsupported' }).Count -gt 0) { return 'unsupported' }
    if (@($Checks | Where-Object { $_.status -ceq 'supported-but-not-configured' }).Count -gt 0) { return 'supported-but-not-configured' }
    if (@($Checks | Where-Object { $_.status -ceq 'unknown' }).Count -gt 0) { return 'unknown' }
    return 'ready'
}

function Get-EzVmWindowsFeatureState {
    param([string]$FeatureName)
    try {
        $command = Get-Command Get-WindowsOptionalFeature -CommandType Cmdlet -ErrorAction Stop
        $feature = & $command -Online -FeatureName $FeatureName -ErrorAction Stop
        return [string]$feature.State
    }
    catch {
        return $null
    }
}

function Get-EzVmDoctorReport {
    [CmdletBinding()]
    param([string]$Root = $script:EzVmDefaultRoot)

    $paths = Get-EzVmPaths -Root $Root
    $checks = New-Object 'System.Collections.Generic.List[object]'
    $isWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
    $is64 = [Environment]::Is64BitOperatingSystem

    if (-not $isWindows) {
        $checks.Add((New-EzVmDoctorCheck -Name 'host-os' -Status 'unsupported' -Message 'ezvm v0.1 requires Windows x86-64.' -Remediation 'Use a compatible Windows 10/11 x86-64 host.'))
    }
    else {
        $caption = 'Windows'
        $version = [Environment]::OSVersion.Version
        try {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            if ($os.Caption) { $caption = [string]$os.Caption }
            if ($os.Version) { $version = [Version]$os.Version }
        }
        catch { }
        $supportedClient = $caption -notmatch 'Server' -and $version.Build -ge 19041
        if (-not $is64) {
            $checks.Add((New-EzVmDoctorCheck -Name 'host-os' -Status 'unsupported' -Message "$caption $version is not a 64-bit operating system." -Remediation 'Use Windows x86-64.'))
        }
        elseif (-not $supportedClient) {
            $checks.Add((New-EzVmDoctorCheck -Name 'host-os' -Status 'unsupported' -Message "$caption $version is outside the Windows 10 2004+/Windows 11 v0.1 host baseline." -Remediation 'Use Windows 10 version 2004 or newer, or Windows 11 x86-64.'))
        }
        else {
            $checks.Add((New-EzVmDoctorCheck -Name 'host-os' -Status 'ready' -Message "$caption $version x86-64 is within the v0.1 host baseline."))
        }
    }

    if ($PSVersionTable.PSVersion.Major -gt 5 -or
        ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -ge 1)) {
        $checks.Add((New-EzVmDoctorCheck -Name 'powershell' -Status 'ready' -Message "PowerShell $($PSVersionTable.PSVersion) satisfies the 5.1+ control-plane baseline."))
    }
    else {
        $checks.Add((New-EzVmDoctorCheck -Name 'powershell' -Status 'unsupported' -Message "PowerShell $($PSVersionTable.PSVersion) is too old." -Remediation 'Use Windows PowerShell 5.1 or current PowerShell 7.'))
    }

    if ($isWindows) {
        try {
            $processors = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)
            $virtKnown = @($processors | Where-Object { $null -ne $_.VirtualizationFirmwareEnabled -or $null -ne $_.VMMonitorModeExtensions })
            if ($virtKnown.Count -eq 0) {
                $checks.Add((New-EzVmDoctorCheck -Name 'hardware-virtualization' -Status 'unknown' -Message 'Windows did not expose a conclusive hardware-virtualization indicator.'))
            }
            elseif (@($processors | Where-Object { $_.VirtualizationFirmwareEnabled -eq $false -or $_.VMMonitorModeExtensions -eq $false }).Count -gt 0) {
                $checks.Add((New-EzVmDoctorCheck -Name 'hardware-virtualization' -Status 'supported-but-not-configured' -Message 'CPU virtualization appears disabled or unavailable to Windows.' -Remediation 'Enable Intel VT-x/AMD-V (SVM) in firmware, then reboot.'))
            }
            else {
                $checks.Add((New-EzVmDoctorCheck -Name 'hardware-virtualization' -Status 'ready' -Message 'Windows reports hardware virtualization enabled.'))
            }
        }
        catch {
            $checks.Add((New-EzVmDoctorCheck -Name 'hardware-virtualization' -Status 'unknown' -Message "Hardware virtualization could not be determined: $($_.Exception.Message)"))
        }

        $whpx = Get-EzVmWindowsFeatureState -FeatureName 'HypervisorPlatform'
        if ($whpx -ceq 'Enabled') {
            $checks.Add((New-EzVmDoctorCheck -Name 'whpx' -Status 'ready' -Message 'Windows Hypervisor Platform is enabled.'))
        }
        elseif ($null -eq $whpx) {
            $checks.Add((New-EzVmDoctorCheck -Name 'whpx' -Status 'unknown' -Message 'Windows Hypervisor Platform feature state could not be determined without changing the host.' -Remediation 'Inspect the HypervisorPlatform optional feature manually.'))
        }
        else {
            $checks.Add((New-EzVmDoctorCheck -Name 'whpx' -Status 'supported-but-not-configured' -Message "Windows Hypervisor Platform state is '$whpx'." -Remediation 'From an elevated shell, run: DISM /online /Enable-Feature /FeatureName:HypervisorPlatform /All ; then reboot if requested. ezvm will not do this automatically.'))
        }
    }
    else {
        $checks.Add((New-EzVmDoctorCheck -Name 'hardware-virtualization' -Status 'unknown' -Message 'Hardware virtualization is not queried on unsupported non-Windows hosts.'))
        $checks.Add((New-EzVmDoctorCheck -Name 'whpx' -Status 'unsupported' -Message 'WHPX exists only on supported Windows hosts.'))
    }

    try {
        [void][IO.Directory]::CreateDirectory($paths.Runtime)
        $probe = Join-Path $paths.Runtime ('.ezvm-write-probe-' + [Guid]::NewGuid().ToString('N') + '.tmp')
        try {
            [IO.File]::WriteAllText($probe, 'ezvm write probe', (New-Object Text.UTF8Encoding($false)))
        }
        finally {
            if (Test-Path -LiteralPath $probe) { [IO.File]::Delete($probe) }
        }
        $checks.Add((New-EzVmDoctorCheck -Name 'runtime-write' -Status 'ready' -Message "Runtime root is writable: $($paths.Runtime)"))
    }
    catch {
        $checks.Add((New-EzVmDoctorCheck -Name 'runtime-write' -Status 'supported-but-not-configured' -Message "Runtime root is not writable: $($_.Exception.Message)" -Remediation 'Move ezvm to a user-writable local filesystem path or correct its permissions.'))
    }

    $rootPath = [IO.Path]::GetFullPath($paths.Root)
    if ($rootPath.StartsWith('\\')) {
        $checks.Add((New-EzVmDoctorCheck -Name 'path' -Status 'supported-but-not-configured' -Message 'The ezvm root is a UNC/network path; v0.1 expects local storage.' -Remediation 'Copy ezvm to a local filesystem path.'))
    }
    else {
        $checks.Add((New-EzVmDoctorCheck -Name 'path' -Status 'ready' -Message "Managed paths derive from the current root; spaces and brackets are supported: $rootPath"))
    }

    try {
        $rootDirectory = Get-Item -LiteralPath $paths.Runtime -ErrorAction Stop
        $drive = New-Object IO.DriveInfo($rootDirectory.PSDrive.Name)
        $freeGiB = [Math]::Round($drive.AvailableFreeSpace / 1GB, 1)
        if ($drive.AvailableFreeSpace -ge 20GB) {
            $checks.Add((New-EzVmDoctorCheck -Name 'disk-space' -Status 'ready' -Message "$freeGiB GiB available on runtime volume."))
        }
        else {
            $checks.Add((New-EzVmDoctorCheck -Name 'disk-space' -Status 'supported-but-not-configured' -Message "Only $freeGiB GiB is available on the runtime volume." -Remediation 'Free at least 20 GiB for QEMU, cloud images, prepared bases and overlays.'))
        }
    }
    catch {
        $checks.Add((New-EzVmDoctorCheck -Name 'disk-space' -Status 'unknown' -Message "Available runtime disk space could not be determined: $($_.Exception.Message)"))
    }

    try {
        $manifest = Get-EzVmQemuManifest -Root $Root
        $managed = Get-EzVmManagedQemuStatus -Root $Root -Manifest $manifest
        if ($managed.Valid) {
            $checks.Add((New-EzVmDoctorCheck -Name 'managed-qemu' -Status 'ready' -Message $managed.Reason))
        }
        else {
            $checks.Add((New-EzVmDoctorCheck -Name 'managed-qemu' -Status 'supported-but-not-configured' -Message $managed.Reason -Remediation "Run '.\ezvm.ps1 bootstrap' to install the reviewed repository-local QEMU runtime."))
        }
    }
    catch {
        $checks.Add((New-EzVmDoctorCheck -Name 'managed-qemu' -Status 'supported-but-not-configured' -Message "Managed QEMU cannot be validated: $($_.Exception.Message)" -Remediation "Restore the reviewed manifest and run '.\ezvm.ps1 bootstrap'."))
    }

    $runtimeState = @()
    if (Test-Path -LiteralPath $paths.Instances -PathType Container) {
        $runtimeState = @(Get-ChildItem -LiteralPath $paths.Instances -Filter 'runtime.json' -File -Recurse -ErrorAction SilentlyContinue)
    }
    if ($runtimeState.Count -eq 0) {
        $checks.Add((New-EzVmDoctorCheck -Name 'runtime-state' -Status 'ready' -Message 'No existing instance runtime state requires reconciliation.'))
    }
    else {
        $checks.Add((New-EzVmDoctorCheck -Name 'runtime-state' -Status 'unknown' -Message "Found $($runtimeState.Count) instance runtime-state file(s). Process identity cannot be proven until the lifecycle issue provides reconciliation." -Remediation 'Do not delete or mutate instance disks based only on stale PID files.'))
    }

    $array = @($checks.ToArray())
    return [pscustomobject][ordered]@{
        status = Resolve-EzVmDoctorOverallStatus -Checks $array
        checks = $array
        whpxExecutionTested = $false
        note = 'doctor reports prerequisite evidence only; it does not claim WHPX execution succeeded.'
    }
}
