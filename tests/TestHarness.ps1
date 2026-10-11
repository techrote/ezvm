# ezvm first-party test harness, version 1.0.0. No downloaded test dependency.
Set-StrictMode -Version 2.0

$script:EzVmTestHarnessVersion = '1.0.0'
$script:EzVmTestCases = New-Object 'System.Collections.Generic.List[object]'
$script:EzVmIsWindowsHost = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT

function Add-EzVmTest {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [object]$Data,
        [string]$SkipReason
    )

    if (@($script:EzVmTestCases | Where-Object { $_.Name -eq $Name }).Count -ne 0) {
        throw "Duplicate test name: $Name"
    }
    [void]$script:EzVmTestCases.Add([pscustomobject]@{
        Name = $Name
        Body = $ScriptBlock
        Data = $Data
        SkipReason = $SkipReason
    })
}

function Assert-EzVmTrue {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [string]$Message = 'Expected the condition to be true.'
    )
    if (-not $Condition) { throw $Message }
}

function Assert-EzVmEqual {
    param(
        [AllowNull()][object]$Actual,
        [AllowNull()][object]$Expected,
        [string]$Message = 'Values differ.'
    )

    if ($null -eq $Actual -and $null -eq $Expected) { return }
    if ($null -eq $Actual -or $null -eq $Expected) {
        throw "$Message Expected <$Expected>, got <$Actual>."
    }
    if ($Actual -is [array] -or $Expected -is [array]) {
        $actualItems = @($Actual)
        $expectedItems = @($Expected)
        if ($actualItems.Count -ne $expectedItems.Count) {
            throw "$Message Expected $($expectedItems.Count) items, got $($actualItems.Count)."
        }
        for ($index = 0; $index -lt $actualItems.Count; $index++) {
            Assert-EzVmEqual -Actual $actualItems[$index] -Expected $expectedItems[$index] -Message "$Message Item $index."
        }
        return
    }
    if ($Actual -cne $Expected) {
        throw "$Message Expected <$Expected>, got <$Actual>."
    }
}

function Assert-EzVmThrows {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [string]$MessagePattern
    )

    $caught = $null
    try { & $ScriptBlock | Out-Null }
    catch { $caught = $_ }
    if ($null -eq $caught) { throw 'Expected a terminating error, but the operation succeeded.' }
    if ($MessagePattern -and $caught.Exception.Message -notmatch $MessagePattern) {
        throw "Expected an error matching <$MessagePattern>, got <$($caught.Exception.Message)>."
    }
    return $caught
}

function New-EzVmTestDirectory {
    param([string]$Prefix = 'fixture')
    $path = Join-Path ([IO.Path]::GetTempPath()) ('ezvm tests ' + $Prefix + ' ' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($path)
    return $path
}

function Remove-EzVmTestDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $tempPrefix = Join-Path ([IO.Path]::GetTempPath()) 'ezvm tests '
    if (-not $fullPath.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean a directory outside this harness's temporary roots: $fullPath"
    }
    if (Test-Path -LiteralPath $fullPath) { Remove-Item -LiteralPath $fullPath -Recurse -Force }
}

function New-EzVmCheckoutFixture {
    param([string]$Prefix = 'portable checkout')
    $root = New-EzVmTestDirectory -Prefix $Prefix
    foreach ($relativePath in @('ezvm.ps1', 'src', 'config', 'manifests', 'guest')) {
        $source = Join-Path $script:EzVmRepositoryRoot $relativePath
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination $root -Recurse -Force
        }
    }
    return $root
}

function Invoke-EzVmTestPowerShell {
    param(
        [Parameter(Mandatory = $true)][string]$CommandText,
        [string]$WorkingDirectory = $script:EzVmRepositoryRoot,
        [ValidateRange(1, 300000)][int]$TimeoutMilliseconds = 30000
    )

    # EncodedCommand has one fixed base64 token. Test data belongs in explicitly
    # quoted PowerShell literals in CommandText, never in a native shell string.
    # Suppress only this test wrapper's module-autoload progress on Windows 5.1.
    # A separate raw -File CLI regression checks the application's own output.
    $CommandText = '$ProgressPreference = ''SilentlyContinue''; ' + $CommandText
    $executableName = 'pwsh'
    if ($script:EzVmIsWindowsHost) {
        $executableName = 'pwsh.exe'
        if ($PSVersionTable.PSVersion.Major -eq 5) { $executableName = 'powershell.exe' }
    }
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path $PSHOME $executableName
    $start.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' +
        [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($CommandText))
    $start.WorkingDirectory = $WorkingDirectory
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Could not start the PowerShell test child.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            $process.Kill()
            [void]$process.WaitForExit(5000)
            throw "PowerShell test child timed out after $TimeoutMilliseconds ms."
        }
        if (-not $stdoutTask.Wait(5000) -or -not $stderrTask.Wait(5000)) {
            throw 'PowerShell test child did not close its redirected output streams.'
        }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StandardOutput = $stdoutTask.Result
            StandardError = $stderrTask.Result
        }
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-EzVmTestSuite {
    if ($script:EzVmTestCases.Count -eq 0) { throw 'No tests were discovered; refusing an empty PASS.' }
    $passed = 0
    $failed = 0
    $skipped = 0
    Write-Host ('ezvm test harness {0}; PowerShell {1}; {2}' -f $script:EzVmTestHarnessVersion, $PSVersionTable.PSVersion, [Environment]::OSVersion.Platform)
    foreach ($test in $script:EzVmTestCases) {
        if ($test.SkipReason) {
            $skipped++
            Write-Host ('SKIP {0}: {1}' -f $test.Name, $test.SkipReason)
            continue
        }
        try {
            & $test.Body $test.Data | Out-Null
            $passed++
            Write-Host ('PASS {0}' -f $test.Name)
        }
        catch {
            $failed++
            Write-Host ('FAIL {0}: {1}' -f $test.Name, $_.Exception.Message)
            Write-Host $_.ScriptStackTrace
        }
    }
    Write-Host ('RESULT: {0} passed, {1} failed, {2} skipped, {3} total.' -f $passed, $failed, $skipped, $script:EzVmTestCases.Count)
    if ($failed -ne 0) { throw "$failed ezvm test(s) failed." }
    if ($passed -eq 0) { throw 'No tests executed successfully; refusing an all-skipped PASS.' }
}
