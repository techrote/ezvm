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

function New-EzVmCliArgumentError {
    param([string]$Command, [string]$Message, [string]$Code = 'invalid_arguments')
    return New-EzVmCommandResult -Success $false -Command $Command -ExitCode 2 -ErrorCode $Code -Message ($Message + ' Run .\ezvm.ps1 help for usage.')
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
    if ($jsonCount -gt 1) {
        return New-EzVmCliArgumentError -Command $(if ($tokens.Count -gt 0) { $tokens[0].ToLowerInvariant() } else { 'help' }) -Message 'The -Json switch may be supplied at most once.'
    }

    $command = 'help'
    $instanceName = $null
    if ($tokens.Count -gt 0) {
        $verb = $tokens[0].ToLowerInvariant()
        switch ($verb) {
            { $_ -in @('help', 'version', 'bootstrap', 'doctor') } {
                if ($tokens.Count -ne 1) {
                    return New-EzVmCliArgumentError -Command $verb -Message "Command '$verb' does not accept positional arguments."
                }
                $command = $verb
            }
            'base' {
                if ($tokens.Count -ne 2) {
                    return New-EzVmCliArgumentError -Command 'base' -Message 'The base command requires exactly one subcommand: acquire or build.'
                }
                $subcommand = $tokens[1].ToLowerInvariant()
                if ($subcommand -notin @('acquire', 'build')) {
                    return New-EzVmCliArgumentError -Command 'base' -Message "Unknown base subcommand '$subcommand'." -Code 'unknown_command'
                }
                $command = 'base ' + $subcommand
            }
            { $_ -in @('start', 'status', 'stop') } {
                if ($tokens.Count -ne 2) {
                    return New-EzVmCliArgumentError -Command $verb -Message "Command '$verb' requires exactly one instance name."
                }
                $instanceName = $tokens[1]
                try { Assert-EzVmStorageInstanceName -Name $instanceName }
                catch { return New-EzVmCliArgumentError -Command $verb -Message $_.Exception.Message }
                $command = $verb
            }
            default {
                return New-EzVmCliArgumentError -Command $verb -Message "Unknown command '$verb'." -Code 'unknown_command'
            }
        }
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
        'base build' {
            $data = Invoke-EzVmBaseBuild -Root $Root -Accelerator whpx
        }
        'status' {
            $data = Get-EzVmInstanceStatus -Root $Root -InstanceName $instanceName
        }
        'start' {
            $configuration = Get-EzVmConfiguration -Root $Root
            $data = Start-EzVmInstance -Root $Root -InstanceName $instanceName -Accelerator whpx -StartupTimeoutSeconds ([int]$configuration.timeouts.processSeconds)
        }
        'stop' {
            $configuration = Get-EzVmConfiguration -Root $Root
            $data = Stop-EzVmInstance -Root $Root -InstanceName $instanceName -ShutdownTimeoutSeconds ([int]$configuration.timeouts.processSeconds)
        }
        'help' {
            $data = [pscustomobject][ordered]@{
                name = 'ezvm'
                version = $version
                usage = '.\ezvm.ps1 <command> [arguments] [-Json]'
                commands = @(
                    [pscustomobject]@{ name = 'help'; description = 'Show available commands and usage.' }
                    [pscustomobject]@{ name = 'version'; description = 'Show the control-plane version.' }
                    [pscustomobject]@{ name = 'doctor'; description = 'Report Windows, WHPX, storage and managed-QEMU prerequisites.' }
                    [pscustomobject]@{ name = 'bootstrap'; description = 'Install the reviewed QEMU runtime into this ezvm root without system installation.' }
                    [pscustomobject]@{ name = 'base acquire'; description = 'Acquire and verify the pinned Ubuntu Noble amd64 source image.' }
                    [pscustomobject]@{ name = 'base build'; description = 'Build and publish an immutable prepared coding base using WHPX.' }
                    [pscustomobject]@{ name = 'status <name>'; description = 'Reconcile durable/runtime/process evidence and report instance lifecycle state.' }
                    [pscustomobject]@{ name = 'start <name>'; description = 'Validate storage and start an existing instance headlessly using WHPX.' }
                    [pscustomobject]@{ name = 'stop <name>'; description = 'Request graceful guest powerdown over host-local QMP and wait for exit.' }
                )
                stage = 'Portable QEMU, prepared bases, thin storage and headless start/status/stop are implemented; instance creation, SSH control and registry allocation follow.'
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
        'base build' {
            $verb = if ($Result.data.reused) { 'Verified existing' } else { 'Published' }
            Write-Output ("$verb prepared base $($Result.data.baseId)")
            Write-Output ("  image: $($Result.data.path)")
            Write-Output ("  manifest: $($Result.data.manifestPath)")
            Write-Output ("  SHA-256 $($Result.data.sha256)")
            Write-Output ("  accelerator: $($Result.data.accelerator)")
        }
        'status' {
            Write-Output ("$($Result.data.name): $($Result.data.state)")
            Write-Output ("  $($Result.data.reason)")
            if ($null -ne $Result.data.pid) { Write-Output ("  pid: $($Result.data.pid)") }
            if ($null -ne $Result.data.accelerator) { Write-Output ("  accelerator: $($Result.data.accelerator)") }
        }
        'start' {
            Write-Output ("Started $($Result.data.name)")
            Write-Output ("  state: $($Result.data.state)")
            Write-Output ("  pid: $($Result.data.pid)")
            Write-Output ("  accelerator: $($Result.data.accelerator)")
            Write-Output ("  serial log: $($Result.data.serialLog)")
            Write-Output ("  QEMU log: $($Result.data.qemuLog)")
        }
        'stop' {
            if ($Result.data.alreadyStopped) { Write-Output ("$($Result.data.name) is already stopped.") }
            else { Write-Output ("Stopped $($Result.data.name) gracefully.") }
        }
        'help' {
            Write-Output ("ezvm $($Result.data.version)")
            Write-Output ('Portable QEMU + QCOW2 coding-agent environments for Windows.')
            Write-Output ('')
            Write-Output ("Usage: $($Result.data.usage)")
            Write-Output ('')
            Write-Output ('Commands:')
            foreach ($item in $Result.data.commands) {
                Write-Output (('  {0,-18} {1}' -f $item.name, $item.description))
            }
            Write-Output ('')
            Write-Output ('Use -Json for one structured result, including errors. Omitting the command shows this help.')
            Write-Output ($Result.data.stage)
        }
        default { throw "No human-readable formatter is registered for '$($Result.command)'." }
    }
}
