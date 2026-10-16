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
