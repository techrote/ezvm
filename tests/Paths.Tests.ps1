Add-EzVmTest -Name 'Paths: default root is independent of the current working directory' -ScriptBlock {
    $elsewhere = New-EzVmTestDirectory -Prefix 'unrelated working directory'
    $previous = Get-Location
    try {
        Set-Location -LiteralPath $elsewhere
        Assert-EzVmEqual -Actual (Get-EzVmRoot) -Expected $script:EzVmRepositoryRoot
        Assert-EzVmEqual -Actual (Get-EzVmPaths).Root -Expected $script:EzVmRepositoryRoot
    }
    finally {
        Set-Location -LiteralPath $previous.Path
        Remove-EzVmTestDirectory -Path $elsewhere
    }
}

Add-EzVmTest -Name 'Paths: every managed path follows a root containing spaces without creating state' -ScriptBlock {
    $root = New-EzVmCheckoutFixture
    try {
        $paths = Get-EzVmPaths -Root $root
        $expected = [ordered]@{
            Root = ''
            Config = 'config'
            Defaults = 'config/defaults.json'
            Runtime = 'runtime'
            UserConfig = 'runtime/config.json'
            Qemu = 'runtime/qemu'
            Cache = 'runtime/cache'
            Downloads = 'runtime/cache/downloads'
            SourceImages = 'runtime/cache/source-images'
            Keys = 'runtime/keys'
            Bases = 'runtime/bases'
            Instances = 'runtime/instances'
            Locks = 'runtime/locks'
        }
        Assert-EzVmEqual -Actual @($paths.PSObject.Properties.Name).Count -Expected $expected.Count
        foreach ($entry in $expected.GetEnumerator()) {
            $name = $entry.Key
            $wanted = $root
            if ($expected[$name]) { $wanted = Join-Path $root $expected[$name] }
            Assert-EzVmEqual -Actual $paths.$name -Expected $wanted -Message "Incorrect $name path."
            Assert-EzVmTrue -Condition ([IO.Path]::IsPathRooted($paths.$name)) -Message "$name is not absolute."
        }
        Assert-EzVmTrue -Condition (-not (Test-Path -LiteralPath $paths.Runtime)) -Message 'Path discovery created runtime state.'
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Paths: cold relocation works without Git metadata or the previous root' -ScriptBlock {
    $original = New-EzVmCheckoutFixture -Prefix 'original long-ish portable checkout'
    $relocated = New-EzVmTestDirectory -Prefix 'relocated portable checkout'
    try {
        Get-ChildItem -LiteralPath $original -Force | Copy-Item -Destination $relocated -Recurse -Force
        Remove-EzVmTestDirectory -Path $original
        $paths = Get-EzVmPaths -Root $relocated
        Assert-EzVmEqual -Actual $paths.Root -Expected $relocated
        Assert-EzVmEqual -Actual $paths.Instances -Expected (Join-Path $relocated 'runtime/instances')
        foreach ($property in $paths.PSObject.Properties) {
            Assert-EzVmTrue -Condition (-not $property.Value.Contains($original)) -Message 'Relocated paths still refer to the previous root.'
        }
        Assert-EzVmTrue -Condition (-not (Test-Path -LiteralPath (Join-Path $relocated '.git')))
    }
    finally {
        Remove-EzVmTestDirectory -Path $original
        Remove-EzVmTestDirectory -Path $relocated
    }
}

Add-EzVmTest -Name 'Paths: relative dot paths resolve to a complete checkout' -ScriptBlock {
    $root = New-EzVmCheckoutFixture
    $previous = Get-Location
    try {
        Set-Location -LiteralPath $root
        Assert-EzVmEqual -Actual (Get-EzVmRoot -Path '.') -Expected $root
        Assert-EzVmEqual -Actual (Get-EzVmPaths -Root '.').Defaults -Expected (Join-Path $root 'config/defaults.json')
    }
    finally {
        Set-Location -LiteralPath $previous.Path
        Remove-EzVmTestDirectory -Path $root
    }
}

Add-EzVmTest -Name 'Paths: empty, missing, incomplete and file roots fail with remediation' -ScriptBlock {
    $root = New-EzVmTestDirectory -Prefix 'incomplete checkout'
    try {
        $leaf = Join-Path $root 'not-a-directory.txt'
        [IO.File]::WriteAllText($leaf, 'fixture')
        foreach ($invalid in @('', ' ', (Join-Path $root 'missing'), $root, $leaf)) {
            Assert-EzVmThrows -ScriptBlock { Get-EzVmRoot -Path $invalid } -MessagePattern 'checkout|root' | Out-Null
        }
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}
