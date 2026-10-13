function Set-EzVmPrivateAcl {
    param([Parameter(Mandatory = $true)][string]$Path, [switch]$Directory)
    $full = Assert-EzVmSafePath -Path $Path -Description 'Private permission target'
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = if ($Directory) { New-Object Security.AccessControl.DirectorySecurity } else { New-Object Security.AccessControl.FileSecurity }
    if (-not $Directory) { Assert-EzVmSingleLinkFile -Path $full }
    $acl.SetOwner($sid)
    $acl.SetAccessRuleProtection($true, $false)
    $inheritance = if ($Directory) { [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit' } else { [Security.AccessControl.InheritanceFlags]::None }
    $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid, [Security.AccessControl.FileSystemRights]::FullControl,
        $inheritance, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $full -AclObject $acl -ErrorAction Stop
    $observed = Get-Acl -LiteralPath $full -ErrorAction Stop
    $rules = @($observed.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    if (-not $observed.AreAccessRulesProtected -or $observed.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $sid.Value -or
        $rules.Count -ne 1 -or $rules[0].IdentityReference.Value -cne $sid.Value -or
        $rules[0].AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
        $rules[0].FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl) {
        throw 'Private Windows ACL verification failed; no broad or inherited access is accepted.'
    }
}

function Protect-EzVmControllerPrivateKey {
    param([Parameter(Mandatory = $true)][string]$Path, [AllowNull()][object]$ProcessRunner = $null)
    $null = Assert-EzVmSafePath -Path $Path -Description 'Controller private key'
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return }
    try {
        Assert-EzVmSingleLinkFile -Path $Path
        # Retain the bounded native boundary used by existing ACL failure tests.
        # Exact replacement below also removes pre-existing explicit broad ACEs.
        $systemRoot = [Environment]::GetEnvironmentVariable('SystemRoot')
        if ([string]::IsNullOrWhiteSpace($systemRoot)) { throw 'SystemRoot is unavailable.' }
        $icacls = Join-Path $systemRoot 'System32\icacls.exe'
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $arguments = @([IO.Path]::GetFullPath($Path), '/inheritance:r', '/grant:r', ('*' + $sid + ':(F)'))
        $result = if ($null -ne $ProcessRunner) { & $ProcessRunner $icacls $arguments 15 } else { Invoke-EzVmProcess -FilePath $icacls -ArgumentList $arguments -TimeoutSeconds 15 }
        if ($null -eq $result -or [int]$result.ExitCode -ne 0) { throw 'Native ACL restriction failed.' }
        Set-EzVmPrivateAcl -Path $Path
    }
    catch { throw ('Failed to restrict the ezvm controller private-key ACL. ' + (Protect-EzVmDiagnosticText $_.Exception.Message)) }
}

function Get-EzVmControllerSshIdentity {
    [CmdletBinding()]
    param([string]$Root = $script:EzVmDefaultRoot, [AllowNull()][object]$Tooling = $null, [scriptblock]$ProcessRunner)
    $Tooling = Assert-EzVmOpenSshTools -Tooling $Tooling
    $paths = Get-EzVmSshPaths -Root $Root
    foreach ($path in @($paths.KeysDirectory, $paths.ControllerPrivateKey, $paths.ControllerPublicKey)) {
        $null = Assert-EzVmSafePath -Path $path -Description 'Controller identity'
    }
    $lock = Enter-EzVmSecurityLock -Path (Join-Path (Get-EzVmPaths -Root $Root).Locks 'controller-key.lock')
    $createdThisCall = $false
    $accepted = $false
    try {
        [void][IO.Directory]::CreateDirectory($paths.KeysDirectory)
        Set-EzVmPrivateAcl -Path $paths.KeysDirectory -Directory
        $privateExists = Test-Path -LiteralPath $paths.ControllerPrivateKey -PathType Leaf
        $publicExists = Test-Path -LiteralPath $paths.ControllerPublicKey -PathType Leaf
        if (-not $privateExists -and $publicExists) { throw 'Controller public key exists without its private key. Restore the matching pair; do not replace an identity accidentally.' }
        if (-not $privateExists) {
            $createdThisCall = $true
            $arguments = @('-q', '-t', 'ed25519', '-N', '', '-C', 'ezvm-controller', '-f', $paths.ControllerPrivateKey)
            $result = if ($null -ne $ProcessRunner) { & $ProcessRunner $Tooling.Keygen $arguments 30 } else { Invoke-EzVmProcess -FilePath $Tooling.Keygen -ArgumentList $arguments -TimeoutSeconds 30 }
            if ($null -eq $result -or [int]$result.ExitCode -ne 0 -or -not [IO.File]::Exists($paths.ControllerPrivateKey) -or -not [IO.File]::Exists($paths.ControllerPublicKey)) {
                throw 'ssh-keygen could not create both controller key files. Partial files from this invocation are removed.'
            }
        }
        $null = Assert-EzVmSafePath -Path $paths.ControllerPrivateKey -Description 'Controller private key'
        if ((Get-Item -LiteralPath $paths.ControllerPrivateKey -Force).Length -gt 65536) { throw 'Controller key exceeds the supported size bound; preserve it and restore a normal Ed25519 key.' }
        Protect-EzVmControllerPrivateKey -Path $paths.ControllerPrivateKey -ProcessRunner $ProcessRunner
        $arguments = @('-y', '-f', $paths.ControllerPrivateKey)
        $derived = if ($null -ne $ProcessRunner) { & $ProcessRunner $Tooling.Keygen $arguments 30 } else { Invoke-EzVmProcess -FilePath $Tooling.Keygen -ArgumentList $arguments -TimeoutSeconds 30 }
        if ($null -eq $derived -or [int]$derived.ExitCode -ne 0 -or $derived.StdOut.Length -gt 8192 -or
            $derived.StdOut.Trim() -cnotmatch '^ssh-ed25519 [A-Za-z0-9+/]+={0,2}(?: [^\r\n]*)?$') {
            throw 'The controller public key could not be derived from its private key. Restore a usable noninteractive Ed25519 identity.'
        }
        $material = [string]::Join(' ', @($derived.StdOut.Trim() -split ' ' | Select-Object -First 2))
        if (-not (Test-Path -LiteralPath $paths.ControllerPublicKey -PathType Leaf)) {
            Write-EzVmSshTextAtomically -Path $paths.ControllerPublicKey -Content ($material + ' ezvm-controller' + [Environment]::NewLine)
        }
        $publicKey = (Read-EzVmBoundedText -Path $paths.ControllerPublicKey -MaximumBytes 8192).Trim()
        if ($publicKey -cnotmatch '^ssh-ed25519 [A-Za-z0-9+/]+={0,2}(?: [^\r\n]*)?$' -or
            [string]::Join(' ', @($publicKey -split ' ' | Select-Object -First 2)) -cne $material) {
            throw 'Controller public/private key mismatch. Existing files are preserved; restore the matching pair before starting a guest.'
        }
        Assert-EzVmCredentialFreeText -Text $publicKey -Description 'Controller public key'
        $accepted = $true
        return [pscustomobject][ordered]@{ PrivateKey = $paths.ControllerPrivateKey; PublicKey = $paths.ControllerPublicKey; PublicKeyText = $material }
    }
    finally {
        if ($createdThisCall -and -not $accepted) {
            foreach ($path in @($paths.ControllerPrivateKey, $paths.ControllerPublicKey)) {
                try { $null = Assert-EzVmSafePath -Path $path -Description 'New key cleanup'; if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) } } catch { }
            }
        }
        $lock.Dispose()
    }
}
