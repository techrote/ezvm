. (Join-Path $script:EzVmRepositoryRoot 'scripts/PrivateAclHostedSupport.ps1')

function Get-EzVmAclHostedTestExecutable {
    $name = if ($script:EzVmIsWindowsHost) { if ($PSVersionTable.PSVersion.Major -eq 5) { 'powershell.exe' } else { 'pwsh.exe' } } else { 'pwsh' }
    return Join-Path $PSHOME $name
}

function Get-EzVmAclHostedTestArguments {
    param([string]$Command)
    return @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command)))
}

function Start-EzVmAclHostedTestChild {
    param([string]$Root, [string]$Name, [int]$ExitCode, [int]$DelayMilliseconds = 200)
    $arguments = Get-EzVmAclHostedTestArguments -Command ('Start-Sleep -Milliseconds ' + $DelayMilliseconds + '; exit ' + $ExitCode)
    return Start-Process -FilePath (Get-EzVmAclHostedTestExecutable) -ArgumentList $arguments -WorkingDirectory $Root -RedirectStandardOutput (Join-Path $Root ($Name + '.stdout')) -RedirectStandardError (Join-Path $Root ($Name + '.stderr')) -PassThru
}

Add-EzVmTest -Name 'Hosted ACL launch: multiple Git applications resolve to exactly the first existing file' -ScriptBlock {
    $root = New-EzVmTestDirectory -Prefix 'hosted Git resolution'
    try {
        $first = Join-Path $root 'first git.exe'
        $second = Join-Path $root 'second git.exe'
        [IO.File]::WriteAllText($first, 'synthetic executable identity')
        [IO.File]::WriteAllText($second, 'synthetic executable identity')
        function Get-Command {
            param($Name, $CommandType, $ErrorAction)
            @([pscustomobject]@{ Source = $first }, [pscustomobject]@{ Source = $second }, [pscustomobject]@{ Source = $second })
        }
        $resolved = @(Resolve-PrivateAclFixtureGit)
        Assert-EzVmEqual $resolved.Count 1
        Assert-EzVmEqual $resolved[0] $first
        [IO.File]::Delete($first)
        Assert-EzVmThrows { Resolve-PrivateAclFixtureGit } -MessagePattern 'first Git application' | Out-Null
        [void][IO.Directory]::CreateDirectory($first)
        Assert-EzVmThrows { Resolve-PrivateAclFixtureGit } -MessagePattern 'first Git application' | Out-Null
    }
    finally { Remove-EzVmTestDirectory $root }
}

Add-EzVmTest -Name 'Hosted ACL launch: successful native stderr is retained without changing caller error preferences' -ScriptBlock {
    $ErrorActionPreference = 'Stop'
    $PSNativeCommandUseErrorActionPreference = $true
    $previousExitCode = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    $previousValue = if ($null -ne $previousExitCode) { $previousExitCode.Value } else { $null }
    try {
        $arguments = Get-EzVmAclHostedTestArguments -Command '[Console]::Out.WriteLine("native output sentinel"); [Console]::Error.WriteLine("native progress sentinel"); exit 0'
        $output = @(Invoke-PrivateAclFixtureGit -Executable (Get-EzVmAclHostedTestExecutable) -Arguments $arguments -Operation 'Synthetic successful Git' 2>&1)
        Assert-EzVmTrue (($output -join "`n") -match 'native output sentinel')
        Assert-EzVmTrue (($output -join "`n") -match 'native progress sentinel')
        Assert-EzVmEqual ([string]$ErrorActionPreference) 'Stop'
        Assert-EzVmTrue $PSNativeCommandUseErrorActionPreference
    }
    finally {
        if ($null -eq $previousExitCode) { Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue }
        else { $global:LASTEXITCODE = $previousValue }
    }
}

Add-EzVmTest -Name 'Hosted ACL launch: native nonzero and missing executable terminate without a stale success code' -ScriptBlock {
    $ErrorActionPreference = 'Stop'
    $PSNativeCommandUseErrorActionPreference = $true
    $previousExitCode = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    $previousValue = if ($null -ne $previousExitCode) { $previousExitCode.Value } else { $null }
    try {
        $arguments = Get-EzVmAclHostedTestArguments -Command '[Console]::Error.WriteLine("native failure sentinel"); exit 23'
        $output = New-Object 'System.Collections.Generic.List[string]'
        Assert-EzVmThrows {
            Invoke-PrivateAclFixtureGit -Executable (Get-EzVmAclHostedTestExecutable) -Arguments $arguments -Operation 'Synthetic failed Git' 2>&1 | ForEach-Object { [void]$output.Add([string]$_) }
        } -MessagePattern 'Synthetic failed Git failed with exit code 23' | Out-Null
        Assert-EzVmTrue (($output -join "`n") -match 'native failure sentinel')
        Assert-EzVmEqual ([string]$ErrorActionPreference) 'Stop'
        Assert-EzVmTrue $PSNativeCommandUseErrorActionPreference
        $global:LASTEXITCODE = 0
        Assert-EzVmThrows {
            Invoke-PrivateAclFixtureGit -Executable (Join-Path $PSHOME 'ezvm-missing-fixture-executable') -Arguments @('--version') -Operation 'Missing Git'
        } -MessagePattern 'executable is missing' | Out-Null
    }
    finally {
        if ($null -eq $previousExitCode) { Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue }
        else { $global:LASTEXITCODE = $previousValue }
    }
}

Add-EzVmTest -Name 'Hosted ACL launch: retained process reports exact zero and nonzero exit codes' -ScriptBlock {
    $root = New-EzVmTestDirectory -Prefix 'hosted process exit'
    try {
        foreach ($expected in @(0, 23)) {
            $child = Start-EzVmAclHostedTestChild -Root $root -Name ('exit-' + $expected) -ExitCode $expected
            try {
                $receipt = [ordered]@{ childExited = $false; childExitCode = $null }
                Wait-PrivateAclFixtureChild -Process $child -Receipt $receipt -TimeoutMilliseconds 10000
                Assert-EzVmTrue $receipt.childExited
                Assert-EzVmTrue ($receipt.childExitCode -is [int])
                Assert-EzVmEqual $receipt.childExitCode $expected
            }
            finally { $child.Dispose() }
        }
    }
    finally { Remove-EzVmTestDirectory $root }
}

Add-EzVmTest -Name 'Hosted ACL launch: unavailable child exit status cannot become successful cleanup evidence' -ScriptBlock {
    $root = New-EzVmTestDirectory -Prefix 'hosted unavailable exit'
    $child = $null
    try {
        $child = Start-EzVmAclHostedTestChild -Root $root -Name 'null-exit' -ExitCode 23
        # Simulate the observed unavailable getter while retaining a real owned child.
        $child | Add-Member -MemberType ScriptMethod -Name get_ExitCode -Value { return $null } -Force
        $receipt = [ordered]@{ childExited = $false; childExitCode = $null }
        Assert-EzVmThrows { Wait-PrivateAclFixtureChild -Process $child -Receipt $receipt -TimeoutMilliseconds 10000 } -MessagePattern 'numeric exit code' | Out-Null
        Assert-EzVmTrue $receipt.childExited
        Assert-EzVmEqual $receipt.childExitCode $null
    }
    finally {
        if ($null -ne $child) { $child.Dispose() }
        Remove-EzVmTestDirectory $root
    }
}

Add-EzVmTest -Name 'Hosted ACL launch: bounded timeout stops only the retained child and withholds success' -ScriptBlock {
    $root = New-EzVmTestDirectory -Prefix 'hosted process timeout'
    $child = $null
    $other = $null
    try {
        $other = Start-EzVmAclHostedTestChild -Root $root -Name 'unrelated' -ExitCode 0 -DelayMilliseconds 30000
        $otherHandle = $other.get_Handle()
        $child = Start-EzVmAclHostedTestChild -Root $root -Name 'timed-out' -ExitCode 0 -DelayMilliseconds 30000
        $receipt = [ordered]@{ childExited = $false; childExitCode = $null }
        Assert-EzVmThrows { Wait-PrivateAclFixtureChild -Process $child -Receipt $receipt -TimeoutMilliseconds 200 } -MessagePattern 'ten-minute wall' | Out-Null
        Assert-EzVmTrue $receipt.childExited
        Assert-EzVmEqual $receipt.childExitCode $null
        Assert-EzVmTrue (-not $other.get_HasExited())
    }
    finally {
        foreach ($process in @($child, $other)) {
            if ($null -ne $process) {
                if (-not $process.get_HasExited()) { $process.Kill(); [void]$process.WaitForExit(5000) }
                $process.Dispose()
            }
        }
        Remove-EzVmTestDirectory $root
    }
}
