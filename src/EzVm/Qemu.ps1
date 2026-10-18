function Assert-EzVmQemuManifestFields {
    param([object]$Value, [string[]]$Expected, [string]$Description)
    if ($Value -isnot [pscustomobject]) { throw "$Description must be a JSON object." }
    $actual = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($name in $actual) {
        if ($Expected -cnotcontains $name) { throw "$Description contains unknown field '$name'." }
    }
    foreach ($name in $Expected) {
        if ($actual -cnotcontains $name) { throw "$Description is missing required field '$name'." }
    }
}

function Assert-EzVmQemuManifestString {
    param([AllowNull()][object]$Value, [string]$Description)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
        throw "$Description must be a non-empty string."
    }
}

function Assert-EzVmQemuManifestInteger {
    param([AllowNull()][object]$Value, [string]$Description)
    $integer = $Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or
        $Value -is [int64] -or $Value -is [uint16] -or $Value -is [uint32] -or $Value -is [uint64]
    if (-not $integer -or $Value -le 0) { throw "$Description must be a positive integer." }
}

function Assert-EzVmQemuArtifactDescriptor {
    param(
        [object]$Artifact,
        [string]$Description,
        [string]$RequiredAlgorithm,
        [string]$RequiredHost
    )
    Assert-EzVmQemuManifestFields -Value $Artifact -Expected @(
        'url', 'filename', 'digestAlgorithm', 'digest', 'sizeBytes'
    ) -Description $Description
    foreach ($name in @('url', 'filename', 'digestAlgorithm', 'digest')) {
        Assert-EzVmQemuManifestString -Value $Artifact.$name -Description "$Description field '$name'"
    }
    Assert-EzVmQemuManifestInteger -Value $Artifact.sizeBytes -Description "$Description field 'sizeBytes'"
    if ($Artifact.digestAlgorithm -cne $RequiredAlgorithm) {
        throw "$Description digestAlgorithm must be '$RequiredAlgorithm'."
    }
    Assert-EzVmArtifactDigest -Algorithm $RequiredAlgorithm -ExpectedDigest $Artifact.digest
    if ([IO.Path]::GetFileName($Artifact.filename) -cne $Artifact.filename) {
        throw "$Description filename must not contain path components."
    }
    $uri = $null
    if (-not [Uri]::TryCreate($Artifact.url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -cne 'https') {
        throw "$Description URL must be absolute HTTPS."
    }
    if ($RequiredHost -and $uri.Host -cne $RequiredHost) {
        throw "$Description URL must use reviewed provider host '$RequiredHost'."
    }
}

function Get-EzVmQemuManifest {
    [CmdletBinding()]
    param([string]$Root = $script:EzVmDefaultRoot, [string]$ManifestPath)

    $paths = Get-EzVmPaths -Root $Root
    if (-not $PSBoundParameters.ContainsKey('ManifestPath')) { $ManifestPath = $paths.QemuManifest }
    $manifest = Read-EzVmJson -Path $ManifestPath -SchemaVersion 1
    $rootFields = @('schemaVersion', 'provider', 'qemu', 'extractor')
    if ($null -ne $manifest.PSObject.Properties['whpxResetOverlay']) { $rootFields += 'whpxResetOverlay' }
    Assert-EzVmQemuManifestFields -Value $manifest -Expected $rootFields -Description 'QEMU manifest'
    Assert-EzVmQemuManifestString -Value $manifest.provider -Description "QEMU manifest field 'provider'"

    Assert-EzVmQemuManifestFields -Value $manifest.qemu -Expected @(
        'version', 'providerBuild', 'url', 'filename', 'digestAlgorithm',
        'digest', 'sizeBytes', 'expectedVersionPrefix'
    ) -Description 'QEMU artifact'
    foreach ($name in @('version', 'providerBuild', 'expectedVersionPrefix')) {
        Assert-EzVmQemuManifestString -Value $manifest.qemu.$name -Description "QEMU artifact field '$name'"
    }
    if ($manifest.qemu.providerBuild -cnotmatch '^[0-9]{8}$') {
        throw 'QEMU providerBuild must be an exact YYYYMMDD provider identity.'
    }
    $qemuDescriptor = [pscustomobject]@{
        url = $manifest.qemu.url
        filename = $manifest.qemu.filename
        digestAlgorithm = $manifest.qemu.digestAlgorithm
        digest = $manifest.qemu.digest
        sizeBytes = $manifest.qemu.sizeBytes
    }
    Assert-EzVmQemuArtifactDescriptor -Artifact $qemuDescriptor -Description 'QEMU artifact' -RequiredAlgorithm 'SHA512' -RequiredHost 'qemu.weilnetz.de'

    Assert-EzVmQemuManifestFields -Value $manifest.extractor -Expected @(
        'version', 'bootstrap', 'package'
    ) -Description '7-Zip extractor manifest'
    Assert-EzVmQemuManifestString -Value $manifest.extractor.version -Description "7-Zip extractor field 'version'"
    Assert-EzVmQemuArtifactDescriptor -Artifact $manifest.extractor.bootstrap -Description '7-Zip bootstrap extractor' -RequiredAlgorithm 'SHA256' -RequiredHost 'github.com'
    Assert-EzVmQemuArtifactDescriptor -Artifact $manifest.extractor.package -Description '7-Zip full package' -RequiredAlgorithm 'SHA256' -RequiredHost 'github.com'
    if ($null -ne $manifest.PSObject.Properties['whpxResetOverlay']) {
        Assert-EzVmQemuOverlayManifest -Overlay $manifest.whpxResetOverlay -Manifest $manifest
    }
    return $manifest
}

function Invoke-EzVmSevenZipBootstrap {
    param(
        [string]$BootstrapExtractor,
        [string]$PackagePath,
        [string]$Destination,
        [string]$ExpectedVersion
    )
    $null = Assert-EzVmSafePath -Path $Destination -Description 'Managed directory'
    [void][IO.Directory]::CreateDirectory($Destination)
    Invoke-EzVmProcess -FilePath $BootstrapExtractor -ArgumentList @(
        'x', $PackagePath, ('-o' + $Destination), '-y'
    ) -WorkingDirectory $Destination -TimeoutSeconds 120 -ThrowOnError | Out-Null

    $executables = @(Get-ChildItem -LiteralPath $Destination -Filter '7z.exe' -File -Recurse)
    $libraries = @(Get-ChildItem -LiteralPath $Destination -Filter '7z.dll' -File -Recurse)
    if ($executables.Count -ne 1 -or $libraries.Count -ne 1 -or
        $executables[0].DirectoryName -cne $libraries[0].DirectoryName) {
        throw 'Verified 7-Zip package did not produce exactly one colocated 7z.exe and 7z.dll. Refusing the unexpected extraction layout.'
    }
    $probe = Invoke-EzVmProcess -FilePath $executables[0].FullName -ArgumentList @('i') -WorkingDirectory $executables[0].DirectoryName -TimeoutSeconds 30 -ThrowOnError
    if ($probe.StdOut -notmatch ('(?m)^7-Zip\s+' + [regex]::Escape($ExpectedVersion) + '\s+\(x64\)')) {
        throw "Extracted 7-Zip did not report reviewed version '$ExpectedVersion' x64."
    }
    return [pscustomobject][ordered]@{
        SevenZipExe = $executables[0].FullName
        VersionOutput = ($probe.StdOut -split '\r?\n' | Where-Object { $_ -match '^7-Zip\s+' } | Select-Object -First 1)
    }
}

function Invoke-EzVmQemuExtraction {
    param([string]$SevenZipExe, [string]$InstallerPath, [string]$Destination)

    $null = Assert-EzVmSafePath -Path $Destination -Description 'Managed directory'

    [void][IO.Directory]::CreateDirectory($Destination)
    Invoke-EzVmProcess -FilePath $SevenZipExe -ArgumentList @(
        'x', $InstallerPath, ('-o' + $Destination), '-y'
    ) -WorkingDirectory $Destination -TimeoutSeconds 300 -ThrowOnError | Out-Null

    foreach ($required in @('qemu-system-x86_64.exe', 'qemu-img.exe', 'COPYING', 'COPYING.LIB')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Destination $required) -PathType Leaf)) {
            throw "Verified QEMU installer produced an unexpected layout: missing '$required' at the portable payload root."
        }
    }
    foreach ($requiredDirectory in @('share', 'lib')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Destination $requiredDirectory) -PathType Container)) {
            throw "Verified QEMU installer produced an unexpected layout: missing '$requiredDirectory' directory."
        }
    }

    # NSIS-only scaffolding is not part of the managed portable runtime.
    $pluginDirectory = Join-Path $Destination '$PLUGINSDIR'
    if (Test-Path -LiteralPath $pluginDirectory) { Remove-EzVmSafeTree -Path $pluginDirectory }
    $uninstaller = Join-Path $Destination 'qemu-uninstall.exe'
    if (Test-Path -LiteralPath $uninstaller) { Remove-Item -LiteralPath $uninstaller -Force }

    return [pscustomobject][ordered]@{
        Root = $Destination
        QemuSystem = Join-Path $Destination 'qemu-system-x86_64.exe'
        QemuImg = Join-Path $Destination 'qemu-img.exe'
    }
}

function Test-EzVmQemuPayload {
    param([string]$Root, [string]$ExpectedVersionPrefix)

    $qemuSystem = Join-Path $Root 'qemu-system-x86_64.exe'
    $qemuImg = Join-Path $Root 'qemu-img.exe'
    foreach ($path in @($qemuSystem, $qemuImg)) {
        if (-not [IO.File]::Exists($path)) { throw "Managed QEMU payload is missing '$path'." }
    }

    $system = Invoke-EzVmProcess -FilePath $qemuSystem -ArgumentList @('--version') -WorkingDirectory $Root -TimeoutSeconds 30 -ThrowOnError
    $image = Invoke-EzVmProcess -FilePath $qemuImg -ArgumentList @('--version') -WorkingDirectory $Root -TimeoutSeconds 30 -ThrowOnError
    if ($system.StdOut -notmatch ('(?m)^QEMU emulator version\s+' + [regex]::Escape($ExpectedVersionPrefix) + '(?:\s|\()')) {
        throw "qemu-system-x86_64.exe did not report reviewed version prefix '$ExpectedVersionPrefix'."
    }
    if ($image.StdOut -notmatch ('(?m)^qemu-img version\s+' + [regex]::Escape($ExpectedVersionPrefix) + '(?:\s|\()')) {
        throw "qemu-img.exe did not report reviewed version prefix '$ExpectedVersionPrefix'."
    }

    $probeDirectory = Join-Path $Root ('.ezvm-probe-' + [Guid]::NewGuid().ToString('N'))
    $null = Assert-EzVmSafePath -Path $probeDirectory -Description 'Managed directory'
    [void][IO.Directory]::CreateDirectory($probeDirectory)
    try {
        $probeImage = Join-Path $probeDirectory 'probe.qcow2'
        Invoke-EzVmProcess -FilePath $qemuImg -ArgumentList @('create', '-f', 'qcow2', $probeImage, '1M') -WorkingDirectory $Root -TimeoutSeconds 30 -ThrowOnError | Out-Null
        $info = Invoke-EzVmProcess -FilePath $qemuImg -ArgumentList @('info', '--output=json', $probeImage) -WorkingDirectory $Root -TimeoutSeconds 30 -ThrowOnError
        $metadata = $info.StdOut | ConvertFrom-Json -ErrorAction Stop
        if ($metadata.format -cne 'qcow2') { throw 'qemu-img functional probe did not create a qcow2 image.' }
    }
    finally {
        if (Test-Path -LiteralPath $probeDirectory) { Remove-EzVmSafeTree -Path $probeDirectory }
    }

    return [pscustomobject][ordered]@{
        QemuSystemVersion = ($system.StdOut -split '\r?\n')[0]
        QemuImgVersion = ($image.StdOut -split '\r?\n')[0]
    }
}

function Get-EzVmManagedQemuStatus {
    [CmdletBinding()]
    param(
        [string]$Root = $script:EzVmDefaultRoot,
        [object]$Manifest,
        [string]$ManifestPath,
        [scriptblock]$PayloadProbe
    )

    $paths = Get-EzVmPaths -Root $Root
    if (-not $PSBoundParameters.ContainsKey('ManifestPath')) { $ManifestPath = $paths.QemuManifest }
    if ($null -eq $Manifest) { $Manifest = Get-EzVmQemuManifest -Root $Root -ManifestPath $ManifestPath }
    $expectedVersion = Get-EzVmEffectiveQemuVersionPrefix -Manifest $Manifest
    $provenancePath = Join-Path $paths.Qemu 'ezvm-provenance.json'
    $systemPath = Join-Path $paths.Qemu 'qemu-system-x86_64.exe'
    $imgPath = Join-Path $paths.Qemu 'qemu-img.exe'
    if (-not (Test-Path -LiteralPath $provenancePath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $systemPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $imgPath -PathType Leaf)) {
        return [pscustomobject][ordered]@{ Valid = $false; Reason = 'Managed QEMU runtime is not installed.'; QemuSystem = $systemPath; QemuImg = $imgPath }
    }
    try {
        Assert-EzVmQemuPayloadIntegrity -RuntimeDirectory $paths.Qemu -ManifestPath $ManifestPath
        if ($null -ne $PayloadProbe) {
            $probe = & $PayloadProbe $paths.Qemu $expectedVersion
            if ($null -eq $probe -or -not $probe.QemuSystemVersion -or -not $probe.QemuImgVersion) {
                return [pscustomobject][ordered]@{ Valid = $false; Reason = 'Managed QEMU fixture probe did not return version evidence.'; QemuSystem = $systemPath; QemuImg = $imgPath }
            }
            $systemVersion = [string]$probe.QemuSystemVersion
            $imageVersion = [string]$probe.QemuImgVersion
        }
        else {
            $system = Invoke-EzVmProcess -FilePath $systemPath -ArgumentList @('--version') -WorkingDirectory $paths.Qemu -TimeoutSeconds 30 -ThrowOnError
            $image = Invoke-EzVmProcess -FilePath $imgPath -ArgumentList @('--version') -WorkingDirectory $paths.Qemu -TimeoutSeconds 30 -ThrowOnError
            if ($system.StdOut -notmatch ('(?m)^QEMU emulator version\s+' + [regex]::Escape($expectedVersion) + '(?:\s|\()') -or
                $image.StdOut -notmatch ('(?m)^qemu-img version\s+' + [regex]::Escape($expectedVersion) + '(?:\s|\()')) {
                return [pscustomobject][ordered]@{ Valid = $false; Reason = 'Managed QEMU executable versions do not match the reviewed manifest.'; QemuSystem = $systemPath; QemuImg = $imgPath }
            }
            $systemVersion = ($system.StdOut -split '\r?\n')[0]
            $imageVersion = ($image.StdOut -split '\r?\n')[0]
        }
        return [pscustomobject][ordered]@{
            Valid = $true
            Reason = 'Managed QEMU runtime matches reviewed provenance and version.'
            QemuSystem = $systemPath
            QemuImg = $imgPath
            QemuSystemVersion = $systemVersion
            QemuImgVersion = $imageVersion
        }
    }
    catch {
        return [pscustomobject][ordered]@{ Valid = $false; Reason = $_.Exception.Message; QemuSystem = $systemPath; QemuImg = $imgPath }
    }
}

function Move-EzVmDirectoryAtomically {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [ValidateRange(1, 100)][int]$Attempts = 20,
        [ValidateRange(0, 5000)][int]$DelayMilliseconds = 250,
        [scriptblock]$Mover
    )

    $sourcePath = Assert-EzVmSafePath -Path $Source -Description 'Atomic directory source'
    $destinationPath = Assert-EzVmSafePath -Path $Destination -Description 'Atomic directory destination'
    $comparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        [StringComparison]::OrdinalIgnoreCase
    } else {
        [StringComparison]::Ordinal
    }
    if (-not [string]::Equals([IO.Path]::GetPathRoot($sourcePath), [IO.Path]::GetPathRoot($destinationPath), $comparison)) {
        throw "Atomic directory promotion requires source and destination on the same filesystem root: '$sourcePath' -> '$destinationPath'."
    }

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $null = Assert-EzVmSafePath -Path $sourcePath -Description 'Atomic directory source'
        $null = Assert-EzVmSafePath -Path $destinationPath -Description 'Atomic directory destination'
        if (-not [IO.Directory]::Exists($sourcePath)) {
            throw "Atomic directory promotion source disappeared before completion: '$sourcePath'."
        }
        if ([IO.Directory]::Exists($destinationPath) -or [IO.File]::Exists($destinationPath)) {
            throw "Atomic directory promotion destination already exists: '$destinationPath'."
        }
        try {
            if ($null -ne $Mover) { & $Mover $sourcePath $destinationPath }
            else { [IO.Directory]::Move($sourcePath, $destinationPath) }
            return
        }
        catch {
            $leaf = $_.Exception
            while ($null -ne $leaf.InnerException) { $leaf = $leaf.InnerException }
            $transient = $leaf -is [IO.IOException] -or $leaf -is [UnauthorizedAccessException]
            if (-not $transient -or $attempt -eq $Attempts) { throw }
            if (-not [IO.Directory]::Exists($sourcePath) -or
                [IO.Directory]::Exists($destinationPath) -or [IO.File]::Exists($destinationPath)) {
                throw
            }
            if ($DelayMilliseconds -gt 0) { Start-Sleep -Milliseconds $DelayMilliseconds }
        }
    }
}

function Install-EzVmQemuRuntime {
    [CmdletBinding()]
    param(
        [string]$Root = $script:EzVmDefaultRoot,
        [string]$ManifestPath,
        [scriptblock]$Downloader,
        [scriptblock]$ExtractorBootstrapper,
        [scriptblock]$QemuExpander,
        [scriptblock]$PayloadProbe
    )

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or -not [Environment]::Is64BitOperatingSystem) {
        throw 'Portable QEMU bootstrap requires a Windows x86-64 host.'
    }

    $paths = Get-EzVmPaths -Root $Root
    $null = Assert-EzVmSafePath -Path $paths.Qemu -Description 'QEMU bootstrap'
    $lock = Enter-EzVmSecurityLock -Path (Join-Path $paths.Locks 'qemu-bootstrap.lock')
    try {
        $manifestArguments = @{ Root = $Root }
        if ($PSBoundParameters.ContainsKey('ManifestPath')) { $manifestArguments.ManifestPath = $ManifestPath }
        $manifest = Get-EzVmQemuManifest @manifestArguments
        $overlay = Get-EzVmQemuOverlay -Manifest $manifest
        $expectedVersion = Get-EzVmEffectiveQemuVersionPrefix -Manifest $manifest
        $effectiveVersion = Get-EzVmEffectiveQemuVersion -Manifest $manifest
        if (-not $PSBoundParameters.ContainsKey('ManifestPath')) { $ManifestPath = $paths.QemuManifest }
        $manifestDigest = Get-EzVmFileDigest -Path $ManifestPath -Algorithm SHA256

        $statusArguments = @{ Root = $Root; Manifest = $manifest; ManifestPath = $ManifestPath }
        if ($null -ne $PayloadProbe) { $statusArguments.PayloadProbe = $PayloadProbe }
        $installed = Get-EzVmManagedQemuStatus @statusArguments
        if ($installed.Valid) {
            return [pscustomobject][ordered]@{
                runtimePath = $paths.Qemu
                qemuSystem = $installed.QemuSystem
                qemuImg = $installed.QemuImg
                version = $effectiveVersion
                providerBuild = $manifest.qemu.providerBuild
                downloaded = $false
                idempotent = $true
            }
        }

        if (Test-Path -LiteralPath $paths.Qemu) {
            throw ('Existing QEMU runtime is not verified and will not be replaced automatically. Stop all guests and preserve it outside runtime/qemu before a fresh bootstrap. ' + $installed.Reason)
        }

        $null = Assert-EzVmSafePath -Path $paths.Downloads -Description 'Managed directory'

        [void][IO.Directory]::CreateDirectory($paths.Downloads)
        $null = Assert-EzVmSafePath -Path $paths.Runtime -Description 'Managed directory'
        [void][IO.Directory]::CreateDirectory($paths.Runtime)

        function Acquire-EzVmQemuArtifact {
            param([object]$Descriptor)
            $arguments = @{
                Url = $Descriptor.url
                FileName = $Descriptor.filename
                Algorithm = $Descriptor.digestAlgorithm
                ExpectedDigest = $Descriptor.digest
                ExpectedSizeBytes = [long]$Descriptor.sizeBytes
                DestinationDirectory = $paths.Downloads
            }
            if ($null -ne $Downloader) { $arguments.Downloader = $Downloader }
            return Get-EzVmVerifiedArtifact @arguments
        }

        $qemuArtifact = Acquire-EzVmQemuArtifact $manifest.qemu
        $bootstrapArtifact = Acquire-EzVmQemuArtifact $manifest.extractor.bootstrap
        $packageArtifact = Acquire-EzVmQemuArtifact $manifest.extractor.package
        $overlayArtifact = $null; $overlayDownloaded = $false
        if ($null -ne $overlay) {
            $overlayArtifact = Acquire-EzVmQemuArtifact $overlay.artifact
            $overlayDownloaded = [bool]$overlayArtifact.Downloaded
        }

        $extractorStage = Join-Path $paths.Runtime ('.qemu-extractor-' + [Guid]::NewGuid().ToString('N'))
        $qemuStage = Join-Path $paths.Runtime ('.qemu-stage-' + [Guid]::NewGuid().ToString('N'))
        $overlayStage = Join-Path $paths.Runtime ('.qemu-overlay-' + [Guid]::NewGuid().ToString('N'))
        $artifactHandles = New-Object 'System.Collections.Generic.List[object]'
        try {
            $artifactPairs = @(@($qemuArtifact, $manifest.qemu), @($bootstrapArtifact, $manifest.extractor.bootstrap), @($packageArtifact, $manifest.extractor.package))
            if ($null -ne $overlayArtifact) { $artifactPairs += ,@($overlayArtifact, $overlay.artifact) }
            foreach ($pair in $artifactPairs) {
                $artifactPath = Assert-EzVmSafePath -Path $pair[0].Path -Description 'Verified acquisition input'
                $artifactHandles.Add([IO.File]::Open($artifactPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read))
                if ((Get-EzVmFileDigest -Path $artifactPath -Algorithm $pair[1].digestAlgorithm) -cne $pair[1].digest -or (Get-Item -LiteralPath $artifactPath -Force).Length -ne [long]$pair[1].sizeBytes) {
                    throw 'A downloaded artifact changed before extraction. No unverified executable will be used.'
                }
            }
            if ($null -ne $ExtractorBootstrapper) {
                $extractor = & $ExtractorBootstrapper $bootstrapArtifact.Path $packageArtifact.Path $extractorStage $manifest.extractor.version
            }
            else {
                $extractor = Invoke-EzVmSevenZipBootstrap -BootstrapExtractor $bootstrapArtifact.Path -PackagePath $packageArtifact.Path -Destination $extractorStage -ExpectedVersion $manifest.extractor.version
            }
            if ($null -eq $extractor -or -not $extractor.SevenZipExe) { throw 'Extractor bootstrap did not return a verified 7z.exe path.' }

            if ($null -ne $QemuExpander) {
                $expanded = & $QemuExpander $extractor.SevenZipExe $qemuArtifact.Path $qemuStage
            }
            else {
                $expanded = Invoke-EzVmQemuExtraction -SevenZipExe $extractor.SevenZipExe -InstallerPath $qemuArtifact.Path -Destination $qemuStage
            }
            if ($null -eq $expanded -or -not (Test-Path -LiteralPath (Join-Path $qemuStage 'qemu-system-x86_64.exe') -PathType Leaf) -or
                -not (Test-Path -LiteralPath (Join-Path $qemuStage 'qemu-img.exe') -PathType Leaf)) {
                throw 'QEMU extraction did not produce the required managed executables.'
            }

            if ($null -ne $overlay) {
                Expand-EzVmQemuOverlay -ArchivePath $overlayArtifact.Path -Destination $overlayStage -Overlay $overlay
                Install-EzVmQemuOverlayFiles -ProviderStage $qemuStage -OverlayStage $overlayStage -Overlay $overlay
            }
            $inventoryArguments = @{RuntimeDirectory=$qemuStage;ManifestDigest=$manifestDigest}
            if ($null -ne $overlay) { $inventoryArguments.ExpectedCanonicalDigest = $overlay.installedPayloadSha256 }
            $inventoryDigest = Write-EzVmQemuPayloadInventory @inventoryArguments
            if ($null -ne $PayloadProbe) {
                $probe = & $PayloadProbe $qemuStage $expectedVersion
            }
            else {
                $probe = Test-EzVmQemuPayload -Root $qemuStage -ExpectedVersionPrefix $expectedVersion
            }
            if ($null -eq $probe -or -not $probe.QemuSystemVersion -or -not $probe.QemuImgVersion) {
                throw 'QEMU payload probe did not return validated version evidence.'
            }

            if ([string]$probe.QemuSystemVersion -notmatch [regex]::Escape($expectedVersion) -or
                [string]$probe.QemuImgVersion -notmatch [regex]::Escape($expectedVersion)) {
                throw "QEMU payload probe did not confirm reviewed version prefix '$expectedVersion'."
            }

            $provenance = [pscustomobject][ordered]@{
                schemaVersion = 1
                payloadManifestSha256 = $inventoryDigest
                manifestSha256 = $manifestDigest
                provider = $manifest.provider
                qemuVersion = $effectiveVersion
                providerBuild = $manifest.qemu.providerBuild
                qemuUrl = $manifest.qemu.url
                qemuFilename = $manifest.qemu.filename
                qemuDigestAlgorithm = $manifest.qemu.digestAlgorithm
                qemuExpectedDigest = $manifest.qemu.digest
                qemuObservedDigest = $qemuArtifact.Digest
                extractorVersion = $manifest.extractor.version
                extractorBootstrapUrl = $manifest.extractor.bootstrap.url
                extractorBootstrapDigest = $bootstrapArtifact.Digest
                extractorPackageUrl = $manifest.extractor.package.url
                extractorPackageDigest = $packageArtifact.Digest
                extractorVersionOutput = [string]$extractor.VersionOutput
                qemuSystemVersion = [string]$probe.QemuSystemVersion
                qemuImgVersion = [string]$probe.QemuImgVersion
                bootstrappedAt = [DateTime]::UtcNow.ToString('o')
            }
            if ($null -ne $overlay) {
                $provenance | Add-Member -NotePropertyName whpxResetOverlay -NotePropertyValue ([pscustomobject]@{
                    artifactSha256 = $overlayArtifact.Digest
                    basePayloadSha256 = $overlay.basePayloadSha256
                    qemuSourceCommit = $overlay.qemuSourceCommit
                    qemuSourceTree = $overlay.qemuSourceTree
                    buildManifestSha256 = $overlay.buildManifestSha256
                })
            }
            Write-EzVmJson -Path (Join-Path $qemuStage 'ezvm-provenance.json') -Value $provenance -SchemaVersion 1

            Assert-EzVmQemuPayloadIntegrity -RuntimeDirectory $qemuStage -ManifestPath $ManifestPath
            Move-EzVmDirectoryAtomically -Source $qemuStage -Destination $paths.Qemu

            return [pscustomobject][ordered]@{
                runtimePath = $paths.Qemu
                qemuSystem = Join-Path $paths.Qemu 'qemu-system-x86_64.exe'
                qemuImg = Join-Path $paths.Qemu 'qemu-img.exe'
                version = $effectiveVersion
                providerBuild = $manifest.qemu.providerBuild
                downloaded = [bool]($qemuArtifact.Downloaded -or $bootstrapArtifact.Downloaded -or $packageArtifact.Downloaded -or $overlayDownloaded)
                idempotent = $false
            }
        }
        finally {
            foreach ($handle in $artifactHandles) { $handle.Dispose() }
            $cleanupFailure = $null
            foreach ($stage in @($extractorStage, $qemuStage, $overlayStage)) {
                if (Test-Path -LiteralPath $stage) {
                    try { Remove-EzVmSafeTree -Path $stage } catch { if ($null -eq $cleanupFailure) { $cleanupFailure = $_ } }
                }
            }
            if ($null -ne $cleanupFailure) { throw $cleanupFailure }
        }
    }
    finally { $lock.Dispose() }
}

function Get-EzVmQemuToolPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('qemu-system-x86_64.exe', 'qemu-img.exe')][string]$Name,
        [string]$Root = $script:EzVmDefaultRoot
    )
    $paths = Get-EzVmPaths -Root $Root
    $path = Join-Path $paths.Qemu $Name
    if (-not [IO.File]::Exists($path)) {
        throw "Managed QEMU tool '$Name' is unavailable. Run '.\ezvm.ps1 bootstrap' first."
    }
    Assert-EzVmQemuPayloadIntegrity -RuntimeDirectory $paths.Qemu -ManifestPath $paths.QemuManifest
    return [IO.Path]::GetFullPath($path)
}
