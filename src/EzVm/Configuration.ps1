function ConvertTo-EzVmConfigurationMap {
    param([AllowNull()][object]$Value)

    if ($Value -is [System.Collections.IDictionary]) {
        $map = [ordered]@{}
        foreach ($key in $Value.get_Keys()) {
            $map[$key] = ConvertTo-EzVmConfigurationMap -Value $Value[$key]
        }
        return $map
    }
    if ($Value -is [pscustomobject]) {
        $map = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $map[$property.Name] = ConvertTo-EzVmConfigurationMap -Value $property.Value
        }
        return $map
    }
    # Keep arrays intact so validation can reject them instead of silently unwrapping them.
    if ($Value -is [array]) { return ,$Value }
    return $Value
}

function Assert-EzVmConfigurationKeys {
    param([object]$Value, [string[]]$Keys, [string]$Location)

    if ($Value -isnot [System.Collections.IDictionary]) {
        throw "Configuration '$Location' must be a JSON object. Restore its documented fields."
    }
    foreach ($key in $Value.get_Keys()) {
        if ($Keys -cnotcontains $key) {
            throw "Unknown configuration field '$Location.$key'. Remove it or use a documented field name."
        }
    }
    foreach ($key in $Keys) {
        if (@($Value.get_Keys()) -cnotcontains $key) {
            throw "Missing configuration field '$Location.$key'. Restore config/defaults.json from the checkout."
        }
    }
}

function Assert-EzVmConfigurationInteger {
    param([AllowNull()][object]$Value, [long]$Minimum, [long]$Maximum, [string]$Location)

    $isInteger = $Value -is [int] -or $Value -is [long] -or $Value -is [short] -or
        $Value -is [byte] -or $Value -is [uint32] -or $Value -is [uint64] -or
        $Value -is [uint16] -or $Value -is [sbyte]
    if (-not $isInteger -or $Value -lt $Minimum -or $Value -gt $Maximum) {
        throw "Configuration '$Location' must be an integer from $Minimum to $Maximum. Correct the configuration and retry."
    }
}

function Assert-EzVmConfiguration {
    param([object]$Value)

    Assert-EzVmConfigurationKeys $Value @('schemaVersion', 'defaultProfile', 'profiles', 'ssh', 'timeouts') 'config'
    Assert-EzVmConfigurationInteger $Value.schemaVersion 1 1 'schemaVersion'
    Assert-EzVmConfigurationKeys $Value.profiles @('light', 'normal', 'heavy') 'profiles'
    if ($Value.defaultProfile -isnot [string] -or @('light', 'normal', 'heavy') -cnotcontains $Value.defaultProfile) {
        throw "Configuration 'defaultProfile' must be light, normal or heavy. Choose an existing profile."
    }
    foreach ($name in @('light', 'normal', 'heavy')) {
        $profile = $Value.profiles[$name]
        Assert-EzVmConfigurationKeys $profile @('cpus', 'memoryMiB') "profiles.$name"
        Assert-EzVmConfigurationInteger $profile.cpus 1 256 "profiles.$name.cpus"
        Assert-EzVmConfigurationInteger $profile.memoryMiB 512 1048576 "profiles.$name.memoryMiB"
    }
    Assert-EzVmConfigurationKeys $Value.ssh @('portRangeStart', 'portRangeEnd') 'ssh'
    Assert-EzVmConfigurationInteger $Value.ssh.portRangeStart 1024 65535 'ssh.portRangeStart'
    Assert-EzVmConfigurationInteger $Value.ssh.portRangeEnd 1024 65535 'ssh.portRangeEnd'
    if ($Value.ssh.portRangeStart -gt $Value.ssh.portRangeEnd) {
        throw "Configuration 'ssh.portRangeStart' must not exceed portRangeEnd. Correct the port range and retry."
    }
    Assert-EzVmConfigurationKeys $Value.timeouts @('processSeconds') 'timeouts'
    Assert-EzVmConfigurationInteger $Value.timeouts.processSeconds 1 3600 'timeouts.processSeconds'
}

function Merge-EzVmConfigurationMap {
    param([System.Collections.IDictionary]$Defaults, [System.Collections.IDictionary]$Override, [string]$Location = 'config')

    foreach ($key in $Override.get_Keys()) {
        if (@($Defaults.get_Keys()) -cnotcontains $key) {
            throw "Unknown configuration field '$Location.$key'. Remove it or use a documented field name."
        }
        if ($Defaults[$key] -is [System.Collections.IDictionary]) {
            if ($Override[$key] -isnot [System.Collections.IDictionary]) {
                throw "Configuration '$Location.$key' must be a JSON object. Supply a nested override, not a replacement scalar or array."
            }
            Merge-EzVmConfigurationMap -Defaults $Defaults[$key] -Override $Override[$key] -Location "$Location.$key"
        }
        else {
            $Defaults[$key] = $Override[$key]
        }
    }
}

function Get-EzVmConfiguration {
    [CmdletBinding()]
    param([string]$Root = $script:EzVmDefaultRoot)

    $paths = Get-EzVmPaths -Root $Root
    $configuration = ConvertTo-EzVmConfigurationMap (Read-EzVmJson -Path $paths.Defaults)
    Assert-EzVmConfiguration -Value $configuration
    if (Test-Path -LiteralPath $paths.UserConfig) {
        $userConfiguration = ConvertTo-EzVmConfigurationMap (Read-EzVmJson -Path $paths.UserConfig)
        Merge-EzVmConfigurationMap -Defaults $configuration -Override $userConfiguration
        Assert-EzVmConfiguration -Value $configuration
    }
    # Every load creates a fresh value; callers cannot mutate a cached global default.
    return [pscustomobject]$configuration
}
