#requires -Version 5.1
# Deliberately parse $args ourselves so invalid switches also get stable exit/JSON output.
# Legacy module autoload emits progress records even for help/version. Suppress
# those at the source before any cmdlet import can contaminate captured output.
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'
$jsonRequested = @($args | Where-Object { $_ -ieq '-Json' }).Count -gt 0

try {
    Import-Module (Join-Path $PSScriptRoot 'src/EzVm/EzVm.psd1') -Force -ErrorAction Stop
    $result = Invoke-EzVmCommand -Arguments $args -Root $PSScriptRoot
    Write-EzVmResult -Result $result -Json:$jsonRequested
    exit $result.exitCode
}
catch {
    # This fallback also covers a broken/missing module. Never mix diagnostics into JSON.
    $message = "ezvm could not complete the command: $($_.Exception.Message) Restore a complete checkout or correct the reported configuration, then retry."
    if ($jsonRequested) {
        $failure = [ordered]@{
            schemaVersion = 1
            success = $false
            command = $null
            exitCode = 1
            data = $null
            error = [ordered]@{ code = 'execution_failed'; message = $message }
        }
        Write-Output ($failure | ConvertTo-Json -Depth 8 -Compress)
    }
    else {
        [Console]::Error.WriteLine($message)
    }
    exit 1
}
