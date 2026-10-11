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
        RequestPaths = New-Object 'System.Collections.Generic.List[string]'
        Clients = New-Object 'System.Collections.Generic.List[object]'
        Closed = $false
    }
}

function Stop-EzVmSeedServer {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Server)

    if ($Server.Closed) { return }
    try {
        foreach ($state in @($Server.Clients.ToArray())) {
            try {
                if ($null -ne $state.Stream) { $state.Stream.Dispose() }
                $state.Client.Dispose()
                $state.Buffer.Dispose()
            }
            catch { }
        }
        $Server.Clients.Clear()
        $Server.Listener.Stop()
    }
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

function Add-EzVmSeedPendingClients {
    param([Parameter(Mandatory = $true)][object]$Server, [int]$Maximum)

    $accepted = 0
    while ($accepted -lt $Maximum -and $Server.Listener.Pending()) {
        $client = $Server.Listener.AcceptTcpClient()
        $client.NoDelay = $true
        $Server.Clients.Add([pscustomobject]@{
            Client = $client
            Stream = $client.GetStream()
            Buffer = New-Object System.IO.MemoryStream
            Closed = $false
        })
        $accepted++
    }
    return $accepted
}

function Close-EzVmSeedPendingClient {
    param([Parameter(Mandatory = $true)][object]$State)
    if ($State.Closed) { return }
    try {
        if ($null -ne $State.Stream) { $State.Stream.Dispose() }
        $State.Client.Dispose()
        $State.Buffer.Dispose()
    }
    finally { $State.Closed = $true }
}

function Complete-EzVmSeedPendingRequest {
    param(
        [Parameter(Mandatory = $true)][object]$Server,
        [Parameter(Mandatory = $true)][object]$State
    )

    if ($State.Buffer.Length -gt 16384) {
        Write-EzVmSeedHttpResponse -Stream $State.Stream -StatusCode 431 -Reason 'Request Header Fields Too Large' -Method GET
        return $true
    }

    $text = [Text.Encoding]::ASCII.GetString($State.Buffer.ToArray())
    $boundary = [regex]::Match($text, '(?s)^(?<headers>.*?)\r?\n\r?\n')
    if (-not $boundary.Success) { return $false }

    $lines = @($boundary.Groups['headers'].Value -split '\r?\n')
    if ($lines.Count -eq 0 -or [string]::IsNullOrWhiteSpace($lines[0])) {
        Write-EzVmSeedHttpResponse -Stream $State.Stream -StatusCode 400 -Reason 'Bad Request' -Method GET
        return $true
    }
    if ($lines.Count -gt 65) {
        Write-EzVmSeedHttpResponse -Stream $State.Stream -StatusCode 431 -Reason 'Request Header Fields Too Large' -Method GET
        return $true
    }

    $match = [regex]::Match($lines[0], '^(?<method>[A-Z]+) (?<target>[^ ]+) HTTP/1\.[01]$')
    if (-not $match.Success) {
        Write-EzVmSeedHttpResponse -Stream $State.Stream -StatusCode 400 -Reason 'Bad Request' -Method GET
        return $true
    }

    $method = $match.Groups['method'].Value
    $target = $match.Groups['target'].Value
    if ($method -cnotin @('GET', 'HEAD')) {
        Write-EzVmSeedHttpResponse -Stream $State.Stream -StatusCode 405 -Reason 'Method Not Allowed' -Method GET
        return $true
    }

    $Server.RequestPaths.Add($target)
    if ($target -ceq '/user-data') {
        Write-EzVmSeedHttpResponse -Stream $State.Stream -StatusCode 200 -Reason 'OK' -Method $method -Body $Server.UserData
    }
    elseif ($target -ceq '/meta-data') {
        Write-EzVmSeedHttpResponse -Stream $State.Stream -StatusCode 200 -Reason 'OK' -Method $method -Body $Server.MetaData
    }
    elseif ($target -ceq '/vendor-data' -or $target -ceq '/network-config') {
        # Current NoCloud probes both standard optional files. Empty 200 responses
        # avoid long datasource retry delays while preserving DHCP networking.
        Write-EzVmSeedHttpResponse -Stream $State.Stream -StatusCode 200 -Reason 'OK' -Method $method -Body ''
    }
    else {
        Write-EzVmSeedHttpResponse -Stream $State.Stream -StatusCode 404 -Reason 'Not Found' -Method $method
    }
    return $true
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

    $null = Add-EzVmSeedPendingClients -Server $Server -Maximum $MaxRequests
    $handled = 0
    $buffer = New-Object byte[] 4096

    foreach ($state in @($Server.Clients.ToArray())) {
        if ($handled -ge $MaxRequests) { break }
        if ($state.Closed) { continue }

        try {
            while ($state.Stream.DataAvailable) {
                $read = $state.Stream.Read($buffer, 0, $buffer.Length)
                if ($read -le 0) { break }
                $state.Buffer.Write($buffer, 0, $read)
                if ($state.Buffer.Length -gt 16384) { break }
            }

            if (Complete-EzVmSeedPendingRequest -Server $Server -State $state) {
                $handled++
                $Server.RequestCount++
                Close-EzVmSeedPendingClient -State $state
                continue
            }

            $socket = $state.Client.Client
            if ($socket.Poll(0, [System.Net.Sockets.SelectMode]::SelectRead) -and $socket.Available -eq 0) {
                Close-EzVmSeedPendingClient -State $state
            }
        }
        catch [System.IO.IOException] {
            Close-EzVmSeedPendingClient -State $state
        }
        catch [System.Net.Sockets.SocketException] {
            Close-EzVmSeedPendingClient -State $state
        }
    }

    for ($index = $Server.Clients.Count - 1; $index -ge 0; $index--) {
        if ($Server.Clients[$index].Closed) { $Server.Clients.RemoveAt($index) }
    }
    return $handled
}
