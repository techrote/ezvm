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
        $null = Invoke-EzVmSeedServerPending -Server $Server -MaxRequests 1
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

        $unknown = Invoke-EzVmSeedHttpFixture -Server $server -RequestLine 'GET /vendor-data HTTP/1.1'
        Assert-EzVmTrue -Condition ($unknown -match '^HTTP/1\.1 404 Not Found')
        Assert-EzVmTrue -Condition ($unknown -notmatch 'user fixture|meta fixture')
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
