Add-EzVmTest -Name 'Download: file hashing matches independent SHA256 and SHA512 vectors with either algorithm spelling' -ScriptBlock {
    $root = New-EzVmTestDirectory -Prefix 'SHA vectors [spaces]'
    try {
        # Fixed expectations are independent of the selected .NET provider.
        $vectors = @(
            @{
                Name = 'empty'; Bytes = [byte[]]@()
                SHA256 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
                SHA512 = 'cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e'
            },
            @{
                Name = 'abc'; Bytes = [Text.Encoding]::ASCII.GetBytes('abc')
                SHA256 = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
                SHA512 = 'ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f'
            },
            @{
                Name = 'multiblock'; Bytes = [byte[]]([byte[]](0..255) * 2)
                SHA256 = '110009dcee21620b166f3abfecb5eff7a873be729d1c2d53822e7acc5f34eb9b'
                SHA512 = 'edb9bed721aa6a5f6fbc6619d3a3c2be3d043043f05a9aebc7b1197a2aa9c49a57d5ddd4674c1785785088d9f1ff42c797a02adc9b817a139a50970da6c99524'
            }
        )
        foreach ($vector in $vectors) {
            $path = Join-Path $root ($vector.Name + '.bin')
            [IO.File]::WriteAllBytes($path, $vector.Bytes)
            foreach ($algorithm in @('SHA256', 'sha256', 'SHA512', 'sha512')) {
                $digest = Get-EzVmFileDigest -Path $path -Algorithm $algorithm
                Assert-EzVmEqual -Actual $digest -Expected $vector[$algorithm.ToUpperInvariant()] -Message ($vector.Name + ' ' + $algorithm)
            }
        }
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Download: consecutive hashes reread changed bytes with unchanged file size and timestamp' -ScriptBlock {
    $root = New-EzVmTestDirectory -Prefix 'SHA fresh bytes'
    try {
        $path = Join-Path $root 'payload.bin'
        $original = [Text.Encoding]::ASCII.GetBytes('cached-file-A')
        $changed = [Text.Encoding]::ASCII.GetBytes('cached-file-B')
        $expectations = @(
            @{
                Algorithm = 'SHA256'
                Original = '14eafdb35f86078b13a22403a58e732c499d4969761149fcb45074c6f482c7ec'
                Changed = '5dd91c25a990838d738080f2568a8d9037cce8892e984bb509480e81b8cc10ea'
            },
            @{
                Algorithm = 'SHA512'
                Original = '4ed7c3f9d791df0fe640ee5f3f8173662bb1310b07ff2f752e76e1dac72c1c20531f75149ee586bfd3dbc2d0625237076a2bb9711edecc5a73668396e9b5f608'
                Changed = 'aadb60f09d26db6c4cb98049be02920d55d3727d4b2272be28ff24cbe473eb221a29673d24012d283a73d46be681ed23cd95e74b5a07a22d58294d5d4e26f96c'
            }
        )
        foreach ($expected in $expectations) {
            [IO.File]::WriteAllBytes($path, $original)
            $timestamp = [IO.File]::GetLastWriteTimeUtc($path)
            Assert-EzVmEqual -Actual (Get-EzVmFileDigest -Path $path -Algorithm $expected.Algorithm) -Expected $expected.Original
            [IO.File]::WriteAllBytes($path, $changed)
            [IO.File]::SetLastWriteTimeUtc($path, $timestamp)
            Assert-EzVmEqual -Actual (Get-Item -LiteralPath $path).Length -Expected $original.Length
            Assert-EzVmEqual -Actual ([IO.File]::GetLastWriteTimeUtc($path)) -Expected $timestamp
            Assert-EzVmEqual -Actual (Get-EzVmFileDigest -Path $path -Algorithm $expected.Algorithm) -Expected $expected.Changed
            [IO.File]::WriteAllBytes($path, $original)
            [IO.File]::SetLastWriteTimeUtc($path, $timestamp)
            Assert-EzVmEqual -Actual (Get-EzVmFileDigest -Path $path -Algorithm $expected.Algorithm) -Expected $expected.Original
        }
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

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
