Import-Module (Join-Path $script:EzVmRepositoryRoot 'scripts/RepositoryContract.psm1') -Force -ErrorAction Stop

function Invoke-EzVmFixtureGit {
    param([string]$Root, [string[]]$Arguments)
    $output = @(& git -C $Root @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Fixture Git failed: $($output -join ' ')" }
}

function New-EzVmRepositoryFixture {
    param([switch]$UseCrlf)

    $root = New-EzVmTestDirectory -Prefix 'tracked repository fixture'
    try {
        foreach ($relative in @('.github', '.gitattributes', '.gitignore', 'README.md', 'AGENTS.md', 'docs', 'ezvm.ps1', 'src', 'config', 'manifests', 'guest', 'tests', 'scripts')) {
            Copy-Item -LiteralPath (Join-Path $script:EzVmRepositoryRoot $relative) -Destination $root -Recurse -Force
        }
        if ($UseCrlf) {
            foreach ($file in (Get-ChildItem -LiteralPath $root -File -Recurse -Force)) {
                $content = [IO.File]::ReadAllText($file.FullName).Replace("`r`n", "`n").Replace("`n", "`r`n")
                [IO.File]::WriteAllText($file.FullName, $content, (New-Object Text.UTF8Encoding($false)))
            }
        }
        Invoke-EzVmFixtureGit -Root $root -Arguments @('init', '--quiet')
        Invoke-EzVmFixtureGit -Root $root -Arguments @('config', 'core.autocrlf', 'false')
        # .gitattributes normalizes source text into the index. Allow that intended
        # CRLF conversion without warnings; real whitespace checks remain enabled.
        Invoke-EzVmFixtureGit -Root $root -Arguments @('config', 'core.safecrlf', 'false')
        Invoke-EzVmFixtureGit -Root $root -Arguments @('add', '--all', '--force')
        return $root
    }
    catch {
        Remove-EzVmTestDirectory -Path $root
        throw
    }
}

function Add-EzVmTrackedFixtureFile {
    param([string]$Root, [string]$RelativePath, [string]$Content = 'synthetic fixture')
    $path = Join-Path $Root $RelativePath
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    [IO.File]::WriteAllText($path, $Content, (New-Object Text.UTF8Encoding($false)))
    Invoke-EzVmFixtureGit -Root $Root -Arguments @('add', '--force', '--', $RelativePath)
    return $path
}

Add-EzVmTest -Name 'Repository: a fully tracked source-only checkout satisfies all contract checks' -ScriptBlock {
    $root = New-EzVmRepositoryFixture
    try {
        $result = Test-EzVmRepositoryContract -Root $root
        Assert-EzVmTrue -Condition ($result.TrackedFiles -ge 30)
        Assert-EzVmTrue -Condition ($result.JsonFiles -ge 2)
        Assert-EzVmTrue -Condition ($result.PowerShellFiles -ge 10)
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Repository: ignored untracked runtime state does not contaminate the source check' -ScriptBlock {
    $root = New-EzVmRepositoryFixture
    try {
        $runtime = Join-Path $root 'runtime'
        [void][IO.Directory]::CreateDirectory($runtime)
        [IO.File]::WriteAllText((Join-Path $runtime 'fixture.qcow2'), 'synthetic ignored fixture, not a disk')
        $null = Test-EzVmRepositoryContract -Root $root
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Repository: CRLF materialization normalizes to LF while genuine trailing whitespace still fails' -ScriptBlock {
    $root = New-EzVmRepositoryFixture -UseCrlf
    try {
        $readme = [IO.File]::ReadAllText((Join-Path $root 'README.md'))
        Assert-EzVmTrue -Condition ($readme.Contains("`r`n")) -Message 'The regression fixture must actually contain Windows CRLF bytes.'
        $eol = @(& git -C $root ls-files --eol -- README.md) -join ''
        Assert-EzVmEqual -Actual $LASTEXITCODE -Expected 0
        Assert-EzVmTrue -Condition ($eol -match 'i/lf\s+w/crlf') -Message 'Git must store LF while the fixture working tree retains CRLF.'
        $null = Test-EzVmRepositoryContract -Root $root
        $null = Add-EzVmTrackedFixtureFile -Root $root -RelativePath 'notes/crlf-trailing.txt' -Content "genuine trailing space `r`n"
        Assert-EzVmThrows -ScriptBlock { Test-EzVmRepositoryContract -Root $root } -MessagePattern 'git diff.*check' | Out-Null
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

$forbiddenPaths = @(
    'runtime/readme.txt',
    'nested/RuNtImE/state.txt',
    'nested/.ezvm/state.txt',
    'nested/CACHE/download.txt',
    'artifacts/report.txt',
    'nested/DISK.QCOW2',
    'payload/installer.EXE',
    'payload/library.DLL',
    'payload/source.IMG',
    'payload/runtime.ZIP',
    'payload/runtime.7z',
    'payload/guest.vmdk',
    'credentials/key.PEM',
    'credentials/private.KEY',
    'credentials/id_ed25519',
    'credentials/.env.local'
)
foreach ($forbiddenPath in $forbiddenPaths) {
    Add-EzVmTest -Name ('Repository: rejects force-added ' + $forbiddenPath) -Data $forbiddenPath -ScriptBlock {
        param($relative)
        $root = New-EzVmRepositoryFixture
        try {
            $null = Add-EzVmTrackedFixtureFile -Root $root -RelativePath $relative
            Assert-EzVmThrows -ScriptBlock { Test-EzVmRepositoryContract -Root $root } -MessagePattern 'Forbidden.*tracked' | Out-Null
        }
        finally { Remove-EzVmTestDirectory -Path $root }
    }
}

Add-EzVmTest -Name 'Repository: private-key headers cannot be hidden in an innocuous text filename' -ScriptBlock {
    $root = New-EzVmRepositoryFixture
    try {
        # Assemble only synthetic headers in temporary fixtures; no credential is stored in source.
        $header = '-----BEGIN ' + 'OPENSSH PRIVATE KEY-----'
        $null = Add-EzVmTrackedFixtureFile -Root $root -RelativePath 'notes/innocent.txt' -Content ($header + "`nsynthetic fixture`n")
        Assert-EzVmThrows -ScriptBlock { Test-EzVmRepositoryContract -Root $root } -MessagePattern 'Private-key content' | Out-Null
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Repository: renamed executable content cannot hide behind a text extension' -ScriptBlock {
    $root = New-EzVmRepositoryFixture
    try {
        $path = Add-EzVmTrackedFixtureFile -Root $root -RelativePath 'notes/payload.txt'
        [IO.File]::WriteAllBytes($path, [byte[]]@(0x4d, 0x5a, 0, 0, 1, 2, 3, 4))
        Invoke-EzVmFixtureGit -Root $root -Arguments @('add', '--force', '--', 'notes/payload.txt')
        Assert-EzVmThrows -ScriptBlock { Test-EzVmRepositoryContract -Root $root } -MessagePattern 'binary/archive/disk payload' | Out-Null
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Repository: all tracked JSON files are parsed including nested uppercase extensions' -ScriptBlock {
    $root = New-EzVmRepositoryFixture
    try {
        $null = Add-EzVmTrackedFixtureFile -Root $root -RelativePath 'notes/nested/BROKEN.JSON' -Content '{"broken":'
        Assert-EzVmThrows -ScriptBlock { Test-EzVmRepositoryContract -Root $root } -MessagePattern 'JSON cannot be parsed' | Out-Null
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Repository: an empty tracked JSON file is invalid' -ScriptBlock {
    $root = New-EzVmRepositoryFixture
    try {
        $null = Add-EzVmTrackedFixtureFile -Root $root -RelativePath 'notes/empty.json' -Content ''
        Assert-EzVmThrows -ScriptBlock { Test-EzVmRepositoryContract -Root $root } -MessagePattern 'JSON file is empty' | Out-Null
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

foreach ($extension in @('ps1', 'psm1', 'psd1')) {
    Add-EzVmTest -Name ('Repository: parses every tracked .' + $extension + ' source') -Data $extension -ScriptBlock {
        param($sourceExtension)
        $root = New-EzVmRepositoryFixture
        try {
            $null = Add-EzVmTrackedFixtureFile -Root $root -RelativePath ('notes/broken.' + $sourceExtension) -Content 'function Broken { '
            Assert-EzVmThrows -ScriptBlock { Test-EzVmRepositoryContract -Root $root } -MessagePattern 'PowerShell source cannot be parsed' | Out-Null
        }
        finally { Remove-EzVmTestDirectory -Path $root }
    }
}

Add-EzVmTest -Name 'Repository: authority files must be tracked even when present on disk' -ScriptBlock {
    $root = New-EzVmRepositoryFixture
    try {
        Invoke-EzVmFixtureGit -Root $root -Arguments @('rm', '--cached', '--quiet', '--', 'docs/rag/08-TESTING-CI-RELEASE.md')
        Assert-EzVmThrows -ScriptBlock { Test-EzVmRepositoryContract -Root $root } -MessagePattern 'Missing or untracked.*08-TESTING' | Out-Null
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Repository: missing working-tree source files are detected' -ScriptBlock {
    $root = New-EzVmRepositoryFixture
    try {
        Remove-Item -LiteralPath (Join-Path $root 'src/EzVm/Paths.ps1') -Force
        Assert-EzVmThrows -ScriptBlock { Test-EzVmRepositoryContract -Root $root } -MessagePattern 'Tracked source file is missing' | Out-Null
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Repository: incorrect and duplicate issue catalogue mappings fail' -ScriptBlock {
    $root = New-EzVmRepositoryFixture
    try {
        $path = Join-Path $root 'docs/programme/IMPLEMENTATION-PROGRAMME.md'
        $programme = [IO.File]::ReadAllText($path)
        [IO.File]::WriteAllText($path, $programme.Replace('https://github.com/techrote/ezvm/issues/13)', 'https://github.com/techrote/ezvm/issues/99)'))
        Assert-EzVmThrows -ScriptBlock { Test-EzVmRepositoryContract -Root $root } -MessagePattern 'coherent issue catalogue row.*EZVM-012' | Out-Null
        $row = [regex]::Match($programme, '(?m)^\| EZVM-012 .*').Value
        Assert-EzVmTrue -Condition (-not [string]::IsNullOrEmpty($row))
        [IO.File]::WriteAllText($path, ($programme + "`n" + $row + "`n"))
        Assert-EzVmThrows -ScriptBlock { Test-EzVmRepositoryContract -Root $root } -MessagePattern 'coherent issue catalogue row.*EZVM-012' | Out-Null
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Repository: staged whitespace errors remain a failing contract check' -ScriptBlock {
    $root = New-EzVmRepositoryFixture
    try {
        $null = Add-EzVmTrackedFixtureFile -Root $root -RelativePath 'notes/trailing.txt' -Content "trailing space `n"
        Assert-EzVmThrows -ScriptBlock { Test-EzVmRepositoryContract -Root $root } -MessagePattern 'git diff.*check' | Out-Null
    }
    finally { Remove-EzVmTestDirectory -Path $root }
}

Add-EzVmTest -Name 'Repository: the checked-in harness has an explicit matching version and no external dependencies' -ScriptBlock {
    $tooling = Get-Content -LiteralPath (Join-Path $script:EzVmRepositoryRoot 'tests/tooling.json') -Raw | ConvertFrom-Json
    Assert-EzVmEqual -Actual $tooling.schemaVersion -Expected 1
    Assert-EzVmEqual -Actual $tooling.version -Expected $script:EzVmTestHarnessVersion
    Assert-EzVmEqual -Actual @($tooling.externalDependencies).Count -Expected 0
}

Add-EzVmTest -Name 'Harness: an empty suite and an actual failed assertion both exit nonzero' -ScriptBlock {
    $harnessPath = (Join-Path $script:EzVmRepositoryRoot 'tests/TestHarness.ps1').Replace("'", "''")
    $empty = Invoke-EzVmTestPowerShell -CommandText ('. ''' + $harnessPath + '''; Invoke-EzVmTestSuite')
    Assert-EzVmTrue -Condition ($empty.ExitCode -ne 0) -Message 'An empty suite returned success.'
    $failed = Invoke-EzVmTestPowerShell -CommandText ('. ''' + $harnessPath + '''; Add-EzVmTest -Name ''intentional failure'' -ScriptBlock { Assert-EzVmEqual -Actual 1 -Expected 2 }; Invoke-EzVmTestSuite')
    Assert-EzVmTrue -Condition ($failed.ExitCode -ne 0) -Message 'A failed assertion returned success.'
    Assert-EzVmTrue -Condition ($failed.StandardOutput -match '0 passed, 1 failed')
}
