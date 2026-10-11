Add-EzVmTest -Name 'Doctor: overall classification has deterministic severity precedence' -ScriptBlock {
    $module = Get-Module EzVm
    $ready = @([pscustomobject]@{ status = 'ready' })
    $unknown = @([pscustomobject]@{ status = 'ready' }, [pscustomobject]@{ status = 'unknown' })
    $notConfigured = @([pscustomobject]@{ status = 'unknown' }, [pscustomobject]@{ status = 'supported-but-not-configured' })
    $unsupported = @([pscustomobject]@{ status = 'supported-but-not-configured' }, [pscustomobject]@{ status = 'unsupported' })

    $a = & $module { param($checks) Resolve-EzVmDoctorOverallStatus -Checks $checks } (, $ready)
    $b = & $module { param($checks) Resolve-EzVmDoctorOverallStatus -Checks $checks } (, $unknown)
    $c = & $module { param($checks) Resolve-EzVmDoctorOverallStatus -Checks $checks } (, $notConfigured)
    $d = & $module { param($checks) Resolve-EzVmDoctorOverallStatus -Checks $checks } (, $unsupported)
    Assert-EzVmEqual -Actual $a -Expected 'ready'
    Assert-EzVmEqual -Actual $b -Expected 'unknown'
    Assert-EzVmEqual -Actual $c -Expected 'supported-but-not-configured'
    Assert-EzVmEqual -Actual $d -Expected 'unsupported'
}

Add-EzVmTest -Name 'Doctor: report has independent prerequisite checks and never claims WHPX execution' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'doctor [root] with spaces'
    try {
        $report = Get-EzVmDoctorReport -Root $root
        Assert-EzTrueStatusVocabulary -Checks $report.checks
        $names = @($report.checks | ForEach-Object { $_.name })
        foreach ($required in @(
            'host-os', 'powershell', 'hardware-virtualization', 'whpx',
            'runtime-write', 'path', 'disk-space', 'managed-qemu', 'runtime-state'
        )) {
            Assert-EzVmTrue -Condition ($names -ccontains $required) -Message "Doctor omitted '$required'."
        }
        Assert-EzVmEqual -Actual $report.whpxExecutionTested -Expected $false
        Assert-EzVmTrue -Condition ($report.note -match 'does not claim WHPX execution')
        $managed = @($report.checks | Where-Object { $_.name -ceq 'managed-qemu' })[0]
        Assert-EzVmEqual -Actual $managed.status -Expected 'supported-but-not-configured'
        Assert-EzVmTrue -Condition ($managed.remediation -match 'bootstrap')
        $path = @($report.checks | Where-Object { $_.name -ceq 'path' })[0]
        Assert-EzVmEqual -Actual $path.status -Expected 'ready'
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

function Assert-EzTrueStatusVocabulary {
    param([object[]]$Checks)
    foreach ($check in $Checks) {
        Assert-EzVmTrue -Condition (@('ready', 'supported-but-not-configured', 'unsupported', 'unknown') -ccontains $check.status) -Message "Unexpected doctor status '$($check.status)'."
        Assert-EzVmTrue -Condition (-not [string]::IsNullOrWhiteSpace($check.message))
    }
}

Add-EzVmTest -Name 'Doctor: JSON CLI output is structured even when host is not release-ready' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'doctor CLI'
    try {
        $result = Invoke-EzVmCliForTest -ArgumentList @('doctor', '-Json') -Root $root
        $value = Assert-EzVmJsonEnvelope -Result $result -Command 'doctor' -ExitCode 0
        Assert-EzVmTrue -Condition (@('ready', 'supported-but-not-configured', 'unsupported', 'unknown') -ccontains $value.data.status)
        Assert-EzVmEqual -Actual $value.data.whpxExecutionTested -Expected $false
        Assert-EzVmTrue -Condition (@($value.data.checks).Count -ge 8
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Doctor: WHPX remediation is informational and host features are never enabled by code' -ScriptBlock {
    $source = [IO.File]::ReadAllText((Join-Path $script:EzVmRepositoryRoot 'src/EzVm/Doctor.ps1'))
    Assert-EzVmTrue -Condition ($source -notmatch '(?i)Enable-WindowsOptionalFeature') -Message 'doctor must never enable Windows optional features.'
    Assert-EzVmTrue -Condition ($source -notmatch '(?i)Start-Process[^\r\n]*RunAs') -Message 'doctor must never elevate itself.'
    Assert-EzVmTrue -Condition ($source -notmatch '(?i)Invoke-EzVmProcess[^\r\n]*dism') -Message 'doctor must never execute DISM feature changes.'
    Assert-EzVmTrue -Condition ($source -match 'DISM /online /Enable-Feature /FeatureName:HypervisorPlatform /All') -Message 'doctor should provide the documented remediation command as text.'
}

Add-EzVmTest -Name 'Doctor: runtime-state files are reported as unknown rather than trusted PID evidence' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'doctor stale state'
    try {
        $paths = Get-EzVmPaths -Root $root
        $instance = Join-Path $paths.Instances 'fixture'
        [void][IO.Directory]::CreateDirectory($instance)
        Write-EzVmJson -Path (Join-Path $instance 'runtime.json') -Value ([pscustomobject][ordered]@{
            schemaVersion = 1
            pid = 1234
        })
        $report = Get-EzVmDoctorReport -Root $root
        $state = @($report.checks | Where-Object { $_.name -ceq 'runtime-state' })[0]
        Assert-EzVmEqual -Actual $state.status -Expected 'unknown'
        Assert-EzVmTrue -Condition ($state.message -match 'cannot be proven')
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}
