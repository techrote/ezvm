function Get-EzVmFileDigest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('SHA256', 'SHA512')][string]$Algorithm
    )

    $fullPath = Resolve-EzVmProcessFileSystemPath -Path $Path
    if (-not [IO.File]::Exists($fullPath)) {
        throw "Cannot hash missing artifact '$Path'. Re-acquire the artifact and retry."
    }
    $stream = $null
    $algorithmInstance = $null
    try {
        $stream = [IO.File]::Open($fullPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $algorithmInstance = [Security.Cryptography.HashAlgorithm]::Create($Algorithm)
        if ($null -eq $algorithmInstance) { throw "Hash algorithm '$Algorithm' is unavailable." }
        $bytes = $algorithmInstance.ComputeHash($stream)
        return ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        if ($null -ne $algorithmInstance) { $algorithmInstance.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Assert-EzVmArtifactDigest {
    param(
        [Parameter(Mandatory = $true)][string]$Algorithm,
        [Parameter(Mandatory = $true)][string]$ExpectedDigest
    )

    $length = if ($Algorithm -ceq 'SHA256') { 64 } else { 128 }
    if ($ExpectedDigest -cnotmatch ('^[0-9a-f]{' + $length + '}$')) {
        throw "Reviewed $Algorithm digest must contain exactly $length lowercase hexadecimal characters."
    }
}

function Invoke-EzVmHttpDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Uri,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Destination,
        [ValidateRange(1, 7200)][int]$TimeoutSeconds = 1800
    )

    $parsed = $null
    if (-not [Uri]::TryCreate($Uri, [UriKind]::Absolute, [ref]$parsed) -or $parsed.Scheme -cne 'https') {
        throw "Artifact URL must be an absolute HTTPS URL: '$Uri'."
    }

    $request = [Net.HttpWebRequest]::Create($parsed)
    $request.Method = 'GET'
    $request.AllowAutoRedirect = $true
    $request.UserAgent = 'ezvm/' + (Get-EzVmVersion)
    $request.Timeout = $TimeoutSeconds * 1000
    $request.ReadWriteTimeout = $TimeoutSeconds * 1000

    $response = $null
    $input = $null
    $output = $null
    try {
        $response = $request.GetResponse()
        $input = $response.GetResponseStream()
        $output = New-Object IO.FileStream(
            $Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $buffer = New-Object byte[] 131072
        while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $output.Write($buffer, 0, $read)
        }
        $output.Flush($true)
    }
    finally {
        if ($null -ne $output) { $output.Dispose() }
        if ($null -ne $input) { $input.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
    }
}

function Get-EzVmVerifiedArtifact {
    <#
    .SYNOPSIS
    Acquires one reviewed artifact and promotes it only after digest verification.
    .DESCRIPTION
    Existing digest-matching content is reused without network access. A corrupt
    authoritative cache entry is removed before reacquisition so a failed retry
    cannot leave known-bad content at the trusted path. Downloads use a unique
    same-directory temporary file and are atomically renamed after verification.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Url,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$FileName,
        [Parameter(Mandatory = $true)][ValidateSet('SHA256', 'SHA512')][string]$Algorithm,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$ExpectedDigest,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$DestinationDirectory,
        [ValidateRange(1, 9223372036854775807)][long]$ExpectedSizeBytes,
        [scriptblock]$Downloader
    )

    Assert-EzVmArtifactDigest -Algorithm $Algorithm -ExpectedDigest $ExpectedDigest
    if ([IO.Path]::GetFileName($FileName) -cne $FileName -or [string]::IsNullOrWhiteSpace($FileName)) {
        throw "Artifact filename must be a plain filename without path components: '$FileName'."
    }

    [void][IO.Directory]::CreateDirectory($DestinationDirectory)
    $destination = Join-Path $DestinationDirectory $FileName
    if ([IO.File]::Exists($destination)) {
        $existingDigest = Get-EzVmFileDigest -Path $destination -Algorithm $Algorithm
        $sizeMatches = (-not $PSBoundParameters.ContainsKey('ExpectedSizeBytes')) -or
            ((Get-Item -LiteralPath $destination).Length -eq $ExpectedSizeBytes)
        if ($existingDigest -ceq $ExpectedDigest -and $sizeMatches) {
            return [pscustomobject][ordered]@{
                Path = $destination
                Digest = $existingDigest
                SizeBytes = (Get-Item -LiteralPath $destination).Length
                Downloaded = $false
            }
        }
        [IO.File]::Delete($destination)
    }

    $temporary = Join-Path $DestinationDirectory ('.ezvm-download-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        if ($null -ne $Downloader) {
            & $Downloader $Url $temporary
        }
        else {
            Invoke-EzVmHttpDownload -Uri $Url -Destination $temporary
        }
        if (-not [IO.File]::Exists($temporary)) {
            throw "Artifact downloader did not create '$temporary'."
        }
        $item = Get-Item -LiteralPath $temporary
        if ($PSBoundParameters.ContainsKey('ExpectedSizeBytes') -and $item.Length -ne $ExpectedSizeBytes) {
            throw "Artifact '$FileName' has size $($item.Length) bytes; reviewed size is $ExpectedSizeBytes bytes."
        }
        $observed = Get-EzVmFileDigest -Path $temporary -Algorithm $Algorithm
        if ($observed -cne $ExpectedDigest) {
            throw "Artifact '$FileName' failed $Algorithm verification. Expected $ExpectedDigest, observed $observed. The untrusted download will not be promoted."
        }

        try {
            [IO.File]::Move($temporary, $destination)
        }
        catch [IO.IOException] {
            # A competing process may have won the new-file race. Accept only an
            # independently verified matching result; never overwrite blindly.
            if ([IO.File]::Exists($destination) -and
                (Get-EzVmFileDigest -Path $destination -Algorithm $Algorithm) -ceq $ExpectedDigest) {
                [IO.File]::Delete($temporary)
            }
            else {
                throw
            }
        }
        return [pscustomobject][ordered]@{
            Path = $destination
            Digest = Get-EzVmFileDigest -Path $destination -Algorithm $Algorithm
            SizeBytes = (Get-Item -LiteralPath $destination).Length
            Downloaded = $true
        }
    }
    catch {
        if ([IO.File]::Exists($temporary)) {
            try { [IO.File]::Delete($temporary) } catch { }
        }
        if ([IO.File]::Exists($destination)) {
            try {
                if ((Get-EzVmFileDigest -Path $destination -Algorithm $Algorithm) -cne $ExpectedDigest) {
                    [IO.File]::Delete($destination)
                }
            }
            catch {
                try { [IO.File]::Delete($destination) } catch { }
            }
        }
        throw
    }
}
