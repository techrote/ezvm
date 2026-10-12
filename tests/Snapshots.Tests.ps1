function Set-EzVmSnapshotFixtureInteger {
    param([byte[]]$Bytes, [int]$Offset, [int]$Length, [long]$Value)
    for ($index = $Length - 1; $index -ge 0; $index--) {
        $Bytes[$Offset + $index] = [byte]($Value -band 255)
        $Value = $Value -shr 8
    }
}

function Write-EzVmSnapshotFixtureImage {
    param([string]$Path, [string]$Backing = '', [string]$Data = '', [long]$VirtualSize = 67108864)
    $header = New-Object byte[] 512
    $header[0] = 0x51; $header[1] = 0x46; $header[2] = 0x49; $header[3] = 0xfb
    Set-EzVmSnapshotFixtureInteger $header 4 4 3
    Set-EzVmSnapshotFixtureInteger $header 20 4 9
    Set-EzVmSnapshotFixtureInteger $header 24 8 $VirtualSize
    Set-EzVmSnapshotFixtureInteger $header 96 4 4
    Set-EzVmSnapshotFixtureInteger $header 100 4 104
    if ($Backing) {
        $backingBytes = [Text.Encoding]::UTF8.GetBytes($Backing)
        Set-EzVmSnapshotFixtureInteger $header 8 8 128
        Set-EzVmSnapshotFixtureInteger $header 16 4 $backingBytes.Length
        Set-EzVmSnapshotFixtureInteger $header 104 4 0xe2792acaL
        Set-EzVmSnapshotFixtureInteger $header 108 4 5
        [Array]::Copy([Text.Encoding]::ASCII.GetBytes('qcow2'), 0, $header, 112, 5)
        [Array]::Copy($backingBytes, 0, $header, 128, $backingBytes.Length)
    }
    $payload = [Text.Encoding]::UTF8.GetBytes(([pscustomobject]@{ data = $Data; backing = $Backing; size = $VirtualSize } | ConvertTo-Json -Compress))
    $image = New-Object byte[] (512 + $payload.Length)
    [Array]::Copy($header, 0, $image, 0, $header.Length)
    [Array]::Copy($payload, 0, $image, 512, $payload.Length)
    [IO.File]::WriteAllBytes($Path, $image)
}

function Get-EzVmSnapshotFixturePayload {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    return ([Text.Encoding]::UTF8.GetString($bytes, 512, $bytes.Length - 512) | ConvertFrom-Json -ErrorAction Stop)
}

function New-EzVmSnapshotFixture {
    param([switch]$WithoutInstance)
    $baseFixture = New-EzVmBaseBuildFixture
    $root = $baseFixture.Root
    $state = [pscustomobject]@{ Calls = New-Object 'System.Collections.Generic.List[object]'; Mode = 'normal' }
    $runnerState = $state
    $runner = {
        param($argumentList)
        $arguments = @($argumentList)
        $runnerState.Calls.Add([string[]]$arguments)
        $command = $arguments[0]
        $path = [IO.Path]::GetFullPath($arguments[-1])
        if ($command -ceq 'create') {
            $backing = $arguments[[Array]::IndexOf($arguments, '-b') + 1]
            Write-EzVmSnapshotFixtureImage -Path $path -Backing $backing
            return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
        }
        if ($command -ceq 'convert') {
            if ($runnerState.Mode -ceq 'fail-convert') {
                [IO.File]::WriteAllText($path, 'partial conversion')
                return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'fixture interrupted conversion' }
            }
            $source = [IO.Path]::GetFullPath($arguments[-2])
            $payload = Get-EzVmSnapshotFixturePayload -Path $source
            $visibleData = $payload.data
            if (-not $visibleData -and $payload.backing) {
                $back = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($source)) $payload.backing))
                $visibleData = (Get-EzVmSnapshotFixturePayload -Path $back).data
            }
            $size = if ($runnerState.Mode -ceq 'wrong-convert-size') { 33554432 } else { [long]$payload.size }
            $backing = if ($runnerState.Mode -ceq 'converted-backing') { '../outside.qcow2' } else { '' }
            Write-EzVmSnapshotFixtureImage -Path $path -Data $visibleData -VirtualSize $size -Backing $backing
            if ($runnerState.Mode -ceq 'source-changes') {
                [IO.File]::AppendAllText($source, 'changed-during-convert')
            }
            return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
        }
        if ($command -ceq 'check') {
            $report = if ($runnerState.Mode -ceq 'bad-check') { '{"format":"qcow2","check-errors":0,"corruptions":1}' }
                elseif ($runnerState.Mode -ceq 'bad-check-type') { '{"format":"qcow2","check-errors":"0"}' }
                else { '{"format":"qcow2","check-errors":0,"corruptions":0,"leaks":0}' }
            return [pscustomobject]@{ ExitCode = 0; StdOut = $report; StdErr = '' }
        }
        if ($command -ceq 'info') {
            if ($runnerState.Mode -ceq 'malformed-info') { return [pscustomobject]@{ ExitCode = 0; StdOut = 'not-json'; StdErr = '' } }
            $payload = Get-EzVmSnapshotFixturePayload -Path $path
            $info = [ordered]@{ filename = $path; format = 'qcow2'; 'virtual-size' = [long]$payload.size }
            if ($payload.backing) {
                $info['backing-filename'] = $payload.backing
                $info['backing-filename-format'] = 'qcow2'
            }
            elseif ($runnerState.Mode -ceq 'info-data-file') { $info['data-file'] = '/external/payload.raw' }
            if ($arguments -ccontains '--backing-chain') {
                $back = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($path)) $payload.backing))
                $chain = @([pscustomobject]$info, [pscustomobject]@{ filename = $back; format = 'qcow2'; 'virtual-size' = [long]$payload.size })
                return [pscustomobject]@{ ExitCode = 0; StdOut = ($chain | ConvertTo-Json -Compress); StdErr = '' }
            }
            return [pscustomobject]@{ ExitCode = 0; StdOut = ([pscustomobject]$info | ConvertTo-Json -Compress); StdErr = '' }
        }
        return [pscustomobject]@{ ExitCode = 90; StdOut = ''; StdErr = "Unexpected snapshot fixture operation $command" }
    }.GetNewClosure()
    $inputPath = Join-Path $root 'incoming standalone.qcow2'
    Write-EzVmSnapshotFixtureImage -Path $inputPath -Data 'baseline guest bytes'
    $safe = New-EzVmStorageLifecycleGuard -State proven-safe -Source 'snapshot fixture has no QEMU owner'
    $fixture = [pscustomobject]@{
        Root = $root; Paths = $baseFixture.Paths; BaseFixture = $baseFixture; InputPath = $inputPath
        Runner = $runner; QemuStatusProvider = $baseFixture.QemuStatusProvider; State = $state
        SafeGuard = $safe; Base = $null; Intent = $null; Disk = $null
    }
    if (-not $WithoutInstance) {
        $fixture.Base = Import-EzVmStandaloneBase -Root $root -ImagePath $inputPath -QemuImgRunner $runner -QemuStatusProvider $fixture.QemuStatusProvider
        $fixture.Intent = New-EzVmInstanceIntent -Root $root -InstanceName 'snapshot-source' -BaseId $fixture.Base.BaseId -QemuImgRunner $runner
        $overlay = New-EzVmInstanceOverlay -Root $root -InstanceName $fixture.Intent.name -BaseId $fixture.Base.BaseId -LifecycleGuard $safe -QemuImgRunner $runner
        $fixture.Disk = $overlay.Disk
        Write-EzVmSnapshotFixtureImage -Path $fixture.Disk -Backing $overlay.BackingReference -Data 'source workspace sentinel and synthetic auth state'
    }
    $state.Calls.Clear()
    return $fixture
}

function Remove-EzVmSnapshotFixture {
    param([object]$Fixture)
    if ($null -ne $Fixture) { Remove-EzVmBaseBuildFixture $Fixture.BaseFixture }
}

Add-EzVmTest -Name 'Snapshots: QCOW2 header accepts only bounded supported standalone or exact managed backing' -ScriptBlock {
    $fixture = New-EzVmSnapshotFixture -WithoutInstance
    try {
        $header = Test-EzVmQcow2Header -Path $fixture.InputPath
        Assert-EzVmEqual $header.VirtualSizeBytes 67108864
        Assert-EzVmEqual $header.BackingReference ''
        Assert-EzVmEqual $header.Version 3
        $v2 = [IO.File]::ReadAllBytes($fixture.InputPath)
        Set-EzVmSnapshotFixtureInteger $v2 4 4 2
        for ($index = 72; $index -lt 112; $index++) { $v2[$index] = 0 }
        [IO.File]::WriteAllBytes($fixture.InputPath, $v2)
        Assert-EzVmEqual (Test-EzVmQcow2Header -Path $fixture.InputPath).Version 2
        Write-EzVmSnapshotFixtureImage -Path $fixture.InputPath -Backing '../../bases/base-known/base.qcow2'
        Assert-EzVmThrows { Test-EzVmQcow2Header -Path $fixture.InputPath } -MessagePattern 'no backing file' | Out-Null
        Assert-EzVmThrows { Test-EzVmQcow2Header -Path $fixture.InputPath -ExpectedBacking '../../bases/wrong/base.qcow2' } -MessagePattern 'does not exactly match' | Out-Null
        Assert-EzVmEqual (Test-EzVmQcow2Header -Path $fixture.InputPath -ExpectedBacking '../../bases/base-known/base.qcow2').BackingReference '../../bases/base-known/base.qcow2'
        Assert-EzVmEqual $fixture.State.Calls.Count 0
    }
    finally { Remove-EzVmSnapshotFixture $fixture }
}

Add-EzVmTest -Name 'Snapshots: malformed or dependency-bearing imports refuse before any qemu-img call' -ScriptBlock {
    $fixture = New-EzVmSnapshotFixture -WithoutInstance
    try {
        $original = [IO.File]::ReadAllBytes($fixture.InputPath)
        $mutations = @(
            @{ offset = 0; length = 4; value = 0; pattern = 'magic' },
            @{ offset = 4; length = 4; value = 4; pattern = 'version' },
            @{ offset = 8; length = 8; value = 128; pattern = 'backing' },
            @{ offset = 16; length = 4; value = 5; pattern = 'backing' },
            @{ offset = 20; length = 4; value = 22; pattern = 'cluster' },
            @{ offset = 24; length = 8; value = 0; pattern = 'positive' },
            @{ offset = 32; length = 4; value = 2; pattern = 'Encrypted' },
            @{ offset = 60; length = 4; value = 1; pattern = 'snapshots' },
            @{ offset = 64; length = 8; value = 512; pattern = 'snapshots' },
            @{ offset = 72; length = 8; value = 1; pattern = 'incompatible' },
            @{ offset = 72; length = 8; value = 2; pattern = 'incompatible' },
            @{ offset = 72; length = 8; value = 4; pattern = 'external-data' },
            @{ offset = 72; length = 8; value = 32; pattern = 'incompatible' },
            @{ offset = 80; length = 8; value = 2; pattern = 'compatible' },
            @{ offset = 88; length = 8; value = 2; pattern = 'external-data' },
            @{ offset = 96; length = 4; value = 7; pattern = 'refcount' },
            @{ offset = 100; length = 4; value = 0xffffffffL; pattern = 'length|convert' },
            @{ offset = 104; length = 4; value = 0x44415441L; pattern = 'extension' },
            @{ offset = 104; length = 4; value = 0x0537be77L; pattern = 'extension' },
            @{ offset = 108; length = 4; value = 1; pattern = 'terminator' }
        )
        foreach ($mutation in $mutations) {
            $bytes = [byte[]]$original.Clone()
            Set-EzVmSnapshotFixtureInteger $bytes $mutation.offset $mutation.length $mutation.value
            [IO.File]::WriteAllBytes($fixture.InputPath, $bytes)
            $before = Get-EzVmFileDigest -Path $fixture.InputPath -Algorithm SHA256
            Assert-EzVmThrows {
                Import-EzVmStandaloneBase -Root $fixture.Root -ImagePath $fixture.InputPath -QemuImgRunner $fixture.Runner -QemuStatusProvider $fixture.QemuStatusProvider
            } -MessagePattern $mutation.pattern | Out-Null
            Assert-EzVmEqual $fixture.State.Calls.Count 0 -Message 'Untrusted header must fail before QEMU receives the source or any staging path.'
            Assert-EzVmEqual (Get-EzVmFileDigest -Path $fixture.InputPath -Algorithm SHA256) $before
        }
        [IO.File]::WriteAllBytes($fixture.InputPath, [byte[]]@(0x51, 0x46, 0x49, 0xfb))
        Assert-EzVmThrows { Import-EzVmStandaloneBase -Root $fixture.Root -ImagePath $fixture.InputPath -QemuImgRunner $fixture.Runner -QemuStatusProvider $fixture.QemuStatusProvider } -MessagePattern 'truncated' | Out-Null
        Assert-EzVmEqual $fixture.State.Calls.Count 0
    }
    finally { Remove-EzVmSnapshotFixture $fixture }
}

Add-EzVmTest -Name 'Snapshots: extension bounds duplicates missing terminators and oversized uint64 fail closed' -ScriptBlock {
    $fixture = New-EzVmSnapshotFixture -WithoutInstance
    try {
        $original = [IO.File]::ReadAllBytes($fixture.InputPath)
        $bytes = [byte[]]$original.Clone()
        Set-EzVmSnapshotFixtureInteger $bytes 104 4 0x6803f857L
        Set-EzVmSnapshotFixtureInteger $bytes 108 4 0xffffffffL
        [IO.File]::WriteAllBytes($fixture.InputPath, $bytes)
        Assert-EzVmThrows { Test-EzVmQcow2Header -Path $fixture.InputPath } -MessagePattern 'exceeds' | Out-Null
        $bytes = [byte[]]$original.Clone()
        foreach ($offset in @(104, 160)) {
            Set-EzVmSnapshotFixtureInteger $bytes $offset 4 0x6803f857L
            Set-EzVmSnapshotFixtureInteger $bytes ($offset + 4) 4 48
        }
        [IO.File]::WriteAllBytes($fixture.InputPath, $bytes)
        Assert-EzVmThrows { Test-EzVmQcow2Header -Path $fixture.InputPath } -MessagePattern 'duplicate' | Out-Null
        $bytes = [byte[]]$original.Clone()
        $bytes[24] = 128
        [IO.File]::WriteAllBytes($fixture.InputPath, $bytes)
        Assert-EzVmThrows { Test-EzVmQcow2Header -Path $fixture.InputPath } -MessagePattern 'integer range' | Out-Null
        $bytes = [byte[]]$original.Clone()
        Set-EzVmSnapshotFixtureInteger $bytes 100 4 112
        $bytes[104] = 1
        [IO.File]::WriteAllBytes($fixture.InputPath, $bytes)
        Assert-EzVmThrows { Test-EzVmQcow2Header -Path $fixture.InputPath } -MessagePattern 'optional header' | Out-Null
        Write-EzVmSnapshotFixtureImage -Path $fixture.InputPath -Backing '../known.qcow2'
        $bytes = [IO.File]::ReadAllBytes($fixture.InputPath)
        Set-EzVmSnapshotFixtureInteger $bytes 8 8 120
        [Array]::Copy([Text.Encoding]::UTF8.GetBytes('../known.qcow2'), 0, $bytes, 120, 14)
        [IO.File]::WriteAllBytes($fixture.InputPath, $bytes)
        Assert-EzVmThrows { Test-EzVmQcow2Header -Path $fixture.InputPath -ExpectedBacking '../known.qcow2' } -MessagePattern 'terminator' | Out-Null
    }
    finally { Remove-EzVmSnapshotFixture $fixture }
}

Add-EzVmTest -Name 'Snapshots: imported symlink ancestors and oversized sidecars refuse before tool invocation' -ScriptBlock {
    $fixture = New-EzVmSnapshotFixture -WithoutInstance
    $link = $null
    try {
        $target = Join-Path $fixture.Root 'actual imports'
        [void][IO.Directory]::CreateDirectory($target)
        Copy-Item -LiteralPath $fixture.InputPath -Destination (Join-Path $target 'disk.qcow2')
        $link = Join-Path $fixture.Root 'redirected imports'
        $itemType = if ($script:EzVmIsWindowsHost) { 'Junction' } else { 'SymbolicLink' }
        $null = New-Item -ItemType $itemType -Path $link -Target $target -ErrorAction Stop
        Assert-EzVmThrows {
            Import-EzVmStandaloneBase -Root $fixture.Root -ImagePath (Join-Path $link 'disk.qcow2') -QemuImgRunner $fixture.Runner -QemuStatusProvider $fixture.QemuStatusProvider
        } -MessagePattern 'reparse point' | Out-Null
        $sidecar = Join-Path $fixture.Root 'oversized-manifest.json'
        [IO.File]::WriteAllText($sidecar, ('x' * 65537))
        Assert-EzVmThrows {
            Import-EzVmStandaloneBase -Root $fixture.Root -ImagePath $fixture.InputPath -ManifestPath $sidecar -QemuImgRunner $fixture.Runner -QemuStatusProvider $fixture.QemuStatusProvider
        } -MessagePattern '64 KiB' | Out-Null
        Assert-EzVmEqual $fixture.State.Calls.Count 0
    }
    finally {
        if ($null -ne $link -and (Test-Path -LiteralPath $link)) { [IO.Directory]::Delete($link) }
        Remove-EzVmSnapshotFixture $fixture
    }
}

Add-EzVmTest -Name 'Snapshots: import normalizes only a staged copy and publishes immutable sensitive provenance' -ScriptBlock {
    $fixture = New-EzVmSnapshotFixture -WithoutInstance
    try {
        $before = Get-EzVmFileDigest -Path $fixture.InputPath -Algorithm SHA256
        $result = Import-EzVmStandaloneBase -Root $fixture.Root -ImagePath $fixture.InputPath -QemuImgRunner $fixture.Runner -QemuStatusProvider $fixture.QemuStatusProvider
        Assert-EzVmEqual (Get-EzVmFileDigest -Path $fixture.InputPath -Algorithm SHA256) $before
        Assert-EzVmEqual $result.Manifest.schemaVersion 2
        Assert-EzVmEqual $result.Manifest.kind 'imported'
        Assert-EzVmEqual $result.Manifest.source.filename 'incoming standalone.qcow2'
        Assert-EzVmEqual $result.Manifest.source.imageSha256 $before
        Assert-EzVmEqual $result.BaseId ('base-' + $result.Manifest.baseSha256)
        Assert-EzVmEqual $result.OperationProvenance $result.Manifest
        Assert-EzVmTrue $result.Manifest.sensitiveState
        Assert-EzVmTrue $result.Manifest.guestIdentityResetRequired
        Assert-EzVmTrue $result.ReadOnly
        Assert-EzVmTrue (((Get-Item -LiteralPath $result.ManifestPath -Force).Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0)
        Assert-EzVmEqual (Test-EzVmPreparedBase -Root $fixture.Root -BaseId $result.BaseId -QemuImgRunner $fixture.Runner).Manifest.baseSha256 (Get-EzVmFileDigest -Path $result.Image -Algorithm SHA256)
        foreach ($call in $fixture.State.Calls) {
            Assert-EzVmTrue ($call -cnotcontains $fixture.InputPath) -Message 'qemu-img must never open the untrusted caller-owned source path.'
            Assert-EzVmTrue ($call -cnotcontains 'rebase' -and $call -cnotcontains 'commit' -and $call -cnotcontains '-r')
        }
        Assert-EzVmEqual @(Get-ChildItem -LiteralPath $fixture.Paths.Bases -Directory -Filter '.snapshot-*' -Force).Count 0
        $manifestText = [IO.File]::ReadAllText($result.ManifestPath)
        Assert-EzVmTrue (-not $manifestText.Contains($fixture.Root)) -Message 'Durable provenance must not retain the source root.'
    }
    finally { Remove-EzVmSnapshotFixture $fixture }
}

Add-EzVmTest -Name 'Snapshots: import refuses managed source paths and an already-open source file' -ScriptBlock {
    $fixture = New-EzVmSnapshotFixture
    $stream = $null
    try {
        Assert-EzVmThrows { Import-EzVmStandaloneBase -Root $fixture.Root -ImagePath $fixture.Base.Image -QemuImgRunner $fixture.Runner -QemuStatusProvider $fixture.QemuStatusProvider } -MessagePattern 'inside managed runtime' | Out-Null
        $stream = New-Object IO.FileStream($fixture.InputPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        Assert-EzVmThrows { Import-EzVmStandaloneBase -Root $fixture.Root -ImagePath $fixture.InputPath -QemuImgRunner $fixture.Runner -QemuStatusProvider $fixture.QemuStatusProvider } -MessagePattern 'another process|being used|IOException|permission|access' | Out-Null
        Assert-EzVmEqual $fixture.State.Calls.Count 0
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        Remove-EzVmSnapshotFixture $fixture
    }
}

Add-EzVmTest -Name 'Snapshots: omitted empty and whitespace optional manifest paths have identical import semantics' -ScriptBlock {
    $fixture = New-EzVmSnapshotFixture -WithoutInstance
    try {
        $first = Import-EzVmStandaloneBase -Root $fixture.Root -ImagePath $fixture.InputPath -QemuImgRunner $fixture.Runner -QemuStatusProvider $fixture.QemuStatusProvider
        foreach ($manifestPath in @('', '   ')) {
            $next = Import-EzVmStandaloneBase -Root $fixture.Root -ImagePath $fixture.InputPath -ManifestPath $manifestPath -QemuImgRunner $fixture.Runner -QemuStatusProvider $fixture.QemuStatusProvider
            Assert-EzVmEqual $next.BaseId $first.BaseId
            Assert-EzVmTrue $next.Reused
            Assert-EzVmEqual $next.OperationProvenance.source.exportManifest $null
            Assert-EzVmEqual $next.OperationProvenance.source.exportManifestSha256 ''
        }
        Assert-EzVmThrows {
            Import-EzVmStandaloneBase -Root $fixture.Root -ImagePath $fixture.InputPath -ManifestPath (Join-Path $fixture.Root 'missing-manifest.json') -QemuImgRunner $fixture.Runner -QemuStatusProvider $fixture.QemuStatusProvider
        } -MessagePattern 'missing' | Out-Null
    }
    finally { Remove-EzVmSnapshotFixture $fixture }
}

Add-EzVmTest -Name 'Snapshots: derived state is standalone independent and carries source identity provenance' -ScriptBlock {
    $fixture = New-EzVmSnapshotFixture
    try {
        $before = Get-EzVmFileDigest -Path $fixture.Disk -Algorithm SHA256
        $result = New-EzVmDerivedBase -Root $fixture.Root -SourceIntent $fixture.Intent -LifecycleGuard $fixture.SafeGuard -QemuImgRunner $fixture.Runner -QemuStatusProvider $fixture.QemuStatusProvider
        Assert-EzVmEqual $result.Manifest.kind 'derived'
        Assert-EzVmEqual $result.Manifest.source.instance.name $fixture.Intent.name
        Assert-EzVmEqual $result.Manifest.source.instance.baseId $fixture.Intent.baseId
        Assert-EzVmEqual $result.Manifest.source.overlaySha256 $before
        Assert-EzVmEqual (Test-EzVmQcow2Header -Path $result.Image).BackingReference ''
        Assert-EzVmEqual (Get-EzVmSnapshotFixturePayload -Path $result.Image).data 'source workspace sentinel and synthetic auth state'
        $sourcePayload = Get-EzVmSnapshotFixturePayload -Path $fixture.Disk
        Write-EzVmSnapshotFixtureImage -Path $fixture.Disk -Backing $sourcePayload.backing -Data 'later source mutation'
        Assert-EzVmEqual (Get-EzVmSnapshotFixturePayload -Path $result.Image).data 'source workspace sentinel and synthetic auth state'
        $clone = New-EzVmInstanceOverlay -Root $fixture.Root -InstanceName 'independent-clone' -BaseId $result.BaseId -LifecycleGuard $fixture.SafeGuard -QemuImgRunner $fixture.Runner
        $chain = Test-EzVmInstanceStorage -Root $fixture.Root -InstanceName 'independent-clone' -BaseId $result.BaseId -QemuImgRunner $fixture.Runner
        Assert-EzVmEqual $chain.ChainDepth 1
        Assert-EzVmEqual $chain.BasePath $result.Image
        Assert-EzVmTrue ($chain.BasePath -cne $fixture.Disk)
        Assert-EzVmEqual (Test-EzVmQcow2Header -Path $clone.Disk -ExpectedBacking $clone.BackingReference).BackingReference $clone.BackingReference
    }
    finally { Remove-EzVmSnapshotFixture $fixture }
}

Add-EzVmTest -Name 'Snapshots: stopped export is atomic backing-independent and exactly digested' -ScriptBlock {
    $fixture = New-EzVmSnapshotFixture
    try {
        $destination = Join-Path $fixture.Root 'export with spaces'
        $before = Get-EzVmFileDigest -Path $fixture.Disk -Algorithm SHA256
        $result = Export-EzVmInstanceStorage -Root $fixture.Root -SourceIntent $fixture.Intent -LifecycleGuard $fixture.SafeGuard -DestinationDirectory $destination -QemuImgRunner $fixture.Runner -QemuStatusProvider $fixture.QemuStatusProvider
        Assert-EzVmEqual $result.Directory $destination
        Assert-EzVmEqual $result.Manifest.imageSha256 (Get-EzVmFileDigest -Path $result.Image -Algorithm SHA256)
        Assert-EzVmEqual $result.Manifest.virtualSizeBytes 67108864
        Assert-EzVmEqual $result.Manifest.source.instance.name $fixture.Intent.name
        Assert-EzVmEqual (Test-EzVmQcow2Header -Path $result.Image).BackingReference ''
        Assert-EzVmEqual (Get-EzVmFileDigest -Path $fixture.Disk -Algorithm SHA256) $before
        Assert-EzVmTrue $result.SensitiveState
        Assert-EzVmTrue ($result.Warning -match 'credentials')
        Assert-EzVmEqual @(Get-ChildItem -LiteralPath $destination -Force).Count 2
        Assert-EzVmThrows {
            Export-EzVmInstanceStorage -Root $fixture.Root -SourceIntent $fixture.Intent -LifecycleGuard $fixture.SafeGuard -DestinationDirectory $destination -QemuImgRunner $fixture.Runner -QemuStatusProvider $fixture.QemuStatusProvider
        } -MessagePattern 'already exists' | Out-Null
        Assert-EzVmEqual (Get-EzVmFileDigest -Path $result.Image -Algorithm SHA256) $result.Manifest.imageSha256
    }
    finally { Remove-EzVmSnapshotFixture $fixture }
}

Add-EzVmTest -Name 'Snapshots: explicit lifecycle guards reject running transitional absent and malformed evidence before tools' -ScriptBlock {
    $fixture = New-EzVmSnapshotFixture
    try {
        $guards = @($null)
        foreach ($state in @('running', 'starting', 'stopping', 'unknown')) { $guards += New-EzVmStorageLifecycleGuard -State $state -Source 'negative guard' }
        $guards += [pscustomobject]@{ schemaVersion = 9; state = 'proven-safe'; source = 'invalid schema' }
        foreach ($guard in $guards) {
            Assert-EzVmThrows {
                New-EzVmDerivedBase -Root $fixture.Root -SourceIntent $fixture.Intent -LifecycleGuard $guard -QemuImgRunner $fixture.Runner -QemuStatusProvider $fixture.QemuStatusProvider
            } -MessagePattern 'lifecycle|proven' | Out-Null
            Assert-EzVmThrows {
                Export-EzVmInstanceStorage -Root $fixture.Root -SourceIntent $fixture.Intent -LifecycleGuard $guard -DestinationDirectory (Join-Path $fixture.Root 'refused export') -QemuImgRunner $fixture.Runner -QemuStatusProvider $fixture.QemuStatusProvider
            } -MessagePattern 'lifecycle|proven' | Out-Null
        }
        Assert-EzVmEqual $fixture.State.Calls.Count 0
        Assert-EzVmEqual @(Get-ChildItem -LiteralPath $fixture.Paths.Bases -Directory -Filter '.snapshot-*' -Force).Count 0
    }
    finally { Remove-EzVmSnapshotFixture $fixture }
}

Add-EzVmTest -Name 'Snapshots: managed source header mismatch refuses traversal before qemu-img info' -ScriptBlock {
    $fixture = New-EzVmSnapshotFixture
    try {
        Write-EzVmSnapshotFixtureImage -Path $fixture.Disk -Backing '../../../../outside.qcow2' -Data 'unsafe source header'
        Assert-EzVmThrows {
            New-EzVmDerivedBase -Root $fixture.Root -SourceIntent $fixture.Intent -LifecycleGuard $fixture.SafeGuard -QemuImgRunner $fixture.Runner -QemuStatusProvider $fixture.QemuStatusProvider
        } -MessagePattern 'does not exactly match' | Out-Null
        Assert-EzVmEqual $fixture.State.Calls.Count 0
    }
    finally { Remove-EzVmSnapshotFixture $fixture }
}

Add-EzVmTest -Name 'Snapshots: failed conversion and failed publication preserve source and recoverable candidate' -ScriptBlock {
    $fixture = New-EzVmSnapshotFixture
    try {
        $before = Get-EzVmFileDigest -Path $fixture.Disk -Algorithm SHA256
        $existingBases = @(Get-ChildItem -LiteralPath $fixture.Paths.Bases -Directory -Filter 'base-*').Count
        $fixture.State.Mode = 'fail-convert'
        Assert-EzVmThrows {
            New-EzVmDerivedBase -Root $fixture.Root -SourceIntent $fixture.Intent -LifecycleGuard $fixture.SafeGuard -QemuImgRunner $fixture.Runner -QemuStatusProvider $fixture.QemuStatusProvider
        } -MessagePattern 'recoverable staging' | Out-Null
        Assert-EzVmEqual (Get-EzVmFileDigest -Path $fixture.Disk -Algorithm SHA256) $before
        Assert-EzVmEqual @(Get-ChildItem -LiteralPath $fixture.Paths.Bases -Directory -Filter 'base-*').Count $existingBases
        $stage = @(Get-ChildItem -LiteralPath $fixture.Paths.Bases -Directory -Filter '.snapshot-*' -Force)[0].FullName
        Assert-EzVmTrue (Test-Path -LiteralPath (Join-Path $stage 'failure.json'))
        Assert-EzVmTrue (Test-Path -LiteralPath (Join-Path $stage 'standalone.qcow2'))
        $fixture.State.Mode = 'normal'
        $refuseMove = { param($source, $destination) throw [InvalidOperationException]::new('fixture publication refusal') }
        Assert-EzVmThrows {
            Export-EzVmInstanceStorage -Root $fixture.Root -SourceIntent $fixture.Intent -LifecycleGuard $fixture.SafeGuard -DestinationDirectory (Join-Path $fixture.Root 'failed export') -QemuImgRunner $fixture.Runner -QemuStatusProvider $fixture.QemuStatusProvider -DirectoryMover $refuseMove
        } -MessagePattern 'recoverable staging' | Out-Null
        Assert-EzVmTrue (-not (Test-Path -LiteralPath (Join-Path $fixture.Root 'failed export')))
        $exportStage = @(Get-ChildItem -LiteralPath $fixture.Root -Directory -Filter '.ezvm-export-*' -Force)[0].FullName
        Assert-EzVmTrue (Test-Path -LiteralPath (Join-Path $exportStage 'disk.qcow2'))
        Assert-EzVmTrue (Test-Path -LiteralPath (Join-Path $exportStage 'manifest.json'))
        Assert-EzVmTrue (Test-Path -LiteralPath (Join-Path $exportStage 'failure.json'))
        Assert-EzVmEqual (Get-EzVmFileDigest -Path $fixture.Disk -Algorithm SHA256) $before
    }
    finally { Remove-EzVmSnapshotFixture $fixture }
}

Add-EzVmTest -Name 'Snapshots: conversion output size backing and integrity claims are independently checked' -ScriptBlock {
    $fixture = New-EzVmSnapshotFixture -WithoutInstance
    try {
        $before = Get-EzVmFileDigest -Path $fixture.InputPath -Algorithm SHA256
        foreach ($mode in @('wrong-convert-size', 'converted-backing', 'bad-check', 'bad-check-type', 'malformed-info', 'info-data-file')) {
            $fixture.State.Mode = $mode
            Assert-EzVmThrows {
                Import-EzVmStandaloneBase -Root $fixture.Root -ImagePath $fixture.InputPath -QemuImgRunner $fixture.Runner -QemuStatusProvider $fixture.QemuStatusProvider
            } -MessagePattern 'Import failed' | Out-Null
            Assert-EzVmEqual @(Get-ChildItem -LiteralPath $fixture.Paths.Bases -Directory -Filter 'base-*').Count 0
            Assert-EzVmEqual (Get-EzVmFileDigest -Path $fixture.InputPath -Algorithm SHA256) $before
        }
    }
    finally { Remove-EzVmSnapshotFixture $fixture }
}

Add-EzVmTest -Name 'Snapshots: export sidecar must match exact bytes size and strict sensitive provenance' -ScriptBlock {
    $fixture = New-EzVmSnapshotFixture
    try {
        $export = Export-EzVmInstanceStorage -Root $fixture.Root -SourceIntent $fixture.Intent -LifecycleGuard $fixture.SafeGuard -DestinationDirectory (Join-Path $fixture.Root 'round trip export') -QemuImgRunner $fixture.Runner -QemuStatusProvider $fixture.QemuStatusProvider
        $import = Import-EzVmStandaloneBase -Root $fixture.Root -ImagePath $export.Image -ManifestPath $export.ManifestPath -QemuImgRunner $fixture.Runner -QemuStatusProvider $fixture.QemuStatusProvider
        Assert-EzVmEqual $import.Manifest.kind 'imported'
        Assert-EzVmEqual $import.OperationProvenance.source.exportManifest.source.instance.name $fixture.Intent.name
        Assert-EzVmEqual $import.OperationProvenance.source.exportManifestSha256 (Get-EzVmFileDigest -Path $export.ManifestPath -Algorithm SHA256)
        $export.Manifest.imageSha256 = 'a' * 64
        Write-EzVmJson -Path $export.ManifestPath -Value $export.Manifest
        $fixture.State.Calls.Clear()
        Assert-EzVmThrows {
            Import-EzVmStandaloneBase -Root $fixture.Root -ImagePath $export.Image -ManifestPath $export.ManifestPath -QemuImgRunner $fixture.Runner -QemuStatusProvider $fixture.QemuStatusProvider
        } -MessagePattern 'do not match' | Out-Null
        Assert-EzVmEqual $fixture.State.Calls.Count 0
        $export.Manifest.sensitiveState = $false
        Write-EzVmJson -Path $export.ManifestPath -Value $export.Manifest
        Assert-EzVmThrows {
            Import-EzVmStandaloneBase -Root $fixture.Root -ImagePath $export.Image -ManifestPath $export.ManifestPath -QemuImgRunner $fixture.Runner -QemuStatusProvider $fixture.QemuStatusProvider
        } -MessagePattern 'sensitiveState must be true' | Out-Null
    }
    finally { Remove-EzVmSnapshotFixture $fixture }
}

Add-EzVmTest -Name 'Snapshots: manifest schemas reject coercion unsafe kinds false cleanup claims and unknown fields' -ScriptBlock {
    $fixture = New-EzVmSnapshotFixture
    try {
        $json = $fixture.Base.OperationProvenance | ConvertTo-Json -Depth 32 -Compress
        $mutations = @(
            { param($m) $m.schemaVersion = '2' },
            { param($m) $m.virtualSizeBytes = '67108864' },
            { param($m) $m.virtualSizeBytes = $true },
            { param($m) $m.baseSha256 = @($m.baseSha256) },
            { param($m) $m.kind = 'prepared' },
            { param($m) $m.kind = @('imported') },
            { param($m) $m.sensitiveState = 'true' },
            { param($m) $m.guestIdentityResetRequired = $false },
            { param($m) $m.source.filename = 'C:\sensitive\disk.qcow2' },
            { param($m) $m.source.imageSha256 = @($m.source.imageSha256) },
            { param($m) $m.source.exportManifestSha256 = 'a' * 64 },
            { param($m) $m.qemu.qemuImgVersion = '' },
            { param($m) $m | Add-Member -NotePropertyName identityCleaned -NotePropertyValue $true }
        )
        foreach ($mutate in $mutations) {
            $manifest = & (Get-Module EzVm) { param($text) ConvertFrom-EzVmJsonText -Text $text -SchemaVersion 2 -Description 'snapshot fixture' } $json
            & $mutate $manifest
            Assert-EzVmThrows { Assert-EzVmSnapshotBaseManifest -Manifest $manifest } | Out-Null
        }
    }
    finally { Remove-EzVmSnapshotFixture $fixture }
}

Add-EzVmTest -Name 'Snapshots: byte-identical operations retain immutable base and return current provenance' -ScriptBlock {
    $fixture = New-EzVmSnapshotFixture
    try {
        $first = New-EzVmDerivedBase -Root $fixture.Root -SourceIntent $fixture.Intent -LifecycleGuard $fixture.SafeGuard -QemuImgRunner $fixture.Runner -QemuStatusProvider $fixture.QemuStatusProvider
        $manifestBefore = Get-EzVmFileDigest -Path $first.ManifestPath -Algorithm SHA256
        $second = New-EzVmDerivedBase -Root $fixture.Root -SourceIntent $fixture.Intent -LifecycleGuard $fixture.SafeGuard -QemuImgRunner $fixture.Runner -QemuStatusProvider $fixture.QemuStatusProvider
        Assert-EzVmTrue $second.Reused
        Assert-EzVmEqual $second.BaseId $first.BaseId
        Assert-EzVmEqual (Get-EzVmFileDigest -Path $first.ManifestPath -Algorithm SHA256) $manifestBefore
        Assert-EzVmEqual $second.OperationProvenance.source.instance.name $fixture.Intent.name
        $export = Export-EzVmInstanceStorage -Root $fixture.Root -SourceIntent $fixture.Intent -LifecycleGuard $fixture.SafeGuard -DestinationDirectory (Join-Path $fixture.Root 'deduplicated export') -QemuImgRunner $fixture.Runner -QemuStatusProvider $fixture.QemuStatusProvider
        $import = Import-EzVmStandaloneBase -Root $fixture.Root -ImagePath $export.Image -ManifestPath $export.ManifestPath -QemuImgRunner $fixture.Runner -QemuStatusProvider $fixture.QemuStatusProvider
        Assert-EzVmTrue $import.Reused
        Assert-EzVmEqual $import.Manifest.kind 'derived'
        Assert-EzVmEqual $import.OperationProvenance.kind 'imported'
        Assert-EzVmEqual $import.OperationProvenance.source.exportManifest.source.instance.name $fixture.Intent.name
        Assert-EzVmEqual (Get-EzVmFileDigest -Path $first.ManifestPath -Algorithm SHA256) $manifestBefore
    }
    finally { Remove-EzVmSnapshotFixture $fixture }
}

Add-EzVmTest -Name 'Snapshots: sensitive-base validation remains relocation-safe and detects manifest mutation' -ScriptBlock {
    $fixture = New-EzVmSnapshotFixture
    $destination = $null
    try {
        $destination = New-EzVmCheckoutFixture -Prefix 'snapshot relocated root B with spaces'
        Copy-Item -LiteralPath $fixture.Paths.Runtime -Destination $destination -Recurse -Force
        $accepted = Test-EzVmPreparedBase -Root $destination -BaseId $fixture.Base.BaseId -QemuImgRunner $fixture.Runner
        Assert-EzVmTrue ($accepted.Image.StartsWith($destination, [StringComparison]::Ordinal))
        Assert-EzVmEqual $accepted.Manifest.baseSha256 $fixture.Base.Manifest.baseSha256
        $chain = Test-EzVmInstanceStorage -Root $destination -InstanceName $fixture.Intent.name -BaseId $fixture.Intent.baseId -QemuImgRunner $fixture.Runner
        Assert-EzVmEqual $chain.ChainDepth 1
        [IO.File]::SetAttributes($accepted.ManifestPath, ((Get-Item -LiteralPath $accepted.ManifestPath -Force).Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)))
        Assert-EzVmThrows { Test-EzVmPreparedBase -Root $destination -BaseId $fixture.Base.BaseId -QemuImgRunner $fixture.Runner } -MessagePattern 'not marked read-only' | Out-Null
    }
    finally {
        if ($null -ne $destination) { Remove-EzVmTestDirectory -Path $destination }
        Remove-EzVmSnapshotFixture $fixture
    }
}
