function Get-EzVmFileDigest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('SHA256', 'SHA512')][string]$Algorithm
    )

    $fullPath = Assert-EzVmSafePath -Path (Resolve-EzVmProcessFileSystemPath -Path $Path) -Description 'Artifact hashing'
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

function Resolve-EzVmDownloadUrl {
    param([string]$Url, [AllowNull()][Uri]$Base = $null)
    $parsed = $null
    $valid = if ($null -eq $Base) { [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$parsed) } else { [Uri]::TryCreate($Base, $Url, [ref]$parsed) }
    if (-not $valid -or $parsed.Scheme -cne 'https' -or $parsed.UserInfo.Length -gt 0) {
        throw 'Artifact download and redirects require HTTPS without embedded credentials.'
    }
    return $parsed
}

function Invoke-EzVmHttpDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Destination,
        [ValidateRange(1, 7200)][int]$TimeoutSeconds = 1800,
        [ValidateRange(1, 9223372036854775807)][long]$MaximumBytes = 17179869184
    )
    $parsed = Resolve-EzVmDownloadUrl -Url $Uri
    $Destination = Assert-EzVmSafePath -Path $Destination -Description 'Download output'
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $response = $input = $output = $null
    try {
        for ($redirects = 0; $redirects -le 5; $redirects++) {
            $remaining = $TimeoutSeconds * 1000 - [int]$clock.ElapsedMilliseconds
            if ($remaining -le 0) { throw 'Artifact download exceeded its total deadline.' }
            $request = [Net.HttpWebRequest]::Create($parsed)
            $request.Method = 'GET'
            $request.AllowAutoRedirect = $false
            $request.UserAgent = 'ezvm/' + (Get-EzVmVersion)
            $request.Timeout = $remaining
            $request.ReadWriteTimeout = $remaining
            $response = $request.GetResponse()
            if ([int]$response.StatusCode -in @(301, 302, 303, 307, 308)) {
                $next = Resolve-EzVmDownloadUrl -Url $response.Headers['Location'] -Base $parsed
                $response.Dispose()
                $response = $null
                if ($redirects -eq 5) { throw 'Artifact download exceeded five HTTPS redirects.' }
                $parsed = $next
                continue
            }
            if ([int]$response.StatusCode -ne 200) { throw 'Artifact download did not return a complete successful response.' }
            break
        }
        if ($response.ContentLength -gt $MaximumBytes) { throw 'Artifact response exceeds the reviewed size bound.' }
        $input = $response.GetResponseStream()
        $null = Assert-EzVmSafePath -Path $Destination -Description 'Download output'
        $output = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $buffer = New-Object byte[] 131072
        [long]$total = 0
        while ($true) {
            $remaining = $TimeoutSeconds * 1000 - [int]$clock.ElapsedMilliseconds
            if ($remaining -le 0) { throw 'Artifact download exceeded its total deadline.' }
            if ($input.CanTimeout) { $input.ReadTimeout = $remaining }
            $read = $input.Read($buffer, 0, $buffer.Length)
            if ($read -eq 0) { break }
            if ($total -gt $MaximumBytes - $read) { throw 'Artifact stream exceeds the reviewed size bound.' }
            $total += $read
            $output.Write($buffer, 0, $read)
        }
        if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw 'Artifact download exceeded its total deadline.' }
        $output.Flush($true)
    }
    finally {
        if ($null -ne $output) { $output.Dispose() }
        if ($null -ne $input) { $input.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
        $clock.Stop()
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
    if ([IO.Path]::GetFileName($FileName) -cne $FileName -or [string]::IsNullOrWhiteSpace($FileName) -or $FileName -match '[\\/:\x00-\x1f]' -or $FileName -in @('.', '..')) {
        throw 'Artifact filename must be a plain filename without path components.'
    }

    $parsedUrl = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$parsedUrl) -or $parsedUrl.Scheme -cne 'https' -or $parsedUrl.UserInfo.Length -gt 0) {
        throw 'Artifact URL must use HTTPS without embedded credentials.'
    }
    $DestinationDirectory = Assert-EzVmSafePath -Path $DestinationDirectory -Description 'Artifact cache'
    $null = Assert-EzVmSafePath -Path (Join-Path $DestinationDirectory $FileName) -Description 'Artifact cache file'
    [void][IO.Directory]::CreateDirectory($DestinationDirectory)
    $lock = Enter-EzVmSecurityLock -Path (Join-Path $DestinationDirectory ('.' + $FileName + '.download.lock'))
    try {
        $destination = Join-Path $DestinationDirectory $FileName
        if ([IO.File]::Exists($destination)) {
            $existingDigest = Get-EzVmFileDigest -Path $destination -Algorithm $Algorithm
            $sizeMatches = (-not $PSBoundParameters.ContainsKey('ExpectedSizeBytes')) -or
                ((Get-Item -LiteralPath $destination -Force).Length -eq $ExpectedSizeBytes)
            if ($existingDigest -ceq $ExpectedDigest -and $sizeMatches) {
                return [pscustomobject][ordered]@{
                    Path = $destination
                    Digest = $existingDigest
                    SizeBytes = (Get-Item -LiteralPath $destination -Force).Length
                    Downloaded = $false
                }
            }
            $null = Assert-EzVmSafePath -Path $destination -Description 'Corrupt cache replacement'
            [IO.File]::Delete($destination)
        }

        $temporary = Join-Path $DestinationDirectory ('.ezvm-download-' + [Guid]::NewGuid().ToString('N') + '.tmp')
        try {
            if ($null -ne $Downloader) {
                & $Downloader $Url $temporary
            }
            else {
                $downloadArguments = @{ Uri = $Url; Destination = $temporary }
                if ($PSBoundParameters.ContainsKey('ExpectedSizeBytes')) { $downloadArguments.MaximumBytes = $ExpectedSizeBytes }
                Invoke-EzVmHttpDownload @downloadArguments
            }
            if (-not [IO.File]::Exists($temporary)) {
                throw "Artifact downloader did not create '$temporary'."
            }
            $null = Assert-EzVmSafePath -Path $temporary -Description 'Downloaded artifact'
            $item = Get-Item -LiteralPath $temporary -Force
            if ($PSBoundParameters.ContainsKey('ExpectedSizeBytes') -and $item.Length -ne $ExpectedSizeBytes) {
                throw "Artifact '$FileName' has size $($item.Length) bytes; reviewed size is $ExpectedSizeBytes bytes."
            }
            $observed = Get-EzVmFileDigest -Path $temporary -Algorithm $Algorithm
            if ($observed -cne $ExpectedDigest) {
                throw "Artifact '$FileName' failed $Algorithm verification. Expected $ExpectedDigest, observed $observed. The untrusted download will not be promoted."
            }

            try {
                $null = Assert-EzVmSafePath -Path $temporary -Description 'Download publication'
                $null = Assert-EzVmSafePath -Path $destination -Description 'Download publication'
                [IO.File]::Move($temporary, $destination)
            }
            catch [IO.IOException] {
                # A competing process may have won the new-file race. Accept only an
                # independently verified matching result; never overwrite blindly.
                if ([IO.File]::Exists($destination) -and
                    (Get-EzVmFileDigest -Path $destination -Algorithm $Algorithm) -ceq $ExpectedDigest -and
                    ((-not $PSBoundParameters.ContainsKey('ExpectedSizeBytes')) -or
                        (Get-Item -LiteralPath $destination -Force).Length -eq $ExpectedSizeBytes)) {
                    [IO.File]::Delete($temporary)
                }
                else {
                    throw
                }
            }
            return [pscustomobject][ordered]@{
                Path = $destination
                Digest = Get-EzVmFileDigest -Path $destination -Algorithm $Algorithm
                SizeBytes = (Get-Item -LiteralPath $destination -Force).Length
                Downloaded = $true
            }
        }
        catch {
            if ([IO.File]::Exists($temporary)) {
                try { $null = Assert-EzVmSafePath -Path $temporary -Description 'Download cleanup'; [IO.File]::Delete($temporary) } catch { }
            }
            # The authoritative destination may belong to a competing publisher.
            # Never delete it in failure cleanup, especially after a failed read.
            throw
        }
    }
    finally { $lock.Dispose() }
}
