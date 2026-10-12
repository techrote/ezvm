function ConvertFrom-EzVmCodingTestProbe {
    param([string]$StdOut, [object]$Intent = (New-EzVmSshTestIntent))
    $profile = Get-EzVmCodingProfile -Root $script:EzVmRepositoryRoot
    return ConvertFrom-EzVmReadinessProbe -StdOut $StdOut -ExpectedInstanceName $Intent.name -ExpectedBaseId $Intent.baseId -ExpectedProfile $Intent.profile -ExpectedCloudInstanceId (Get-EzVmSshTestCloudId -Intent $Intent) -ExpectedProvisioningProfile $profile.Name -ExpectedProvisioningVersion $profile.Version -ExpectedProvisioningDigest $profile.Digest
}

function Set-EzVmCodingTestProbeField {
    param([string]$Probe, [string]$Field, [AllowEmptyString()][string]$Value)
    $lines = @($Probe -split '\r?\n' | ForEach-Object {
        if ($_.StartsWith(($Field + '='), [StringComparison]::Ordinal)) { $Field + '=' + $Value }
        else { $_ }
    })
    return [string]::Join([Environment]::NewLine, $lines)
}

Add-EzVmTest -Name 'Coding readiness: seed separates resource and coding identities and configures locked coder workspace policy' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'coding seed [spaces]'
    try {
        $intent = New-EzVmSshTestIntent -Cpus 2 -MemoryMiB 4096
        $seed = New-EzVmInstanceSeedData -Root $root -Intent $intent -InstanceName $intent.name -ControllerPublicKey 'ssh-ed25519 AAAA do-not-copy-this-comment'
        Assert-EzVmEqual -Actual $seed.Identity.schemaVersion -Expected 2
        Assert-EzVmEqual -Actual $seed.Identity.profile -Expected 'light'
        Assert-EzVmEqual -Actual $seed.Identity.provisioningProfile -Expected 'coding-default'
        Assert-EzVmEqual -Actual $seed.Identity.provisioningVersion -Expected 1
        Assert-EzVmEqual -Actual $seed.Identity.provisioningDigest -Expected (Get-EzVmCodingProfile -Root $root).Digest
        foreach ($content in @('homedir: /home/coder', 'lock_passwd: true', 'ssh_pwauth: false', 'disable_root: true', 'ALL=(ALL:ALL) NOPASSWD:ALL', 'PasswordAuthentication no', 'KbdInteractiveAuthentication no', 'PermitRootLogin no')) {
            Assert-EzVmTrue -Condition ($seed.UserData.Contains($content)) -Message "Missing coder policy: $content"
        }
        Assert-EzVmTrue -Condition ($seed.UserData.Contains('/etc/ezvm/profile.json') -and $seed.UserData.Contains('/usr/local/sbin/ezvm-coding-profile'))
        Assert-EzVmTrue -Condition ($seed.UserData.Contains('systemctl reload ssh')) -Message 'Effective SSH policy must be activated before completion.'
        Assert-EzVmTrue -Condition ($seed.UserData.Contains('systemd-run, --no-block')) -Message 'Finalization must not deadlock cloud-init completion.'
        Assert-EzVmTrue -Condition (-not $seed.UserData.Contains('do-not-copy-this-comment')) -Message 'Public-key comments must not enter guest seed.'
        Assert-EzVmTrue -Condition (-not $seed.UserData.Contains([string][char]13)) -Message 'Guest seed must use Unix newlines on Windows too.'
        Assert-EzVmTrue -Condition ($seed.UserData -notmatch '(?im)^packages:|^package_upgrade:|curl.+\|\s*(sh|bash)') -Message 'Instance startup must validate the baseline without unreviewed package installation.'
        Assert-EzVmThrows -ScriptBlock {
            New-EzVmInstanceSeedData -Root $root -Intent $intent -InstanceName $intent.name -ControllerPublicKey 'ssh-ed25519 AAAA' -Profile heavy
        } -MessagePattern 'resource profile.*does not match durable intent' | Out-Null
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Coding readiness: legacy intent remains readable but start refuses before key generation or guest mutation' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'legacy coding refusal'
    try {
        $intent = New-EzVmSshTestIntent
        $intent.provisioningProfile = 'ezvm-core'
        $paths = Get-EzVmInstanceRuntimePaths -Root $root -InstanceName $intent.name
        [void][IO.Directory]::CreateDirectory($paths.Directory)
        Write-EzVmJson -Path $paths.Intent -Value $intent
        $before = [IO.File]::ReadAllText($paths.Intent)
        Assert-EzVmEqual -Actual (Get-EzVmInstanceIntent -Root $root -InstanceName $intent.name).provisioningProfile -Expected 'ezvm-core'
        Assert-EzVmThrows -ScriptBlock {
            Start-EzVmReadyInstance -Root $root -InstanceName $intent.name
        } -MessagePattern 'unsupported.*new named instance.*not silently upgraded' | Out-Null
        Assert-EzVmEqual -Actual ([IO.File]::ReadAllText($paths.Intent)) -Expected $before
        Assert-EzVmTrue -Condition (-not (Test-Path -LiteralPath $paths.Runtime)) -Message 'Unsupported profile cannot launch a guest.'
        Assert-EzVmTrue -Condition (-not (Test-Path -LiteralPath (Get-EzVmSshPaths -Root $root).ControllerPrivateKey)) -Message 'Unsupported profile must be refused before controller-key creation.'
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Coding readiness: complete versioned identity plus live proof grants READY' -ScriptBlock {
    $intent = New-EzVmSshTestIntent
    $identity = New-EzVmSshTestIdentityJson -Intent $intent
    $probe = New-EzVmSshTestProbe -IdentityBase64 (ConvertTo-EzVmSshTestBase64 $identity)
    $result = ConvertFrom-EzVmCodingTestProbe -StdOut $probe -Intent $intent
    Assert-EzVmEqual -Actual $result.Ready -Expected $true
    Assert-EzVmEqual -Actual $result.ReadyMarker.provisioningState -Expected 'complete'
    Assert-EzVmEqual -Actual $result.ProfileReady -Expected $true
    Assert-EzVmEqual -Actual $result.Identity.provisioningVersion -Expected 1
}

Add-EzVmTest -Name 'Coding readiness: each identity field in either identity or completion marker is compared with host intent' -ScriptBlock {
    $intent = New-EzVmSshTestIntent
    $identity = New-EzVmSshTestIdentityJson -Intent $intent
    $probe = New-EzVmSshTestProbe -IdentityBase64 (ConvertTo-EzVmSshTestBase64 $identity)
    $changes = @(
        @('instanceName', 'different-agent'), @('baseId', ('base-' + ('b' * 64))),
        @('profile', 'heavy'), @('cloudInstanceId', 'ezvm-other-123456789abc'),
        @('provisioningProfile', 'ezvm-core'), @('provisioningVersion', 2),
        @('provisioningDigest', ('0' * 64))
    )
    foreach ($field in @('EZVM_IDENTITY_B64', 'EZVM_READY_B64')) {
        foreach ($change in $changes) {
            $document = $identity | ConvertFrom-Json
            if ($field -ceq 'EZVM_READY_B64') { $document | Add-Member -NotePropertyName provisioningState -NotePropertyValue 'complete' }
            $document.($change[0]) = $change[1]
            $changed = Set-EzVmCodingTestProbeField -Probe $probe -Field $field -Value (ConvertTo-EzVmSshTestBase64 ($document | ConvertTo-Json -Compress))
            Assert-EzVmThrows -ScriptBlock {
                ConvertFrom-EzVmCodingTestProbe -StdOut $changed -Intent $intent
            } -MessagePattern 'identity mismatch' | Out-Null
        }
    }
}

Add-EzVmTest -Name 'Coding readiness: malformed schemas, coerced versions and extra identity fields cannot pass' -ScriptBlock {
    $intent = New-EzVmSshTestIntent
    $identity = New-EzVmSshTestIdentityJson -Intent $intent
    $probe = New-EzVmSshTestProbe -IdentityBase64 (ConvertTo-EzVmSshTestBase64 $identity)
    foreach ($field in @('EZVM_IDENTITY_B64', 'EZVM_READY_B64')) {
        foreach ($change in @(@('schemaVersion', 1), @('schemaVersion', '2'), @('schemaVersion', $true), @('provisioningVersion', '1'), @('provisioningVersion', $true), @('provisioningVersion', 1.5), @('provisioningVersion', $null))) {
            $document = $identity | ConvertFrom-Json
            if ($field -ceq 'EZVM_READY_B64') { $document | Add-Member -NotePropertyName provisioningState -NotePropertyValue 'complete' }
            $document.($change[0]) = $change[1]
            $changed = Set-EzVmCodingTestProbeField -Probe $probe -Field $field -Value (ConvertTo-EzVmSshTestBase64 ($document | ConvertTo-Json -Compress))
            Assert-EzVmThrows -ScriptBlock { ConvertFrom-EzVmCodingTestProbe -StdOut $changed } -MessagePattern 'schemaVersion|integer' | Out-Null
        }
        foreach ($kind in @('missing', 'extra')) {
            $document = $identity | ConvertFrom-Json
            if ($field -ceq 'EZVM_READY_B64') { $document | Add-Member -NotePropertyName provisioningState -NotePropertyValue 'complete' }
            if ($kind -ceq 'missing') { $document.PSObject.Properties.Remove('provisioningDigest') }
            else { $document | Add-Member -NotePropertyName unexpected -NotePropertyValue 'ignored fields are not allowed' }
            $changed = Set-EzVmCodingTestProbeField -Probe $probe -Field $field -Value (ConvertTo-EzVmSshTestBase64 ($document | ConvertTo-Json -Compress))
            Assert-EzVmThrows -ScriptBlock { ConvertFrom-EzVmCodingTestProbe -StdOut $changed } -MessagePattern 'missing required field|unknown field' | Out-Null
        }
    }
}

Add-EzVmTest -Name 'Coding readiness: no identity, absent completion, pending profile and unfinished cloud-init never become READY' -ScriptBlock {
    $identity = New-EzVmSshTestIdentityJson -Intent (New-EzVmSshTestIntent)
    $probe = New-EzVmSshTestProbe -IdentityBase64 (ConvertTo-EzVmSshTestBase64 $identity)
    foreach ($change in @(
        @('EZVM_IDENTITY_B64', ''), @('EZVM_READY_B64', ''), @('EZVM_PROFILE_CHECK', 'pending'),
        @('EZVM_CLOUD_B64', (ConvertTo-EzVmSshTestBase64 'status: running'))
    )) {
        $changed = Set-EzVmCodingTestProbeField -Probe $probe -Field $change[0] -Value $change[1]
        Assert-EzVmEqual -Actual (ConvertFrom-EzVmCodingTestProbe -StdOut $changed).Ready -Expected $false
    }
    $document = $identity | ConvertFrom-Json
    $document | Add-Member -NotePropertyName provisioningState -NotePropertyValue 'provisioning'
    $changed = Set-EzVmCodingTestProbeField -Probe $probe -Field 'EZVM_READY_B64' -Value (ConvertTo-EzVmSshTestBase64 ($document | ConvertTo-Json -Compress))
    Assert-EzVmThrows -ScriptBlock { ConvertFrom-EzVmCodingTestProbe -StdOut $changed } -MessagePattern 'does not record complete' | Out-Null
}

Add-EzVmTest -Name 'Coding readiness: missing required tool and degraded cloud-init are hard failures despite old success markers' -ScriptBlock {
    $identity = New-EzVmSshTestIdentityJson -Intent (New-EzVmSshTestIntent)
    $encoded = ConvertTo-EzVmSshTestBase64 $identity
    $probe = New-EzVmSshTestProbe -IdentityBase64 $encoded -ProfileCheck failed -ProfileError 'missing required command: rg'
    Assert-EzVmThrows -ScriptBlock { ConvertFrom-EzVmCodingTestProbe -StdOut $probe } -MessagePattern 'Coding profile validation failed.*missing required command: rg' | Out-Null
    foreach ($exit in @('1', '2', '127', 'invalid')) {
        $probe = New-EzVmSshTestProbe -IdentityBase64 $encoded -CloudExit $exit
        Assert-EzVmThrows -ScriptBlock { ConvertFrom-EzVmCodingTestProbe -StdOut $probe } -MessagePattern 'cloud-init reports failed' | Out-Null
    }
}

Add-EzVmTest -Name 'Coding readiness: malformed, duplicate, truncated and legacy probe records fail closed' -ScriptBlock {
    $identity = New-EzVmSshTestIdentityJson -Intent (New-EzVmSshTestIntent)
    $encoded = ConvertTo-EzVmSshTestBase64 $identity
    $probe = New-EzVmSshTestProbe -IdentityBase64 $encoded
    foreach ($bad in @(
        ($probe + 'EZVM_PROFILE_CHECK=pass'),
        ($probe + 'UNEXPECTED=pass'),
        ($probe + 'unframed output'),
        (Set-EzVmCodingTestProbeField -Probe $probe -Field 'EZVM_IDENTITY_B64' -Value '%%%'),
        (Set-EzVmCodingTestProbeField -Probe $probe -Field 'EZVM_READY_B64' -Value '/w=='),
        (Set-EzVmCodingTestProbeField -Probe $probe -Field 'EZVM_READY_B64' -Value (ConvertTo-EzVmSshTestBase64 ('x' * 8193))),
        ('x' * 65537),
        ('EZVM_IDENTITY_B64=' + $encoded + [Environment]::NewLine + 'EZVM_READY=1')
    )) {
        Assert-EzVmThrows -ScriptBlock { ConvertFrom-EzVmCodingTestProbe -StdOut $bad } | Out-Null
    }
}

Add-EzVmTest -Name 'Coding readiness: failed live proof clears cached host READY and preserves managed host-key trust' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'coding failed revalidation'
    try {
        $intent = New-EzVmSshTestIntent
        $access = New-EzVmSshTestAccess -Root $root -Intent $intent
        $launch = New-EzVmSshTestLaunch -Root $root -Intent $intent -Access $access
        $access.state = 'READY'
        $access.readyAt = [DateTime]::UtcNow.ToString('o')
        $paths = Get-EzVmSshPaths -Root $root -InstanceName $intent.name
        [void][IO.Directory]::CreateDirectory($paths.KnownHostsDirectory)
        $oldTrust = '[127.0.0.1]:22001 ssh-ed25519 AAAA' + [Environment]::NewLine
        [IO.File]::WriteAllText($paths.InstanceKnownHosts, $oldTrust)
        $probe = New-EzVmSshTestProbe -IdentityBase64 (ConvertTo-EzVmSshTestBase64 (New-EzVmSshTestIdentityJson -Intent $intent)) -ProfileCheck failed -ProfileError 'missing required command: rg'
        $module = Get-Module EzVm
        Assert-EzVmThrows -ScriptBlock {
            & $module {
                param($r, $i, $a, $output, $processProvider)
                $runner = { param($exe, $arguments, $timeout) [pscustomobject]@{ ExitCode = 0; StdOut = $output; StdErr = '' } }.GetNewClosure()
                Wait-EzVmSshReady -Root $r -InstanceName $i.name -Intent $i -Access $a -Identity ([pscustomobject]@{PrivateKey = 'unused'}) -Tooling ([pscustomobject]@{Ssh = 'unused'}) -TimeoutSeconds 3 -PortProbe { $true } -HostKeyScanner { '[127.0.0.1]:22001 ssh-ed25519 BBBB' } -SshRunner $runner -ProcessProvider $processProvider
            } $root $intent $access $probe $launch.ProcessProvider
        } -MessagePattern 'Coding profile validation failed.*missing required command: rg' | Out-Null
        $after = Read-EzVmJson -Path $paths.AccessState -SchemaVersion 2
        Assert-EzVmEqual -Actual $after.state -Expected 'PROVISIONING'
        Assert-EzVmEqual -Actual $after.readyAt -Expected ''
        Assert-EzVmEqual -Actual ([IO.File]::ReadAllText($paths.InstanceKnownHosts)) -Expected $oldTrust
        Assert-EzVmEqual -Actual @(Get-ChildItem -LiteralPath $paths.KnownHostsDirectory -Filter '*.candidate' -File -Force).Count -Expected 0
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Coding readiness: parent deadline prevents a fresh child budget from granting late READY or trust' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'coding late proof'
    try {
        $intent = New-EzVmSshTestIntent
        $access = New-EzVmSshTestAccess -Root $root -Intent $intent
        $launch = New-EzVmSshTestLaunch -Root $root -Intent $intent -Access $access
        $paths = Get-EzVmSshPaths -Root $root -InstanceName $intent.name
        $probe = New-EzVmSshTestProbe -IdentityBase64 (ConvertTo-EzVmSshTestBase64 (New-EzVmSshTestIdentityJson -Intent $intent))
        $module = Get-Module EzVm
        Assert-EzVmThrows -ScriptBlock {
            & $module {
                param($r, $i, $a, $output, $processProvider)
                $runner = {
                    param($exe, $arguments, $timeout)
                    Start-Sleep -Milliseconds 2200
                    [pscustomobject]@{ ExitCode = 0; StdOut = $output; StdErr = '' }
                }.GetNewClosure()
                Wait-EzVmSshReady -Root $r -InstanceName $i.name -Intent $i -Access $a -Identity ([pscustomobject]@{PrivateKey = 'unused'}) -Tooling ([pscustomobject]@{Ssh = 'unused'}) -TimeoutSeconds 5 -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(2)) -PortProbe { $true } -HostKeyScanner { '[127.0.0.1]:22001 ssh-ed25519 BBBB' } -SshRunner $runner -ProcessProvider $processProvider
            } $root $intent $access $probe $launch.ProcessProvider
        } -MessagePattern 'exceeded.*deadline' | Out-Null
        Assert-EzVmTrue -Condition (-not (Test-Path -LiteralPath $paths.InstanceKnownHosts)) -Message 'Late evidence must not become managed host-key trust.'
        Assert-EzVmEqual -Actual (Read-EzVmJson -Path $paths.AccessState -SchemaVersion 2).state -Expected 'PROVISIONING'
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Coding readiness: access schemas and profile versions reject coercion and mixed intent' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'coding access schemas'
    try {
        $intent = New-EzVmSshTestIntent
        $module = Get-Module EzVm
        foreach ($change in @(@('schemaVersion', 1), @('schemaVersion', '2'), @('provisioningVersion', $true), @('provisioningVersion', '1'), @('provisioningProfile', 'ezvm-core'), @('provisioningDigest', 'bad'))) {
            $access = New-EzVmSshTestAccess -Root $root -Intent $intent
            $access.($change[0]) = $change[1]
            Assert-EzVmThrows -ScriptBlock {
                & $module { param($a) Assert-EzVmSshAccessState -Access $a -ExpectedName 'ssh-agent' } $access
            } | Out-Null
        }
        foreach ($change in @(@('baseId', ('base-' + ('b' * 64))), @('provisioningDigest', ('0' * 64)), @('cloudInstanceId', 'ezvm-different-123456789abc'))) {
            $access = New-EzVmSshTestAccess -Root $root -Intent $intent
            $access.($change[0]) = $change[1]
            Assert-EzVmThrows -ScriptBlock {
                & $module {
                    param($r, $i, $a)
                    Wait-EzVmSshReady -Root $r -InstanceName $i.name -Intent $i -Access $a -Identity ([pscustomobject]@{PrivateKey='unused'}) -Tooling ([pscustomobject]@{Ssh='unused'}) -TimeoutSeconds 2
                } $root $intent $access
            } -MessagePattern 'does not match the requested instance and coding profile' | Out-Null
        }
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}
