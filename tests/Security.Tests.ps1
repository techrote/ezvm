function New-EzVmSecurityDirectoryLink {
    param([string]$Path, [string]$Target)
    $kind = if ($script:EzVmIsWindowsHost) { 'Junction' } else { 'SymbolicLink' }
    New-Item -ItemType $kind -Path $Path -Target $Target -ErrorAction Stop | Out-Null
}

Add-EzVmTest -Name 'Security: redirected download cache refuses before deletion or downloader execution' -ScriptBlock {
    $root = New-EzVmTestDirectory -Prefix 'cache redirection'
    $link = Join-Path $root 'cache'
    try {
        $outside = Join-Path $root 'outside'
        [void][IO.Directory]::CreateDirectory($outside)
        $victim = Join-Path $outside 'artifact.txt'
        [IO.File]::WriteAllText($victim, 'outside bytes must survive')
        New-EzVmSecurityDirectoryLink -Path $link -Target $outside
        $observed = [pscustomobject]@{ Calls = 0 }
        $download = { param($url, $path) $observed.Calls++; throw 'unexpected downloader' }.GetNewClosure()
        Assert-EzVmThrows -ScriptBlock {
            Get-EzVmVerifiedArtifact -Url 'https://example.invalid/artifact' -FileName 'artifact.txt' -Algorithm SHA256 -ExpectedDigest ('a' * 64) -DestinationDirectory $link -Downloader $download
        } -MessagePattern 'reparse|symlink|redirection' | Out-Null
        Assert-EzVmEqual -Actual $observed.Calls -Expected 0
        Assert-EzVmEqual -Actual ([IO.File]::ReadAllText($victim)) -Expected 'outside bytes must survive'
    }
    finally {
        if (Test-Path -LiteralPath $link) { [IO.Directory]::Delete($link) }
        Remove-EzVmTestDirectory $root
    }
}

Add-EzVmTest -Name 'Security: JSON replacement rejects redirected ancestors and preserves outside bytes' -ScriptBlock {
    $root = New-EzVmTestDirectory -Prefix 'JSON redirection'
    $link = Join-Path $root 'alias'
    try {
        $outside = Join-Path $root 'outside'
        [void][IO.Directory]::CreateDirectory($outside)
        $victim = Join-Path $outside 'state.json'
        [IO.File]::WriteAllText($victim, '{"schemaVersion":1,"value":"original"}')
        New-EzVmSecurityDirectoryLink -Path $link -Target $outside
        Assert-EzVmThrows -ScriptBlock {
            Write-EzVmJson -Path (Join-Path $link 'state.json') -Value @{ schemaVersion = 1; value = 'changed' }
        } -MessagePattern 'reparse|symlink|redirection' | Out-Null
        Assert-EzVmEqual -Actual ([IO.File]::ReadAllText($victim)) -Expected '{"schemaVersion":1,"value":"original"}'
    }
    finally {
        if (Test-Path -LiteralPath $link) { [IO.Directory]::Delete($link) }
        Remove-EzVmTestDirectory $root
    }
}

Add-EzVmTest -Name 'Security: dangling directory links and ancestors above managed roots are refused' -ScriptBlock {
    $root = New-EzVmTestDirectory -Prefix 'ancestor redirection'
    $link = Join-Path $root 'alias'
    try {
        $target = Join-Path $root 'target'
        [void][IO.Directory]::CreateDirectory($target)
        New-EzVmSecurityDirectoryLink -Path $link -Target $target
        $module = Get-Module EzVm
        Assert-EzVmThrows { & $module { param($p) Assert-EzVmSafePath -Path (Join-Path $p 'nested/new.json') } $link } -MessagePattern 'reparse' | Out-Null
        [IO.Directory]::Delete($target)
        Assert-EzVmThrows { & $module { param($p) Assert-EzVmSafePath -Path $p } $link } -MessagePattern 'reparse' | Out-Null
    }
    finally {
        try { [IO.Directory]::Delete($link) } catch { }
        Remove-EzVmTestDirectory $root
    }
}

Add-EzVmTest -Name 'Security: recursive cleanup preflights all descendants without following a junction' -ScriptBlock {
    $root = New-EzVmTestDirectory -Prefix 'safe cleanup'
    $link = Join-Path $root 'stage/redirect'
    try {
        $stage = Join-Path $root 'stage'; $outside = Join-Path $root 'outside'
        [void][IO.Directory]::CreateDirectory($stage); [void][IO.Directory]::CreateDirectory($outside)
        [IO.File]::WriteAllText((Join-Path $stage 'keep.txt'), 'stage evidence')
        [IO.File]::WriteAllText((Join-Path $outside 'keep.txt'), 'outside evidence')
        New-EzVmSecurityDirectoryLink -Path $link -Target $outside
        Assert-EzVmThrows { & (Get-Module EzVm) { param($p) Remove-EzVmSafeTree -Path $p } $stage } -MessagePattern 'reparse' | Out-Null
        Assert-EzVmEqual ([IO.File]::ReadAllText((Join-Path $stage 'keep.txt'))) 'stage evidence'
        Assert-EzVmEqual ([IO.File]::ReadAllText((Join-Path $outside 'keep.txt'))) 'outside evidence'
    }
    finally { if (Test-Path -LiteralPath $link) { [IO.Directory]::Delete($link) }; Remove-EzVmTestDirectory $root }
}

Add-EzVmTest -Name 'Security: invalid acquisition URL cannot delete an existing cache entry' -ScriptBlock {
    $root = New-EzVmTestDirectory -Prefix 'invalid url'
    try {
        $file = Join-Path $root 'artifact.bin'; [IO.File]::WriteAllText($file, 'preserve before validation')
        foreach ($url in @('http://example.invalid/a', 'https://user:password@example.invalid/a')) {
            Assert-EzVmThrows { Get-EzVmVerifiedArtifact -Url $url -FileName 'artifact.bin' -Algorithm SHA256 -ExpectedDigest ('a' * 64) -DestinationDirectory $root -Downloader { throw 'not reached' } } -MessagePattern 'HTTPS' | Out-Null
            Assert-EzVmEqual ([IO.File]::ReadAllText($file)) 'preserve before validation'
        }
        foreach ($name in @('..', '.', 'a:b', 'a\b', 'a/b')) {
            Assert-EzVmThrows { Get-EzVmVerifiedArtifact -Url 'https://example.invalid/a' -FileName $name -Algorithm SHA256 -ExpectedDigest ('a' * 64) -DestinationDirectory $root -Downloader { throw 'not reached' } } -MessagePattern 'plain filename' | Out-Null
        }
    }
    finally { Remove-EzVmTestDirectory $root }
}

Add-EzVmTest -Name 'Security: failed acquisition preserves a competing destination and removes only its temporary file' -ScriptBlock {
    $root = New-EzVmTestDirectory -Prefix 'competing cache'
    try {
        $destination = Join-Path $root 'artifact.bin'
        $downloader = { param($u, $p) [IO.File]::WriteAllText($destination, 'competing publisher evidence'); [IO.File]::WriteAllText($p, 'partial'); throw 'interrupted' }.GetNewClosure()
        Assert-EzVmThrows { Get-EzVmVerifiedArtifact -Url 'https://example.invalid/a' -FileName 'artifact.bin' -Algorithm SHA256 -ExpectedDigest ('a' * 64) -DestinationDirectory $root -Downloader $downloader } -MessagePattern 'interrupted' | Out-Null
        Assert-EzVmEqual ([IO.File]::ReadAllText($destination)) 'competing publisher evidence'
        Assert-EzVmEqual @(Get-ChildItem -LiteralPath $root -Filter '*.tmp' -Force).Count 0
    }
    finally { Remove-EzVmTestDirectory $root }
}

Add-EzVmTest -Name 'Security: redirect resolution forbids downgrade and userinfo while accepting relative HTTPS locations' -ScriptBlock {
    & (Get-Module EzVm) {
        $base = [Uri]'https://example.invalid/path/file'
        if ((Resolve-EzVmDownloadUrl -Url '../other' -Base $base).AbsoluteUri -cne 'https://example.invalid/other') { throw 'Relative redirect was not resolved.' }
        foreach ($url in @('http://example.invalid/a', 'file:///tmp/a', 'https://user:secret@example.invalid/a')) {
            $rejected = $false; try { $null = Resolve-EzVmDownloadUrl -Url $url -Base $base } catch { $rejected = $true }
            if (-not $rejected) { throw 'Unsafe redirect was accepted.' }
        }
    }
}

Add-EzVmTest -Name 'Security: state text is bounded and refuses reparse reads' -ScriptBlock {
    $root = New-EzVmTestDirectory -Prefix 'bounded state'
    try {
        $path = Join-Path $root 'large.json'
        [IO.File]::WriteAllText($path, ('x' * 2097153))
        Assert-EzVmThrows { Read-EzVmJson -Path $path } -MessagePattern 'bounded read limit' | Out-Null
        $module = Get-Module EzVm
        $small = Join-Path $root 'small.txt'; [IO.File]::WriteAllText($small, '12345')
        Assert-EzVmEqual (& $module { param($p) Read-EzVmBoundedText -Path $p -MaximumBytes 5 } $small) '12345'
        Assert-EzVmThrows { & $module { param($p) Read-EzVmBoundedText -Path $p -MaximumBytes 4 } $small } -MessagePattern 'bounded' | Out-Null
    }
    finally { Remove-EzVmTestDirectory $root }
}

function New-EzVmSecurityQemuRuntime {
    param([string]$Root)
    $paths = Get-EzVmPaths -Root $Root
    [void][IO.Directory]::CreateDirectory($paths.Qemu)
    foreach ($file in @('qemu-img.exe', 'qemu-system-x86_64.exe', 'dependency.dll', 'firmware.fd')) { [IO.File]::WriteAllText((Join-Path $paths.Qemu $file), ('fixture ' + $file)) }
    $manifestDigest = Get-EzVmFileDigest -Path $paths.QemuManifest -Algorithm SHA256
    $digest = & (Get-Module EzVm) { param($p, $d) Write-EzVmQemuPayloadInventory -RuntimeDirectory $p -ManifestDigest $d } $paths.Qemu $manifestDigest
    Write-EzVmJson -Path (Join-Path $paths.Qemu 'ezvm-provenance.json') -Value @{ schemaVersion = 1; manifestSha256 = $manifestDigest; payloadManifestSha256 = $digest }
    return $paths
}

Add-EzVmTest -Name 'Security: installed executable DLL firmware and inventory tampering refuse before any version probe' -ScriptBlock {
    foreach ($mode in @('qemu-img.exe', 'dependency.dll', 'firmware.fd', 'extra.dll', 'missing', 'receipt')) {
        $root = New-EzVmCheckoutFixture -Prefix ('QEMU tamper ' + $mode)
        try {
            $paths = New-EzVmSecurityQemuRuntime $root
            $calls = [pscustomobject]@{ Count = 0 }
            $probe = { param($r, $v) $calls.Count++; [pscustomobject]@{ QemuSystemVersion = "QEMU emulator version $v"; QemuImgVersion = "qemu-img version $v" } }.GetNewClosure()
            Assert-EzVmTrue (Get-EzVmManagedQemuStatus -Root $root -PayloadProbe $probe).Valid
            Assert-EzVmEqual $calls.Count 1
            if ($mode -ceq 'missing') { [IO.File]::Delete((Join-Path $paths.Qemu 'dependency.dll')) }
            elseif ($mode -ceq 'receipt') { [IO.File]::AppendAllText((Join-Path $paths.Qemu 'ezvm-payload.json'), ' ') }
            else { [IO.File]::WriteAllText((Join-Path $paths.Qemu $mode), 'tampered bytes') }
            $status = Get-EzVmManagedQemuStatus -Root $root -PayloadProbe $probe
            Assert-EzVmEqual $status.Valid $false
            Assert-EzVmEqual $calls.Count 1 -Message 'Tampered installed content must not execute even a version probe.'
            Assert-EzVmThrows { Get-EzVmQemuToolPath -Root $root -Name 'qemu-img.exe' } -MessagePattern 'payload|inventory' | Out-Null
        }
        finally { Remove-EzVmTestDirectory $root }
    }
}

Add-EzVmTest -Name 'Security: repeated public QEMU checks reject same-size same-time payload mutation after prior success' -ScriptBlock {
    foreach ($target in @('qemu-img.exe', 'dependency.dll', 'firmware.fd')) {
        $root = New-EzVmCheckoutFixture -Prefix ('QEMU fresh bytes ' + $target)
        try {
            $paths = New-EzVmSecurityQemuRuntime $root
            $calls = [pscustomobject]@{ Count = 0 }
            $probe = { param($r, $v) $calls.Count++; [pscustomobject]@{ QemuSystemVersion = "QEMU emulator version $v"; QemuImgVersion = "qemu-img version $v" } }.GetNewClosure()
            $receiptPath = Join-Path $paths.Qemu 'ezvm-provenance.json'
            $inventoryPath = Join-Path $paths.Qemu 'ezvm-payload.json'
            $receiptBefore = [IO.File]::ReadAllText($receiptPath)
            $inventoryBefore = [IO.File]::ReadAllText($inventoryPath)
            Assert-EzVmTrue (Get-EzVmManagedQemuStatus -Root $root -PayloadProbe $probe).Valid
            foreach ($tool in @('qemu-img.exe', 'qemu-system-x86_64.exe')) {
                Assert-EzVmEqual -Actual (Get-EzVmQemuToolPath -Root $root -Name $tool) -Expected (Join-Path $paths.Qemu $tool)
            }
            Assert-EzVmEqual -Actual $calls.Count -Expected 1
            $path = Join-Path $paths.Qemu $target
            $original = [IO.File]::ReadAllBytes($path)
            $timestamp = [IO.File]::GetLastWriteTimeUtc($path)
            $changed = [byte[]]$original.Clone()
            $changed[$changed.Length - 1] = $changed[$changed.Length - 1] -bxor 90
            [IO.File]::WriteAllBytes($path, $changed)
            [IO.File]::SetLastWriteTimeUtc($path, $timestamp)
            Assert-EzVmEqual -Actual (Get-Item -LiteralPath $path).Length -Expected $original.Length
            Assert-EzVmEqual -Actual ([IO.File]::GetLastWriteTimeUtc($path)) -Expected $timestamp
            $status = Get-EzVmManagedQemuStatus -Root $root -PayloadProbe $probe
            Assert-EzVmEqual -Actual $status.Valid -Expected $false
            Assert-EzVmTrue -Condition ($status.Reason -match 'payload digest or size mismatch')
            Assert-EzVmEqual -Actual $calls.Count -Expected 1 -Message 'Changed bytes must be refused before executing a version probe.'
            foreach ($tool in @('qemu-img.exe', 'qemu-system-x86_64.exe')) {
                Assert-EzVmThrows { Get-EzVmQemuToolPath -Root $root -Name $tool } -MessagePattern 'payload digest or size mismatch' | Out-Null
            }
            Assert-EzVmEqual -Actual ([IO.File]::ReadAllText($receiptPath)) -Expected $receiptBefore
            Assert-EzVmEqual -Actual ([IO.File]::ReadAllText($inventoryPath)) -Expected $inventoryBefore
            [IO.File]::WriteAllBytes($path, $original)
            [IO.File]::SetLastWriteTimeUtc($path, $timestamp)
            Assert-EzVmTrue (Get-EzVmManagedQemuStatus -Root $root -PayloadProbe $probe).Valid
            Assert-EzVmEqual -Actual $calls.Count -Expected 2
        }
        finally { Remove-EzVmTestDirectory $root }
    }
}

Add-EzVmTest -Name 'Security: legacy QEMU receipts are not upgraded from unverified installed bytes' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'legacy QEMU receipt'
    try {
        $paths = New-EzVmSecurityQemuRuntime $root
        $receiptPath = Join-Path $paths.Qemu 'ezvm-provenance.json'
        $receipt = Read-EzVmJson $receiptPath; $receipt.PSObject.Properties.Remove('payloadManifestSha256')
        Write-EzVmJson $receiptPath $receipt
        $before = [IO.File]::ReadAllText($receiptPath)
        $status = Get-EzVmManagedQemuStatus -Root $root -PayloadProbe { throw 'must not execute installed bytes' }
        Assert-EzVmEqual $status.Valid $false
        Assert-EzVmTrue ($status.Reason -match 'lacks a verified payload inventory')
        Assert-EzVmEqual ([IO.File]::ReadAllText($receiptPath)) $before
    }
    finally { Remove-EzVmTestDirectory $root }
}

Add-EzVmTest -Name 'Security: seed shutdown expires transport and releases payloads without retaining rejected request targets' -ScriptBlock {
    $server = Start-EzVmSeedServer -UserData 'private seed fixture' -MetaData 'meta fixture' -TimeoutSeconds 30
    try {
        $null = Invoke-EzVmSeedHttpFixture -Server $server -RequestLine 'GET /bad?token=synthetic-sensitive-query HTTP/1.1'
        Assert-EzVmEqual @($server.RequestPaths.ToArray()) @('<rejected>')
        $server.DeadlineUtc = [DateTime]::UtcNow.AddSeconds(-1)
        Assert-EzVmThrows { Invoke-EzVmSeedServerPending $server } -MessagePattern 'bounded lifetime' | Out-Null
        Assert-EzVmEqual $server.Closed $true
        Assert-EzVmEqual $server.UserData ''
        Assert-EzVmEqual $server.MetaData ''
        Assert-EzVmEqual $server.Clients.Count 0
    }
    finally { Stop-EzVmSeedServer $server }
    Assert-EzVmThrows { Start-EzVmSeedServer -UserData ('u' * 1048577) -MetaData 'm' } -MessagePattern 'bounded' | Out-Null
}

Add-EzVmTest -Name 'Security: seed client count and request history remain bounded' -ScriptBlock {
    $server = Start-EzVmSeedServer -UserData 'u' -MetaData 'm' -TimeoutSeconds 30
    $clients = New-Object 'System.Collections.Generic.List[object]'
    try {
        for ($i = 0; $i -lt 24; $i++) {
            $c = New-Object Net.Sockets.TcpClient; $c.Connect('127.0.0.1', $server.Port); $clients.Add($c)
        }
        $null = Invoke-EzVmSeedServerPending -Server $server -MaxRequests 64
        Assert-EzVmTrue ($server.Clients.Count -le 16)
        foreach ($c in $clients) { $c.Dispose() }
        $null = Invoke-EzVmSeedServerPending -Server $server -MaxRequests 64
        for ($i = 0; $i -lt 70; $i++) { $null = Invoke-EzVmSeedHttpFixture -Server $server -RequestLine 'GET /meta-data HTTP/1.1' }
        Assert-EzVmEqual $server.RequestPaths.Count 64
    }
    finally { foreach ($c in $clients) { $c.Dispose() }; Stop-EzVmSeedServer $server }
}

Add-EzVmTest -Name 'Security: controller identity mismatch preserves both pre-existing key files' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'controller mismatch'
    try {
        $paths = Get-EzVmSshPaths -Root $root
        [void][IO.Directory]::CreateDirectory($paths.KeysDirectory)
        [IO.File]::WriteAllText($paths.ControllerPrivateKey, 'synthetic private bytes')
        [IO.File]::WriteAllText($paths.ControllerPublicKey, 'ssh-ed25519 AAAA fixture')
        $tools = [pscustomobject]@{ Valid = $true; Ssh = 'fixture'; Scp = 'fixture'; Keygen = 'fixture-keygen'; Missing = @(); Reason = 'fixture' }
        $runner = { param($exe, $arguments, $seconds) [pscustomobject]@{ ExitCode = 0; StdOut = $(if ($exe -ceq 'fixture-keygen') { 'ssh-ed25519 BBBB' } else { '' }); StdErr = '' } }
        Assert-EzVmThrows { Get-EzVmControllerSshIdentity -Root $root -Tooling $tools -ProcessRunner $runner } -MessagePattern 'public/private key mismatch' | Out-Null
        Assert-EzVmEqual ([IO.File]::ReadAllText($paths.ControllerPrivateKey)) 'synthetic private bytes'
        Assert-EzVmEqual ([IO.File]::ReadAllText($paths.ControllerPublicKey)) 'ssh-ed25519 AAAA fixture'
    }
    finally { Remove-EzVmTestDirectory $root }
}

Add-EzVmTest -Name 'Security: token guards and bounded diagnostics redact before truncating' -ScriptBlock {
    $tokens = @('ghp_' + ('A' * 36), 'github_pat_' + ('B' * 70), 'sk-proj-' + ('C' * 60), 'AKIA' + ('D' * 16))
    foreach ($token in $tokens) {
        Assert-EzVmThrows { & (Get-Module EzVm) { param($t) Assert-EzVmCredentialFreeText -Text $t } $token } -MessagePattern 'credential-like' | Out-Null
        $safe = & (Get-Module EzVm) { param($t) Protect-EzVmDiagnosticText -Text ('prefix ' + $t + ' suffix') -MaximumCharacters 64 } $token
        Assert-EzVmTrue ($safe.Contains('[REDACTED]') -and -not $safe.Contains($token.Substring(0, 10)))
    }
    $safe = & (Get-Module EzVm) { Protect-EzVmDiagnosticText -Text 'Authorization: Bearer synthetic-value' }
    Assert-EzVmEqual $safe 'Authorization: Bearer [REDACTED]'
}

Add-EzVmTest -Name 'Security: unsafe transfer destinations and controller-key sources refuse before guest access' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'copy boundaries'
    $link = Join-Path $root 'redirect'
    try {
        $paths = Get-EzVmPaths -Root $root
        [void][IO.Directory]::CreateDirectory($paths.Keys)
        [IO.File]::WriteAllText((Join-Path $paths.Keys 'controller_ed25519'), 'fixture')
        Assert-EzVmThrows { Invoke-EzVmCopyToGuest -Root $root -InstanceName absent -HostPath (Join-Path $paths.Keys 'controller_ed25519') -GuestPath '/tmp/key' } -MessagePattern 'must not be transferred' | Out-Null
        Assert-EzVmThrows { Invoke-EzVmCopyFromGuest -Root $root -InstanceName absent -GuestPath '/tmp/file' -HostPath (Join-Path $paths.Keys 'controller_ed25519') } -MessagePattern 'cannot replace managed runtime' | Out-Null
        New-EzVmSecurityDirectoryLink -Path $link -Target $root
        Assert-EzVmThrows { Invoke-EzVmCopyFromGuest -Root $root -InstanceName absent -GuestPath '/tmp/file' -HostPath (Join-Path $link 'target') } -MessagePattern 'reparse' | Out-Null
    }
    finally { if (Test-Path -LiteralPath $link) { [IO.Directory]::Delete($link) }; Remove-EzVmTestDirectory $root }
}

$securityWindowsSkip = if ($script:EzVmIsWindowsHost) { '' } else { 'Windows-specific ACL, hard-link and device-path checks execute in both required Windows lanes.' }
Add-EzVmTest -Name 'Security: Windows path validation reaches the drive root under both PowerShell runtimes' -SkipReason $securityWindowsSkip -ScriptBlock {
    $root = New-EzVmTestDirectory -Prefix 'drive root ancestor'
    try {
        $candidate = Join-Path $root 'nested/path.txt'
        $validated = & (Get-Module EzVm) { param($p) Assert-EzVmSafePath -Path $p } $candidate
        Assert-EzVmEqual $validated ([IO.Path]::GetFullPath($candidate))
    }
    finally { Remove-EzVmTestDirectory $root }
}

Add-EzVmTest -Name 'Security: Windows private ACL removes pre-existing broad explicit ACEs' -SkipReason $securityWindowsSkip -ScriptBlock {
    $root = New-EzVmTestDirectory -Prefix 'explicit ACL'
    try {
        $file = Join-Path $root 'private.txt'; [IO.File]::WriteAllText($file, 'fixture')
        $acl = Get-Acl -LiteralPath $file
        $everyone = [Security.Principal.SecurityIdentifier]::new('S-1-1-0')
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($everyone, 'FullControl', 'Allow'))
        Set-Acl -LiteralPath $file -AclObject $acl
        & (Get-Module EzVm) { param($p) Protect-EzVmControllerPrivateKey -Path $p } $file
        $after = Get-Acl -LiteralPath $file
        $rules = @($after.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        Assert-EzVmEqual $rules.Count 1
        Assert-EzVmEqual $rules[0].IdentityReference.Value ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    }
    finally { Remove-EzVmTestDirectory $root }
}

Add-EzVmTest -Name 'Security: Windows hard-linked keys refuse permission mutation of another file' -SkipReason $securityWindowsSkip -ScriptBlock {
    $root = New-EzVmTestDirectory -Prefix 'hardlink ACL'
    try {
        $file = Join-Path $root 'outside.txt'; $link = Join-Path $root 'private.txt'
        [IO.File]::WriteAllText($file, 'outside')
        New-Item -ItemType HardLink -Path $link -Target $file | Out-Null
        $before = (Get-Acl -LiteralPath $file).Sddl
        Assert-EzVmThrows { & (Get-Module EzVm) { param($p) Protect-EzVmControllerPrivateKey -Path $p } $link } -MessagePattern 'hard-linked' | Out-Null
        Assert-EzVmEqual (Get-Acl -LiteralPath $file).Sddl $before
    }
    finally { Remove-EzVmTestDirectory $root }
}

Add-EzVmTest -Name 'Security: Windows ADS device and ambiguous trailing-component paths refuse' -SkipReason $securityWindowsSkip -ScriptBlock {
    $root = New-EzVmTestDirectory -Prefix 'Windows path syntax'
    try {
        foreach ($tail in @('state.json:stream', 'NUL', 'CON.txt', 'COM1', 'bad.', 'bad ')) {
            Assert-EzVmThrows { & (Get-Module EzVm) { param($p) Assert-EzVmSafePath -Path $p } (Join-Path $root $tail) } -MessagePattern 'unsafe|alternate|local drive' | Out-Null
        }
        Assert-EzVmThrows { & (Get-Module EzVm) { Assert-EzVmSafePath -Path '\\?\C:\Windows' } } -MessagePattern 'local drive|namespace' | Out-Null
    }
    finally { Remove-EzVmTestDirectory $root }
}

Add-EzVmTest -Name 'Security: base seed rejects token-shaped content in either template before guest execution' -ScriptBlock {
    foreach ($template in @('user-data.yaml', 'meta-data.yaml')) {
        $root = New-EzVmCheckoutFixture -Prefix 'base input tokens'
        try {
            $path = Join-Path (Get-EzVmPaths $root).BaseCloudInit $template
            [IO.File]::AppendAllText($path, ("`n# synthetic " + 'ghp_' + ('Z' * 36) + "`n"))
            Assert-EzVmThrows { New-EzVmBaseSeedData -Root $root -BuildId ('a' * 32) } -MessagePattern 'credential-like' | Out-Null
            Assert-EzVmTrue (-not (Test-Path -LiteralPath (Get-EzVmPaths $root).Instances))
        }
        finally { Remove-EzVmTestDirectory $root }
    }
}

Add-EzVmTest -Name 'Security: production overlay validation rejects external dependencies before resolving a QEMU executable' -ScriptBlock {
    $fixture = New-EzVmSnapshotFixture
    try {
        Write-EzVmSnapshotFixtureImage -Path $fixture.Disk -Backing '../../../outside.qcow2'
        # No metadata runner and no QEMU installation: a dependency error must
        # precede tool resolution, so this tests the real production preflight.
        Assert-EzVmThrows { Test-EzVmInstanceOverlay -Root $fixture.Root -OverlayPath $fixture.Disk -BaseId $fixture.Intent.baseId } -MessagePattern 'backing' | Out-Null
    }
    finally { Remove-EzVmSnapshotFixture $fixture }
}

Add-EzVmTest -Name 'Security: tracked token formats are rejected without displaying their bytes' -ScriptBlock {
    $root = New-EzVmRepositoryFixture
    try {
        $credential = 'github_pat_' + ('Z' * 70)
        $null = Add-EzVmTrackedFixtureFile -Root $root -RelativePath 'notes/token.txt' -Content $credential
        $errorText = ''
        try { $null = Test-EzVmRepositoryContract -Root $root } catch { $errorText = $_.Exception.Message }
        Assert-EzVmTrue ($errorText.Contains('credential-like'))
        Assert-EzVmTrue (-not $errorText.Contains($credential))
    }
    finally { Remove-EzVmTestDirectory $root }
}

Add-EzVmTest -Name 'Security: bootstrap revalidates all acquired inputs before executing the extractor' -SkipReason $qemuWindowsSkip -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'late acquisition mutation'
    try {
        $fixture = New-EzVmQemuFixture -Root $root
        $hooks = New-EzVmQemuFixtureHooks -Fixture $fixture
        $cache = (Get-EzVmPaths $root).Downloads
        $download = $hooks.Downloader
        $changedDownload = {
            param($url, $destination)
            & $download $url $destination
            if ($url -match '7zip-package-fixture') {
                [IO.File]::WriteAllText((Join-Path $cache 'qemu-fixture.exe'), 'changed after earlier successful verification')
            }
        }.GetNewClosure()
        $calls = [pscustomobject]@{ Count = 0 }
        $extractor = { param($b, $p, $d, $v) $calls.Count++; throw 'unverified input reached execution' }.GetNewClosure()
        Assert-EzVmThrows { Install-EzVmQemuRuntime -Root $root -ManifestPath $fixture.ManifestPath -Downloader $changedDownload -ExtractorBootstrapper $extractor } -MessagePattern 'changed before extraction' | Out-Null
        Assert-EzVmEqual $calls.Count 0
        Assert-EzVmTrue (-not (Test-Path -LiteralPath (Get-EzVmPaths $root).Qemu))
    }
    finally { Remove-EzVmTestDirectory $root }
}

Add-EzVmTest -Name 'Security: invalid installed runtime is preserved instead of replaced during bootstrap' -SkipReason $qemuWindowsSkip -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'preserve invalid runtime'
    try {
        $paths = Get-EzVmPaths $root
        [void][IO.Directory]::CreateDirectory($paths.Qemu)
        $evidence = Join-Path $paths.Qemu 'evidence.txt'
        [IO.File]::WriteAllText($evidence, 'preserve exactly')
        Assert-EzVmThrows { Install-EzVmQemuRuntime -Root $root -Downloader { throw 'must not download' } } -MessagePattern 'will not be replaced automatically' | Out-Null
        Assert-EzVmEqual ([IO.File]::ReadAllText($evidence)) 'preserve exactly'
    }
    finally { Remove-EzVmTestDirectory $root }
}

Add-EzVmTest -Name 'Security: actual Windows key generation and staged copy-from preserve destination on failure' -SkipReason $qemuWindowsSkip -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'native key and atomic transfer'
    try {
        $intent = New-EzVmPortabilityIdentityTestIntent
        $access = New-EzVmSshTestAccess -Root $root -Intent $intent
        $launch = New-EzVmSshTestLaunch -Root $root -Intent $intent -Access $access
        $access.state = 'READY'; $access.readyAt = [DateTime]::UtcNow.ToString('o')
        Write-EzVmJson -Path (Get-EzVmSshPaths -Root $root -InstanceName $intent.name).AccessState -Value $access -SchemaVersion 2
        $identity = Get-EzVmControllerSshIdentity -Root $root
        $originalKey = Get-EzVmFileDigest -Path $identity.PrivateKey -Algorithm SHA256
        $again = Get-EzVmControllerSshIdentity -Root $root
        Assert-EzVmEqual $again.PublicKeyText $identity.PublicKeyText
        Assert-EzVmEqual (Get-EzVmFileDigest -Path $identity.PrivateKey -Algorithm SHA256) $originalKey
        $output = Join-Path $root 'result with spaces.txt'
        [IO.File]::WriteAllText($output, 'old result')
        $partial = {
            param($exe, $arguments, $timeout)
            [IO.File]::WriteAllText($arguments[-1], 'partial bytes')
            [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'synthetic transfer failure' }
        }
        Assert-EzVmThrows { Invoke-EzVmCopyFromGuest -Root $root -InstanceName $intent.name -GuestPath '/tmp/result' -HostPath $output -ProcessProvider $launch.ProcessProvider -ScpRunner $partial } -MessagePattern 'copy-from failed' | Out-Null
        Assert-EzVmEqual ([IO.File]::ReadAllText($output)) 'old result'
        Assert-EzVmEqual @(Get-ChildItem -LiteralPath $root -Force -Filter '.ezvm-copy-*').Count 0
        $complete = {
            param($exe, $arguments, $timeout)
            if ($arguments -cnotcontains 'BatchMode=yes') { throw 'transfer must be noninteractive' }
            [IO.File]::WriteAllText($arguments[-1], 'complete new bytes')
            [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' }
        }
        $null = Invoke-EzVmCopyFromGuest -Root $root -InstanceName $intent.name -GuestPath '/tmp/result' -HostPath $output -ProcessProvider $launch.ProcessProvider -ScpRunner $complete
        Assert-EzVmEqual ([IO.File]::ReadAllText($output)) 'complete new bytes'
        Assert-EzVmEqual @(Get-ChildItem -LiteralPath $root -Force -Filter '.ezvm-copy-*').Count 0
        Assert-EzVmEqual (Get-EzVmFileDigest -Path $identity.PrivateKey -Algorithm SHA256) $originalKey
    }
    finally { Remove-EzVmTestDirectory $root }
}
