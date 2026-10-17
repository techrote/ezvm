# Real Windows ACL fixtures. Synthetic bytes only; no account or privilege changes.
$privateAclWindowsSkip = if ($script:EzVmIsWindowsHost) { '' } else { 'Private DACL regression requires a Windows filesystem; the separate hosted standard-user lanes are authoritative.' }

function Set-EzVmTestAclDescriptor {
    param([string]$Path, [object]$Descriptor, [switch]$Directory)
    $item = if ($Directory) { [IO.DirectoryInfo]::new($Path) } else { [IO.FileInfo]::new($Path) }
    if ($PSVersionTable.PSVersion.Major -le 5) { $item.SetAccessControl($Descriptor) }
    else { [IO.FileSystemAclExtensions]::SetAccessControl($item, $Descriptor) }
}

function Assert-EzVmTestPrivateAcl {
    param([string]$Path, [switch]$Directory)
    # Observe the OS descriptor independently of the product's readback path.
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    Assert-EzVmEqual $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value $sid
    Assert-EzVmTrue $acl.AreAccessRulesProtected
    Assert-EzVmEqual $rules.Count 1
    Assert-EzVmEqual $rules[0].IdentityReference.Value $sid
    Assert-EzVmEqual ([string]$rules[0].AccessControlType) 'Allow'
    Assert-EzVmEqual ([string]$rules[0].FileSystemRights) 'FullControl'
    Assert-EzVmTrue (-not $rules[0].IsInherited)
    Assert-EzVmEqual ([string]$rules[0].PropagationFlags) 'None'
    $expectedInheritance = if ($Directory) { 'ContainerInherit, ObjectInherit' } else { 'None' }
    Assert-EzVmEqual ([string]$rules[0].InheritanceFlags) $expectedInheritance
}

function Add-EzVmTestBroadDirectoryAce {
    param([string]$Path, [string]$Sid)
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $identity = [Security.Principal.SecurityIdentifier]::new($Sid)
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl',
        'ContainerInherit, ObjectInherit', 'None', 'Allow'))
    Set-EzVmTestAclDescriptor -Path $Path -Descriptor $acl -Directory
}

Add-EzVmTest -Name 'Private ACL: inherited broad file access is removed and repeated protection preserves bytes' -SkipReason $privateAclWindowsSkip -ScriptBlock {
    $root = New-EzVmTestDirectory -Prefix 'inherited ACL [literal]'
    try {
        Add-EzVmTestBroadDirectoryAce -Path $root -Sid 'S-1-1-0'
        $file = Join-Path $root 'synthetic [private].txt'
        [IO.File]::WriteAllText($file, 'synthetic private bytes; never a credential')
        $before = Get-Acl -LiteralPath $file
        $group = $before.GetGroup([Security.Principal.SecurityIdentifier]).Value
        $rules = @($before.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        Assert-EzVmTrue (@($rules | Where-Object { $_.IdentityReference.Value -ceq 'S-1-1-0' -and $_.IsInherited }).Count -gt 0)
        foreach ($iteration in 1..2) {
            & (Get-Module EzVm) { param($p) Protect-EzVmControllerPrivateKey -Path $p } $file
            Assert-EzVmTestPrivateAcl -Path $file
            Assert-EzVmEqual ([IO.File]::ReadAllText($file)) 'synthetic private bytes; never a credential'
            Assert-EzVmEqual (Get-Acl -LiteralPath $file).GetGroup([Security.Principal.SecurityIdentifier]).Value $group
        }
    }
    finally { Remove-EzVmTestDirectory $root }
}

Add-EzVmTest -Name 'Private ACL: directory broad ACEs are removed and protected reapplication remains private' -SkipReason $privateAclWindowsSkip -ScriptBlock {
    $root = New-EzVmTestDirectory -Prefix 'directory ACL'
    try {
        Add-EzVmTestBroadDirectoryAce -Path $root -Sid 'S-1-1-0'
        $directory = Join-Path $root 'synthetic key directory'
        [void][IO.Directory]::CreateDirectory($directory)
        Add-EzVmTestBroadDirectoryAce -Path $directory -Sid 'S-1-5-11'
        $before = Get-Acl -LiteralPath $directory
        $group = $before.GetGroup([Security.Principal.SecurityIdentifier]).Value
        $rules = @($before.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        Assert-EzVmTrue (@($rules | Where-Object { $_.IdentityReference.Value -ceq 'S-1-1-0' -and $_.IsInherited }).Count -gt 0)
        Assert-EzVmTrue (@($rules | Where-Object { $_.IdentityReference.Value -ceq 'S-1-5-11' -and -not $_.IsInherited }).Count -gt 0)
        foreach ($iteration in 1..2) {
            & (Get-Module EzVm) { param($p) Set-EzVmPrivateAcl -Path $p -Directory } $directory
            Assert-EzVmTestPrivateAcl -Path $directory -Directory
            Assert-EzVmEqual (Get-Acl -LiteralPath $directory).GetGroup([Security.Principal.SecurityIdentifier]).Value $group
        }
        $child = Join-Path $directory 'new synthetic child.txt'
        [IO.File]::WriteAllText($child, 'fixture')
        $childAcl = Get-Acl -LiteralPath $child
        $childRules = @($childAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        Assert-EzVmEqual $childRules.Count 1
        Assert-EzVmTrue $childRules[0].IsInherited
        Assert-EzVmEqual $childRules[0].IdentityReference.Value ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
        Assert-EzVmEqual ([string]$childRules[0].FileSystemRights) 'FullControl'
    }
    finally { Remove-EzVmTestDirectory $root }
}

Add-EzVmTest -Name 'Private ACL: wrong object types and missing targets refuse before mutation' -SkipReason $privateAclWindowsSkip -ScriptBlock {
    $root = New-EzVmTestDirectory -Prefix 'wrong ACL target'
    try {
        $file = Join-Path $root 'unchanged.txt'; [IO.File]::WriteAllText($file, 'sentinel')
        $fileAcl = (Get-Acl -LiteralPath $file).Sddl
        $directoryAcl = (Get-Acl -LiteralPath $root).Sddl
        Assert-EzVmThrows { & (Get-Module EzVm) { param($p) Set-EzVmPrivateAcl -Path $p -Directory } $file } -MessagePattern 'requested file or directory type' | Out-Null
        Assert-EzVmThrows { & (Get-Module EzVm) { param($p) Set-EzVmPrivateAcl -Path $p } $root } -MessagePattern 'requested file or directory type' | Out-Null
        $missing = Join-Path $root 'missing.txt'
        Assert-EzVmThrows { & (Get-Module EzVm) { param($p) Set-EzVmPrivateAcl -Path $p } $missing } -MessagePattern 'existing object' | Out-Null
        Assert-EzVmEqual (Get-Acl -LiteralPath $file).Sddl $fileAcl
        Assert-EzVmEqual (Get-Acl -LiteralPath $root).Sddl $directoryAcl
        Assert-EzVmEqual ([IO.File]::ReadAllText($file)) 'sentinel'
        Assert-EzVmTrue (-not (Test-Path -LiteralPath $missing))
    }
    finally { Remove-EzVmTestDirectory $root }
}

Add-EzVmTest -Name 'Private ACL: denied DACL persistence terminates without changing the target' -SkipReason $privateAclWindowsSkip -ScriptBlock {
    $root = New-EzVmTestDirectory -Prefix 'denied ACL'
    try {
        $file = Join-Path $root 'readable without WRITE_DAC.txt'; [IO.File]::WriteAllText($file, 'sentinel')
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl = [Security.AccessControl.FileSecurity]::new()
        $acl.SetAccessRuleProtection($true, $false)
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'Read', 'Allow'))
        # OWNER RIGHTS suppresses the owner's otherwise implicit WRITE_DAC.
        $ownerRights = [Security.Principal.SecurityIdentifier]::new('S-1-3-4')
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($ownerRights, 'ReadPermissions', 'Allow'))
        Set-EzVmTestAclDescriptor -Path $file -Descriptor $acl
        $before = (Get-Acl -LiteralPath $file).Sddl
        Assert-EzVmThrows { & (Get-Module EzVm) { param($p) Set-EzVmPrivateAcl -Path $p } $file } | Out-Null
        Assert-EzVmEqual (Get-Acl -LiteralPath $file).Sddl $before
        Assert-EzVmEqual ([IO.File]::ReadAllText($file)) 'sentinel'
        # The containing fixture still owns DELETE_CHILD; no permission repair.
        [IO.File]::Delete($file)
    }
    finally { Remove-EzVmTestDirectory $root }
}

Add-EzVmTest -Name 'Private ACL: pre-existing identity refuses native ACL failure before key derivation' -SkipReason $privateAclWindowsSkip -ScriptBlock {
    $root = New-EzVmCheckoutFixture -Prefix 'preserved ACL failure'
    try {
        $paths = Get-EzVmSshPaths -Root $root
        [void][IO.Directory]::CreateDirectory($paths.KeysDirectory)
        [IO.File]::WriteAllText($paths.ControllerPrivateKey, 'synthetic private bytes')
        [IO.File]::WriteAllText($paths.ControllerPublicKey, 'ssh-ed25519 AAAA fixture')
        $calls = [pscustomobject]@{ Keygen = 0; NativeAcl = 0 }
        $tools = [pscustomobject]@{ Valid = $true; Ssh = 'fixture'; Scp = 'fixture'; Keygen = 'fixture-keygen'; Missing = @(); Reason = 'fixture' }
        $runner = {
            param($exe, $arguments, $seconds)
            if ($exe -ceq 'fixture-keygen') { $calls.Keygen++; throw 'Key derivation must not run after ACL refusal.' }
            $calls.NativeAcl++
            return [pscustomobject]@{ ExitCode = 5; StdOut = ''; StdErr = 'synthetic ACL refusal' }
        }.GetNewClosure()
        Assert-EzVmThrows { Get-EzVmControllerSshIdentity -Root $root -Tooling $tools -ProcessRunner $runner } -MessagePattern 'Failed to restrict.*private-key ACL' | Out-Null
        Assert-EzVmEqual $calls.NativeAcl 1
        Assert-EzVmEqual $calls.Keygen 0
        Assert-EzVmEqual ([IO.File]::ReadAllText($paths.ControllerPrivateKey)) 'synthetic private bytes'
        Assert-EzVmEqual ([IO.File]::ReadAllText($paths.ControllerPublicKey)) 'ssh-ed25519 AAAA fixture'
    }
    finally { Remove-EzVmTestDirectory $root }
}
