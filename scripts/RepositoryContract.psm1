Set-StrictMode -Version 2.0

function Invoke-EzVmRepositoryGit {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $output = @(& git -C $Root -c core.quotepath=false @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Repository validation could not run git $($Arguments -join ' '): $($output -join [Environment]::NewLine)"
    }
    return $output
}

function Test-EzVmRepositoryContract {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Root)

    $rootPath = [IO.Path]::GetFullPath($Root)
    if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) {
        throw "Repository root does not exist: $rootPath"
    }
    if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
        throw 'Repository validation requires Git. Install Git and run scripts/Test-Repository.ps1 again.'
    }
    $gitRoot = (Invoke-EzVmRepositoryGit -Root $rootPath -Arguments @('rev-parse', '--show-toplevel')) -join ''
    $comparison = [StringComparison]::Ordinal
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { $comparison = [StringComparison]::OrdinalIgnoreCase }
    if (-not [string]::Equals([IO.Path]::GetFullPath($gitRoot), $rootPath, $comparison)) {
        throw "Validation root must be the Git repository root, not a nested directory: $rootPath"
    }

    # NUL delimiting preserves spaces, Unicode and unusual tracked filenames.
    $trackedText = (Invoke-EzVmRepositoryGit -Root $rootPath -Arguments @('ls-files', '--cached', '-z')) -join "`n"
    $tracked = @($trackedText.Split([char[]]@([char]0), [StringSplitOptions]::RemoveEmptyEntries))
    if ($tracked.Count -eq 0) { throw 'The repository has no tracked files.' }
    $trackedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($file in $tracked) { [void]$trackedSet.Add($file) }

    $required = @(
        'README.md',
        'AGENTS.md',
        '.gitattributes',
        '.gitignore',
        '.github/workflows/ci.yml',
        'docs/programme/IMPLEMENTATION-PROGRAMME.md',
        'docs/rag/README.md',
        'docs/rag/00-PROJECT-CHARTER.md',
        'docs/rag/01-ARCHITECTURE.md',
        'docs/rag/02-HOST-QEMU-CONTRACT.md',
        'docs/rag/03-QCOW2-STATE-CONTRACT.md',
        'docs/rag/04-GUEST-BOOTSTRAP-CONTRACT.md',
        'docs/rag/05-NETWORK-SSH-CONTRACT.md',
        'docs/rag/06-SECURITY-PORTABILITY-CONTRACT.md',
        'docs/rag/07-CLI-STATE-CONTRACT.md',
        'docs/rag/08-TESTING-CI-RELEASE.md',
        'ezvm.ps1',
        'src/EzVm/EzVm.psd1',
        'src/EzVm/EzVm.psm1',
        'config/defaults.json',
        'manifests/qemu-windows.json',
        'tests/Run-Tests.ps1',
        'tests/TestHarness.ps1',
        'tests/tooling.json',
        'scripts/Test-Repository.ps1',
        'scripts/RepositoryContract.psm1'
    )
    foreach ($path in $required) {
        if (-not $trackedSet.Contains($path) -or -not (Test-Path -LiteralPath (Join-Path $rootPath $path) -PathType Leaf)) {
            throw "Missing or untracked required repository authority/source file: $path"
        }
    }

    $programme = [IO.File]::ReadAllText((Join-Path $rootPath 'docs/programme/IMPLEMENTATION-PROGRAMME.md'))
    for ($number = 1; $number -le 12; $number++) {
        $code = 'EZVM-{0:d3}' -f $number
        $rowPattern = '(?m)^\|\s*' + [regex]::Escape($code) + '\s*\|[^\r\n]*?\(https://github\.com/techrote/ezvm/issues/(?<issue>[0-9]+)\)'
        $rows = [regex]::Matches($programme, $rowPattern)
        if ($rows.Count -ne 1 -or [int]$rows[0].Groups['issue'].Value -ne ($number + 1)) {
            throw "Programme must contain one coherent issue catalogue row for $code linked to issue #$($number + 1)."
        }
    }

    $forbiddenDirectory = '(?i)(^|/)(runtime|\.ezvm|cache|artifacts|TestResults|coverage)(/|$)'
    $forbiddenExtension = '(?i)\.(qcow2?|img|iso|vhdx?|vmdk|vdi|raw|ova|ovf|dmg|exe|msi|msix|msp|dll|so(?:\.[0-9.]+)?|dylib|bin|zip|7z|rar|tar|tgz|gz|bz2|xz|zst|pem|key|p12|pfx|ppk|token|pid|sock)$'
    $forbiddenName = '(?i)(^|/)(\.env(?:\..*)?|id_(rsa|dsa|ecdsa|ed25519)|ssh_host_[^/]+_key)$'
    $privateKeyContent = '(?m)^\s*-{4,5}\s*BEGIN (?:(?:RSA|DSA|EC|OPENSSH|ENCRYPTED) )?PRIVATE KEY\s*-{4,5}|^PuTTY-User-Key-File-[23]:'
    $jsonCount = 0
    $powerShellCount = 0

    foreach ($file in $tracked) {
        if ($file -match $forbiddenDirectory -or $file -match $forbiddenExtension -or $file -match $forbiddenName) {
            throw "Forbidden generated/binary/secret-like artifact is tracked: $file. Remove it from Git and keep generated state under runtime/."
        }
        $absolutePath = Join-Path $rootPath $file
        if (-not (Test-Path -LiteralPath $absolutePath -PathType Leaf)) {
            throw "Tracked source file is missing from the working tree: $file"
        }
        $item = Get-Item -LiteralPath $absolutePath -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Tracked symbolic links are outside the repository source contract: $file"
        }
        if ($item.Length -gt 5MB) {
            throw "Tracked source exceeds the 5 MiB source-file limit: $file. Keep large generated payloads out of Git."
        }
        $bytes = [IO.File]::ReadAllBytes($absolutePath)
        $signature = [BitConverter]::ToString($bytes, 0, [Math]::Min(8, $bytes.Length))
        if ($signature -match '^(4D-5A|7F-45-4C-46|51-46-49-FB|50-4B-03-04|37-7A-BC-AF-27-1C|52-61-72-21-1A-07|1F-8B)') {
            throw "Tracked binary/archive/disk payload has an executable or runtime signature: $file"
        }
        $content = [IO.File]::ReadAllText($absolutePath)
        if ($content.IndexOf([char]0) -ge 0) {
            throw "Tracked source contains binary NUL data: $file"
        }
        if ($content -match $privateKeyContent) {
            throw "Private-key content is tracked in $file. Remove it from Git and replace any exposed credential."
        }
        $extension = [IO.Path]::GetExtension($file)
        if ($extension -ieq '.json') {
            if ([string]::IsNullOrWhiteSpace($content)) { throw "Tracked JSON file is empty: $file" }
            try { $null = ConvertFrom-Json -InputObject $content -ErrorAction Stop }
            catch { throw "Tracked JSON cannot be parsed: $file. $($_.Exception.Message)" }
            $jsonCount++
        }
        if ($extension -iin @('.ps1', '.psm1', '.psd1')) {
            $tokens = $null
            $parseErrors = $null
            $null = [Management.Automation.Language.Parser]::ParseFile($absolutePath, [ref]$tokens, [ref]$parseErrors)
            if (@($parseErrors).Count -ne 0) {
                throw "Tracked PowerShell source cannot be parsed by PowerShell $($PSVersionTable.PSVersion): $file. $($parseErrors[0].Message)"
            }
            $powerShellCount++
        }
    }

    $null = & git -C $rootPath rev-parse --verify --quiet HEAD
    if ($LASTEXITCODE -eq 0) {
        $null = Invoke-EzVmRepositoryGit -Root $rootPath -Arguments @('show', '--format=', '--check', 'HEAD')
    }
    $null = Invoke-EzVmRepositoryGit -Root $rootPath -Arguments @('diff', '--check')
    $null = Invoke-EzVmRepositoryGit -Root $rootPath -Arguments @('diff', '--cached', '--check')
    return [pscustomobject]@{
        TrackedFiles = $tracked.Count
        JsonFiles = $jsonCount
        PowerShellFiles = $powerShellCount
    }
}

Export-ModuleMember -Function Test-EzVmRepositoryContract
