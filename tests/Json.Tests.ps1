Add-EzVmTest -Name 'JSON creates and replaces versioned state in a path with spaces' -ScriptBlock {
    $directory = New-EzVmTestDirectory -Prefix 'json roundtrip'
    try {
        $path = Join-Path $directory 'state with spaces.json'
        $text = 'VM ' + [char] 0x03BB + ' ' + [char] 0x65E5
        $inputValue = [ordered] @{
            schemaVersion = 1
            name = $text
            enabled = $true
            optional = $null
            empty = @()
            nested = [pscustomobject] @{ values = @(1, 'two', $false) }
        }
        $output = @(Write-EzVmJson -Path $path -Value $inputValue)
        Assert-EzVmEqual -Actual $output.Count -Expected 0
        $actual = Read-EzVmJson -Path $path
        Assert-EzVmEqual -Actual $actual.schemaVersion -Expected 1
        Assert-EzVmEqual -Actual $actual.name -Expected $text
        Assert-EzVmEqual -Actual $actual.enabled -Expected $true
        Assert-EzVmTrue -Condition ($null -eq $actual.optional) -Message 'JSON null must round-trip.'
        Assert-EzVmEqual -Actual @($actual.empty).Count -Expected 0
        Assert-EzVmEqual -Actual $actual.nested.values.Count -Expected 3
        Assert-EzVmEqual -Actual $actual.nested.values[1] -Expected 'two'

        Write-EzVmJson -Path $path -Value @{ schemaVersion = 1; name = 'replacement' }
        Assert-EzVmEqual -Actual (Read-EzVmJson -Path $path).name -Expected 'replacement'
        Assert-EzVmEqual -Actual ([System.IO.Directory]::GetFiles($directory).Length) -Expected 1
        $bytes = [System.IO.File]::ReadAllBytes($path)
        Assert-EzVmTrue -Condition ([BitConverter]::ToString($bytes[0..2]) -ne 'EF-BB-BF') -Message 'State is written as UTF-8 without a BOM.'
    }
    finally { Remove-EzVmTestDirectory -Path $directory }
}

Add-EzVmTest -Name 'JSON resolves relative paths against the PowerShell location' -ScriptBlock {
    $directory = New-EzVmTestDirectory -Prefix 'json location'
    Push-Location -LiteralPath $directory
    try {
        Write-EzVmJson -Path 'relative.json' -Value @{ schemaVersion = 1; name = 'relative' }
        Assert-EzVmTrue -Condition ([System.IO.File]::Exists((Join-Path $directory 'relative.json'))) -Message 'The file must use the PowerShell location.'
        Assert-EzVmEqual -Actual (Read-EzVmJson -Path 'relative.json').name -Expected 'relative'
    }
    finally {
        Pop-Location
        Remove-EzVmTestDirectory -Path $directory
    }
}

Add-EzVmTest -Name 'JSON round-trips a literal Keys member in hashtables and ordered dictionaries' -ScriptBlock {
    $directory = New-EzVmTestDirectory -Prefix 'json dictionary Keys'
    try {
        $path = Join-Path $directory 'state.json'
        $values = @(
            @{ schemaVersion = 1; Keys = @('first', 'second'); payload = @{ value = 'hashtable' } },
            [ordered] @{ schemaVersion = 1; Keys = @('first', 'second'); payload = @{ value = 'ordered dictionary' } }
        )
        foreach ($value in $values) {
            Write-EzVmJson -Path $path -Value $value
            $actual = Read-EzVmJson -Path $path
            Assert-EzVmEqual -Actual $actual.schemaVersion -Expected 1
            Assert-EzVmEqual -Actual $actual.Keys.Count -Expected 2
            Assert-EzVmEqual -Actual $actual.Keys[0] -Expected 'first'
            Assert-EzVmEqual -Actual $actual.Keys[1] -Expected 'second'
            Assert-EzVmEqual -Actual $actual.payload.value -Expected $value['payload']['value']
        }
    }
    finally { Remove-EzVmTestDirectory -Path $directory }
}

Add-EzVmTest -Name 'JSON literal Keys members cannot hide unsupported or cyclic payloads from validation' -ScriptBlock {
    $directory = New-EzVmTestDirectory -Prefix 'json Keys validation'
    try {
        $path = Join-Path $directory 'state.json'
        $original = [System.Text.Encoding]::UTF8.GetBytes('{"schemaVersion":1,"value":"preserve exactly"}')
        [System.IO.File]::WriteAllBytes($path, $original)
        $cycle = @{}
        $cycle['self'] = $cycle
        $values = @(
            @{ schemaVersion = 1; Keys = @('schemaVersion'); payload = { 'unsupported script' } },
            [ordered] @{ schemaVersion = 1; Keys = @('schemaVersion'); payload = { 'unsupported script' } },
            @{ schemaVersion = 1; Keys = @('schemaVersion'); payload = $cycle },
            [ordered] @{ schemaVersion = 1; Keys = @('schemaVersion'); payload = $cycle }
        )
        foreach ($value in $values) {
            Assert-EzVmThrows -ScriptBlock { Write-EzVmJson -Path $path -Value $value } -MessagePattern 'unsupported type|reference cycle'
            Assert-EzVmEqual -Actual ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($path))) -Expected ([Convert]::ToBase64String($original))
            Assert-EzVmEqual -Actual ([System.IO.Directory]::GetFiles($directory).Length) -Expected 1
        }
    }
    finally { Remove-EzVmTestDirectory -Path $directory }
}

Add-EzVmTest -Name 'JSON rejects malformed documents and non-object roots' -ScriptBlock {
    $directory = New-EzVmTestDirectory -Prefix 'json invalid'
    try {
        $path = Join-Path $directory 'invalid.json'
        $documents = @('', 'null', 'true', '42', '"text"', '[]', '[{"schemaVersion":1}]', '{"schemaVersion":')
        foreach ($document in $documents) {
            [System.IO.File]::WriteAllText($path, $document)
            Assert-EzVmThrows -ScriptBlock { Read-EzVmJson -Path $path } -MessagePattern 'JSON'
        }
        Assert-EzVmThrows -ScriptBlock { Read-EzVmJson -Path (Join-Path $directory 'missing.json') } -MessagePattern 'exists.*readable'
    }
    finally { Remove-EzVmTestDirectory -Path $directory }
}

Add-EzVmTest -Name 'JSON requires an exact integer schema version' -ScriptBlock {
    $directory = New-EzVmTestDirectory -Prefix 'json schema'
    try {
        $path = Join-Path $directory 'state.json'
        $documents = @('{}', '{"SchemaVersion":1}', '{"schemaVersion":null}', '{"schemaVersion":"1"}', '{"schemaVersion":true}', '{"schemaVersion":1.0}', '{"schemaVersion":1.5}', '{"schemaVersion":2}')
        foreach ($document in $documents) {
            [System.IO.File]::WriteAllText($path, $document)
            Assert-EzVmThrows -ScriptBlock { Read-EzVmJson -Path $path } -MessagePattern 'schemaVersion'
        }
        Write-EzVmJson -Path $path -Value @{ schemaVersion = 2; name = 'explicit schema' } -SchemaVersion 2
        Assert-EzVmEqual -Actual (Read-EzVmJson -Path $path -SchemaVersion 2).name -Expected 'explicit schema'
        Assert-EzVmThrows -ScriptBlock { Read-EzVmJson -Path $path } -MessagePattern 'unsupported schemaVersion'
    }
    finally { Remove-EzVmTestDirectory -Path $directory }
}

Add-EzVmTest -Name 'JSON preserves nested timestamp strings including offsets' -ScriptBlock {
    $directory = New-EzVmTestDirectory -Prefix 'json timestamps'
    try {
        $path = Join-Path $directory 'state.json'
        $offset = '2026-10-11T12:34:56.1234000+02:00'
        $utc = '2026-10-11T10:34:56Z'
        Write-EzVmJson -Path $path -Value @{ schemaVersion = 1; nested = @{ times = @($offset, $utc) } }
        $value = Read-EzVmJson -Path $path
        Assert-EzVmTrue -Condition ($value.nested.times[0] -is [string]) -Message 'Timestamps must remain JSON strings.'
        Assert-EzVmEqual -Actual $value.nested.times[0] -Expected $offset
        Assert-EzVmEqual -Actual $value.nested.times[1] -Expected $utc
        Write-EzVmJson -Path $path -Value $value
        Assert-EzVmEqual -Actual (Read-EzVmJson -Path $path).nested.times[0] -Expected $offset
    }
    finally { Remove-EzVmTestDirectory -Path $directory }
}

Add-EzVmTest -Name 'JSON serialization failures preserve old bytes and create no temporary remnants' -ScriptBlock {
    $directory = New-EzVmTestDirectory -Prefix 'json fail safe'
    try {
        $path = Join-Path $directory 'state.json'
        $original = [System.Text.Encoding]::UTF8.GetBytes("{`n  `"schemaVersion`": 1, `"name`": `"keep exactly`"`n}`n")
        [System.IO.File]::WriteAllBytes($path, $original)
        $cycle = @{ schemaVersion = 1 }
        $cycle['self'] = $cycle
        $tooDeep = @{ schemaVersion = 1 }
        $cursor = $tooDeep
        foreach ($index in 1..66) {
            $cursor['next'] = @{}
            $cursor = $cursor['next']
        }
        $invalidValues = @(
            @{ schemaVersion = '1' },
            @{ schemaVersion = $true },
            @{ schemaVersion = 2 },
            @{ schemaVersion = 1; cannotSerialize = { 'script content' } },
            @{ schemaVersion = 1; invalidNumber = [double]::NaN },
            @{ schemaVersion = 1; timestamp = [datetime]::UtcNow },
            $cycle,
            $tooDeep
        )
        foreach ($value in $invalidValues) {
            Assert-EzVmThrows -ScriptBlock { Write-EzVmJson -Path $path -Value $value } -MessagePattern 'Could not atomically write JSON'
            Assert-EzVmEqual -Actual ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($path))) -Expected ([Convert]::ToBase64String($original))
            Assert-EzVmEqual -Actual ([System.IO.Directory]::GetFiles($directory).Length) -Expected 1
        }
        Assert-EzVmThrows -ScriptBlock { Write-EzVmJson -Path (Join-Path $directory 'new.json') -Value $cycle } -MessagePattern 'cycle'
        Assert-EzVmTrue -Condition (-not [System.IO.File]::Exists((Join-Path $directory 'new.json'))) -Message 'Validation must finish before a new state file is created.'
    }
    finally { Remove-EzVmTestDirectory -Path $directory }
}

Add-EzVmTest -Name 'JSON failed promotion cleans its temporary file and preserves the destination directory' -ScriptBlock {
    $directory = New-EzVmTestDirectory -Prefix 'json promotion failure'
    try {
        $destination = Join-Path $directory 'state.json'
        $null = [System.IO.Directory]::CreateDirectory($destination)
        $sentinel = Join-Path $destination 'preserve.txt'
        [System.IO.File]::WriteAllText($sentinel, 'existing destination')
        Assert-EzVmThrows -ScriptBlock { Write-EzVmJson -Path $destination -Value @{ schemaVersion = 1 } } -MessagePattern 'atomically write'
        Assert-EzVmEqual -Actual ([System.IO.File]::ReadAllText($sentinel)) -Expected 'existing destination'
        Assert-EzVmEqual -Actual ([System.IO.Directory]::GetFiles($directory).Length) -Expected 0
        Assert-EzVmThrows -ScriptBlock { Write-EzVmJson -Path (Join-Path (Join-Path $directory 'absent') 'state.json') -Value @{ schemaVersion = 1 } } -MessagePattern 'parent directory'
        Assert-EzVmTrue -Condition (-not [System.IO.Directory]::Exists((Join-Path $directory 'absent'))) -Message 'JSON writes must not create unexpected parent directories.'
    }
    finally { Remove-EzVmTestDirectory -Path $directory }
}

$lockedStateSkip = $null
if (-not $script:EzVmIsWindowsHost) {
    $lockedStateSkip = 'Windows FileShare.None replacement semantics require a Windows host; Windows CI runs this check on both PowerShell versions.'
}
Add-EzVmTest -Name 'JSON locked existing state is preserved byte for byte after replacement failure' -SkipReason $lockedStateSkip -ScriptBlock {
    $directory = New-EzVmTestDirectory -Prefix 'json locked target'
    $lock = $null
    try {
        $path = Join-Path $directory 'state.json'
        $original = [System.Text.Encoding]::UTF8.GetBytes('{"schemaVersion":1,"value":"old bytes"}')
        [System.IO.File]::WriteAllBytes($path, $original)
        $lock = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        Assert-EzVmThrows -ScriptBlock { Write-EzVmJson -Path $path -Value @{ schemaVersion = 1; value = 'replacement' } } -MessagePattern 'atomically write'
        $lock.Dispose()
        $lock = $null
        Assert-EzVmEqual -Actual ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($path))) -Expected ([Convert]::ToBase64String($original))
        Assert-EzVmEqual -Actual ([System.IO.Directory]::GetFiles($directory).Length) -Expected 1
    }
    finally {
        if ($null -ne $lock) { $lock.Dispose() }
        Remove-EzVmTestDirectory -Path $directory
    }
}
