function New-EzVmSourceImageFixture {
    param(
        [string]$Root,
        [string]$Payload = 'synthetic Ubuntu cloud image fixture',
        [string]$Release = '24.04',
        [string]$Codename = 'noble',
        [string]$Architecture = 'amd64',
        [string]$Publication = '20260926',
        [string]$Url,
        [string]$FileName = 'ubuntu-24.04-server-cloudimg-amd64.img'
    )

    $payloadPath = Join-Path $Root 'synthetic-source-payload.bin'
    [IO.File]::WriteAllBytes($payloadPath, [Text.Encoding]::UTF8.GetBytes($Payload))
    $digest = Get-EzVmFileDigest -Path $payloadPath -Algorithm SHA256
    if (-not $PSBoundParameters.ContainsKey('Url')) {
        $Url = 'https://cloud-images.ubuntu.com/releases/noble/release-' + $Publication + '/' + $FileName
    }
    $manifestPath = Join-Path $Root 'synthetic-ubuntu-manifest.json'
    $manifest = [pscustomobject][ordered]@{
        schemaVersion = 1
        provider = 'Canonical Ubuntu Cloud Images'
        release = $Release
        codename = $Codename
        architecture = $Architecture
        publication = $Publication
        url = $Url
        filename = $FileName
        sha256 = $digest
    }
    Write-EzVmJson -Path $manifestPath -Value $manifest -SchemaVersion 1
    return [pscustomobject]@{ PayloadPath = $payloadPath; Digest = $digest; ManifestPath = $manifestPath }
}

Add-EzVmTest -Name 'Source image: checked-in Noble manifest is exact, dated and reviewed' -ScriptBlock {
    $manifest = Get-EzVmSourceImageManifest -Root $script:EzVmRepositoryRoot
    Assert-EzVmEqual -Actual $manifest.release -Expected '24.04'
    Assert-EzVmEqual -Actual $manifest.codename -Expected 'noble'
    Assert-EzVmEqual -Actual $manifest.architecture -Expected 'amd64'
    Assert-EzVmEqual -Actual $manifest.publication -Expected '20260926'
    Assert-EzVmEqual -Actual $manifest.filename -Expected 'ubuntu-24.04-server-cloudimg-amd64.img'
    Assert-EzVmEqual -Actual $manifest.sha256 -Expected '6a81c37564db9b1ee84e141922625e1d7c5b389b99bb3c572e0243607d5bb4d2'
    Assert-EzVmTrue -Condition ($manifest.url -match '/release-20260926/') -Message 'Manifest must not follow a mutable current alias.'
}

Add-EzVmTest -Name 'Source image: acquisition verifies fixture content, records provenance and never mutates source' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'source image acquire with spaces'
    try {
        $fixture = New-EzVmSourceImageFixture -Root $root
        $before = [IO.File]::ReadAllBytes($fixture.PayloadPath)
        $payloadPath = $fixture.PayloadPath
        $downloader = { param($url, $temporary) [IO.File]::Copy($payloadPath, $temporary, $false) }.GetNewClosure()
        $result = Invoke-EzVmSourceImageAcquire -Root $root -ManifestPath $fixture.ManifestPath -Downloader $downloader

        Assert-EzVmTrue -Condition $result.downloaded
        Assert-EzVmTrue -Condition $result.immutable
        Assert-EzVmEqual -Actual $result.sha256 -Expected $fixture.Digest
        Assert-EzVmEqual -Actual (Get-EzVmFileDigest -Path $result.path -Algorithm SHA256) -Expected $fixture.Digest
        Assert-EzVmEqual -Actual ([Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.PayloadPath))) -Expected ([Convert]::ToBase64String($before))
        Assert-EzVmTrue -Condition (Test-Path -LiteralPath $result.provenancePath -PathType Leaf)
        $provenance = Read-EzVmJson -Path $result.provenancePath
        Assert-EzVmEqual -Actual $provenance.sha256 -Expected $fixture.Digest
        Assert-EzVmEqual -Actual $provenance.architecture -Expected 'amd64'
        Assert-EzVmTrue -Condition ($provenance.recordedAt -is [string])
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Source image: cached-good acquisition is idempotent and preserves provenance' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'source image cache idempotent'
    try {
        $fixture = New-EzVmSourceImageFixture -Root $root
        $payloadPath = $fixture.PayloadPath
        $downloader = { param($url, $temporary) [IO.File]::Copy($payloadPath, $temporary, $false) }.GetNewClosure()
        $first = Invoke-EzVmSourceImageAcquire -Root $root -ManifestPath $fixture.ManifestPath -Downloader $downloader
        $provenanceBefore = [IO.File]::ReadAllText($first.provenancePath)
        $mustNotDownload = { throw 'valid cached source must not redownload' }
        $second = Invoke-EzVmSourceImageAcquire -Root $root -ManifestPath $fixture.ManifestPath -Downloader $mustNotDownload
        Assert-EzVmTrue -Condition (-not $second.downloaded)
        Assert-EzVmEqual -Actual $second.path -Expected $first.path
        Assert-EzVmEqual -Actual ([IO.File]::ReadAllText($second.provenancePath)) -Expected $provenanceBefore
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Source image: corrupt cached image is rejected and replaced only by matching content' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'source image corrupt cache'
    try {
        $fixture = New-EzVmSourceImageFixture -Root $root
        $paths = Get-EzVmPaths -Root $root
        [void][IO.Directory]::CreateDirectory($paths.SourceImages)
        $authoritative = Join-Path $paths.SourceImages 'ubuntu-24.04-server-cloudimg-amd64.img'
        [IO.File]::WriteAllText($authoritative, 'corrupt cache')
        $payloadPath = $fixture.PayloadPath
        $downloader = { param($url, $temporary) [IO.File]::Copy($payloadPath, $temporary, $false) }.GetNewClosure()
        $result = Invoke-EzVmSourceImageAcquire -Root $root -ManifestPath $fixture.ManifestPath -Downloader $downloader
        Assert-EzVmTrue -Condition $result.downloaded
        Assert-EzVmEqual -Actual (Get-EzVmFileDigest -Path $authoritative -Algorithm SHA256) -Expected $fixture.Digest
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Source image: failed recovery of a corrupt cache leaves no authoritative image' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'source image failed recovery'
    try {
        $fixture = New-EzVmSourceImageFixture -Root $root
        $paths = Get-EzVmPaths -Root $root
        [void][IO.Directory]::CreateDirectory($paths.SourceImages)
        $authoritative = Join-Path $paths.SourceImages 'ubuntu-24.04-server-cloudimg-amd64.img'
        [IO.File]::WriteAllText($authoritative, 'corrupt cache')
        Assert-EzVmThrows -ScriptBlock {
            Invoke-EzVmSourceImageAcquire -Root $root -ManifestPath $fixture.ManifestPath -Downloader { throw 'interrupted source transfer' }
        } -MessagePattern 'interrupted source transfer' | Out-Null
        Assert-EzVmTrue -Condition (-not (Test-Path -LiteralPath $authoritative))
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Source image: manifest rejects release, architecture, mutable URL and unknown fields' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'source manifest validation'
    try {
        $wrongArch = New-EzVmSourceImageFixture -Root $root -Architecture 'arm64'
        Assert-EzVmThrows -ScriptBlock { Get-EzVmSourceImageManifest -Root $root -ManifestPath $wrongArch.ManifestPath } -MessagePattern "architecture must be 'amd64'" | Out-Null

        $wrongRelease = New-EzVmSourceImageFixture -Root $root -Release '24.10'
        Assert-EzVmThrows -ScriptBlock { Get-EzVmSourceImageManifest -Root $root -ManifestPath $wrongRelease.ManifestPath } -MessagePattern '24.04 LTS Noble' | Out-Null

        $mutable = New-EzVmSourceImageFixture -Root $root -Url 'https://cloud-images.ubuntu.com/releases/noble/current/ubuntu-24.04-server-cloudimg-amd64.img'
        Assert-EzVmThrows -ScriptBlock { Get-EzVmSourceImageManifest -Root $root -ManifestPath $mutable.ManifestPath } -MessagePattern 'dated Noble release' | Out-Null

        $value = Read-EzVmJson -Path $wrongArch.ManifestPath
        $value | Add-Member -NotePropertyName unexpected -NotePropertyValue 'no'
        Write-EzVmJson -Path $wrongArch.ManifestPath -Value $value
        Assert-EzVmThrows -ScriptBlock { Get-EzVmSourceImageManifest -Root $root -ManifestPath $wrongArch.ManifestPath } -MessagePattern 'unknown field' | Out-Null
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Source image: malformed old provenance is replaced rather than crashing strict mode' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'source provenance recovery'
    try {
        $fixture = New-EzVmSourceImageFixture -Root $root
        $payloadPath = $fixture.PayloadPath
        $downloader = { param($url, $temporary) [IO.File]::Copy($payloadPath, $temporary, $false) }.GetNewClosure()
        $first = Invoke-EzVmSourceImageAcquire -Root $root -ManifestPath $fixture.ManifestPath -Downloader $downloader
        Write-EzVmJson -Path $first.provenancePath -Value ([pscustomobject][ordered]@{ schemaVersion = 1; legacy = 'incomplete' })
        $second = Invoke-EzVmSourceImageAcquire -Root $root -ManifestPath $fixture.ManifestPath -Downloader { throw 'cache hit should avoid downloader' }
        $provenance = Read-EzVmJson -Path $second.provenancePath
        Assert-EzVmEqual -Actual $provenance.sha256 -Expected $fixture.Digest
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}
