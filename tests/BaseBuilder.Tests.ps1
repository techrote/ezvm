function New-EzVmBaseBuildFixture {
    $root = New-EzVmCheckoutFixture -Prefix 'prepared base build [fixture] with spaces'
    $paths = Get-EzVmPaths -Root $root

    [void][IO.Directory]::CreateDirectory($paths.Qemu)
    $share = Join-Path $paths.Qemu 'share'
    [void][IO.Directory]::CreateDirectory($share)
    [IO.File]::WriteAllText((Join-Path $paths.Qemu 'qemu-system-x86_64.exe'), 'fixture qemu')
    [IO.File]::WriteAllText((Join-Path $paths.Qemu 'qemu-img.exe'), 'fixture qemu-img')
    [IO.File]::WriteAllText((Join-Path $share 'edk2-x86_64-code.fd'), 'fixture firmware code')
    [IO.File]::WriteAllText((Join-Path $share 'edk2-i386-vars.fd'), 'fixture firmware vars')

    [void][IO.Directory]::CreateDirectory($paths.SourceImages)
    $sourcePath = Join-Path $paths.SourceImages 'ubuntu-24.04-server-cloudimg-amd64.img'
    [IO.File]::WriteAllText($sourcePath, 'synthetic verified Ubuntu qcow2 source')
    $sourceDigest = Get-EzVmFileDigest -Path $sourcePath -Algorithm SHA256

    $sourceManifest = Read-EzVmJson -Path $paths.UbuntuManifest
    $sourceManifest.sha256 = $sourceDigest
    Write-EzVmJson -Path $paths.UbuntuManifest -Value $sourceManifest

    $qemuStatusProvider = {
        param($fixtureRoot, $manifest)
        $fixturePaths = Get-EzVmPaths -Root $fixtureRoot
        [pscustomobject]@{
            Valid = $true
            Reason = 'synthetic QEMU fixture'
            QemuSystem = Join-Path $fixturePaths.Qemu 'qemu-system-x86_64.exe'
            QemuImg = Join-Path $fixturePaths.Qemu 'qemu-img.exe'
            QemuSystemVersion = 'QEMU emulator version 11.1.0 (fixture)'
            QemuImgVersion = 'qemu-img version 11.1.0 (fixture)'
        }
    }

    $sourceProvider = {
        param($fixtureRoot, $manifest)
        $fixturePaths = Get-EzVmPaths -Root $fixtureRoot
        $path = Join-Path $fixturePaths.SourceImages $manifest.filename
        [pscustomobject]@{
            path = $path
            sha256 = $manifest.sha256
            publication = $manifest.publication
            provenancePath = $path + '.provenance.json'
        }
    }

    $sourceForRunner = $sourcePath
    $qemuImgRunner = {
        param($argumentList)
        $arguments = @($argumentList)
        $command = $arguments[0]
        $stdout = ''
        if ($command -ceq 'create') {
            $destination = $arguments[$arguments.Count - 1]
            [IO.File]::WriteAllText($destination, 'synthetic staging overlay')
        }
        elseif ($command -ceq 'resize') {
        }
        elseif ($command -ceq 'convert') {
            $destination = $arguments[$arguments.Count - 1]
            [IO.File]::WriteAllText($destination, 'synthetic flattened standalone prepared base')
        }
        elseif ($command -ceq 'info') {
            $path = $arguments[$arguments.Count - 1]
            if ([IO.Path]::GetFileName($path) -ceq 'staging.qcow2') {
                $value = [pscustomobject][ordered]@{
                    format = 'qcow2'
                    'virtual-size' = [long]17179869184
                    'backing-filename' = [IO.Path]::GetFullPath($sourceForRunner)
                    'backing-filename-format' = 'qcow2'
                }
            }
            else {
                $value = [pscustomobject][ordered]@{
                    format = 'qcow2'
                    'virtual-size' = [long]17179869184
                }
            }
            $stdout = $value | ConvertTo-Json -Compress
        }
        elseif ($command -ceq 'check') {
            $stdout = '{"corruptions":0,"leaks":0,"check-errors":0}'
        }
        else {
            return [pscustomobject]@{ ExitCode = 91; StdOut = ''; StdErr = "unexpected qemu-img command: $command" }
        }
        return [pscustomobject]@{ ExitCode = 0; StdOut = $stdout; StdErr = '' }
    }.GetNewClosure()

    $guestRunner = {
        param($context)
        if ($context.SeedServer.Address -cne '127.0.0.1') { throw 'seed listener was not loopback' }
        if ($context.SeedUrl -cne 'http://10.0.2.100:8000/') { throw 'unexpected NoCloud seed URL' }
        if ($context.GuestForward -notmatch '-tcp:127\.0\.0\.1:[0-9]+$') { throw 'seed forwarding is not loopback-only' }
        if (($context.Arguments -join ' ') -notmatch 'ds=nocloud;s=http://10\.0\.2\.100:8000/') { throw 'SMBIOS NoCloud configuration missing' }
        [pscustomobject][ordered]@{
            OsId = 'ubuntu'
            OsVersion = '24.04'
            CloudInitVersion = 'cloud-init 24.1 fixture'
            ToolsValidated = $true
            IdentityCleaned = $true
        }
    }

    return [pscustomobject]@{
        Root = $root
        Paths = $paths
        SourcePath = $sourcePath
        SourceDigest = $sourceDigest
        QemuStatusProvider = $qemuStatusProvider
        SourceProvider = $sourceProvider
        QemuImgRunner = $qemuImgRunner
        GuestRunner = $guestRunner
    }
}

function Remove-EzVmBaseBuildFixture {
    param([object]$Fixture)
    if ($null -ne $Fixture) { Remove-EzVmTestDirectory -Path $Fixture.Root }
}

Add-EzVmTest -Name 'Base builder: verified staging is flattened, content-addressed, read-only and standalone' -ScriptBlock {
    $fixture = New-EzVmBaseBuildFixture
    try {
        $sourceBefore = Get-EzVmFileDigest -Path $fixture.SourcePath -Algorithm SHA256
        $result = Invoke-EzVmBaseBuild -Root $fixture.Root -Accelerator tcg -BuildTimeoutSeconds 60 -QemuStatusProvider $fixture.QemuStatusProvider -SourceProvider $fixture.SourceProvider -QemuImgRunner $fixture.QemuImgRunner -GuestRunner $fixture.GuestRunner
        Assert-EzVmTrue -Condition ($result.baseId -match '^base-[a-f0-9]{64}$')
        Assert-EzVmEqual -Actual $result.baseId -Expected ('base-' + $result.sha256)
        Assert-EzVmEqual -Actual $result.accelerator -Expected 'tcg'
        Assert-EzVmTrue -Condition (-not $result.reused)
        Assert-EzVmTrue -Condition (Test-Path -LiteralPath $result.path -PathType Leaf)
        Assert-EzVmTrue -Condition (Test-Path -LiteralPath $result.manifestPath -PathType Leaf)
        Assert-EzVmEqual -Actual (Get-EzVmFileDigest -Path $fixture.SourcePath -Algorithm SHA256) -Expected $sourceBefore -Message 'Base build must never mutate the verified source image.'

        $accepted = Test-EzVmPreparedBase -Root $fixture.Root -BaseId $result.baseId -QemuImgRunner $fixture.QemuImgRunner
        Assert-EzVmTrue -Condition $accepted.ReadOnly
        Assert-EzVmEqual -Actual $accepted.Manifest.source.imageSha256 -Expected $fixture.SourceDigest
        Assert-EzVmEqual -Actual $accepted.Manifest.guest.osId -Expected 'ubuntu'
        Assert-EzVmEqual -Actual $accepted.Manifest.guest.osVersion -Expected '24.04'
        Assert-EzVmEqual -Actual $accepted.Manifest.build.accelerator -Expected 'tcg'
        Assert-EzVmTrue -Condition ($accepted.Manifest.provisioning.digest -match '^[a-f0-9]{64}$')
        Assert-EzVmEqual -Actual @(Get-ChildItem -LiteralPath $fixture.Paths.Bases -Directory -Filter '.build-*' -Force).Count -Expected 0
        Assert-EzVmEqual -Actual @(Get-ChildItem -LiteralPath $fixture.Paths.Bases -Directory -Filter '.publish-*' -Force).Count -Expected 0
    }
    finally { Remove-EzVmBaseBuildFixture $fixture }
}

Add-EzVmTest -Name 'Base builder: identical final content reuses the content-addressed base without replacement' -ScriptBlock {
    $fixture = New-EzVmBaseBuildFixture
    try {
        $first = Invoke-EzVmBaseBuild -Root $fixture.Root -Accelerator tcg -BuildTimeoutSeconds 60 -QemuStatusProvider $fixture.QemuStatusProvider -SourceProvider $fixture.SourceProvider -QemuImgRunner $fixture.QemuImgRunner -GuestRunner $fixture.GuestRunner
        $firstManifest = [IO.File]::ReadAllText($first.manifestPath)
        $second = Invoke-EzVmBaseBuild -Root $fixture.Root -Accelerator tcg -BuildTimeoutSeconds 60 -QemuStatusProvider $fixture.QemuStatusProvider -SourceProvider $fixture.SourceProvider -QemuImgRunner $fixture.QemuImgRunner -GuestRunner $fixture.GuestRunner
        Assert-EzVmTrue -Condition $second.reused
        Assert-EzVmEqual -Actual $second.baseId -Expected $first.baseId
        Assert-EzVmEqual -Actual ([IO.File]::ReadAllText($first.manifestPath)) -Expected $firstManifest -Message 'Existing immutable base manifest must not be replaced.'
    }
    finally { Remove-EzVmBaseBuildFixture $fixture }
}

Add-EzVmTest -Name 'Base builder: guest provisioning failure never creates an authoritative base' -ScriptBlock {
    $fixture = New-EzVmBaseBuildFixture
    try {
        $failedGuest = { param($context) throw 'synthetic cloud-init failure' }
        Assert-EzVmThrows -ScriptBlock {
            Invoke-EzVmBaseBuild -Root $fixture.Root -Accelerator tcg -BuildTimeoutSeconds 60 -QemuStatusProvider $fixture.QemuStatusProvider -SourceProvider $fixture.SourceProvider -QemuImgRunner $fixture.QemuImgRunner -GuestRunner $failedGuest
        } -MessagePattern 'No authoritative base was promoted.*synthetic cloud-init failure' | Out-Null
        Assert-EzVmEqual -Actual @(Get-ChildItem -LiteralPath $fixture.Paths.Bases -Directory -Filter 'base-*' -Force).Count -Expected 0
        $failed = @(Get-ChildItem -LiteralPath $fixture.Paths.Bases -Directory -Filter '.build-*' -Force)
        Assert-EzVmEqual -Actual $failed.Count -Expected 1
        Assert-EzVmTrue -Condition (Test-Path -LiteralPath (Join-Path $failed[0].FullName 'failure.json') -PathType Leaf)
        Assert-EzVmTrue -Condition (Test-Path -LiteralPath (Join-Path $failed[0].FullName 'staging.qcow2') -PathType Leaf)
        Assert-EzVmEqual -Actual @(Get-ChildItem -LiteralPath $fixture.Paths.Bases -Directory -Filter '.publish-*' -Force).Count -Expected 0
    }
    finally { Remove-EzVmBaseBuildFixture $fixture }
}

Add-EzVmTest -Name 'Base builder: flatten or integrity failure never becomes authoritative' -ScriptBlock {
    $fixture = New-EzVmBaseBuildFixture
    try {
        $normalRunner = $fixture.QemuImgRunner
        $brokenRunner = {
            param($argumentList)
            $arguments = @($argumentList)
            if ($arguments[0] -ceq 'convert') {
                return [pscustomobject]@{ ExitCode = 82; StdOut = ''; StdErr = 'synthetic flatten failure' }
            }
            & $normalRunner $arguments
        }.GetNewClosure()

        Assert-EzVmThrows -ScriptBlock {
            Invoke-EzVmBaseBuild -Root $fixture.Root -Accelerator tcg -BuildTimeoutSeconds 60 -QemuStatusProvider $fixture.QemuStatusProvider -SourceProvider $fixture.SourceProvider -QemuImgRunner $brokenRunner -GuestRunner $fixture.GuestRunner
        } -MessagePattern 'No authoritative base was promoted.*flatten failure' | Out-Null
        Assert-EzVmEqual -Actual @(Get-ChildItem -LiteralPath $fixture.Paths.Bases -Directory -Filter 'base-*' -Force).Count -Expected 0
    }
    finally { Remove-EzVmBaseBuildFixture $fixture }
}

Add-EzVmTest -Name 'Base builder: rejects unverified QEMU and source content before guest launch' -ScriptBlock {
    $fixture = New-EzVmBaseBuildFixture
    try {
        $badQemu = { [pscustomobject]@{ Valid = $false; Reason = 'fixture provenance mismatch' } }
        $script:EzVmGuestRan = $false
        $guest = { $script:EzVmGuestRan = $true; throw 'must not launch' }
        Assert-EzVmThrows -ScriptBlock {
            Invoke-EzVmBaseBuild -Root $fixture.Root -Accelerator tcg -BuildTimeoutSeconds 60 -QemuStatusProvider $badQemu -SourceProvider $fixture.SourceProvider -QemuImgRunner $fixture.QemuImgRunner -GuestRunner $guest
        } -MessagePattern 'validated managed QEMU.*provenance mismatch' | Out-Null
        Assert-EzVmTrue -Condition (-not $script:EzVmGuestRan)

        $badQemu = $fixture.QemuStatusProvider
        [IO.File]::AppendAllText($fixture.SourcePath, 'tamper')
        Assert-EzVmThrows -ScriptBlock {
            Invoke-EzVmBaseBuild -Root $fixture.Root -Accelerator tcg -BuildTimeoutSeconds 60 -QemuStatusProvider $badQemu -SourceProvider $fixture.SourceProvider -QemuImgRunner $fixture.QemuImgRunner -GuestRunner $guest
        } -MessagePattern 'no longer matches the reviewed manifest' | Out-Null
        Assert-EzVmTrue -Condition (-not $script:EzVmGuestRan)
    }
    finally { Remove-EzVmBaseBuildFixture $fixture }
}

Add-EzVmTest -Name 'Base builder: standalone validation rejects an unexpected backing chain' -ScriptBlock {
    $fixture = New-EzVmBaseBuildFixture
    try {
        $result = Invoke-EzVmBaseBuild -Root $fixture.Root -Accelerator tcg -BuildTimeoutSeconds 60 -QemuStatusProvider $fixture.QemuStatusProvider -SourceProvider $fixture.SourceProvider -QemuImgRunner $fixture.QemuImgRunner -GuestRunner $fixture.GuestRunner
        $badInfo = {
            param($argumentList)
            $arguments = @($argumentList)
            if ($arguments[0] -ceq 'info') {
                $value = [pscustomobject][ordered]@{
                    format = 'qcow2'
                    'virtual-size' = [long]17179869184
                    'backing-filename' = '..\outside.qcow2'
                }
                return [pscustomobject]@{ ExitCode = 0; StdOut = ($value | ConvertTo-Json -Compress); StdErr = '' }
            }
            [pscustomobject]@{ ExitCode = 0; StdOut = '{}'; StdErr = '' }
        }
        Assert-EzVmThrows -ScriptBlock {
            Test-EzVmPreparedBase -Root $fixture.Root -BaseId $result.baseId -QemuImgRunner $badInfo
        } -MessagePattern 'standalone with no backing file' | Out-Null
    }
    finally { Remove-EzVmBaseBuildFixture $fixture }
}

Add-EzVmTest -Name 'Base builder: guest serial facts require READY, tool validation, cleanup and matching build identity' -ScriptBlock {
    $module = Get-Module EzVm
    $buildId = '0123456789abcdef0123456789abcdef'
    $encode = { param($text) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text)) }
    $markerLines = @(
        ('EZVM_BASE_BUILD_ID=' + $buildId)
        ('EZVM_BASE_OS_ID_B64=' + (& $encode 'ubuntu'))
        ('EZVM_BASE_OS_VERSION_B64=' + (& $encode '24.04'))
        ('EZVM_BASE_CLOUD_INIT_B64=' + (& $encode 'cloud-init 24.1'))
        'EZVM_BASE_TOOLS_OK=1'
        'EZVM_BASE_CLEAN_OK=1'
        'EZVM_BASE_READY=1'
    )
    $lines = [string]::Join([Environment]::NewLine, [string[]]$markerLines)
    $facts = & $module { param($text, $id) Get-EzVmBaseGuestFacts -SerialText $text -BuildId $id } $lines $buildId
    Assert-EzVmEqual -Actual $facts.OsId -Expected 'ubuntu'
    Assert-EzVmEqual -Actual $facts.CloudInitVersion -Expected 'cloud-init 24.1'

    Assert-EzVmThrows -ScriptBlock {
        & $module { param($text, $id) Get-EzVmBaseGuestFacts -SerialText $text -BuildId $id } $lines 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    } -MessagePattern 'different build identity' | Out-Null
}

Add-EzVmTest -Name 'Base builder: candidate validation fails before authoritative publication' -ScriptBlock {
    $fixture = New-EzVmBaseBuildFixture
    try {
        $normalRunner = $fixture.QemuImgRunner
        $candidateRejectRunner = {
            param($argumentList)
            $arguments = @($argumentList)
            if ($arguments[0] -ceq 'info' -and [IO.Path]::GetFileName($arguments[$arguments.Count - 1]) -ceq 'base.qcow2') {
                $value = [pscustomobject][ordered]@{
                    format = 'qcow2'
                    'virtual-size' = [long]17179869184
                    'backing-filename' = '..\unexpected-backing.qcow2'
                }
                return [pscustomobject]@{ ExitCode = 0; StdOut = ($value | ConvertTo-Json -Compress); StdErr = '' }
            }
            & $normalRunner $arguments
        }.GetNewClosure()

        Assert-EzVmThrows -ScriptBlock {
            Invoke-EzVmBaseBuild -Root $fixture.Root -Accelerator tcg -BuildTimeoutSeconds 60 -QemuStatusProvider $fixture.QemuStatusProvider -SourceProvider $fixture.SourceProvider -QemuImgRunner $candidateRejectRunner -GuestRunner $fixture.GuestRunner
        } -MessagePattern 'No authoritative base was promoted.*standalone with no backing file' | Out-Null

        Assert-EzVmEqual -Actual @(Get-ChildItem -LiteralPath $fixture.Paths.Bases -Directory -Filter 'base-*' -Force).Count -Expected 0
        Assert-EzVmEqual -Actual @(Get-ChildItem -LiteralPath $fixture.Paths.Bases -Directory -Filter '.publish-*' -Force).Count -Expected 0
        Assert-EzVmEqual -Actual @(Get-ChildItem -LiteralPath $fixture.Paths.Bases -Directory -Filter '.build-*' -Force).Count -Expected 1
    }
    finally { Remove-EzVmBaseBuildFixture $fixture }
}
