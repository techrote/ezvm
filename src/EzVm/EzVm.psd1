@{
    RootModule = 'EzVm.psm1'
    ModuleVersion = '0.0.0'
    GUID = '2e0b7e67-36f3-4e77-96c8-8d40296b7abd'
    Author = 'ezvm contributors'
    Description = 'Portable Windows QEMU environment manager: control-plane foundation.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Get-EzVmVersion',
        'Get-EzVmRoot',
        'Get-EzVmPaths',
        'Get-EzVmConfiguration',
        'Read-EzVmJson',
        'Write-EzVmJson',
        'Invoke-EzVmProcess',
        'Get-EzVmFileDigest',
        'Get-EzVmVerifiedArtifact',
        'Get-EzVmQemuManifest',
        'Install-EzVmQemuRuntime',
        'Get-EzVmManagedQemuStatus',
        'Get-EzVmQemuToolPath',
        'Get-EzVmDoctorReport',
        'Get-EzVmSourceImageManifest',
        'Invoke-EzVmSourceImageAcquire',
        'Get-EzVmVerifiedSourceImage',
        'Start-EzVmSeedServer',
        'Invoke-EzVmSeedServerPending',
        'Stop-EzVmSeedServer',
        'Get-EzVmBaseRecipe',
        'Get-EzVmBaseProvisioningDigest',
        'New-EzVmBaseSeedData',
        'New-EzVmBaseQemuArguments',
        'Invoke-EzVmBaseBuild',
        'Test-EzVmPreparedBase',
        'Get-EzVmInstanceStoragePaths',
        'Get-EzVmStorageRelativePath',
        'New-EzVmStorageLifecycleGuard',
        'Get-EzVmStorageImageInfo',
        'Get-EzVmStorageBackingChain',
        'Test-EzVmInstanceOverlay',
        'Test-EzVmInstanceStorage',
        'New-EzVmInstanceOverlay',
        'Test-EzVmStoppedImageIntegrity',
        'Reset-EzVmInstanceOverlayStorage',
        'Get-EzVmInstanceRuntimePaths',
        'New-EzVmInstanceIntent',
        'Get-EzVmInstanceIntent',
        'Get-EzVmArgumentFingerprint',
        'Get-EzVmRuntimeFirmwarePaths',
        'New-EzVmRuntimeQemuArguments',
        'Get-EzVmInstanceStatus',
        'Get-EzVmInstanceStorageLifecycleGuard',
        'Start-EzVmInstance',
        'Stop-EzVmInstance',
        'Invoke-EzVmCommand',
        'Write-EzVmResult'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{ EzVmVersion = '0.0.0-dev' }
}
