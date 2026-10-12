function ConvertTo-EzVmPortabilityCliLiteral {
    param([AllowEmptyString()][string]$Text)
    return "'" + $Text.Replace("'", "''") + "'"
}

function New-EzVmPortabilityCliFixture {
    $root = New-EzVmCheckoutFixture -Prefix 'portability CLI [isolated]'
    # Replace only operation boundaries in this disposable copied module. The
    # actual entry point, argument parser, result envelope and formatters execute
    # unchanged in child PowerShell processes. No real VM/disk operation runs.
    $stubs = @'
function Save-EzVmCliBoundaryCall {
    param([string]$Root, [string]$Operation, [object]$Received)
    Write-EzVmJson -Path (Join-Path $Root 'cli-boundary-call.json') -Value ([pscustomobject]@{
        schemaVersion = 1; operation = $Operation; received = $Received
    })
}
function New-EzVmCliBoundaryInstance {
    param([string]$Name, [string]$Profile, [AllowNull()][object]$Cpus, [AllowNull()][object]$MemoryMiB,
        [object]$Received, [bool]$Sensitive = $false)
    return [pscustomobject][ordered]@{
        name = $Name; profile = $(if ($Profile) { $Profile } else { 'normal' })
        cpus = $(if ($null -ne $Cpus) { [int]$Cpus } else { 4 })
        memoryMiB = $(if ($null -ne $MemoryMiB) { [int]$MemoryMiB } else { 8192 })
        baseId = 'base-' + ('a' * 64); baseSelection = 'explicit'; sshPort = 22007
        warnings = @(); sensitiveState = $Sensitive; received = $Received
    }
}
function New-EzVmManagedInstance {
    param($Root, $InstanceName, $BaseId, $Profile, $Cpus, $MemoryMiB)
    $received = [pscustomobject]@{ root = $Root; name = $InstanceName; baseId = $BaseId; profile = $Profile; cpus = $Cpus; memoryMiB = $MemoryMiB }
    Save-EzVmCliBoundaryCall -Root $Root -Operation create -Received $received
    return New-EzVmCliBoundaryInstance -Name $InstanceName -Profile $Profile -Cpus $Cpus -MemoryMiB $MemoryMiB -Received $received
}
function Copy-EzVmManagedInstance {
    param($Root, $SourceInstanceName, $DestinationInstanceName, $Mode)
    $received = [pscustomobject]@{ root = $Root; source = $SourceInstanceName; destination = $DestinationInstanceName; mode = $Mode }
    Save-EzVmCliBoundaryCall -Root $Root -Operation clone -Received $received
    $result = New-EzVmCliBoundaryInstance -Name $DestinationInstanceName -Profile light -Cpus 2 -MemoryMiB 4096 -Received $received -Sensitive ($Mode -ceq 'stateful')
    $result | Add-Member -NotePropertyName mode -NotePropertyValue $Mode
    $result | Add-Member -NotePropertyName sourceName -NotePropertyValue $SourceInstanceName
    return $result
}
function Reset-EzVmManagedInstance {
    param($Root, $InstanceName)
    $received = [pscustomobject]@{ root = $Root; name = $InstanceName }
    Save-EzVmCliBoundaryCall -Root $Root -Operation reset -Received $received
    return [pscustomobject]@{
        name = $InstanceName; state = 'CREATED'; baseId = 'base-' + ('b' * 64)
        identityGeneration = 'c' * 32; resetBaseline = 'derived'; sensitiveState = $true
        recoveryArtifact = @('retained reset backup.qcow2'); received = $received
    }
}
function Export-EzVmManagedInstance {
    param($Root, $InstanceName, $DestinationDirectory)
    $received = [pscustomobject]@{ root = $Root; name = $InstanceName; destinationDirectory = $DestinationDirectory }
    Save-EzVmCliBoundaryCall -Root $Root -Operation export -Received $received
    return [pscustomobject]@{
        Directory = $DestinationDirectory; Image = Join-Path $DestinationDirectory 'disk.qcow2'
        ManifestPath = Join-Path $DestinationDirectory 'manifest.json'
        Manifest = [pscustomobject]@{ imageSha256 = 'd' * 64 }; received = $received
    }
}
function Import-EzVmManagedInstance {
    param($Root, $InstanceName, $ImagePath, $ManifestPath, $Profile, $Cpus, $MemoryMiB)
    $received = [pscustomobject]@{ root = $Root; name = $InstanceName; imagePath = $ImagePath; manifestPath = $ManifestPath; profile = $Profile; cpus = $Cpus; memoryMiB = $MemoryMiB }
    Save-EzVmCliBoundaryCall -Root $Root -Operation import -Received $received
    return New-EzVmCliBoundaryInstance -Name $InstanceName -Profile $Profile -Cpus $Cpus -MemoryMiB $MemoryMiB -Received $received -Sensitive $true
}
function Test-EzVmPortableBundle {
    param($Root)
    $received = [pscustomobject]@{ root = $Root }
    Save-EzVmCliBoundaryCall -Root $Root -Operation 'portability check' -Received $received
    return [pscustomobject]@{ Valid = $true; Root = $Root; InstanceCount = 2; Instances = @(); received = $received }
}
'@
    [IO.File]::AppendAllText((Join-Path $root 'src/EzVm/Portability.ps1'), ("`n" + $stubs + "`n"), (New-Object Text.UTF8Encoding($false)))
    return $root
}

function Invoke-EzVmPortabilityCliProcess {
    param([string]$Root, [AllowEmptyCollection()][AllowEmptyString()][string[]]$Arguments)
    $tokens = @($Arguments | ForEach-Object { ConvertTo-EzVmPortabilityCliLiteral $_ }) -join ', '
    $command = '$ErrorActionPreference = ''Stop''; $cliTokens = @(' + $tokens + '); & ' +
        (ConvertTo-EzVmPortabilityCliLiteral (Join-Path $Root 'ezvm.ps1')) + ' @cliTokens; exit $LASTEXITCODE'
    return Invoke-EzVmTestPowerShell -CommandText $command
}

function Assert-EzVmPortabilityCliEnvelope {
    param([object]$Result, [AllowNull()][object]$Command, [int]$ExitCode)
    Assert-EzVmEqual -Actual $Result.ExitCode -Expected $ExitCode
    Assert-EzVmEqual -Actual $Result.StandardError -Expected '' -Message 'JSON results must not mix stderr diagnostics with their envelope.'
    $values = @($Result.StandardOutput | ConvertFrom-Json -ErrorAction Stop)
    Assert-EzVmEqual -Actual $values.Count -Expected 1 -Message 'Each CLI invocation must return exactly one JSON envelope.'
    $value = $values[0]
    Assert-EzVmEqual -Actual @($value.PSObject.Properties.Name | Sort-Object) -Expected @('command', 'data', 'error', 'exitCode', 'schemaVersion', 'success')
    Assert-EzVmEqual -Actual $value.schemaVersion -Expected 1
    Assert-EzVmEqual -Actual $value.command -Expected $Command
    Assert-EzVmEqual -Actual $value.exitCode -Expected $ExitCode
    Assert-EzVmEqual -Actual $value.success -Expected ($ExitCode -eq 0)
    if ($ExitCode -eq 0) { Assert-EzVmEqual -Actual $value.error -Expected $null }
    else {
        Assert-EzVmEqual -Actual $value.data -Expected $null
        Assert-EzVmTrue -Condition (-not [string]::IsNullOrWhiteSpace([string]$value.error.message))
    }
    return $value
}

Add-EzVmTest -Name 'Portability CLI: explicit modes and path/resource tokens reach the correct operation unchanged' -ScriptBlock {
    $root = New-EzVmPortabilityCliFixture
    try {
        $image = Join-Path $root 'inputs with spaces [copy] & dollars $/source image.qcow2'
        $manifest = Join-Path $root "O'Brien export manifest.json"
        $destination = Join-Path $root "O'Brien export [snapshot]"
        $baseId = 'base-' + ('e' * 64)
        $cases = @(
            @{ Tokens = @('cLoNe', 'Source-ONE', 'Fresh-Copy', '-mOdE', 'FRESH', '-Json'); Command = 'clone'; Expected = @{ source = 'Source-ONE'; destination = 'Fresh-Copy'; mode = 'fresh' } },
            @{ Tokens = @('-JSON', 'CLONE', 'source-two', 'saved-copy', '-MODE', 'STATEFUL'); Command = 'clone'; Expected = @{ source = 'source-two'; destination = 'saved-copy'; mode = 'stateful' } },
            @{ Tokens = @('RESET', 'Source-ONE', '-Json'); Command = 'reset'; Expected = @{ name = 'Source-ONE' } },
            @{ Tokens = @('export', 'source-two', $destination, '-Json'); Command = 'export'; Expected = @{ name = 'source-two'; destinationDirectory = $destination } },
            @{ Tokens = @('ImPoRt', 'imported', $image, '-ManifestPath', $manifest, '-PROFILE', 'custom', '-CPUS', '3', '-memorymib', '6144', '-Json'); Command = 'import'; Expected = @{ name = 'imported'; imagePath = $image; manifestPath = $manifest; profile = 'custom'; cpus = 3; memoryMiB = 6144 } },
            @{ Tokens = @('create', 'clean', '-BaseId', $baseId, '-Profile', 'light', '-Json'); Command = 'create'; Expected = @{ name = 'clean'; baseId = $baseId; profile = 'light' } },
            @{ Tokens = @('PORTABILITY', 'CHECK', '-Json'); Command = 'portability check'; Expected = @{} }
        )
        foreach ($case in $cases) {
            $result = Invoke-EzVmPortabilityCliProcess -Root $root -Arguments $case.Tokens
            $value = Assert-EzVmPortabilityCliEnvelope -Result $result -Command $case.Command -ExitCode 0
            Assert-EzVmEqual -Actual $value.data.received.root -Expected $root
            foreach ($field in $case.Expected.Keys) {
                Assert-EzVmEqual -Actual $value.data.received.$field -Expected $case.Expected[$field] -Message ("Incorrect CLI routing for $($case.Command) field '$field'.")
            }
            $call = Read-EzVmJson -Path (Join-Path $root 'cli-boundary-call.json')
            Assert-EzVmEqual -Actual $call.operation -Expected $case.Command
        }
        Assert-EzVmTrue -Condition (-not (Test-Path -LiteralPath (Join-Path $root 'runtime'))) -Message 'CLI fixture unexpectedly crossed a real storage boundary.'
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Portability CLI: ambiguous destructive syntax is refused before dispatch' -ScriptBlock {
    $root = New-EzVmPortabilityCliFixture
    try {
        $cases = @(
            @{ tokens = @('clone', 'source', 'copy') },
            @{ tokens = @('clone', 'source', 'copy', '-Mode') },
            @{ tokens = @('clone', 'source', 'copy', '-Mode', 'automatic') },
            @{ tokens = @('clone', 'source', 'copy', '-Mode', 'fresh', '-Mode', 'stateful') },
            @{ tokens = @('clone', 'source', 'copy', '-Fresh', 'stateful') },
            @{ tokens = @('clone', 'source', '../copy', '-Mode', 'stateful') },
            @{ tokens = @('reset') },
            @{ tokens = @('reset', 'source', 'extra') },
            @{ tokens = @('reset', 'NUL') },
            @{ tokens = @('export', 'source') },
            @{ tokens = @('export', 'source', '') },
            @{ tokens = @('export', 'source', 'destination', 'extra') },
            @{ tokens = @('import', 'copy') },
            @{ tokens = @('import', 'copy', '') },
            @{ tokens = @('import', 'copy', 'disk.qcow2', '-ManifestPath') },
            @{ tokens = @('import', 'copy', 'disk.qcow2', '-Profile', 'normal', '-PROFILE', 'light') },
            @{ tokens = @('import', 'copy', 'disk.qcow2', '-Cpus', '2', '-CPUS', '3') },
            @{ tokens = @('import', 'copy', 'disk.qcow2', '-MemoryMiB', '4096', '-memorymib', '8192') },
            @{ tokens = @('import', 'copy', 'disk.qcow2', '-ManifestPath', 'a.json', '-manifestpath', 'b.json') },
            @{ tokens = @('import', 'copy', 'disk.qcow2', '-Cpus', '2.5') },
            @{ tokens = @('import', 'copy', 'disk.qcow2', '-Cpus', '-1') },
            @{ tokens = @('import', 'copy', 'disk.qcow2', '-MemoryMiB', '2147483648') },
            @{ tokens = @('import', 'copy', 'disk.qcow2', '-Profile', '') },
            @{ tokens = @('import', 'copy', 'disk.qcow2', '-BaseId', ('base-' + ('a' * 64))) },
            @{ tokens = @('create', 'copy', '-ManifestPath', 'export.json') },
            @{ tokens = @('portability') },
            @{ tokens = @('portability', 'repair') },
            @{ tokens = @('portability', 'check', '-Force') },
            @{ tokens = @('-Json', 'clone', 'source', 'copy', '-Mode', 'fresh', '-Json') }
        )
        $serialized = ConvertTo-EzVmPortabilityCliLiteral ($cases | ConvertTo-Json -Depth 6 -Compress)
        $modulePath = ConvertTo-EzVmPortabilityCliLiteral (Join-Path $root 'src/EzVm/EzVm.psd1')
        $rootLiteral = ConvertTo-EzVmPortabilityCliLiteral $root
        $command = '$ErrorActionPreference = ''Stop''; Import-Module ' + $modulePath + ' -Force; $cases = ' + $serialized +
            ' | ConvertFrom-Json; $results = @($cases | ForEach-Object { Invoke-EzVmCommand -Root ' + $rootLiteral + ' -Arguments ([string[]]$_.tokens) }); $results | ConvertTo-Json -Depth 8 -Compress; exit 0'
        $run = Invoke-EzVmTestPowerShell -CommandText $command
        Assert-EzVmEqual -Actual $run.ExitCode -Expected 0
        Assert-EzVmEqual -Actual $run.StandardError -Expected ''
        $results = @($run.StandardOutput | ConvertFrom-Json -ErrorAction Stop)
        Assert-EzVmEqual -Actual $results.Count -Expected $cases.Count
        foreach ($result in $results) {
            Assert-EzVmEqual -Actual $result.success -Expected $false
            Assert-EzVmEqual -Actual $result.exitCode -Expected 2
            Assert-EzVmEqual -Actual $result.data -Expected $null
            Assert-EzVmEqual -Actual $result.error.code -Expected 'invalid_arguments'
            Assert-EzVmTrue -Condition ($result.error.message -match 'help')
        }
        Assert-EzVmTrue -Condition (-not (Test-Path -LiteralPath (Join-Path $root 'cli-boundary-call.json'))) -Message 'Invalid syntax invoked a lifecycle/storage operation.'
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Portability CLI: actual entry point returns usage failure in human and JSON modes' -ScriptBlock {
    $root = New-EzVmPortabilityCliFixture
    try {
        $human = Invoke-EzVmPortabilityCliProcess -Root $root -Arguments @('clone', 'source', 'destination')
        Assert-EzVmEqual -Actual $human.ExitCode -Expected 2
        Assert-EzVmEqual -Actual $human.StandardOutput -Expected ''
        Assert-EzVmTrue -Condition ($human.StandardError -match 'Choose the mode explicitly' -and $human.StandardError -match 'help')
        $json = Invoke-EzVmPortabilityCliProcess -Root $root -Arguments @('import', 'destination', 'disk.qcow2', '-BaseId', 'forbidden', '-Json')
        $value = Assert-EzVmPortabilityCliEnvelope -Result $json -Command 'import' -ExitCode 2
        Assert-EzVmEqual -Actual $value.error.code -Expected 'invalid_arguments'
        Assert-EzVmTrue -Condition ($value.error.message -match 'Unknown import option')
        Assert-EzVmTrue -Condition (-not (Test-Path -LiteralPath (Join-Path $root 'cli-boundary-call.json')))
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Portability CLI: human results explain baseline sensitivity and retained recovery material' -ScriptBlock {
    $root = New-EzVmPortabilityCliFixture
    try {
        $cases = @(
            @{ Tokens = @('clone', 'source', 'fresh-copy', '-Mode', 'fresh'); Expected = @('Created fresh-copy', 'clone mode: fresh; source: source', 'SSH reservation: 127.0.0.1:22007'); Sensitive = $false },
            @{ Tokens = @('clone', 'source', 'saved-copy', '-Mode', 'stateful'); Expected = @('Created saved-copy', 'clone mode: stateful; source: source', 'immutable baseline may contain credentials'); Sensitive = $true },
            @{ Tokens = @('reset', 'saved-copy'); Expected = @('Reset saved-copy: CREATED', 'reset restores this snapshot baseline', 'retained reset backup.qcow2'); Sensitive = $true },
            @{ Tokens = @('export', 'source', (Join-Path $root 'saved export')); Expected = @('Exported standalone image:', 'manifest.json', ('d' * 64), 'bundle may contain credentials'); Sensitive = $true },
            @{ Tokens = @('import', 'imported', (Join-Path $root 'saved export/disk.qcow2')); Expected = @('Created imported', 'SSH reservation: 127.0.0.1:22007', 'immutable baseline may contain credentials'); Sensitive = $true },
            @{ Tokens = @('portability', 'check'); Expected = @('Cold portability validated: 2 stopped instances', 'all guests remain stopped', 'again at the destination'); Sensitive = $false }
        )
        foreach ($case in $cases) {
            $result = Invoke-EzVmPortabilityCliProcess -Root $root -Arguments $case.Tokens
            Assert-EzVmEqual -Actual $result.ExitCode -Expected 0
            Assert-EzVmEqual -Actual $result.StandardError -Expected ''
            foreach ($text in $case.Expected) {
                Assert-EzVmTrue -Condition ($result.StandardOutput.Contains($text)) -Message ("Missing user-facing portability result '$text'.")
            }
            Assert-EzVmEqual -Actual ($result.StandardOutput -match 'sensitive state:') -Expected $case.Sensitive
        }
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Portability CLI: successful JSON stays usable in a same-host PowerShell pipeline' -ScriptBlock {
    $root = New-EzVmPortabilityCliFixture
    try {
        $entry = ConvertTo-EzVmPortabilityCliLiteral (Join-Path $root 'ezvm.ps1')
        $command = '$ErrorActionPreference = ''Stop''; $values = @(& ' + $entry +
            ' clone source piped-copy -Mode STATEFUL -Json | ConvertFrom-Json); if ($LASTEXITCODE -ne 0 -or $values.Count -ne 1 -or -not $values[0].success -or $values[0].data.mode -cne ''stateful'' -or $values[0].data.name -cne ''piped-copy'') { exit 91 }; [Console]::Write($values[0].data.name); exit 0'
        $result = Invoke-EzVmTestPowerShell -CommandText $command
        Assert-EzVmEqual -Actual $result.ExitCode -Expected 0
        Assert-EzVmEqual -Actual $result.StandardOutput -Expected 'piped-copy'
        Assert-EzVmEqual -Actual $result.StandardError -Expected ''
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Portability CLI: missing real instances remain execution failures without a false success envelope' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'portability CLI missing instances'
    try {
        foreach ($tokens in @(
            @('reset', 'absent', '-Json'),
            @('clone', 'absent', 'copy', '-Mode', 'stateful', '-Json'),
            @('export', 'absent', (Join-Path $root 'export'), '-Json')
        )) {
            $run = Invoke-EzVmPortabilityCliProcess -Root $root -Arguments $tokens
            $value = Assert-EzVmPortabilityCliEnvelope -Result $run -Command $null -ExitCode 1
            Assert-EzVmEqual -Actual $value.error.code -Expected 'execution_failed'
            Assert-EzVmTrue -Condition ($value.error.message -match 'instance.json|does not exist')
        }
        Assert-EzVmTrue -Condition (-not (Test-Path -LiteralPath (Join-Path $root 'runtime/instances/copy')))
        Assert-EzVmTrue -Condition (-not (Test-Path -LiteralPath (Join-Path $root 'export')))
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Portability CLI: help exposes explicit copy choices and export/import argument direction' -ScriptBlock {
    $result = Invoke-EzVmCommand -Arguments @('help', '-Json')
    $commands = @($result.data.commands | ForEach-Object { $_.name })
    foreach ($required in @('reset <name>', 'clone <source> <destination> -Mode fresh|stateful', 'export <name> <new-directory>', 'import <name> <image> [options]', 'portability check')) {
        Assert-EzVmTrue -Condition ($commands -ccontains $required) -Message ("Help omits the implemented command '$required'.")
    }
    $help = @(Write-EzVmResult -Result $result) -join "`n"
    Assert-EzVmTrue -Condition ($help -match 'same baseline with a fresh overlay' -and $help -match 'independent sensitive stateful snapshot')
    Assert-EzVmTrue -Condition ($help -match '-ManifestPath, -Profile, -Cpus, -MemoryMiB')
    Assert-EzVmTrue -Condition ($help -match 'docs/PORTABILITY.md')
}
