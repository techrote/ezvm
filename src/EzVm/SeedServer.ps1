function Start-EzVmSeedServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$UserData,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$MetaData,
        [ValidateRange(1, 86400)][int]$TimeoutSeconds = 1800
    )

    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Server.ExclusiveAddressUse = $true
    $listener.Start()
    $endpoint = [System.Net.IPEndPoint]$listener.LocalEndpoint
    $startedAt = [DateTime]::UtcNow
    return [pscustomobject]@{
        Listener = $listener
        Address = '127.0.0.1'
        Port = [int]$endpoint.Port
        UserData = $UserData
        MetaData = $MetaData
        StartedAt = $startedAt
        DeadlineUtc = $startedAt.AddSeconds($TimeoutSeconds)
        RequestCount = 0
        Closed = $false
    }
}

function Stop-EzVmSeedServer {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Server)

    if ($Server.Closed) { return }
    try { $Server.Listener.Stop() }
    finally { $Server.Closed = $true }
}

function Write-EzVmSeedHttpResponse {
    param(
        [Parameter(Mandatory = $true)][System.IO.Stream]$Stream,
        [Parameter(Mandatory = $true)][int]$StatusCode,
        [Parameter(Mandatory = $true)][string]$Reason,
        [Parameter(Mandatory = $true)][ValidateSet('GET', 'HEAD')][string]$Method,
        [AllowEmptyString()][string]$Body = ''
    )

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $bodyBytes = $utf8.GetBytes($Body)
    $crlf = [char]13 + [char]10
    $header = "HTTP/1.1 $StatusCode $Reason" + $crlf +
        'Content-Type: text/plain; charset=utf-8' + $crlf +
        "Content-Length: $($bodyBytes.Length)" + $crlf +
        'Connection: close' + $crlf +
        'Cache-Control: no-store' + $crlf + $crlf
    $headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    if ($Method -ceq 'GET' -and $bodyBytes.Length -gt 0) {
        $Stream.Write($bodyBytes, 0, $bodyBytes.Length)
    }
    $Stream.Flush()
}

function Invoke-EzVmSeedServerPending {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Server,
        [ValidateRange(1, 64)][int]$MaxRequests = 8
    )

    if ($Server.Closed) { throw 'The cloud-init seed server is already closed.' }
    if ([DateTime]::UtcNow -gt $Server.DeadlineUtc) {
        throw 'The cloud-init seed server exceeded its bounded lifetime.'
    }

    $handled = 0
    while ($handled -lt $MaxRequests -and $Server.Listener.Pending()) {
        $client = $null
        $stream = $null
        $reader = $null
        try {
            $client = $Server.Listener.AcceptTcpClient()
            $client.ReceiveTimeout = 5000
            $client.SendTimeout = 5000
            $stream = $client.GetStream()
            $reader = New-Object System.IO.StreamReader($stream, [Text.Encoding]::ASCII, $false, 1024, $true)
            $requestLine = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($requestLine)) {
                Write-EzVmSeedHttpResponse -Stream $stream -StatusCode 400 -Reason 'Bad Request' -Method GET
                continue
            }

            $headerCount = 0
            $headerBytes = 0
            while ($true) {
                $line = $reader.ReadLine()
                if ($null -eq $line -or $line.Length -eq 0) { break }
                $headerCount++
                $headerBytes += $line.Length
                if ($headerCount -gt 64 -or $headerBytes -gt 16384) {
                    Write-EzVmSeedHttpResponse -Stream $stream -StatusCode 431 -Reason 'Request Header Fields Too Large' -Method GET
                    $requestLine = $null
                    break
                }
            }
            if ($null -eq $requestLine) { continue }

            $match = [regex]::Match($requestLine, '^(?<method>[A-Z]+) (?<target>[^ ]+) HTTP/1\.[01]$')
            if (-not $match.Success) {
                Write-EzVmSeedHttpResponse -Stream $stream -StatusCode 400 -Reason 'Bad Request' -Method GET
                continue
            }

            $method = $match.Groups['method'].Value
            $target = $match.Groups['target'].Value
            if ($method -cnotin @('GET', 'HEAD')) {
                Write-EzVmSeedHttpResponse -Stream $stream -StatusCode 405 -Reason 'Method Not Allowed' -Method GET
                continue
            }

            if ($target -ceq '/user-data') {
                Write-EzVmSeedHttpResponse -Stream $stream -StatusCode 200 -Reason 'OK' -Method $method -Body $Server.UserData
            }
            elseif ($target -ceq '/meta-data') {
                Write-EzVmSeedHttpResponse -Stream $stream -StatusCode 200 -Reason 'OK' -Method $method -Body $Server.MetaData
            }
            else {
                Write-EzVmSeedHttpResponse -Stream $stream -StatusCode 404 -Reason 'Not Found' -Method $method
            }
        }
        finally {
            if ($null -ne $reader) { $reader.Dispose() }
            if ($null -ne $stream) { $stream.Dispose() }
            if ($null -ne $client) { $client.Dispose() }
            $handled++
            $Server.RequestCount++
        }
    }
    return $handled
}
