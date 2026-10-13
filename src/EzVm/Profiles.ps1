function Get-EzVmCodingProfile {
    [CmdletBinding()]
    param(
        [string]$Root = $script:EzVmDefaultRoot,
        [string]$Name = 'coding-default',
        [int]$Version = 1
    )

    if ($Name -cne 'coding-default' -or $Version -ne 1) {
        throw "Guest provisioning profile '$Name' version '$Version' is unsupported. Create a new named instance with coding-default version 1; existing legacy overlays are not silently upgraded or reset."
    }

    $paths = Get-EzVmPaths -Root $Root
    $directory = Join-Path $paths.Root 'guest/profiles/coding-default/v1'
    $manifestPath = Join-Path $directory 'profile.json'
    $scriptPath = Join-Path $directory 'provision.sh'
    foreach ($path in @($manifestPath, $scriptPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Coding profile source is missing: '$path'. Restore the reviewed profile files before creating or starting an instance."
        }
    }

    $manifest = Read-EzVmJson -Path $manifestPath -SchemaVersion 1
    Assert-EzVmBaseRecipeFields -Value $manifest -Expected @(
        'schemaVersion', 'name', 'version', 'user', 'home', 'workspace', 'privilege', 'requiredCommands'
    ) -Description 'Coding profile'
    Assert-EzVmBaseRecipeInteger -Value $manifest.version -Minimum 1 -Maximum 1 -Description 'Coding profile version'
    foreach ($entry in @(
        @('name', 'coding-default'),
        @('user', 'coder'),
        @('home', '/home/coder'),
        @('workspace', '/home/coder/workspace'),
        @('privilege', 'passwordless-sudo')
    )) {
        $value = $manifest.($entry[0])
        if ($value -isnot [string] -or $value -cne $entry[1]) {
            throw "Coding profile $($entry[0]) must be exactly '$($entry[1])' for coding-default version 1."
        }
    }

    $required = @(
        'sshd', 'ssh', 'scp', 'sudo', 'cloud-init', 'git', 'gcc', 'g++', 'make',
        'cmake', 'ninja', 'python3', 'pip3', 'curl', 'wget', 'jq', 'rg', 'unzip',
        'zip', 'rsync', 'tmux'
    )
    if ($manifest.requiredCommands -isnot [array] -or $manifest.requiredCommands.Count -ne $required.Count) {
        throw 'Coding profile requiredCommands must contain the complete version 1 command contract exactly once.'
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($command in $manifest.requiredCommands) {
        if ($command -isnot [string] -or $command -cnotmatch '^[A-Za-z0-9][A-Za-z0-9+._-]*$' -or
            $required -cnotcontains $command -or -not $seen.Add($command)) {
            throw "Coding profile requiredCommands contains an unsafe, unsupported or duplicate command. Restore the complete reviewed version 1 command contract."
        }
    }

    $utf8 = New-Object Text.UTF8Encoding($false, $true)
    $manifestJson = (Read-EzVmBoundedText -Path $manifestPath -MaximumBytes 65536).Replace("`r`n", "`n").Replace("`r", "`n").TrimEnd([char[]]@([char]10)) + "`n"
    $guestScript = (Read-EzVmBoundedText -Path $scriptPath -MaximumBytes 1048576).Replace("`r`n", "`n").Replace("`r", "`n").TrimEnd([char[]]@([char]10)) + "`n"
    if (-not $guestScript.StartsWith("#!/bin/sh`n", [StringComparison]::Ordinal)) {
        throw 'Coding profile provision.sh must be a reviewed POSIX shell script.'
    }
    foreach ($content in @($manifestJson, $guestScript)) {
        Assert-EzVmCredentialFreeText -Text $content -Description 'Coding profile source'
        if ($content.IndexOf([char]0) -ge 0 -or
            $content -match '(?im)BEGIN .*PRIVATE KEY|OPENSSH PRIVATE KEY|github_pat_|ghp_[A-Za-z0-9]|__[A-Z0-9_]+__') {
            throw 'Coding profile source contains a binary NUL, unresolved placeholder or credential-like material.'
        }
    }

    # File names and NUL delimiters make the two normalized UTF-8 source inputs
    # unambiguous. CRLF checkouts and LF checkouts have the same guest identity.
    $digestInput = 'profile.json' + [char]0 + $manifestJson + [char]0 +
        'provision.sh' + [char]0 + $guestScript + [char]0
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = ([BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($digestInput)))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }

    return [pscustomobject][ordered]@{
        Name = [string]$manifest.name
        Version = [int]$manifest.version
        Digest = $digest
        Manifest = $manifest
        ManifestJson = $manifestJson
        Script = $guestScript
    }
}
