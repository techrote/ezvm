function New-EzVmStorageFixture {
    $baseFixture = New-EzVmBaseBuildFixture
    $safe = New-EzVmStorageLifecycleGuard -State 'proven-safe' -Source 'storage fixture: no QEMU process owns these synthetic images'
    $baseResult = Invoke-EzVmBaseBuild -Root $baseFixture.Root -Accelerator tcg -BuildTimeoutSeconds 60 -QemuStatusProvider $baseFixture.QemuStatusProvider -SourceProvider $baseFixture.SourceProvider -QemuImgRunner $baseFixture.QemuImgRunner -GuestRunner $baseFixture.GuestRunner

    $state = [pscustomobject]@{
        Mode = 'normal'
        CreateCount = 0
        Calls = New-Object 'System.Collections.Generic.List[object]'
    }
    $baseRunner = $baseFixture.QemuImgRunner
    $stateForRunner = $state
    $runner = {
        param($argumentList)
        $arguments = @($argumentList)
        $stateForRunner.Calls.Add([string[]]$arguments)
        $command = $arguments[0]

        if ($command -ceq 'create') {
            $destination = [IO.Path]::GetFullPath($arguments[$arguments.Count - 1])
            $backingIndex = [Array]::IndexOf($arguments, '-b')
            if ($backingIndex -lt 0 -or $backingIndex + 1 -ge $arguments.Count) {
                return [pscustomobject]@{ ExitCode = 2; StdOut = ''; StdErr = 'missing backing argument' }
            }
            $backing = $arguments[$backingIndex + 1]
            $resolved = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($destination)) $backing))
            if (-not [IO.File]::Exists($resolved)) {
                return [pscustomobject]@{ ExitCode = 2; StdOut = ''; StdErr = 'fixture backing file is missing' }
            }
            $stateForRunner.CreateCount++
            $payload = [pscustomobject][ordered]@{
                kind = 'overlay'
                backing = $backing
                generation = $stateForRunner.CreateCount
            }
            [IO.File]::WriteAllText($destination, ($payload | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
            return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
        }

        if ($command -ceq 'info') {
            $path = [IO.Path]::GetFullPath($arguments[$arguments.Count - 1])
            $payload = $null
            try {
                $text = [IO.File]::ReadAllText($path)
                if ($text.StartsWith('{', [StringComparison]::Ordinal)) {
                    $payload = $text | ConvertFrom-Json -ErrorAction Stop
                }
            }
            catch { $payload = $null }

            if ($null -ne $payload -and $payload.kind -ceq 'overlay') {
                if ($stateForRunner.Mode -ceq 'malformed-chain-json' -and $arguments -ccontains '--backing-chain') {
                    return [pscustomobject]@{ ExitCode = 0; StdOut = '{"broken":'; StdErr = '' }
                }

                $backing = [string]$payload.backing
                $resolved = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($path)) $backing))
                $format = if ($stateForRunner.Mode -ceq 'wrong-backing-format' -or
                    ($stateForRunner.Mode -ceq 'wrong-replacement-format' -and [int]$payload.generation -gt 1)) { 'raw' } else { 'qcow2' }
                $top = [pscustomobject][ordered]@{
                    filename = $path
                    format = 'qcow2'
                    'virtual-size' = [long]17179869184
                    'backing-filename' = $backing
                    'backing-filename-format' = $format
                }
                $base = [pscustomobject][ordered]@{
                    filename = $resolved
                    format = 'qcow2'
                    'virtual-size' = [long]17179869184
                }
                if ($arguments -ccontains '--backing-chain') {
                    $chain = @($top, $base)
                    if ($stateForRunner.Mode -ceq 'second-level') {
                        $chain += [pscustomobject][ordered]@{
                            filename = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($resolved)) 'deeper.qcow2'))
                            format = 'qcow2'
                            'virtual-size' = [long]17179869184
                        }
                    }
                    return [pscustomobject]@{ ExitCode = 0; StdOut = ($chain | ConvertTo-Json -Compress); StdErr = '' }
                }
                return [pscustomobject]@{ ExitCode = 0; StdOut = ($top | ConvertTo-Json -Compress); StdErr = '' }
            }

            return & $baseRunner $arguments
        }

        if ($command -ceq 'check') {
            if ($stateForRunner.Mode -ceq 'malformed-check-json') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = 'not-json'; StdErr = '' }
            }
            if ($stateForRunner.Mode -ceq 'corrupt-check') {
                return [pscustomobject]@{
                    ExitCode = 2
                    StdOut = '{"filename":"fixture","format":"qcow2","check-errors":0,"corruptions":2,"leaks":1}'
                    StdErr = 'synthetic corruption'
                }
            }
            return [pscustomobject]@{
                ExitCode = 0
                StdOut = '{"filename":"fixture","format":"qcow2","check-errors":0,"corruptions":0,"leaks":0}'
                StdErr = ''
            }
        }

        return & $baseRunner $arguments
    }.GetNewClosure()

    return [pscustomobject]@{
        BaseFixture = $baseFixture
        Root = $baseFixture.Root
        Paths = $baseFixture.Paths
        BaseId = $baseResult.baseId
        BasePath = $baseResult.path
        SafeGuard = $safe
        Runner = $runner
        State = $state
    }
}

function Remove-EzVmStorageFixture {
    param([object]$Fixture)
    if ($null -ne $Fixture) { Remove-EzVmBaseBuildFixture $Fixture.BaseFixture }
}

function Get-EzVmStorageOverlayPayload {
    param([string]$Path)
    return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop)
}

function Set-EzVmStorageOverlayBacking {
    param([string]$Path, [string]$Backing)
    $payload = Get-EzVmStorageOverlayPayload -Path $Path
    $payload.backing = $Backing
    [IO.File]::WriteAllText($Path, ($payload | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
}

Add-EzVmTest -Name 'Storage: rejects unsafe instance names before filesystem mutation' -ScriptBlock {
    $fixture = New-EzVmStorageFixture
    try {
        $result = New-EzVmInstanceOverlay -Root $fixture.Root -InstanceName 'agent one' -BaseId $fixture.BaseId -LifecycleGuard $fixture.SafeGuard -QemuImgRunner $fixture.Runner
        throw 'fixture should reject spaces in instance names before this point'
    }
    catch {
        Assert-EzVmTrue -Condition ($_.Exception.Message -match 'Instance name') -Message 'Instance names containing spaces must be rejected before filesystem mutation.'
    }
    finally { Remove-EzVmStorageFixture $fixture }
}

Add-EzVmTest -Name 'Storage: valid overlay uses explicit qcow2 backing and validates exact immutable base' -ScriptBlock {
    $fixture = New-EzVmStorageFixture
    try {
        $baseBefore = Get-EzVmFileDigest -Path $fixture.BasePath -Algorithm SHA256
        $result = New-EzVmInstanceOverlay -Root $fixture.Root -InstanceName 'agent-one' -BaseId $fixture.BaseId -LifecycleGuard $fixture.SafeGuard -QemuImgRunner $fixture.Runner
        $validated = Test-EzVmInstanceStorage -Root $fixture.Root -InstanceName 'agent-one' -BaseId $fixture.BaseId -QemuImgRunner $fixture.Runner

        Assert-EzVmEqual -Actual $validated.ChainDepth -Expected 1
        Assert-EzVmEqual -Actual $validated.BasePath -Expected $fixture.BasePath
        Assert-EzVmEqual -Actual $validated.ResolvedBackingPath -Expected $fixture.BasePath
        Assert-EzVmTrue -Condition (-not [IO.Path]::IsPathRooted($validated.BackingReference))
        Assert-EzVmEqual -Actual (Get-EzVmFileDigest -Path $fixture.BasePath -Algorithm SHA256) -Expected $baseBefore -Message 'Overlay creation must never mutate the immutable base.'

        $createCall = @($fixture.State.Calls | Where-Object { $_[0] -ceq 'create' })[-1]
        Assert-EzVmTrue -Condition ($createCall -ccontains '-f')
        Assert-EzVmTrue -Condition ($createCall -ccontains '-F')
        Assert-EzVmTrue -Condition ($createCall -ccontains '-b')
        Assert-EzVmTrue -Condition ($createCall -cnotcontains '-u') -Message 'Unsafe backing creation must never be used.'
        $fIndex = [Array]::IndexOf($createCall, '-f')
        $FIndex = [Array]::IndexOf($createCall, '-F')
        Assert-EzVmEqual -Actual $createCall[$fIndex + 1] -Expected 'qcow2'
        Assert-EzVmEqual -Actual $createCall[$FIndex + 1] -Expected 'qcow2'
        Assert-EzVmEqual -Actual $result.BackingReference -Expected $validated.BackingReference
    }
    finally { Remove-EzVmStorageFixture $fixture }
}

Add-EzVmTest -Name 'Storage: relative backing survives complete cold root relocation without rebase' -ScriptBlock {
    $fixture = New-EzVmStorageFixture
    $target = $null
    try {
        $created = New-EzVmInstanceOverlay -Root $fixture.Root -InstanceName 'relocate' -BaseId $fixture.BaseId -LifecycleGuard $fixture.SafeGuard -QemuImgRunner $fixture.Runner
        $referenceBefore = $created.BackingReference

        $target = New-EzVmCheckoutFixture -Prefix 'relocated complete root B [different prefix]'
        Copy-Item -LiteralPath (Join-Path $fixture.Root 'runtime') -Destination $target -Recurse -Force
        $validated = Test-EzVmInstanceStorage -Root $target -InstanceName 'relocate' -BaseId $fixture.BaseId -QemuImgRunner $fixture.Runner

        Assert-EzVmEqual -Actual $validated.BackingReference -Expected $referenceBefore
        Assert-EzVmTrue -Condition ($validated.OverlayPath.StartsWith([IO.Path]::GetFullPath($target), [StringComparison]::OrdinalIgnoreCase))
        Assert-EzVmTrue -Condition ($validated.BasePath.StartsWith([IO.Path]::GetFullPath($target), [StringComparison]::OrdinalIgnoreCase))
        $allCalls = [string]::Join([Environment]::NewLine, [string[]]@($fixture.State.Calls | ForEach-Object { $_ -join ' ' }))
        Assert-EzVmTrue -Condition ($allCalls -notmatch '(?i)\brebase\b') -Message 'Relocation must not rebase a valid normal instance.'
    }
    finally {
        if ($null -ne $target) { Remove-EzVmTestDirectory -Path $target }
        Remove-EzVmStorageFixture $fixture
    }
}

Add-EzVmTest -Name 'Storage: rejects missing backing base and base digest mismatch' -ScriptBlock {
    $fixture = New-EzVmStorageFixture
    try {
        $null = New-EzVmInstanceOverlay -Root $fixture.Root -InstanceName 'missing-base' -BaseId $fixture.BaseId -LifecycleGuard $fixture.SafeGuard -QemuImgRunner $fixture.Runner
        $attributes = (Get-Item -LiteralPath $fixture.BasePath -Force).Attributes
        [IO.File]::SetAttributes($fixture.BasePath, ($attributes -band (-bnot [IO.FileAttributes]::ReadOnly)))
        [IO.File]::AppendAllText($fixture.BasePath, 'tamper')
        [IO.File]::SetAttributes($fixture.BasePath, ((Get-Item -LiteralPath $fixture.BasePath -Force).Attributes -bor [IO.FileAttributes]::ReadOnly))
        Assert-EzVmThrows -ScriptBlock {
            Test-EzVmInstanceStorage -Root $fixture.Root -InstanceName 'missing-base' -BaseId $fixture.BaseId -QemuImgRunner $fixture.Runner
        } -MessagePattern 'digest does not match' | Out-Null

        [IO.File]::SetAttributes($fixture.BasePath, ((Get-Item -LiteralPath $fixture.BasePath -Force).Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)))
        Remove-Item -LiteralPath $fixture.BasePath -Force
        Assert-EzVmThrows -ScriptBlock {
            Test-EzVmInstanceStorage -Root $fixture.Root -InstanceName 'missing-base' -BaseId $fixture.BaseId -QemuImgRunner $fixture.Runner
        } -MessagePattern 'incomplete|missing' | Out-Null
    }
    finally { Remove-EzVmStorageFixture $fixture }
}

Add-EzVmTest -Name 'Storage: rejects wrong backing format and unsupported second backing level' -ScriptBlock {
    $fixture = New-EzVmStorageFixture
    try {
        $null = New-EzVmInstanceOverlay -Root $fixture.Root -InstanceName 'bad-chain' -BaseId $fixture.BaseId -LifecycleGuard $fixture.SafeGuard -QemuImgRunner $fixture.Runner
        $fixture.State.Mode = 'wrong-backing-format'
        Assert-EzVmThrows -ScriptBlock {
            Test-EzVmInstanceStorage -Root $fixture.Root -InstanceName 'bad-chain' -BaseId $fixture.BaseId -QemuImgRunner $fixture.Runner
        } -MessagePattern 'backing format.*qcow2' | Out-Null

        $fixture.State.Mode = 'second-level'
        Assert-EzVmThrows -ScriptBlock {
            Test-EzVmInstanceStorage -Root $fixture.Root -InstanceName 'bad-chain' -BaseId $fixture.BaseId -QemuImgRunner $fixture.Runner
        } -MessagePattern 'backing-chain depth 2' | Out-Null
    }
    finally { Remove-EzVmStorageFixture $fixture }
}

Add-EzVmTest -Name 'Storage: rejects backing path escape and wrong existing managed backing' -ScriptBlock {
    $fixture = New-EzVmStorageFixture
    try {
        $created = New-EzVmInstanceOverlay -Root $fixture.Root -InstanceName 'escape' -BaseId $fixture.BaseId -LifecycleGuard $fixture.SafeGuard -QemuImgRunner $fixture.Runner
        Set-EzVmStorageOverlayBacking -Path $created.Disk -Backing '..\..\..\outside.qcow2'
        Assert-EzVmThrows -ScriptBlock {
            Test-EzVmInstanceStorage -Root $fixture.Root -InstanceName 'escape' -BaseId $fixture.BaseId -QemuImgRunner $fixture.Runner
        } -MessagePattern 'outside.*managed|escapes' | Out-Null

        $wrongDirectory = Join-Path $fixture.Paths.Bases 'wrong-base'
        [void][IO.Directory]::CreateDirectory($wrongDirectory)
        $wrongFile = Join-Path $wrongDirectory 'base.qcow2'
        [IO.File]::WriteAllText($wrongFile, 'wrong base fixture')
        $relative = Get-EzVmStorageRelativePath -FromDirectory ([IO.Path]::GetDirectoryName($created.Disk)) -TargetPath $wrongFile
        Set-EzVmStorageOverlayBacking -Path $created.Disk -Backing $relative
        Assert-EzVmThrows -ScriptBlock {
            Test-EzVmInstanceStorage -Root $fixture.Root -InstanceName 'escape' -BaseId $fixture.BaseId -QemuImgRunner $fixture.Runner
        } -MessagePattern 'recorded base.*requires' | Out-Null
    }
    finally { Remove-EzVmStorageFixture $fixture }
}

Add-EzVmTest -Name 'Storage: malformed qemu-img JSON fails closed' -ScriptBlock {
    $fixture = New-EzVmStorageFixture
    try {
        $null = New-EzVmInstanceOverlay -Root $fixture.Root -InstanceName 'json' -BaseId $fixture.BaseId -LifecycleGuard $fixture.SafeGuard -QemuImgRunner $fixture.Runner
        $fixture.State.Mode = 'malformed-chain-json'
        Assert-EzVmThrows -ScriptBlock {
            Test-EzVmInstanceStorage -Root $fixture.Root -InstanceName 'json' -BaseId $fixture.BaseId -QemuImgRunner $fixture.Runner
        } -MessagePattern 'malformed JSON' | Out-Null
    }
    finally { Remove-EzVmStorageFixture $fixture }
}

Add-EzVmTest -Name 'Storage: lifecycle guard fails closed for missing, running, transitional and unknown state' -ScriptBlock {
    $fixture = New-EzVmStorageFixture
    try {
        Assert-EzVmThrows -ScriptBlock {
            New-EzVmInstanceOverlay -Root $fixture.Root -InstanceName 'guard-none' -BaseId $fixture.BaseId -LifecycleGuard $null -QemuImgRunner $fixture.Runner
        } -MessagePattern 'explicit positive lifecycle evidence' | Out-Null

        foreach ($state in @('running', 'starting', 'stopping', 'unknown')) {
            $guard = New-EzVmStorageLifecycleGuard -State $state -Source 'fixture'
            Assert-EzVmThrows -ScriptBlock {
                New-EzVmInstanceOverlay -Root $fixture.Root -InstanceName ('guard-' + $state) -BaseId $fixture.BaseId -LifecycleGuard $guard -QemuImgRunner $fixture.Runner
            } -MessagePattern 'requires positively proven' | Out-Null
        }
        Assert-EzVmEqual -Actual @(Get-ChildItem -LiteralPath $fixture.Paths.Instances -Filter 'guard-*' -Directory -ErrorAction SilentlyContinue).Count -Expected 0
    }
    finally { Remove-EzVmStorageFixture $fixture }
}

Add-EzVmTest -Name 'Storage: stopped-only check reports healthy and corrupt metadata without repair' -ScriptBlock {
    $fixture = New-EzVmStorageFixture
    try {
        $null = New-EzVmInstanceOverlay -Root $fixture.Root -InstanceName 'check' -BaseId $fixture.BaseId -LifecycleGuard $fixture.SafeGuard -QemuImgRunner $fixture.Runner
        $healthy = Test-EzVmStoppedImageIntegrity -Root $fixture.Root -InstanceName 'check' -BaseId $fixture.BaseId -LifecycleGuard $fixture.SafeGuard -QemuImgRunner $fixture.Runner
        Assert-EzVmTrue -Condition $healthy.Healthy
        Assert-EzVmEqual -Actual $healthy.Corruptions -Expected 0

        $fixture.State.Mode = 'corrupt-check'
        $bad = Test-EzVmStoppedImageIntegrity -Root $fixture.Root -InstanceName 'check' -BaseId $fixture.BaseId -LifecycleGuard $fixture.SafeGuard -QemuImgRunner $fixture.Runner
        Assert-EzVmTrue -Condition (-not $bad.Healthy)
        Assert-EzVmEqual -Actual $bad.Corruptions -Expected 2
        Assert-EzVmEqual -Actual $bad.Leaks -Expected 1

        $checkCalls = @($fixture.State.Calls | Where-Object { $_[0] -ceq 'check' })
        foreach ($call in $checkCalls) {
            Assert-EzVmTrue -Condition ($call -cnotcontains '-r') -Message 'Integrity diagnostics must never request automatic repair.'
        }

        $fixture.State.Mode = 'malformed-check-json'
        Assert-EzVmThrows -ScriptBlock {
            Test-EzVmStoppedImageIntegrity -Root $fixture.Root -InstanceName 'check' -BaseId $fixture.BaseId -LifecycleGuard $fixture.SafeGuard -QemuImgRunner $fixture.Runner
        } -MessagePattern 'malformed JSON' | Out-Null
    }
    finally { Remove-EzVmStorageFixture $fixture }
}

Add-EzVmTest -Name 'Storage: reset validates replacement before changing original overlay' -ScriptBlock {
    $fixture = New-EzVmStorageFixture
    try {
        $created = New-EzVmInstanceOverlay -Root $fixture.Root -InstanceName 'reset-invalid' -BaseId $fixture.BaseId -LifecycleGuard $fixture.SafeGuard -QemuImgRunner $fixture.Runner
        $before = [IO.File]::ReadAllText($created.Disk)
        $fixture.State.Mode = 'wrong-replacement-format'
        Assert-EzVmThrows -ScriptBlock {
            Reset-EzVmInstanceOverlayStorage -Root $fixture.Root -InstanceName 'reset-invalid' -BaseId $fixture.BaseId -LifecycleGuard $fixture.SafeGuard -QemuImgRunner $fixture.Runner
        } -MessagePattern 'backing format' | Out-Null
        Assert-EzVmEqual -Actual ([IO.File]::ReadAllText($created.Disk)) -Expected $before -Message 'Invalid replacement must leave original overlay untouched.'
    }
    finally { Remove-EzVmStorageFixture $fixture }
}

Add-EzVmTest -Name 'Storage: failed replacement promotion restores original overlay' -ScriptBlock {
    $fixture = New-EzVmStorageFixture
    try {
        $created = New-EzVmInstanceOverlay -Root $fixture.Root -InstanceName 'reset-restore' -BaseId $fixture.BaseId -LifecycleGuard $fixture.SafeGuard -QemuImgRunner $fixture.Runner
        $before = [IO.File]::ReadAllText($created.Disk)
        $moveState = [pscustomobject]@{ Count = 0 }
        $mover = {
            param($source, $destination)
            $moveState.Count++
            if ($moveState.Count -eq 2) { throw [InvalidOperationException]::new('synthetic candidate promotion failure') }
            [IO.File]::Move($source, $destination)
        }.GetNewClosure()
        Assert-EzVmThrows -ScriptBlock {
            Reset-EzVmInstanceOverlayStorage -Root $fixture.Root -InstanceName 'reset-restore' -BaseId $fixture.BaseId -LifecycleGuard $fixture.SafeGuard -QemuImgRunner $fixture.Runner -FileMover $mover
        } -MessagePattern 'synthetic candidate promotion failure' | Out-Null
        Assert-EzVmEqual -Actual ([IO.File]::ReadAllText($created.Disk)) -Expected $before -Message 'Failed promotion must restore the original overlay.'
        Assert-EzVmEqual -Actual $moveState.Count -Expected 3 -Message 'Expected original->backup, failed candidate->active, then backup->active restore.'
    }
    finally { Remove-EzVmStorageFixture $fixture }
}

Add-EzVmTest -Name 'Storage: successful reset commits only validated replacement and preserves base bytes' -ScriptBlock {
    $fixture = New-EzVmStorageFixture
    try {
        $baseBefore = Get-EzVmFileDigest -Path $fixture.BasePath -Algorithm SHA256
        $created = New-EzVmInstanceOverlay -Root $fixture.Root -InstanceName 'reset-ok' -BaseId $fixture.BaseId -LifecycleGuard $fixture.SafeGuard -QemuImgRunner $fixture.Runner
        $firstGeneration = (Get-EzVmStorageOverlayPayload -Path $created.Disk).generation
        $result = Reset-EzVmInstanceOverlayStorage -Root $fixture.Root -InstanceName 'reset-ok' -BaseId $fixture.BaseId -LifecycleGuard $fixture.SafeGuard -QemuImgRunner $fixture.Runner
        $secondGeneration = (Get-EzVmStorageOverlayPayload -Path $result.Disk).generation
        Assert-EzVmTrue -Condition ([int]$secondGeneration -gt [int]$firstGeneration)
        Assert-EzVmTrue -Condition $result.Replaced
        Assert-EzVmEqual -Actual (Get-EzVmFileDigest -Path $fixture.BasePath -Algorithm SHA256) -Expected $baseBefore
        $null = Test-EzVmInstanceStorage -Root $fixture.Root -InstanceName 'reset-ok' -BaseId $fixture.BaseId -QemuImgRunner $fixture.Runner
    }
    finally { Remove-EzVmStorageFixture $fixture }
}

Add-EzVmTest -Name 'Storage: source contains no normal commit, rebase, unsafe create or base write shortcut' -ScriptBlock {
    $source = [IO.File]::ReadAllText((Join-Path $script:EzVmRepositoryRoot 'src/EzVm/Storage.ps1'))
    Assert-EzVmTrue -Condition ($source -notmatch "(?i)'commit'|\bqemu-img\s+commit\b") -Message 'Storage implementation must not commit mutable instance state into a base.'
    Assert-EzVmTrue -Condition ($source -notmatch "(?i)'rebase'|\bqemu-img\s+rebase\b") -Message 'Storage implementation must not automatically rebase broken chains.'
    Assert-EzVmTrue -Condition ($source -notmatch "(?i)'create'[^\r\n]*'-u'") -Message 'Storage implementation must not use unsafe backing creation.'
}
