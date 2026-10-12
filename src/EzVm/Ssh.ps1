function Get-EzVmOpenSshTools {
    [CmdletBinding()]
    param()

    $isWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
    $spec = [ordered]@{
        Ssh = $(if ($isWindows) { 'ssh.exe' } else { 'ssh' })
        Scp = $(if ($isWindows) { 'scp.exe' } else { 'scp' })
        Keygen = $(if ($isWindows) { 'ssh-keygen.exe' } else { 'ssh-keygen' })
    }
    $resolved = [ordered]@{}
    $missing = New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in $spec.GetEnumerator()) {
        $command = @(Get-Command -Name $entry.Value -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($command.Count -eq 0) {
            $resolved[$entry.Key] = $null
            $missing.Add($entry.Value)
            continue
        }
        $path = $command[0].Source
        if ([string]::IsNullOrWhiteSpace($path)) { $path = $command[0].Path }
        if ([string]::IsNullOrWhiteSpace($path)) {
            $resolved[$entry.Key] = $null
            $missing.Add($entry.Value)
            continue
        }
        $resolved[$entry.Key] = [IO.Path]::GetFullPath($path)
    }

    $valid = $missing.Count -eq 0
    $reason = if ($valid) {
        'Windows OpenSSH client tooling required by ezvm is available.'
    }
    else {
        'Missing required OpenSSH application(s): ' + ([string]::Join(', ', $missing.ToArray())) + '.'
    }
    return [pscustomobject][ordered]@{
        Valid = $valid
        Ssh = $resolved.Ssh
        Scp = $resolved.Scp
        Keygen = $resolved.Keygen
        Missing = [string[]]$missing.ToArray()
        Reason = $reason
    }
}

function Assert-EzVmOpenSshTools {
    param([AllowNull()][object]$Tooling = $null)

    if ($null -eq $Tooling) { $Tooling = Get-EzVmOpenSshTools }
    if ($null -eq $Tooling -or $Tooling.Valid -ne $true) {
        $detail = if ($null -ne $Tooling -and -not [string]::IsNullOrWhiteSpace([string]$Tooling.Reason)) {
            [string]$Tooling.Reason
        } else {
            'Required OpenSSH tooling could not be resolved.'
        }
        throw "$detail Install the Windows OpenSSH Client optional feature so ssh.exe, scp.exe and ssh-keygen.exe are available, then run '.\ezvm.ps1 doctor' again."
    }
    return $Tooling
}

function Get-EzVmSshPaths {
    [CmdletBinding()]
    param(
        [string]$Root = $script:EzVmDefaultRoot,
        [string]$InstanceName
    )

    $paths = Get-EzVmPaths -Root $Root
    $knownHostsDirectory = Join-Path $paths.Keys 'known-hosts'
    $instanceKnownHosts = $null
    $accessState = $null
    if (-not [string]::IsNullOrWhiteSpace($InstanceName)) {
        Assert-EzVmStorageInstanceName -Name $InstanceName
        $runtimePaths = Get-EzVmInstanceRuntimePaths -Root $Root -InstanceName $InstanceName
        $instanceKnownHosts = Join-Path $knownHostsDirectory ($InstanceName + '.known_hosts')
        $accessState = Join-Path $runtimePaths.Directory 'access.json'
    }
    return [pscustomobject][ordered]@{
        KeysDirectory = [IO.Path]::GetFullPath($paths.Keys)
        ControllerPrivateKey = [IO.Path]::GetFullPath((Join-Path $paths.Keys 'controller_ed25519'))
        ControllerPublicKey = [IO.Path]::GetFullPath((Join-Path $paths.Keys 'controller_ed25519.pub'))
        KnownHostsDirectory = [IO.Path]::GetFullPath($knownHostsDirectory)
        InstanceKnownHosts = $(if ($null -ne $instanceKnownHosts) { [IO.Path]::GetFullPath($instanceKnownHosts) } else { $null })
        AccessState = $(if ($null -ne $accessState) { [IO.Path]::GetFullPath($accessState) } else { $null })
    }
}

function Write-EzVmSshTextAtomically {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowEmptyString()][string]$Content = ''
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    [void][IO.Directory]::CreateDirectory($directory)
    $temporary = Join-Path $directory ('.' + [IO.Path]::GetFileName($fullPath) + '.tmp-' + [Guid]::NewGuid().ToString('N'))
    try {
        $encoding = New-Object Text.UTF8Encoding($false)
        $stream = New-Object IO.FileStream($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $bytes = $encoding.GetBytes($Content)
            if ($bytes.Length -gt 0) { $stream.Write($bytes, 0, $bytes.Length) }
            $stream.Flush($true)
        }
        finally { $stream.Dispose() }

        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            [IO.File]::Replace($temporary, $fullPath, [System.Management.Automation.Language.NullString]::Value)
        }
        else {
            [IO.File]::Move($temporary, $fullPath)
        }
    }
    catch {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Protect-EzVmControllerPrivateKey {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowNull()][object]$ProcessRunner = $null
    )

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return }
    $systemRoot = [Environment]::GetEnvironmentVariable('SystemRoot')
    if ([string]::IsNullOrWhiteSpace($systemRoot)) {
        throw 'Cannot restrict the controller private-key ACL because SystemRoot is unavailable.'
    }
    $icacls = Join-Path $systemRoot 'System32\icacls.exe'
    if (-not (Test-Path -LiteralPath $icacls -PathType Leaf)) {
        throw "Cannot restrict the controller private-key ACL because '$icacls' is unavailable."
    }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $arguments = @(
        [IO.Path]::GetFullPath($Path),
        '/inheritance:r',
        '/grant:r',
        ('*' + $sid + ':(F)')
    )
    $result = if ($null -ne $ProcessRunner) {
        & $ProcessRunner $icacls $arguments 15
    } else {
        Invoke-EzVmProcess -FilePath $icacls -ArgumentList $arguments -TimeoutSeconds 15
    }
    if ($null -eq $result -or [int]$result.ExitCode -ne 0) {
        $detail = if ($null -ne $result) { [string]$result.StdErr } else { '' }
        throw "Failed to restrict the ezvm controller private-key ACL. $detail"
    }
}

function Get-EzVmControllerSshIdentity {
    [CmdletBinding()]
    param(
        [string]$Root = $script:EzVmDefaultRoot,
        [AllowNull()][object]$Tooling = $null,
        [scriptblock]$ProcessRunner
    )

    $Tooling = Assert-EzVmOpenSshTools -Tooling $Tooling
    $paths = Get-EzVmSshPaths -Root $Root
    [void][IO.Directory]::CreateDirectory($paths.KeysDirectory)
    $privateExists = Test-Path -LiteralPath $paths.ControllerPrivateKey -PathType Leaf
    $publicExists = Test-Path -LiteralPath $paths.ControllerPublicKey -PathType Leaf
    $createdThisCall = $false

    if (-not $privateExists -and $publicExists) {
        throw "The ezvm controller public key exists without its private key at '$($paths.ControllerPrivateKey)'. Restore the matching private key or remove the orphan public key deliberately before generating a new controller identity."
    }

    if (-not $privateExists) {
        $arguments = @('-q', '-t', 'ed25519', '-N', '', '-C', 'ezvm-controller', '-f', $paths.ControllerPrivateKey)
        $result = if ($null -ne $ProcessRunner) {
            & $ProcessRunner $Tooling.Keygen $arguments 30
        } else {
            Invoke-EzVmProcess -FilePath $Tooling.Keygen -ArgumentList $arguments -TimeoutSeconds 30
        }
        if ($null -eq $result -or [int]$result.ExitCode -ne 0) {
            $detail = if ($null -ne $result) { [string]$result.StdErr } else { '' }
            throw "ssh-keygen could not create the ezvm controller keypair. $detail"
        }
        $createdThisCall = $true
        $privateExists = Test-Path -LiteralPath $paths.ControllerPrivateKey -PathType Leaf
        $publicExists = Test-Path -LiteralPath $paths.ControllerPublicKey -PathType Leaf
        if (-not $privateExists -or -not $publicExists) {
            foreach ($path in @($paths.ControllerPrivateKey, $paths.ControllerPublicKey)) {
                if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
            }
            throw 'ssh-keygen reported success but did not create both controller key files.'
        }
    }

    try {
        Protect-EzVmControllerPrivateKey -Path $paths.ControllerPrivateKey -ProcessRunner $ProcessRunner
    }
    catch {
        if ($createdThisCall) {
            foreach ($path in @($paths.ControllerPrivateKey, $paths.ControllerPublicKey)) {
                if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
            }
        }
        throw
    }

    if (-not $publicExists) {
        $arguments = @('-y', '-f', $paths.ControllerPrivateKey)
        $result = if ($null -ne $ProcessRunner) {
            & $ProcessRunner $Tooling.Keygen $arguments 30
        } else {
            Invoke-EzVmProcess -FilePath $Tooling.Keygen -ArgumentList $arguments -TimeoutSeconds 30
        }
        if ($null -eq $result -or [int]$result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$result.StdOut)) {
            throw 'The controller public key is missing and could not be reconstructed from the private key.'
        }
        Write-EzVmSshTextAtomically -Path $paths.ControllerPublicKey -Content ($result.StdOut.Trim() + ' ezvm-controller' + [Environment]::NewLine)
    }

    $publicKey = [IO.File]::ReadAllText($paths.ControllerPublicKey, (New-Object Text.UTF8Encoding($false, $true))).Trim()
    if ($publicKey -cnotmatch '^ssh-ed25519 [A-Za-z0-9+/]+={0,2}(?: [^\r\n]*)?$') {
        throw 'The ezvm controller public key is not a single valid-looking Ed25519 OpenSSH public-key line.'
    }
    if ($publicKey -match '(?i)PRIVATE KEY') {
        throw 'The controller public-key file contains private-key material; refusing to use it.'
    }
    return [pscustomobject][ordered]@{
        PrivateKey = $paths.ControllerPrivateKey
        PublicKey = $paths.ControllerPublicKey
        PublicKeyText = $publicKey
    }
}

function Get-EzVmSshSha256Hex {
    param([Parameter(Mandatory = $true)][string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($Text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Get-EzVmIntentProfileName {
    param(
        [string]$Root,
        [Parameter(Mandatory = $true)][object]$Intent
    )
    $profileProperty = $Intent.PSObject.Properties['profile']
    if ($null -ne $profileProperty -and
        $profileProperty.Value -is [string] -and
        @('light', 'normal', 'heavy', 'custom') -ccontains [string]$profileProperty.Value) {
        return [string]$profileProperty.Value
    }

    $configuration = Get-EzVmConfiguration -Root $Root
    foreach ($name in @('light', 'normal', 'heavy')) {
        $profile = $configuration.profiles.$name
        if ([int]$profile.cpus -eq [int]$Intent.cpus -and [int]$profile.memoryMiB -eq [int]$Intent.memoryMiB) {
            return $name
        }
    }
    return 'custom'
}

function ConvertTo-EzVmYamlSingleQuoted {
    param([AllowEmptyString()][string]$Value = '')
    return "'" + $Value.Replace("'", "''") + "'"
}

function Get-EzVmGuestHostname {
    param([Parameter(Mandatory = $true)][string]$InstanceName)
    Assert-EzVmStorageInstanceName -Name $InstanceName
    $label = ($InstanceName.ToLowerInvariant() -replace '[^a-z0-9-]', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($label)) { $label = 'instance' }
    if ($label.Length -gt 42) { $label = $label.Substring(0, 42).TrimEnd('-') }
    $suffix = (Get-EzVmSshSha256Hex -Text $InstanceName).Substring(0, 8)
    return 'ezvm-' + $label + '-' + $suffix
}

function New-EzVmInstanceSeedData {
    [CmdletBinding()]
    param(
        [string]$Root = $script:EzVmDefaultRoot,
        [Parameter(Mandatory = $true)][string]$InstanceName,
        [Parameter(Mandatory = $true)][object]$Intent,
        [Parameter(Mandatory = $true)][string]$ControllerPublicKey,
        [string]$Profile
    )

    Assert-EzVmStorageInstanceName -Name $InstanceName
    Assert-EzVmInstanceIntent -Intent $Intent -ExpectedName $InstanceName
    if ($ControllerPublicKey -cnotmatch '^ssh-ed25519 [A-Za-z0-9+/]+={0,2}(?: [^\r\n]*)?$' -or
        $ControllerPublicKey -match '(?i)PRIVATE KEY') {
        throw 'Instance seed requires exactly one Ed25519 controller public key and must never receive private-key material.'
    }
    if ([string]::IsNullOrWhiteSpace($Profile)) {
        $Profile = Get-EzVmIntentProfileName -Root $Root -Intent $Intent
    }
    if ($Profile -cnotmatch '^[a-z0-9][a-z0-9._-]{0,31}$') {
        throw "Instance profile marker '$Profile' is invalid."
    }

    $hostname = Get-EzVmGuestHostname -InstanceName $InstanceName
    $cloudIdHash = Get-EzVmSshSha256Hex -Text ($InstanceName + '|' + [string]$Intent.baseId + '|' + [string]$Intent.createdAt)
    $cloudInstanceId = 'ezvm-' + $InstanceName.ToLowerInvariant() + '-' + $cloudIdHash.Substring(0, 12)
    $identity = [pscustomobject][ordered]@{
        schemaVersion = 1
        instanceName = $InstanceName
        baseId = [string]$Intent.baseId
        profile = $Profile
        cloudInstanceId = $cloudInstanceId
    }
    $identityJson = $identity | ConvertTo-Json -Compress

    $userDataLines = @(
        '#cloud-config',
        'preserve_hostname: false',
        ('hostname: ' + (ConvertTo-EzVmYamlSingleQuoted $hostname)),
        'ssh_pwauth: false',
        'disable_root: true',
        'users:',
        '  - default',
        '  - name: coder',
        '    gecos: ezvm coding user',
        '    groups: [adm, sudo]',
        "    sudo: ['ALL=(ALL) NOPASSWD:ALL']",
        '    shell: /bin/bash',
        '    lock_passwd: true',
        '    ssh_authorized_keys:',
        ('      - ' + (ConvertTo-EzVmYamlSingleQuoted $ControllerPublicKey)),
        'write_files:',
        '  - path: /etc/ezvm/identity.json',
        '    owner: root:root',
        "    permissions: '0644'",
        '    content: |',
        ('      ' + $identityJson),
        '  - path: /usr/local/sbin/ezvm-instance-finalize',
        '    owner: root:root',
        "    permissions: '0755'",
        '    content: |',
        '      #!/bin/sh',
        '      set -eu',
        '      install -d -m 0755 /var/lib/ezvm',
        '      if cloud-init status --wait >/var/log/ezvm-cloud-init-status.log 2>&1; then',
        '        cp /etc/ezvm/identity.json /var/lib/ezvm/ready.json',
        '        chmod 0644 /var/lib/ezvm/ready.json',
        '        rm -f /var/lib/ezvm/provisioning-failed',
        '      else',
        "        printf '%s\n' 'cloud-init failed' > /var/lib/ezvm/provisioning-failed",
        '        exit 1',
        '      fi',
        'runcmd:',
        '  - [systemd-run, --no-block, --unit=ezvm-instance-finalize, --collect, --property=Type=oneshot, /usr/local/sbin/ezvm-instance-finalize]'
    )
    $metaDataLines = @(
        ('instance-id: ' + (ConvertTo-EzVmYamlSingleQuoted $cloudInstanceId)),
        ('local-hostname: ' + (ConvertTo-EzVmYamlSingleQuoted $hostname))
    )
    $userData = [string]::Join([Environment]::NewLine, $userDataLines) + [Environment]::NewLine
    $metaData = [string]::Join([Environment]::NewLine, $metaDataLines) + [Environment]::NewLine
    if (($userData + $metaData) -match '(?i)BEGIN .*PRIVATE KEY|OPENSSH PRIVATE KEY') {
        throw 'Generated instance NoCloud data unexpectedly contains private-key material.'
    }

    return [pscustomobject][ordered]@{
        UserData = $userData
        MetaData = $metaData
        InstanceName = $InstanceName
        BaseId = [string]$Intent.baseId
        Profile = $Profile
        Hostname = $hostname
        CloudInstanceId = $cloudInstanceId
        Identity = $identity
    }
}

function Enter-EzVmSshAllocationLock {
    param([string]$Root, [ValidateRange(1, 30000)][int]$TimeoutMilliseconds = 5000)

    $paths = Get-EzVmPaths -Root $Root
    [void][IO.Directory]::CreateDirectory($paths.Locks)
    $null = Assert-EzVmStorageManagedPath -Path $paths.Locks -ContainmentRoot $paths.Runtime -SafetyRoot $paths.Root -Description 'SSH allocation lock directory' -RequireDirectory
    $lockPath = Join-Path $paths.Locks 'ssh-port-allocation.lock'
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    while ($true) {
        try {
            return New-Object IO.FileStream($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        }
        catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) {
                throw 'Timed out waiting for the ezvm SSH port-allocation lock. Another instance start may still be publishing its localhost SSH endpoint.'
            }
            Start-Sleep -Milliseconds 50
        }
    }
}

function Test-EzVmLoopbackPortAvailable {
    param([Parameter(Mandatory = $true)][ValidateRange(1024, 65535)][int]$Port)
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
    try {
        $listener.Server.ExclusiveAddressUse = $true
        $listener.Start()
        return $true
    }
    catch [Net.Sockets.SocketException] { return $false }
    finally {
        try { $listener.Stop() } catch { }
    }
}

function Get-EzVmAvailableSshPort {
    [CmdletBinding()]
    param(
        [string]$Root = $script:EzVmDefaultRoot,
        [scriptblock]$PortProbe,
        [AllowEmptyCollection()][int[]]$ReservedPorts = @()
    )

    $configuration = Get-EzVmConfiguration -Root $Root
    $start = [int]$configuration.ssh.portRangeStart
    $end = [int]$configuration.ssh.portRangeEnd
    $reserved = @{}
    foreach ($value in @($ReservedPorts)) { $reserved[[int]$value] = $true }

    for ($port = $start; $port -le $end; $port++) {
        if ($reserved.ContainsKey($port)) { continue }
        $available = if ($null -ne $PortProbe) { [bool](& $PortProbe $port) } else { Test-EzVmLoopbackPortAvailable -Port $port }
        if ($available) { return $port }
    }
    throw "No unreserved loopback SSH port is available in configured range $start-$end. Stop an unused instance, free a conflicting local listener, or configure a different ezvm SSH range."
}

function Get-EzVmNullKnownHostsPath {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { return 'NUL' }
    return '/dev/null'
}

function ConvertTo-EzVmPosixArgument {
    param([AllowEmptyString()][string]$Value = '')
    if ($Value.IndexOf([char]0) -ge 0) { throw 'Remote command arguments cannot contain NUL characters.' }
    $single = [string][char]39
    $double = [string][char]34
    $escapedSingle = $single + $double + $single + $double + $single
    return $single + $Value.Replace($single, $escapedSingle) + $single
}

function Join-EzVmRemoteCommand {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Tokens)
    if ($Tokens.Count -eq 0) { throw 'A remote command requires at least one token.' }
    return [string]::Join(' ', @($Tokens | ForEach-Object { ConvertTo-EzVmPosixArgument $_ }))
}

function New-EzVmSshCommandArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PrivateKey,
        [Parameter(Mandatory = $true)][string]$KnownHosts,
        [Parameter(Mandatory = $true)][ValidateRange(1024, 65535)][int]$Port,
        [string]$User = 'coder',
        [AllowEmptyCollection()][string[]]$RemoteCommand = @(),
        [switch]$Batch,
        [switch]$AcceptNewHostKey,
        [ValidateRange(1, 60)][int]$ConnectTimeoutSeconds = 5
    )

    if ($User -cnotmatch '^[a-z_][a-z0-9_-]{0,31}$') { throw "SSH user '$User' is invalid." }
    $strictHostKeyMode = if ($AcceptNewHostKey) { 'accept-new' } else { 'yes' }
    $arguments = New-Object 'System.Collections.Generic.List[string]'
    foreach ($pair in @(
        @('-p', [string]$Port),
        @('-i', [IO.Path]::GetFullPath($PrivateKey)),
        @('-o', 'IdentitiesOnly=yes'),
        @('-o', ('StrictHostKeyChecking=' + $strictHostKeyMode)),
        @('-o', 'UpdateHostKeys=no'),
        @('-o', 'HostKeyAlgorithms=ssh-ed25519'),
        @('-o', 'HashKnownHosts=no'),
        @('-o', ('UserKnownHostsFile=' + [IO.Path]::GetFullPath($KnownHosts))),
        @('-o', ('GlobalKnownHostsFile=' + (Get-EzVmNullKnownHostsPath))),
        @('-o', 'PasswordAuthentication=no'),
        @('-o', 'KbdInteractiveAuthentication=no'),
        @('-o', 'PreferredAuthentications=publickey'),
        @('-o', ('ConnectTimeout=' + $ConnectTimeoutSeconds)),
        @('-o', 'ConnectionAttempts=1')
    )) {
        $arguments.Add($pair[0])
        $arguments.Add($pair[1])
    }
    if ($Batch) {
        $arguments.Add('-o')
        $arguments.Add('BatchMode=yes')
        $arguments.Add('-o')
        $arguments.Add('NumberOfPasswordPrompts=0')
    }
    $arguments.Add(($User + '@127.0.0.1'))
    if ($RemoteCommand.Count -gt 0) {
        $arguments.Add((Join-EzVmRemoteCommand -Tokens $RemoteCommand))
    }
    return $arguments.ToArray()
}

function New-EzVmScpCommandArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PrivateKey,
        [Parameter(Mandatory = $true)][string]$KnownHosts,
        [Parameter(Mandatory = $true)][ValidateRange(1024, 65535)][int]$Port,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    foreach ($value in @($Source, $Destination)) {
        if ([string]::IsNullOrWhiteSpace($value) -or $value.IndexOf([char]0) -ge 0 -or $value -match '[\r\n]') {
            throw 'SCP source and destination must be non-empty single-line paths without NUL characters.'
        }
    }
    return @(
        '-P', [string]$Port,
        '-i', [IO.Path]::GetFullPath($PrivateKey),
        '-o', 'IdentitiesOnly=yes',
        '-o', 'StrictHostKeyChecking=yes',
        '-o', 'UpdateHostKeys=no',
        '-o', 'HostKeyAlgorithms=ssh-ed25519',
        '-o', 'HashKnownHosts=no',
        '-o', ('UserKnownHostsFile=' + [IO.Path]::GetFullPath($KnownHosts)),
        '-o', ('GlobalKnownHostsFile=' + (Get-EzVmNullKnownHostsPath)),
        '-o', 'PasswordAuthentication=no',
        '-o', 'KbdInteractiveAuthentication=no',
        '--',
        $Source,
        $Destination
    )
}

function Get-EzVmKnownHostKeyMaterial {
    param([Parameter(Mandatory = $true)][string]$Line)
    $trimmed = $Line.Trim()
    $match = [regex]::Match($trimmed, '^(?<host>\S+)\s+(?<type>ssh-ed25519)\s+(?<key>[A-Za-z0-9+/]+={0,2})(?:\s+.*)?$')
    if (-not $match.Success) { throw 'Expected one OpenSSH Ed25519 known-host line.' }
    return [pscustomobject][ordered]@{
        Host = $match.Groups['host'].Value
        Type = $match.Groups['type'].Value
        Key = $match.Groups['key'].Value
        Material = $match.Groups['type'].Value + ' ' + $match.Groups['key'].Value
    }
}

function New-EzVmEmptyCandidateKnownHosts {
    param(
        [string]$Root,
        [string]$InstanceName,
        [string]$LaunchId
    )

    $paths = Get-EzVmSshPaths -Root $Root -InstanceName $InstanceName
    [void][IO.Directory]::CreateDirectory($paths.KnownHostsDirectory)
    $candidate = Join-Path $paths.KnownHostsDirectory ('.' + $InstanceName + '.' + $LaunchId + '.candidate')
    Write-EzVmSshTextAtomically -Path $candidate -Content ''
    return [pscustomobject][ordered]@{
        Candidate = [IO.Path]::GetFullPath($candidate)
        Managed = $paths.InstanceKnownHosts
    }
}

function Assert-EzVmCandidateKnownHostsEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateRange(1024, 65535)][int]$Port
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'SSH did not create the launch-local host-key candidate.'
    }
    $lines = @([IO.File]::ReadAllLines($Path) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not $_.TrimStart().StartsWith('#') })
    if ($lines.Count -ne 1) {
        throw 'Launch-local SSH host-key candidate must contain exactly one managed Ed25519 entry.'
    }
    $entry = Get-EzVmKnownHostKeyMaterial -Line $lines[0]
    $expectedHost = '[127.0.0.1]:' + $Port
    if ($entry.Host -cne $expectedHost) {
        throw "Launch-local SSH host-key candidate belongs to '$($entry.Host)', expected '$expectedHost'."
    }
    return $entry
}

function New-EzVmCandidateKnownHosts {
    param(
        [string]$Root,
        [string]$InstanceName,
        [string]$LaunchId,
        [ValidateRange(1024, 65535)][int]$Port,
        [Parameter(Mandatory = $true)][string]$ScannedLine
    )

    $paths = Get-EzVmSshPaths -Root $Root -InstanceName $InstanceName
    [void][IO.Directory]::CreateDirectory($paths.KnownHostsDirectory)
    $scanned = Get-EzVmKnownHostKeyMaterial -Line $ScannedLine
    $expectedHost = '[127.0.0.1]:' + $Port
    if ($scanned.Host -cne $expectedHost) {
        throw "Scanned SSH host-key entry belongs to '$($scanned.Host)', expected '$expectedHost'."
    }

    $existingMaterial = $null
    $changed = $false
    if (Test-Path -LiteralPath $paths.InstanceKnownHosts -PathType Leaf) {
        $existingLines = @([IO.File]::ReadAllLines($paths.InstanceKnownHosts) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not $_.TrimStart().StartsWith('#') })
        if ($existingLines.Count -ne 1) {
            throw "Managed known-hosts state for instance '$InstanceName' is malformed; refusing to weaken host-key verification."
        }
        $existing = Get-EzVmKnownHostKeyMaterial -Line $existingLines[0]
        $existingMaterial = $existing.Material
        $changed = $existing.Material -cne $scanned.Material
    }

    # A changed key is never trusted merely because keyscan observed it. Keep the
    # existing managed entry untouched and use this launch-local candidate only
    # for the authenticated identity/readiness proof. Promotion happens later.
    $candidate = Join-Path $paths.KnownHostsDirectory ('.' + $InstanceName + '.' + $LaunchId + '.candidate')
    [IO.File]::WriteAllText($candidate, ($ScannedLine.Trim() + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
    return [pscustomobject][ordered]@{
        Candidate = [IO.Path]::GetFullPath($candidate)
        Managed = $paths.InstanceKnownHosts
        Material = $scanned.Material
        ExistingMaterial = $existingMaterial
        Changed = $changed
    }
}

function Assert-EzVmSshAccessState {
    param([Parameter(Mandatory = $true)][object]$Access, [string]$ExpectedName)
    $expected = @('schemaVersion', 'instanceName', 'launchId', 'sshHost', 'sshPort', 'sshUser', 'state', 'cloudInstanceId', 'profile', 'readyAt')
    if ($Access -isnot [pscustomobject]) { throw 'SSH access state must be a JSON object.' }
    $actual = @($Access.PSObject.Properties.Name)
    foreach ($name in $actual) { if ($expected -cnotcontains $name) { throw "SSH access state contains unknown field '$name'." } }
    foreach ($name in $expected) { if ($actual -cnotcontains $name) { throw "SSH access state is missing required field '$name'." } }
    if ($Access.schemaVersion -ne 1) { throw 'SSH access state schemaVersion must be integer 1.' }
    if ($Access.instanceName -cne $ExpectedName) { throw 'SSH access state belongs to a different instance.' }
    if ($Access.launchId -isnot [string] -or $Access.launchId -cnotmatch '^[a-f0-9]{32}$') { throw 'SSH access launchId is invalid.' }
    if ($Access.sshHost -cne '127.0.0.1') { throw 'SSH access must bind exactly to 127.0.0.1.' }
    Assert-EzVmRuntimeInteger -Value $Access.sshPort -Description 'SSH access port' -Minimum 1024 -Maximum 65535
    if ($Access.sshUser -cne 'coder') { throw 'SSH access user must be coder for the EZVM-007 profile.' }
    if (@('PROVISIONING', 'READY') -cnotcontains [string]$Access.state) { throw "SSH access state '$($Access.state)' is unsupported." }
    if ($Access.cloudInstanceId -isnot [string] -or [string]::IsNullOrWhiteSpace($Access.cloudInstanceId)) { throw 'SSH access cloudInstanceId is invalid.' }
    if ($Access.profile -isnot [string] -or $Access.profile -cnotmatch '^[a-z0-9][a-z0-9._-]{0,31}$') { throw 'SSH access profile is invalid.' }
    Assert-EzVmRuntimeTimestamp -Value $Access.readyAt -Description 'SSH access readyAt' -AllowEmpty
    if ($Access.state -ceq 'READY' -and [string]::IsNullOrWhiteSpace([string]$Access.readyAt)) {
        throw 'READY SSH access state requires readyAt.'
    }
}

function Write-EzVmSshAccessState {
    param([string]$Root, [string]$InstanceName, [Parameter(Mandatory = $true)][object]$Access)
    Assert-EzVmSshAccessState -Access $Access -ExpectedName $InstanceName
    $path = (Get-EzVmSshPaths -Root $Root -InstanceName $InstanceName).AccessState
    Write-EzVmJson -Path $path -Value $Access -SchemaVersion 1
}

function Get-EzVmSshAccessState {
    [CmdletBinding()]
    param(
        [string]$Root = $script:EzVmDefaultRoot,
        [Parameter(Mandatory = $true)][string]$InstanceName,
        [switch]$RequireReady,
        [scriptblock]$ProcessProvider
    )

    $paths = Get-EzVmSshPaths -Root $Root -InstanceName $InstanceName
    if (-not (Test-Path -LiteralPath $paths.AccessState -PathType Leaf)) {
        throw "Instance '$InstanceName' has no SSH access state. Start it through the EZVM-007 start path first."
    }
    $access = Read-EzVmJson -Path $paths.AccessState -SchemaVersion 1
    Assert-EzVmSshAccessState -Access $access -ExpectedName $InstanceName
    $runtime = Get-EzVmRuntimeStateFile -Root $Root -InstanceName $InstanceName
    if ($null -eq $runtime -or $runtime.launchId -cne $access.launchId) {
        throw "SSH access state for instance '$InstanceName' is stale relative to the current QEMU launch."
    }
    $status = Get-EzVmInstanceStatus -Root $Root -InstanceName $InstanceName -ProcessProvider $ProcessProvider
    if ($status.state -cne 'RUNNING') {
        throw "Instance '$InstanceName' is not safely RUNNING; current lifecycle state is '$($status.state)'."
    }
    if ($RequireReady -and $access.state -cne 'READY') {
        throw "Instance '$InstanceName' has not reached authenticated SSH READY state."
    }
    return $access
}

function Test-EzVmTcpEndpoint {
    param(
        [string]$HostAddress = '127.0.0.1',
        [Parameter(Mandatory = $true)][ValidateRange(1024, 65535)][int]$Port,
        [ValidateRange(1, 5000)][int]$TimeoutMilliseconds = 250
    )

    $client = New-Object Net.Sockets.TcpClient
    $wait = $null
    try {
        $async = $client.BeginConnect($HostAddress, $Port, $null, $null)
        $wait = $async.AsyncWaitHandle
        if (-not $wait.WaitOne($TimeoutMilliseconds)) { return $false }
        $client.EndConnect($async)
        return $client.Connected
    }
    catch { return $false }
    finally {
        if ($null -ne $wait) { $wait.Dispose() }
        $client.Dispose()
    }
}

function ConvertFrom-EzVmReadinessProbe {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$StdOut = '',
        [Parameter(Mandatory = $true)][string]$ExpectedInstanceName,
        [Parameter(Mandatory = $true)][string]$ExpectedBaseId,
        [Parameter(Mandatory = $true)][string]$ExpectedProfile,
        [Parameter(Mandatory = $true)][string]$ExpectedCloudInstanceId
    )

    $identityEncoded = $null
    $cloudEncoded = $null
    $marker = $null
    foreach ($line in @($StdOut -split '\r?\n')) {
        if ($line.StartsWith('EZVM_IDENTITY_B64=', [StringComparison]::Ordinal)) { $identityEncoded = $line.Substring(18) }
        elseif ($line.StartsWith('EZVM_CLOUD_B64=', [StringComparison]::Ordinal)) { $cloudEncoded = $line.Substring(15) }
        elseif ($line.StartsWith('EZVM_READY=', [StringComparison]::Ordinal)) { $marker = $line.Substring(11) }
    }

    $identity = $null
    if (-not [string]::IsNullOrWhiteSpace($identityEncoded)) {
        try {
            $identityJson = (New-Object Text.UTF8Encoding($false, $true)).GetString([Convert]::FromBase64String($identityEncoded))
            $identity = $identityJson | ConvertFrom-Json -ErrorAction Stop
        }
        catch { throw "Authenticated guest returned malformed ezvm identity evidence: $($_.Exception.Message)" }

        foreach ($field in @('schemaVersion', 'instanceName', 'baseId', 'profile', 'cloudInstanceId')) {
            if (@($identity.PSObject.Properties.Name) -cnotcontains $field) {
                throw "Authenticated guest identity is missing '$field'."
            }
        }
        if ($identity.schemaVersion -ne 1 -or
            [string]$identity.instanceName -cne $ExpectedInstanceName -or
            [string]$identity.baseId -cne $ExpectedBaseId -or
            [string]$identity.profile -cne $ExpectedProfile -or
            [string]$identity.cloudInstanceId -cne $ExpectedCloudInstanceId) {
            throw "Authenticated guest identity mismatch for requested instance '$ExpectedInstanceName'. Refusing READY."
        }
    }

    $cloudStatus = ''
    if (-not [string]::IsNullOrWhiteSpace($cloudEncoded)) {
        try { $cloudStatus = (New-Object Text.UTF8Encoding($false, $true)).GetString([Convert]::FromBase64String($cloudEncoded)).Trim() }
        catch { throw 'Authenticated guest returned malformed cloud-init status evidence.' }
    }
    if ($cloudStatus -match '(?im)^status:\s*error\b') {
        throw "cloud-init reports failed provisioning for instance '$ExpectedInstanceName'. Inspect guest cloud-init logs before retrying."
    }

    $cloudDone = $cloudStatus -match '(?im)^status:\s*done\b'
    $markerReady = $marker -ceq '1'
    return [pscustomobject][ordered]@{
        IdentityPresent = $null -ne $identity
        CloudStatus = $cloudStatus
        CloudDone = $cloudDone
        MarkerReady = $markerReady
        Ready = ($null -ne $identity -and $cloudDone -and $markerReady)
        Identity = $identity
    }
}

function Get-EzVmReadinessRemoteScript {
    return 'identity_b64="$(base64 -w0 /etc/ezvm/identity.json 2>/dev/null || true)"; cloud_text="$(cloud-init status 2>/dev/null || true)"; cloud_b64="$(printf %s "$cloud_text" | base64 -w0)"; ready=0; test -f /var/lib/ezvm/ready.json && ready=1; printf "EZVM_IDENTITY_B64=%s\nEZVM_CLOUD_B64=%s\nEZVM_READY=%s\n" "$identity_b64" "$cloud_b64" "$ready"'
}

function Wait-EzVmSshReady {
    [CmdletBinding()]
    param(
        [string]$Root = $script:EzVmDefaultRoot,
        [Parameter(Mandatory = $true)][string]$InstanceName,
        [Parameter(Mandatory = $true)][object]$Intent,
        [Parameter(Mandatory = $true)][object]$Access,
        [Parameter(Mandatory = $true)][object]$Identity,
        [Parameter(Mandatory = $true)][object]$Tooling,
        [AllowNull()][object]$SeedServer = $null,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 60,
        [scriptblock]$PortProbe,
        [scriptblock]$HostKeyScanner,
        [scriptblock]$SshRunner,
        [scriptblock]$SleepProvider
    )

    Assert-EzVmSshAccessState -Access $Access -ExpectedName $InstanceName
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $candidate = $null
    $candidateAcceptNew = $false
    $lastError = 'forwarded SSH port has not become reachable'
    $authenticated = $false
    try {
        while ([DateTime]::UtcNow -lt $deadline) {
            if ($null -ne $SeedServer) {
                try { $null = Invoke-EzVmSeedServerPending -Server $SeedServer -MaxRequests 8 }
                catch { throw "Instance seed transport failed before readiness: $($_.Exception.Message)" }
            }

            $portReady = if ($null -ne $PortProbe) {
                [bool](& $PortProbe '127.0.0.1' ([int]$Access.sshPort))
            } else {
                Test-EzVmTcpEndpoint -Port ([int]$Access.sshPort) -TimeoutMilliseconds 250
            }
            if (-not $portReady) {
                if ($null -ne $SleepProvider) { & $SleepProvider 100 } else { Start-Sleep -Milliseconds 100 }
                continue
            }

            if ($null -eq $candidate) {
                try {
                    if ($null -ne $HostKeyScanner) {
                        $remaining = [Math]::Max(1, [Math]::Min(5, [int][Math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalSeconds)))
                        $line = & $HostKeyScanner ([int]$Access.sshPort) $remaining
                        $candidate = New-EzVmCandidateKnownHosts -Root $Root -InstanceName $InstanceName -LaunchId ([string]$Access.launchId) -Port ([int]$Access.sshPort) -ScannedLine ([string]$line)
                        $candidateAcceptNew = $false
                    }
                    else {
                        $candidate = New-EzVmEmptyCandidateKnownHosts -Root $Root -InstanceName $InstanceName -LaunchId ([string]$Access.launchId)
                        $candidateAcceptNew = $true
                    }
                }
                catch {
                    if ($_.Exception.Message -match 'malformed.*known-hosts|belongs to') { throw }
                    $lastError = $_.Exception.Message
                    if ($null -ne $SleepProvider) { & $SleepProvider 100 } else { Start-Sleep -Milliseconds 100 }
                    continue
                }
            }

            # TCG guests can take materially longer than five seconds for the
            # SSH key exchange plus a remote shell invocation even after TCP 22
            # is reachable. Keep each attempt bounded, but give a healthy slow
            # guest enough budget to prove identity instead of repeatedly killing
            # the client and consuming the entire outer readiness deadline.
            $remainingSeconds = [Math]::Max(1, [Math]::Min(30, [int][Math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalSeconds)))
            $connectTimeoutSeconds = [Math]::Max(1, [Math]::Min(15, $remainingSeconds))
            $arguments = New-EzVmSshCommandArguments -PrivateKey $Identity.PrivateKey -KnownHosts $candidate.Candidate -Port ([int]$Access.sshPort) -User ([string]$Access.sshUser) -Batch -RemoteCommand @('sh', '-lc', (Get-EzVmReadinessRemoteScript)) -AcceptNewHostKey:$candidateAcceptNew -ConnectTimeoutSeconds $connectTimeoutSeconds
            try {
                $result = if ($null -ne $SshRunner) {
                    & $SshRunner $Tooling.Ssh $arguments $remainingSeconds
                } else {
                    Invoke-EzVmProcess -FilePath $Tooling.Ssh -ArgumentList $arguments -TimeoutSeconds $remainingSeconds
                }
                if ($null -eq $result) { throw 'SSH readiness runner returned no result.' }
                if ([int]$result.ExitCode -eq 0) {
                    $null = Assert-EzVmCandidateKnownHostsEntry -Path $candidate.Candidate -Port ([int]$Access.sshPort)
                    $authenticated = $true
                    $probe = ConvertFrom-EzVmReadinessProbe -StdOut ([string]$result.StdOut) -ExpectedInstanceName $InstanceName -ExpectedBaseId ([string]$Intent.baseId) -ExpectedProfile ([string]$Access.profile) -ExpectedCloudInstanceId ([string]$Access.cloudInstanceId)
                    if ($probe.Ready) {
                        Write-EzVmSshTextAtomically -Path $candidate.Managed -Content ([IO.File]::ReadAllText($candidate.Candidate))
                        $Access.state = 'READY'
                        $Access.readyAt = [DateTime]::UtcNow.ToString('o')
                        Write-EzVmSshAccessState -Root $Root -InstanceName $InstanceName -Access $Access
                        return $Access
                    }
                    $lastError = "authenticated SSH succeeded but cloud-init/identity marker is not READY (cloud='$($probe.CloudStatus)', marker=$($probe.MarkerReady))."
                }
                elseif ([int]$result.ExitCode -eq 255) {
                    $lastError = "SSH authentication/transport is not ready: $([string]$result.StdErr)"
                }
                else {
                    throw "Authenticated SSH readiness probe exited unexpectedly with code $($result.ExitCode): $([string]$result.StdErr)"
                }
            }
            catch {
                if ($authenticated -or $_.Exception.Message -match 'identity mismatch|cloud-init reports failed|readiness probe exited unexpectedly') { throw }
                $lastError = $_.Exception.Message
            }

            if ($null -ne $SleepProvider) { & $SleepProvider 100 } else { Start-Sleep -Milliseconds 100 }
        }
        throw "Instance '$InstanceName' did not reach authenticated SSH READY within $TimeoutSeconds seconds. Last readiness evidence: $lastError"
    }
    finally {
        if ($null -ne $candidate -and (Test-Path -LiteralPath $candidate.Candidate)) {
            Remove-Item -LiteralPath $candidate.Candidate -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-EzVmSeedServerLifetimeSeconds {
    [CmdletBinding()]
    param([ValidateRange(1, 3600)][int]$ReadyTimeoutSeconds)

    # The seed transport is subordinate to the enclosing READY deadline. Give it
    # a bounded grace period so its own deadline can never pre-empt and mask the
    # parent readiness timeout/evidence due to scheduler or polling jitter.
    return [int]$ReadyTimeoutSeconds + 30
}

function Start-EzVmReadyInstance {
    [CmdletBinding()]
    param(
        [string]$Root = $script:EzVmDefaultRoot,
        [Parameter(Mandatory = $true)][string]$InstanceName,
        [ValidateSet('whpx', 'tcg')][string]$Accelerator = 'whpx',
        [ValidateRange(1, 3600)][int]$ReadyTimeoutSeconds = 60,
        [scriptblock]$QemuImgRunner,
        [scriptblock]$QemuStatusProvider,
        [scriptblock]$ProcessProvider,
        [scriptblock]$ProcessLauncher,
        [scriptblock]$QmpInvoker,
        [scriptblock]$PortProbe,
        [scriptblock]$HostKeyScanner,
        [scriptblock]$SshRunner,
        [scriptblock]$SleepProvider,
        [AllowNull()][object]$Tooling = $null,
        [AllowNull()][object]$ControllerIdentity = $null
    )

    Assert-EzVmStorageInstanceName -Name $InstanceName
    $Tooling = Assert-EzVmOpenSshTools -Tooling $Tooling
    if ($null -eq $ControllerIdentity) {
        $ControllerIdentity = Get-EzVmControllerSshIdentity -Root $Root -Tooling $Tooling
    }
    $intent = Get-EzVmInstanceIntent -Root $Root -InstanceName $InstanceName
    $profile = Get-EzVmIntentProfileName -Root $Root -Intent $intent
    $seed = New-EzVmInstanceSeedData -Root $Root -InstanceName $InstanceName -Intent $intent -ControllerPublicKey $ControllerIdentity.PublicKeyText -Profile $profile
    $deadline = [DateTime]::UtcNow.AddSeconds($ReadyTimeoutSeconds)
    $seedLifetimeSeconds = Get-EzVmSeedServerLifetimeSeconds -ReadyTimeoutSeconds $ReadyTimeoutSeconds
    $seedServer = Start-EzVmSeedServer -UserData $seed.UserData -MetaData $seed.MetaData -TimeoutSeconds $seedLifetimeSeconds
    $allocationLock = $null
    try {
        $allocationLock = Enter-EzVmSshAllocationLock -Root $Root
        $sshPort = Assert-EzVmInstanceSshPortReservation -Root $Root -Intent $intent -PortProbe $PortProbe
        $remaining = [Math]::Max(1, [int][Math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalSeconds))
        $started = Start-EzVmInstance -Root $Root -InstanceName $InstanceName -Accelerator $Accelerator -StartupTimeoutSeconds $remaining -QemuImgRunner $QemuImgRunner -QemuStatusProvider $QemuStatusProvider -ProcessProvider $ProcessProvider -ProcessLauncher $ProcessLauncher -QmpInvoker $QmpInvoker -SshPort $sshPort -SeedHostPort ([int]$seedServer.Port) -SeedGuestAddress '10.0.2.100' -SeedGuestPort 8000
        $allocationLock.Dispose()
        $allocationLock = $null

        $runtime = Get-EzVmRuntimeStateFile -Root $Root -InstanceName $InstanceName
        $access = [pscustomobject][ordered]@{
            schemaVersion = 1
            instanceName = $InstanceName
            launchId = [string]$runtime.launchId
            sshHost = '127.0.0.1'
            sshPort = [int]$sshPort
            sshUser = 'coder'
            state = 'PROVISIONING'
            cloudInstanceId = $seed.CloudInstanceId
            profile = $profile
            readyAt = ''
        }
        Write-EzVmSshAccessState -Root $Root -InstanceName $InstanceName -Access $access
        $remaining = [int][Math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalSeconds)
        if ($remaining -lt 1) {
            throw "Instance '$InstanceName' reached QEMU RUNNING but exhausted its $ReadyTimeoutSeconds second total readiness timeout before SSH qualification."
        }
        $ready = Wait-EzVmSshReady -Root $Root -InstanceName $InstanceName -Intent $intent -Access $access -Identity $ControllerIdentity -Tooling $Tooling -SeedServer $seedServer -TimeoutSeconds $remaining -PortProbe $PortProbe -HostKeyScanner $HostKeyScanner -SshRunner $SshRunner -SleepProvider $SleepProvider
        return [pscustomobject][ordered]@{
            name = $InstanceName
            state = 'READY'
            pid = [int]$started.pid
            accelerator = $Accelerator
            sshHost = '127.0.0.1'
            sshPort = [int]$ready.sshPort
            sshUser = [string]$ready.sshUser
            readyAt = [string]$ready.readyAt
            serialLog = [string]$started.serialLog
            qemuLog = [string]$started.qemuLog
        }
    }
    finally {
        if ($null -ne $allocationLock) { try { $allocationLock.Dispose() } catch { } }
        if ($null -ne $seedServer) { try { Stop-EzVmSeedServer -Server $seedServer } catch { } }
    }
}

function Resolve-EzVmExecProcessResult {
    param([Parameter(Mandatory = $true)][object]$Result)
    if ($null -eq $Result -or $null -eq $Result.ExitCode) { throw 'SSH command runner returned no exit status.' }
    if ([int]$Result.ExitCode -eq 255) {
        throw "SSH transport/authentication failed: $([string]$Result.StdErr)"
    }
    return [pscustomobject][ordered]@{
        exitCode = [int]$Result.ExitCode
        stdout = [string]$Result.StdOut
        stderr = [string]$Result.StdErr
    }
}

function Invoke-EzVmExec {
    [CmdletBinding()]
    param(
        [string]$Root = $script:EzVmDefaultRoot,
        [Parameter(Mandatory = $true)][string]$InstanceName,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Command,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 60,
        [scriptblock]$ProcessProvider,
        [scriptblock]$SshRunner
    )
    if ($Command.Count -eq 0) { throw 'exec requires at least one command token after --.' }
    $access = Get-EzVmSshAccessState -Root $Root -InstanceName $InstanceName -RequireReady -ProcessProvider $ProcessProvider
    $tooling = Assert-EzVmOpenSshTools
    $identity = Get-EzVmControllerSshIdentity -Root $Root -Tooling $tooling
    $knownHosts = (Get-EzVmSshPaths -Root $Root -InstanceName $InstanceName).InstanceKnownHosts
    $arguments = New-EzVmSshCommandArguments -PrivateKey $identity.PrivateKey -KnownHosts $knownHosts -Port ([int]$access.sshPort) -User ([string]$access.sshUser) -Batch -RemoteCommand $Command
    $result = if ($null -ne $SshRunner) {
        & $SshRunner $tooling.Ssh $arguments $TimeoutSeconds
    } else {
        Invoke-EzVmProcess -FilePath $tooling.Ssh -ArgumentList $arguments -TimeoutSeconds $TimeoutSeconds
    }
    $resolved = Resolve-EzVmExecProcessResult -Result $result
    return [pscustomobject][ordered]@{
        name = $InstanceName
        exitCode = $resolved.exitCode
        stdout = $resolved.stdout
        stderr = $resolved.stderr
    }
}

function Invoke-EzVmInteractiveNative {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList
    )
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Resolve-EzVmProcessFileSystemPath -Path $FilePath
    $start.UseShellExecute = $false
    if ($null -ne $start.PSObject.Properties['ArgumentList']) {
        foreach ($argument in $ArgumentList) { $start.ArgumentList.Add($argument) }
    }
    else {
        $escaped = New-Object 'System.Collections.Generic.List[string]'
        foreach ($argument in $ArgumentList) { $escaped.Add((ConvertTo-EzVmWindowsArgument -Argument $argument)) }
        $start.Arguments = [string]::Join(' ', $escaped.ToArray())
    }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'The operating system did not create the SSH client process.' }
        $process.WaitForExit()
        return [int]$process.ExitCode
    }
    finally { $process.Dispose() }
}

function Invoke-EzVmSsh {
    [CmdletBinding()]
    param(
        [string]$Root = $script:EzVmDefaultRoot,
        [Parameter(Mandatory = $true)][string]$InstanceName,
        [scriptblock]$ProcessProvider
    )
    $access = Get-EzVmSshAccessState -Root $Root -InstanceName $InstanceName -RequireReady -ProcessProvider $ProcessProvider
    $tooling = Assert-EzVmOpenSshTools
    $identity = Get-EzVmControllerSshIdentity -Root $Root -Tooling $tooling
    $knownHosts = (Get-EzVmSshPaths -Root $Root -InstanceName $InstanceName).InstanceKnownHosts
    $arguments = New-EzVmSshCommandArguments -PrivateKey $identity.PrivateKey -KnownHosts $knownHosts -Port ([int]$access.sshPort) -User ([string]$access.sshUser)
    return Invoke-EzVmInteractiveNative -FilePath $tooling.Ssh -ArgumentList $arguments
}

function Invoke-EzVmCopyToGuest {
    [CmdletBinding()]
    param(
        [string]$Root = $script:EzVmDefaultRoot,
        [Parameter(Mandatory = $true)][string]$InstanceName,
        [Parameter(Mandatory = $true)][string]$HostPath,
        [Parameter(Mandatory = $true)][string]$GuestPath,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 60,
        [scriptblock]$ProcessProvider,
        [scriptblock]$ScpRunner
    )
    $fullHostPath = [IO.Path]::GetFullPath($HostPath)
    if (-not (Test-Path -LiteralPath $fullHostPath -PathType Leaf)) {
        throw "Host source file '$fullHostPath' does not exist; copy-to transfers one file."
    }
    $access = Get-EzVmSshAccessState -Root $Root -InstanceName $InstanceName -RequireReady -ProcessProvider $ProcessProvider
    $tooling = Assert-EzVmOpenSshTools
    $identity = Get-EzVmControllerSshIdentity -Root $Root -Tooling $tooling
    $knownHosts = (Get-EzVmSshPaths -Root $Root -InstanceName $InstanceName).InstanceKnownHosts
    $remote = [string]$access.sshUser + '@127.0.0.1:' + $GuestPath
    $arguments = New-EzVmScpCommandArguments -PrivateKey $identity.PrivateKey -KnownHosts $knownHosts -Port ([int]$access.sshPort) -Source $fullHostPath -Destination $remote
    $result = if ($null -ne $ScpRunner) { & $ScpRunner $tooling.Scp $arguments $TimeoutSeconds } else { Invoke-EzVmProcess -FilePath $tooling.Scp -ArgumentList $arguments -TimeoutSeconds $TimeoutSeconds }
    if ([int]$result.ExitCode -ne 0) { throw "copy-to failed with scp exit code $($result.ExitCode): $([string]$result.StdErr)" }
    return [pscustomobject][ordered]@{ name = $InstanceName; direction = 'host-to-guest'; hostPath = $fullHostPath; guestPath = $GuestPath }
}

function Invoke-EzVmCopyFromGuest {
    [CmdletBinding()]
    param(
        [string]$Root = $script:EzVmDefaultRoot,
        [Parameter(Mandatory = $true)][string]$InstanceName,
        [Parameter(Mandatory = $true)][string]$GuestPath,
        [Parameter(Mandatory = $true)][string]$HostPath,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 60,
        [scriptblock]$ProcessProvider,
        [scriptblock]$ScpRunner
    )
    $fullHostPath = [IO.Path]::GetFullPath($HostPath)
    $parent = [IO.Path]::GetDirectoryName($fullHostPath)
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "Host destination directory '$parent' does not exist."
    }
    $access = Get-EzVmSshAccessState -Root $Root -InstanceName $InstanceName -RequireReady -ProcessProvider $ProcessProvider
    $tooling = Assert-EzVmOpenSshTools
    $identity = Get-EzVmControllerSshIdentity -Root $Root -Tooling $tooling
    $knownHosts = (Get-EzVmSshPaths -Root $Root -InstanceName $InstanceName).InstanceKnownHosts
    $remote = [string]$access.sshUser + '@127.0.0.1:' + $GuestPath
    $arguments = New-EzVmScpCommandArguments -PrivateKey $identity.PrivateKey -KnownHosts $knownHosts -Port ([int]$access.sshPort) -Source $remote -Destination $fullHostPath
    $result = if ($null -ne $ScpRunner) { & $ScpRunner $tooling.Scp $arguments $TimeoutSeconds } else { Invoke-EzVmProcess -FilePath $tooling.Scp -ArgumentList $arguments -TimeoutSeconds $TimeoutSeconds }
    if ([int]$result.ExitCode -ne 0) { throw "copy-from failed with scp exit code $($result.ExitCode): $([string]$result.StdErr)" }
    return [pscustomobject][ordered]@{ name = $InstanceName; direction = 'guest-to-host'; guestPath = $GuestPath; hostPath = $fullHostPath }
}
