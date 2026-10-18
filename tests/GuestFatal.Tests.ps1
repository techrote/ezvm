Add-EzVmTest -Name 'Guest fatal: current owned kernel panic refuses readiness without changing runtime ownership' -ScriptBlock {
    $fixture = New-EzVmRuntimeFixture
    try {
        $started = Start-EzVmRuntimeFixtureInstance -Fixture $fixture
        $runtime = Get-EzVmRuntimeFixtureState -Fixture $fixture
        $path = (Get-EzVmInstanceRuntimePaths -Root $fixture.Root -InstanceName $fixture.InstanceName).Runtime
        $before = [IO.File]::ReadAllText($path)
        [IO.File]::WriteAllText($runtime.serialLog, "[ 132.675973] Kernel panic - not syncing: Attempted to kill init! exitcode=0x0000008b`n")
        $module = Get-Module EzVm
        Assert-EzVmThrows -ScriptBlock {
            & $module {param($r,$n,$l,$p) Assert-EzVmGuestHasNoKernelPanic -Root $r -InstanceName $n -LaunchId $l -ProcessProvider $p} $fixture.Root $fixture.InstanceName $runtime.launchId $fixture.ProcessProvider
        } -MessagePattern 'kernel panic.*current owned launch' | Out-Null
        Assert-EzVmEqual -Actual ([IO.File]::ReadAllText($path)) -Expected $before
        Assert-EzVmEqual -Actual $fixture.State.Processes.Count -Expected 1
    } finally { Remove-EzVmRuntimeFixture -Fixture $fixture }
}

Add-EzVmTest -Name 'Guest fatal: stale serial and wrong launch cannot supply current panic evidence' -ScriptBlock {
    $fixture = New-EzVmRuntimeFixture
    try {
        $null = Start-EzVmRuntimeFixtureInstance -Fixture $fixture
        $runtime = Get-EzVmRuntimeFixtureState -Fixture $fixture
        $paths = Get-EzVmInstanceRuntimePaths -Root $fixture.Root -InstanceName $fixture.InstanceName
        [IO.File]::WriteAllText((Join-Path $paths.Logs ('serial-'+('f'*32)+'.log')), '[ 1.000] Kernel panic - not syncing: old launch')
        $module = Get-Module EzVm
        & $module {param($r,$n,$l,$p) Assert-EzVmGuestHasNoKernelPanic -Root $r -InstanceName $n -LaunchId $l -ProcessProvider $p} $fixture.Root $fixture.InstanceName $runtime.launchId $fixture.ProcessProvider
        Assert-EzVmThrows -ScriptBlock {
            & $module {param($r,$n,$p) Assert-EzVmGuestHasNoKernelPanic -Root $r -InstanceName $n -LaunchId ('f'*32) -ProcessProvider $p} $fixture.Root $fixture.InstanceName $fixture.ProcessProvider
        } -MessagePattern 'launch changed' | Out-Null
    } finally { Remove-EzVmRuntimeFixture -Fixture $fixture }
}

Add-EzVmTest -Name 'Guest fatal: foreign log path and reused PID fail closed without consuming guest prose' -ScriptBlock {
    $fixture = New-EzVmRuntimeFixture
    try {
        $null = Start-EzVmRuntimeFixtureInstance -Fixture $fixture
        $runtime = Get-EzVmRuntimeFixtureState -Fixture $fixture
        $module = Get-Module EzVm
        $fixture.State.Processes[0].StartTimeUtc = ([DateTimeOffset]::Parse($runtime.processStartTimeUtc)).AddSeconds(5).ToString('o')
        Assert-EzVmThrows -ScriptBlock {
            & $module {param($r,$n,$l,$p) Assert-EzVmGuestHasNoKernelPanic -Root $r -InstanceName $n -LaunchId $l -ProcessProvider $p} $fixture.Root $fixture.InstanceName $runtime.launchId $fixture.ProcessProvider
        } -MessagePattern 'ownership is unproven' | Out-Null
        $fixture.State.Processes[0].StartTimeUtc = $runtime.processStartTimeUtc
        $runtime.serialLog = Join-Path $fixture.Root 'foreign.log'
        Write-EzVmJson -Path (Get-EzVmInstanceRuntimePaths -Root $fixture.Root -InstanceName $fixture.InstanceName).Runtime -Value $runtime
        Assert-EzVmThrows -ScriptBlock {
            & $module {param($r,$n,$l,$p) Assert-EzVmGuestHasNoKernelPanic -Root $r -InstanceName $n -LaunchId $l -ProcessProvider $p} $fixture.Root $fixture.InstanceName $runtime.launchId $fixture.ProcessProvider
        } -MessagePattern 'outside its launch-owned path' | Out-Null
    } finally { Remove-EzVmRuntimeFixture -Fixture $fixture }
}
