#requires -Version 5.1
Set-StrictMode -Version 2.0

$script:EzVmDefaultRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$script:EzVmVersion = (Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'EzVm.psd1')).PrivateData.EzVmVersion

# An explicit list prevents an unexpected file in this directory being executed on import.
foreach ($source in @('Paths.ps1', 'Json.ps1', 'Configuration.ps1', 'Process.ps1', 'Download.ps1', 'Qemu.ps1', 'Doctor.ps1', 'SourceImage.ps1', 'Cli.ps1')) {
    . (Join-Path $PSScriptRoot $source)
}

Export-ModuleMember -Function @(
    'Get-EzVmVersion', 'Get-EzVmRoot', 'Get-EzVmPaths', 'Get-EzVmConfiguration',
    'Read-EzVmJson', 'Write-EzVmJson', 'Invoke-EzVmProcess',
    'Get-EzVmFileDigest', 'Get-EzVmVerifiedArtifact',
    'Get-EzVmQemuManifest', 'Install-EzVmQemuRuntime', 'Get-EzVmManagedQemuStatus', 'Get-EzVmQemuToolPath',
    'Get-EzVmDoctorReport',
    'Get-EzVmSourceImageManifest', 'Invoke-EzVmSourceImageAcquire', 'Get-EzVmVerifiedSourceImage',
    'Invoke-EzVmCommand', 'Write-EzVmResult'
)
