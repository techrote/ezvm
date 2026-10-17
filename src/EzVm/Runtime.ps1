function Get-EzVmRuntimeProperty {
    param([AllowNull()][object]$Object, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Assert-EzVmRuntimeFields {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Description
    )
    if ($Value -isnot [pscustomobject]) { throw "$Description must be a JSON object." }
    $actual = @($Value.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($name in $actual) {
        if ($Expected -cnotcontains $name) { throw "$Description contains unknown field '$name'." }
    }
    foreach ($name in $Expected) {
        if ($actual -cnotcontains $name) { throw "$Description is missing required field '$name'." }
    }
}

function Assert-EzVmRuntimeInteger {
    param([AllowNull()][object]$Value, [string]$Description, [long]$Minimum, [long]$Maximum)
    $integer = $Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or
        $Value -is [int64] -or $Value -is [uint16] -or $Value -is [uint32] -or $Value -is [uint64]
    if (-not $integer -or [long]$Value -lt $Minimum -or [long]$Value -gt $Maximum) {
        throw "$Description must be an integer from $Minimum through $Maximum."
    }
}

function Assert-EzVmRuntimeTimestamp {
    param([AllowNull()][object]$Value, [string]$Description, [switch]$AllowEmpty)
    if ($Value -isnot [string]) { throw "$Description must be an ISO timestamp string." }
    if ($AllowEmpty -and $Value.Length -eq 0) { return }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse(
        $Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$parsed)) {
        throw "$Description must be an ISO timestamp string."
    }
}

function Get-EzVmInstanceRuntimePaths {
    [CmdletBinding()]
    param(
        [string]$Root = $script:EzVmDefaultRoot,
        [Parameter(Mandatory = $true)][string]$InstanceName
    )
    $storage = Get-EzVmInstanceStoragePaths -Root $Root -InstanceName $InstanceName
    return [pscustomobject][ordered]@{
        InstanceName = $InstanceName
        Directory = $storage.Directory
        Disk = $storage.Disk
        Intent = Join-Path $storage.Directory 'instance.json'
        Operation = Join-Path $storage.Directory 'lifecycle-operation.json'
        Origin = Join-Path $storage.Directory 'origin.json'
        Runtime = Join-Path $storage.Directory 'runtime.json'
        FirmwareVariables = Join-Path $storage.Directory 'uefi-vars.fd'
        Logs = Join-Path $storage.Directory 'logs'
    }
}

function Assert-EzVmInstanceIntent {
    param([object]$Intent, [string]$ExpectedName)

    if ($Intent -is [pscustomobject]) {
        $legacyFields = @('schemaVersion', 'name', 'baseId', 'cpus', 'memoryMiB', 'createdAt')
        $actualFields = @($Intent.PSObject.Properties | ForEach-Object { $_.Name })
        if ($actualFields.Count -eq $legacyFields.Count -and
            @($legacyFields | Where-Object { $actualFields -cnotcontains $_ }).Count -eq 0) {
            throw "Instance intent '$ExpectedName' uses the legacy EZVM-006 schema. EZVM-008 requires durable profile, SSH-port and provisioning metadata; recreate or deliberately migrate this pre-v0.1 instance before start."
        }
    }

    $schema = Get-EzVmRuntimeProperty -Object $Intent -Name 'schemaVersion'
    Assert-EzVmRuntimeInteger -Value $schema -Description 'Instance intent schemaVersion' -Minimum 1 -Maximum 2
    $fields = @(
        'schemaVersion', 'name', 'baseId', 'profile', 'cpus', 'memoryMiB',
        'sshPort', 'createdAt', 'provisioningProfile', 'provisioningVersion'
    )
    if ($schema -eq 2) { $fields += 'identityGeneration' }
    Assert-EzVmRuntimeFields -Value $Intent -Expected $fields -Description 'Instance intent'
    if ($schema -eq 2 -and ($Intent.identityGeneration -isnot [string] -or $Intent.identityGeneration -cnotmatch '^[a-f0-9]{32}$')) {
        throw 'Instance intent identityGeneration must be 32 lowercase hexadecimal characters.'
    }
    Assert-EzVmStorageInstanceName -Name ([string]$Intent.name)
    if ($Intent.name -cne $ExpectedName) {
        throw "Instance intent name '$($Intent.name)' does not match managed instance '$ExpectedName'."
    }
    if ($Intent.baseId -isnot [string] -or $Intent.baseId -cnotmatch '^base-[a-f0-9]{64}$') {
        throw 'Instance intent baseId is invalid.'
    }
    if ($Intent.profile -isnot [string] -or @('light', 'normal', 'heavy', 'custom') -cnotcontains [string]$Intent.profile) {
        throw 'Instance intent profile must be light, normal, heavy or custom.'
    }
    Assert-EzVmRuntimeInteger -Value $Intent.cpus -Description 'Instance intent cpus' -Minimum 1 -Maximum 256
    Assert-EzVmRuntimeInteger -Value $Intent.memoryMiB -Description 'Instance intent memoryMiB' -Minimum 512 -Maximum 1048576
    Assert-EzVmRuntimeInteger -Value $Intent.sshPort -Description 'Instance intent sshPort' -Minimum 1024 -Maximum 65535
    Assert-EzVmRuntimeTimestamp -Value $Intent.createdAt -Description 'Instance intent createdAt'
    if ($Intent.provisioningProfile -isnot [string] -or $Intent.provisioningProfile -cnotmatch '^[a-z0-9][a-z0-9._-]{0,63}$') {
        throw 'Instance intent provisioningProfile is invalid.'
    }
    Assert-EzVmRuntimeInteger -Value $Intent.provisioningVersion -Description 'Instance intent provisioningVersion' -Minimum 1 -Maximum 2147483647
}

function New-EzVmInstanceIntent {
    [CmdletBinding()]
    param(
        [string]$Root = $script:EzVmDefaultRoot,
        [Parameter(Mandatory = $true)][string]$InstanceName,
        [Parameter(Mandatory = $true)][string]$BaseId,
        [AllowEmptyString()][string]$Profile = '',
        [ValidateRange(1, 256)][int]$Cpus = 4,
        [ValidateRange(512, 1048576)][int]$MemoryMiB = 8192,
        [ValidateRange(1024, 65535)][int]$SshPort = 22000,
        [ValidatePattern('^[a-z0-9][a-z0-9._-]{0,63}$')][string]$ProvisioningProfile = 'coding-default',
        [ValidateRange(1, 2147483647)][int]$ProvisioningVersion = 1,
        [scriptblock]$QemuImgRunner
    )

    $null = Get-EzVmCodingProfile -Root $Root -Name $ProvisioningProfile -Version $ProvisioningVersion
    $paths = Get-EzVmPaths -Root $Root
    $runtimePaths = Get-EzVmInstanceRuntimePaths -Root $Root -InstanceName $InstanceName
    $null = Test-EzVmPreparedBase -Root $Root -BaseId $BaseId -QemuImgRunner $QemuImgRunner

    if ([string]::IsNullOrWhiteSpace($Profile)) {
        $configuration = Get-EzVmConfiguration -Root $Root
        $matches = @(@('light', 'normal', 'heavy') | Where-Object {
            $candidateProfile = $configuration.profiles.$_
            [int]$candidateProfile.cpus -eq $Cpus -and
            [int]$candidateProfile.memoryMiB -eq $MemoryMiB
        })
        $Profile = if ($matches.Count -eq 1) { [string]$matches[0] } else { 'custom' }
    }
    else {
        $Profile = $Profile.ToLowerInvariant()
        if (@('light', 'normal', 'heavy', 'custom') -cnotcontains $Profile) {
            throw "Instance profile '$Profile' is invalid."
        }
    }

    [void][IO.Directory]::CreateDirectory($paths.Instances)
    [void][IO.Directory]::CreateDirectory($runtimePaths.Directory)
    $null = Assert-EzVmStorageManagedPath -Path $runtimePaths.Directory -ContainmentRoot $paths.Instances -SafetyRoot $paths.Root -Description 'Instance directory' -RequireDirectory
    if (Test-Path -LiteralPath $runtimePaths.Intent) {
        throw "Instance intent already exists at '$($runtimePaths.Intent)'. Refusing to replace durable instance identity."
    }

    $intent = [pscustomobject][ordered]@{
        schemaVersion = 2
        name = $InstanceName
        baseId = $BaseId
        profile = $Profile
        cpus = $Cpus
        memoryMiB = $MemoryMiB
        sshPort = $SshPort
        createdAt = [DateTime]::UtcNow.ToString('o')
        provisioningProfile = $ProvisioningProfile
        provisioningVersion = $ProvisioningVersion
        identityGeneration = [Guid]::NewGuid().ToString('N')
    }
    Assert-EzVmInstanceIntent -Intent $intent -ExpectedName $InstanceName
    Write-EzVmJson -Path $runtimePaths.Intent -Value $intent -SchemaVersion 2
    return $intent
}

function Get-EzVmInstanceIntent {
    [CmdletBinding()]
    param(
        [string]$Root = $script:EzVmDefaultRoot,
        [Parameter(Mandatory = $true)][string]$InstanceName
    )

    $paths = Get-EzVmPaths -Root $Root
    $runtimePaths = Get-EzVmInstanceRuntimePaths -Root $Root -InstanceName $InstanceName
    if (-not (Test-Path -LiteralPath $runtimePaths.Intent -PathType Leaf)) {
        throw "Instance '$InstanceName' has no durable instance.json. Create/reconcile the instance before starting it."
    }
    $null = Assert-EzVmStorageManagedPath -Path $runtimePaths.Intent -ContainmentRoot $paths.Instances -SafetyRoot $paths.Root -Description 'Instance intent' -RequireFile
    # Both complete schema versions remain readable; reads never rotate identity.
    $text = (Read-EzVmBoundedText -Path $runtimePaths.Intent)
    try { $intent = ConvertFrom-EzVmJsonText -Text $text -SchemaVersion 2 -Description 'Instance intent' }
    catch { $intent = ConvertFrom-EzVmJsonText -Text $text -SchemaVersion 1 -Description 'Instance intent' }
    Assert-EzVmInstanceIntent -Intent $intent -ExpectedName $InstanceName
    return $intent
}

function Get-EzVmArgumentFingerprint {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ArgumentList)

    $memory = New-Object IO.MemoryStream
    $writer = New-Object IO.BinaryWriter($memory, (New-Object Text.UTF8Encoding($false)), $true)
    try {
        $writer.Write([int]$ArgumentList.Count)
        foreach ($argument in $ArgumentList) {
            $bytes = [Text.Encoding]::UTF8.GetBytes([string]$argument)
            $writer.Write([int]$bytes.Length)
            $writer.Write($bytes)
        }
        $writer.Flush()
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            return ([BitConverter]::ToString($sha.ComputeHash($memory.ToArray()))).Replace('-', '').ToLowerInvariant()
        }
        finally { $sha.Dispose() }
    }
    finally {
        $writer.Dispose()
        $memory.Dispose()
    }
}

function ConvertFrom-EzVmWindowsCommandLine {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$CommandLine)

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'Windows process command-line parsing is available only on Windows.'
    }
    if (-not ('EzVmCommandLineNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class EzVmCommandLineNative {
    [DllImport("shell32.dll", SetLastError=true)]
    public static extern IntPtr CommandLineToArgvW(
        [MarshalAs(UnmanagedType.LPWStr)] string lpCmdLine,
        out int pNumArgs);
    [DllImport("kernel32.dll")]
    public static extern IntPtr LocalFree(IntPtr hMem);
}
'@
    }

    $count = 0
    $pointer = [EzVmCommandLineNative]::CommandLineToArgvW($CommandLine, [ref]$count)
    if ($pointer -eq [IntPtr]::Zero -or $count -lt 1) {
        throw 'Windows could not parse the observed QEMU process command line.'
    }
    try {
        $tokens = New-Object 'System.Collections.Generic.List[string]'
        for ($index = 0; $index -lt $count; $index++) {
            $itemPointer = [Runtime.InteropServices.Marshal]::ReadIntPtr($pointer, $index * [IntPtr]::Size)
            $tokens.Add([Runtime.InteropServices.Marshal]::PtrToStringUni($itemPointer))
        }
        return $tokens.ToArray()
    }
    finally { [void][EzVmCommandLineNative]::LocalFree($pointer) }
}

function ConvertTo-EzVmRuntimeProcessSnapshot {
    param([Parameter(Mandatory = $true)][object]$Process)

    $creation = Get-EzVmRuntimeProperty $Process 'CreationDate'
    if ($creation -is [DateTime]) {
        $startTime = $creation.ToUniversalTime()
    }
    elseif ($creation -is [DateTimeOffset]) {
        $startTime = $creation.UtcDateTime
    }
    else {
        try { $startTime = ([DateTimeOffset]::Parse([string]$creation, [Globalization.CultureInfo]::InvariantCulture)).UtcDateTime }
        catch { throw "Observed process $($Process.ProcessId) has no usable creation timestamp." }
    }

    $commandLine = [string](Get-EzVmRuntimeProperty $Process 'CommandLine')
    if ([string]::IsNullOrWhiteSpace($commandLine)) {
        throw "Observed process $($Process.ProcessId) has no readable command line; process identity is ambiguous."
    }
    $tokens = @(ConvertFrom-EzVmWindowsCommandLine -CommandLine $commandLine)
    if ($tokens.Count -lt 1) { throw "Observed process $($Process.ProcessId) has an empty command line." }
    $arguments = @()
    if ($tokens.Count -gt 1) { $arguments = @($tokens[1..($tokens.Count - 1)]) }

    return [pscustomobject][ordered]@{
        Pid = [int](Get-EzVmRuntimeProperty $Process 'ProcessId')
        ExecutablePath = [string](Get-EzVmRuntimeProperty $Process 'ExecutablePath')
        CommandLine = $commandLine
        Arguments = [string[]]$arguments
        StartTimeUtc = $startTime.ToString('o')
    }
}

function Get-EzVmObservedQemuProcesses {
    param(
        [AllowNull()][Nullable[int]]$ProcessId,
        [scriptblock]$ProcessProvider
    )

    if ($null -ne $ProcessProvider) {
        return @(& $ProcessProvider $ProcessId)
    }
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'QEMU runtime process reconciliation requires Windows or an explicit test process provider.'
    }

    try {
        if ($null -ne $ProcessId) {
            $items = @(Get-CimInstance -ClassName Win32_Process -OperationTimeoutSec 5 -Filter ("ProcessId = " + [int]$ProcessId) -ErrorAction Stop)
        }
        else {
            $items = @(Get-CimInstance -ClassName Win32_Process -OperationTimeoutSec 5 -Filter "Name = 'qemu-system-x86_64.exe'" -ErrorAction Stop)
        }
        $snapshots = New-Object 'System.Collections.Generic.List[object]'
        foreach ($item in $items) {
            $snapshots.Add((ConvertTo-EzVmRuntimeProcessSnapshot -Process $item))
        }
        return $snapshots.ToArray()
    }
    catch {
        throw "Windows process identity could not be queried safely: $($_.Exception.Message)"
    }
}

function Get-EzVmInstanceQemuName {
    param([string]$InstanceName)
    return 'ezvm-' + $InstanceName
}

function Test-EzVmArgumentsOwnInstance {
    param([string[]]$Arguments, [string]$InstanceName)

    for ($index = 0; $index -lt $Arguments.Count - 1; $index++) {
        if ($Arguments[$index] -ceq '-name' -and $Arguments[$index + 1] -ceq ('guest=' + (Get-EzVmInstanceQemuName -InstanceName $InstanceName))) {
            return $true
        }
    }
    return $false
}

function Get-EzVmObservedInstanceOwners {
    param([string]$InstanceName, [scriptblock]$ProcessProvider)

    $all = @(Get-EzVmObservedQemuProcesses -ProcessId $null -ProcessProvider $ProcessProvider)
    return @($all | Where-Object {
        $arguments = @($_.Arguments)
        Test-EzVmArgumentsOwnInstance -Arguments $arguments -InstanceName $InstanceName
    })
}

function Assert-EzVmRuntimeState {
    param([object]$Runtime, [string]$ExpectedName)

    Assert-EzVmRuntimeFields -Value $Runtime -Expected @(
        'schemaVersion', 'instanceName', 'state', 'pid', 'processStartTimeUtc',
        'qemuExecutable', 'argumentFingerprint', 'launchId', 'qmpHost', 'qmpPort',
        'accelerator', 'startedAt', 'lastObservedAt', 'stoppedAt',
        'qemuLog', 'serialLog'
    ) -Description 'Instance runtime state'
    if ($Runtime.schemaVersion -ne 1) { throw 'Instance runtime schemaVersion must be integer 1.' }
    if ($Runtime.instanceName -cne $ExpectedName) { throw 'Instance runtime state belongs to a different instance.' }
    if (@('STARTING', 'RUNNING', 'STOPPING', 'STOPPED') -cnotcontains [string]$Runtime.state) {
        throw "Instance runtime state '$($Runtime.state)' is unsupported."
    }
    Assert-EzVmRuntimeInteger -Value $Runtime.pid -Description 'Instance runtime pid' -Minimum 1 -Maximum ([int]::MaxValue)
    Assert-EzVmRuntimeTimestamp -Value $Runtime.processStartTimeUtc -Description 'Instance runtime processStartTimeUtc'
    if ($Runtime.qemuExecutable -isnot [string] -or -not [IO.Path]::IsPathRooted($Runtime.qemuExecutable)) {
        throw 'Instance runtime qemuExecutable must be an absolute path.'
    }
    if ($Runtime.argumentFingerprint -isnot [string] -or $Runtime.argumentFingerprint -cnotmatch '^[a-f0-9]{64}$') {
        throw 'Instance runtime argumentFingerprint is invalid.'
    }
    if ($Runtime.launchId -isnot [string] -or $Runtime.launchId -cnotmatch '^[a-f0-9]{32}$') {
        throw 'Instance runtime launchId is invalid.'
    }
    if ($Runtime.qmpHost -cne '127.0.0.1') {
        throw 'Instance runtime qmpHost must be exactly 127.0.0.1.'
    }
    Assert-EzVmRuntimeInteger -Value $Runtime.qmpPort -Description 'Instance runtime qmpPort' -Minimum 1024 -Maximum 65535
    if (@('whpx', 'tcg') -cnotcontains [string]$Runtime.accelerator) {
        throw 'Instance runtime accelerator must be whpx or tcg.'
    }
    foreach ($field in @('startedAt', 'lastObservedAt')) {
        Assert-EzVmRuntimeTimestamp -Value $Runtime.$field -Description "Instance runtime $field"
    }
    Assert-EzVmRuntimeTimestamp -Value $Runtime.stoppedAt -Description 'Instance runtime stoppedAt' -AllowEmpty
    foreach ($field in @('qemuLog', 'serialLog')) {
        if ($Runtime.$field -isnot [string] -or -not [IO.Path]::IsPathRooted($Runtime.$field)) {
            throw "Instance runtime $field must be an absolute path."
        }
    }
}

function Get-EzVmRuntimeStateFile {
    param([string]$Root, [string]$InstanceName)

    $runtimePaths = Get-EzVmInstanceRuntimePaths -Root $Root -InstanceName $InstanceName
    if (-not (Test-Path -LiteralPath $runtimePaths.Runtime -PathType Leaf)) { return $null }
    $runtime = Read-EzVmJson -Path $runtimePaths.Runtime -SchemaVersion 1
    Assert-EzVmRuntimeState -Runtime $runtime -ExpectedName $InstanceName
    return $runtime
}

function Write-EzVmRuntimeStateFile {
    param([string]$Root, [string]$InstanceName, [object]$Runtime)

    Assert-EzVmRuntimeState -Runtime $Runtime -ExpectedName $InstanceName
    $runtimePaths = Get-EzVmInstanceRuntimePaths -Root $Root -InstanceName $InstanceName
    Write-EzVmJson -Path $runtimePaths.Runtime -Value $Runtime -SchemaVersion 1
}

function Get-EzVmRuntimeIdentityResult {
    param(
        [object]$Runtime,
        [scriptblock]$ProcessProvider
    )

    $observed = @(Get-EzVmObservedQemuProcesses -ProcessId ([int]$Runtime.pid) -ProcessProvider $ProcessProvider)
    if ($observed.Count -eq 0) {
        return [pscustomobject]@{ Match = $false; Kind = 'missing'; Reason = "Recorded PID $($Runtime.pid) no longer exists."; Process = $null }
    }
    if ($observed.Count -ne 1) {
        return [pscustomobject]@{ Match = $false; Kind = 'ambiguous'; Reason = "Recorded PID $($Runtime.pid) produced multiple observations."; Process = $null }
    }
    $process = $observed[0]
    if ([string]::IsNullOrWhiteSpace([string]$process.ExecutablePath)) {
        return [pscustomobject]@{ Match = $false; Kind = 'ambiguous'; Reason = 'Observed process executable path is unavailable.'; Process = $process }
    }
    if (-not (Test-EzVmStorageSamePath -Left $process.ExecutablePath -Right $Runtime.qemuExecutable)) {
        return [pscustomobject]@{ Match = $false; Kind = 'reused'; Reason = "PID $($Runtime.pid) belongs to '$($process.ExecutablePath)', not the recorded QEMU executable."; Process = $process }
    }

    $expectedStart = [DateTimeOffset]::Parse($Runtime.processStartTimeUtc, [Globalization.CultureInfo]::InvariantCulture)
    $observedStart = [DateTimeOffset]::Parse([string]$process.StartTimeUtc, [Globalization.CultureInfo]::InvariantCulture)
    if ([Math]::Abs(($expectedStart.UtcDateTime - $observedStart.UtcDateTime).TotalSeconds) -gt 2.0) {
        return [pscustomobject]@{ Match = $false; Kind = 'reused'; Reason = "PID $($Runtime.pid) start time does not match the recorded launch."; Process = $process }
    }

    $arguments = @($process.Arguments)
    if (-not (Test-EzVmArgumentsOwnInstance -Arguments $arguments -InstanceName $Runtime.instanceName)) {
        return [pscustomobject]@{ Match = $false; Kind = 'fingerprint'; Reason = 'Observed QEMU command line does not carry this instance launch marker.'; Process = $process }
    }
    $fingerprint = Get-EzVmArgumentFingerprint -ArgumentList ([string[]]$arguments)
    if ($fingerprint -cne $Runtime.argumentFingerprint) {
        return [pscustomobject]@{ Match = $false; Kind = 'fingerprint'; Reason = 'Observed QEMU argument fingerprint differs from the recorded launch.'; Process = $process }
    }
    return [pscustomobject]@{ Match = $true; Kind = 'match'; Reason = 'Observed process identity matches the recorded ezvm launch.'; Process = $process }
}

function New-EzVmRuntimeStatusResult {
    param(
        [string]$InstanceName,
        [string]$State,
        [string]$Reason,
        [AllowNull()][object]$Runtime = $null,
        [AllowNull()][object]$Process = $null
    )
    return [pscustomobject][ordered]@{
        schemaVersion = 1
        name = $InstanceName
        state = $State
        reason = $Reason
        pid = $(if ($null -ne $Process) { [int]$Process.Pid } elseif ($null -ne $Runtime) { [int]$Runtime.pid } else { $null })
        accelerator = $(if ($null -ne $Runtime) { [string]$Runtime.accelerator } else { $null })
        qmpHost = $(if ($null -ne $Runtime) { [string]$Runtime.qmpHost } else { $null })
        qmpPort = $(if ($null -ne $Runtime) { [int]$Runtime.qmpPort } else { $null })
        startedAt = $(if ($null -ne $Runtime) { [string]$Runtime.startedAt } else { $null })
        stoppedAt = $(if ($null -ne $Runtime) { [string]$Runtime.stoppedAt } else { $null })
    }
}

function Get-EzVmInstanceStatus {
    [CmdletBinding()]
    param(
        [string]$Root = $script:EzVmDefaultRoot,
        [Parameter(Mandatory = $true)][string]$InstanceName,
        [scriptblock]$ProcessProvider
    )

    $runtimePaths = Get-EzVmInstanceRuntimePaths -Root $Root -InstanceName $InstanceName
    if (-not (Test-Path -LiteralPath $runtimePaths.Intent -PathType Leaf)) {
        return New-EzVmRuntimeStatusResult -InstanceName $InstanceName -State 'ABSENT' -Reason 'No durable instance intent exists.'
    }
    if (Test-Path -LiteralPath $runtimePaths.Operation) {
        return New-EzVmRuntimeStatusResult -InstanceName $InstanceName -State 'UNKNOWN' -Reason ("An interrupted lifecycle operation requires recovery. Preserve and inspect '$($runtimePaths.Operation)' and its recorded recovery artifacts before starting or changing storage.")
    }
    try { $null = Get-EzVmInstanceIntent -Root $Root -InstanceName $InstanceName }
    catch {
        return New-EzVmRuntimeStatusResult -InstanceName $InstanceName -State 'UNKNOWN' -Reason ("Durable instance intent is invalid: " + $_.Exception.Message)
    }

    $runtime = $null
    if (Test-Path -LiteralPath $runtimePaths.Runtime -PathType Leaf) {
        try { $runtime = Get-EzVmRuntimeStateFile -Root $Root -InstanceName $InstanceName }
        catch {
            return New-EzVmRuntimeStatusResult -InstanceName $InstanceName -State 'UNKNOWN' -Reason ("runtime.json is corrupt or unsupported: " + $_.Exception.Message)
        }
    }

    if ($null -eq $runtime -or $runtime.state -ceq 'STOPPED') {
        try { $owners = @(Get-EzVmObservedInstanceOwners -InstanceName $InstanceName -ProcessProvider $ProcessProvider) }
        catch {
            return New-EzVmRuntimeStatusResult -InstanceName $InstanceName -State 'UNKNOWN' -Reason $_.Exception.Message -Runtime $runtime
        }
        if ($owners.Count -eq 0) {
            $state = if ($null -eq $runtime) { 'CREATED' } else { 'STOPPED' }
            $reason = if ($state -ceq 'CREATED') {
                'Instance intent exists and no managed QEMU process owns it.'
            } else {
                'Last launch is recorded stopped and no managed QEMU process owns the instance.'
            }
            return New-EzVmRuntimeStatusResult -InstanceName $InstanceName -State $state -Reason $reason -Runtime $runtime
        }
        return New-EzVmRuntimeStatusResult -InstanceName $InstanceName -State 'UNKNOWN' -Reason "Found $($owners.Count) QEMU process(es) carrying the instance marker without matching active runtime ownership evidence." -Runtime $runtime -Process $owners[0]
    }

    try { $identity = Get-EzVmRuntimeIdentityResult -Runtime $runtime -ProcessProvider $ProcessProvider }
    catch {
        return New-EzVmRuntimeStatusResult -InstanceName $InstanceName -State 'UNKNOWN' -Reason ("Process identity is ambiguous: " + $_.Exception.Message) -Runtime $runtime
    }
    if ($identity.Match) {
        return New-EzVmRuntimeStatusResult -InstanceName $InstanceName -State ([string]$runtime.state) -Reason $identity.Reason -Runtime $runtime -Process $identity.Process
    }

    if (@('missing', 'reused', 'fingerprint') -ccontains $identity.Kind) {
        try { $owners = @(Get-EzVmObservedInstanceOwners -InstanceName $InstanceName -ProcessProvider $ProcessProvider) }
        catch {
            return New-EzVmRuntimeStatusResult -InstanceName $InstanceName -State 'UNKNOWN' -Reason ($identity.Reason + ' ' + $_.Exception.Message) -Runtime $runtime
        }
        # The process that failed identity validation is not evidence of a
        # second owner merely because its unchanged -name marker still matches.
        # Only a distinct PID can turn stale recorded ownership into UNKNOWN.
        $alternateOwners = @($owners | Where-Object {
            $null -eq $identity.Process -or [int]$_.Pid -ne [int]$identity.Process.Pid
        })
        if ($alternateOwners.Count -gt 0) {
            return New-EzVmRuntimeStatusResult -InstanceName $InstanceName -State 'UNKNOWN' -Reason ($identity.Reason + " Found $($alternateOwners.Count) other QEMU owner candidate(s) for this instance.") -Runtime $runtime -Process $alternateOwners[0]
        }
        return New-EzVmRuntimeStatusResult -InstanceName $InstanceName -State 'STALE' -Reason $identity.Reason -Runtime $runtime -Process $identity.Process
    }

    return New-EzVmRuntimeStatusResult -InstanceName $InstanceName -State 'UNKNOWN' -Reason $identity.Reason -Runtime $runtime -Process $identity.Process
}

function Get-EzVmInstanceStorageLifecycleGuard {
    [CmdletBinding()]
    param(
        [string]$Root = $script:EzVmDefaultRoot,
        [Parameter(Mandatory = $true)][string]$InstanceName,
        [scriptblock]$ProcessProvider
    )

    $status = Get-EzVmInstanceStatus -Root $Root -InstanceName $InstanceName -ProcessProvider $ProcessProvider
    $state = switch ($status.state) {
        'CREATED' { 'proven-safe' }
        'STOPPED' { 'proven-safe' }
        'RUNNING' { 'running' }
        'STARTING' { 'starting' }
        'STOPPING' { 'stopping' }
        default { 'unknown' }
    }
    return New-EzVmStorageLifecycleGuard -State $state -Source ("EZVM-006 process reconciliation: " + $status.state + '; ' + $status.reason)
}

function Enter-EzVmInstanceLifecycleLock {
    param(
        [string]$Root,
        [string]$InstanceName,
        [ValidateRange(1, 30000)][int]$TimeoutMilliseconds = 5000
    )

    Assert-EzVmStorageInstanceName -Name $InstanceName
    $paths = Get-EzVmPaths -Root $Root
    $null = Assert-EzVmStorageManagedPath -Path $paths.Locks -ContainmentRoot $paths.Runtime -SafetyRoot $paths.Root -Description 'Lifecycle lock directory'
    [void][IO.Directory]::CreateDirectory($paths.Locks)
    $null = Assert-EzVmStorageManagedPath -Path $paths.Locks -ContainmentRoot $paths.Runtime -SafetyRoot $paths.Root -Description 'Lifecycle lock directory' -RequireDirectory
    $lockPath = Join-Path $paths.Locks ('instance-' + $InstanceName + '.lock')
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    while ($true) {
        $null = Assert-EzVmStorageManagedPath -Path $lockPath -ContainmentRoot $paths.Locks -SafetyRoot $paths.Root -Description 'Instance lifecycle lock'
        try {
            $stream = New-Object IO.FileStream($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $payload = [Text.Encoding]::UTF8.GetBytes(('pid=' + $PID + ';acquiredAt=' + [DateTime]::UtcNow.ToString('o')))
            $stream.SetLength(0)
            $stream.Write($payload, 0, $payload.Length)
            $stream.Flush($true)
            return $stream
        }
        catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) {
                throw "Timed out waiting for lifecycle lock for instance '$InstanceName'. Another start/stop/status mutation may still be running."
            }
            Start-Sleep -Milliseconds 50
        }
    }
}

function Enter-EzVmQmpAllocationLock {
    param([string]$Root, [ValidateRange(1, 30000)][int]$TimeoutMilliseconds = 5000)

    $paths = Get-EzVmPaths -Root $Root
    $null = Assert-EzVmStorageManagedPath -Path $paths.Locks -ContainmentRoot $paths.Runtime -SafetyRoot $paths.Root -Description 'QMP allocation lock directory'
    [void][IO.Directory]::CreateDirectory($paths.Locks)
    $null = Assert-EzVmStorageManagedPath -Path $paths.Locks -ContainmentRoot $paths.Runtime -SafetyRoot $paths.Root -Description 'Lifecycle lock directory' -RequireDirectory
    $lockPath = Join-Path $paths.Locks 'qmp-port-allocation.lock'
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    while ($true) {
        $null = Assert-EzVmStorageManagedPath -Path $lockPath -ContainmentRoot $paths.Locks -SafetyRoot $paths.Root -Description 'QMP allocation lock'
        try {
            return New-Object IO.FileStream($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        }
        catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) {
                throw 'Timed out waiting for the ezvm QMP port-allocation lock. Another instance start may still be publishing its management endpoint.'
            }
            Start-Sleep -Milliseconds 50
        }
    }
}

function Get-EzVmRuntimeFirmwarePaths {
    param([string]$Root, [string]$InstanceName)

    $paths = Get-EzVmPaths -Root $Root
    $runtimePaths = Get-EzVmInstanceRuntimePaths -Root $Root -InstanceName $InstanceName
    $code = Join-Path $paths.Qemu 'share/edk2-x86_64-code.fd'
    $template = Join-Path $paths.Qemu 'share/edk2-i386-vars.fd'
    foreach ($path in @($code, $template)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Managed QEMU firmware is incomplete: missing '$path'. Re-run bootstrap and retry."
        }
    }
    $null = Assert-EzVmSafePath -Path $runtimePaths.FirmwareVariables -Description 'Guest firmware state'
    if (-not (Test-Path -LiteralPath $runtimePaths.FirmwareVariables -PathType Leaf)) {
        $candidate = Join-Path $runtimePaths.Directory ('.uefi-vars-' + [Guid]::NewGuid().ToString('N') + '.tmp')
        try {
            [IO.File]::Copy($template, $candidate, $false)
            Move-EzVmStorageFile -Source $candidate -Destination $runtimePaths.FirmwareVariables
        }
        finally {
            if (Test-Path -LiteralPath $candidate) { try { Remove-Item -LiteralPath $candidate -Force } catch { } }
        }
    }
    $paths = Get-EzVmPaths -Root $Root
    $null = Assert-EzVmStorageManagedPath -Path $runtimePaths.FirmwareVariables -ContainmentRoot $runtimePaths.Directory -SafetyRoot $paths.Root -Description 'Instance UEFI variable store' -RequireFile
    return [pscustomobject][ordered]@{
        Code = [IO.Path]::GetFullPath($code)
        Variables = [IO.Path]::GetFullPath($runtimePaths.FirmwareVariables)
    }
}

function Get-EzVmEphemeralLoopbackPort {
    [CmdletBinding()]
    param()

    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try {
        $listener.Server.ExclusiveAddressUse = $true
        $listener.Start()
        return [int]([Net.IPEndPoint]$listener.LocalEndpoint).Port
    }
    finally { $listener.Stop() }
}

function New-EzVmRuntimeQemuArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstanceName,
        [Parameter(Mandatory = $true)][object]$Intent,
        [Parameter(Mandatory = $true)][string]$Disk,
        [Parameter(Mandatory = $true)][string]$FirmwareCode,
        [Parameter(Mandatory = $true)][string]$FirmwareVariables,
        [Parameter(Mandatory = $true)][string]$SerialLog,
        [Parameter(Mandatory = $true)][string]$QemuLog,
        [Parameter(Mandatory = $true)][ValidateRange(1024, 65535)][int]$QmpPort,
        [ValidateSet('whpx', 'tcg')][string]$Accelerator = 'whpx',
        [ValidateRange(0, 65535)][int]$SshPort = 0,
        [ValidateRange(0, 65535)][int]$SeedHostPort = 0,
        [string]$SeedGuestAddress = '10.0.2.100',
        [ValidateRange(1, 65535)][int]$SeedGuestPort = 8000
    )

    Assert-EzVmInstanceIntent -Intent $Intent -ExpectedName $InstanceName
    if ($SshPort -gt 0 -and $SshPort -lt 1024) { throw 'SSH host forwarding requires a non-privileged port from 1024 to 65535.' }
    if ($SeedHostPort -gt 0 -and $SeedHostPort -lt 1024) { throw 'Seed guest forwarding requires a non-privileged host port from 1024 to 65535.' }
    if ($SeedHostPort -gt 0 -and $SeedGuestAddress -cne '10.0.2.100') {
        throw 'The EZVM-007 NoCloud guest-forward address must be exactly 10.0.2.100.'
    }

    $netdev = 'user,id=net0,ipv6=off'
    if ($SshPort -gt 0) {
        $netdev += ',hostfwd=tcp:127.0.0.1:' + $SshPort + '-:22'
    }
    if ($SeedHostPort -gt 0) {
        $netdev += ',guestfwd=tcp:' + $SeedGuestAddress + ':' + $SeedGuestPort + '-tcp:127.0.0.1:' + $SeedHostPort
    }

    $arguments = New-Object 'System.Collections.Generic.List[string]'
    foreach ($pair in @(
        @('-name', ('guest=' + (Get-EzVmInstanceQemuName -InstanceName $InstanceName))),
        @('-machine', 'q35'),
        @('-accel', $(if ($Accelerator -ceq 'tcg') { 'tcg,thread=multi' } else { 'whpx' })),
        @('-m', [string]$Intent.memoryMiB),
        @('-smp', [string]$Intent.cpus),
        @('-display', 'none'),
        @('-monitor', 'none'),
        @('-serial', ('file:' + [IO.Path]::GetFullPath($SerialLog))),
        @('-D', [IO.Path]::GetFullPath($QemuLog)),
        @('-d', 'guest_errors,unimp'),
        @('-qmp', ('tcp:127.0.0.1:' + $QmpPort + ',server=on,wait=off,nodelay=on')),
        @('-drive', ('if=pflash,format=raw,readonly=on,file=' + [IO.Path]::GetFullPath($FirmwareCode))),
        @('-drive', ('if=pflash,format=raw,file=' + [IO.Path]::GetFullPath($FirmwareVariables))),
        @('-drive', ('if=none,id=osdisk,format=qcow2,file=' + [IO.Path]::GetFullPath($Disk))),
        @('-device', 'virtio-blk-pci,drive=osdisk,bootindex=0'),
        @('-netdev', $netdev),
        @('-device', 'virtio-net-pci,netdev=net0'),
        @('-boot', 'order=c,strict=on'),
        @('-rtc', 'base=utc')
    )) {
        $arguments.Add($pair[0])
        $arguments.Add($pair[1])
    }
    if ($SeedHostPort -gt 0) {
        $seedUrl = 'http://' + $SeedGuestAddress + ':' + $SeedGuestPort + '/'
        $arguments.Add('-smbios')
        $instanceIdOption = if ($Intent.schemaVersion -eq 2) { 'i=' + (Get-EzVmGuestCloudInstanceId -Intent $Intent) + ';' } else { '' }
        $arguments.Add('type=1,serial=ds=nocloud;' + $instanceIdOption + 's=' + $seedUrl)
    }
    if ($Intent.schemaVersion -eq 2) {
        $arguments.Add('-uuid')
        $arguments.Add((Get-EzVmGuestMachineUuid -Intent $Intent))
    }
    if ($Accelerator -ceq 'tcg') {
        $arguments.Add('-cpu')
        $arguments.Add('max')
    }
    $arguments.Add('-no-user-config')
    $arguments.Add('-nodefaults')
    # Generation-aware guests perform one identity initialization reboot without
    # releasing QEMU's storage ownership. Older instances keep their old argv policy.
    if ($Intent.schemaVersion -eq 1) { $arguments.Add('-no-reboot') }
    return $arguments.ToArray()
}

function Get-EzVmRuntimeProcessType {
    # Bind an in-memory native helper to its actual source, including after module
    # reimport from another checkout. No installed binary or global service.
    $sourcePath = Join-Path $PSScriptRoot 'RuntimeProcess.cs'
    $source = (Read-EzVmBoundedText -Path $sourcePath -MaximumBytes 65536).Replace("`r`n", "`n")
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $digest = ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($source)))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
    $namespace = 'EzVm.Dash08.V' + $digest
    $typeName = $namespace + '.RuntimeProcess'
    $type = $typeName -as [type]
    if ($null -ne $type) { return $type }
    $mutex = New-Object Threading.Mutex($false, ('Local\ezvm-runtime-native-' + $PID))
    $taken = $false
    try {
        try { $taken = $mutex.WaitOne(5000) }
        catch [Threading.AbandonedMutexException] { $taken = $true }
        if (-not $taken) { throw 'Timed out preparing the native runtime launcher; no process was launched.' }
        $type = $typeName -as [type]
        if ($null -eq $type) {
            Add-Type -TypeDefinition ($source.Replace('namespace EzVm.Dash08 {', ('namespace ' + $namespace + ' {'))) -Language CSharp -ErrorAction Stop
            $type = $typeName -as [type]
        }
        if ($null -eq $type) { throw 'Could not load the source-bound native runtime launcher.' }
        return $type
    }
    finally {
        if ($taken) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Start-EzVmRuntimeProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$ArgumentList,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$StandardOutputPath,
        [Parameter(Mandatory = $true)][string]$StandardErrorPath
    )

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'QEMU runtime launch requires Windows; use explicit process fixtures elsewhere.'
    }
    $executable = Assert-EzVmSafePath -Path (Resolve-EzVmProcessFileSystemPath -Path $FilePath) -Description 'Runtime executable'
    $directory = Assert-EzVmSafePath -Path (Resolve-EzVmProcessFileSystemPath -Path $WorkingDirectory) -Description 'Runtime working directory'
    $stdout = Assert-EzVmSafePath -Path (Resolve-EzVmProcessFileSystemPath -Path $StandardOutputPath) -Description 'Runtime stdout log'
    $stderr = Assert-EzVmSafePath -Path (Resolve-EzVmProcessFileSystemPath -Path $StandardErrorPath) -Description 'Runtime stderr log'
    if (-not [IO.File]::Exists($executable)) { throw "Runtime executable '$executable' does not exist; bootstrap the reviewed QEMU runtime." }
    if (-not [IO.Directory]::Exists($directory)) { throw "Runtime working directory '$directory' does not exist." }
    foreach ($log in @($stdout, $stderr)) {
        if (-not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($log))) { throw "Runtime log parent does not exist: '$log'." }
        if (Test-Path -LiteralPath $log) { throw "Runtime log already exists: '$log'. Existing diagnostics are never replaced." }
    }
    if (Test-EzVmStorageSamePath -Left $stdout -Right $stderr) { throw 'Runtime stdout and stderr require distinct new files.' }
    $escaped = New-Object 'System.Collections.Generic.List[string]'
    $escaped.Add((ConvertTo-EzVmWindowsArgument -Argument $executable))
    foreach ($argument in $ArgumentList) {
        if ($null -eq $argument -or $argument.IndexOf([char]0) -ge 0) { throw 'Runtime arguments must be NUL-free strings.' }
        $escaped.Add((ConvertTo-EzVmWindowsArgument -Argument $argument))
    }
    $commandLine = [string]::Join(' ', $escaped.ToArray())
    $type = Get-EzVmRuntimeProcessType
    # Direct file handles outlive this caller; no parent-owned draining thread,
    # inherited capture pipe, stdin preamble, shell, job breakaway or elevation.
    return $type::Start($executable, $commandLine, $directory, $stdout, $stderr)
}

function Get-EzVmRuntimeRemainingMilliseconds {
    param([Diagnostics.Stopwatch]$Clock, [int]$BudgetMilliseconds, [string]$Stage)
    $remaining = [long]$BudgetMilliseconds - $Clock.ElapsedMilliseconds
    if ($remaining -le 0) { throw [TimeoutException]::new("$Stage exceeded its $BudgetMilliseconds ms total deadline.") }
    return [int]$remaining
}

function Read-EzVmQmpJsonLine {
    param(
        [Parameter(Mandatory = $true)][IO.StreamReader]$Reader,
        [ValidateRange(1, 30000)][int]$TimeoutMilliseconds
    )

    $task = $Reader.ReadLineAsync()
    if (-not $task.Wait($TimeoutMilliseconds)) { throw "Timed out waiting $TimeoutMilliseconds ms for QMP response." }
    $line = $task.Result
    if ($null -eq $line) { throw 'QMP closed the management pipe before a complete response was received.' }
    try { return $line | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "QMP returned malformed JSON: $($_.Exception.Message)" }
}

function Wait-EzVmQmpResponse {
    param(
        [Parameter(Mandatory = $true)][IO.StreamReader]$Reader,
        [Parameter(Mandatory = $true)][string]$Id,
        [ValidateRange(1, 30000)][int]$TimeoutMilliseconds
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $remaining = [Math]::Max(1, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        $message = Read-EzVmQmpJsonLine -Reader $Reader -TimeoutMilliseconds $remaining
        $messageId = Get-EzVmRuntimeProperty $message 'id'
        if ($null -ne $messageId -and [string]$messageId -ceq $Id) {
            $error = Get-EzVmRuntimeProperty $message 'error'
            if ($null -ne $error) {
                $description = [string](Get-EzVmRuntimeProperty $error 'desc')
                throw "QMP command '$Id' failed: $description"
            }
            return $message
        }
    }
    throw "Timed out waiting for QMP response id '$Id'."
}

function Invoke-EzVmQmpCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$HostAddress,
        [Parameter(Mandatory = $true)][ValidateRange(1024, 65535)][int]$Port,
        [Parameter(Mandatory = $true)][string]$Command,
        [ValidateRange(1, 30000)][int]$TimeoutMilliseconds = 3000
    )

    if ($HostAddress -cne '127.0.0.1') { throw 'QMP management must connect only to 127.0.0.1.' }
    if ($Command -notin @('query-status', 'system_powerdown')) { throw "QMP command '$Command' is not permitted by this control path." }

    $clock = [Diagnostics.Stopwatch]::StartNew()
    $client = New-Object Net.Sockets.TcpClient([Net.Sockets.AddressFamily]::InterNetwork)
    $reader = $null
    $writer = $null
    try {
        $connect = $client.ConnectAsync($HostAddress, $Port)
        $remaining = Get-EzVmRuntimeRemainingMilliseconds $clock $TimeoutMilliseconds 'QMP connect'
        if (-not $connect.Wait($remaining)) { throw [TimeoutException]::new('Timed out connecting to QMP at ' + $HostAddress + ':' + $Port + '.') }
        if (-not $client.Connected) { throw ('Could not connect to QMP at ' + $HostAddress + ':' + $Port + '.') }
        $stream = $client.GetStream()
        $reader = New-Object IO.StreamReader($stream, (New-Object Text.UTF8Encoding($false)), $false, 4096, $true)
        $writer = New-Object IO.StreamWriter($stream, (New-Object Text.UTF8Encoding($false)), 4096, $true)
        $writer.NewLine = [Environment]::NewLine
        $writer.AutoFlush = $true
        $remaining = Get-EzVmRuntimeRemainingMilliseconds $clock $TimeoutMilliseconds 'QMP greeting'
        $greeting = Read-EzVmQmpJsonLine -Reader $reader -TimeoutMilliseconds $remaining
        if ($null -eq (Get-EzVmRuntimeProperty $greeting 'QMP')) { throw 'QMP management endpoint did not provide a valid server greeting.' }

        $capId = 'ezvm-capabilities'
        $remaining = Get-EzVmRuntimeRemainingMilliseconds $clock $TimeoutMilliseconds 'QMP capabilities write'
        $write = $writer.WriteLineAsync(([pscustomobject][ordered]@{ execute = 'qmp_capabilities'; id = $capId } | ConvertTo-Json -Compress))
        if (-not $write.Wait($remaining)) { throw [TimeoutException]::new('Timed out writing QMP capabilities.') }
        $remaining = Get-EzVmRuntimeRemainingMilliseconds $clock $TimeoutMilliseconds 'QMP capabilities response'
        $null = Wait-EzVmQmpResponse -Reader $reader -Id $capId -TimeoutMilliseconds $remaining

        $id = 'ezvm-' + $Command + '-' + [Guid]::NewGuid().ToString('N')
        $remaining = Get-EzVmRuntimeRemainingMilliseconds $clock $TimeoutMilliseconds 'QMP command write'
        $write = $writer.WriteLineAsync(([pscustomobject][ordered]@{ execute = $Command; id = $id } | ConvertTo-Json -Compress))
        if (-not $write.Wait($remaining)) { throw [TimeoutException]::new('Timed out writing QMP command.') }
        $remaining = Get-EzVmRuntimeRemainingMilliseconds $clock $TimeoutMilliseconds 'QMP command response'
        $response = Wait-EzVmQmpResponse -Reader $reader -Id $id -TimeoutMilliseconds $remaining
        $null = Get-EzVmRuntimeRemainingMilliseconds $clock $TimeoutMilliseconds 'QMP result'
        return Get-EzVmRuntimeProperty $response 'return'
    }
    finally {
        # Close the transport first, including timed-out reads/writes. Disposing a
        # writer first could flush to a stalled peer outside the operation budget.
        $client.Dispose()
        if ($null -ne $writer) { try { $writer.Dispose() } catch { } }
        if ($null -ne $reader) { try { $reader.Dispose() } catch { } }
        $clock.Stop()
    }
}

function Invoke-EzVmRuntimeQmp {
    param([string]$HostAddress, [int]$Port, [string]$Command, [int]$TimeoutMilliseconds, [scriptblock]$QmpInvoker)
    if ($null -ne $QmpInvoker) { return & $QmpInvoker $HostAddress $Port $Command $TimeoutMilliseconds }
    return Invoke-EzVmQmpCommand -HostAddress $HostAddress -Port $Port -Command $Command -TimeoutMilliseconds $TimeoutMilliseconds
}

function Start-EzVmInstance {
    [CmdletBinding()]
    param(
        [string]$Root = $script:EzVmDefaultRoot,
        [Parameter(Mandatory = $true)][string]$InstanceName,
        [ValidateSet('whpx', 'tcg')][string]$Accelerator = 'whpx',
        [ValidateRange(1, 3600)][int]$StartupTimeoutSeconds = 60,
        [scriptblock]$QemuImgRunner,
        [scriptblock]$QemuStatusProvider,
        [scriptblock]$ProcessProvider,
        [scriptblock]$ProcessLauncher,
        [scriptblock]$QmpInvoker,
        [ValidateRange(0, 65535)][int]$SshPort = 0,
        [ValidateRange(0, 65535)][int]$SeedHostPort = 0,
        [string]$SeedGuestAddress = '10.0.2.100',
        [ValidateRange(1, 65535)][int]$SeedGuestPort = 8000,
        [AllowNull()][object]$ExpectedIntent = $null
    )

    Assert-EzVmStorageInstanceName -Name $InstanceName
    $lock = Enter-EzVmInstanceLifecycleLock -Root $Root -InstanceName $InstanceName
    $qmpAllocationLock = $null
    $launch = $null
    $runtimePublished = $false
    try {
        $intent = Get-EzVmInstanceIntent -Root $Root -InstanceName $InstanceName
        if ($null -ne $ExpectedIntent) {
            Assert-EzVmInstanceIntent -Intent $ExpectedIntent -ExpectedName $InstanceName
            if (($intent | ConvertTo-Json -Depth 8 -Compress) -cne ($ExpectedIntent | ConvertTo-Json -Depth 8 -Compress)) {
                throw 'Instance intent changed while preparing the launch seed. Retry start with the current identity; no guest was launched.'
            }
        }
        $status = Get-EzVmInstanceStatus -Root $Root -InstanceName $InstanceName -ProcessProvider $ProcessProvider
        if (@('CREATED', 'STOPPED') -cnotcontains $status.state) {
            throw "Instance '$InstanceName' cannot start from lifecycle state '$($status.state)': $($status.reason)"
        }
        $storage = Test-EzVmInstanceStorage -Root $Root -InstanceName $InstanceName -BaseId $intent.baseId -QemuImgRunner $QemuImgRunner
        $paths = Get-EzVmPaths -Root $Root
        $managed = if ($null -ne $QemuStatusProvider) {
            & $QemuStatusProvider $Root
        } else {
            Get-EzVmManagedQemuStatus -Root $Root
        }
        if ($null -eq $managed -or -not $managed.Valid) { throw "Instance start requires validated managed QEMU. $($managed.Reason) Run '.\ezvm.ps1 bootstrap' and retry." }

        $runtimePaths = Get-EzVmInstanceRuntimePaths -Root $Root -InstanceName $InstanceName
        $null = Assert-EzVmSafePath -Path $runtimePaths.Logs -Description 'QEMU log directory'
        [void][IO.Directory]::CreateDirectory($runtimePaths.Logs)
        $null = Assert-EzVmStorageManagedPath -Path $runtimePaths.Logs -ContainmentRoot $runtimePaths.Directory -SafetyRoot $paths.Root -Description 'Instance log directory' -RequireDirectory
        $firmware = Get-EzVmRuntimeFirmwarePaths -Root $Root -InstanceName $InstanceName
        $launchId = [Guid]::NewGuid().ToString('N')
        $qmpHost = '127.0.0.1'
        $qmpAllocationLock = Enter-EzVmQmpAllocationLock -Root $Root
        $qmpPort = Get-EzVmEphemeralLoopbackPort
        $serialLog = Join-Path $runtimePaths.Logs ('serial-' + $launchId + '.log')
        $qemuLog = Join-Path $runtimePaths.Logs ('qemu-' + $launchId + '.log')
        $arguments = New-EzVmRuntimeQemuArguments -InstanceName $InstanceName -Intent $intent -Disk $storage.OverlayPath -FirmwareCode $firmware.Code -FirmwareVariables $firmware.Variables -SerialLog $serialLog -QemuLog $qemuLog -QmpPort $qmpPort -Accelerator $Accelerator -SshPort $SshPort -SeedHostPort $SeedHostPort -SeedGuestAddress $SeedGuestAddress -SeedGuestPort $SeedGuestPort
        $fingerprint = Get-EzVmArgumentFingerprint -ArgumentList $arguments

        $startupClock = [Diagnostics.Stopwatch]::StartNew()
        $startupBudget = $StartupTimeoutSeconds * 1000
        if ($null -ne $ProcessLauncher) {
            $launch = & $ProcessLauncher $managed.QemuSystem $arguments $paths.Qemu
        }
        else {
            $launch = Start-EzVmRuntimeProcess -FilePath $managed.QemuSystem -ArgumentList $arguments -WorkingDirectory $paths.Qemu -StandardOutputPath ($qemuLog + '.stdout.log') -StandardErrorPath ($qemuLog + '.stderr.log')
        }
        if ($null -eq $launch -or $null -eq $launch.Pid -or $null -eq $launch.StartTimeUtc) {
            throw 'QEMU process launcher did not return PID and start-time evidence.'
        }

        $now = [DateTime]::UtcNow.ToString('o')
        $runtime = [pscustomobject][ordered]@{
            schemaVersion = 1
            instanceName = $InstanceName
            state = 'STARTING'
            pid = [int]$launch.Pid
            processStartTimeUtc = [string]$launch.StartTimeUtc
            qemuExecutable = [IO.Path]::GetFullPath($managed.QemuSystem)
            argumentFingerprint = $fingerprint
            launchId = $launchId
            qmpHost = $qmpHost
            qmpPort = $qmpPort
            accelerator = $Accelerator
            startedAt = $now
            lastObservedAt = $now
            stoppedAt = ''
            qemuLog = [IO.Path]::GetFullPath($qemuLog)
            serialLog = [IO.Path]::GetFullPath($serialLog)
        }
        Write-EzVmRuntimeStateFile -Root $Root -InstanceName $InstanceName -Runtime $runtime
        $runtimePublished = $true

        $lastError = $null
        while ($startupClock.ElapsedMilliseconds -lt $startupBudget) {
            $identity = Get-EzVmRuntimeIdentityResult -Runtime $runtime -ProcessProvider $ProcessProvider
            if (-not $identity.Match) {
                throw "QEMU exited or changed identity before startup completed: $($identity.Reason)"
            }
            try {
                $remaining = Get-EzVmRuntimeRemainingMilliseconds $startupClock $startupBudget 'QEMU startup'
                $qmpStatus = Invoke-EzVmRuntimeQmp -HostAddress $qmpHost -Port $qmpPort -Command 'query-status' -TimeoutMilliseconds ([Math]::Min(750, $remaining)) -QmpInvoker $QmpInvoker
                $null = Get-EzVmRuntimeRemainingMilliseconds $startupClock $startupBudget 'QEMU startup result'
                $qmpRunning = Get-EzVmRuntimeProperty $qmpStatus 'running'
                $qmpState = [string](Get-EzVmRuntimeProperty $qmpStatus 'status')
                if ($qmpRunning -ne $true -or $qmpState -cne 'running') {
                    throw "QMP is reachable but reports status '$qmpState' (running=$qmpRunning)."
                }
                $after = Get-EzVmRuntimeIdentityResult -Runtime $runtime -ProcessProvider $ProcessProvider
                if (-not $after.Match) { throw "QEMU identity changed during startup observation: $($after.Reason)" }
                $null = Get-EzVmRuntimeRemainingMilliseconds $startupClock $startupBudget 'QEMU startup publication'
                $runtime.state = 'RUNNING'
                $runtime.lastObservedAt = [DateTime]::UtcNow.ToString('o')
                Write-EzVmRuntimeStateFile -Root $Root -InstanceName $InstanceName -Runtime $runtime
                if ($null -ne $qmpAllocationLock) {
                    $qmpAllocationLock.Dispose()
                    $qmpAllocationLock = $null
                }
                return [pscustomobject][ordered]@{
                    name = $InstanceName
                    state = 'RUNNING'
                    pid = [int]$runtime.pid
                    launchId = [string]$runtime.launchId
                    accelerator = $Accelerator
                    qmpHost = $qmpHost
                    qmpPort = $qmpPort
                    serialLog = $runtime.serialLog
                    qemuLog = $runtime.qemuLog
                }
            }
            catch {
                $lastError = $_.Exception.Message
                $remaining = [Math]::Max(0, $startupBudget - $startupClock.ElapsedMilliseconds)
                if ($remaining -gt 0) { Start-Sleep -Milliseconds ([Math]::Min(100, $remaining)) }
            }
        }
        throw "Instance '$InstanceName' exceeded its $StartupTimeoutSeconds second startup timeout while QEMU still owns the disk. runtime.json remains STARTING; do not mutate storage until status is reconciled. Last QMP error: $lastError"
    }
    catch {
        if ($null -ne $launch -and -not $runtimePublished -and $null -ne (Get-EzVmRuntimeProperty $launch 'Process')) {
            try {
                if (-not $launch.Process.HasExited) { $launch.Process.Kill() }
            } catch { }
        }
        throw
    }
    finally {
        if ($null -ne $launch -and $null -ne (Get-EzVmRuntimeProperty $launch 'Process')) {
            try { $launch.Process.Dispose() } catch { }
        }
        if ($null -ne $qmpAllocationLock) { try { $qmpAllocationLock.Dispose() } catch { } }
        $lock.Dispose()
    }
}

function Stop-EzVmInstance {
    [CmdletBinding()]
    param(
        [string]$Root = $script:EzVmDefaultRoot,
        [Parameter(Mandatory = $true)][string]$InstanceName,
        [ValidateRange(1, 3600)][int]$ShutdownTimeoutSeconds = 60,
        [scriptblock]$ProcessProvider,
        [scriptblock]$QmpInvoker
    )

    Assert-EzVmStorageInstanceName -Name $InstanceName
    $lock = Enter-EzVmInstanceLifecycleLock -Root $Root -InstanceName $InstanceName
    try {
        $status = Get-EzVmInstanceStatus -Root $Root -InstanceName $InstanceName -ProcessProvider $ProcessProvider
        if ($status.state -eq 'ABSENT') { throw "Instance '$InstanceName' does not exist." }
        if (@('CREATED', 'STOPPED') -ccontains $status.state) {
            return [pscustomobject][ordered]@{ name = $InstanceName; state = 'STOPPED'; alreadyStopped = $true }
        }
        if (@('RUNNING', 'STARTING', 'STOPPING') -cnotcontains $status.state) {
            throw "Instance '$InstanceName' cannot be stopped safely from lifecycle state '$($status.state)': $($status.reason)"
        }

        $runtime = Get-EzVmRuntimeStateFile -Root $Root -InstanceName $InstanceName
        $identity = Get-EzVmRuntimeIdentityResult -Runtime $runtime -ProcessProvider $ProcessProvider
        if (-not $identity.Match) { throw "Refusing power action because QEMU process identity is not proven: $($identity.Reason)" }

        $runtime.state = 'STOPPING'
        $runtime.lastObservedAt = [DateTime]::UtcNow.ToString('o')
        Write-EzVmRuntimeStateFile -Root $Root -InstanceName $InstanceName -Runtime $runtime
        $shutdownClock = [Diagnostics.Stopwatch]::StartNew()
        $shutdownBudget = $ShutdownTimeoutSeconds * 1000
        $null = Invoke-EzVmRuntimeQmp -HostAddress $runtime.qmpHost -Port ([int]$runtime.qmpPort) -Command 'system_powerdown' -TimeoutMilliseconds ([Math]::Min(3000, $shutdownBudget)) -QmpInvoker $QmpInvoker
        $lastIdentityObservationError = $null
        while ($shutdownClock.ElapsedMilliseconds -lt $shutdownBudget) {
            try {
                $observed = @(Get-EzVmObservedQemuProcesses -ProcessId ([int]$runtime.pid) -ProcessProvider $ProcessProvider)
                $current = $null
                if ($observed.Count -eq 1) {
                    # Identity validation performs another fresh process query.
                    # QEMU may exit between these two observations, so both must
                    # share the same bounded retry for unreadable terminating PIDs.
                    $current = Get-EzVmRuntimeIdentityResult -Runtime $runtime -ProcessProvider $ProcessProvider
                }
                $null = Get-EzVmRuntimeRemainingMilliseconds $shutdownClock $shutdownBudget 'Graceful shutdown observation'
                $lastIdentityObservationError = $null
            }
            catch {
                # Windows can briefly retain a terminating PID after QEMU has
                # exited far enough that CIM no longer exposes its command line.
                # That state is not proof of exit, so never mark STOPPED from the
                # query failure itself. Retry within the existing bounded shutdown
                # deadline and require either a proven reused identity or
                # an empty PID observation before releasing storage ownership.
                $lastIdentityObservationError = $_.Exception.Message
                $remaining = [Math]::Max(0, $shutdownBudget - $shutdownClock.ElapsedMilliseconds)
                if ($remaining -gt 0) { Start-Sleep -Milliseconds ([Math]::Min(100, $remaining)) }
                continue
            }

            if ($observed.Count -eq 0) {
                $runtime.state = 'STOPPED'
                $runtime.lastObservedAt = [DateTime]::UtcNow.ToString('o')
                $runtime.stoppedAt = $runtime.lastObservedAt
                Write-EzVmRuntimeStateFile -Root $Root -InstanceName $InstanceName -Runtime $runtime
                return [pscustomobject][ordered]@{ name = $InstanceName; state = 'STOPPED'; alreadyStopped = $false }
            }
            if ($observed.Count -eq 1) {
                if (-not $current.Match -and @('missing', 'reused') -ccontains $current.Kind) {
                    $runtime.state = 'STOPPED'
                    $runtime.lastObservedAt = [DateTime]::UtcNow.ToString('o')
                    $runtime.stoppedAt = $runtime.lastObservedAt
                    Write-EzVmRuntimeStateFile -Root $Root -InstanceName $InstanceName -Runtime $runtime
                    return [pscustomobject][ordered]@{ name = $InstanceName; state = 'STOPPED'; alreadyStopped = $false }
                }
                if (-not $current.Match) {
                    throw "QEMU process identity became ambiguous during graceful shutdown: $($current.Reason)"
                }
            }
            else {
                throw 'QEMU process identity became ambiguous during graceful shutdown.'
            }
            $remaining = [Math]::Max(0, $shutdownBudget - $shutdownClock.ElapsedMilliseconds)
            if ($remaining -gt 0) { Start-Sleep -Milliseconds ([Math]::Min(100, $remaining)) }
        }
        $detail = if ([string]::IsNullOrWhiteSpace([string]$lastIdentityObservationError)) {
            ''
        } else {
            ' Last process-identity observation error: ' + [string]$lastIdentityObservationError
        }
        throw "Guest powerdown was requested, but instance '$InstanceName' did not exit within $ShutdownTimeoutSeconds seconds. QEMU was not killed; runtime state remains STOPPING.$detail"
    }
    finally { $lock.Dispose() }
}
