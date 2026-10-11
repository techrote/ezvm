function Invoke-EzVmSeedHttpFixture {
    param([object]$Server, [string]$RequestLine)

    $client = New-Object Net.Sockets.TcpClient
    $stream = $null
    $reader = $null
    try {
        $client.Connect('127.0.0.1', $Server.Port)
        $stream = $client.GetStream()
        $crlf = [char]13 + [char]10
        $request = $RequestLine + $crlf + 'Host: seed.local' + $crlf + 'Connection: close' + $crlf + $crlf
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
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $false, 1024, $true)
        return $reader.ReadToEnd()
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
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
        Assert-EzVmEqual -Actual @($server.RequestPaths.ToArray()) -Expected @('/user-data', '/meta-data', '/vendor-data', '/network-config', '/unexpected')
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


Add-EzVmTest -Name 'Seed server: idle guestfwd connection remains non-blocking until request bytes arrive' -ScriptBlock {
    $server = Start-EzVmSeedServer -UserData 'delayed user fixture' -MetaData 'meta fixture' -TimeoutSeconds 30
    $client = New-Object Net.Sockets.TcpClient
    $stream = $null
    $reader = $null
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
        $request = 'GET /user-data HTTP/1.1' + $crlf + 'Host: seed.local' + $crlf + $crlf
        $bytes = [Text.Encoding]::ASCII.GetBytes($request)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()

        $deadline = [DateTime]::UtcNow.AddSeconds(2)
        $handled = 0
        while ($handled -eq 0 -and [DateTime]::UtcNow -lt $deadline) {
            $handled = Invoke-EzVmSeedServerPending -Server $server -MaxRequests 1
            if ($handled -eq 0) { Start-Sleep -Milliseconds 10 }
        }
        Assert-EzVmEqual -Actual $handled -Expected 1
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $false, 1024, $true)
        $response = $reader.ReadToEnd()
        Assert-EzVmTrue -Condition ($response -match '^HTTP/1\.1 200 OK')
        Assert-EzVmTrue -Condition ($response.EndsWith('delayed user fixture', [StringComparison]::Ordinal))
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
        $client.Dispose()
        Stop-EzVmSeedServer -Server $server
    }
}
