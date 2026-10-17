#requires -Version 5.1
# Lightweight launch helpers only; dot-sourcing this file creates no account or process.
function Resolve-PrivateAclFixtureGit {
    $application = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $path = $application.Source
    if ($path -isnot [string] -or -not [IO.Path]::IsPathRooted($path) -or
        -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'The first Git application is not an existing absolute executable path.'
    }
    return $path
}

function Invoke-PrivateAclFixtureGit {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Operation
    )
    if (-not [IO.Path]::IsPathRooted($Executable) -or -not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
        throw 'The fixture Git executable is missing or is not an absolute file path.'
    }
    # Git writes ordinary clone/checkout progress to stderr. Windows PowerShell
    # can promote that output to NativeCommandError under Stop. Retain both
    # output streams, and decide native success from the explicit exit code.
    $previousPreference = $ErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    # Native commands update the global automatic variable. A local variable
    # would shadow the result and leave an unavailable/stale exit status.
    $global:LASTEXITCODE = $null
    try {
        $ErrorActionPreference = 'Continue'
        & $Executable @Arguments
        $exitCode = $global:LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    if ($exitCode -isnot [int] -or $exitCode -ne 0) {
        throw ($Operation + ' failed with exit code ' + $exitCode + '; inspect the retained native output.')
    }
}

function Wait-PrivateAclFixtureChild {
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Receipt,
        [ValidateRange(1, 600000)][int]$TimeoutMilliseconds = 600000
    )
    # Start-Process on Windows PowerShell returns a Process opened by ID. Force
    # its handle to be retained immediately, before waiting; otherwise ExitCode
    # can be unavailable after a short-lived child exits. Explicit getter calls
    # propagate exceptions that PowerShell property access can hide as $null.
    $processHandle = $Process.get_Handle()
    if ($processHandle -isnot [IntPtr] -or $processHandle -eq [IntPtr]::Zero -or $processHandle -eq [IntPtr](-1)) {
        throw 'Cannot retain the owned standard-user child process handle.'
    }
    if (-not $Process.WaitForExit($TimeoutMilliseconds)) {
        # This retained Process owns this one child. Never reacquire it by PID.
        $Process.Kill()
        $Receipt.childExited = $Process.WaitForExit(5000)
        throw 'Standard-user ACL qualification exceeded its ten-minute wall.'
    }
    $Receipt.childExited = $true
    $exitCode = $Process.get_ExitCode()
    if ($exitCode -isnot [int]) { throw 'The exited standard-user child did not provide a numeric exit code.' }
    $Receipt.childExitCode = $exitCode
}
