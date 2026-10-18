. (Join-Path $script:EzVmRepositoryRoot 'scripts/QualificationResources.ps1')

Add-EzVmTest -Name 'Qualification resources: eight CPUs preserve profile memories and bind base recipe without changing defaults' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'qualification eight CPUs'
    try {
        $paths = Get-EzVmPaths -Root $root
        $defaultsBefore = Get-EzVmFileDigest -Path $paths.Defaults -Algorithm SHA256
        $recipeBefore = Get-EzVmBaseProvisioningDigest -Root $root
        Set-EzVmQualificationResources -Root $root -Cpus 8
        $config = Get-EzVmConfiguration -Root $root
        Assert-EzVmEqual $config.defaultProfile 'normal'
        foreach ($name in @('light', 'normal', 'heavy')) { Assert-EzVmEqual $config.profiles[$name].cpus 8 }
        Assert-EzVmEqual $config.profiles.light.memoryMiB 4096
        Assert-EzVmEqual $config.profiles.normal.memoryMiB 8192
        Assert-EzVmEqual $config.profiles.heavy.memoryMiB 16384
        Assert-EzVmEqual (Get-EzVmBaseRecipe -Root $root).cpus 8
        Assert-EzVmEqual (Get-EzVmFileDigest -Path $paths.Defaults -Algorithm SHA256) $defaultsBefore
        Assert-EzVmTrue ((Get-EzVmBaseProvisioningDigest -Root $root) -cne $recipeBefore)
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Qualification resources: existing runtime and invalid CPU requests refuse before mutation' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'qualification CPU refusals'
    try {
        $paths = Get-EzVmPaths -Root $root
        $before = Get-EzVmFileDigest -Path $paths.BaseBaseline -Algorithm SHA256
        foreach ($invalid in @(0, -1, 33)) { $null = Assert-EzVmThrows { Set-EzVmQualificationResources -Root $root -Cpus $invalid } }
        [void][IO.Directory]::CreateDirectory($paths.Runtime)
        [IO.File]::WriteAllText((Join-Path $paths.Runtime 'sentinel.txt'), 'unrelated')
        $null = Assert-EzVmThrows { Set-EzVmQualificationResources -Root $root -Cpus 8 } -MessagePattern 'fresh'
        Assert-EzVmEqual (Get-EzVmFileDigest -Path $paths.BaseBaseline -Algorithm SHA256) $before
        Assert-EzVmEqual ([IO.File]::ReadAllText((Join-Path $paths.Runtime 'sentinel.txt'))) 'unrelated'
        $null = Assert-EzVmThrows { Set-EzVmQualificationResources -Root $script:EzVmRepositoryRoot -Cpus 8 } -MessagePattern 'source checkout'
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}
