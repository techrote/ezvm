# 07 — CLI and state contract

## Public entry point

v0.1 exposes a repository-root PowerShell entry point:

~~~powershell
.\ezvm.ps1 <command> [arguments]
~~~

The public path must work under Windows PowerShell 5.1. PowerShell 7 compatibility is also expected.

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

Precedence should be explicit, for example:

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

## Locks

Operations that mutate global allocation or an instance use bounded lock files or equivalent synchronization.

A stale lock must be detectable using process/time identity rather than requiring manual deletion in normal failure cases.

## Output

Human-readable output is the default.

Structured output such as -Json is desirable for doctor/status/list and should be stable enough for scripts once introduced.

Do not mix progress chatter into structured JSON output.
