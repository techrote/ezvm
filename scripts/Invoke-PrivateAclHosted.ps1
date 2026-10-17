#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet(5, 7)][int]$ExpectedMajor,
    [Parameter(Mandatory = $true)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
# This fixture is never an owner-workstation setup command. GitHub discards its
# host after the job. Only a freshly named local test account is created/removed.
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or
    [Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'This account fixture runs only on disposable GitHub-hosted Windows runners.' }
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$head = ((& git -C $root rev-parse HEAD) -join '').Trim()
if ($LASTEXITCODE -ne 0 -or $head -cnotmatch '^[a-f0-9]{40}$') { throw 'Cannot identify the exact candidate.' }
$state = @(& git -C $root status --porcelain --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $state.Count) { throw 'Hosted ACL fixture requires a clean source checkout.' }
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) { throw 'Hosted ACL evidence destination must be new.' }
[void][IO.Directory]::CreateDirectory($output)
$lease = [Guid]::NewGuid().ToString('N')
$fixture = Join-Path $env:PUBLIC ('ezvm acl fixture ' + $lease)
$account = $null
$child = $null
$result = [ordered]@{ schemaVersion = 1; sourceCommit = $head; childExitCode = $null; childExited = $false;
    temporaryAccountRemoved = $false; fixtureRemoved = $false; reason = '' }
try {
    if (Test-Path -LiteralPath $fixture) { throw 'The fresh hosted fixture path already exists.' }
    [void][IO.Directory]::CreateDirectory($fixture)
    $password = ConvertTo-SecureString ([Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N') + '!aA7') -AsPlainText -Force
    $account = New-LocalUser -Name ('ezvmacl' + $lease.Substring(0, 12)) -Password $password -AccountExpires ([DateTime]::Now.AddHours(2)) -Description 'Disposable hosted EzVM ACL test fixture'
    $usersSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
    if (@(Get-LocalGroupMember -SID $usersSid | Where-Object { $_.SID.Value -ceq $account.SID.Value }).Count -eq 0) {
        Add-LocalGroupMember -SID $usersSid -Member $account
    }
    # Give only the fixture account, current runner and SYSTEM access to this new
    # fixture tree. This grants file rights, not account/token privileges.
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @($account.SID, [Security.Principal.WindowsIdentity]::GetCurrent().User, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))
    }
    ([IO.DirectoryInfo]::new($fixture)).SetAccessControl($acl)
    $bundle = Join-Path $fixture 'source.bundle'
    & git -C $root bundle create $bundle HEAD
    if ($LASTEXITCODE -ne 0) { throw 'Could not stage the immutable public source bundle.' }
    $candidate = Join-Path $fixture 'candidate'
    $baseline = Join-Path $fixture 'baseline'
    $evidence = Join-Path $fixture 'evidence'
    $testTemp = Join-Path $fixture 'test temporary files'
    [void][IO.Directory]::CreateDirectory($testTemp)
    $executable = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    if ($ExpectedMajor -eq 7) { $executable = & (Join-Path $PSScriptRoot 'Install-TestPowerShell.ps1') -DestinationRoot $fixture }
    $git = (Get-Command git -CommandType Application -ErrorAction Stop).Source
    function ConvertTo-AclFixtureLiteral { param([string]$Value) return ("'" + $Value.Replace("'", "''") + "'") }
    $command = @(
        '$ErrorActionPreference = ''Stop''',
        ('$env:TEMP = ' + (ConvertTo-AclFixtureLiteral $testTemp)),
        '$env:TMP = $env:TEMP',
        ('& ' + (ConvertTo-AclFixtureLiteral $git) + ' clone --no-checkout ' + (ConvertTo-AclFixtureLiteral $bundle) + ' ' + (ConvertTo-AclFixtureLiteral $candidate)),
        'if ($LASTEXITCODE -ne 0) { throw ''Candidate clone failed.'' }',
        ('& ' + (ConvertTo-AclFixtureLiteral $git) + ' -C ' + (ConvertTo-AclFixtureLiteral $candidate) + ' checkout --detach ' + $head),
        'if ($LASTEXITCODE -ne 0) { throw ''Candidate checkout failed.'' }',
        ('& ' + (ConvertTo-AclFixtureLiteral $git) + ' clone --no-checkout ' + (ConvertTo-AclFixtureLiteral $bundle) + ' ' + (ConvertTo-AclFixtureLiteral $baseline)),
        'if ($LASTEXITCODE -ne 0) { throw ''Baseline clone failed.'' }',
        ('& ' + (ConvertTo-AclFixtureLiteral $git) + ' -C ' + (ConvertTo-AclFixtureLiteral $baseline) + ' checkout --detach d5265c804d0d8494d8171482a85aca563b181e05'),
        'if ($LASTEXITCODE -ne 0) { throw ''Baseline checkout failed.'' }',
        ('& ' + (ConvertTo-AclFixtureLiteral (Join-Path $candidate 'scripts/Invoke-PrivateAclQualification.ps1')) +
            ' -BaselineRoot ' + (ConvertTo-AclFixtureLiteral $baseline) + ' -ExpectedCommit ' + $head +
            ' -ExpectedMajor ' + $ExpectedMajor + ' -OutputDirectory ' + (ConvertTo-AclFixtureLiteral $evidence)),
        'exit $LASTEXITCODE'
    ) -join [Environment]::NewLine
    # CreateProcessWithLogonW limits its command line to 1024 characters. The
    # multi-checkout command exceeded that bound when passed as EncodedCommand.
    # This script contains only public source identities and owned fixture paths;
    # the account credential stays exclusively in the in-memory PSCredential.
    $launcher = Join-Path $fixture 'launch-standard-user.ps1'
    [IO.File]::WriteAllText($launcher, $command, (New-Object Text.UTF8Encoding($false)))
    $launchArguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $launcher + '"'
    if (($executable.Length + $launchArguments.Length + 4) -gt 1024) { throw 'Standard-user fixture launch exceeds the native command-line bound.' }
    $credential = [Management.Automation.PSCredential]::new(($env:COMPUTERNAME + '\' + $account.Name), $password)
    $child = Start-Process -FilePath $executable -ArgumentList $launchArguments -Credential $credential -LoadUserProfile -WorkingDirectory $fixture -RedirectStandardOutput (Join-Path $output 'process.stdout.log') -RedirectStandardError (Join-Path $output 'process.stderr.log') -PassThru
    if (-not $child.WaitForExit(600000)) {
        # The retained Process handle identifies this one owned child; no PID
        # search, wildcard termination, elevation or retry with privileges.
        $child.Kill()
        $result.childExited = $child.WaitForExit(5000)
        throw 'Standard-user ACL qualification exceeded its ten-minute wall.'
    }
    $result.childExited = $true
    $result.childExitCode = $child.ExitCode
    if (Test-Path -LiteralPath $evidence -PathType Container) {
        foreach ($name in @('receipt.json', 'fixed-suite.log')) {
            $path = Join-Path $evidence $name
            if (Test-Path -LiteralPath $path -PathType Leaf) { Copy-Item -LiteralPath $path -Destination (Join-Path $output $name) }
        }
    }
    if ($child.ExitCode -ne 0) { throw ('Standard-user child failed with exit code ' + $child.ExitCode + '; inspect its retained logs/receipt.') }
    $receipt = Get-Content -LiteralPath (Join-Path $output 'receipt.json') -Raw | ConvertFrom-Json
    if ($receipt.outcome -cne 'pass' -or $receipt.exitCode -ne 0 -or -not $receipt.sourceUnchanged -or $receipt.candidate.commit -cne $head) { throw 'Child receipt did not establish exact-source ACL success.' }
}
catch { $result.reason = $_.Exception.Message }
finally {
    if ($null -ne $child) { $child.Dispose() }
    if ($null -ne $account) {
        try {
            Remove-LocalUser -SID $account.SID -ErrorAction Stop
            if (@(Get-LocalUser | Where-Object { $_.SID.Value -ceq $account.SID.Value }).Count -ne 0) { throw 'Temporary account still exists.' }
            $result.temporaryAccountRemoved = $true
        }
        catch { $result.reason += (' Account cleanup failed: ' + $_.Exception.Message) }
    }
    try {
        # Public source bundle, cloned sources and synthetic tests only. The
        # product tree guard refuses redirected or unbounded leftovers.
        # A failed/interrupted full suite may have retained lightweight children.
        # Preserve that fixture for this disposable host's teardown; do not
        # delete underneath descendants whose ownership is unresolved.
        if ($null -ne $child -and (-not $result.childExited -or $result.childExitCode -ne 0)) {
            throw 'Failed child fixture is quarantined until disposable host teardown.'
        }
        . (Join-Path $root 'src/EzVm/Security.ps1')
        if (Test-Path -LiteralPath $fixture) { Remove-EzVmSafeTree -Path $fixture }
        $result.fixtureRemoved = -not (Test-Path -LiteralPath $fixture)
    }
    catch { $result.reason += (' Fixture cleanup failed: ' + $_.Exception.Message) }
    [IO.File]::WriteAllText((Join-Path $output 'host-fixture.json'), ($result | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
}
if ($result.reason -or -not $result.childExited -or -not $result.temporaryAccountRemoved -or -not $result.fixtureRemoved) { throw ('Hosted ACL fixture failed: ' + $result.reason) }
Write-Host ('PASS standard-user ACL qualification; candidate=' + $head + '; PowerShell major=' + $ExpectedMajor)
