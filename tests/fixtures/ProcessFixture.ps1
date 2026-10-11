# Output uses Console streams, independently of PowerShell's preference variables.
param(
    [ValidateSet('nonzero', 'streams', 'sleep', 'directory', 'input')]
    [string] $Mode = 'nonzero',
    [string] $MarkerPath
)

[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
switch ($Mode) {
    'nonzero' {
        [Console]::Out.Write('stdout-' + [char] 0x03BB)
        [Console]::Error.Write('stderr-' + [char] 0x65E5)
        exit 23
    }
    'streams' {
        # More than typical pipe capacity on each stream; reading one stream to
        # completion before draining the other would deadlock this child.
        $stdoutBlock = 'O' * 4096
        $stderrBlock = 'E' * 4096
        foreach ($index in 1..64) {
            [Console]::Out.Write($stdoutBlock)
            [Console]::Error.Write($stderrBlock)
        }
        exit 0
    }
    'sleep' {
        if (-not [string]::IsNullOrEmpty($MarkerPath)) {
            [System.IO.File]::WriteAllText($MarkerPath, [string] $PID)
        }
        Start-Sleep -Seconds 30
        exit 0
    }
    'directory' {
        [Console]::Out.Write([Environment]::CurrentDirectory)
        exit 0
    }
    'input' {
        [Console]::Out.Write([Console]::In.ReadToEnd())
        exit 0
    }
}
