# Optional resources for a newly copied, disposable qualification root only.
function Set-EzVmQualificationResources {
    param([Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][ValidateRange(1, 32)][int]$Cpus)
    $paths = Get-EzVmPaths -Root $Root
    if ($paths.Root -ieq [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))) { throw 'Qualification resources cannot modify their source checkout.' }
    if (Test-Path -LiteralPath $paths.Runtime) { throw 'Qualification resources require a fresh root without runtime state.' }
    $configuration = Get-EzVmConfiguration -Root $Root
    $recipe = Get-EzVmBaseRecipe -Root $Root
    $overrides = [ordered]@{ schemaVersion = 1; profiles = [ordered]@{} }
    foreach ($name in @('light', 'normal', 'heavy')) {
        $overrides.profiles[$name] = [ordered]@{ cpus = $Cpus }
    }
    # All memory, profile names and other defaults stay as reviewed. The base
    # builder also uses the requested CPU count; its recipe identity changes.
    $recipe.cpus = $Cpus
    Write-EzVmJson -Path $paths.BaseBaseline -Value $recipe
    [void][IO.Directory]::CreateDirectory($paths.Runtime)
    Write-EzVmJson -Path $paths.UserConfig -Value $overrides
    $observed = Get-EzVmConfiguration -Root $Root
    foreach ($name in @('light', 'normal', 'heavy')) {
        if ($observed.profiles[$name].cpus -ne $Cpus -or
            $observed.profiles[$name].memoryMiB -ne $configuration.profiles[$name].memoryMiB) {
            throw 'Qualification CPU override did not preserve profile resources.'
        }
    }
    if ((Get-EzVmBaseRecipe -Root $Root).cpus -ne $Cpus) { throw 'Qualification base CPU override failed.' }
}
