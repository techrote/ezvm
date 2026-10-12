# Host filesystem safeguards. These defend against malformed/stale layout, not a
# hostile administrator replacing the application or racing every filesystem call.
function Assert-EzVmSafePath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [string]$Description = 'Host path')

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -match '[\x00-\x1f]') {
        throw "$Description contains an empty path or control characters. Use a regular local filesystem path."
    }
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        # Check spelling BEFORE .NET Framework can trim a trailing dot or space.
        if ($Path.StartsWith('\\') -or $Path -match '^[A-Za-z]:(?![\\/])') {
            throw "$Description requires an ordinary local drive path, not a device namespace or drive-relative path."
        }
        $tail = if ($Path -match '^[A-Za-z]:') { $Path.Substring(2) } else { $Path }
        if ($tail.Contains(':')) { throw "$Description contains an alternate stream or non-filesystem namespace." }
        foreach ($part in @($tail -split '[\\/]' | Where-Object { $_ -notin @('', '.', '..') })) {
            if ($part -match '[. ]$|[<>"|?*]' -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9\u00b9\u00b2\u00b3]|LPT[1-9\u00b9\u00b2\u00b3])(?:\..*)?$') {
                throw "$Description contains an unsafe Windows path component."
            }
        }
    }
    $provider = $null
    $drive = $null
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path, [ref]$provider, [ref]$drive)
    if ($provider.Name -cne 'FileSystem') { throw "$Description must be a filesystem path." }
    $full = [IO.Path]::GetFullPath($full)
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        # Device namespaces, UNC and alternate streams are not the local-disk
        # portability contract. Brackets and spaces inside components are valid.
        if ($full -notmatch '^[A-Za-z]:[\\/]' -or $full.Substring(2).Contains(':')) {
            throw "$Description requires a local drive path without device namespaces or alternate data streams."
        }
        foreach ($part in @($full.Substring(3) -split '[\\/]' | Where-Object { $_.Length -gt 0 })) {
            if ($part -match '[. ]$|[<>"|?*]' -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9\u00b9\u00b2\u00b3]|LPT[1-9\u00b9\u00b2\u00b3])(?:\..*)?$') {
                throw "$Description contains an unsafe Windows path component. Use ordinary non-device filenames."
            }
        }
    }
    # Walk ALL existing ancestors, including those above the selected root.
    # Get-Item -Force sees dangling links and hidden files; Test-Path alone does not.
    $cursor = $full
    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        try {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            $attributesProperty = $item.PSObject.Properties['Attributes']
            if ($null -ne $attributesProperty) {
                if (([IO.FileAttributes]$attributesProperty.Value -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "$Description traverses a reparse point at '$cursor'. Refusing junction/symlink redirection; restore a regular local layout."
                }
            }
            elseif ($item -is [System.Management.Automation.PSDriveInfo]) {
                # Windows PowerShell 5.1 can represent the drive root itself as
                # PSDriveInfo rather than DirectoryInfo. Accept that provider
                # shape only for the exact filesystem root; descendants must
                # still expose filesystem attributes and remain fail-closed.
                $pathRoot = [IO.Path]::GetPathRoot($cursor)
                if (-not [string]::Equals($cursor, $pathRoot, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "$Description could not validate filesystem attributes at '$cursor'. Refusing an ambiguous ancestor."
                }
            }
            else {
                throw "$Description could not validate filesystem attributes at '$cursor'. Refusing an ambiguous ancestor."
            }
        }
        catch [System.Management.Automation.ItemNotFoundException] { }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -ceq $cursor) { break }
        $cursor = $parent
    }
    return $full
}

function Read-EzVmBoundedText {
    param([Parameter(Mandatory = $true)][string]$Path,
        [ValidateRange(1, 16777216)][int]$MaximumBytes = 2097152)
    $full = Assert-EzVmSafePath -Path $Path -Description 'Text state'
    $stream = [IO.File]::Open($full, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($stream.Length -gt $MaximumBytes) { throw 'Text state exceeds the bounded read limit; preserve it for inspection instead of loading it.' }
        $buffer = New-Object byte[] ($MaximumBytes + 1)
        $count = 0
        while ($count -lt $buffer.Length) {
            $read = $stream.Read($buffer, $count, $buffer.Length - $count)
            if ($read -eq 0) { break }
            $count += $read
        }
        if ($count -gt $MaximumBytes) { throw 'Text state grew beyond the bounded read limit.' }
        $start = 0
        if ($count -ge 3 -and $buffer[0] -eq 239 -and $buffer[1] -eq 187 -and $buffer[2] -eq 191) { $start = 3 }
        return (New-Object Text.UTF8Encoding($false, $true)).GetString($buffer, $start, $count - $start)
    }
    finally { $stream.Dispose() }
}

function Get-EzVmSafeTree {
    param([Parameter(Mandatory = $true)][string]$Path,
        [ValidateRange(1, 100000)][int]$MaximumEntries = 20000)
    $root = Assert-EzVmSafePath -Path $Path -Description 'Managed tree'
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $pending.Push($root)
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        $null = Assert-EzVmSafePath -Path $current -Description 'Managed tree'
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        $entries.Add($item)
        if ($entries.Count -gt $MaximumEntries) { throw 'Managed tree exceeds its bounded entry limit; preserve it for explicit inspection.' }
        if ($item -is [IO.DirectoryInfo]) {
            foreach ($child in [IO.Directory]::EnumerateFileSystemEntries($current)) {
                if ($pending.Count + $entries.Count -ge $MaximumEntries) { throw 'Managed tree exceeds its bounded entry limit; preserve it for explicit inspection.' }
                $pending.Push($child)
            }
        }
    }
    return $entries.ToArray()
}

function Remove-EzVmSafeTree {
    param([Parameter(Mandatory = $true)][string]$Path)
    # Complete link/size preflight before deleting anything; then recheck each
    # path and delete bottom-up without invoking recursive provider traversal.
    $entries = @(Get-EzVmSafeTree -Path $Path)
    for ($index = $entries.Count - 1; $index -ge 0; $index--) {
        $entry = $entries[$index]
        $null = Assert-EzVmSafePath -Path $entry.FullName -Description 'Cleanup path'
        if ($entry -is [IO.DirectoryInfo]) { [IO.Directory]::Delete($entry.FullName, $false) }
        else {
            # File.Delete unlinks the name. Do not change attributes on shared
            # hard-link targets; read-only leftovers are recoverable evidence.
            if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and ($entry.Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0) {
                Assert-EzVmSingleLinkFile -Path $entry.FullName
                [IO.File]::SetAttributes($entry.FullName, ($entry.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)))
            }
            [IO.File]::Delete($entry.FullName)
        }
    }
}

function Enter-EzVmSecurityLock {
    param([Parameter(Mandatory = $true)][string]$Path,
        [ValidateRange(1, 30000)][int]$TimeoutMilliseconds = 5000)
    $full = Assert-EzVmSafePath -Path $Path -Description 'Security lock'
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full))
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    do {
        $null = Assert-EzVmSafePath -Path $full -Description 'Security lock'
        try { return [IO.File]::Open($full, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) { throw 'A security operation already owns this lock. Let it finish, then retry; do not delete a live lock file.' }
            Start-Sleep -Milliseconds 50
        }
    } while ($true)
}

function Get-EzVmSecretPattern {
    # High-confidence credential formats only; no entropy scanner or content echo.
    return '(?i)-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----|\bgh[pousr]_[A-Za-z0-9]{36,255}\b|\bgithub_pat_[A-Za-z0-9_]{60,255}\b|\b(?:AKIA|ASIA)[A-Z0-9]{16}\b|\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{32,255}\b'
}

function Assert-EzVmCredentialFreeText {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [string]$Description = 'Managed input')
    if ([regex]::IsMatch($Text, (Get-EzVmSecretPattern))) {
        throw "$Description contains credential-like material. Remove it from source and rotate exposed credentials; contents are intentionally not printed."
    }
}

function Protect-EzVmDiagnosticText {
    param([AllowNull()][AllowEmptyString()][string]$Text = '',
        [ValidateRange(64, 16384)][int]$MaximumCharacters = 4096)
    if ($null -eq $Text) { return '' }
    # Bound regex work as well as output, but redact before truncating to avoid
    # leaving a partial credential at the display boundary.
    if ($Text.Length -gt 1048576) { return '[diagnostic omitted: input exceeds 1 MiB]' }
    $safe = [regex]::Replace($Text, (Get-EzVmSecretPattern), '[REDACTED]')
    $safe = [regex]::Replace($safe, '(?im)(authorization\s*:\s*(?:bearer|basic)\s+)\S+', '$1[REDACTED]')
    $safe = [regex]::Replace($safe, '(?i)([?&](?:token|access_token|api_key|password|secret)=)[^\s&#]+', '$1[REDACTED]')
    $safe = [regex]::Replace($safe, '(?i)(https?://)[^\s/@]+:[^\s/@]+@', '$1[REDACTED]@')
    $safe = [regex]::Replace($safe, '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', '?')
    if ($safe.Length -gt $MaximumCharacters) { $safe = $safe.Substring(0, $MaximumCharacters) + ' [truncated]' }
    return $safe
}

function Assert-EzVmSingleLinkFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = Assert-EzVmSafePath -Path $Path -Description 'Permission target'
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return }
    if ($null -eq ('EzVm.Security.FileIdentity' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace EzVm.Security {
    public static class FileIdentity {
        [StructLayout(LayoutKind.Sequential)]
        private struct Info {
            public uint Attributes, CreationLow, CreationHigh, AccessLow, AccessHigh;
            public uint WriteLow, WriteHigh, Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out Info info);
        public static void RequireSingleLink(string path) {
            using (var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read)) {
                Info info;
                if (!GetFileInformationByHandle(file.SafeFileHandle, out info))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                if (info.Links != 1 || (info.Attributes & 0x400) != 0)
                    throw new IOException("Permission changes refuse hard-linked or reparse-point files.");
            }
        }
    }
}
'@
    }
    [EzVm.Security.FileIdentity]::RequireSingleLink($full)
}
