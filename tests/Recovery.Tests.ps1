Add-EzVmTest -Name 'Recovery: absent instance diagnosis is read-only and explicit about missing intent' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'absent diagnosis'
    try {
        $result = Get-EzVmInstanceDiagnosis -Root $root -InstanceName absent
        Assert-EzVmEqual $result.lifecycleState 'ABSENT'
        Assert-EzVmEqual $result.repairsPerformed $false
        Assert-EzVmTrue ($result.findings.code -contains 'instance_missing')
        Assert-EzVmEqual $result.imageCheck 'not-requested'
        Assert-EzVmTrue (-not (Test-Path -LiteralPath (Get-EzVmPaths $root).Runtime))
        $cli = Invoke-EzVmCommand -Root $root -Arguments @('diagnose', 'absent', '-Json')
        Assert-EzVmEqual $cli.exitCode 0
        Assert-EzVmEqual $cli.data.status 'attention'
        foreach ($args in @(@('diagnose'), @('diagnose', '../bad'), @('diagnose', 'one', '-Force'), @('diagnose', 'one', '-CheckImage', '-CheckImage'))) {
            Assert-EzVmEqual (Invoke-EzVmCommand -Root $root -Arguments $args).exitCode 2
        }
    }
    finally { Remove-EzVmTestDirectory $root }
}

Add-EzVmTest -Name 'Recovery: stopped image inspection verifies headers chain digest and integrity without changing data' -ScriptBlock {
    $fixture = New-EzVmSnapshotFixture
    try {
        $before = Get-EzVmFileDigest -Path $fixture.Disk -Algorithm SHA256
        $intentPath = (Get-EzVmInstanceRuntimePaths -Root $fixture.Root -InstanceName $fixture.Intent.name).Intent
        $intentBefore = [IO.File]::ReadAllText($intentPath)
        $result = Get-EzVmInstanceDiagnosis -Root $fixture.Root -InstanceName $fixture.Intent.name -CheckImage -ProcessProvider { @() } -QemuImgRunner $fixture.Runner
        Assert-EzVmEqual $result.imageCheck 'passed'
        Assert-EzVmEqual $result.repairsPerformed $false
        Assert-EzVmEqual (Get-EzVmFileDigest -Path $fixture.Disk -Algorithm SHA256) $before
        Assert-EzVmEqual ([IO.File]::ReadAllText($intentPath)) $intentBefore
    }
    finally { Remove-EzVmSnapshotFixture $fixture }
}

Add-EzVmTest -Name 'Recovery: running ambiguous and stale owners cannot reach offline diagnostic tools' -ScriptBlock {
    foreach ($mode in @('running', 'stale', 'unknown')) {
        $root = New-EzVmCheckoutFixture -Prefix ('diagnosis ownership ' + $mode)
        try {
            $intent = New-EzVmPortabilityIdentityTestIntent
            $access = New-EzVmSshTestAccess -Root $root -Intent $intent
            $launch = New-EzVmSshTestLaunch -Root $root -Intent $intent -Access $access
            $paths = Get-EzVmInstanceRuntimePaths -Root $root -InstanceName $intent.name
            $original = [IO.File]::ReadAllText($paths.Runtime)
            $provider = if ($mode -ceq 'running') { $launch.ProcessProvider } elseif ($mode -ceq 'stale') { { @() } } else { { throw 'process query unavailable' } }
            $observed = [pscustomobject]@{ Calls = 0 }
            $runner = { param($a) $observed.Calls++; throw 'must not invoke qemu-img' }.GetNewClosure()
            $result = Get-EzVmInstanceDiagnosis -Root $root -InstanceName $intent.name -CheckImage -ProcessProvider $provider -QemuImgRunner $runner
            Assert-EzVmEqual $result.imageCheck 'refused'
            Assert-EzVmEqual $observed.Calls 0
            Assert-EzVmEqual $result.repairsPerformed $false
            Assert-EzVmEqual ([IO.File]::ReadAllText($paths.Runtime)) $original
        }
        finally { Remove-EzVmTestDirectory $root }
    }
}

Add-EzVmTest -Name 'Recovery: missing base bad provenance and redirected backing provide actionable fail-closed findings' -ScriptBlock {
    foreach ($mode in @('missing', 'manifest', 'backing', 'digest', 'corrupt')) {
        $fixture = New-EzVmSnapshotFixture
        try {
            $paths = Get-EzVmInstanceRuntimePaths -Root $fixture.Root -InstanceName $fixture.Intent.name
            if ($mode -ceq 'missing') { [IO.File]::Move($fixture.Base.Image, ($fixture.Base.Image + '.saved')) }
            elseif ($mode -ceq 'manifest') {
                [IO.File]::SetAttributes($fixture.Base.ManifestPath, [IO.FileAttributes]::Normal)
                [IO.File]::WriteAllText($fixture.Base.ManifestPath, '{bad')
            }
            elseif ($mode -ceq 'backing') { Write-EzVmSnapshotFixtureImage -Path $fixture.Disk -Backing '../../../outside.qcow2' }
            elseif ($mode -ceq 'digest') {
                [IO.File]::SetAttributes($fixture.Base.Image, [IO.FileAttributes]::Normal)
                [IO.File]::AppendAllText($fixture.Base.Image, 'tamper')
            }
            else { $fixture.State.Mode = 'bad-check' }
            $before = Get-EzVmFileDigest -Path $fixture.Disk -Algorithm SHA256
            $result = Get-EzVmInstanceDiagnosis -Root $fixture.Root -InstanceName $fixture.Intent.name -CheckImage -ProcessProvider { @() } -QemuImgRunner $fixture.Runner
            Assert-EzVmEqual $result.imageCheck 'failed'
            Assert-EzVmTrue ($result.findings.Count -gt 0)
            Assert-EzVmTrue (@($result.findings | Where-Object { $_.remediation.Length -lt 20 }).Count -eq 0)
            Assert-EzVmEqual (Get-EzVmFileDigest -Path $fixture.Disk -Algorithm SHA256) $before
        }
        finally { Remove-EzVmSnapshotFixture $fixture }
    }
}

Add-EzVmTest -Name 'Recovery: interrupted reset journal and staging artifacts are preserved and never followed as instructions' -ScriptBlock {
    $fixture = New-EzVmSnapshotFixture
    try {
        $paths = Get-EzVmInstanceRuntimePaths -Root $fixture.Root -InstanceName $fixture.Intent.name
        $journal = '{"schemaVersion":1,"untrustedPath":"../../outside","private":"synthetic"}'
        [IO.File]::WriteAllText($paths.Operation, $journal)
        $artifact = Join-Path $paths.Directory ('.disk-backup-' + ('a' * 32) + '.qcow2')
        [IO.File]::WriteAllText($artifact, 'recovery bytes')
        $result = Get-EzVmInstanceDiagnosis -Root $fixture.Root -InstanceName $fixture.Intent.name -CheckImage -ProcessProvider { @() } -QemuImgRunner { throw 'must not open image' }
        Assert-EzVmEqual $result.imageCheck 'refused'
        Assert-EzVmTrue ($result.findings.code -contains 'interrupted_reset')
        Assert-EzVmEqual $result.recoveryArtifacts.Count 1
        Assert-EzVmEqual ([IO.File]::ReadAllText($artifact)) 'recovery bytes'
        Assert-EzVmEqual ([IO.File]::ReadAllText($paths.Operation)) $journal
        Assert-EzVmTrue (($result | ConvertTo-Json -Depth 8) -notmatch 'untrustedPath|synthetic')
    }
    finally { Remove-EzVmSnapshotFixture $fixture }
}

Add-EzVmTest -Name 'Recovery: a real loopback collision is diagnosed without changing durable reservations' -ScriptBlock {
    $fixture = New-EzVmSnapshotFixture
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        $fixture.Intent.sshPort = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
        $paths = Get-EzVmInstanceRuntimePaths -Root $fixture.Root -InstanceName $fixture.Intent.name
        Write-EzVmJson -Path $paths.Intent -Value $fixture.Intent -SchemaVersion 2
        $before = [IO.File]::ReadAllText($paths.Intent)
        $result = Get-EzVmInstanceDiagnosis -Root $fixture.Root -InstanceName $fixture.Intent.name -ProcessProvider { @() }
        Assert-EzVmTrue ($result.findings.code -contains 'port_collision')
        Assert-EzVmEqual ([IO.File]::ReadAllText($paths.Intent)) $before
    }
    finally { $listener.Stop(); Remove-EzVmSnapshotFixture $fixture }
}

Add-EzVmTest -Name 'Recovery: failed base build clears seed input while preserving disk and redacted failure evidence' -ScriptBlock {
    $fixture = New-EzVmBaseBuildFixture
    try {
        $credential = 'ghp_' + ('Z' * 36)
        $guest = { param($context) throw ('failure with ' + $credential) }.GetNewClosure()
        Assert-EzVmThrows { Invoke-EzVmBaseBuild -Root $fixture.Root -Accelerator tcg -BuildTimeoutSeconds 60 -QemuStatusProvider $fixture.QemuStatusProvider -SourceProvider $fixture.SourceProvider -QemuImgRunner $fixture.QemuImgRunner -GuestRunner $guest } | Out-Null
        $stage = @(Get-ChildItem -LiteralPath $fixture.Paths.Bases -Directory -Force -Filter '.build-*')[0]
        Assert-EzVmTrue (-not (Test-Path -LiteralPath (Join-Path $stage.FullName 'seed')))
        Assert-EzVmTrue (Test-Path -LiteralPath (Join-Path $stage.FullName 'staging.qcow2'))
        $failure = [IO.File]::ReadAllText((Join-Path $stage.FullName 'failure.json'))
        Assert-EzVmTrue ($failure.Contains('[REDACTED]') -and -not $failure.Contains($credential))
    }
    finally { Remove-EzVmBaseBuildFixture $fixture }
}
