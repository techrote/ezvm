# DASH-08 — Native process ownership and lifecycle deadlines

This is the scoped core contract amendment for [DASH-08 / #34](https://github.com/techrote/ezvm/issues/34)
and software child [#44](https://github.com/techrote/ezvm/issues/44). It supplements
[host/QEMU](02-HOST-QEMU-CONTRACT.md), [CLI/state](07-CLI-STATE-CONTRACT.md) and
[test/release](08-TESTING-CI-RELEASE.md). Candidate behavior is not accepted-main
qualification until the required review, CI, merge and accepted-revision checks.
The parent standard-user Windows/WHPX gate and PROVISION remain held.

## Native launch boundary

`Start-EzVmRuntimeProcess` uses the source-bound `RuntimeProcess.cs` helper.
Its in-memory type name includes the normalized source SHA-256, preventing a
previously imported checkout's helper from silently serving changed source.
The helper is lazily compiled by PowerShell; no installed DLL, Python dependency,
new service, interpreter installation or managed-QEMU payload modification is added.
The source-only release already packages tracked `src/` files, including this C# file.

Windows `CreateProcessW` receives the exact absolute executable, existing tested
CRT-quoted argument tokens, explicit working directory and an extended startup
handle list. Exactly three handles are eligible for inheritance: read-only NUL
stdin and two direct diagnostic files. There is no shell, elevation, job breakaway,
caller-owned pipe drainer or implicit standard-input content. Normal caller exit
or interruption does not own the child lifetime. Windows job cleanup, logoff and
host shutdown are not escaped or promised survivable.

`runtime.json` retains its existing closed schema. Given its `qemuLog`, native
stdout is `<qemuLog>.stdout.log` and stderr is `<qemuLog>.stderr.log`. These files
are created exclusively beneath the instance log directory, never in the reviewed
QEMU payload. Existing files are refused, not truncated. Existing serial/QEMU logs
and all argument, launch, process-start and storage identity checks remain binding.
Native launch errors preserve available diagnostics and name the failing boundary.

The native handoff pins the created OS process handle and compares exact creation
time before returning the managed process. A failure before durable ownership
publication may terminate only that newly created, exactly owned process. Once
STARTING is published, timeout or caller exit must not silently abort a VM owning
its disk. Ambiguous/reused identities never authorize a guessed kill or repair.

## Deadline accounting

| Operation | Budget boundary and expiration behavior |
|---|---|
| QMP command | One monotonic timeout covers connect, greeting, capability write/read and command write/read. Close the owned transport before writer disposal; no fresh per-phase budgets or late successful result. |
| Runtime start | Startup budget begins before process launch. Each QMP attempt uses the lesser of 750 ms and the remaining budget. Recheck the process identity and deadline after QMP before RUNNING publication. Timeout preserves STARTING and the storage hold. |
| Graceful stop | The shutdown budget includes `system_powerdown`, rather than starting a new full wait afterward. Late observations cannot release ownership as STOPPED. Timeout preserves STOPPING and never force-kills QEMU. |
| Guest readiness | The existing absolute parent deadline across identity, SSH, cloud-init, coding-ready and live tool checks remains unchanged. No late READY or fresh child budget is introduced. |

Lifecycle-lock acquisition, validated preflight/storage/tool operations and Windows
process queries retain their own existing bounds. These are not hard-real-time
whole-command promises across filesystem stalls, OS scheduling or arbitrary test
callbacks. No accepted numeric target or default timeout is increased. Public
start still requires authenticated coding READY, not merely reachable QMP.

## Required software checks and physical boundary

`tests/Dash08Lifecycle.Tests.ps1` retains the old launch as a negative control and
covers actual Windows process handles, pipe EOF, caller interruption, output flood,
NUL stdin, unrelated inheritable handles, argv/path encoding, log preimages, late
results, QMP sockets and before/after-publication child ownership. It uses only
source-built disposable native fixtures; its injected lifecycle providers are
explicitly not real guest observations.

`scripts/Invoke-Dash08Qualification.ps1` requires a clean exact Windows x64 checkout
and the requested actual PowerShell engine (5.1 or pinned 7), rejects zero/skipped
mandatory software tests, and records source commit/tree, source hashes, runtime,
per-case outcomes and measurements. The full first-party core suite remains
required, including existing SSH, cloud-init, coding, ACL and recovery tests.
Existing real release qualification is not replaced by this short lane.

The [finding matrix and operator handoff](../research/TRIO-2026-10/DASH-08-LIFECYCLE.md)
separates native fixtures, existing software regressions, TCG and actual supported
standard-user Windows/WHPX evidence. T04 is SKIP in hosted fixtures, not PASS.
No physical acceptance, original FR-14/15 incident closure, supported-host exclusion,
dashboard mutation authority or TRIO restart follows from this software candidate.

## Platform references

- [CreateProcessW](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessw)
- [UpdateProcThreadAttribute and HANDLE_LIST](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-updateprocthreadattribute)
- [Redirected child-process input/output and pipe ownership](https://learn.microsoft.com/en-us/windows/win32/procthread/creating-a-child-process-with-redirected-input-and-output)
