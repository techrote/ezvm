function Read-EzVmSeedHttpFixtureResponse {
    param(
        [Parameter(Mandatory = $true)][Net.Sockets.NetworkStream]$Stream,
        [bool]$ExpectBody = $true
    )

    $Stream.ReadTimeout = 2000
    $reader = New-Object IO.StreamReader($Stream, [Text.Encoding]::UTF8, $false, 1024, $true)
    try {
        $status = $reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace($status)) { throw 'Seed fixture response omitted an HTTP status line.' }

        $headers = New-Object 'System.Collections.Generic.List[string]'
        $contentLength = 0
        while ($true) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { throw 'Seed fixture response ended before its header terminator.' }
            if ($line.Length -eq 0) { break }
            $headers.Add($line)
            if ($line -match '^Content-Length:\s*(?<length>[0-9]+)$') {
                $contentLength = [int]$Matches['length']
            }
        }

        $bodyBuilder = New-Object Text.StringBuilder
        if ($ExpectBody) {
            for ($index = 0; $index -lt $contentLength; $index++) {
                $value = $reader.Read()
                if ($value -lt 0) { throw 'Seed fixture response ended before Content-Length characters were available.' }
                [void]$bodyBuilder.Append([char]$value)
            }
        }

        $crlf = [char]13 + [char]10
        return $status + $crlf + ([string]::Join($crlf, $headers.ToArray())) + $crlf + $crlf + $bodyBuilder.ToString()
    }
    finally { $reader.Dispose() }
}

function Invoke-EzVmSeedHttpFixture {
    param([object]$Server, [string]$RequestLine)

    $client = New-Object Net.Sockets.TcpClient
    $stream = $null
    try {
        $client.Connect('127.0.0.1', $Server.Port)
        $stream = $client.GetStream()
        $crlf = [char]13 + [char]10
        $request = $RequestLine + $crlf + 'Host: seed.local' + $crlf + 'Connection: keep-alive' + $crlf + $crlf
        $bytes = [Text.Encoding]::ASCII.GetBytes($request)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        $deadline = [DateTime]::UtcNow.AddSeconds(2)
        $handled = 0
        while ($handled -eq 0 -and [DateTime]::UtcNow -lt $deadline) {
            $handled = Invoke-EzVmSeedServerPending -Server $Server -MaxRequests 1
            if ($handled -eq 0) { Start-Sleep -Milliseconds 10 }
        }
        Assert-EzVmEqual -Actual $handled -Expected 1 -Message 'Seed fixture request was not handled within two seconds.'
        return Read-EzVmSeedHttpFixtureResponse -Stream $stream -ExpectBody:(-not $RequestLine.StartsWith('HEAD ', [StringComparison]::Ordinal))
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        $client.Dispose()
    }
}

Add-EzVmTest -Name 'Seed server: binds exclusively to loopback and serves only active seed files' -ScriptBlock {
    $server = Start-EzVmSeedServer -UserData 'user fixture' -MetaData 'meta fixture' -TimeoutSeconds 30
    try {
        Assert-EzVmEqual -Actual $server.Address -Expected '127.0.0.1'
        $endpoint = [Net.IPEndPoint]$server.Listener.LocalEndpoint
        Assert-EzVmTrue -Condition ([Net.IPAddress]::IsLoopback($endpoint.Address)) -Message 'Seed listener must bind only to loopback.'

        $user = Invoke-EzVmSeedHttpFixture -Server $server -RequestLine 'GET /user-data HTTP/1.1'
        Assert-EzVmTrue -Condition ($user -match '^HTTP/1\.1 200 OK')
        Assert-EzVmTrue -Condition ($user.EndsWith('user fixture', [StringComparison]::Ordinal))

        $meta = Invoke-EzVmSeedHttpFixture -Server $server -RequestLine 'GET /meta-data HTTP/1.1'
        Assert-EzVmTrue -Condition ($meta -match '^HTTP/1\.1 200 OK')
        Assert-EzVmTrue -Condition ($meta.EndsWith('meta fixture', [StringComparison]::Ordinal))

        $vendor = Invoke-EzVmSeedHttpFixture -Server $server -RequestLine 'GET /vendor-data HTTP/1.1'
        Assert-EzVmTrue -Condition ($vendor -match '^HTTP/1\.1 200 OK')
        Assert-EzVmTrue -Condition ($vendor -match 'Content-Length: 0')
        Assert-EzVmTrue -Condition ($vendor -notmatch 'user fixture|meta fixture')

        $network = Invoke-EzVmSeedHttpFixture -Server $server -RequestLine 'GET /network-config HTTP/1.1'
        Assert-EzVmTrue -Condition ($network -match '^HTTP/1\.1 200 OK')
        Assert-EzVmTrue -Condition ($network -match 'Content-Length: 0')

        $unknown = Invoke-EzVmSeedHttpFixture -Server $server -RequestLine 'GET /unexpected HTTP/1.1'
        Assert-EzVmTrue -Condition ($unknown -match '^HTTP/1\.1 404 Not Found')
        Assert-EzVmTrue -Condition ($unknown -notmatch 'user fixture|meta fixture')
        Assert-EzVmEqual -Actual @($server.RequestPaths.ToArray()) -Expected @('/user-data', '/meta-data', '/vendor-data', '/network-config', '<rejected>')
    }
    finally { Stop-EzVmSeedServer -Server $server }
}

Add-EzVmTest -Name 'Seed server: HEAD returns metadata length without leaking the body' -ScriptBlock {
    $server = Start-EzVmSeedServer -UserData 'secretless user fixture' -MetaData 'meta fixture' -TimeoutSeconds 30
    try {
        $response = Invoke-EzVmSeedHttpFixture -Server $server -RequestLine 'HEAD /user-data HTTP/1.1'
        Assert-EzVmTrue -Condition ($response -match '^HTTP/1\.1 200 OK')
        Assert-EzVmTrue -Condition ($response -match 'Content-Length: 23')
        Assert-EzVmTrue -Condition ($response -notmatch 'secretless user fixture')
    }
    finally { Stop-EzVmSeedServer -Server $server }
}

Add-EzVmTest -Name 'Seed server: unsupported methods and malformed paths fail closed' -ScriptBlock {
    $server = Start-EzVmSeedServer -UserData 'u' -MetaData 'm' -TimeoutSeconds 30
    try {
        $post = Invoke-EzVmSeedHttpFixture -Server $server -RequestLine 'POST /user-data HTTP/1.1'
        Assert-EzVmTrue -Condition ($post -match '^HTTP/1\.1 405 Method Not Allowed')
        $query = Invoke-EzVmSeedHttpFixture -Server $server -RequestLine 'GET /user-data?unexpected=1 HTTP/1.1'
        Assert-EzVmTrue -Condition ($query -match '^HTTP/1\.1 404 Not Found')
    }
    finally { Stop-EzVmSeedServer -Server $server }
}

Add-EzVmTest -Name 'Seed server: bounded lifetime expires and closed servers refuse work' -ScriptBlock {
    $server = Start-EzVmSeedServer -UserData 'u' -MetaData 'm' -TimeoutSeconds 1
    try {
        Start-Sleep -Milliseconds 1100
        Assert-EzVmThrows -ScriptBlock { Invoke-EzVmSeedServerPending -Server $server } -MessagePattern 'bounded lifetime' | Out-Null
    }
    finally { Stop-EzVmSeedServer -Server $server }
    Assert-EzVmThrows -ScriptBlock { Invoke-EzVmSeedServerPending -Server $server } -MessagePattern 'already closed' | Out-Null
}


Add-EzVmTest -Name 'Seed server: direct guestfwd connection stays persistent across the complete NoCloud fetch sequence' -ScriptBlock {
    $server = Start-EzVmSeedServer -UserData 'delayed user fixture' -MetaData 'meta fixture' -TimeoutSeconds 30
    $client = New-Object Net.Sockets.TcpClient
    $stream = $null
    try {
        $client.Connect('127.0.0.1', $server.Port)
        $stream = $client.GetStream()

        $clock = [Diagnostics.Stopwatch]::StartNew()
        $handled = Invoke-EzVmSeedServerPending -Server $server -MaxRequests 1
        $clock.Stop()
        Assert-EzVmEqual -Actual $handled -Expected 0
        Assert-EzVmTrue -Condition ($clock.ElapsedMilliseconds -lt 1000) -Message 'An idle QEMU guestfwd socket must not block the seed pump.'
        Assert-EzVmEqual -Actual $server.Clients.Count -Expected 1 -Message 'Idle forwarding socket should remain available for later guest bytes.'

        $crlf = [char]13 + [char]10
        foreach ($case in @(
            [pscustomobject]@{ Path = '/meta-data'; ExpectedBody = 'meta fixture' }
            [pscustomobject]@{ Path = '/user-data'; ExpectedBody = 'delayed user fixture' }
            [pscustomobject]@{ Path = '/vendor-data'; ExpectedBody = '' }
            [pscustomobject]@{ Path = '/network-config'; ExpectedBody = '' }
        )) {
            $request = 'GET ' + $case.Path + ' HTTP/1.1' + $crlf + 'Host: seed.local' + $crlf + 'Connection: keep-alive' + $crlf + $crlf
            $bytes = [Text.Encoding]::ASCII.GetBytes($request)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()

            $deadline = [DateTime]::UtcNow.AddSeconds(2)
            $handled = 0
            while ($handled -eq 0 -and [DateTime]::UtcNow -lt $deadline) {
                $handled = Invoke-EzVmSeedServerPending -Server $server -MaxRequests 1
                if ($handled -eq 0) { Start-Sleep -Milliseconds 10 }
            }
            Assert-EzVmEqual -Actual $handled -Expected 1 -Message ('Persistent guestfwd request was not handled: ' + $case.Path)
            Assert-EzVmEqual -Actual $server.Clients.Count -Expected 1 -Message 'The direct guestfwd host chardev must stay open across seed requests.'

            $response = Read-EzVmSeedHttpFixtureResponse -Stream $stream
            Assert-EzVmTrue -Condition ($response -match '^HTTP/1\.1 200 OK')
            Assert-EzVmTrue -Condition ($response.EndsWith($case.ExpectedBody, [StringComparison]::Ordinal))
        }

        Assert-EzVmEqual -Actual $server.RequestCount -Expected 4
        Assert-EzVmEqual -Actual @($server.RequestPaths.ToArray()) -Expected @('/meta-data', '/user-data', '/vendor-data', '/network-config')
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        $client.Dispose()
        Stop-EzVmSeedServer -Server $server
    }
}
