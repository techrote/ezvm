#requires -Version 5.1
Set-StrictMode -Version 2.0

$script:EzVmDefaultRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$script:EzVmVersion = (Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'EzVm.psd1')).PrivateData.EzVmVersion

# An explicit list prevents an unexpected file in this directory being executed on import.
foreach ($source in @('Paths.ps1', 'Json.ps1', 'Configuration.ps1', 'Process.ps1', 'Download.ps1', 'Qemu.ps1', 'Doctor.ps1', 'SourceImage.ps1', 'SeedServer.ps1', 'BaseRecipe.ps1', 'BaseBuilder.ps1', 'Storage.ps1', 'Runtime.ps1', 'Registry.ps1', 'Profiles.ps1', 'Ssh.ps1', 'Cli.ps1')) {
    . (Join-Path $PSScriptRoot $source)
}

Export-ModuleMember -Function @(
    'Get-EzVmVersion', 'Get-EzVmRoot', 'Get-EzVmPaths', 'Get-EzVmConfiguration',
    'Read-EzVmJson', 'Write-EzVmJson', 'Invoke-EzVmProcess',
    'Get-EzVmFileDigest', 'Get-EzVmVerifiedArtifact',
    'Get-EzVmQemuManifest', 'Install-EzVmQemuRuntime', 'Get-EzVmManagedQemuStatus', 'Get-EzVmQemuToolPath',
    'Get-EzVmDoctorReport',
    'Get-EzVmSourceImageManifest', 'Invoke-EzVmSourceImageAcquire', 'Get-EzVmVerifiedSourceImage',
    'Start-EzVmSeedServer', 'Invoke-EzVmSeedServerPending', 'Stop-EzVmSeedServer',
    'Get-EzVmBaseRecipe', 'Get-EzVmBaseProvisioningDigest', 'New-EzVmBaseSeedData', 'New-EzVmBaseQemuArguments',
    'Invoke-EzVmBaseBuild', 'Test-EzVmPreparedBase',
    'Get-EzVmInstanceStoragePaths', 'Get-EzVmStorageRelativePath', 'New-EzVmStorageLifecycleGuard',
    'Get-EzVmStorageImageInfo', 'Get-EzVmStorageBackingChain', 'Test-EzVmInstanceOverlay', 'Test-EzVmInstanceStorage',
    'New-EzVmInstanceOverlay', 'Test-EzVmStoppedImageIntegrity', 'Reset-EzVmInstanceOverlayStorage',
    'Get-EzVmInstanceRuntimePaths', 'New-EzVmInstanceIntent', 'Get-EzVmInstanceIntent',
    'Resolve-EzVmInstanceResources', 'Get-EzVmPreparedBaseSelection', 'Get-EzVmInstanceRegistry',
    'Get-EzVmAllocatedSshPorts', 'Assert-EzVmInstanceSshPortReservation', 'New-EzVmManagedInstance',
    'Get-EzVmManagedInstanceStatus', 'Get-EzVmManagedInstanceList',
    'Get-EzVmArgumentFingerprint', 'Get-EzVmRuntimeFirmwarePaths', 'New-EzVmRuntimeQemuArguments',
    'Get-EzVmInstanceStatus', 'Get-EzVmInstanceStorageLifecycleGuard', 'Start-EzVmInstance', 'Stop-EzVmInstance',
    'Get-EzVmOpenSshTools', 'Get-EzVmSshPaths', 'Get-EzVmControllerSshIdentity',
    'Get-EzVmAvailableSshPort', 'Get-EzVmCodingProfile', 'New-EzVmInstanceSeedData', 'New-EzVmSshCommandArguments', 'New-EzVmScpCommandArguments',
    'ConvertFrom-EzVmReadinessProbe', 'Get-EzVmSshAccessState', 'Start-EzVmReadyInstance',
    'Invoke-EzVmSsh', 'Invoke-EzVmExec', 'Invoke-EzVmCopyToGuest', 'Invoke-EzVmCopyFromGuest',
    'Invoke-EzVmCommand', 'Write-EzVmResult'
)
