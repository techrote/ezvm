function Assert-EzVmBaseRecipeFields {
    param([object]$Value, [string[]]$Expected, [string]$Description)
    if ($Value -isnot [pscustomobject]) { throw "$Description must be a JSON object." }
    $actual = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($name in $actual) {
        if ($Expected -cnotcontains $name) { throw "$Description contains unknown field '$name'." }
    }
    foreach ($name in $Expected) {
        if ($actual -cnotcontains $name) { throw "$Description is missing required field '$name'." }
    }
}

function Assert-EzVmBaseRecipeInteger {
    param([AllowNull()][object]$Value, [int]$Minimum, [int]$Maximum, [string]$Description)
    $integer = $Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or
        $Value -is [int64] -or $Value -is [uint16] -or $Value -is [uint32] -or $Value -is [uint64]
    if (-not $integer -or $Value -lt $Minimum -or $Value -gt $Maximum) {
        throw "$Description must be an integer from $Minimum to $Maximum."
    }
}

function Get-EzVmBaseRecipe {
    [CmdletBinding()]
    param([string]$Root = $script:EzVmDefaultRoot)

    $paths = Get-EzVmPaths -Root $Root
    $recipe = Read-EzVmJson -Path $paths.BaseBaseline -SchemaVersion 1
    Assert-EzVmBaseRecipeFields -Value $recipe -Expected @(
        'schemaVersion', 'recipeVersion', 'virtualSizeGiB', 'cpus', 'memoryMiB',
        'machine', 'seedGuestAddress', 'seedGuestPort', 'packages', 'requiredCommands'
    ) -Description 'Prepared-base recipe'

    if ($recipe.recipeVersion -isnot [string] -or $recipe.recipeVersion -cnotmatch '^[0-9]+$') {
        throw "Prepared-base recipeVersion must be a non-empty numeric string."
    }
    Assert-EzVmBaseRecipeInteger -Value $recipe.virtualSizeGiB -Minimum 8 -Maximum 256 -Description 'Prepared-base virtualSizeGiB'
    Assert-EzVmBaseRecipeInteger -Value $recipe.cpus -Minimum 1 -Maximum 32 -Description 'Prepared-base cpus'
    Assert-EzVmBaseRecipeInteger -Value $recipe.memoryMiB -Minimum 1024 -Maximum 65536 -Description 'Prepared-base memoryMiB'
    Assert-EzVmBaseRecipeInteger -Value $recipe.seedGuestPort -Minimum 1024 -Maximum 65535 -Description 'Prepared-base seedGuestPort'

    if ($recipe.machine -cne 'q35') {
        throw "Prepared-base machine must be the explicit v0.1 'q35' baseline."
    }
    if ($recipe.seedGuestAddress -cne '10.0.2.100') {
        throw "Prepared-base seedGuestAddress must remain the reserved guest-only v0.1 address 10.0.2.100."
    }

    $packages = @($recipe.packages)
    if ($packages.Count -eq 0) { throw 'Prepared-base package list must not be empty.' }
    foreach ($package in $packages) {
        if ($package -isnot [string] -or $package -cnotmatch '^[a-z0-9][a-z0-9+.-]*$') {
            throw "Prepared-base package name '$package' is invalid."
        }
    }

    $commands = @($recipe.requiredCommands)
    if ($commands.Count -eq 0) { throw 'Prepared-base requiredCommands must not be empty.' }
    foreach ($command in $commands) {
        if ($command -isnot [string] -or $command -cnotmatch '^[A-Za-z0-9][A-Za-z0-9+._-]*$') {
            throw "Prepared-base required command '$command' is invalid."
        }
    }
    return $recipe
}

function Get-EzVmBaseProvisioningDigest {
    [CmdletBinding()]
    param([string]$Root = $script:EzVmDefaultRoot)

    $paths = Get-EzVmPaths -Root $Root
    $files = [ordered]@{
        'baseline.json' = $paths.BaseBaseline
        'meta-data.yaml' = $paths.BaseMetaDataTemplate
        'user-data.yaml' = $paths.BaseUserDataTemplate
    }

    $stream = New-Object System.IO.MemoryStream
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        foreach ($name in @($files.Keys | Sort-Object)) {
            $path = $files[$name]
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Prepared-base provisioning source is missing: $path"
            }
            $nameBytes = [Text.Encoding]::UTF8.GetBytes($name)
            $stream.Write($nameBytes, 0, $nameBytes.Length)
            $stream.WriteByte(0)
            $bytes = [IO.File]::ReadAllBytes($path)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.WriteByte(0)
        }
        $stream.Position = 0
        $hash = $sha.ComputeHash($stream)
        return ([BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
        $stream.Dispose()
    }
}

function New-EzVmBaseSeedData {
    [CmdletBinding()]
    param(
        [string]$Root = $script:EzVmDefaultRoot,
        [Parameter(Mandatory = $true)][string]$BuildId
    )

    if ($BuildId -cnotmatch '^[a-f0-9]{32}$') {
        throw 'Prepared-base build ID must be exactly 32 lowercase hexadecimal characters.'
    }

    $paths = Get-EzVmPaths -Root $Root
    $recipe = Get-EzVmBaseRecipe -Root $Root
    $userTemplate = [IO.File]::ReadAllText($paths.BaseUserDataTemplate, (New-Object Text.UTF8Encoding($false, $true)))
    $metaTemplate = [IO.File]::ReadAllText($paths.BaseMetaDataTemplate, (New-Object Text.UTF8Encoding($false, $true)))

    $packageLines = @($recipe.packages | ForEach-Object { '  - ' + $_ }) -join [Environment]::NewLine
    $requiredCommands = @($recipe.requiredCommands) -join ' '

    $userData = $userTemplate.Replace('__BUILD_ID__', $BuildId).
        Replace('__PACKAGE_LINES__', $packageLines).
        Replace('__REQUIRED_COMMANDS__', $requiredCommands)
    $metaData = $metaTemplate.Replace('__BUILD_ID__', $BuildId)

    if ($userData -match '__[A-Z0-9_]+__' -or $metaData -match '__[A-Z0-9_]+__') {
        throw 'Prepared-base cloud-init generation left an unresolved template placeholder.'
    }
    if ($userData -match '(?im)BEGIN .*PRIVATE KEY|github_pat_|ghp_[A-Za-z0-9]') {
        throw 'Prepared-base cloud-init unexpectedly contains credential-like material.'
    }

    return [pscustomobject][ordered]@{
        BuildId = $BuildId
        UserData = $userData
        MetaData = $metaData
        Recipe = $recipe
        ProvisioningDigest = Get-EzVmBaseProvisioningDigest -Root $Root
    }
}

function Get-EzVmBaseFirmwarePaths {
    [CmdletBinding()]
    param(
        [string]$Root = $script:EzVmDefaultRoot,
        [Parameter(Mandatory = $true)][string]$StagingDirectory
    )

    $paths = Get-EzVmPaths -Root $Root
    $firmwareRoot = Join-Path $paths.Qemu 'share'
    $code = Join-Path $firmwareRoot 'edk2-x86_64-code.fd'
    $varsTemplate = Join-Path $firmwareRoot 'edk2-i386-vars.fd'
    foreach ($path in @($code, $varsTemplate)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Managed QEMU firmware is incomplete: missing '$path'. Re-run bootstrap and retry."
        }
    }

    [void][IO.Directory]::CreateDirectory($StagingDirectory)
    $vars = Join-Path $StagingDirectory 'uefi-vars.fd'
    [IO.File]::Copy($varsTemplate, $vars, $false)
    return [pscustomobject][ordered]@{
        Code = [IO.Path]::GetFullPath($code)
        Variables = [IO.Path]::GetFullPath($vars)
        CodeName = 'edk2-x86_64-code.fd'
        VariablesTemplateName = 'edk2-i386-vars.fd'
    }
}

function New-EzVmBaseQemuArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BuildId,
        [Parameter(Mandatory = $true)][object]$Recipe,
        [Parameter(Mandatory = $true)][string]$StagingDisk,
        [Parameter(Mandatory = $true)][string]$FirmwareCode,
        [Parameter(Mandatory = $true)][string]$FirmwareVariables,
        [Parameter(Mandatory = $true)][string]$SerialLog,
        [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$SeedHostPort,
        [ValidateSet('whpx', 'tcg')][string]$Accelerator = 'whpx'
    )

    if ($BuildId -cnotmatch '^[a-f0-9]{32}$') { throw 'Invalid prepared-base build ID.' }
    $seedUrl = 'http://' + $Recipe.seedGuestAddress + ':' + $Recipe.seedGuestPort + '/'
    if (-not $seedUrl.EndsWith('/', [StringComparison]::Ordinal)) {
        throw 'NoCloud seed URL must end in a trailing slash.'
    }
    $guestForward = 'guestfwd=tcp:' + $Recipe.seedGuestAddress + ':' + $Recipe.seedGuestPort +
        '-tcp:127.0.0.1:' + $SeedHostPort

    $arguments = New-Object 'System.Collections.Generic.List[string]'
    foreach ($pair in @(
        @('-name', ('ezvm-base-build-' + $BuildId)),
        @('-machine', [string]$Recipe.machine),
        @('-accel', $(if ($Accelerator -ceq 'tcg') { 'tcg,thread=multi' } else { 'whpx' })),
        @('-m', [string]$Recipe.memoryMiB),
        @('-smp', [string]$Recipe.cpus),
        @('-display', 'none'),
        @('-monitor', 'none'),
        @('-serial', ('file:' + [IO.Path]::GetFullPath($SerialLog))),
        @('-drive', ('if=pflash,format=raw,readonly=on,file=' + [IO.Path]::GetFullPath($FirmwareCode))),
        @('-drive', ('if=pflash,format=raw,file=' + [IO.Path]::GetFullPath($FirmwareVariables))),
        @('-drive', ('if=none,id=osdisk,format=qcow2,file=' + [IO.Path]::GetFullPath($StagingDisk))),
        @('-device', 'virtio-blk-pci,drive=osdisk,bootindex=0'),
        @('-netdev', ('user,id=net0,ipv6=off,' + $guestForward)),
        @('-device', 'virtio-net-pci,netdev=net0'),
        @('-smbios', ('type=1,serial=ds=nocloud;s=' + $seedUrl)),
        @('-boot', 'order=c,strict=on'),
        @('-rtc', 'base=utc')
    )) {
        $arguments.Add($pair[0])
        $arguments.Add($pair[1])
    }
    if ($Accelerator -ceq 'tcg') {
        $arguments.Add('-cpu')
        $arguments.Add('max')
    }
    $arguments.Add('-no-reboot')

    return [pscustomobject][ordered]@{
        Arguments = $arguments.ToArray()
        SeedUrl = $seedUrl
        GuestForward = $guestForward
        Accelerator = $Accelerator
    }
}
