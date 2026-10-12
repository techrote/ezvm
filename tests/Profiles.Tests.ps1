function Get-EzVmProfileTestPaths {
    param([string]$Root)
    $directory = Join-Path $Root 'guest/profiles/coding-default/v1'
    return [pscustomobject]@{
        Manifest = Join-Path $directory 'profile.json'
        Script = Join-Path $directory 'provision.sh'
    }
}

function Write-EzVmProfileTestJson {
    param([string]$Path, [object]$Value)
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
}

Add-EzVmTest -Name 'Coding profile: versioned defaults define one complete usable coding command contract' -ScriptBlock {
    $profile = Get-EzVmCodingProfile -Root $script:EzVmRepositoryRoot
    Assert-EzVmEqual -Actual $profile.Name -Expected 'coding-default'
    Assert-EzVmEqual -Actual $profile.Version -Expected 1
    Assert-EzVmTrue -Condition ($profile.Digest -cmatch '^[a-f0-9]{64}$')
    Assert-EzVmEqual -Actual $profile.Manifest.user -Expected 'coder'
    Assert-EzVmEqual -Actual $profile.Manifest.home -Expected '/home/coder'
    Assert-EzVmEqual -Actual $profile.Manifest.workspace -Expected '/home/coder/workspace'
    Assert-EzVmEqual -Actual $profile.Manifest.privilege -Expected 'passwordless-sudo'
    $expected = @(
        'sshd', 'ssh', 'scp', 'sudo', 'cloud-init', 'git', 'gcc', 'g++', 'make',
        'cmake', 'ninja', 'python3', 'pip3', 'curl', 'wget', 'jq', 'rg', 'unzip',
        'zip', 'rsync', 'tmux'
    )
    Assert-EzVmEqual -Actual @($profile.Manifest.requiredCommands | Sort-Object) -Expected @($expected | Sort-Object)
    $baseline = Get-EzVmBaseRecipe -Root $script:EzVmRepositoryRoot
    foreach ($command in $expected) {
        Assert-EzVmTrue -Condition (@($baseline.requiredCommands) -ccontains $command) -Message "Prepared-base validation must supply profile command '$command'."
    }
    foreach ($package in @('openssh-client', 'openssh-server', 'sudo', 'python3-venv', 'python3-pip')) {
        Assert-EzVmTrue -Condition (@($baseline.packages) -ccontains $package) -Message "Prepared base must explicitly install '$package'."
    }
}

Add-EzVmTest -Name 'Coding profile: legacy, unknown, case-changed and unsafe profile identities refuse without upgrade' -ScriptBlock {
    foreach ($name in @('ezvm-core', 'unknown', 'Coding-Default', '../coding-default')) {
        Assert-EzVmThrows -ScriptBlock {
            Get-EzVmCodingProfile -Root $script:EzVmRepositoryRoot -Name $name
        } -MessagePattern 'unsupported.*new named instance.*not silently upgraded' | Out-Null
    }
    foreach ($version in @(0, 2, 2147483647)) {
        Assert-EzVmThrows -ScriptBlock {
            Get-EzVmCodingProfile -Root $script:EzVmRepositoryRoot -Version $version
        } -MessagePattern 'unsupported.*new named instance' | Out-Null
    }
}

Add-EzVmTest -Name 'Coding profile: normalized source digest is stable across relocation and CRLF checkout' -ScriptBlock {
    $first = New-EzVmCheckoutFixture -Prefix 'coding profile LF [spaces]'
    $second = New-EzVmCheckoutFixture -Prefix 'coding profile CRLF moved'
    try {
        $original = Get-EzVmCodingProfile -Root $first
        $files = Get-EzVmProfileTestPaths -Root $second
        foreach ($path in @($files.Manifest, $files.Script)) {
            $text = [IO.File]::ReadAllText($path).Replace("`r`n", "`n").Replace("`r", "`n")
            [IO.File]::WriteAllText($path, $text.Replace("`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))
        }
        $moved = Get-EzVmCodingProfile -Root $second
        Assert-EzVmEqual -Actual $moved.Digest -Expected $original.Digest
        Assert-EzVmEqual -Actual $moved.ManifestJson -Expected $original.ManifestJson
        Assert-EzVmEqual -Actual $moved.Script -Expected $original.Script
        Assert-EzVmTrue -Condition (-not $moved.Script.Contains("`r") -and -not $moved.ManifestJson.Contains("`r"))
        Assert-EzVmTrue -Condition ($moved.Script.EndsWith("`n", [StringComparison]::Ordinal))
        Assert-EzVmTrue -Condition ($moved.ManifestJson.EndsWith("`n", [StringComparison]::Ordinal))
    }
    finally {
        Remove-EzVmTestDirectory -Path $first
        Remove-EzVmTestDirectory -Path $second
    }
}

Add-EzVmTest -Name 'Coding profile: digest covers both reviewed manifest and guest implementation bytes' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'coding profile digest inputs'
    try {
        $files = Get-EzVmProfileTestPaths -Root $root
        $before = Get-EzVmCodingProfile -Root $root
        [IO.File]::AppendAllText($files.Script, "# reviewed implementation change`n", (New-Object Text.UTF8Encoding($false)))
        $scriptChanged = Get-EzVmCodingProfile -Root $root
        Assert-EzVmTrue -Condition ($scriptChanged.Digest -cne $before.Digest)
        $manifest = Read-EzVmJson -Path $files.Manifest
        $commands = @($manifest.requiredCommands)
        [Array]::Reverse($commands)
        $manifest.requiredCommands = $commands
        Write-EzVmProfileTestJson -Path $files.Manifest -Value $manifest
        $manifestChanged = Get-EzVmCodingProfile -Root $root
        Assert-EzVmTrue -Condition ($manifestChanged.Digest -cne $scriptChanged.Digest)
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Coding profile: schema, version, paths, account and privilege drift are rejected' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'coding profile strict schema'
    try {
        $files = Get-EzVmProfileTestPaths -Root $root
        $original = [IO.File]::ReadAllText($files.Manifest)
        foreach ($case in @(
            @{ Field = 'schemaVersion'; Value = 2; Error = 'unsupported schemaVersion' },
            @{ Field = 'schemaVersion'; Value = '1'; Error = 'integer schemaVersion' },
            @{ Field = 'schemaVersion'; Value = $true; Error = 'integer schemaVersion' },
            @{ Field = 'version'; Value = 2; Error = 'profile version' },
            @{ Field = 'version'; Value = '1'; Error = 'profile version' },
            @{ Field = 'version'; Value = $true; Error = 'profile version' },
            @{ Field = 'name'; Value = 'coding-other'; Error = 'profile name' },
            @{ Field = 'user'; Value = 'root'; Error = 'profile user' },
            @{ Field = 'home'; Value = '/root'; Error = 'profile home' },
            @{ Field = 'workspace'; Value = '/home/coder/../root'; Error = 'profile workspace' },
            @{ Field = 'privilege'; Value = 'unknown'; Error = 'profile privilege' }
        )) {
            $manifest = $original | ConvertFrom-Json
            $manifest.($case.Field) = $case.Value
            Write-EzVmProfileTestJson -Path $files.Manifest -Value $manifest
            Assert-EzVmThrows -ScriptBlock { Get-EzVmCodingProfile -Root $root } -MessagePattern $case.Error | Out-Null
        }
        $manifest = $original | ConvertFrom-Json
        Add-Member -InputObject $manifest -MemberType NoteProperty -Name UnexpectedField -Value 'not a profile extension'
        Write-EzVmProfileTestJson -Path $files.Manifest -Value $manifest
        Assert-EzVmThrows -ScriptBlock { Get-EzVmCodingProfile -Root $root } -MessagePattern 'unknown field' | Out-Null
        $manifest = $original | ConvertFrom-Json
        $manifest.PSObject.Properties.Remove('workspace')
        Write-EzVmProfileTestJson -Path $files.Manifest -Value $manifest
        Assert-EzVmThrows -ScriptBlock { Get-EzVmCodingProfile -Root $root } -MessagePattern 'missing required field' | Out-Null
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Coding profile: empty, missing, duplicate, shell-significant and non-string tool lists refuse' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'coding profile command boundaries'
    try {
        $files = Get-EzVmProfileTestPaths -Root $root
        $original = [IO.File]::ReadAllText($files.Manifest)
        foreach ($kind in @('empty', 'missing', 'duplicate', 'unsafe', 'nonstring', 'scalar', 'null', 'unsupported')) {
            $manifest = $original | ConvertFrom-Json
            switch ($kind) {
                'empty' { $manifest.requiredCommands = @() }
                'missing' { $manifest.requiredCommands = @($manifest.requiredCommands | Where-Object { $_ -cne 'rg' }) }
                'duplicate' { $manifest.requiredCommands[0] = $manifest.requiredCommands[1] }
                'unsafe' { $manifest.requiredCommands[0] = 'sshd; touch /tmp/untrusted' }
                'nonstring' { $manifest.requiredCommands[0] = 1 }
                'scalar' { $manifest.requiredCommands = 'sshd' }
                'null' { $manifest.requiredCommands = $null }
                'unsupported' { $manifest.requiredCommands[0] = 'unreviewed-command' }
            }
            Write-EzVmProfileTestJson -Path $files.Manifest -Value $manifest
            Assert-EzVmThrows -ScriptBlock { Get-EzVmCodingProfile -Root $root } -MessagePattern 'requiredCommands' | Out-Null
        }
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Coding profile: missing implementation, placeholder, private material and token comments fail before generation' -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'coding profile source refusal'
    try {
        $files = Get-EzVmProfileTestPaths -Root $root
        $original = [IO.File]::ReadAllText($files.Script)
        Remove-Item -LiteralPath $files.Script
        Assert-EzVmThrows -ScriptBlock { Get-EzVmCodingProfile -Root $root } -MessagePattern 'source is missing' | Out-Null
        foreach ($suffix in @(
            ('# ' + '__UNRESOLVED_PROFILE_VALUE__'),
            ('# ' + 'BEGIN OPENSSH PRIVATE KEY'),
            ('# ' + 'ghp_' + ('x' * 20)),
            ('# binary ' + [char]0)
        )) {
            [IO.File]::WriteAllText($files.Script, $original + "`n" + $suffix, (New-Object Text.UTF8Encoding($false)))
            Assert-EzVmThrows -ScriptBlock { Get-EzVmCodingProfile -Root $root } -MessagePattern 'placeholder or credential-like' | Out-Null
        }
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Coding profile: guest validation retains bounded functional checks and safe workspace creation' -ScriptBlock {
    $profile = Get-EzVmCodingProfile -Root $script:EzVmRepositoryRoot
    $guest = $profile.Script
    Assert-EzVmTrue -Condition ($guest.Contains('os.O_NOFOLLOW') -and $guest.Contains('dir_fd=home')) -Message 'Workspace creation must not follow caller-controlled symlinks.'
    Assert-EzVmTrue -Condition ($guest.Contains('os.fchown(workspace, uid, gid)'))
    Assert-EzVmTrue -Condition ($guest.Contains('home_info.st_mode & 0o700 != 0o700')) -Message 'A root-readable but coder-inaccessible home must not qualify.'
    Assert-EzVmTrue -Condition ($guest.Contains('timeout 10 python3 -') -and $guest.Contains("os.chdir('/home/coder/workspace')") -and $guest.Contains('tempfile.TemporaryFile(') -and $guest.Contains('if probe.read() != payload:')) -Message 'Readiness must prove actual coder workspace traversal, writing and reading with automatic probe cleanup.'
    Assert-EzVmTrue -Condition ($guest -notmatch '(?i)chown\s+-R|os\.walk\(') -Message 'Provisioning must not recursively rewrite existing workspace content.'
    Assert-EzVmTrue -Condition ($guest.Contains('passwd -S coder') -and $guest.Contains('passwd -S root'))
    Assert-EzVmTrue -Condition ($guest.Contains('sudo -n -- /usr/bin/id -u'))
    Assert-EzVmTrue -Condition ($guest.Contains('timeout 90 sh -eu -c') -and $guest.Contains('python3 -m venv') -and $guest.Contains('-m pip --version'))
    Assert-EzVmTrue -Condition ($guest.Contains('provisioningState: "complete"') -and $guest.Contains('mv -f -- "$ready_temporary" /var/lib/ezvm/ready.json'))
    Assert-EzVmTrue -Condition ($guest.Contains('rm -f -- /var/lib/ezvm/ready.json')) -Message 'A failed live validation must invalidate stale completion evidence.'
    Assert-EzVmTrue -Condition ($guest -notmatch '(?i)curl\s+[^\r\n]*\|\s*(sh|bash)|wget\s+[^\r\n]*\|\s*(sh|bash)|apt(-get)?\s+install') -Message 'Instance provisioning validates the stable base and must not run an unreviewed installer.'
    Assert-EzVmTrue -Condition (($profile.ManifestJson + $guest) -notmatch '(?i)PRIVATE KEY|github_pat_|ghp_[A-Za-z0-9]|__[A-Z0-9_]+__')
}
