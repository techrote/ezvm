#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Import-Module (Join-Path $Root 'src/EzVm/EzVm.psd1') -Force -ErrorAction Stop

$paths = Get-EzVmPaths -Root $Root
$qemuImg = Get-EzVmQemuToolPath -Name 'qemu-img.exe' -Root $Root
$qemuDirectory = Split-Path -Parent $qemuImg
$synthetic = Join-Path $paths.Runtime ('ezvm-005-real-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($synthetic)

function Invoke-RealQemuImg {
    param([string[]]$Arguments)
    return Invoke-EzVmProcess -FilePath $qemuImg -ArgumentList $Arguments -WorkingDirectory $qemuDirectory -TimeoutSeconds 120
}

$runner = {
    param($argumentList)
    Invoke-RealQemuImg -Arguments ([string[]]@($argumentList))
}

try {
    $baseScratch = Join-Path $synthetic 'base.qcow2'
    $createdBase = Invoke-RealQemuImg -Arguments @('create', '-f', 'qcow2', $baseScratch, '64M')
    if ($createdBase.ExitCode -ne 0) { throw "Could not create synthetic base: $($createdBase.StdErr)" }

    $baseInfoResult = Invoke-RealQemuImg -Arguments @('info', '--output=json', $baseScratch)
    if ($baseInfoResult.ExitCode -ne 0) { throw "Could not inspect synthetic base: $($baseInfoResult.StdErr)" }
    $baseInfo = $baseInfoResult.StdOut | ConvertFrom-Json -ErrorAction Stop
    if ($baseInfo.format -cne 'qcow2' -or [long]$baseInfo.'virtual-size' -ne 67108864) {
        throw 'Synthetic qemu-img base did not have the expected qcow2 format/64MiB virtual size.'
    }

    $baseSha = Get-EzVmFileDigest -Path $baseScratch -Algorithm SHA256
    $baseId = 'base-' + $baseSha
    $baseDirectory = Join-Path $paths.Bases $baseId
    [void][IO.Directory]::CreateDirectory($baseDirectory)
    $basePath = Join-Path $baseDirectory 'base.qcow2'
    [IO.File]::Move($baseScratch, $basePath)

    $zeroDigest = '0' * 64
    $manifest = [pscustomobject][ordered]@{
        schemaVersion = 1
        baseId = $baseId
        baseSha256 = $baseSha
        virtualSizeBytes = [long]67108864
        builtAt = [DateTime]::UtcNow.ToString('o')
        source = [pscustomobject][ordered]@{
            manifestSha256 = $zeroDigest
            imageSha256 = $zeroDigest
            publication = 'synthetic-ezvm-005'
            filename = 'synthetic.qcow2'
        }
        provisioning = [pscustomobject][ordered]@{
            recipeVersion = 'synthetic'
            digest = $zeroDigest
        }
        qemu = [pscustomobject][ordered]@{
            manifestSha256 = Get-EzVmFileDigest -Path $paths.QemuManifest -Algorithm SHA256
            qemuSystemVersion = 'not booted; EZVM-005 qemu-img-only qualification'
            qemuImgVersion = ((Invoke-RealQemuImg -Arguments @('--version')).StdOut -split '\r?\n')[0]
            providerBuild = '20260811'
        }
        guest = [pscustomobject][ordered]@{
            osId = 'synthetic'
            osVersion = 'synthetic'
            cloudInitVersion = 'not-applicable'
            baselineToolsValidated = $true
            identityCleaned = $true
        }
        build = [pscustomobject][ordered]@{
            accelerator = 'tcg'
            machine = 'q35'
            firmwareCode = 'not-booted'
            firmwareVariablesTemplate = 'not-booted'
        }
    }
    $manifestPath = Join-Path $baseDirectory 'manifest.json'
    Write-EzVmJson -Path $manifestPath -Value $manifest -SchemaVersion 1
    [IO.File]::SetAttributes($basePath, ((Get-Item -LiteralPath $basePath -Force).Attributes -bor [IO.FileAttributes]::ReadOnly))
    [IO.File]::SetAttributes($manifestPath, ((Get-Item -LiteralPath $manifestPath -Force).Attributes -bor [IO.FileAttributes]::ReadOnly))

    $acceptedBase = Test-EzVmPreparedBase -Root $Root -BaseId $baseId -QemuImgRunner $runner
    $guard = New-EzVmStorageLifecycleGuard -State 'proven-safe' -Source 'EZVM-005 real qemu-img qualification; no QEMU VM process exists'

    $created = New-EzVmInstanceOverlay -Root $Root -InstanceName 'real-qemu-img' -BaseId $baseId -LifecycleGuard $guard -QemuImgRunner $runner
    $validated = Test-EzVmInstanceStorage -Root $Root -InstanceName 'real-qemu-img' -BaseId $baseId -QemuImgRunner $runner
    if ($validated.ChainDepth -ne 1 -or [IO.Path]::IsPathRooted($validated.BackingReference)) {
        throw 'Real overlay validation did not prove a one-level relative backing relationship.'
    }
    if (-not (Test-Path -LiteralPath $validated.ResolvedBackingPath -PathType Leaf)) {
        throw 'Real overlay resolved backing file is missing.'
    }

    $check = Test-EzVmStoppedImageIntegrity -Root $Root -InstanceName 'real-qemu-img' -BaseId $baseId -LifecycleGuard $guard -QemuImgRunner $runner
    if (-not $check.Healthy) {
        throw "Real qemu-img check reported unhealthy overlay: corruptions=$($check.Corruptions) leaks=$($check.Leaks) errors=$($check.CheckErrors)."
    }

    $instanceDirectory = (Get-EzVmInstanceStoragePaths -Root $Root -InstanceName 'real-qemu-img').Directory
    $child = Join-Path $instanceDirectory 'unsupported-child.qcow2'
    $childBacking = [IO.Path]::GetFileName($created.Disk)
    $childCreate = Invoke-RealQemuImg -Arguments @('create', '-f', 'qcow2', '-F', 'qcow2', '-b', $childBacking, $child)
    if ($childCreate.ExitCode -ne 0) { throw "Could not create real second-level rejection fixture: $($childCreate.StdErr)" }
    $depthRejected = $false
    try {
        Test-EzVmInstanceOverlay -Root $Root -OverlayPath $child -BaseId $baseId -QemuImgRunner $runner | Out-Null
    }
    catch {
        if ($_.Exception.Message -match 'backing-chain depth 2') { $depthRejected = $true }
        else { throw }
    }
    if (-not $depthRejected) { throw 'Real qemu-img second backing level was not rejected.' }
    Remove-Item -LiteralPath $child -Force

    $relocated = Join-Path ([IO.Path]::GetTempPath()) ('ezvm 005 relocated root ' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($relocated)
    try {
        foreach ($relative in @('ezvm.ps1', 'src', 'config', 'manifests', 'guest')) {
            Copy-Item -LiteralPath (Join-Path $Root $relative) -Destination $relocated -Recurse -Force
        }
        $relocatedRuntime = Join-Path $relocated 'runtime'
        [void][IO.Directory]::CreateDirectory($relocatedRuntime)
        Copy-Item -LiteralPath $paths.Bases -Destination $relocatedRuntime -Recurse -Force
        Copy-Item -LiteralPath $paths.Instances -Destination $relocatedRuntime -Recurse -Force

        $relocatedValidation = Test-EzVmInstanceStorage -Root $relocated -InstanceName 'real-qemu-img' -BaseId $baseId -QemuImgRunner $runner
        if ($relocatedValidation.BackingReference -cne $validated.BackingReference) {
            throw 'Cold relocation changed the stored relative backing reference.'
        }
        if (-not $relocatedValidation.BasePath.StartsWith([IO.Path]::GetFullPath($relocated), [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Cold relocation did not resolve the base inside the relocated root.'
        }

        $reset = Reset-EzVmInstanceOverlayStorage -Root $relocated -InstanceName 'real-qemu-img' -BaseId $baseId -LifecycleGuard $guard -QemuImgRunner $runner
        $resetValidation = Test-EzVmInstanceStorage -Root $relocated -InstanceName 'real-qemu-img' -BaseId $baseId -QemuImgRunner $runner
        if ($resetValidation.BackingReference -cne $validated.BackingReference -or -not $reset.Replaced) {
            throw 'Real reset-safe replacement did not preserve the relocation-safe base relationship.'
        }
    }
    finally {
        if (Test-Path -LiteralPath $relocated) { Remove-Item -LiteralPath $relocated -Recurse -Force }
    }

    Write-Host ('EZVM005_REAL_QEMU_IMG_PASS=' + $baseId)
    Write-Host ('EZVM005_REAL_BACKING=' + $validated.BackingReference)
    Write-Host ('EZVM005_REAL_CHAIN_DEPTH=' + $validated.ChainDepth)
    Write-Host ('EZVM005_REAL_CHECK_HEALTHY=' + $check.Healthy)
    Write-Host 'EZVM005_WHPX=NOT-APPLICABLE: no guest execution is part of EZVM-005 qualification.'
}
finally {
    if (Test-Path -LiteralPath $synthetic) { Remove-Item -LiteralPath $synthetic -Recurse -Force }
}
