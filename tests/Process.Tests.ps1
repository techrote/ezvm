function Get-EzVmProcessTestExecutable {
    $name = 'pwsh'
    if ($script:EzVmIsWindowsHost) {
        $name = 'pwsh.exe'
        if ($PSVersionTable.PSVersion.Major -le 5) { $name = 'powershell.exe' }
    }
    return Join-Path $PSHOME $name
}

function Get-EzVmProcessTestArguments {
    param([string] $Mode)
    $fixture = Join-Path $script:EzVmRepositoryRoot 'tests/fixtures/ProcessFixture.ps1'
    return @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $fixture, '-Mode', $Mode)
}

function New-EzVmNativeProcessTestFixture {
    param([string] $Directory)

    $compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    Assert-EzVmTrue -Condition ([System.IO.File]::Exists($compiler)) -Message 'Windows .NET Framework C# compiler is required to build the source-only native process fixture.'
    $fixture = Join-Path $Directory 'argument fixture.exe'
    $source = Join-Path $script:EzVmRepositoryRoot 'tests/fixtures/NativeArguments.cs'
    $compile = Invoke-EzVmProcess -FilePath $compiler -ArgumentList @('/nologo', '/target:exe', ('/out:' + $fixture), $source) -ThrowOnError
    Assert-EzVmEqual -Actual $compile.ExitCode -Expected 0
    return $fixture
}

Add-EzVmTest -Name 'Process returns exact nonzero exit and UTF-8 stdout/stderr' -ScriptBlock {
    $result = Invoke-EzVmProcess -FilePath (Get-EzVmProcessTestExecutable) -ArgumentList (Get-EzVmProcessTestArguments -Mode 'nonzero')
    Assert-EzVmEqual -Actual $result.ExitCode -Expected 23
    Assert-EzVmEqual -Actual $result.StdOut -Expected ('stdout-' + [char] 0x03BB)
    Assert-EzVmEqual -Actual $result.StdErr -Expected ('stderr-' + [char] 0x65E5)
}

Add-EzVmTest -Name 'Process ThrowOnError preserves the captured failure evidence' -ScriptBlock {
    $caught = $null
    try {
        $null = Invoke-EzVmProcess -FilePath (Get-EzVmProcessTestExecutable) -ArgumentList (Get-EzVmProcessTestArguments -Mode 'nonzero') -ThrowOnError
    }
    catch { $caught = $_ }
    Assert-EzVmTrue -Condition ($null -ne $caught) -Message 'A failed process with ThrowOnError must throw.'
    Assert-EzVmTrue -Condition ($caught.Exception.Message -match 'exited with code 23') -Message 'The error must report its exit code.'
    Assert-EzVmEqual -Actual $caught.Exception.Data['ExitCode'] -Expected 23
    Assert-EzVmEqual -Actual $caught.Exception.Data['StdOut'] -Expected ('stdout-' + [char] 0x03BB)
    Assert-EzVmEqual -Actual $caught.Exception.Data['StdErr'] -Expected ('stderr-' + [char] 0x65E5)
}

Add-EzVmTest -Name 'Process concurrently drains output larger than both pipe buffers' -ScriptBlock {
    $result = Invoke-EzVmProcess -FilePath (Get-EzVmProcessTestExecutable) -ArgumentList (Get-EzVmProcessTestArguments -Mode 'streams') -TimeoutSeconds 20
    Assert-EzVmEqual -Actual $result.ExitCode -Expected 0
    Assert-EzVmEqual -Actual $result.StdOut -Expected ('O' * (4096 * 64))
    Assert-EzVmEqual -Actual $result.StdErr -Expected ('E' * (4096 * 64))
}

Add-EzVmTest -Name 'Process uses explicit and current PowerShell working directories with spaces' -ScriptBlock {
    $directory = New-EzVmTestDirectory -Prefix 'process working directory'
    try {
        $result = Invoke-EzVmProcess -FilePath (Get-EzVmProcessTestExecutable) -ArgumentList (Get-EzVmProcessTestArguments -Mode 'directory') -WorkingDirectory $directory
        Assert-EzVmEqual -Actual $result.StdOut -Expected $directory
        Push-Location -LiteralPath $directory
        try {
            $result = Invoke-EzVmProcess -FilePath (Get-EzVmProcessTestExecutable) -ArgumentList (Get-EzVmProcessTestArguments -Mode 'directory')
            Assert-EzVmEqual -Actual $result.StdOut -Expected $directory
        }
        finally { Pop-Location }
    }
    finally { Remove-EzVmTestDirectory -Path $directory }
}

Add-EzVmTest -Name 'Process closes standard input for non-interactive children' -ScriptBlock {
    $result = Invoke-EzVmProcess -FilePath (Get-EzVmProcessTestExecutable) -ArgumentList (Get-EzVmProcessTestArguments -Mode 'input') -TimeoutSeconds 10
    Assert-EzVmEqual -Actual $result.ExitCode -Expected 0
    Assert-EzVmEqual -Actual $result.StdOut -Expected ''
}

Add-EzVmTest -Name 'Process rejects missing executables, invalid directories and NUL arguments' -ScriptBlock {
    $directory = New-EzVmTestDirectory -Prefix 'process invalid'
    try {
        Assert-EzVmThrows -ScriptBlock { Invoke-EzVmProcess -FilePath (Join-Path $directory 'missing-executable.exe') } -MessagePattern 'Could not start.*bootstrap'
        Assert-EzVmThrows -ScriptBlock { Invoke-EzVmProcess -FilePath (Get-EzVmProcessTestExecutable) -WorkingDirectory (Join-Path $directory 'missing') } -MessagePattern 'working directory.*does not exist'
        Assert-EzVmThrows -ScriptBlock { Invoke-EzVmProcess -FilePath (Get-EzVmProcessTestExecutable) -ArgumentList @('prefix' + [char] 0 + 'suffix') } -MessagePattern 'NUL'
    }
    finally { Remove-EzVmTestDirectory -Path $directory }
}

Add-EzVmTest -Name 'Process timeout is bounded and terminates the direct child' -ScriptBlock {
    $directory = New-EzVmTestDirectory -Prefix 'process timeout'
    try {
        $marker = Join-Path $directory 'child.pid.txt'
        $arguments = @(Get-EzVmProcessTestArguments -Mode 'sleep') + @('-MarkerPath', $marker)
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        Assert-EzVmThrows -ScriptBlock { Invoke-EzVmProcess -FilePath (Get-EzVmProcessTestExecutable) -ArgumentList $arguments -TimeoutSeconds 3 } -MessagePattern '3 second timeout'
        $clock.Stop()
        Assert-EzVmTrue -Condition ($clock.Elapsed.TotalSeconds -lt 12) -Message 'The three-second timeout plus bounded cleanup must return promptly.'
        Assert-EzVmTrue -Condition ([System.IO.File]::Exists($marker)) -Message 'The child must have started before the timeout.'
        $childId = [int] [System.IO.File]::ReadAllText($marker)
        $child = $null
        try { $child = [System.Diagnostics.Process]::GetProcessById($childId) }
        catch [System.ArgumentException] { }
        if ($null -ne $child) {
            try { Assert-EzVmTrue -Condition $child.HasExited -Message 'The direct child must not remain running after timeout.' }
            finally { $child.Dispose() }
        }
    }
    finally { Remove-EzVmTestDirectory -Path $directory }
}

$nativeArgumentSkip = $null
if (-not $script:EzVmIsWindowsHost) {
    $nativeArgumentSkip = 'The native Windows process fixtures require Windows; both Windows PowerShell 5.1 and PowerShell 7 CI jobs run them.'
}
Add-EzVmTest -Name 'Process preserves native Windows argument tokens including empty quotes slashes and Unicode' -SkipReason $nativeArgumentSkip -ScriptBlock {
    $directory = New-EzVmTestDirectory -Prefix 'native argument fixture'
    try {
        $fixture = New-EzVmNativeProcessTestFixture -Directory $directory
        $tokens = @(
            '', 'plain', 'two words', '"', 'embedded"quote', '\', '\\',
            'C:\directory with spaces\', 'slashes\\"quoted', 'tail\\',
            "tab`tseparated", "line`nbreak", ('unicode-' + [char] 0x03BB + [char] 0x65E5),
            '& | < > ^ %PATH% $(not-a-shell) ;', 'final'
        )
        $result = Invoke-EzVmProcess -FilePath $fixture -ArgumentList $tokens -WorkingDirectory $directory -ThrowOnError
        Assert-EzVmEqual -Actual $result.ExitCode -Expected 0
        $lines = $result.StdOut -split '\r?\n'
        Assert-EzVmEqual -Actual ([int] $lines[0]) -Expected $tokens.Count
        foreach ($index in 0..($tokens.Count - 1)) {
            $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($lines[$index + 1]))
            Assert-EzVmEqual -Actual $decoded -Expected $tokens[$index]
        }
        Assert-EzVmEqual -Actual $result.StdErr -Expected ''
        $empty = Invoke-EzVmProcess -FilePath $fixture -ArgumentList @() -ThrowOnError
        Assert-EzVmEqual -Actual $empty.StdOut.Trim() -Expected '0'
    }
    finally { Remove-EzVmTestDirectory -Path $directory }
}

Add-EzVmTest -Name 'Process sends zero stdin bytes with a BOM-bearing console encoding and restores it after success and failure' -SkipReason $nativeArgumentSkip -ScriptBlock {
    $directory = New-EzVmTestDirectory -Prefix 'native stdin fixture'
    $originalEncoding = [Console]::InputEncoding
    $originalReader = [Console]::In
    $testReader = $null
    try {
        $fixture = New-EzVmNativeProcessTestFixture -Directory $directory
        $bomEncoding = New-Object System.Text.UTF8Encoding($true)
        [Console]::InputEncoding = $bomEncoding
        $testReader = New-Object System.IO.StringReader("buffered caller input`n")
        [Console]::SetIn($testReader)
        $expectedReader = [Console]::In
        Assert-EzVmEqual -Actual ([BitConverter]::ToString([Console]::InputEncoding.GetPreamble())) -Expected 'EF-BB-BF'

        $result = Invoke-EzVmProcess -FilePath $fixture -ArgumentList @('--stdin-byte-count') -TimeoutSeconds 10 -ThrowOnError
        Assert-EzVmEqual -Actual $result.StdOut.Trim() -Expected '0'
        Assert-EzVmEqual -Actual $result.StdErr -Expected ''
        Assert-EzVmTrue -Condition ($bomEncoding.Equals([Console]::InputEncoding)) -Message 'A successful launch must restore the original console encoding.'
        Assert-EzVmTrue -Condition ([object]::ReferenceEquals($expectedReader, [Console]::In)) -Message 'A successful launch must preserve the caller console reader.'

        Assert-EzVmThrows -ScriptBlock { Invoke-EzVmProcess -FilePath (Join-Path $directory 'missing.exe') } -MessagePattern 'Could not start'
        Assert-EzVmTrue -Condition ($bomEncoding.Equals([Console]::InputEncoding)) -Message 'A failed launch must restore the original console encoding.'
        Assert-EzVmTrue -Condition ([object]::ReferenceEquals($expectedReader, [Console]::In)) -Message 'A failed launch must preserve the caller console reader.'

        # The nested caller has redirected stdin and CreateNoWindow, so its
        # process helper cannot assume an attached, configurable console exists.
        $modulePath = (Join-Path $script:EzVmRepositoryRoot 'src/EzVm/EzVm.psd1').Replace("'", "''")
        $quotedFixture = $fixture.Replace("'", "''")
        $command = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (-not [Console]::IsInputRedirected) { throw 'The test caller must have redirected input.' }
Import-Module '__MODULE__' -Force
$result = Invoke-EzVmProcess -FilePath '__FIXTURE__' -ArgumentList @('--stdin-byte-count') -ThrowOnError
[Console]::Out.Write($result.StdOut)
'@
        $command = $command.Replace('__MODULE__', $modulePath).Replace('__FIXTURE__', $quotedFixture)
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($command))
        $headless = Invoke-EzVmProcess -FilePath (Get-EzVmProcessTestExecutable) -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) -TimeoutSeconds 15 -ThrowOnError
        Assert-EzVmEqual -Actual $headless.StdOut.Trim() -Expected '0'
        Assert-EzVmEqual -Actual $headless.StdErr -Expected ''
        Assert-EzVmTrue -Condition ($bomEncoding.Equals([Console]::InputEncoding)) -Message 'The redirected caller test must also restore the parent console encoding.'
        Assert-EzVmTrue -Condition ([object]::ReferenceEquals($expectedReader, [Console]::In)) -Message 'The redirected caller test must preserve the parent console reader.'
        Assert-EzVmEqual -Actual ([Console]::In.ReadLine()) -Expected 'buffered caller input'
    }
    finally {
        try { [Console]::InputEncoding = $originalEncoding }
        finally {
            [Console]::SetIn($originalReader)
            if ($null -ne $testReader) { $testReader.Dispose() }
            Remove-EzVmTestDirectory -Path $directory
        }
    }
}
