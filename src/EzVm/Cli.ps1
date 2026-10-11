function Get-EzVmVersion {
    [CmdletBinding()]
    param()
    return $script:EzVmVersion
}

function New-EzVmCommandResult {
    param(
        [bool]$Success,
        [AllowNull()][string]$Command,
        [int]$ExitCode,
        [AllowNull()][object]$Data = $null,
        [string]$ErrorCode,
        [string]$Message
    )
    $errorDetail = $null
    if (-not $Success) {
        $errorDetail = [pscustomobject][ordered]@{ code = $ErrorCode; message = $Message }
    }
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        success = $Success
        command = $Command
        exitCode = $ExitCode
        data = $Data
        error = $errorDetail
    }
}

function Invoke-EzVmCommand {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][AllowEmptyString()][string[]]$Arguments = @(),
        [string]$Root = $script:EzVmDefaultRoot
    )

    $tokens = New-Object 'System.Collections.Generic.List[string]'
    $jsonCount = 0
    foreach ($argument in $Arguments) {
        if ($argument -ieq '-Json') { $jsonCount++; continue }
        $tokens.Add($argument)
    }

    $command = 'help'
    if ($tokens.Count -gt 0) {
        $command = (($tokens.ToArray() | ForEach-Object { $_.ToLowerInvariant() }) -join ' ')
    }
    $valid = @('help', 'version', 'bootstrap', 'doctor', 'base acquire')
    if ($jsonCount -gt 1 -or [string]::IsNullOrWhiteSpace($command) -or $valid -cnotcontains $command) {
        $errorCode = if ($tokens.Count -gt 0 -and $valid -cnotcontains $command) { 'unknown_command' } else { 'invalid_arguments' }
        $errorCommand = 'help'
        if ($tokens.Count -gt 0) { $errorCommand = $tokens[0].ToLowerInvariant() }
        return New-EzVmCommandResult -Success $false -Command $errorCommand -ExitCode 2 -ErrorCode $errorCode -Message "Command or arguments '$command' are unavailable. Run .\ezvm.ps1 help for usage."
    }

    $null = Get-EzVmRoot -Path $Root
    $version = Get-EzVmVersion
    switch ($command) {
        'version' {
            $data = [pscustomobject][ordered]@{ name = 'ezvm'; version = $version }
        }
        'bootstrap' {
            $data = Install-EzVmQemuRuntime -Root $Root
        }
        'doctor' {
            $data = Get-EzVmDoctorReport -Root $Root
        }
        'base acquire' {
            $data = Invoke-EzVmSourceImageAcquire -Root $Root
        }
        'help' {
            $data = [pscustomobject][ordered]@{
                name = 'ezvm'
                version = $version
                usage = '.\ezvm.ps1 <command> [-Json]'
                commands = @(
                    [pscustomobject]@{ name = 'help'; description = 'Show available commands and usage.' }
                    [pscustomobject]@{ name = 'version'; description = 'Show the control-plane version.' }
                    [pscustomobject]@{ name = 'doctor'; description = 'Report Windows, WHPX, storage and managed-QEMU prerequisites.' }
                    [pscustomobject]@{ name = 'bootstrap'; description = 'Install the reviewed QEMU runtime into this ezvm root without system installation.' }
                    [pscustomobject]@{ name = 'base acquire'; description = 'Acquire and verify the pinned Ubuntu Noble amd64 source image.' }
                )
                stage = 'Portable QEMU bootstrap, host preflight and verified Ubuntu source acquisition are implemented; prepared-base and VM lifecycle work is delivered by later issues.'
            }
        }
    }
    return New-EzVmCommandResult -Success $true -Command $command -ExitCode 0 -Data $data
}

function Write-EzVmResult {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Result, [switch]$Json)

    if ($Json) {
        Write-Output ($Result | ConvertTo-Json -Depth 16 -Compress)
        return
    }
    if (-not $Result.success) {
        [Console]::Error.WriteLine("ezvm: $($Result.error.message)")
        return
    }
    switch ($Result.command) {
        'version' { Write-Output ("ezvm $($Result.data.version)") }
        'bootstrap' {
            $verb = if ($Result.data.idempotent) { 'Verified existing' } else { 'Installed' }
            Write-Output ("$verb managed QEMU $($Result.data.version) (provider build $($Result.data.providerBuild))")
            Write-Output ("  runtime: $($Result.data.runtimePath)")
            Write-Output ("  qemu-system-x86_64: $($Result.data.qemuSystem)")
            Write-Output ("  qemu-img: $($Result.data.qemuImg)")
        }
        'doctor' {
            Write-Output ("ezvm doctor: $($Result.data.status)")
            foreach ($check in $Result.data.checks) {
                Write-Output (('  {0,-28} {1,-30} {2}' -f $check.name, $check.status, $check.message))
                if (-not [string]::IsNullOrWhiteSpace($check.remediation)) {
                    Write-Output ("    remediation: $($check.remediation)")
                }
            }
            Write-Output ('  WHPX execution tested: false (doctor reports prerequisites only).')
        }
        'base acquire' {
            $verb = if ($Result.data.downloaded) { 'Acquired' } else { 'Verified cached' }
            Write-Output ("$verb Ubuntu source image:")
            Write-Output ("  $($Result.data.path)")
            Write-Output ("  SHA-256 $($Result.data.sha256)")
            Write-Output ("  publication $($Result.data.publication)")
        }
        'help' {
            Write-Output ("ezvm $($Result.data.version)")
            Write-Output ('Portable QEMU + QCOW2 coding-agent environments for Windows.')
            Write-Output ('')
            Write-Output ("Usage: $($Result.data.usage)")
            Write-Output ('')
            Write-Output ('Commands:')
            foreach ($item in $Result.data.commands) {
                Write-Output (('  {0,-10} {1}' -f $item.name, $item.description))
            }
            Write-Output ('')
            Write-Output ('Use -Json for one structured result, including errors. Omitting the command shows this help.')
            Write-Output ($Result.data.stage)
        }
        default { throw "No human-readable formatter is registered for '$($Result.command)'." }
    }
}
