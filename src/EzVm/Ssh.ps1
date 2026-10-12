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

function Get-EzVmGuestCloudInstanceId {
    param([Parameter(Mandatory = $true)][object]$Intent)
    $hash = Get-EzVmSshSha256Hex -Text ([string]$Intent.name + '|' + [string]$Intent.baseId + '|' + [string]$Intent.createdAt)
    return 'ezvm-' + ([string]$Intent.name).ToLowerInvariant() + '-' + $hash.Substring(0, 12)
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
    # Comments are not key material and can accidentally contain host paths or
    # credentials. Only the algorithm and public-key bytes enter the guest seed.
    $ControllerPublicKey = [string]::Join(' ', @($ControllerPublicKey -split ' ' | Select-Object -First 2))
    $codingProfile = Get-EzVmCodingProfile -Root $Root -Name ([string]$Intent.provisioningProfile) -Version ([int]$Intent.provisioningVersion)
    if ([string]::IsNullOrWhiteSpace($Profile)) {
        $Profile = Get-EzVmIntentProfileName -Root $Root -Intent $Intent
    }
    if ($Profile -cnotmatch '^[a-z0-9][a-z0-9._-]{0,31}$' -or $Profile -cne [string]$Intent.profile) {
        throw "Instance resource profile marker '$Profile' does not match durable intent."
    }

    $hostname = Get-EzVmGuestHostname -InstanceName $InstanceName
    $cloudInstanceId = Get-EzVmGuestCloudInstanceId -Intent $Intent
    $identity = [pscustomobject][ordered]@{
        schemaVersion = 2
        instanceName = $InstanceName
        baseId = [string]$Intent.baseId
        profile = $Profile
        cloudInstanceId = $cloudInstanceId
        provisioningProfile = [string]$codingProfile.Name
        provisioningVersion = [int]$codingProfile.Version
        provisioningDigest = [string]$codingProfile.Digest
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
        '    homedir: /home/coder',
        '    groups: [adm, sudo]',
        "    sudo: ['ALL=(ALL:ALL) NOPASSWD:ALL']",
        '    shell: /bin/bash',
        '    lock_passwd: true',
        '    ssh_authorized_keys:',
        ('      - ' + (ConvertTo-EzVmYamlSingleQuoted $ControllerPublicKey)),
        'write_files:',
        '  - path: /etc/ssh/sshd_config.d/00-ezvm-coding.conf',
        '    owner: root:root',
        "    permissions: '0644'",
        '    content: |',
        '      PasswordAuthentication no',
        '      KbdInteractiveAuthentication no',
        '      PubkeyAuthentication yes',
        '      PermitRootLogin no',
        '  - path: /etc/ezvm/identity.json',
        '    owner: root:root',
        "    permissions: '0644'",
        '    content: |',
        ('      ' + $identityJson),
        '  - path: /etc/ezvm/profile.json',
        '    owner: root:root',
        "    permissions: '0644'",
        '    encoding: b64',
        ('    content: ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$codingProfile.ManifestJson))),
        '  - path: /usr/local/sbin/ezvm-coding-profile',
        '    owner: root:root',
        "    permissions: '0755'",
        '    encoding: b64',
        ('    content: ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$codingProfile.Script))),
        '  - path: /usr/local/sbin/ezvm-instance-finalize',
        '    owner: root:root',
        "    permissions: '0755'",
        '    content: |',
        '      #!/bin/sh',
        '      set -eu',
        '      export PATH=/usr/sbin:/usr/bin:/sbin:/bin',
        '      install -d -m 0755 /var/lib/ezvm',
        '      rm -f /var/lib/ezvm/ready.json',
        '      if cloud-init status --wait >/var/log/ezvm-cloud-init-status.log 2>&1; then',
        '        if ! /usr/sbin/sshd -t || ! systemctl reload ssh; then',
        "          printf '%s\n' 'SSH policy activation failed' > /var/lib/ezvm/provisioning-failed",
        '          exit 1',
        '        fi',
        '        exec /usr/local/sbin/ezvm-coding-profile provision',
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
    # Guest scripts must use Unix newlines even when generated on Windows.
    $userData = [string]::Join("`n", $userDataLines) + "`n"
    $metaData = [string]::Join("`n", $metaDataLines) + "`n"
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
        CodingProfile = $codingProfile
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
    $expected = @('schemaVersion', 'instanceName', 'baseId', 'launchId', 'sshHost', 'sshPort', 'sshUser', 'state', 'cloudInstanceId', 'profile', 'provisioningProfile', 'provisioningVersion', 'provisioningDigest', 'readyAt')
    if ($Access -isnot [pscustomobject]) { throw 'SSH access state must be a JSON object.' }
    $actual = @($Access.PSObject.Properties.Name)
    foreach ($name in $actual) { if ($expected -cnotcontains $name) { throw "SSH access state contains unknown field '$name'." } }
    foreach ($name in $expected) { if ($actual -cnotcontains $name) { throw "SSH access state is missing required field '$name'." } }
    Assert-EzVmRuntimeInteger -Value $Access.schemaVersion -Description 'SSH access state schemaVersion; stop and restart to regenerate legacy access state' -Minimum 2 -Maximum 2
    if ($Access.instanceName -cne $ExpectedName) { throw 'SSH access state belongs to a different instance.' }
    if ($Access.baseId -isnot [string] -or $Access.baseId -cnotmatch '^base-[a-f0-9]{64}$') { throw 'SSH access baseId is invalid.' }
    if ($Access.launchId -isnot [string] -or $Access.launchId -cnotmatch '^[a-f0-9]{32}$') { throw 'SSH access launchId is invalid.' }
    if ($Access.sshHost -cne '127.0.0.1') { throw 'SSH access must bind exactly to 127.0.0.1.' }
    Assert-EzVmRuntimeInteger -Value $Access.sshPort -Description 'SSH access port' -Minimum 1024 -Maximum 65535
    if ($Access.sshUser -cne 'coder') { throw 'SSH access user must be coder for the coding-default profile.' }
    if (@('PROVISIONING', 'READY') -cnotcontains [string]$Access.state) { throw "SSH access state '$($Access.state)' is unsupported." }
    if ($Access.cloudInstanceId -isnot [string] -or [string]::IsNullOrWhiteSpace($Access.cloudInstanceId)) { throw 'SSH access cloudInstanceId is invalid.' }
    if ($Access.profile -isnot [string] -or $Access.profile -cnotmatch '^[a-z0-9][a-z0-9._-]{0,31}$') { throw 'SSH access profile is invalid.' }
    if ($Access.provisioningProfile -isnot [string] -or $Access.provisioningProfile -cne 'coding-default') { throw 'SSH access provisioningProfile must be coding-default.' }
    Assert-EzVmRuntimeInteger -Value $Access.provisioningVersion -Description 'SSH access provisioningVersion' -Minimum 1 -Maximum 1
    if ($Access.provisioningDigest -isnot [string] -or $Access.provisioningDigest -cnotmatch '^[a-f0-9]{64}$') { throw 'SSH access provisioningDigest must be a SHA256 identity.' }
    Assert-EzVmRuntimeTimestamp -Value $Access.readyAt -Description 'SSH access readyAt' -AllowEmpty
    if ($Access.state -ceq 'READY' -and [string]::IsNullOrWhiteSpace([string]$Access.readyAt)) {
        throw 'READY SSH access state requires readyAt.'
    }
}

function Write-EzVmSshAccessState {
    param([string]$Root, [string]$InstanceName, [Parameter(Mandatory = $true)][object]$Access)
    Assert-EzVmSshAccessState -Access $Access -ExpectedName $InstanceName
    $path = (Get-EzVmSshPaths -Root $Root -InstanceName $InstanceName).AccessState
    Write-EzVmJson -Path $path -Value $Access -SchemaVersion 2
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
        throw "Instance '$InstanceName' has no SSH access state. Start it through the coding-ready start path first."
    }
    $access = Read-EzVmJson -Path $paths.AccessState -SchemaVersion 2
    Assert-EzVmSshAccessState -Access $access -ExpectedName $InstanceName
    $intent = Get-EzVmInstanceIntent -Root $Root -InstanceName $InstanceName
    $codingProfile = Get-EzVmCodingProfile -Root $Root -Name ([string]$intent.provisioningProfile) -Version ([int]$intent.provisioningVersion)
    if ($access.baseId -cne $intent.baseId -or
        $access.cloudInstanceId -cne (Get-EzVmGuestCloudInstanceId -Intent $intent) -or
        $access.profile -cne $intent.profile -or
        [int]$access.sshPort -ne [int]$intent.sshPort -or
        $access.provisioningProfile -cne $codingProfile.Name -or
        [int]$access.provisioningVersion -ne $codingProfile.Version -or
        $access.provisioningDigest -cne $codingProfile.Digest) {
        throw "SSH access profile identity for instance '$InstanceName' no longer matches durable intent and reviewed source. Stop the instance and create a new named instance for the requested profile; do not rewrite an existing overlay's identity."
    }
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
        [Parameter(Mandatory = $true)][string]$ExpectedCloudInstanceId,
        [Parameter(Mandatory = $true)][string]$ExpectedProvisioningProfile,
        [Parameter(Mandatory = $true)][ValidateRange(1, 2147483647)][int]$ExpectedProvisioningVersion,
        [Parameter(Mandatory = $true)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedProvisioningDigest
    )

    if ($StdOut.Length -gt 65536) { throw 'Authenticated guest readiness evidence exceeds its bounded protocol size.' }
    $evidence = @{}
    $expectedFields = @('EZVM_IDENTITY_B64', 'EZVM_CLOUD_B64', 'EZVM_CLOUD_EXIT', 'EZVM_READY_B64', 'EZVM_PROFILE_CHECK', 'EZVM_PROFILE_ERROR_B64')
    foreach ($line in @($StdOut -split '\r?\n')) {
        if ($line.Length -eq 0) { continue }
        $separator = $line.IndexOf('=')
        if ($separator -lt 1) { throw 'Authenticated guest returned malformed readiness protocol evidence.' }
        $key = $line.Substring(0, $separator)
        if ($expectedFields -cnotcontains $key -or $evidence.ContainsKey($key)) {
            throw 'Authenticated guest returned unexpected or duplicate readiness protocol fields.'
        }
        $evidence[$key] = $line.Substring($separator + 1)
    }
    foreach ($key in $expectedFields) {
        if (-not $evidence.ContainsKey($key)) { throw "Authenticated guest readiness evidence is missing '$key'; legacy SSH-only readiness cannot grant coding READY." }
    }
    if (@('pending', 'pass', 'failed') -cnotcontains $evidence['EZVM_PROFILE_CHECK']) { throw 'Authenticated guest returned an invalid coding profile check state.' }

    $documents = @{}
    foreach ($key in @('EZVM_IDENTITY_B64', 'EZVM_READY_B64', 'EZVM_CLOUD_B64', 'EZVM_PROFILE_ERROR_B64')) {
        try {
            $decoded = (New-Object Text.UTF8Encoding($false, $true)).GetString([Convert]::FromBase64String($evidence[$key]))
            if ($decoded.Length -gt 8192) { throw 'decoded field exceeds 8192 characters' }
            $documents[$key] = $decoded
        }
        catch { throw "Authenticated guest returned malformed bounded readiness evidence in '$key'." }
    }
    $identityFields = @('schemaVersion', 'instanceName', 'baseId', 'profile', 'cloudInstanceId', 'provisioningProfile', 'provisioningVersion', 'provisioningDigest')
    $identity = $null
    $readyMarker = $null
    foreach ($key in @('EZVM_IDENTITY_B64', 'EZVM_READY_B64')) {
        if ([string]::IsNullOrWhiteSpace($documents[$key])) { continue }
        $document = ConvertFrom-EzVmJsonText -Text $documents[$key] -SchemaVersion 2 -Description 'Authenticated guest identity/readiness marker'
        $fields = $identityFields
        if ($key -ceq 'EZVM_READY_B64') { $fields = $identityFields + @('provisioningState') }
        Assert-EzVmRuntimeFields -Value $document -Expected $fields -Description 'Authenticated guest identity/readiness marker'
        Assert-EzVmRuntimeInteger -Value $document.provisioningVersion -Description 'Guest provisioningVersion' -Minimum 1 -Maximum 2147483647
        foreach ($pair in @(
            @('instanceName', $ExpectedInstanceName), @('baseId', $ExpectedBaseId),
            @('profile', $ExpectedProfile), @('cloudInstanceId', $ExpectedCloudInstanceId),
            @('provisioningProfile', $ExpectedProvisioningProfile), @('provisioningDigest', $ExpectedProvisioningDigest)
        )) {
            if ($document.($pair[0]) -isnot [string] -or $document.($pair[0]) -cne $pair[1]) {
                throw "Authenticated guest identity mismatch for requested instance '$ExpectedInstanceName' ($($pair[0])). Refusing READY."
            }
        }
        if ([int]$document.provisioningVersion -ne $ExpectedProvisioningVersion) { throw "Authenticated guest identity mismatch for requested coding profile version. Refusing READY." }
        if ($key -ceq 'EZVM_IDENTITY_B64') { $identity = $document }
        else {
            if ($document.provisioningState -isnot [string] -or $document.provisioningState -cne 'complete') {
                throw 'Authenticated coding profile marker does not record complete provisioning. Refusing READY.'
            }
            $readyMarker = $document
        }
    }

    $cloudStatus = $documents['EZVM_CLOUD_B64'].Trim()
    if ($evidence['EZVM_CLOUD_EXIT'] -cne '0' -or $cloudStatus -match '(?im)^status:\s*error\b') {
        throw "cloud-init reports failed provisioning for instance '$ExpectedInstanceName'. Inspect guest cloud-init logs before retrying."
    }
    if ($evidence['EZVM_PROFILE_CHECK'] -ceq 'failed') {
        $detail = $documents['EZVM_PROFILE_ERROR_B64'].Trim()
        if ($detail.Length -gt 2048) { $detail = $detail.Substring(0, 2048) }
        throw "Coding profile validation failed for instance '$ExpectedInstanceName'. Refusing READY. $detail"
    }

    $cloudDone = $cloudStatus -cmatch '^status:\s*done\s*$'
    $markerReady = $null -ne $readyMarker
    $profileReady = $evidence['EZVM_PROFILE_CHECK'] -ceq 'pass'
    return [pscustomobject][ordered]@{
        IdentityPresent = $null -ne $identity
        CloudStatus = $cloudStatus
        CloudDone = $cloudDone
        MarkerReady = $markerReady
        ProfileReady = $profileReady
        Ready = ($null -ne $identity -and $cloudDone -and $markerReady -and $profileReady)
        Identity = $identity
        ReadyMarker = $readyMarker
    }
}

function Get-EzVmReadinessRemoteScript {
    param([Parameter(Mandatory = $true)][ValidatePattern('^[a-f0-9]{64}$')][string]$ProvisioningDigest)
    $script = @'
PATH=/usr/sbin:/usr/bin:/sbin:/bin
LC_ALL=C
export PATH LC_ALL
identity_b64="$(head -c 8193 /etc/ezvm/identity.json 2>/dev/null | base64 -w0)"
cloud_text="$(cloud-init status 2>/dev/null)"
cloud_exit=$?
cloud_b64="$(printf %s "$cloud_text" | base64 -w0)"
ready_b64="$(head -c 8193 /var/lib/ezvm/ready.json 2>/dev/null | base64 -w0)"
profile_check=pending
profile_error=''
if test -f /var/lib/ezvm/provisioning-failed; then
    profile_check=failed
    profile_error="$(head -c 2048 /var/lib/ezvm/provisioning-failed 2>/dev/null)"
elif test "$cloud_exit" -eq 0 && test "$cloud_text" = 'status: done' && test -n "$ready_b64"; then
    actual_digest="$({ printf 'profile.json\000'; cat /etc/ezvm/profile.json; printf '\000provision.sh\000'; cat /usr/local/sbin/ezvm-coding-profile; printf '\000'; } 2>/dev/null | sha256sum)"
    if test "$actual_digest" != '__EZVM_PROFILE_DIGEST__  -'; then
        profile_check=failed
        profile_error='coding profile source digest does not match the reviewed requested version'
    elif profile_error="$(sudo -n -- timeout --signal=TERM --kill-after=5s 110s /usr/local/sbin/ezvm-coding-profile validate 2>&1)"; then
        profile_check=pass
    else
        profile_check=failed
    fi
fi
profile_error_b64="$(printf %s "$profile_error" | head -c 2048 | base64 -w0)"
printf 'EZVM_IDENTITY_B64=%s\nEZVM_CLOUD_B64=%s\nEZVM_CLOUD_EXIT=%s\nEZVM_READY_B64=%s\nEZVM_PROFILE_CHECK=%s\nEZVM_PROFILE_ERROR_B64=%s\n' "$identity_b64" "$cloud_b64" "$cloud_exit" "$ready_b64" "$profile_check" "$profile_error_b64"
'@
    return $script.Replace('__EZVM_PROFILE_DIGEST__', $ProvisioningDigest).Replace(([string][char]13 + [char]10), [string][char]10)
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
        [DateTime]$DeadlineUtc = [DateTime]::MinValue,
        [scriptblock]$PortProbe,
        [scriptblock]$HostKeyScanner,
        [scriptblock]$SshRunner,
        [scriptblock]$SleepProvider
    )

    Assert-EzVmSshAccessState -Access $Access -ExpectedName $InstanceName
    Assert-EzVmInstanceIntent -Intent $Intent -ExpectedName $InstanceName
    $codingProfile = Get-EzVmCodingProfile -Root $Root -Name ([string]$Intent.provisioningProfile) -Version ([int]$Intent.provisioningVersion)
    if ($Access.baseId -cne $Intent.baseId -or $Access.profile -cne $Intent.profile -or
        [int]$Access.sshPort -ne [int]$Intent.sshPort -or
        $Access.cloudInstanceId -cne (Get-EzVmGuestCloudInstanceId -Intent $Intent) -or
        $Access.provisioningProfile -cne $codingProfile.Name -or
        [int]$Access.provisioningVersion -ne $codingProfile.Version -or
        $Access.provisioningDigest -cne $codingProfile.Digest) {
        throw 'SSH readiness access identity does not match the requested instance and coding profile.'
    }
    # Revalidation invalidates cached host READY before any fallible probe. A
    # missing tool or mismatched marker must never leave old access authoritative.
    $Access.state = 'PROVISIONING'
    $Access.readyAt = ''
    Write-EzVmSshAccessState -Root $Root -InstanceName $InstanceName -Access $Access
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    if ($DeadlineUtc -ne [DateTime]::MinValue) {
        if ($DeadlineUtc.Kind -ne [DateTimeKind]::Utc) { throw 'SSH readiness DeadlineUtc must use UTC.' }
        if ($DeadlineUtc -lt $deadline) { $deadline = $DeadlineUtc }
    }
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

            # Completed coding profiles perform a real, bounded venv check.
            # Its budget and SSH negotiation share the original total deadline.
            $remainingSeconds = [int][Math]::Floor(($deadline - [DateTime]::UtcNow).TotalSeconds)
            if ($remainingSeconds -lt 1) { break }
            $remainingSeconds = [Math]::Min(120, $remainingSeconds)
            $connectTimeoutSeconds = [Math]::Max(1, [Math]::Min(15, $remainingSeconds))
            $arguments = New-EzVmSshCommandArguments -PrivateKey $Identity.PrivateKey -KnownHosts $candidate.Candidate -Port ([int]$Access.sshPort) -User ([string]$Access.sshUser) -Batch -RemoteCommand @('sh', '-lc', (Get-EzVmReadinessRemoteScript -ProvisioningDigest $codingProfile.Digest)) -AcceptNewHostKey:$candidateAcceptNew -ConnectTimeoutSeconds $connectTimeoutSeconds
            $authenticated = $false
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
                    $probe = ConvertFrom-EzVmReadinessProbe -StdOut ([string]$result.StdOut) -ExpectedInstanceName $InstanceName -ExpectedBaseId ([string]$Intent.baseId) -ExpectedProfile ([string]$Access.profile) -ExpectedCloudInstanceId ([string]$Access.cloudInstanceId) -ExpectedProvisioningProfile $codingProfile.Name -ExpectedProvisioningVersion $codingProfile.Version -ExpectedProvisioningDigest $codingProfile.Digest
                    if ($probe.Ready) {
                        if ([DateTime]::UtcNow -ge $deadline) { throw "Coding readiness proof exceeded the $TimeoutSeconds second deadline. Refusing READY." }
                        Write-EzVmSshTextAtomically -Path $candidate.Managed -Content ([IO.File]::ReadAllText($candidate.Candidate))
                        $Access.state = 'READY'
                        $Access.readyAt = [DateTime]::UtcNow.ToString('o')
                        Write-EzVmSshAccessState -Root $Root -InstanceName $InstanceName -Access $Access
                        return $Access
                    }
                    $lastError = "authenticated SSH succeeded but coding readiness is incomplete (cloud='$($probe.CloudStatus)', marker=$($probe.MarkerReady), profile=$($probe.ProfileReady))."
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
    $intent = Get-EzVmInstanceIntent -Root $Root -InstanceName $InstanceName
    # Refuse unsupported legacy intent before key creation or any guest launch.
    $null = Get-EzVmCodingProfile -Root $Root -Name ([string]$intent.provisioningProfile) -Version ([int]$intent.provisioningVersion)
    $Tooling = Assert-EzVmOpenSshTools -Tooling $Tooling
    if ($null -eq $ControllerIdentity) {
        $ControllerIdentity = Get-EzVmControllerSshIdentity -Root $Root -Tooling $Tooling
    }
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
            schemaVersion = 2
            instanceName = $InstanceName
            baseId = [string]$intent.baseId
            launchId = [string]$runtime.launchId
            sshHost = '127.0.0.1'
            sshPort = [int]$sshPort
            sshUser = 'coder'
            state = 'PROVISIONING'
            cloudInstanceId = $seed.CloudInstanceId
            profile = $profile
            provisioningProfile = [string]$seed.CodingProfile.Name
            provisioningVersion = [int]$seed.CodingProfile.Version
            provisioningDigest = [string]$seed.CodingProfile.Digest
            readyAt = ''
        }
        Write-EzVmSshAccessState -Root $Root -InstanceName $InstanceName -Access $access
        $remaining = [int][Math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalSeconds)
        if ($remaining -lt 1) {
            throw "Instance '$InstanceName' reached QEMU RUNNING but exhausted its $ReadyTimeoutSeconds second total readiness timeout before SSH qualification."
        }
        $ready = Wait-EzVmSshReady -Root $Root -InstanceName $InstanceName -Intent $intent -Access $access -Identity $ControllerIdentity -Tooling $Tooling -SeedServer $seedServer -TimeoutSeconds $remaining -DeadlineUtc $deadline -PortProbe $PortProbe -HostKeyScanner $HostKeyScanner -SshRunner $SshRunner -SleepProvider $SleepProvider
        return [pscustomobject][ordered]@{
            name = $InstanceName
            state = 'READY'
            pid = [int]$started.pid
            accelerator = $Accelerator
            sshHost = '127.0.0.1'
            sshPort = [int]$ready.sshPort
            sshUser = [string]$ready.sshUser
            provisioningProfile = [string]$ready.provisioningProfile
            provisioningVersion = [int]$ready.provisioningVersion
            provisioningDigest = [string]$ready.provisioningDigest
            workspace = [string]$seed.CodingProfile.Manifest.workspace
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
