#requires -Version 5.1
# Optional, in-process observation for the full qualification script only.
# Product functions and their original scriptblocks are never edited on disk.

function Write-EzVmQualificationTelemetry {
    param([object]$State, [System.Collections.IDictionary]$Record)
    if ($State.writerFailed) { throw 'Qualification telemetry is incomplete; refusing further observed work.' }
    try {
        $State.sequence++
        $Record.schemaVersion = 1
        $Record.sequence = $State.sequence
        $Record.utc = [DateTime]::UtcNow.ToString('o')
        $Record.elapsedSeconds = $State.clock.Elapsed.TotalSeconds
        $bytes = $State.encoding.GetBytes(($Record | ConvertTo-Json -Depth 10 -Compress) + "`n")
        if ($State.bytesWritten + $bytes.Length -gt $State.maximumBytes) { throw 'Telemetry size bound reached.' }
        $State.stream.Write($bytes, 0, $bytes.Length)
        $State.stream.Flush()
        $State.bytesWritten += $bytes.Length
    }
    catch {
        $State.writerFailed = $true
        throw 'Qualification telemetry could not be written within its bound; evidence is incomplete.'
    }
}

function Start-EzVmQualificationSpan {
    param([object]$State, [string]$Operation, [string]$Category, [hashtable]$Details = @{})
    $State.operationId++
    $parent = $null
    if ($State.stack.Count) { $parent = $State.stack[$State.stack.Count - 1].operationId }
    $totals = @{}
    foreach ($kind in $State.digestTotals.Keys) { $totals[$kind] = $State.digestTotals[$kind].Clone() }
    $span = [pscustomobject]@{ operationId = $State.operationId; parentOperationId = $parent;
        operation = $Operation; category = $Category; started = [Diagnostics.Stopwatch]::GetTimestamp(); digestBefore = $totals }
    & $State.write -State $State -Record ([ordered]@{ event = 'start'; operationId = $span.operationId;
        parentOperationId = $parent; operation = $Operation; category = $Category; details = $Details })
    $State.stack.Add($span)
    return $span
}

function Stop-EzVmQualificationSpan {
    param([object]$State, [object]$Span, [bool]$Failed)
    try {
        if (-not $State.stack.Count -or $State.stack[$State.stack.Count - 1].operationId -ne $Span.operationId) {
            $State.writerFailed = $true
            throw 'Qualification telemetry nesting is incomplete.'
        }
        $State.stack.RemoveAt($State.stack.Count - 1)
        $totals = [ordered]@{}
        foreach ($kind in @('manifest', 'qemu-payload', 'base-image', 'source-image', 'other')) {
            $after = $State.digestTotals[$kind]
            $before = $Span.digestBefore[$kind]
            if ($after.calls -ne $before.calls) {
                $totals[$kind] = [ordered]@{ calls = $after.calls - $before.calls;
                    failedCalls = $after.failedCalls - $before.failedCalls; bytes = $after.bytes - $before.bytes;
                    elapsedSeconds = $after.elapsedSeconds - $before.elapsedSeconds }
            }
        }
        & $State.write -State $State -Record ([ordered]@{ event = $(if ($Failed) { 'failure' } else { 'end' });
            operationId = $Span.operationId; parentOperationId = $Span.parentOperationId;
            operation = $Span.operation; category = $Span.category;
            durationSeconds = ([Diagnostics.Stopwatch]::GetTimestamp() - $Span.started) / [double][Diagnostics.Stopwatch]::Frequency;
            digestTotals = $totals })
    }
    catch {
        $State.writerFailed = $true
        # A telemetry failure must not replace an original terminating error.
        if (-not $Failed) { throw }
    }
}

function Add-EzVmQualificationDigestObservation {
    param([object]$State, [string]$Kind, [long]$Started, [long]$Bytes, [bool]$Failed)
    $total = $State.digestTotals[$Kind]
    $total.calls++
    $total.elapsedSeconds += ([Diagnostics.Stopwatch]::GetTimestamp() - $Started) / [double][Diagnostics.Stopwatch]::Frequency
    if ($Failed) { $total.failedCalls++ } else { $total.bytes += $Bytes }
}

function New-EzVmQualificationTelemetry {
    param([Parameter(Mandatory = $true)][string]$Path, [ValidateRange(512, 8388608)][long]$MaximumBytes = 8MB)
    if (-not [IO.Path]::IsPathRooted($Path)) { throw 'Qualification telemetry requires an absolute output path.' }
    $full = [IO.Path]::GetFullPath($Path)
    $parent = New-Object IO.DirectoryInfo ([IO.Path]::GetDirectoryName($full))
    if (-not $parent.Exists) { throw 'Qualification telemetry parent must already exist.' }
    for ($item = $parent; $null -ne $item; $item = $item.Parent) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Qualification telemetry refuses reparse-point ancestors.' }
    }
    $state = [pscustomobject]@{ stream = [IO.File]::Open($full, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read);
        encoding = New-Object Text.UTF8Encoding($false); maximumBytes = $MaximumBytes; bytesWritten = [long]0;
        clock = [Diagnostics.Stopwatch]::StartNew(); sequence = 0; operationId = 0; writerFailed = $false;
        stack = New-Object 'Collections.Generic.List[object]'; digestTotals = @{}; binding = $null; rootSpan = $null;
        write = ${function:Write-EzVmQualificationTelemetry}; begin = ${function:Start-EzVmQualificationSpan};
        end = ${function:Stop-EzVmQualificationSpan}; digest = ${function:Add-EzVmQualificationDigestObservation} }
    foreach ($kind in @('manifest', 'qemu-payload', 'base-image', 'source-image', 'other')) {
        $state.digestTotals[$kind] = @{ calls = 0; failedCalls = 0; bytes = [long]0; elapsedSeconds = [double]0 }
    }
    try { $state.rootSpan = & $state.begin -State $state -Operation 'full-release' -Category 'qualification' }
    catch { $state.stream.Dispose(); throw }
    return $state
}

function Enable-EzVmQualificationTelemetry {
    param([object]$State, [Management.Automation.PSModuleInfo]$Module)
    if ($null -ne $State.binding) { throw 'Qualification telemetry already observes a module.' }
    # Fixed targets only. No arguments, paths, stderr, guest output or exception
    # text are serialized. Hashing is aggregated rather than logging every QEMU
    # payload file on every repeated integrity check.
    $targets = [ordered]@{
        'Get-EzVmFileDigest' = 'integrity'; 'Invoke-EzVmProcess' = 'process';
        'Assert-EzVmQemuPayloadIntegrity' = 'validation'; 'Test-EzVmPreparedBaseDirectory' = 'validation';
        'Test-EzVmInstanceStorage' = 'validation'; 'Test-EzVmPortableBundle' = 'validation';
        'Get-EzVmDoctorReport' = 'validation'; 'Install-EzVmQemuRuntime' = 'acquisition';
        'Invoke-EzVmSourceImageAcquire' = 'acquisition'; 'Invoke-EzVmBaseBuild' = 'base-build';
        'Start-EzVmReadyInstance' = 'ready'; 'Stop-EzVmInstance' = 'shutdown';
        'Copy-EzVmManagedInstance' = 'image'; 'Export-EzVmManagedInstance' = 'image';
        'Import-EzVmManagedInstance' = 'image'; 'Reset-EzVmManagedInstance' = 'image'
    }
    $originals = @{}
    $State.binding = [pscustomobject]@{ module = $Module; originals = $originals }
    try {
        & $Module {
            param($Observer, $Targets, $Originals)
            $script:EzVmQualificationTelemetryState = $Observer
            $script:EzVmQualificationTelemetryOriginals = $Originals
            foreach ($name in $Targets.Keys) {
                $command = Get-Command -Name $name -CommandType Function -ErrorAction Stop
                $Originals[$name] = $command.ScriptBlock
                $metadata = New-Object Management.Automation.CommandMetadata $command
                $parameters = [Management.Automation.ProxyCommand]::GetParamBlock($metadata)
                $body = @'
[CmdletBinding()]
param(__PARAMETERS__)
$observer = $script:EzVmQualificationTelemetryState
$original = $script:EzVmQualificationTelemetryOriginals['__NAME__']
$failed = $true
__OBSERVE__
'@
                if ($name -ceq 'Get-EzVmFileDigest') {
                    $observe = @'
if ($observer.writerFailed) { throw 'Qualification telemetry is incomplete; refusing further observed work.' }
$normalized = $Path.Replace('\', '/')
$leaf = [IO.Path]::GetFileName($normalized)
$kind = 'other'; $length = [long]0
if ($leaf -cin @('qemu-windows.json', 'ubuntu-noble-amd64.json', 'manifest.json', 'ezvm-payload.json')) { $kind = 'manifest' }
elseif ($normalized -match '/runtime/qemu/') { $kind = 'qemu-payload' }
elseif ($leaf -ceq 'base.qcow2') { $kind = 'base-image' }
elseif ($leaf -match '\.img$') { $kind = 'source-image' }
# Metadata only; failure to observe optional size cannot change the hash call.
try { if ($kind -cne 'other') { $length = (New-Object IO.FileInfo $Path).Length } } catch { $length = 0 }
$started = [Diagnostics.Stopwatch]::GetTimestamp()
try { & $original @PSBoundParameters; $failed = $false }
finally { & $observer.digest -State $observer -Kind $kind -Started $started -Bytes $length -Failed $failed }
'@
                }
                else {
                    $observe = @'
$details = @{}
$category = '__CATEGORY__'
if ('__NAME__' -ceq 'Invoke-EzVmProcess') {
    $leaf = [IO.Path]::GetFileName($FilePath).ToLowerInvariant()
    $details.tool = if ($leaf -cin @('qemu-img.exe', 'qemu-system-x86_64.exe', 'ssh.exe', 'scp.exe')) { $leaf } else { 'other' }
    if ($leaf -ceq 'qemu-img.exe') {
        $category = 'image'
        $action = if ($PSBoundParameters.ContainsKey('ArgumentList') -and $ArgumentList.Count) { [string]$ArgumentList[0] } else { '' }
        $details.action = if ($action -cin @('info', 'compare', 'create', 'convert', 'check', 'rebase', 'resize', '--version')) { $action } else { 'other' }
    }
}
$span = & $observer.begin -State $observer -Operation '__NAME__' -Category $category -Details $details
try { & $original @PSBoundParameters; $failed = $false }
finally { & $observer.end -State $observer -Span $span -Failed $failed }
'@
                }
                $body = $body.Replace('__PARAMETERS__', $parameters).Replace('__OBSERVE__', $observe).
                    Replace('__NAME__', $name).Replace('__CATEGORY__', $Targets[$name])
                $wrapper = $ExecutionContext.SessionState.Module.NewBoundScriptBlock([scriptblock]::Create($body))
                Set-Item -Path ('Function:script:' + $name) -Value $wrapper
            }
        } $State $targets $originals
    }
    catch { Disable-EzVmQualificationTelemetry -State $State; throw }
}

function Disable-EzVmQualificationTelemetry {
    param([object]$State)
    if ($null -eq $State.binding) { return }
    $binding = $State.binding
    & $binding.module {
        param($Originals)
        foreach ($name in $Originals.Keys) { Set-Item -Path ('Function:script:' + $name) -Value $Originals[$name] }
        Remove-Variable -Name EzVmQualificationTelemetryState, EzVmQualificationTelemetryOriginals -Scope Script -ErrorAction SilentlyContinue
    } $binding.originals
    $State.binding = $null
}

function Write-EzVmQualificationIdentity {
    param([object]$State,
        [ValidateSet('qemu-system', 'qemu-img', 'source-image', 'prepared-base')][string]$Kind,
        [ValidatePattern('^[a-f0-9]{64}$')][string]$Sha256,
        [ValidateRange(0, 9223372036854775807)][long]$SizeBytes,
        [ValidatePattern('^[A-Za-z0-9._+-]{1,64}$')][string]$Version)
    $details = [ordered]@{ kind = $Kind; sha256 = $Sha256; sizeBytes = $SizeBytes }
    if ($Version) { $details.version = $Version }
    & $State.write -State $State -Record ([ordered]@{ event = 'identity'; operationId = $State.rootSpan.operationId;
        parentOperationId = $null; operation = 'verified-identity'; category = 'identity'; details = $details })
}

function Close-EzVmQualificationTelemetry {
    param([object]$State, [bool]$Failed)
    try { & $State.end -State $State -Span $State.rootSpan -Failed $Failed }
    finally { $State.stream.Dispose() }
    if ($State.writerFailed -and -not $Failed) { throw 'Qualification telemetry is incomplete; no complete observed result is available.' }
}
