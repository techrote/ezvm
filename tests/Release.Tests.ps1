Add-EzVmTest -Name 'Release: public version and module manifest agree on 0.1.0' -ScriptBlock {
    $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $script:EzVmRepositoryRoot 'src/EzVm/EzVm.psd1')
    Assert-EzVmEqual -Actual ([string]$manifest.ModuleVersion) -Expected '0.1.0'
    Assert-EzVmEqual -Actual ([string]$manifest.PrivateData.EzVmVersion) -Expected '0.1.0'
    Assert-EzVmEqual -Actual (Get-EzVmVersion) -Expected '0.1.0'
}

Add-EzVmTest -Name 'Release: notes match exact reviewed provider pins and hosted WHPX limitation' -ScriptBlock {
    $root = $script:EzVmRepositoryRoot
    $qemu = Get-Content -LiteralPath (Join-Path $root 'manifests/qemu-windows.json') -Raw | ConvertFrom-Json
    $ubuntu = Get-Content -LiteralPath (Join-Path $root 'manifests/ubuntu-noble-amd64.json') -Raw | ConvertFrom-Json
    $notes = [IO.File]::ReadAllText((Join-Path $root 'docs/RELEASE-v0.1.0.md'))
    foreach ($value in @(
        [string]$qemu.qemu.version,
        [string]$qemu.qemu.providerBuild,
        [string]$qemu.qemu.digest,
        [string]$qemu.extractor.version,
        [string]$qemu.extractor.bootstrap.digest,
        [string]$qemu.extractor.package.digest,
        [string]$ubuntu.publication,
        [string]$ubuntu.sha256
    )) {
        Assert-EzVmTrue -Condition $notes.Contains($value) -Message ('Release notes omitted reviewed pin: ' + $value)
    }
    Assert-EzVmTrue -Condition ($notes -match 'WHPX execution.*SKIP|WHPX.*capability SKIP') -Message 'Release notes must explicitly refuse a hosted WHPX PASS.'
}

Add-EzVmTest -Name 'Release: deterministic package is source-only, self-describing and executable' -ScriptBlock {
    $first = New-EzVmTestDirectory -Prefix 'release package one'
    $second = New-EzVmTestDirectory -Prefix 'release package two'
    $extract = New-EzVmTestDirectory -Prefix 'release extracted'
    try {
        $scriptPath = Join-Path $script:EzVmRepositoryRoot 'scripts/New-EzVmReleasePackage.ps1'
        $one = & $scriptPath -Root $script:EzVmRepositoryRoot -OutputDirectory $first -Version '0.1.0'
        $two = & $scriptPath -Root $script:EzVmRepositoryRoot -OutputDirectory $second -Version '0.1.0'

        Assert-EzVmEqual -Actual $one.Version -Expected '0.1.0'
        Assert-EzVmEqual -Actual $one.SourceCommit -Expected $two.SourceCommit
        Assert-EzVmEqual -Actual $one.SourceTree -Expected $two.SourceTree
        Assert-EzVmEqual -Actual $one.PackageSha256 -Expected $two.PackageSha256
        Assert-EzVmEqual -Actual (Get-FileHash -LiteralPath $one.PackagePath -Algorithm SHA256).Hash.ToLowerInvariant() -Expected $one.PackageSha256

        $sidecar = [IO.File]::ReadAllText($one.ChecksumPath).Trim()
        Assert-EzVmEqual -Actual $sidecar -Expected ($one.PackageSha256 + '  ezvm-0.1.0.zip')

        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        $archive = [IO.Compression.ZipFile]::OpenRead($one.PackagePath)
        try {
            $names = @($archive.Entries | ForEach-Object { $_.FullName })
            foreach ($required in @(
                'ezvm-0.1.0/ezvm.ps1',
                'ezvm-0.1.0/README.md',
                'ezvm-0.1.0/THIRD-PARTY-NOTICES.md',
                'ezvm-0.1.0/docs/GETTING-STARTED.md',
                'ezvm-0.1.0/docs/RELEASE-v0.1.0.md',
                'ezvm-0.1.0/docs/WHPX-QUALIFICATION.md',
                'ezvm-0.1.0/manifests/qemu-windows.json',
                'ezvm-0.1.0/manifests/ubuntu-noble-amd64.json',
                'ezvm-0.1.0/RELEASE-METADATA.json'
            )) {
                Assert-EzVmTrue -Condition ($names -ccontains $required) -Message ('Release package omitted ' + $required)
            }
            foreach ($name in $names) {
                Assert-EzVmTrue -Condition ($name.StartsWith('ezvm-0.1.0/', [StringComparison]::Ordinal)) -Message 'Release ZIP contains content outside its versioned root.'
                Assert-EzVmTrue -Condition ($name -notmatch '/(?:runtime|cache|artifacts|tests|scripts|\.github)/') -Message ('Release ZIP contains generated/test/workflow/tooling content: ' + $name)
                Assert-EzVmTrue -Condition ($name -notmatch '(?i)\.(?:qcow2?|img|iso|vhdx?|vmdk|vdi|raw|exe|dll|msi|zip|7z|pem|key|pfx|token)$') -Message ('Release ZIP contains a binary/secret-like payload: ' + $name)
            }

            $metadataEntry = @($archive.Entries | Where-Object { $_.FullName -ceq 'ezvm-0.1.0/RELEASE-METADATA.json' })
            Assert-EzVmEqual -Actual $metadataEntry.Count -Expected 1
            $reader = New-Object IO.StreamReader($metadataEntry[0].Open(), (New-Object Text.UTF8Encoding($false, $true)))
            try { $metadata = $reader.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop }
            finally { $reader.Dispose() }
            Assert-EzVmEqual -Actual $metadata.version -Expected '0.1.0'
            Assert-EzVmEqual -Actual $metadata.sourceCommit -Expected $one.SourceCommit
            Assert-EzVmEqual -Actual $metadata.sourceTree -Expected $one.SourceTree
            Assert-EzVmEqual -Actual $metadata.thirdPartyBinariesIncluded -Expected $false
            Assert-EzVmEqual -Actual @($metadata.files).Count -Expected $one.FileCount
        }
        finally { $archive.Dispose() }

        [IO.Compression.ZipFile]::ExtractToDirectory($one.PackagePath, $extract)
        $packageRoot = Join-Path $extract 'ezvm-0.1.0'
        $entry = "'" + (Join-Path $packageRoot 'ezvm.ps1').Replace("'", "''") + "'"
        $command = '$value = & ' + $entry + ' version -Json | ConvertFrom-Json; if (-not $value.success -or $value.data.version -cne ''0.1.0'') { exit 93 }; [Console]::Write($value.data.version); exit 0'
        $result = Invoke-EzVmTestPowerShell -CommandText $command -WorkingDirectory $packageRoot
        Assert-EzVmEqual -Actual $result.ExitCode -Expected 0
        Assert-EzVmEqual -Actual $result.StandardOutput -Expected '0.1.0'
        Assert-EzVmEqual -Actual $result.StandardError -Expected ''
    }
    finally {
        Remove-EzVmTestDirectory $first
        Remove-EzVmTestDirectory $second
        Remove-EzVmTestDirectory $extract
    }
}
