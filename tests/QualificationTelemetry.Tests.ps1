. (Join-Path $script:EzVmRepositoryRoot 'scripts/QualificationTelemetry.ps1')

function Invoke-EzVmTelemetryTest {
    param([scriptblock]$Action, [scriptblock]$Arrange)
    $directory = New-EzVmTestDirectory -Prefix 'qualification telemetry'
    $state = $null
    $modulePath = Join-Path $script:EzVmRepositoryRoot 'src/EzVm/EzVm.psd1'
    try {
        $module = Import-Module $modulePath -Force -PassThru
        if ($null -ne $Arrange) { & $module $Arrange $directory }
        $state = New-EzVmQualificationTelemetry -Path (Join-Path $directory 'timing.jsonl')
        Enable-EzVmQualificationTelemetry -State $state -Module $module
        Import-Module -ModuleInfo $module -Force
        & $Action $state $directory $module
    }
    finally {
        if ($null -ne $state) {
            Disable-EzVmQualificationTelemetry -State $state
            if ($state.stream.CanWrite) { Close-EzVmQualificationTelemetry -State $state -Failed $true }
        }
        Import-Module $modulePath -Force
        Remove-EzVmTestDirectory -Path $directory
    }
}

Add-EzVmTest -Name 'Qualification telemetry: original module defaults, object identity and bound parameters survive observation' -ScriptBlock {
    Invoke-EzVmTelemetryTest -Arrange {
        $script:telemetryResult = [pscustomobject]@{ value = 'original object'; root = $null; count = 0 }
        function script:Get-EzVmDoctorReport {
            [CmdletBinding()]param([string]$Root = $script:EzVmDefaultRoot)
            $script:telemetryResult.root = $Root
            $script:telemetryResult.count++
            return $script:telemetryResult
        }
    } -Action {
        param($State, $Directory, $Module)
        $expected = & $Module { $script:telemetryResult }
        $result = Get-EzVmDoctorReport
        Assert-EzVmTrue ([object]::ReferenceEquals($result, $expected))
        Assert-EzVmEqual $result.root $script:EzVmRepositoryRoot
        Assert-EzVmEqual $result.count 1
        $result = Get-EzVmDoctorReport -Root 'explicit root with spaces'
        Assert-EzVmEqual $result.root 'explicit root with spaces'
        Assert-EzVmEqual $result.count 2
        $before = $State.sequence
        Disable-EzVmQualificationTelemetry -State $State
        Import-Module -ModuleInfo $Module -Force
        $null = Get-EzVmDoctorReport
        Assert-EzVmEqual $State.sequence $before 'Disabled observer changed the event sequence.'
    }
}

Add-EzVmTest -Name 'Qualification telemetry: nested validation retains hash results with bounded aggregate counters' -ScriptBlock {
    Invoke-EzVmTelemetryTest -Arrange {
        param($Directory)
        $script:telemetryFixture = Join-Path $Directory 'manifest.json'
        [IO.File]::WriteAllText($script:telemetryFixture, 'synthetic public manifest')
        function script:Get-EzVmDoctorReport {
            [CmdletBinding()]param([string]$Root = $script:EzVmDefaultRoot)
            Test-EzVmPreparedBaseDirectory -Root $Root -Directory $script:telemetryFixture -BaseId fixture
        }
        function script:Test-EzVmPreparedBaseDirectory {
            [CmdletBinding()]param([string]$Root, [string]$Directory, [string]$BaseId)
            for ($n = 0; $n -lt 100; $n++) { $hash = Get-EzVmFileDigest -Path $Directory -Algorithm SHA256 }
            return $hash
        }
    } -Action {
        param($State, $Directory)
        $expected = Get-EzVmFileDigest -Path (Join-Path $Directory 'manifest.json') -Algorithm SHA256
        Assert-EzVmEqual (Get-EzVmDoctorReport) $expected
        $events = @(Get-Content -LiteralPath (Join-Path $Directory 'timing.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
        Assert-EzVmEqual $events.Count 5 'Individual payload hashes must not create a log flood.'
        $inner = @($events | Where-Object { $_.event -ceq 'end' -and $_.operation -ceq 'Test-EzVmPreparedBaseDirectory' })[0]
        $outer = @($events | Where-Object { $_.event -ceq 'end' -and $_.operation -ceq 'Get-EzVmDoctorReport' })[0]
        Assert-EzVmEqual $inner.parentOperationId $outer.operationId
        Assert-EzVmEqual $inner.digestTotals.manifest.calls 100
        Assert-EzVmEqual $outer.digestTotals.manifest.calls 100
        Assert-EzVmEqual $inner.digestTotals.manifest.failedCalls 0
        Assert-EzVmTrue ($outer.durationSeconds -ge $inner.durationSeconds -and $inner.durationSeconds -ge 0)
        Assert-EzVmTrue ($State.digestTotals.manifest.calls -eq 101)
        for ($n = 0; $n -lt $events.Count; $n++) {
            Assert-EzVmEqual $events[$n].sequence ($n + 1)
            Assert-EzVmTrue ($events[$n].elapsedSeconds -ge 0)
        }
    }
}

Add-EzVmTest -Name 'Qualification telemetry: original terminating error and preceding output are preserved without logging payloads' -ScriptBlock {
    Invoke-EzVmTelemetryTest -Arrange {
        function script:Get-EzVmDoctorReport {
            [CmdletBinding()]param([string]$Root)
            Write-Output 'synthetic output before error'
            throw 'synthetic private diagnostic must stay out of telemetry'
        }
    } -Action {
        param($State, $Directory)
        $output = New-Object 'Collections.Generic.List[object]'
        $caught = $null
        try { Get-EzVmDoctorReport -Root 'synthetic private path' | ForEach-Object { $output.Add($_) } } catch { $caught = $_ }
        Assert-EzVmEqual $caught.Exception.Message 'synthetic private diagnostic must stay out of telemetry'
        Assert-EzVmEqual @($output.ToArray()) @('synthetic output before error')
        # ReadAllText does not share an existing writer on Windows. Inspect the
        # retained evidence after the failed session is finalized and closed.
        Assert-EzVmTrue $State.stream.CanWrite
        Disable-EzVmQualificationTelemetry -State $State
        Close-EzVmQualificationTelemetry -State $State -Failed $true
        Assert-EzVmTrue (-not $State.stream.CanWrite)
        Assert-EzVmTrue (-not $State.writerFailed)
        Assert-EzVmEqual $State.stack.Count 0
        $text = [IO.File]::ReadAllText((Join-Path $Directory 'timing.jsonl'))
        Assert-EzVmTrue (-not $text.Contains('synthetic private'))
        Assert-EzVmTrue (-not $text.Contains('synthetic output'))
        $events = @($text -split "`n" | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        Assert-EzVmEqual $events.Count 4
        $event = $events[-2]
        Assert-EzVmEqual $event.event failure
        Assert-EzVmEqual $event.operation Get-EzVmDoctorReport
        Assert-EzVmEqual $events[-1].event failure
        Assert-EzVmEqual $events[-1].operation full-release
    }
}

Add-EzVmTest -Name 'Qualification telemetry: native process result and nonzero exit are unchanged' -ScriptBlock {
    Invoke-EzVmTelemetryTest -Action {
        param($State)
        $executable = Join-Path $PSHOME $(if ($script:EzVmIsWindowsHost -and $PSVersionTable.PSVersion.Major -eq 5) { 'powershell.exe' } elseif ($script:EzVmIsWindowsHost) { 'pwsh.exe' } else { 'pwsh' })
        $result = Invoke-EzVmProcess -FilePath $executable -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', "[Console]::Out.Write('public fixture'); exit 7") -TimeoutSeconds 30
        Assert-EzVmEqual $result.ExitCode 7
        Assert-EzVmEqual $result.StdOut 'public fixture'
        Assert-EzVmEqual $result.StdErr ''
        $null = Assert-EzVmThrows -ScriptBlock {
            Invoke-EzVmProcess -FilePath $executable -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'exit 9') -TimeoutSeconds 30 -ThrowOnError
        } -MessagePattern '9'
    }
}

Add-EzVmTest -Name 'Qualification telemetry: writer fault latches and cannot replace an original failure' -ScriptBlock {
    Invoke-EzVmTelemetryTest -Arrange {
        function script:Get-EzVmDoctorReport {
            [CmdletBinding()]param([string]$Root)
            $script:EzVmQualificationTelemetryState.stream.Dispose()
            throw 'original operation failure after writer fault'
        }
    } -Action {
        param($State)
        $null = Assert-EzVmThrows { Get-EzVmDoctorReport } -MessagePattern '^original operation failure after writer fault$'
        Assert-EzVmTrue $State.writerFailed
        $null = Assert-EzVmThrows { Get-EzVmDoctorReport } -MessagePattern 'telemetry is incomplete'
        $null = Assert-EzVmThrows { Close-EzVmQualificationTelemetry -State $State -Failed $false } -MessagePattern 'telemetry'
    }
}

Add-EzVmTest -Name 'Qualification telemetry: relocated module retains its own root and the same observation session' -ScriptBlock {
    Invoke-EzVmTelemetryTest -Arrange {
        function script:Get-EzVmDoctorReport { [CmdletBinding()]param([string]$Root = $script:EzVmDefaultRoot) return $Root }
    } -Action {
        param($State)
        $relocated = New-EzVmCheckoutFixture -Prefix 'telemetry relocated root'
        $module = $null
        try {
            Assert-EzVmEqual (Get-EzVmDoctorReport) $script:EzVmRepositoryRoot
            $oldSequence = $State.sequence
            Disable-EzVmQualificationTelemetry -State $State
            $module = Import-Module (Join-Path $relocated 'src/EzVm/EzVm.psd1') -Force -PassThru
            & $module {
                function script:Get-EzVmDoctorReport { [CmdletBinding()]param([string]$Root = $script:EzVmDefaultRoot) return $Root }
            }
            Enable-EzVmQualificationTelemetry -State $State -Module $module
            Import-Module -ModuleInfo $module -Force
            Assert-EzVmEqual (Get-EzVmDoctorReport) $relocated
            Assert-EzVmEqual $State.sequence ($oldSequence + 2)
        }
        finally {
            Disable-EzVmQualificationTelemetry -State $State
            if ($null -ne $module) { Remove-Module -ModuleInfo $module -Force }
            Remove-EzVmTestDirectory -Path $relocated
        }
    }
}

Add-EzVmTest -Name 'Qualification telemetry: fresh path and byte bound refuse overwrite and truncated success' -ScriptBlock {
    $directory = New-EzVmTestDirectory -Prefix 'telemetry boundaries'
    $state = $null
    try {
        $path = Join-Path $directory 'receipt.jsonl'
        [IO.File]::WriteAllText($path, 'unrelated sentinel')
        $null = Assert-EzVmThrows { New-EzVmQualificationTelemetry -Path $path }
        Assert-EzVmEqual ([IO.File]::ReadAllText($path)) 'unrelated sentinel'
        $null = Assert-EzVmThrows { New-EzVmQualificationTelemetry -Path relative.jsonl } -MessagePattern 'absolute'
        $state = New-EzVmQualificationTelemetry -Path (Join-Path $directory 'bounded.jsonl') -MaximumBytes 512
        $null = Assert-EzVmThrows {
            Write-EzVmQualificationIdentity -State $state -Kind qemu-img -Sha256 ('a' * 64) -SizeBytes 20 -Version 11.1.0
        } -MessagePattern 'bound'
        Assert-EzVmTrue $state.writerFailed
        Assert-EzVmTrue ((Get-Item -LiteralPath (Join-Path $directory 'bounded.jsonl')).Length -le 512)
        $null = Assert-EzVmThrows { Close-EzVmQualificationTelemetry -State $state -Failed $false }
    }
    finally { if ($null -ne $state) { $state.stream.Dispose() }; Remove-EzVmTestDirectory -Path $directory }
}
