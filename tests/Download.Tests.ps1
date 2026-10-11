Add-EzVmTest -Name 'Download: accepts a digest-matching artifact and promotes it atomically' -ScriptBlock {
    $root = New-EzVmTestDirectory -Prefix 'verified download'
    try {
        $payloadPath = Join-Path $root 'payload.bin'
        [IO.File]::WriteAllBytes($payloadPath, [Text.Encoding]::UTF8.GetBytes('verified-payload'))
        $digest = Get-EzVmFileDigest -Path $payloadPath -Algorithm SHA256
        $destination = Join-Path $root 'cache with spaces'
        $downloader = { param($url, $temporary) [IO.File]::Copy($payloadPath, $temporary, $false) }.GetNewClosure()
        $result = Get-EzVmVerifiedArtifact -Url 'https://example.invalid/artifact.bin' -FileName 'artifact.bin' -Algorithm SHA256 -ExpectedDigest $digest -DestinationDirectory $destination -Downloader $downloader
        Assert-EzVmTrue -Condition $result.Downloaded
        Assert-EzVmEqual -Actual $result.Digest -Expected $digest
        Assert-EzVmEqual -Actual (Get-EzVmFileDigest -Path $result.Path -Algorithm SHA256) -Expected $digest
        Assert-EzVmEqual -Actual @(Get-ChildItem -LiteralPath $destination -Filter '.ezvm-download-*.tmp' -Force).Count -Expected 0
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Download: rejects digest mismatch without authoritative cache content' -ScriptBlock {
    $root = New-EzVmTestDirectory -Prefix 'download mismatch'
    try {
        $destination = Join-Path $root 'cache'
        $wrongDigest = ('0' * 64)
        $downloader = {
            param($url, $temporary)
            [IO.File]::WriteAllBytes($temporary, [Text.Encoding]::UTF8.GetBytes('untrusted'))
        }
        Assert-EzVmThrows -ScriptBlock {
            Get-EzVmVerifiedArtifact -Url 'https://example.invalid/artifact.bin' -FileName 'artifact.bin' -Algorithm SHA256 -ExpectedDigest $wrongDigest -DestinationDirectory $destination -Downloader $downloader
        } -MessagePattern 'failed SHA256 verification' | Out-Null
        Assert-EzVmTrue -Condition (-not (Test-Path -LiteralPath (Join-Path $destination 'artifact.bin')))
        Assert-EzVmEqual -Actual @(Get-ChildItem -LiteralPath $destination -Filter '.ezvm-download-*.tmp' -Force).Count -Expected 0
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Download: interrupted partial download is cleaned and never promoted' -ScriptBlock {
    $root = New-EzVmTestDirectory -Prefix 'download interrupted'
    try {
        $destination = Join-Path $root 'cache'
        $downloader = {
            param($url, $temporary)
            [IO.File]::WriteAllBytes($temporary, [byte[]](1, 2, 3, 4))
            throw 'synthetic interrupted transfer'
        }
        Assert-EzVmThrows -ScriptBlock {
            Get-EzVmVerifiedArtifact -Url 'https://example.invalid/artifact.bin' -FileName 'artifact.bin' -Algorithm SHA256 -ExpectedDigest ('1' * 64) -DestinationDirectory $destination -Downloader $downloader
        } -MessagePattern 'synthetic interrupted transfer' | Out-Null
        Assert-EzVmTrue -Condition (-not (Test-Path -LiteralPath (Join-Path $destination 'artifact.bin')))
        Assert-EzVmEqual -Actual @(Get-ChildItem -LiteralPath $destination -Filter '.ezvm-download-*.tmp' -Force).Count -Expected 0
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Download: valid cached artifact is idempotent and does not invoke downloader' -ScriptBlock {
    $root = New-EzVmTestDirectory -Prefix 'download cached'
    try {
        $destination = Join-Path $root 'cache'
        [void][IO.Directory]::CreateDirectory($destination)
        $path = Join-Path $destination 'artifact.bin'
        [IO.File]::WriteAllBytes($path, [Text.Encoding]::UTF8.GetBytes('already-verified'))
        $digest = Get-EzVmFileDigest -Path $path -Algorithm SHA256
        $downloader = { throw 'downloader must not run for a valid cache hit' }
        $result = Get-EzVmVerifiedArtifact -Url 'https://example.invalid/artifact.bin' -FileName 'artifact.bin' -Algorithm SHA256 -ExpectedDigest $digest -DestinationDirectory $destination -Downloader $downloader
        Assert-EzVmTrue -Condition (-not $result.Downloaded)
        Assert-EzVmEqual -Actual $result.Path -Expected $path
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Download: corrupt cached artifact is removed and replaced only by verified content' -ScriptBlock {
    $root = New-EzVmTestDirectory -Prefix 'download replace corrupt'
    try {
        $destination = Join-Path $root 'cache'
        [void][IO.Directory]::CreateDirectory($destination)
        $path = Join-Path $destination 'artifact.bin'
        [IO.File]::WriteAllBytes($path, [Text.Encoding]::UTF8.GetBytes('corrupt'))
        $payloadPath = Join-Path $root 'good.bin'
        [IO.File]::WriteAllBytes($payloadPath, [Text.Encoding]::UTF8.GetBytes('replacement-verified'))
        $digest = Get-EzVmFileDigest -Path $payloadPath -Algorithm SHA256
        $downloader = { param($url, $temporary) [IO.File]::Copy($payloadPath, $temporary, $false) }.GetNewClosure()
        $result = Get-EzVmVerifiedArtifact -Url 'https://example.invalid/artifact.bin' -FileName 'artifact.bin' -Algorithm SHA256 -ExpectedDigest $digest -DestinationDirectory $destination -Downloader $downloader
        Assert-EzVmTrue -Condition $result.Downloaded
        Assert-EzVmEqual -Actual (Get-EzVmFileDigest -Path $path -Algorithm SHA256) -Expected $digest
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Download: failed replacement after corrupt cache leaves no trusted destination' -ScriptBlock {
    $root = New-EzVmTestDirectory -Prefix 'download corrupt failure'
    try {
        $destination = Join-Path $root 'cache'
        [void][IO.Directory]::CreateDirectory($destination)
        $path = Join-Path $destination 'artifact.bin'
        [IO.File]::WriteAllBytes($path, [Text.Encoding]::UTF8.GetBytes('known-bad-cache'))
        $downloader = { throw 'synthetic network failure' }
        Assert-EzVmThrows -ScriptBlock {
            Get-EzVmVerifiedArtifact -Url 'https://example.invalid/artifact.bin' -FileName 'artifact.bin' -Algorithm SHA256 -ExpectedDigest ('a' * 64) -DestinationDirectory $destination -Downloader $downloader
        } -MessagePattern 'synthetic network failure' | Out-Null
        Assert-EzVmTrue -Condition (-not (Test-Path -LiteralPath $path)) -Message 'Known-bad cache content must not survive as the authoritative artifact.'
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Download: rejects malformed digest, non-HTTPS URL and path-like filename' -ScriptBlock {
    $root = New-EzVmTestDirectory -Prefix 'download input validation'
    try {
        Assert-EzVmThrows -ScriptBlock {
            Get-EzVmVerifiedArtifact -Url 'https://example.invalid/a' -FileName 'a.bin' -Algorithm SHA256 -ExpectedDigest 'ABC' -DestinationDirectory $root -Downloader { }
        } -MessagePattern 'lowercase hexadecimal' | Out-Null
        Assert-EzVmThrows -ScriptBlock {
            Get-EzVmVerifiedArtifact -Url 'http://example.invalid/a' -FileName 'a.bin' -Algorithm SHA256 -ExpectedDigest ('a' * 64) -DestinationDirectory $root
        } -MessagePattern 'HTTPS' | Out-Null
        Assert-EzVmThrows -ScriptBlock {
            Get-EzVmVerifiedArtifact -Url 'https://example.invalid/a' -FileName '../a.bin' -Algorithm SHA256 -ExpectedDigest ('a' * 64) -DestinationDirectory $root -Downloader { }
        } -MessagePattern 'plain filename' | Out-Null
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}
