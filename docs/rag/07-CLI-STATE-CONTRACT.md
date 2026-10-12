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

The foundation initially implemented `help` and `version`; the current command
surface is listed in the README and the implemented subsystem sections below.
An empty invocation, or
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
resource/port allocation and host-capability checks are implemented by the
registry, lifecycle and preflight subsystems.

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
  "baseId": "base-<sha256>",
  "profile": "normal",
  "cpus": 4,
  "memoryMiB": 8192,
  "sshPort": 22001,
  "createdAt": "...",
  "provisioningProfile": "coding-default",
  "provisioningVersion": 1
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

## Bootstrap and doctor CLI (EZVM-002)

`bootstrap` installs only the reviewed repository-local QEMU runtime. Human output
reports whether a matching runtime was reused or newly promoted and always prints
absolute managed QEMU paths. Structured output uses the standard result envelope.

`doctor` returns an overall status and independent checks using exactly
`ready`, `supported-but-not-configured`, `unsupported`, or `unknown`.
Known missing configuration takes precedence over unknown optional evidence, and
unsupported host requirements take highest precedence. WHPX remediation is printed
as guidance only; no command path performs elevation or feature enablement.

## Source-image CLI (EZVM-003)

`base acquire` is a two-token public command. It accepts the global `-Json`
switch in the same manner as `help` and `version`.

Human output identifies whether the image was newly acquired or an already valid
cache entry was reused, followed by its managed path, SHA-256 and publication.
Structured output uses the normal command-result envelope and returns the same
source identity in `data`.

Acquisition creates only generated state beneath `runtime/cache/source-images`.
It does not load mutable guest state, boot QEMU or modify the verified source
image.

## Prepared-base CLI (EZVM-004)

`base build` is now a public two-token command. Production CLI execution uses
WHPX and refuses prerequisite failure; it does not silently substitute TCG.
Hosted qualification may call the module build function with explicit
`Accelerator tcg`, and that accelerator is recorded in base provenance.

On success, human output reports the content-addressed base ID, image/manifest
paths, SHA-256 and actual accelerator. Structured output uses the normal JSON
envelope.

Prepared-base durable state is `runtime/bases/<base-id>/base.qcow2` plus
`manifest.json`. The manifest contains no relocatable absolute paths. Temporary
`.build-*` and `.publish-*` directories are not authoritative bases.
## Storage API boundary (EZVM-005)

EZVM-005 intentionally adds no final public instance-create/reset command. It
exports reusable module APIs for subsequent issues:

- instance storage path derivation;
- relative backing calculation;
- lifecycle-guard construction;
- machine-readable image/backing-chain inspection;
- overlay creation and complete-chain validation;
- stopped-image integrity diagnostics;
- reset-safe overlay replacement.

The lifecycle guard state `proven-safe` is the only state that permits storage
mutation or offline integrity checking. EZVM-006 must produce that evidence from
its process/state reconciliation; callers cannot rely on a missing runtime file
or stale PID as an implicit STOPPED result.

No absolute prepared-base path is required as durable instance authority. Later
instance metadata should record the base ID/fingerprint and derive the current
path from the active ezvm root.

## Implemented runtime CLI and state (EZVM-006)

The public lifecycle commands are:

~~~text
ezvm status <name>
ezvm start <name>
ezvm stop <name>
~~~

`start` uses WHPX and does not expose an implicit TCG fallback. `status`
reconciles durable intent, runtime evidence and Windows process identity.
`stop` uses host-local QMP `system_powerdown` and waits for clean process
exit. A shutdown timeout returns failure and leaves STOPPING ownership evidence;
QEMU is not silently killed.

The initial EZVM-006 durable instance-intent schema was the following historical
subset. It is no longer sufficient; the complete current schema is specified
under named instances below.

~~~json
{
  "schemaVersion": 1,
  "name": "example",
  "baseId": "base-<sha256>",
  "cpus": 4,
  "memoryMiB": 8192,
  "createdAt": "<ISO timestamp>"
}
~~~

The runtime-state schema records:

~~~json
{
  "schemaVersion": 1,
  "instanceName": "example",
  "state": "RUNNING",
  "pid": 1234,
  "processStartTimeUtc": "<ISO timestamp>",
  "qemuExecutable": "<ephemeral derived absolute path>",
  "argumentFingerprint": "<sha256>",
  "launchId": "<32 hex>",
  "qmpHost": "127.0.0.1",
  "qmpPort": 49152,
  "accelerator": "whpx",
  "startedAt": "<ISO timestamp>",
  "lastObservedAt": "<ISO timestamp>",
  "stoppedAt": "",
  "qemuLog": "<ephemeral derived absolute path>",
  "serialLog": "<ephemeral derived absolute path>"
}
~~~

Absolute paths in `runtime.json` are ephemeral launch evidence and are
revalidated/regenerated after relocation; they are not durable portable intent.

Lifecycle status may report ABSENT, CREATED, STARTING, RUNNING, STOPPING, STOPPED,
STALE or UNKNOWN. Only CREATED/STOPPED can yield the storage layer's
`proven-safe` guard.


## SSH/access CLI and state (EZVM-007)

The additional public commands are:

~~~text
ezvm ssh <name>
ezvm exec <name> -- <command> [arguments...]
ezvm copy-to <name> <host-file> <guest-path>
ezvm copy-from <name> <guest-path> <host-file>
~~~

`start <name>` now returns only after the existing QEMU lifecycle reaches
RUNNING **and** the EZVM-007 SSH readiness contract reaches READY. The process
lifecycle itself remains EZVM-006 RUNNING/STOPPING/etc.; READY is deliberately a
separate access/provisioning layer rather than a new process-ownership state.

The per-launch `access.json` schema is version 2 with EZVM-009:

~~~json
{
  "schemaVersion": 2,
  "instanceName": "example",
  "launchId": "<32 lowercase hex>",
  "baseId": "base-<sha256>",
  "sshHost": "127.0.0.1",
  "sshPort": 22000,
  "sshUser": "coder",
  "state": "PROVISIONING",
  "cloudInstanceId": "ezvm-example-...",
  "profile": "normal",
  "provisioningProfile": "coding-default",
  "provisioningVersion": 1,
  "provisioningDigest": "<sha256>",
  "readyAt": ""
}
~~~

READY requires a non-empty ISO `readyAt`, matched guest identity/completion
documents and successful live coding-environment checks. The file contains no
absolute relocatable path and is stale if its launch ID no longer matches the
current runtime state. Version 1 access state cannot authorize READY under the
new contract; access evidence must be regenerated by a supported instance start.

`exec` treats SSH exit 255 as a transport/authentication failure. Other non-zero
exit codes are the remote command result and are propagated to the ezvm process.
The module API preserves the captured remote stdout/stderr. At the CLI boundary a
remote non-zero result uses the normal failure envelope
(`success: false`, `data: null`, `error.code: remote_command_failed`) while
retaining the guest exit code and bounded stdout/stderr evidence in the error
message; it is never represented as successful execution. The `--` separator
ends ezvm global switch parsing, so a remote argument literally named `-Json`
stays a guest argument. Interactive `ssh` rejects ezvm `-Json` because the
child owns the console streams.

The copy commands are intentionally directional and transfer one file in
EZVM-007. All SSH/scp commands use the managed controller key and scoped
known-hosts state.

## Named instances and registry (EZVM-008)

The implemented public additions are:

~~~text
ezvm create <name> [-Profile light|normal|heavy] [-BaseId <base-id>] [-Cpus <n>] [-MemoryMiB <n>]
ezvm list
~~~

If `-Profile` is omitted, `defaultProfile` is used. CPU/RAM command-line
overrides replace the selected profile defaults while the selected profile name
remains durable provenance. If `-BaseId` is omitted, create selects the valid
prepared base with the newest manifest `builtAt` timestamp. Explicit base IDs
are validated before use.

The `instance.json` schema remains version 1 during the pre-v0.1 development
line. EZVM-008 introduced the complete durable intent, and EZVM-009 changes
the default provisioning identity to `coding-default`/`1`:

~~~json
{
  "schemaVersion": 1,
  "name": "example",
  "baseId": "base-<sha256>",
  "profile": "normal",
  "cpus": 4,
  "memoryMiB": 8192,
  "sshPort": 22001,
  "createdAt": "<ISO timestamp>",
  "provisioningProfile": "coding-default",
  "provisioningVersion": 1
}
~~~

Legacy EZVM-006 intent containing only name/base/resources/time is explicitly
refused with migration/recreation guidance rather than silently assigning new
durable resources during a read.

`list` reconstructs registry state directly from instance directories. A
missing or malformed `instance.json`, unsafe directory name, case-insensitive
portable name collision, or directory/intent name disagreement is an error; no
separate global index is trusted over the recoverable instance authority.
Structured output returns one stable command envelope with `count` and
`instances`.

Named-resource creation and start operations use the bounded SSH allocation lock.
A stale lock file without a live handle is reusable; an active competing holder
causes a bounded failure instead of an unbounded wait.

## Coding profile identity and compatibility (EZVM-009)

`profile` means the `light`/`normal`/`heavy` resource defaults. It is distinct
from `provisioningProfile` and `provisioningVersion`, which select the reviewed
guest recipe. Public `create` uses `coding-default` version 1; it does not yet
expose arbitrary guest-profile selection. `Get-EzVmCodingProfile` validates the
supported name/version and strict manifest schema, then hashes the normalized
manifest and recipe together before the profile can be served to a guest. The
host requires the installed guest sources to agree with this source identity.

`/etc/ezvm/identity.json` uses this schema version 2 identity:

~~~json
{
  "schemaVersion": 2,
  "instanceName": "example",
  "baseId": "base-<sha256>",
  "profile": "normal",
  "cloudInstanceId": "ezvm-example-...",
  "provisioningProfile": "coding-default",
  "provisioningVersion": 1,
  "provisioningDigest": "<sha256>"
}
~~~

`/var/lib/ezvm/ready.json` contains the same fields and adds
`"provisioningState": "complete"`. A file's presence, a wrong profile version
or an incomplete provisioning state cannot satisfy readiness. The host checks
all identity fields and fresh guest tools/account/workspace before publishing
READY access state. The digest binds the resolved repository provisioning
source; it is not a guest credential or proof against guest-root tampering.

Complete existing EZVM-008 intent with `ezvm-core`/`1` remains readable by
`list`, `status` and `stop`, allowing a running older instance to be identified
and shut down. `start` rejects that unsupported coding profile before guest
provisioning and supplies guidance to create a new named instance. No read
rewrites the old intent, replaces its overlay or upgrades guest identity. The
older incomplete EZVM-006 intent remains refused as documented above.

Future version support requires reviewed profile source, schema/resolver and
readiness tests plus an explicit new-instance or migration path. Existing
immutable bases and old overlays must not be modified to make an unsupported
profile appear current.
