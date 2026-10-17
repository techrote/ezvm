. (Join-Path $script:EzVmRepositoryRoot 'scripts/TcgQualification.ps1')

Add-EzVmTest -Name 'TCG qualification: seed adjustment is pure, deterministic and preserves original actions' -ScriptBlock {
    $path = Join-Path $script:EzVmRepositoryRoot 'guest/base-cloud-init/user-data.yaml'
    $original = [IO.File]::ReadAllText($path)
    $before = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    $effective = New-EzVmTcgTimerQualificationSeed -Template $original
    $lf = $original.Replace("`r`n", "`n")
    Assert-EzVmEqual -Actual (New-EzVmTcgTimerQualificationSeed -Template $lf.Replace("`n", "`r`n")) -Expected $effective
    Assert-EzVmEqual -Actual (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -Expected $before
    Assert-EzVmTrue -Condition (-not $original.Contains('no_timer_check'))
    Assert-EzVmTrue -Condition $effective.Contains('GRUB_CMDLINE_LINUX="${GRUB_CMDLINE_LINUX} no_timer_check"')
    Assert-EzVmEqual -Actual ([regex]::Matches($effective, 'no_timer_check').Count) -Expected 1
    Assert-EzVmTrue -Condition $effective.Contains("runcmd:`n  - [update-grub]`n  - [systemd-run")
    $oldScript = $lf.Substring($lf.IndexOf('  - path: /usr/local/sbin/ezvm-finalize-base'))
    Assert-EzVmTrue -Condition $effective.Contains($oldScript.Replace("runcmd:`n", "runcmd:`n  - [update-grub]`n"))
}

Add-EzVmTest -Name 'TCG qualification: malformed or previously adjusted seeds are refused' -ScriptBlock {
    $original = [IO.File]::ReadAllText((Join-Path $script:EzVmRepositoryRoot 'guest/base-cloud-init/user-data.yaml')).Replace("`r`n", "`n")
    foreach ($bad in @(
        $original.Replace('#cloud-config', '#other'),
        $original.Replace("write_files:`n", ''),
        $original.Replace("runcmd:`n", ''),
        ($original + "`nwrite_files:`n"),
        ($original + "`nruncmd:`n"),
        ($original + "`n# no_timer_check`n"),
        ($original + "`n# 99-ezvm-tcg-qualification`n"),
        ($original + "`r")
    )) {
        $null = Assert-EzVmThrows { New-EzVmTcgTimerQualificationSeed -Template $bad }
    }
    $once = New-EzVmTcgTimerQualificationSeed -Template $original
    $null = Assert-EzVmThrows { New-EzVmTcgTimerQualificationSeed -Template $once } -MessagePattern 'existing timer override'
    $null = Assert-EzVmThrows { New-EzVmTcgTimerQualificationSeed -Template ('x' * 1048577) } -MessagePattern 'bounded template'
}

Add-EzVmTest -Name 'TCG qualification: adjusted fixture has distinct provenance and still uses normal seed validation' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'tcg qualification seed'
    try {
        $before = Get-EzVmBaseProvisioningDigest -Root $root
        $path = (Get-EzVmPaths -Root $root).BaseUserDataTemplate
        $effective = New-EzVmTcgTimerQualificationSeed -Template ([IO.File]::ReadAllText($path))
        [IO.File]::WriteAllText($path, $effective, (New-Object Text.UTF8Encoding($false)))
        $seed = New-EzVmBaseSeedData -Root $root -BuildId '0123456789abcdef0123456789abcdef'
        Assert-EzVmTrue -Condition ($seed.ProvisioningDigest -cne $before)
        Assert-EzVmEqual -Actual $seed.ProvisioningDigest -Expected (Get-EzVmBaseProvisioningDigest -Root $root)
        Assert-EzVmTrue -Condition $seed.UserData.Contains('no_timer_check')
        Assert-EzVmTrue -Condition $seed.UserData.Contains('cloud-init status --wait')
        Assert-EzVmTrue -Condition $seed.UserData.Contains('EZVM_BASE_FAILURE_B64=')
        Assert-EzVmTrue -Condition (-not [IO.File]::ReadAllText((Join-Path $script:EzVmRepositoryRoot 'guest/base-cloud-init/user-data.yaml')).Contains('no_timer_check'))
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'TCG qualification: opt-in without release mode is refused before creating any root' -ScriptBlock {
    $root = New-EzVmTestDirectory -Prefix 'tcg qualification refusal'
    try {
        $null = Assert-EzVmThrows {
            & (Join-Path $script:EzVmRepositoryRoot 'scripts/Invoke-EzVm010RealPortability.ps1') -Root $root -TcgTimerCheckWorkaround
        } -MessagePattern 'restricted to explicit disposable release qualification'
        Assert-EzVmEqual -Actual @(Get-ChildItem -LiteralPath $root -Force).Count -Expected 0
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'TCG qualification: every guest start verifies effective boot option and working timers' -ScriptBlock {
    $probe = Get-EzVmTcgTimerQualificationProbe
    foreach ($required in @('/proc/cmdline', '/proc/interrupts', 'IO-APIC', '/proc/uptime', 'after > before', 'current_clocksource', 'test "$count" -eq 1')) {
        Assert-EzVmTrue -Condition $probe.Contains($required) -Message ('Missing timer evidence: ' + $required)
    }
    $source = [IO.File]::ReadAllText((Join-Path $script:EzVmRepositoryRoot 'scripts/Invoke-EzVm010RealPortability.ps1'))
    Assert-EzVmTrue -Condition $source.Contains('if ($TcgTimerCheckWorkaround)')
    Assert-EzVmTrue -Condition $source.Contains('-Script (Get-EzVmTcgTimerQualificationProbe) -TimeoutSeconds 60')
    Assert-EzVmTrue -Condition $source.Contains('-ReadyTimeoutSeconds 900')
    Assert-EzVmTrue -Condition $source.Contains('-BuildTimeoutSeconds 2400')
    Assert-EzVmTrue -Condition (-not [IO.File]::ReadAllText((Join-Path $script:EzVmRepositoryRoot 'src/EzVm/EzVm.psm1')).Contains('TcgQualification.ps1'))
}
