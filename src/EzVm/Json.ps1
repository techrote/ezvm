function Resolve-EzVmJsonFilePath {
    param([Parameter(Mandatory = $true)][string] $Path)

    $provider = $null
    $drive = $null
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $Path, [ref] $provider, [ref] $drive)
    if ($provider.Name -ne 'FileSystem') {
        throw "JSON state requires a filesystem path: '$Path'."
    }
    return $resolved
}

function Assert-EzVmJsonSchema {
    param(
        [AllowNull()][object] $Value,
        [int] $SchemaVersion,
        [string] $Description
    )

    $found = $false
    $version = $null
    if ($Value -is [System.Collections.IDictionary]) {
        # A literal JSON member named Keys shadows PowerShell's dictionary
        # adapter property. The underlying accessor always returns the real keys.
        foreach ($key in $Value.get_Keys()) {
            if (($key -is [string]) -and ($key -ceq 'schemaVersion')) {
                $found = $true
                $version = $Value[$key]
                break
            }
        }
    }
    elseif ($Value -is [System.Management.Automation.PSCustomObject]) {
        foreach ($property in $Value.PSObject.Properties) {
            if ($property.Name -ceq 'schemaVersion') {
                if ($property.MemberType -ne 'NoteProperty') {
                    throw "$Description must contain a plain schemaVersion data property."
                }
                $found = $true
                $version = $property.Value
                break
            }
        }
    }
    else {
        throw "$Description must be a JSON object with an integer schemaVersion."
    }

    $integer = ($version -is [byte]) -or ($version -is [sbyte]) -or
        ($version -is [int16]) -or ($version -is [uint16]) -or
        ($version -is [int32]) -or ($version -is [uint32]) -or
        ($version -is [int64]) -or ($version -is [uint64])
    if ((-not $found) -or (-not $integer)) {
        throw "$Description requires an integer schemaVersion property (for example, schemaVersion: 1)."
    }
    if ($version -ne $SchemaVersion) {
        throw "$Description has unsupported schemaVersion '$version'; expected $SchemaVersion. Use a compatible ezvm version or migrate the state explicitly."
    }
}

function Assert-EzVmJsonValue {
    param(
        [AllowNull()][object] $Value,
        [int] $Depth,
        [System.Collections.Generic.List[object]] $Ancestors
    )

    # Windows PowerShell 5.1 can silently stringify values beyond ConvertTo-Json's
    # depth. Validate the plain data tree first, including cycles, on both hosts.
    if ($Depth -gt 64) {
        throw 'JSON state exceeds the supported nesting depth of 64. Simplify the state before saving it.'
    }
    if ($null -eq $Value) { return }
    if (($Value -is [string]) -or ($Value -is [bool]) -or
        ($Value -is [byte]) -or ($Value -is [sbyte]) -or
        ($Value -is [int16]) -or ($Value -is [uint16]) -or
        ($Value -is [int32]) -or ($Value -is [uint32]) -or
        ($Value -is [int64]) -or ($Value -is [uint64]) -or
        ($Value -is [decimal])) {
        return
    }
    if (($Value -is [datetime]) -or ($Value -is [datetimeoffset])) {
        throw 'JSON timestamps must be strings. Pass an ISO 8601 string when writing; use Windows PowerShell 5.1 or PowerShell 7.5+ to preserve timestamp strings when reading.'
    }
    if (($Value -is [double]) -or ($Value -is [single])) {
        if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)) {
            throw 'JSON state cannot contain NaN or infinity. Supply a finite numeric value.'
        }
        return
    }

    $isDictionary = $Value -is [System.Collections.IDictionary]
    $isObject = $Value -is [System.Management.Automation.PSCustomObject]
    $isArray = ($Value -is [System.Array]) -or ($Value -is [System.Collections.IList])
    if (-not ($isDictionary -or $isObject -or $isArray)) {
        throw "JSON state contains unsupported type '$($Value.GetType().FullName)'. Use plain objects, string-keyed dictionaries, arrays and JSON scalar values."
    }
    foreach ($ancestor in $Ancestors) {
        if ([object]::ReferenceEquals($ancestor, $Value)) {
            throw 'JSON state contains a reference cycle. Remove the cycle before saving it.'
        }
    }

    $Ancestors.Add($Value)
    try {
        if ($isDictionary) {
            foreach ($key in $Value.get_Keys()) {
                if ($key -isnot [string]) {
                    throw 'JSON state dictionary keys must be strings.'
                }
                Assert-EzVmJsonValue -Value $Value[$key] -Depth ($Depth + 1) -Ancestors $Ancestors
            }
        }
        elseif ($isObject) {
            foreach ($property in $Value.PSObject.Properties) {
                if ($property.MemberType -ne 'NoteProperty') {
                    throw "JSON state property '$($property.Name)' is not a plain data property. Remove computed properties before saving."
                }
                Assert-EzVmJsonValue -Value $property.Value -Depth ($Depth + 1) -Ancestors $Ancestors
            }
        }
        else {
            foreach ($item in $Value) {
                Assert-EzVmJsonValue -Value $item -Depth ($Depth + 1) -Ancestors $Ancestors
            }
        }
    }
    finally {
        $Ancestors.RemoveAt($Ancestors.Count - 1)
    }
}

function ConvertFrom-EzVmJsonText {
    param(
        [AllowEmptyString()][string] $Text,
        [int] $SchemaVersion,
        [string] $Description
    )

    # Check the root token before conversion: legacy ConvertFrom-Json enumerates
    # arrays, so an array containing one object could otherwise look like an object.
    if (-not $Text.TrimStart().StartsWith('{', [StringComparison]::Ordinal)) {
        throw "$Description must contain a JSON object, not an array, scalar or empty document."
    }
    try {
        $parameters = @{ InputObject = $Text; ErrorAction = 'Stop' }
        if ((Get-Command ConvertFrom-Json -CommandType Cmdlet).Parameters.ContainsKey('DateKind')) {
            # Added in 7.5; Windows PowerShell 5.1 already preserves ISO strings.
            $parameters['DateKind'] = 'String'
        }
        $value = ConvertFrom-Json @parameters
    }
    catch {
        throw "$Description contains malformed JSON. Repair or restore this state file. $(Protect-EzVmDiagnosticText $_.Exception.Message)"
    }
    Assert-EzVmJsonSchema -Value $value -SchemaVersion $SchemaVersion -Description $Description
    $ancestors = New-Object 'System.Collections.Generic.List[object]'
    Assert-EzVmJsonValue -Value $value -Depth 0 -Ancestors $ancestors
    return $value
}

function Read-EzVmJson {
    <#
    .SYNOPSIS
    Reads a filesystem JSON object and refuses missing or unsupported schemas.
    .DESCRIPTION
    ISO timestamp strings remain strings on Windows PowerShell 5.1 and current
    PowerShell 7. Older PowerShell 7 releases without DateKind fail clearly on
    auto-converted timestamps rather than changing their representation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $Path,
        [ValidateRange(1, 2147483647)][int] $SchemaVersion = 1
    )

    try {
        $fullPath = Resolve-EzVmJsonFilePath -Path $Path
        $encoding = New-Object System.Text.UTF8Encoding($false, $true)
        $text = Read-EzVmBoundedText -Path $fullPath
    }
    catch {
        throw "Could not read JSON state '$Path'. Check that the file exists and is readable, or restore it from a known valid copy. $(Protect-EzVmDiagnosticText $_.Exception.Message)"
    }
    return ConvertFrom-EzVmJsonText -Text $text -SchemaVersion $SchemaVersion -Description "JSON state '$Path'"
}

function Write-EzVmJson {
    <#
    .SYNOPSIS
    Validates and atomically writes an explicitly versioned JSON object.
    .DESCRIPTION
    The parent directory must already exist. The value must contain the requested
    integer schemaVersion. Data is validated and serialized before a unique
    same-directory temporary file is created. The temporary file is flushed to
    disk, then promoted with File.Replace (existing state) or File.Move (new state).
    Filesystems without replacement support fail closed; there is no truncate,
    copy-over or delete-then-move fallback. This helper does not provide a lock
    against concurrent writers; allocation/lifecycle callers own their locks.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $Path,
        [Parameter(Mandatory = $true)][AllowNull()][object] $Value,
        [ValidateRange(1, 2147483647)][int] $SchemaVersion = 1
    )

    $temporaryPath = $null
    $ownsTemporaryFile = $false
    $failure = $null
    $cleanupFailure = $null
    try {
        Assert-EzVmJsonSchema -Value $Value -SchemaVersion $SchemaVersion -Description 'JSON state to write'
        $ancestors = New-Object 'System.Collections.Generic.List[object]'
        Assert-EzVmJsonValue -Value $Value -Depth 0 -Ancestors $ancestors
        $json = ConvertTo-Json -InputObject $Value -Depth 100 -ErrorAction Stop -WarningAction Stop
        $null = ConvertFrom-EzVmJsonText -Text $json -SchemaVersion $SchemaVersion -Description 'Serialized JSON state'
        $encoding = New-Object System.Text.UTF8Encoding($false, $true)
        $bytes = $encoding.GetBytes($json + [Environment]::NewLine)

        $fullPath = Resolve-EzVmJsonFilePath -Path $Path
        $null = Assert-EzVmSafePath -Path $fullPath -Description 'JSON publication'
        $directory = [System.IO.Path]::GetDirectoryName($fullPath)
        if (-not [System.IO.Directory]::Exists($directory)) {
            throw "The parent directory '$directory' does not exist. Create the state directory before saving."
        }
        $temporaryPath = [System.IO.Path]::Combine($directory, '.ezvm-' + [guid]::NewGuid().ToString('N') + '.tmp')
        $stream = $null
        try {
            $stream = New-Object System.IO.FileStream(
                $temporaryPath, [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $ownsTemporaryFile = $true
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        finally {
            if ($null -ne $stream) { $stream.Dispose() }
        }

        $null = Assert-EzVmSafePath -Path $fullPath -Description 'JSON publication'
        if ([System.IO.File]::Exists($fullPath)) {
            # PowerShell casts $null to an empty string for a string parameter;
            # NullString preserves the actual null backup-path required by .NET.
            [System.IO.File]::Replace($temporaryPath, $fullPath, [System.Management.Automation.Language.NullString]::Value)
        }
        else {
            # A competing new-file writer makes Move fail instead of overwriting.
            [System.IO.File]::Move($temporaryPath, $fullPath)
        }
    }
    catch {
        $failure = $_
    }
    finally {
        if ($ownsTemporaryFile -and [System.IO.File]::Exists($temporaryPath)) {
            try { $null = Assert-EzVmSafePath -Path $temporaryPath -Description 'JSON cleanup'; [System.IO.File]::Delete($temporaryPath) }
            catch { $cleanupFailure = $_ }
        }
    }
    if ($null -ne $failure) {
        $message = "Could not atomically write JSON state '$Path'. Check the data, folder permissions, open file locks and filesystem replacement support. $($failure.Exception.Message)"
        if ($null -ne $cleanupFailure) {
            $message += " Temporary-file cleanup also failed for '$temporaryPath': $($cleanupFailure.Exception.Message)"
        }
        throw [System.IO.IOException]::new($message, $failure.Exception)
    }
}
