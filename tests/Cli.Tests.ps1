function ConvertTo-EzVmTestLiteral {
    param([AllowEmptyString()][string]$Text)
    return "'" + $Text.Replace("'", "''") + "'"
}

function Invoke-EzVmCliForTest {
    param(
        [AllowEmptyCollection()][AllowEmptyString()][string[]]$ArgumentList = @(),
        [string]$Root = $script:EzVmRepositoryRoot,
        [string]$WorkingDirectory = $script:EzVmRepositoryRoot
    )
    $arguments = @($ArgumentList | ForEach-Object { ConvertTo-EzVmTestLiteral $_ }) -join ', '
    $command = '$ezvmCliArguments = @(' + $arguments + '); & ' + (ConvertTo-EzVmTestLiteral (Join-Path $Root 'ezvm.ps1')) + ' @ezvmCliArguments; exit $LASTEXITCODE'
    return Invoke-EzVmTestPowerShell -CommandText $command -WorkingDirectory $WorkingDirectory
}

function Assert-EzVmJsonEnvelope {
    param([object]$Result, [string]$Command, [int]$ExitCode)
    Assert-EzVmEqual -Actual $Result.ExitCode -Expected $ExitCode
    Assert-EzVmEqual -Actual $Result.StandardError -Expected '' -Message 'Structured output leaked diagnostics to stderr.'
    $value = $Result.StandardOutput | ConvertFrom-Json -ErrorAction Stop
    Assert-EzVmEqual -Actual $value.schemaVersion -Expected 1
    Assert-EzVmEqual -Actual $value.success -Expected ($ExitCode -eq 0)
    Assert-EzVmEqual -Actual $value.command -Expected $Command
    Assert-EzVmEqual -Actual $value.exitCode -Expected $ExitCode
    Assert-EzVmEqual -Actual @($value.PSObject.Properties.Name | Sort-Object) -Expected @('command', 'data', 'error', 'exitCode', 'schemaVersion', 'success')
    if ($ExitCode -eq 0) {
        Assert-EzVmTrue -Condition ($null -ne $value.data)
        Assert-EzVmEqual -Actual $value.error -Expected $null
    }
    else {
        Assert-EzVmEqual -Actual $value.data -Expected $null
        Assert-EzVmTrue -Condition (-not [string]::IsNullOrWhiteSpace($value.error.message))
        Assert-EzVmTrue -Condition (-not [string]::IsNullOrWhiteSpace($value.error.code))
    }
    return $value
}

Add-EzVmTest -Name 'CLI: help and empty input provide human usage' -ScriptBlock {
    foreach ($arguments in @(@('help'), @())) {
        $result = Invoke-EzVmCliForTest -ArgumentList $arguments
        Assert-EzVmEqual -Actual $result.ExitCode -Expected 0
        Assert-EzVmEqual -Actual $result.StandardError -Expected ''
        Assert-EzVmTrue -Condition ($result.StandardOutput -match 'Usage:.*ezvm\.ps1')
        Assert-EzVmTrue -Condition ($result.StandardOutput -match 'help' -and $result.StandardOutput -match 'version')
        Assert-EzVmTrue -Condition ($result.StandardOutput -match 'Foundation') -Message 'Help must distinguish implemented commands from the future VM programme.'
    }
}

Add-EzVmTest -Name 'CLI: human version matches the module version' -ScriptBlock {
    $result = Invoke-EzVmCliForTest -ArgumentList @('version')
    Assert-EzVmEqual -Actual $result.ExitCode -Expected 0
    Assert-EzVmEqual -Actual $result.StandardError -Expected ''
    Assert-EzVmEqual -Actual $result.StandardOutput.Trim() -Expected ('ezvm ' + (Get-EzVmVersion))
    Assert-EzVmEqual -Actual (Get-EzVmVersion) -Expected '0.0.0-dev'
}

$structuredCases = @(
    @{ Arguments = @('help', '-Json'); Command = 'help' },
    @{ Arguments = @('-Json', 'version'); Command = 'version' },
    @{ Arguments = @('version', '-Json'); Command = 'version' },
    @{ Arguments = @('-Json'); Command = 'help' },
    @{ Arguments = @('VeRsIoN', '-jSoN'); Command = 'version' }
)
foreach ($structuredCase in $structuredCases) {
    $testName = 'CLI: structured ' + ($structuredCase.Arguments -join ' ')
    if ($structuredCase.Arguments[0] -ceq 'VeRsIoN') { $testName += ' (case-insensitive parsing)' }
    Add-EzVmTest -Name $testName -Data $structuredCase -ScriptBlock {
        param($case)
        $result = Invoke-EzVmCliForTest -ArgumentList $case.Arguments
        $value = Assert-EzVmJsonEnvelope -Result $result -Command $case.Command -ExitCode 0
        Assert-EzVmEqual -Actual $value.data.version -Expected (Get-EzVmVersion)
    }
}

Add-EzVmTest -Name 'CLI: JSON is available to a same-host PowerShell pipeline' -ScriptBlock {
    $entry = ConvertTo-EzVmTestLiteral (Join-Path $script:EzVmRepositoryRoot 'ezvm.ps1')
    $command = '$ErrorActionPreference = ''Stop''; $value = & ' + $entry + ' version -Json | ConvertFrom-Json; if ($value.data.version -ne ''0.0.0-dev'' -or -not $value.success) { exit 91 }; [Console]::Write($value.data.version); exit 0'
    $result = Invoke-EzVmTestPowerShell -CommandText $command
    Assert-EzVmEqual -Actual $result.ExitCode -Expected 0
    Assert-EzVmEqual -Actual $result.StandardOutput -Expected '0.0.0-dev'
    Assert-EzVmEqual -Actual $result.StandardError -Expected ''
}

$invalidCliCases = @(
    @{ Name = 'unknown command'; Arguments = @('not-a-command') },
    @{ Name = 'future command'; Arguments = @('bootstrap') },
    @{ Name = 'extra positional argument'; Arguments = @('help', 'extra') },
    @{ Name = 'unsupported switch'; Arguments = @('version', '-Unexpected') },
    @{ Name = 'missing command value'; Arguments = @('') }
)
foreach ($invalidCliCase in $invalidCliCases) {
    Add-EzVmTest -Name ('CLI: human error for ' + $invalidCliCase.Name) -Data $invalidCliCase -ScriptBlock {
        param($case)
        $result = Invoke-EzVmCliForTest -ArgumentList $case.Arguments
        Assert-EzVmEqual -Actual $result.ExitCode -Expected 2
        Assert-EzVmEqual -Actual $result.StandardOutput -Expected ''
        Assert-EzVmTrue -Condition ($result.StandardError -match 'help') -Message 'Usage errors must direct the user to help.'
    }
}

$invalidJsonCases = @(
    @{ Name = 'unknown command'; Arguments = @('not-a-command', '-Json'); Command = 'not-a-command' },
    @{ Name = 'extra argument'; Arguments = @('-Json', 'help', 'extra'); Command = 'help' },
    @{ Name = 'duplicate JSON switch'; Arguments = @('-Json', 'version', '-Json'); Command = 'version' }
)
foreach ($invalidJsonCase in $invalidJsonCases) {
    Add-EzVmTest -Name ('CLI: structured error for ' + $invalidJsonCase.Name) -Data $invalidJsonCase -ScriptBlock {
        param($case)
        $result = Invoke-EzVmCliForTest -ArgumentList $case.Arguments
        $value = Assert-EzVmJsonEnvelope -Result $result -Command $case.Command -ExitCode 2
        Assert-EzVmTrue -Condition ($value.error.message -match 'help')
    }
}

Add-EzVmTest -Name 'CLI: copied checkout with spaces and brackets works from an unrelated directory' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'portable [copy] with spaces'
    $elsewhere = New-EzVmTestDirectory -Prefix 'CLI working directory'
    try {
        $result = Invoke-EzVmCliForTest -ArgumentList @('version', '-Json') -Root $root -WorkingDirectory $elsewhere
        $value = Assert-EzVmJsonEnvelope -Result $result -Command 'version' -ExitCode 0
        Assert-EzVmEqual -Actual $value.data.version -Expected '0.0.0-dev'
        Assert-EzVmTrue -Condition (-not (Test-Path -LiteralPath (Join-Path $root '.git')))
        Assert-EzVmTrue -Condition (-not (Test-Path -LiteralPath (Join-Path $root 'runtime')))
        Assert-EzVmTrue -Condition (-not (Test-Path -LiteralPath (Join-Path $elsewhere 'runtime')))
    }
    finally {
        Remove-EzVmTestDirectory -Path $root
        Remove-EzVmTestDirectory -Path $elsewhere
    }
}

Add-EzVmTest -Name 'CLI: a broken checkout has a clean JSON execution-failure result' -ScriptBlock {
    $root = New-EzVmTestDirectory -Prefix 'broken checkout'
    try {
        Copy-Item -LiteralPath (Join-Path $script:EzVmRepositoryRoot 'ezvm.ps1') -Destination $root
        $result = Invoke-EzVmCliForTest -ArgumentList @('version', '-Json') -Root $root
        Assert-EzVmEqual -Actual $result.ExitCode -Expected 1
        Assert-EzVmEqual -Actual $result.StandardError -Expected ''
        $value = $result.StandardOutput | ConvertFrom-Json -ErrorAction Stop
        Assert-EzVmEqual -Actual $value.schemaVersion -Expected 1
        Assert-EzVmEqual -Actual $value.success -Expected $false
        Assert-EzVmEqual -Actual $value.exitCode -Expected 1
        Assert-EzVmEqual -Actual $value.error.code -Expected 'execution_failed'
        Assert-EzVmTrue -Condition ($value.error.message -match 'checkout')
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}
