function ConvertTo-EzVmWindowsArgument {
    param([AllowEmptyString()][string] $Argument)

    # Windows CRT parsing: backslashes before a quote must be doubled, plus one
    # to escape the quote; trailing backslashes must be doubled before our closing
    # quote. Always quoting also preserves an empty token. FileName is separate.
    # https://learn.microsoft.com/en-us/cpp/c-language/parsing-c-command-line-arguments
    $builder = New-Object System.Text.StringBuilder
    $null = $builder.Append([char] 34)
    $backslashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq [char] 92) {
            $backslashes++
            continue
        }
        if ($character -eq [char] 34) {
            $null = $builder.Append([char] 92, (2 * $backslashes + 1))
            $null = $builder.Append([char] 34)
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            $null = $builder.Append([char] 92, $backslashes)
            $backslashes = 0
        }
        $null = $builder.Append($character)
    }
    if ($backslashes -gt 0) {
        $null = $builder.Append([char] 92, (2 * $backslashes))
    }
    $null = $builder.Append([char] 34)
    return $builder.ToString()
}

function Resolve-EzVmProcessFileSystemPath {
    param([Parameter(Mandatory = $true)][string] $Path)

    $provider = $null
    $drive = $null
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $Path, [ref] $provider, [ref] $drive)
    if ($provider.Name -ne 'FileSystem') {
        throw "Process paths must use the filesystem provider: '$Path'."
    }
    return $resolved
}

function Stop-EzVmTimedOutProcess {
    param([System.Diagnostics.Process] $Process)

    # Kill(bool) is absent from .NET Framework. Only the direct child can be
    # terminated there; callers must not rely on this helper to own a VM tree.
    try {
        if ($Process.HasExited) {
            return 'The child exited, but its output streams did not finish; check for descendants holding inherited stream handles.'
        }
        $treeKill = $Process.GetType().GetMethod('Kill', [type[]] @([bool]))
        if ($null -ne $treeKill) { $Process.Kill($true) }
        else { $Process.Kill() }
        if ($Process.WaitForExit(2000)) {
            return 'The child process was terminated.'
        }
        return "Termination was requested but could not be confirmed; inspect process ID $($Process.Id)."
    }
    catch {
        return "Could not confirm child termination; inspect process ID $($Process.Id). $($_.Exception.Message)"
    }
}

function Start-EzVmProcessWithoutInputPreamble {
    param(
        [System.Diagnostics.Process] $Process,
        [int] $TimeoutMilliseconds,
        [ref] $Started
    )

    if ($null -ne $Process.StartInfo.PSObject.Properties['StandardInputEncoding']) {
        $Process.StartInfo.StandardInputEncoding = New-Object System.Text.UTF8Encoding($false)
        $Started.Value = $Process.Start()
        return
    }

    # .NET Framework creates its stdin StreamWriter from Console.InputEncoding
    # and enables AutoFlush inside Start(), which can send a BOM before we can
    # close stdin. Use the same code page without its preamble during Start only.
    # Serialize cooperating Framework calls across runspaces in this process so
    # they cannot observe or restore each other's temporary encoding.
    $mutex = New-Object System.Threading.Mutex($false, ('Local\ezvm-stdin-encoding-' + $PID))
    $lockTaken = $false
    $restoreEncoding = $false
    $restoreReader = $false
    $originalEncoding = $null
    $originalReader = $null
    try {
        try { $lockTaken = $mutex.WaitOne($TimeoutMilliseconds) }
        catch [System.Threading.AbandonedMutexException] { $lockTaken = $true }
        if (-not $lockTaken) {
            throw 'Timed out waiting for another ezvm process launch to finish configuring standard input. Retry the command.'
        }
        $originalEncoding = [Console]::InputEncoding
        if ($originalEncoding.GetPreamble().Length -gt 0) {
            $encoding = switch ($originalEncoding.CodePage) {
                65001 { New-Object System.Text.UTF8Encoding($false) }
                1200 { New-Object System.Text.UnicodeEncoding($false, $false) }
                1201 { New-Object System.Text.UnicodeEncoding($true, $false) }
                12000 { New-Object System.Text.UTF32Encoding($false, $false) }
                12001 { New-Object System.Text.UTF32Encoding($true, $false) }
                default { throw 'The console input encoding has an unsupported preamble. Use current PowerShell 7 or configure a standard encoding before retrying.' }
            }
            $encoding = $encoding.Clone()
            $encoding.EncoderFallback = $originalEncoding.EncoderFallback
            $encoding.DecoderFallback = $originalEncoding.DecoderFallback
            # Setting InputEncoding clears Console.In's cached reader. Preserve
            # it, including a caller-supplied reader and any buffered input.
            $originalReader = [Console]::In
            $restoreReader = $true
            try { [Console]::InputEncoding = $encoding }
            catch {
                throw [System.InvalidOperationException]::new(
                    'This Windows PowerShell host cannot configure standard input without a preamble. Use current PowerShell 7, or a console that permits input-encoding updates.',
                    $_.Exception)
            }
            $restoreEncoding = $true
        }
        # Keep the caller informed even if restoring the encoding later fails,
        # so its finally block can still terminate a successfully started child.
        $Started.Value = $Process.Start()
    }
    finally {
        try {
            try {
                if ($restoreEncoding) { [Console]::InputEncoding = $originalEncoding }
            }
            finally {
                if ($restoreReader) { [Console]::SetIn($originalReader) }
            }
        }
        finally {
            if ($lockTaken) { $mutex.ReleaseMutex() }
            $mutex.Dispose()
        }
    }
}

function Invoke-EzVmProcess {
    <#
    .SYNOPSIS
    Runs a non-interactive executable without a shell and captures its result.
    .DESCRIPTION
    Pass one unescaped string for each argument. Native ArgumentList is used when
    available; Windows PowerShell 5.1 uses the Windows CRT quoting contract. Tools
    with a bespoke Windows command-line parser may require a dedicated adapter.
    Standard input is closed and output is decoded as UTF-8. Both output streams
    are drained concurrently. A non-zero exit returns the captured result unless
    ThrowOnError is set; a launch failure or timeout always throws. Timeouts have
    a bounded two-second termination grace. On .NET Framework only the direct
    child can be killed. Exception Data includes captured output on non-zero exit.
    Framework launches briefly use the same console input code page without a
    preamble and restore its encoding before returning. ezvm launches serialize
    this adjustment across runspaces; unrelated code must not change the console
    encoding or input reader concurrently. Hosts that cannot update a required
    encoding fail clearly and can use current PowerShell 7 without this adjustment.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $FilePath,
        [AllowEmptyCollection()][AllowEmptyString()][string[]] $ArgumentList = @(),
        [string] $WorkingDirectory,
        [ValidateRange(1, 2147483)][int] $TimeoutSeconds = 60,
        [switch] $ThrowOnError
    )

    if ([string]::IsNullOrWhiteSpace($FilePath) -or ($FilePath.IndexOf([char] 0) -ge 0)) {
        throw 'Supply an executable filename or path without NUL characters.'
    }
    if ($null -eq $ArgumentList) { $ArgumentList = @() }
    foreach ($argument in $ArgumentList) {
        if ($argument.IndexOf([char] 0) -ge 0) {
            throw 'Process arguments cannot contain NUL characters. Supply each argument as a separate unescaped string.'
        }
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    if ([System.IO.Path]::IsPathRooted($FilePath) -or
        ($FilePath.IndexOf('/') -ge 0) -or ($FilePath.IndexOf('\') -ge 0)) {
        $startInfo.FileName = Resolve-EzVmProcessFileSystemPath -Path $FilePath
    }
    if ($PSBoundParameters.ContainsKey('WorkingDirectory')) {
        if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            throw 'WorkingDirectory must name an existing filesystem directory.'
        }
        $startInfo.WorkingDirectory = Resolve-EzVmProcessFileSystemPath -Path $WorkingDirectory
    }
    else {
        $startInfo.WorkingDirectory = Resolve-EzVmProcessFileSystemPath -Path '.'
    }
    if (-not [System.IO.Directory]::Exists($startInfo.WorkingDirectory)) {
        throw "Process working directory '$($startInfo.WorkingDirectory)' does not exist. Create it or select an existing directory."
    }
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
    $finished = $false
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $timeoutMilliseconds = $TimeoutSeconds * 1000
    try {
        try {
            $remaining = [int] [Math]::Max(0, $timeoutMilliseconds - $clock.ElapsedMilliseconds)
            Start-EzVmProcessWithoutInputPreamble -Process $process -TimeoutMilliseconds $remaining -Started ([ref] $started)
            if (-not $started) { throw 'The operating system did not create a child process.' }
        }
        catch {
            throw [System.InvalidOperationException]::new(
                "Could not start executable '$FilePath'. Check its path and permissions, and install or bootstrap the required tool. $($_.Exception.Message)",
                $_.Exception)
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        # Close the pipe itself: no characters or encoding preamble are input.
        $process.StandardInput.BaseStream.Close()
        $remaining = [int] [Math]::Max(0, $timeoutMilliseconds - $clock.ElapsedMilliseconds)
        $exited = $process.WaitForExit($remaining)
        $drained = $false
        if ($exited) {
            $remaining = [int] [Math]::Max(0, $timeoutMilliseconds - $clock.ElapsedMilliseconds)
            $drained = [System.Threading.Tasks.Task]::WaitAll(
                [System.Threading.Tasks.Task[]] @($stdoutTask, $stderrTask), $remaining)
        }
        if ((-not $exited) -or (-not $drained)) {
            $termination = Stop-EzVmTimedOutProcess -Process $process
            $finished = $true
            throw [System.TimeoutException]::new(
                "Executable '$FilePath' exceeded its $TimeoutSeconds second timeout. $termination Check the tool or increase TimeoutSeconds for an expected long operation.")
        }

        $finished = $true
        $result = [pscustomobject] @{
            ExitCode = $process.ExitCode
            StdOut = $stdoutTask.Result
            StdErr = $stderrTask.Result
        }
        if ($ThrowOnError -and ($result.ExitCode -ne 0)) {
            $detail = $result.StdErr.Trim()
            if ([string]::IsNullOrWhiteSpace($detail)) { $detail = $result.StdOut.Trim() }
            if ($detail.Length -gt 2048) { $detail = $detail.Substring(0, 2048) + '...' }
            $exception = [System.InvalidOperationException]::new(
                "Executable '$FilePath' exited with code $($result.ExitCode). Inspect the tool output and correct the reported failure. $detail")
            $exception.Data['ExitCode'] = $result.ExitCode
            $exception.Data['StdOut'] = $result.StdOut
            $exception.Data['StdErr'] = $result.StdErr
            throw $exception
        }
        return $result
    }
    finally {
        if ($started -and (-not $finished)) {
            $null = Stop-EzVmTimedOutProcess -Process $process
        }
        $clock.Stop()
        $process.Dispose()
    }
}
