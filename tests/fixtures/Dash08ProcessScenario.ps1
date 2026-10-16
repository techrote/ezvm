function New-EzVmDash08NativeFixture {
    param([string]$Directory, [string]$Name = 'Dash08VmLifetime')
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    $source = Join-Path $script:EzVmRepositoryRoot ('tests/fixtures/' + $Name + '.cs')
    $fixture = Join-Path $Directory ($Name + ' with spaces.exe')
    $null = Invoke-EzVmProcess -FilePath $compiler -ArgumentList @('/nologo', '/target:exe', ('/out:' + $fixture), $source) -ThrowOnError
    return $fixture
}

function Read-EzVmDash08SharedText {
    param([string]$Path)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $reader = New-Object IO.StreamReader($stream, [Text.UTF8Encoding]::new($false))
    try { return $reader.ReadToEnd() }
    finally { $reader.Dispose(); $stream.Dispose() }
}

function Invoke-EzVmDash08ProcessScenario {
    param([ValidateSet('Current', 'Legacy', 'Interrupted')][string]$Mode = 'Current', [string[]]$Tokens = @())
    $directory = New-EzVmTestDirectory -Prefix ('dash08 ' + [char]0x03bb + ' ' + $Mode)
    $parent = $null
    $child = $null
    $childVerified = $false
    $childStopped = $false
    $result = $null
    try {
        $fixture = New-EzVmDash08NativeFixture -Directory $directory
        $module = (Join-Path $script:EzVmRepositoryRoot 'src/EzVm/EzVm.psd1').Replace("'", "''")
        $encodedTokens = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject @($Tokens) -Compress)))
        $command = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Import-Module '__MODULE__' -Force
$directory = '__DIRECTORY__'
$fixture = '__FIXTURE__'
$tokens = @([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__TOKENS__')) | ConvertFrom-Json)
$arguments = @($directory) + $tokens
# An unrelated inheritable handle must not be copied into the long-lived child.
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class Dash08Inheritance { [DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags); }'
$sentinel = [IO.File]::Open((Join-Path $directory 'unrelated.lock'), [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
if (-not [Dash08Inheritance]::SetHandleInformation($sentinel.SafeFileHandle.DangerousGetHandle(), 1, 1)) { throw 'Could not prepare unrelated inheritable fixture handle.' }
try {
    & (Get-Module EzVm) {
        param($fixture, $directory, $arguments)
        if ('__MODE__' -eq 'Legacy') {
            # Retained negative control: the exact former launch mechanism.
            $start = New-Object Diagnostics.ProcessStartInfo
            $start.FileName = $fixture
            $start.WorkingDirectory = $directory
            $start.UseShellExecute = $false
            $start.CreateNoWindow = $true
            $quoted = @($arguments | ForEach-Object { ConvertTo-EzVmWindowsArgument -Argument $_ })
            $start.Arguments = [string]::Join(' ', [string[]]$quoted)
            $process = New-Object Diagnostics.Process
            $process.StartInfo = $start
            try { if (-not $process.Start()) { throw 'Legacy fixture failed to launch.' } }
            finally { $process.Dispose() }
        } else {
            $launch = Start-EzVmRuntimeProcess -FilePath $fixture -ArgumentList $arguments -WorkingDirectory $directory -StandardOutputPath (Join-Path $directory 'stdout.log') -StandardErrorPath (Join-Path $directory 'stderr.log')
            $launch.Process.Dispose()
        }
    } $fixture $directory $arguments
    [IO.File]::WriteAllText((Join-Path $directory 'caller.ready'), 'ready')
    if ('__MODE__' -eq 'Interrupted') { Start-Sleep -Seconds 30 }
    [Console]::Out.WriteLine('{"callerReturned":true}')
} finally { $sentinel.Dispose() }
'@
        $command = $command.Replace('__MODULE__', $module).Replace('__DIRECTORY__', $directory.Replace("'", "''")).Replace('__FIXTURE__', $fixture.Replace("'", "''")).Replace('__TOKENS__', $encodedTokens).Replace('__MODE__', $Mode)
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = Join-Path $PSHOME $(if ($PSVersionTable.PSVersion.Major -eq 5) { 'powershell.exe' } else { 'pwsh.exe' })
        $start.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $start.WorkingDirectory = $directory
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardInput = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $parent = New-Object Diagnostics.Process
        $parent.StartInfo = $start
        $clock = [Diagnostics.Stopwatch]::StartNew()
        if (-not $parent.Start()) { throw 'Could not start the capture fixture caller.' }
        $stdout = $parent.StandardOutput.ReadToEndAsync()
        $stderr = $parent.StandardError.ReadToEndAsync()
        $parent.StandardInput.BaseStream.Close()
        if ($Mode -eq 'Interrupted') {
            while (-not [IO.File]::Exists((Join-Path $directory 'caller.ready')) -and -not $parent.HasExited -and $clock.Elapsed.TotalSeconds -lt 15) { Start-Sleep -Milliseconds 20 }
            if (-not [IO.File]::Exists((Join-Path $directory 'caller.ready'))) { throw 'Caller did not reach the owned interruption point.' }
            $parent.Kill() # exactly the caller this harness created, not its child/tree
        }
        if (-not $parent.WaitForExit(15000)) { throw 'Capture fixture caller exceeded its 15-second wait bound.' }
        if ($Mode -ne 'Interrupted' -and $parent.ExitCode -ne 0) {
            if ($stderr.Wait(1000)) { throw ('Capture caller failed: ' + $stderr.Result) }
            throw ('Capture caller failed with exit ' + $parent.ExitCode)
        }
        $drained = [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout, $stderr), 1000)
        $identity = [IO.File]::ReadAllLines((Join-Path $directory 'child.identity'))
        $child = [Diagnostics.Process]::GetProcessById([int]$identity[0])
        $null = $child.Handle # cache the exact handle before later cleanup
        if ($child.StartTime.ToUniversalTime().Ticks -ne [long]$identity[1] -or $child.MainModule.FileName -cne $fixture) { throw 'Fixture ownership changed; refusing process action.' }
        $childVerified = $true
        $alive = -not $child.HasExited
        $heartbeatPath = Join-Path $directory 'heartbeat'
        $before = (Get-Item -LiteralPath $heartbeatPath).Length
        Start-Sleep -Milliseconds 350
        $after = (Get-Item -LiteralPath $heartbeatPath).Length
        $lockReleased = $false
        try {
            $lock = [IO.File]::Open((Join-Path $directory 'unrelated.lock'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $lock.Dispose(); $lockReleased = $true
        } catch [IO.IOException] { }
        $stdoutText = ''; $stderrText = ''; $inputByte = $null
        if ($Mode -ne 'Legacy') {
            $stdoutText = Read-EzVmDash08SharedText (Join-Path $directory 'stdout.log')
            $stderrText = Read-EzVmDash08SharedText (Join-Path $directory 'stderr.log')
            if ($Tokens -ccontains '--read-stdin') { $inputByte = [int](Read-EzVmDash08SharedText (Join-Path $directory 'stdin-first-byte')) }
        }
        $observed = @([IO.File]::ReadAllLines((Join-Path $directory 'arguments')))
        $decoded = @()
        for ($index = 1; $index -lt $observed.Count; $index++) { $decoded += [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($observed[$index])) }
        [IO.File]::WriteAllText((Join-Path $directory 'stop'), 'stop only the fixture rooted here')
        $childStopped = $child.WaitForExit(5000)
        if (-not $childStopped) { throw 'Simulated VM did not honor its own stop marker.' }
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout, $stderr), 5000)) { throw 'Capture did not close after fixture shutdown.' }
        $result = [pscustomobject]@{
            Mode = $Mode; ParentExited = $true; CapturedOutputDrained = $drained
            FixtureSurvivedParent = $alive; HeartbeatContinued = ($after -gt $before)
            UnrelatedHandleReleased = $lockReleased; FixtureStopped = $childStopped
            FixtureExitCode = $child.ExitCode; CallerOutput = $stdout.Result
            CallerError = $stderr.Result; NativeStdout = $stdoutText; NativeStderr = $stderrText
            StdinFirstByte = $inputByte; Tokens = $decoded; DeclaredTokenCount = [int]$observed[0]
            ElapsedMilliseconds = $clock.ElapsedMilliseconds
        }
        return $result
    }
    finally {
        [IO.File]::WriteAllText((Join-Path $directory 'stop'), 'stop')
        if ($null -ne $parent) {
            if (-not $parent.HasExited) { $parent.Kill(); [void]$parent.WaitForExit(3000) }
            $parent.Dispose()
        }
        if ($null -ne $child) {
            if ($childVerified -and -not $child.HasExited) {
                if (-not $child.WaitForExit(5000)) { $child.Kill(); [void]$child.WaitForExit(2000) }
            }
            $childStopped = $childVerified -and $child.HasExited
            $child.Dispose()
        }
        if ($childStopped) { Remove-EzVmTestDirectory -Path $directory }
        # A failed/unverified launch retains its isolated directory until the
        # fixture's hard lifetime expires. No guessed PID or unrelated file cleanup.
    }
}
