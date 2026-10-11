function Get-EzVmObjectProperty {
    param([AllowNull()][object]$Object, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Invoke-EzVmBaseQemuImg {
    param(
        [string]$Root,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [scriptblock]$Runner,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 600
    )

    if ($null -ne $Runner) {
        $result = & $Runner $ArgumentList
        if ($null -eq $result -or $null -eq $result.PSObject.Properties['ExitCode']) {
            throw 'qemu-img test runner must return ExitCode, StdOut and StdErr.'
        }
        if ([int]$result.ExitCode -ne 0) {
            throw "qemu-img fixture failed with exit code $($result.ExitCode): $($result.StdErr)"
        }
        return $result
    }

    $tool = Get-EzVmQemuToolPath -Name 'qemu-img.exe' -Root $Root
    return Invoke-EzVmProcess -FilePath $tool -ArgumentList $ArgumentList -WorkingDirectory (Split-Path -Parent $tool) -TimeoutSeconds $TimeoutSeconds -ThrowOnError
}

function Get-EzVmQemuImageInfo {
    param([string]$Root, [string]$Path, [scriptblock]$Runner)

    $result = Invoke-EzVmBaseQemuImg -Root $Root -ArgumentList @('info', '--output=json', $Path) -Runner $Runner
    try { return $result.StdOut | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "qemu-img returned invalid JSON while inspecting '$Path': $($_.Exception.Message)" }
}

function Assert-EzVmStandaloneQcow2 {
    param([object]$Info, [string]$Description)

    if ((Get-EzVmObjectProperty $Info 'format') -cne 'qcow2') {
        throw "$Description must be qcow2."
    }
    $backing = Get-EzVmObjectProperty $Info 'backing-filename'
    if (-not [string]::IsNullOrWhiteSpace([string]$backing)) {
        throw "$Description must be standalone with no backing file; found '$backing'."
    }
    $virtualSize = Get-EzVmObjectProperty $Info 'virtual-size'
    if ($null -eq $virtualSize -or [long]$virtualSize -le 0) {
        throw "$Description must report a positive virtual size."
    }
}

function New-EzVmBaseStagingDisk {
    [CmdletBinding()]
    param(
        [string]$Root = $script:EzVmDefaultRoot,
        [Parameter(Mandatory = $true)][string]$SourceImage,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][ValidateRange(8, 256)][int]$VirtualSizeGiB,
        [scriptblock]$QemuImgRunner
    )

    $sourceInfo = Get-EzVmQemuImageInfo -Root $Root -Path $SourceImage -Runner $QemuImgRunner
    Assert-EzVmStandaloneQcow2 -Info $sourceInfo -Description 'Verified Ubuntu source image'

    $null = Invoke-EzVmBaseQemuImg -Root $Root -ArgumentList @(
        'create', '-f', 'qcow2', '-F', 'qcow2', '-b', [IO.Path]::GetFullPath($SourceImage), [IO.Path]::GetFullPath($Destination)
    ) -Runner $QemuImgRunner
    $null = Invoke-EzVmBaseQemuImg -Root $Root -ArgumentList @(
        'resize', [IO.Path]::GetFullPath($Destination), ($VirtualSizeGiB.ToString() + 'G')
    ) -Runner $QemuImgRunner

    $info = Get-EzVmQemuImageInfo -Root $Root -Path $Destination -Runner $QemuImgRunner
    if ((Get-EzVmObjectProperty $info 'format') -cne 'qcow2') {
        throw 'Prepared-base staging image is not qcow2.'
    }
    if ([string]::IsNullOrWhiteSpace([string](Get-EzVmObjectProperty $info 'backing-filename'))) {
        throw 'Prepared-base staging image lost its verified source backing file.'
    }
    return $info
}

function Convert-EzVmBaseToStandalone {
    [CmdletBinding()]
    param(
        [string]$Root = $script:EzVmDefaultRoot,
        [Parameter(Mandatory = $true)][string]$StagingDisk,
        [Parameter(Mandatory = $true)][string]$Destination,
        [scriptblock]$QemuImgRunner
    )

    $null = Invoke-EzVmBaseQemuImg -Root $Root -ArgumentList @(
        'convert', '-f', 'qcow2', '-O', 'qcow2', [IO.Path]::GetFullPath($StagingDisk), [IO.Path]::GetFullPath($Destination)
    ) -Runner $QemuImgRunner -TimeoutSeconds 1800

    $info = Get-EzVmQemuImageInfo -Root $Root -Path $Destination -Runner $QemuImgRunner
    Assert-EzVmStandaloneQcow2 -Info $info -Description 'Prepared base'
    $null = Invoke-EzVmBaseQemuImg -Root $Root -ArgumentList @(
        'check', '--output=json', '-f', 'qcow2', [IO.Path]::GetFullPath($Destination)
    ) -Runner $QemuImgRunner -TimeoutSeconds 1800
    return $info
}

function Start-EzVmBaseQemuProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = Resolve-EzVmProcessFileSystemPath -Path $FilePath
    $startInfo.WorkingDirectory = Resolve-EzVmProcessFileSystemPath -Path $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $startInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    if ($null -ne $startInfo.PSObject.Properties['ArgumentList']) {
        foreach ($argument in $ArgumentList) { $startInfo.ArgumentList.Add($argument) }
    }
    else {
        $escaped = New-Object 'System.Collections.Generic.List[string]'
        foreach ($argument in $ArgumentList) {
            $escaped.Add((ConvertTo-EzVmWindowsArgument -Argument $argument))
        }
        $startInfo.Arguments = [string]::Join(' ', $escaped.ToArray())
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $started = $false
    try {
        Start-EzVmProcessWithoutInputPreamble -Process $process -TimeoutMilliseconds 30000 -Started ([ref]$started)
        if (-not $started) { throw 'The operating system did not create the QEMU process.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.BaseStream.Close()
        return [pscustomobject]@{
            Process = $process
            StdOutTask = $stdoutTask
            StdErrTask = $stderrTask
        }
    }
    catch {
        if ($started) { try { $process.Kill() } catch { } }
        $process.Dispose()
        throw
    }
}

function Stop-EzVmBaseQemuProcess {
    param([AllowNull()][object]$Handle)
    if ($null -eq $Handle) { return }
    try {
        if (-not $Handle.Process.HasExited) {
            $null = Stop-EzVmTimedOutProcess -Process $Handle.Process
        }
    }
    catch { }
}

function Complete-EzVmBaseQemuProcess {
    param([Parameter(Mandatory = $true)][object]$Handle)

    if (-not $Handle.Process.HasExited) {
        throw 'QEMU process is still running and cannot be completed.'
    }
    if (-not $Handle.StdOutTask.Wait(5000) -or -not $Handle.StdErrTask.Wait(5000)) {
        throw 'QEMU exited but its output streams did not drain.'
    }
    return [pscustomobject]@{
        ExitCode = $Handle.Process.ExitCode
        StdOut = $Handle.StdOutTask.Result
        StdErr = $Handle.StdErrTask.Result
    }
}

function Read-EzVmSharedTextTail {
    param([Parameter(Mandatory = $true)][string]$Path, [int]$MaxBytes = 2097152)

    if (-not [IO.File]::Exists($Path)) { return '' }
    $stream = $null
    $reader = $null
    try {
        $stream = New-Object IO.FileStream(
            $Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        if ($stream.Length -gt $MaxBytes) { $stream.Seek(-$MaxBytes, [IO.SeekOrigin]::End) | Out-Null }
        $reader = New-Object IO.StreamReader($stream, (New-Object Text.UTF8Encoding($false, $false)), $true, 4096, $true)
        return $reader.ReadToEnd()
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Get-EzVmSerialMarker {
    param([string]$Text, [string]$Name)
    $match = [regex]::Matches($Text, '(?m)^' + [regex]::Escape($Name) + '=(?<value>[^\r\n]*)\r?$')
    if ($match.Count -eq 0) { return $null }
    return $match[$match.Count - 1].Groups['value'].Value
}

function ConvertFrom-EzVmMarkerBase64 {
    param([AllowNull()][string]$Value, [string]$Description)
    if ($null -eq $Value) { throw "Guest provisioning did not report $Description." }
    try { return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Value)) }
    catch { throw "Guest provisioning reported invalid base64 for $Description." }
}

function Get-EzVmBaseGuestFacts {
    param([string]$SerialText, [string]$BuildId)

    if ((Get-EzVmSerialMarker $SerialText 'EZVM_BASE_READY') -cne '1') {
        throw 'Guest provisioning did not emit the explicit prepared-base READY marker.'
    }
    if ((Get-EzVmSerialMarker $SerialText 'EZVM_BASE_TOOLS_OK') -cne '1') {
        throw 'Guest provisioning did not prove the baseline tool validation succeeded.'
    }
    if ((Get-EzVmSerialMarker $SerialText 'EZVM_BASE_CLEAN_OK') -cne '1') {
        throw 'Guest provisioning did not prove cloud-init and identity cleanup succeeded.'
    }
    if ((Get-EzVmSerialMarker $SerialText 'EZVM_BASE_BUILD_ID') -cne $BuildId) {
        throw 'Guest provisioning READY marker belongs to a different build identity.'
    }

    return [pscustomobject][ordered]@{
        OsId = ConvertFrom-EzVmMarkerBase64 (Get-EzVmSerialMarker $SerialText 'EZVM_BASE_OS_ID_B64') 'guest OS ID'
        OsVersion = ConvertFrom-EzVmMarkerBase64 (Get-EzVmSerialMarker $SerialText 'EZVM_BASE_OS_VERSION_B64') 'guest OS version'
        CloudInitVersion = ConvertFrom-EzVmMarkerBase64 (Get-EzVmSerialMarker $SerialText 'EZVM_BASE_CLOUD_INIT_B64') 'cloud-init version'
        ToolsValidated = $true
        IdentityCleaned = $true
    }
}

function Invoke-EzVmBaseProvisioningVm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$QemuSystem,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][object]$SeedServer,
        [Parameter(Mandatory = $true)][string]$SerialLog,
        [Parameter(Mandatory = $true)][string]$BuildId,
        [ValidateRange(30, 86400)][int]$TimeoutSeconds = 2700
    )

    if (Test-Path -LiteralPath $SerialLog) { Remove-Item -LiteralPath $SerialLog -Force }
    $handle = $null
    try {
        $handle = Start-EzVmBaseQemuProcess -FilePath $QemuSystem -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        $serialText = ''
        while ([DateTime]::UtcNow -lt $deadline) {
            $null = Invoke-EzVmSeedServerPending -Server $SeedServer -MaxRequests 8
            $serialText = Read-EzVmSharedTextTail -Path $SerialLog

            $failure = Get-EzVmSerialMarker $serialText 'EZVM_BASE_FAILURE_B64'
            if ($null -ne $failure) {
                $detail = ConvertFrom-EzVmMarkerBase64 $failure 'guest provisioning failure'
                throw "Guest baseline validation failed: $detail"
            }
            if ($handle.Process.HasExited) { break }
            Start-Sleep -Milliseconds 100
        }

        if (-not $handle.Process.HasExited) {
            Stop-EzVmBaseQemuProcess -Handle $handle
            throw "Prepared-base guest provisioning exceeded its $TimeoutSeconds second timeout."
        }

        $result = Complete-EzVmBaseQemuProcess -Handle $handle
        $serialText = Read-EzVmSharedTextTail -Path $SerialLog
        if ($result.ExitCode -ne 0) {
            $detail = $result.StdErr.Trim()
            if ($detail.Length -gt 2048) { $detail = $detail.Substring(0, 2048) + '...' }
            throw "QEMU exited with code $($result.ExitCode) before a prepared base could be accepted. $detail"
        }
        return Get-EzVmBaseGuestFacts -SerialText $serialText -BuildId $BuildId
    }
    finally {
        if ($null -ne $handle) {
            Stop-EzVmBaseQemuProcess -Handle $handle
            $handle.Process.Dispose()
        }
    }
}

function Assert-EzVmPreparedBaseManifest {
    param([object]$Manifest)

    Assert-EzVmBaseRecipeFields -Value $Manifest -Expected @(
        'schemaVersion', 'baseId', 'baseSha256', 'virtualSizeBytes', 'builtAt',
        'source', 'provisioning', 'qemu', 'guest', 'build'
    ) -Description 'Prepared-base manifest'
    if ($Manifest.baseId -isnot [string] -or $Manifest.baseId -cnotmatch '^base-[a-f0-9]{64}$') {
        throw 'Prepared-base manifest baseId is invalid.'
    }
    Assert-EzVmArtifactDigest -Algorithm SHA256 -ExpectedDigest $Manifest.baseSha256
    if ($Manifest.baseId -cne ('base-' + $Manifest.baseSha256)) {
        throw 'Prepared-base ID must be content-addressed by the complete base SHA-256.'
    }
    $size = $Manifest.virtualSizeBytes
    $integer = $size -is [int] -or $size -is [long] -or $size -is [uint32] -or $size -is [uint64]
    if (-not $integer -or [long]$size -le 0) { throw 'Prepared-base virtualSizeBytes must be positive.' }
    if ($Manifest.builtAt -isnot [string] -or [string]::IsNullOrWhiteSpace($Manifest.builtAt)) {
        throw 'Prepared-base builtAt must be an ISO timestamp string.'
    }

    Assert-EzVmBaseRecipeFields -Value $Manifest.source -Expected @(
        'manifestSha256', 'imageSha256', 'publication', 'filename'
    ) -Description 'Prepared-base source provenance'
    Assert-EzVmArtifactDigest -Algorithm SHA256 -ExpectedDigest $Manifest.source.manifestSha256
    Assert-EzVmArtifactDigest -Algorithm SHA256 -ExpectedDigest $Manifest.source.imageSha256

    Assert-EzVmBaseRecipeFields -Value $Manifest.provisioning -Expected @(
        'recipeVersion', 'digest'
    ) -Description 'Prepared-base provisioning provenance'
    Assert-EzVmArtifactDigest -Algorithm SHA256 -ExpectedDigest $Manifest.provisioning.digest

    Assert-EzVmBaseRecipeFields -Value $Manifest.qemu -Expected @(
        'manifestSha256', 'qemuSystemVersion', 'qemuImgVersion', 'providerBuild'
    ) -Description 'Prepared-base QEMU provenance'
    Assert-EzVmArtifactDigest -Algorithm SHA256 -ExpectedDigest $Manifest.qemu.manifestSha256

    Assert-EzVmBaseRecipeFields -Value $Manifest.guest -Expected @(
        'osId', 'osVersion', 'cloudInitVersion', 'baselineToolsValidated', 'identityCleaned'
    ) -Description 'Prepared-base guest provenance'
    if ($Manifest.guest.baselineToolsValidated -ne $true -or $Manifest.guest.identityCleaned -ne $true) {
        throw 'Prepared-base guest provenance must prove tool validation and identity cleanup.'
    }

    Assert-EzVmBaseRecipeFields -Value $Manifest.build -Expected @(
        'accelerator', 'machine', 'firmwareCode', 'firmwareVariablesTemplate'
    ) -Description 'Prepared-base build provenance'
    if (@('whpx', 'tcg') -cnotcontains $Manifest.build.accelerator) {
        throw 'Prepared-base build accelerator must be whpx or tcg.'
    }
}

function Test-EzVmPreparedBase {
    [CmdletBinding()]
    param(
        [string]$Root = $script:EzVmDefaultRoot,
        [Parameter(Mandatory = $true)][string]$BaseId,
        [scriptblock]$QemuImgRunner
    )

    if ($BaseId -cnotmatch '^base-[a-f0-9]{64}$') { throw "Invalid prepared-base ID '$BaseId'." }
    $paths = Get-EzVmPaths -Root $Root
    $directory = Join-Path $paths.Bases $BaseId
    $image = Join-Path $directory 'base.qcow2'
    $manifestPath = Join-Path $directory 'manifest.json'
    if (-not (Test-Path -LiteralPath $image -PathType Leaf) -or -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Prepared base '$BaseId' is incomplete. Expected base.qcow2 and manifest.json."
    }

    $manifest = Read-EzVmJson -Path $manifestPath -SchemaVersion 1
    Assert-EzVmPreparedBaseManifest -Manifest $manifest
    if ($manifest.baseId -cne $BaseId) { throw 'Prepared-base directory identity does not match its manifest.' }
    $observed = Get-EzVmFileDigest -Path $image -Algorithm SHA256
    if ($observed -cne $manifest.baseSha256) { throw 'Prepared-base content digest does not match its manifest.' }

    $info = Get-EzVmQemuImageInfo -Root $Root -Path $image -Runner $QemuImgRunner
    Assert-EzVmStandaloneQcow2 -Info $info -Description "Prepared base '$BaseId'"
    if ([long](Get-EzVmObjectProperty $info 'virtual-size') -ne [long]$manifest.virtualSizeBytes) {
        throw 'Prepared-base virtual size does not match its manifest.'
    }
    if ((Get-Item -LiteralPath $image -Force).Attributes -band [IO.FileAttributes]::ReadOnly) {
        $readOnly = $true
    }
    else {
        throw 'Prepared-base image is not marked read-only by the immutable-base contract.'
    }

    return [pscustomobject][ordered]@{
        BaseId = $BaseId
        Directory = $directory
        Image = $image
        ManifestPath = $manifestPath
        Manifest = $manifest
        ReadOnly = $readOnly
    }
}

function Write-EzVmBaseFailureEvidence {
    param([string]$StagingDirectory, [string]$BuildId, [object]$Failure)

    if (-not (Test-Path -LiteralPath $StagingDirectory -PathType Container)) { return }
    try {
        $value = [pscustomobject][ordered]@{
            schemaVersion = 1
            buildId = $BuildId
            failedAt = [DateTime]::UtcNow.ToString('o')
            message = [string]$Failure.Exception.Message
        }
        Write-EzVmJson -Path (Join-Path $StagingDirectory 'failure.json') -Value $value -SchemaVersion 1
    }
    catch { }
}

function Build-EzVmPreparedBase {
    [CmdletBinding()]
    param(
        [string]$Root = $script:EzVmDefaultRoot,
        [ValidateSet('whpx', 'tcg')][string]$Accelerator = 'whpx',
        [ValidateRange(30, 86400)][int]$BuildTimeoutSeconds = 2700,
        [scriptblock]$QemuStatusProvider,
        [scriptblock]$SourceProvider,
        [scriptblock]$QemuImgRunner,
        [scriptblock]$GuestRunner
    )

    $paths = Get-EzVmPaths -Root $Root
    $qemuManifest = Get-EzVmQemuManifest -Root $Root
    $qemuManifestDigest = Get-EzVmFileDigest -Path $paths.QemuManifest -Algorithm SHA256
    $qemuStatus = if ($null -ne $QemuStatusProvider) {
        & $QemuStatusProvider $Root $qemuManifest
    }
    else {
        Get-EzVmManagedQemuStatus -Root $Root -Manifest $qemuManifest -ManifestPath $paths.QemuManifest
    }
    if ($null -eq $qemuStatus -or -not $qemuStatus.Valid) {
        $reason = if ($null -ne $qemuStatus) { $qemuStatus.Reason } else { 'No managed QEMU status was returned.' }
        throw "Prepared-base build requires a validated managed QEMU runtime. $reason Run '.\ezvm.ps1 bootstrap' and retry."
    }

    $sourceManifest = Get-EzVmSourceImageManifest -Root $Root
    $sourceManifestDigest = Get-EzVmFileDigest -Path $paths.UbuntuManifest -Algorithm SHA256
    $source = if ($null -ne $SourceProvider) { & $SourceProvider $Root $sourceManifest } else { Get-EzVmVerifiedSourceImage -Root $Root }
    if ($null -eq $source -or -not $source.path -or -not (Test-Path -LiteralPath $source.path -PathType Leaf)) {
        throw "Prepared-base build requires the verified Ubuntu source image. Run '.\ezvm.ps1 base acquire' and retry."
    }
    $sourceDigest = Get-EzVmFileDigest -Path $source.path -Algorithm SHA256
    if ($sourceDigest -cne $sourceManifest.sha256) {
        throw 'Ubuntu source image changed after acquisition and no longer matches the reviewed manifest.'
    }

    $recipe = Get-EzVmBaseRecipe -Root $Root
    $buildId = [Guid]::NewGuid().ToString('N')
    [void][IO.Directory]::CreateDirectory($paths.Bases)
    $stage = Join-Path $paths.Bases ('.build-' + $buildId)
    [void][IO.Directory]::CreateDirectory($stage)
    $seedDirectory = Join-Path $stage 'seed'
    [void][IO.Directory]::CreateDirectory($seedDirectory)
    $seedServer = $null
    $publish = $null

    try {
        $seed = New-EzVmBaseSeedData -Root $Root -BuildId $buildId
        $utf8 = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText((Join-Path $seedDirectory 'user-data'), $seed.UserData, $utf8)
        [IO.File]::WriteAllText((Join-Path $seedDirectory 'meta-data'), $seed.MetaData, $utf8)

        $firmware = Get-EzVmBaseFirmwarePaths -Root $Root -StagingDirectory $stage
        $stagingDisk = Join-Path $stage 'staging.qcow2'
        $null = New-EzVmBaseStagingDisk -Root $Root -SourceImage $source.path -Destination $stagingDisk -VirtualSizeGiB $recipe.virtualSizeGiB -QemuImgRunner $QemuImgRunner

        $serialLog = Join-Path $stage 'serial.log'
        $seedServer = Start-EzVmSeedServer -UserData $seed.UserData -MetaData $seed.MetaData -TimeoutSeconds $BuildTimeoutSeconds
        try {
            $command = New-EzVmBaseQemuArguments -BuildId $buildId -Recipe $recipe -StagingDisk $stagingDisk -FirmwareCode $firmware.Code -FirmwareVariables $firmware.Variables -SerialLog $serialLog -SeedHostPort $seedServer.Port -Accelerator $Accelerator
            $context = [pscustomobject][ordered]@{
                Root = $Root
                BuildId = $buildId
                QemuSystem = $qemuStatus.QemuSystem
                Arguments = $command.Arguments
                SeedServer = $seedServer
                SeedUrl = $command.SeedUrl
                GuestForward = $command.GuestForward
                SerialLog = $serialLog
                StagingDisk = $stagingDisk
                Accelerator = $Accelerator
                TimeoutSeconds = $BuildTimeoutSeconds
            }
            $guestFacts = if ($null -ne $GuestRunner) {
                & $GuestRunner $context
            }
            else {
                Invoke-EzVmBaseProvisioningVm -QemuSystem $context.QemuSystem -ArgumentList $context.Arguments -WorkingDirectory $paths.Qemu -SeedServer $seedServer -SerialLog $serialLog -BuildId $buildId -TimeoutSeconds $BuildTimeoutSeconds
            }
        }
        finally {
            if ($null -ne $seedServer) {
                Stop-EzVmSeedServer -Server $seedServer
                $seedServer = $null
            }
        }

        if ($null -eq $guestFacts -or $guestFacts.ToolsValidated -ne $true -or $guestFacts.IdentityCleaned -ne $true) {
            throw 'Guest provisioning did not return validated tool and identity-cleanup evidence.'
        }

        $flat = Join-Path $stage 'base-flat.qcow2'
        $flatInfo = Convert-EzVmBaseToStandalone -Root $Root -StagingDisk $stagingDisk -Destination $flat -QemuImgRunner $QemuImgRunner
        if (-not (Test-Path -LiteralPath $flat -PathType Leaf)) {
            throw 'qemu-img flattening did not produce the prepared-base file.'
        }

        $baseDigest = Get-EzVmFileDigest -Path $flat -Algorithm SHA256
        $baseId = 'base-' + $baseDigest
        $virtualSize = [long](Get-EzVmObjectProperty $flatInfo 'virtual-size')
        $manifest = [pscustomobject][ordered]@{
            schemaVersion = 1
            baseId = $baseId
            baseSha256 = $baseDigest
            virtualSizeBytes = $virtualSize
            builtAt = [DateTime]::UtcNow.ToString('o')
            source = [pscustomobject][ordered]@{
                manifestSha256 = $sourceManifestDigest
                imageSha256 = $sourceDigest
                publication = [string]$sourceManifest.publication
                filename = [string]$sourceManifest.filename
            }
            provisioning = [pscustomobject][ordered]@{
                recipeVersion = [string]$recipe.recipeVersion
                digest = [string]$seed.ProvisioningDigest
            }
            qemu = [pscustomobject][ordered]@{
                manifestSha256 = $qemuManifestDigest
                qemuSystemVersion = [string]$qemuStatus.QemuSystemVersion
                qemuImgVersion = [string]$qemuStatus.QemuImgVersion
                providerBuild = [string]$qemuManifest.qemu.providerBuild
            }
            guest = [pscustomobject][ordered]@{
                osId = [string]$guestFacts.OsId
                osVersion = [string]$guestFacts.OsVersion
                cloudInitVersion = [string]$guestFacts.CloudInitVersion
                baselineToolsValidated = $true
                identityCleaned = $true
            }
            build = [pscustomobject][ordered]@{
                accelerator = $Accelerator
                machine = [string]$recipe.machine
                firmwareCode = $firmware.CodeName
                firmwareVariablesTemplate = $firmware.VariablesTemplateName
            }
        }
        Assert-EzVmPreparedBaseManifest -Manifest $manifest

        $publish = Join-Path $paths.Bases ('.publish-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($publish)
        $publishImage = Join-Path $publish 'base.qcow2'
        [IO.File]::Move($flat, $publishImage)
        $publishManifest = Join-Path $publish 'manifest.json'
        Write-EzVmJson -Path $publishManifest -Value $manifest -SchemaVersion 1

        $imageAttributes = (Get-Item -LiteralPath $publishImage -Force).Attributes -bor [IO.FileAttributes]::ReadOnly
        [IO.File]::SetAttributes($publishImage, $imageAttributes)
        $manifestAttributes = (Get-Item -LiteralPath $publishManifest -Force).Attributes -bor [IO.FileAttributes]::ReadOnly
        [IO.File]::SetAttributes($publishManifest, $manifestAttributes)

        $final = Join-Path $paths.Bases $baseId
        if (Test-Path -LiteralPath $final -PathType Container) {
            $existing = Test-EzVmPreparedBase -Root $Root -BaseId $baseId -QemuImgRunner $QemuImgRunner
            if ($existing.Manifest.baseSha256 -cne $baseDigest) {
                throw "Content-addressed prepared-base collision at '$baseId'. Refusing replacement."
            }
            Remove-Item -LiteralPath $publish -Recurse -Force
            $publish = $null
            Remove-Item -LiteralPath $stage -Recurse -Force
            return [pscustomobject][ordered]@{
                baseId = $baseId
                path = $existing.Image
                manifestPath = $existing.ManifestPath
                sha256 = $baseDigest
                virtualSizeBytes = $virtualSize
                reused = $true
                accelerator = $Accelerator
            }
        }

        [IO.Directory]::Move($publish, $final)
        $publish = $null
        $accepted = Test-EzVmPreparedBase -Root $Root -BaseId $baseId -QemuImgRunner $QemuImgRunner
        Remove-Item -LiteralPath $stage -Recurse -Force

        return [pscustomobject][ordered]@{
            baseId = $baseId
            path = $accepted.Image
            manifestPath = $accepted.ManifestPath
            sha256 = $baseDigest
            virtualSizeBytes = $virtualSize
            reused = $false
            accelerator = $Accelerator
        }
    }
    catch {
        if ($null -ne $seedServer) {
            try { Stop-EzVmSeedServer -Server $seedServer } catch { }
        }
        if ($null -ne $publish -and (Test-Path -LiteralPath $publish -PathType Container)) {
            try { Remove-Item -LiteralPath $publish -Recurse -Force } catch { }
        }
        Write-EzVmBaseFailureEvidence -StagingDirectory $stage -BuildId $buildId -Failure $_
        throw [InvalidOperationException]::new(
            "Prepared-base build failed. No authoritative base was promoted. Diagnostic staging evidence is retained at '$stage'. $($_.Exception.Message)",
            $_.Exception)
    }
}
