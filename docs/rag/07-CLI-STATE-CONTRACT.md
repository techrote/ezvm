# 07 — CLI and state contract

## Public entry point

v0.1 exposes a repository-root PowerShell entry point:

~~~powershell
.\ezvm.ps1 <command> [arguments]
~~~

The public path must work under Windows PowerShell 5.1. PowerShell 7 compatibility is also expected.

## Implemented foundation (EZVM-001)

The initial source version is `0.0.0-dev`; v0.1 is reserved for the release gate.
The entry point imports `src/EzVm/EzVm.psd1`. The module explicitly loads separate
CLI, path, configuration, JSON and process source files.

Only `help` and `version` are implemented at this stage. An empty invocation, or
`-Json` without a command, shows help. Commands and the `-Json` switch are case
insensitive; the switch may occur before or after the command, once. Extra
arguments, unknown switches and unavailable commands fail with exit code 2 and
usage guidance. Execution failures use exit code 1. There are no successful
placeholder implementations of planned commands.

`Get-EzVmRoot` defaults to the module's source location and validates checkout
markers; it does not search the current working directory or require `.git`.
An explicit `-Path` is a complete root, not a request to walk up parent folders.
`Get-EzVmPaths -Root` calculates absolute paths for the configuration and runtime
layout without creating directories. Nothing in the configuration persists those
derived absolute paths. These helpers support filesystem paths containing spaces.

## Planned command surface

The implementation issues may refine exact parameter spelling while preserving these behaviors.

~~~text
ezvm doctor
ezvm bootstrap
ezvm base acquire
ezvm base build
ezvm base list

ezvm create <name> [profile/options]
ezvm list
ezvm status <name>
ezvm start <name>
ezvm stop <name>
ezvm ssh <name>
ezvm exec <name> -- <command>
ezvm copy ...

ezvm reset <name>
ezvm clone <source> <destination>
ezvm export <name> <path>
ezvm import <path> <name>
ezvm destroy <name>
~~~

## Exit behavior

- success returns exit code 0;
- user/config/environment errors return non-zero;
- a remote command's failure must be observable;
- capability-based skips exist in tests, not as a way for production commands to report success.

## Names

Instance names must be validated to a conservative portable character set.

Names map to directory names. Disallow path separators, dot-navigation, drive prefixes, control characters and reserved Windows device names.

## Resource profiles

Initial profiles:

| Profile | vCPU | RAM | Intent |
| --- | ---: | ---: | --- |
| light | 2 | 4 GiB | small agents / scripting |
| normal | 4 | 8 GiB | default coding agent |
| heavy | 8 | 16 GiB | compiles / larger tasks |

Users may override CPU/RAM within validated bounds.

Profiles describe defaults, not host guarantees. doctor/start must detect impossible allocations where practical.

## Persistent configuration

config/defaults.json is repository-controlled defaults.

Optional user/runtime configuration belongs under runtime and is gitignored.

The foundation implements `Get-EzVmConfiguration -Root`: repository defaults are
loaded fresh, then optional `runtime/config.json` is recursively overlaid. The
override must include integer `schemaVersion: 1`, but may omit other fields and
individual nested settings. No input file is changed during a read. Missing
overrides are normal; malformed or unsupported overrides are errors.

Both defaults and the merged result are validated. Field names are case sensitive;
unknown fields, unknown profile names, nulls, arrays in place of objects, numeric
strings, booleans in integer fields and unsupported schemas are refused. The
foundation schema is:

| Setting | Default | Accepted values |
| --- | --- | --- |
| `schemaVersion` | 1 | Integer 1 |
| `defaultProfile` | `normal` | `light`, `normal`, `heavy` |
| `profiles.<name>.cpus` | Profile table above | Integer 1-256 |
| `profiles.<name>.memoryMiB` | Profile table above | Integer 512-1048576 |
| `ssh.portRangeStart` | 22000 | Integer 1024-65535 |
| `ssh.portRangeEnd` | 22999 | Integer 1024-65535, at least the start |
| `timeouts.processSeconds` | 60 | Integer 1-3600 |

These are configuration validation limits, not promises of host capacity. Actual
resource/port allocation and host-capability checks belong to subsequent issues.

Later instance and command implementations extend the precedence to:

1. command-line option;
2. instance.json;
3. runtime user defaults;
4. repository defaults.

## instance.json

Durable instance intent includes fields equivalent to:

~~~json
{
  "schemaVersion": 1,
  "name": "example",
  "baseId": "noble-...",
  "profile": "normal",
  "cpus": 4,
  "memoryMiB": 8192,
  "sshPort": 22001,
  "createdAt": "...",
  "provisioningProfile": "coding-default"
}
~~~

Do not persist absolute paths that can be derived from the relocated ezvm root.

## runtime.json

Ephemeral process observation may include:

~~~json
{
  "schemaVersion": 1,
  "pid": 1234,
  "startedAt": "...",
  "qemuExecutable": "...",
  "argumentFingerprint": "...",
  "state": "RUNNING"
}
~~~

This file is a cache/evidence source, not unquestioned truth.

## Global registry

A generated registry may accelerate list/port allocation, but instance directories remain recoverable sources of durable instance configuration.

If registry and instance.json disagree, fail clearly and provide a repair/reconcile path.

## Atomic writes

JSON state writes use temp-file + validated replacement semantics where possible.

Never truncate the only copy of important instance metadata before replacement content is valid.

`Read-EzVmJson -Path` and `Write-EzVmJson -Path -Value` require a top-level JSON
object with integer `schemaVersion`, defaulting to supported version 1. A caller
can explicitly pass `-SchemaVersion` for its own supported contract; this does
not perform a migration. Writes reject cyclic, excessively deep or non-data
objects before serializing. The parent directory must already exist.

Timestamp values are explicit JSON strings, not .NET date objects. Reads preserve
their exact string form under Windows PowerShell 5.1 and current PowerShell 7
(`DateKind String` on 7.5+). Earlier PowerShell 7 versions without that option
refuse auto-converted timestamps with upgrade guidance instead of silently
changing timezone, formatting or value types. Callers should use ISO strings when
adding the later `createdAt` and `startedAt` fields.

The writer creates a unique temporary file in the destination directory, flushes
it to disk, then uses `System.IO.File.Replace` for existing state or `File.Move`
for a new file. A replacement failure is an error, with temporary-file cleanup;
there is no truncate, delete-then-move or copy-over fallback. Filesystems must
support these normal Windows operations. This provides atomic publication within
the filesystem's guarantees, not a guarantee against every power-loss/storage
failure. Callers still own locks for concurrent read-modify-write operations.

## External process boundary

`Invoke-EzVmProcess -FilePath -ArgumentList` runs a short-lived, non-interactive
executable directly with shell execution disabled. Pass one unescaped string per
argument. It returns `ExitCode`, `StdOut` and `StdErr`; non-zero exits remain
observable, and `-ThrowOnError` additionally raises a contextual exception.
Launch failures and timeouts always throw. Standard input receives immediate EOF
with zero bytes, including no encoding preamble; output is decoded as UTF-8 and
both output streams are drained concurrently.

Current .NET uses an explicit BOM-free `StandardInputEncoding`. .NET Framework
can flush a console-encoding preamble during `Process.Start`, before the caller
can close stdin. For a preamble-bearing console encoding, the helper briefly
uses the same code page without a preamble around `Start`, restoring both the
original encoding and `Console.In` reader in `finally`, including on launch
failure. Preserving the reader also preserves caller-supplied or buffered input.
An encoding that already has no preamble requires no console update.

A bounded per-process named mutex coordinates this Framework adjustment among
ezvm calls in different runspaces. Its wait consumes the command's timeout
budget. Unrelated code must not access `Console.InputEncoding` or `Console.In`
concurrently. If a host without a usable console cannot apply a required encoding
adjustment, the launch fails clearly with guidance to use current PowerShell 7;
it must not send a preamble as a fallback. Redirected callers with no window are
covered by a native raw-byte stdin regression.

PowerShell 7 uses the runtime's token-based `ProcessStartInfo.ArgumentList` when
available. Windows PowerShell 5.1 uses explicit Windows CRT argument quoting,
including empty arguments, embedded quotes and trailing backslashes. Executables
with a different argument grammar need a dedicated adapter. A batch file or
PowerShell script is not an executable: explicitly invoke the intended interpreter
with its arguments when such execution is required.

`-WorkingDirectory` defaults to the current PowerShell filesystem location, and
`-TimeoutSeconds` defaults to 60. The process and stream drain share the timeout;
termination has a bounded two-second grace. .NET Framework can terminate only the
direct child. This helper does not manage long-running QEMU instances or promise
descendant cleanup on PowerShell 5.1; the VM lifecycle issue owns that boundary.
Callers must take care before displaying captured output that may contain secrets.

## Locks

Operations that mutate global allocation or an instance use bounded lock files or equivalent synchronization.

A stale lock must be detectable using process/time identity rather than requiring manual deletion in normal failure cases.

## Output

Human-readable output is the default.

Structured output such as -Json is desirable for doctor/status/list and should be stable enough for scripts once introduced.

Do not mix progress chatter into structured JSON output.

The implemented `-Json` envelope contains `schemaVersion`, `success`, `command`,
`exitCode`, `data` and `error`. Success has `error: null`; a failure has
`data: null` and an error object containing `code` and `message`. JSON is written
as one object on the PowerShell success stream, including for failures, and the
process still exits non-zero on failure. Human-readable failures go to stderr.
This also supports `ezvm.ps1 version -Json | ConvertFrom-Json` in a PowerShell
session. `help` and `version` do not load optional user configuration, allowing
their diagnostic use when that file needs repair.
