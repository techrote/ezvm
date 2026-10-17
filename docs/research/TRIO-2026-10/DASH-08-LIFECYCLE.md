# DASH-08 lifecycle investigation

Status: IN PROGRESS; parent issue #34 remains open. TRIO remains paused.

## Reconciled source and preservation boundary

The selected accepted baseline is main `d5265c804d0d8494d8171482a85aca563b181e05`, tree `9416befc914dafcdefbc5c9bcc605b1ddd53e082` (DASH-01 / #27 accepted). DASH-02 PR #42 is separate and is not a dependency. Its branch, pending release qualification and the owner's original Windows/QEMU session are not test targets.

Current source pins before implementation:

- `src/EzVm/Runtime.ps1`: Git blob `59cae4784a0d36b7b3a964a0f495772fbf61f801`.
- `src/EzVm/Keys.ps1`: Git blob `da6bcf712ff2b4fd05bb6d3ad8593389c7738f28`.
- `src/EzVm/Ssh.ps1`: Git blob `89e27fbd3dae2df1fae11128ab23eabe9f6a69da`.

The two historical owner patches are reported by the field study. Their private working-tree preimages/diffs are not available in this cloud checkout; these source pins identify the assessed committed baseline, not a claim that private patch applicability was reproduced. No owner working tree or live VM is accessed, reverted, cleaned or adopted as a fixture. Preserve original research observations and evidence-index bytes.

## Pre-implementation finding matrix

This matrix precedes behavior changes. Historical reports are not new reproductions.

| Finding | Current source assessment | Reproduction / disposition |
|---|---|---|
| FR-14 captured start pipe | `Start-EzVmRuntimeProcess` uses `ProcessStartInfo` with no explicit standard handles; `CreateNoWindow` alone does not establish capture independence. | Suspected retained defect. Execute a source-only disposable native child beneath a captured PowerShell caller. Record parent exit and pipe EOF separately. Windows result pending. |
| FR-15 standard-user key ACL | Existing managed-key contract requires exact current-user ACL, pair validation, lock and reparse/hard-link refusal. | Historical host incident not reproduced here. Preserve Keys.ps1; actual standard-user clean-host qualification remains required. |
| FR-15 first-boot/WHPX reboot | Schema-2 launch allows identity initialization reboot; schema-1 preserves its old no-reboot policy. No implicit TCG fallback. | Preserve accepted behavior. Physical WHPX unavailable; SKIP is not PASS or an exclusion of supported Windows. |
| FR-15 CPU features | WHPX and explicit TCG argument policies are distinct; only TCG requests cpu=max. | No new current-source CPU defect established. No speculative CPU-model or mitigation change. Record actual host/QEMU/guest during T04. |
| FR-15 SSH selection | Managed SSH transport resolves ssh/scp/keygen explicitly; ssh-keyscan is excluded. Strict scoped trust is separate from candidate learning. | Preserve accepted selection/trust policy. Missing-tool and readiness regressions remain authoritative software evidence, not standard-user hardware acceptance. |
| FR-15 timeouts | Guest identity/cloud-init/coding-ready/live tools already share an absolute readiness deadline. QMP connect/greeting/capability/command currently each get the whole per-call timeout; startup accepts a returned RUNNING result without a post-call deadline check. | Separate deterministic deadline counterexamples are required before changing those boundaries. Do not simply increase existing budgets. |
| Stale/partial ownership | Runtime requires PID, executable, start time, instance marker and argv fingerprint; STALE/UNKNOWN refuse storage mutation. | Retain existing guards and extend cut-point/late-result tests. No guessed repair or reused-PID kill. |

## Evidence boundaries

The initial `scripts/Measure-Dash08StartPipe.ps1` run measures the baseline process boundary on GitHub-hosted Windows PowerShell 5.1. It creates only a bounded native fixture in a new temporary directory. It records actual source commit/tree and runtime, parent exit, pipe-drain observation and surviving simulated VM. Its source archive is a tracked-source qualification artifact, not a release or runtime bundle.

DASH-08-T04 is not executed by that harness: no real guest, standard-user Windows desktop, WHPX, physical CPU feature or user-owned start session is involved. A successful reproduction does not close FR-14/15 or issue #34.

## Confirmed reproduction and software repair

The pre-implementation matrix above is retained as the investigation record at
`fe40c18989625f93111c3ba36748205596b0e59e`, not silently rewritten as later evidence.
[Baseline Windows run 38981355586](https://github.com/techrote/ezvm/actions/runs/38981355586)
completed on Windows Server 2022 / PowerShell `5.1.20348.5622`. Its exact tree was
`dc5234ce90cf961f06c3aa7b2331e174d90a8e4e`; Runtime.ps1 SHA-256 was
`b86122f56df1f849d0f5110828519718882e9ea4fd254bff0fb252c7b68a163b`.
The actual receipt recorded parentExited=true, outputDrainedBeforeFixtureStop=false,
fixtureSurvivedParent=true and fixtureStopped=true. This confirms the captured-pipe
mechanism. It does not claim to replay the original owner's incident.

The archived baseline [measurement script](https://github.com/techrote/ezvm/blob/fe40c18989625f93111c3ba36748205596b0e59e/scripts/Measure-Dash08StartPipe.ps1)
is replaced in the candidate checkout by a retained legacy negative control and
the full process-boundary qualifier. Archive artifact `12081192397`, SHA-256
`6986d89fe9d34f0b36cd4bed88000fd4b9589b363c83f2b6dc6ad133741069f6`, includes the exact
tracked-source archive and measured JSON. The reconstructed local source tree was
verified against that Git tree; local Linux did not execute the Windows code.

[Software child #44](https://github.com/techrote/ezvm/issues/44) owns the scoped
implementation. Native launch explicitly supplies NUL stdin and direct exclusively
created stdout/stderr files through a three-handle inheritance allowlist. Exact
process-handle/creation evidence is pinned before handoff. No caller-side draining
thread, shell, elevation, job escape or global service is introduced. Per-launch
native log paths derive from qemuLog and do not modify its closed state schema.

QMP now uses one monotonic operation budget; startup verifies both remaining time
and process identity after the QMP answer, and graceful stop includes the powerdown
command in its existing budget. Late positive answers cannot publish RUNNING or
STOPPED. Unpublished-child cleanup and published-STARTING timeout have separate
actual native-process tests. Existing Keys.ps1, Ssh.ps1, QEMU argv/mitigation policy,
original research, owner-patch boundaries and readiness checks remain unchanged.

The full amendment and its precise budget scope are in the
[core lifecycle contract](../../rag/DASH-08-LIFECYCLE-CONTRACT.md).

## Test coverage and limitations

| Original case | Candidate evidence |
|---|---|
| T01 | New native tests retain the legacy pipe-EOF counterexample and exercise caller exit/interruption, continuing heartbeat/log writes, output flood, EOF-only input, unrelated inheritable handles, spaces/Unicode/quotes/empty argv and no-clobber launch errors. Native fixtures are not actual public WHPX start acceptance. |
| T02 | New real loopback QMP socket tests distinguish a total deadline from independent per-phase waits; late start/stop answers stay held. Existing Ssh.Tests.ps1 and CodingReadiness.Tests.ps1 cover unreachable SSH, cloud-init pending/failed, identity mismatch, absent tools, stale READY and parent-deadline expiry. The complete core suite remains required. |
| T03 | New identity-change and real before/after-publication child tests supplement Runtime.Tests.ps1 stale/reused PID, corrupt metadata, alternate owners, lock and fingerprint cases; Ssh.Tests.ps1 covers port collisions and explicit tool selection. No unrelated VM is a target. |
| T04 | NOT EXECUTED / SKIP in hosted fixtures. Standard-user supported Windows/WHPX, physical CPU features and the original ACL/first-boot incidents are not qualified by native stubs or TCG. Parent #34 remains open. |

The dedicated clean-checkout Windows x64 lane runs the 11 DASH-08 software tests
on Windows PowerShell 5.1 and the repository's pinned PowerShell 7. Its JSON receipts
record actual source commit/tree, relevant source SHA-256, OS/runtime, each case and
measurements. A missing, empty or skipped mandatory software set fails. T04 is a
separate explicit SKIP with originalIssueAcceptance=false; no total hides it.

Initial hosted feedback corrected test assumptions, not a lowered target: an
inherited unused pipe handle can delay EOF without carrying console bytes; a
correctly detached caller can exit before fixture initialization; JSON array
pipeline enumeration differs across the two supported PowerShell engines. The
negative-control EOF assertion, native lifetime/input/output assertions and exact
argv checks are retained. Current PR/check receipts, rather than an earlier green
revision or static prose, are authoritative for the candidate's actual result.

Pre-publication software qualification at `17aa8a58357c33d98e9b54c3095b38e01a175de7`,
tree `dbf71dc26e702c5fbd5914eb56e53893622ac5b9`, passed all **11/11** new cases with
zero failures or software skips on both PowerShell `5.1.20348.5622` and `7.6.6` in
[run 38983985886](https://github.com/techrote/ezvm/actions/runs/38983985886).
Downloaded archive digests and every source hash in both receipts were independently
compared to the authored candidate bytes. This is not the later publication-head
full-CI or accepted-main result; required checks must still follow that exact head.

| Receipt | Raw JSON SHA-256 | Artifact |
|---|---|---|
| PowerShell 5.1 | `587640e479deba1ab4f7a2716c9eba90250d1d8acb15bdd7f8dd3957cbc4e17e` | `12082531926` |
| PowerShell 7 | `ce003724ae99e4306b5a0c9aa7a42bb944b62f4b839dbb2f9524f0372fb9785e` | `12082610633` |

The 1500 ms total-QMP delayed cases expired at measured 1510 ms / 1502 ms,
respectively (scheduler overhead is reported, not hidden). Corrected captured
native scenarios took 1334 ms / 1993 ms including fixture checks and cleanup; these
are not guest-boot latency or dashboard performance claims. T04 stayed SKIP.

The existing first-party full Windows CI and real release qualification remain
required. The branch reuses PR #43's identical four-file GitHub-only runner migration
so no new workflow targets the superseded runner. Existing DASH-02 and migration
branches/runs are not changed, cancelled or rerun. The accepted DASH-01 specification
is reconciled with the identical already-published document from PR #42; its code,
corpus, original receipts and dependency graph are not changed.

## T04 operator qualification handoff — not executed

Use only a newly approved disposable checkout/root and disposable guest on a
supported Windows 10 2004+ or Windows 11 x64 host with configured WHPX. Do not use
the original TRIO root, keys, live QEMU session or either private owner patch as a
fixture. Record the actual source commit/tree, clean status, OS/build, CPU, firmware
virtualization, PowerShell, managed QEMU/SSH paths and reviewed payload provenance.
Record `whoami /groups` or equivalent token evidence proving the runtime is
unelevated; a configured feature is not proof of accelerator execution.

Follow [WHPX-QUALIFICATION.md](../../WHPX-QUALIFICATION.md) for doctor, reviewed
bootstrap/base preparation, fresh `create dash08-whpx -Profile normal`, public
WHPX start, authenticated coding readiness, exec, graceful stop, stopped image
validation and portability check. Apply its stop conditions without relaxing any
mitigation, readiness criterion, identity check or supported-host policy.

For the captured-start observation, use Windows PowerShell 5.1 in that disposable
root after its host/base preconditions pass. The timeout below is a capture guard,
not a changed product readiness budget; on this engine the process helper's timeout
cleanup addresses only its direct caller, not a process tree:

~~~powershell
Import-Module .\src\EzVm\EzVm.psd1 -Force
$root = (Get-Location).Path
$config = Get-EzVmConfiguration -Root $root
$clock = [Diagnostics.Stopwatch]::StartNew()
$result = Invoke-EzVmProcess -FilePath (Join-Path $PSHOME 'powershell.exe') `
  -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy',
    'Bypass', '-File', (Join-Path $root 'ezvm.ps1'), 'start', 'dash08-whpx', '-Json') `
  -WorkingDirectory $root -TimeoutSeconds ([int]$config.timeouts.processSeconds + 15)
$clock.Stop()
$result
$clock.Elapsed
.\ezvm.ps1 status dash08-whpx -Json
~~~

Retain exit code, complete stdout/stderr, capture-completion elapsed time, READY
stage evidence, actual launch identity and the native/serial/QEMU logs. Confirm the
intended same process remains alive after the capture returns, and execute an
approved harmless guest command before graceful stop. Repeat caller interruption
only at a separately approved post-publication point with the exact owned caller
handle; never kill a tree or numeric PID guessed from old state. Preserve metadata
and diagnostics if interruption prevents a clean public result.

STOP on unsupported/unconfigured doctor, wrong source/root, elevated runtime,
ambiguous ownership, ACL/pair or SSH selection failure, WHPX/CPU initialization
failure, READY timeout, changed identity, storage/backing failure, non-draining
capture, lost guest lifetime or unproven STOPPED. Do not delete runtime evidence,
relax security mitigations, force-open disks, adopt another process or retry by
changing acceptance. Mark the exact case FAIL/SKIP and retain raw evidence outside
published source; publish only reviewed redacted receipts. Accepted-revision
verification is still required after any resulting fix. TRIO remains paused.
