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
    if ($tokens.Count -gt 0) { $command = $tokens[0].ToLowerInvariant() }
    if ($jsonCount -gt 1 -or $tokens.Count -gt 1 -or [string]::IsNullOrWhiteSpace($command)) {
        return New-EzVmCommandResult -Success $false -Command $command -ExitCode 2 -ErrorCode 'invalid_arguments' -Message 'Expected help or version with at most one -Json switch. Run .\ezvm.ps1 help for usage.'
    }
    if (@('help', 'version') -notcontains $command) {
        return New-EzVmCommandResult -Success $false -Command $command -ExitCode 2 -ErrorCode 'unknown_command' -Message "Command '$command' is unavailable. This foundation implements help and version; run .\ezvm.ps1 help for usage."
    }

    # Establish the current source root without loading user state or creating directories.
    $null = Get-EzVmRoot -Path $Root
    $version = Get-EzVmVersion
    switch ($command) {
        'version' {
            $data = [pscustomobject][ordered]@{ name = 'ezvm'; version = $version }
        }
        'help' {
            $data = [pscustomobject][ordered]@{
                name = 'ezvm'
                version = $version
                usage = '.\ezvm.ps1 <command> [-Json]'
                commands = @(
                    [pscustomobject]@{ name = 'help'; description = 'Show available commands and usage.' }
                    [pscustomobject]@{ name = 'version'; description = 'Show the control-plane version.' }
                )
                stage = 'Foundation: VM acquisition and lifecycle commands are scheduled in subsequent issues.'
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
        'help' {
            Write-Output ("ezvm $($Result.data.version)")
            Write-Output ('Portable QEMU + QCOW2 coding-agent environments for Windows.')
            Write-Output ('')
            Write-Output ("Usage: $($Result.data.usage)")
            Write-Output ('')
            Write-Output ('Commands:')
            foreach ($command in $Result.data.commands) {
                Write-Output (('  {0,-10} {1}' -f $command.name, $command.description))
            }
            Write-Output ('')
            Write-Output ('Use -Json for one structured result, including errors. Omitting the command shows this help.')
            Write-Output ($Result.data.stage)
        }
        default { throw "No human-readable formatter is registered for '$($Result.command)'. Add a formatter for this command." }
    }
}
