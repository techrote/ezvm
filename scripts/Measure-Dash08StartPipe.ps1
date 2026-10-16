#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2.0
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'This reproduction requires Windows.' }
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$directory = Join-Path ([IO.Path]::GetTempPath()) ('ezvm dash08 pipe ' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($directory)
[void][IO.Directory]::CreateDirectory($OutputDirectory)
Import-Module (Join-Path $root 'src/EzVm/EzVm.psd1') -Force
$receipt = [ordered]@{
    schemaVersion = 1
    kind = 'DASH-08 baseline pipe reproduction; not acceptance'
    sourceRevision = (git -C $root rev-parse HEAD).Trim()
    sourceTree = (git -C $root rev-parse 'HEAD^{tree}').Trim()
    runtimeSourceSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $root 'src/EzVm/Runtime.ps1')).Hash.ToLowerInvariant()
    powerShell = $PSVersionTable.PSVersion.ToString()
    os = [Environment]::OSVersion.ToString()
    startedAt = [DateTime]::UtcNow.ToString('o')
    parentExited = $false
    outputDrainedBeforeFixtureStop = $false
    fixtureSurvivedParent = $false
    fixtureStopped = $false
    result = 'FAIL'
    error = $null
    T04 = 'SKIP: no standard-user desktop or WHPX integration; only disposable native process boundary'
}
$parent = $null
$child = $null
try {
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    $fixture = Join-Path $directory 'simulated vm.exe'
    $null = Invoke-EzVmProcess -FilePath $compiler -ArgumentList @('/nologo', '/target:exe', ('/out:' + $fixture), (Join-Path $root 'tests/fixtures/Dash08VmLifetime.cs')) -ThrowOnError
    $quotedModule = (Join-Path $root 'src/EzVm/EzVm.psd1').Replace("'", "''")
    $quotedFixture = $fixture.Replace("'", "''")
    $quotedDirectory = $directory.Replace("'", "''")
    $command = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Import-Module '__MODULE__' -Force
& (Get-Module EzVm) {
    $launch = Start-EzVmRuntimeProcess -FilePath '__FIXTURE__' -ArgumentList @('__DIRECTORY__') -WorkingDirectory '__DIRECTORY__'
    $launch.Process.Dispose()
}
[Console]::Out.WriteLine('{"callerReturned":true}')
'@
    $command = $command.Replace('__MODULE__', $quotedModule).Replace('__FIXTURE__', $quotedFixture).Replace('__DIRECTORY__', $quotedDirectory)
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path $PSHOME $(if ($PSVersionTable.PSVersion.Major -eq 5) { 'powershell.exe' } else { 'pwsh.exe' })
    $start.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $start.WorkingDirectory = $directory
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $parent = New-Object Diagnostics.Process
    $parent.StartInfo = $start
    if (-not $parent.Start()) { throw 'Could not start the owned capture caller.' }
    $stdout = $parent.StandardOutput.ReadToEndAsync()
    $stderr = $parent.StandardError.ReadToEndAsync()
    $receipt.parentExited = $parent.WaitForExit(12000)
    if (-not $receipt.parentExited) { throw 'The fixture caller did not exit within 12 seconds.' }
    if ($parent.ExitCode -ne 0) { throw ('The fixture caller failed with exit ' + $parent.ExitCode) }
    $receipt.outputDrainedBeforeFixtureStop = [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout, $stderr), 1000)
    $identityPath = Join-Path $directory 'child.identity'
    if (-not [IO.File]::Exists($identityPath)) { throw 'The fixture did not publish process identity.' }
    $identity = [IO.File]::ReadAllLines($identityPath)
    $child = [Diagnostics.Process]::GetProcessById([int]$identity[0])
    if ($child.StartTime.ToUniversalTime().Ticks -ne [long]$identity[1]) { throw 'Fixture process identity changed; refusing process action.' }
    $receipt.fixtureSurvivedParent = -not $child.HasExited
    if (-not $receipt.fixtureSurvivedParent) { throw 'The bounded simulated VM did not survive caller exit.' }
    [IO.File]::WriteAllText((Join-Path $directory 'stop'), 'stop the fixture owned by this directory')
    $receipt.fixtureStopped = $child.WaitForExit(5000)
    if (-not $receipt.fixtureStopped) { throw 'The fixture did not honor its own stop marker.' }
    if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout, $stderr), 5000)) { throw 'Capture did not drain after fixture exit.' }
    $receipt.result = if ($receipt.outputDrainedBeforeFixtureStop) { 'NOT-REPRODUCED' } else { 'REPRODUCED: caller exited but fixture retained capture streams' }
}
catch {
    $receipt.error = $_.Exception.Message
    throw
}
finally {
    [IO.File]::WriteAllText((Join-Path $directory 'stop'), 'stop')
    if ($null -ne $parent) {
        if (-not $parent.HasExited) { $parent.Kill(); [void]$parent.WaitForExit(3000) }
        $parent.Dispose()
    }
    if ($null -ne $child) { [void]$child.WaitForExit(5000); $child.Dispose() }
    $receipt.endedAt = [DateTime]::UtcNow.ToString('o')
    $path = Join-Path $OutputDirectory 'dash08-start-pipe.json'
    [IO.File]::WriteAllText($path, (($receipt | ConvertTo-Json -Depth 6) + "`n"), [Text.UTF8Encoding]::new($false))
    Get-Content -LiteralPath $path
    Get-FileHash -Algorithm SHA256 -LiteralPath $path
    # On an abnormal launch, leave the isolated directory for the bounded child;
    # never guess at a PID or delete files beneath a still-running fixture.
    if ($receipt.fixtureStopped) { Remove-Item -LiteralPath $directory -Recurse -Force }
}
