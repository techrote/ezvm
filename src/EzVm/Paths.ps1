function Get-EzVmRoot {
    [CmdletBinding()]
    param([string]$Path = $script:EzVmDefaultRoot)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'The ezvm root must be a directory containing ezvm.ps1 and config/defaults.json. Supply a complete checkout path.'
    }
    try {
        $directory = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($directory -isnot [System.IO.DirectoryInfo]) {
            throw 'The root is not a filesystem directory.'
        }
        $root = $directory.FullName
        foreach ($marker in @('ezvm.ps1', 'config/defaults.json')) {
            if (-not (Test-Path -LiteralPath (Join-Path $root $marker) -PathType Leaf)) {
                throw "Missing checkout file: $marker"
            }
        }
        return $root
    }
    catch {
        throw "Cannot use ezvm root '$Path': $($_.Exception.Message) Supply a complete ezvm checkout; a .git directory is not required."
    }
}

function Get-EzVmPaths {
    [CmdletBinding()]
    param([string]$Root = $script:EzVmDefaultRoot)

    $resolvedRoot = Get-EzVmRoot -Path $Root
    $runtime = Join-Path $resolvedRoot 'runtime'
    $cache = Join-Path $runtime 'cache'
    $config = Join-Path $resolvedRoot 'config'
    # Pure path calculation: reading help/configuration never creates runtime directories.
    return [pscustomobject][ordered]@{
        Root = $resolvedRoot
        Config = $config
        Defaults = Join-Path $config 'defaults.json'
        Runtime = $runtime
        UserConfig = Join-Path $runtime 'config.json'
        Qemu = Join-Path $runtime 'qemu'
        Cache = $cache
        Downloads = Join-Path $cache 'downloads'
        SourceImages = Join-Path $cache 'source-images'
        Keys = Join-Path $runtime 'keys'
        Bases = Join-Path $runtime 'bases'
        Instances = Join-Path $runtime 'instances'
        Locks = Join-Path $runtime 'locks'
    }
}
