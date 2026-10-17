# DASH-08 — Qualify lifecycle prerequisites for dashboard-managed devboxes

Status: **IN-PROGRESS** | Priority: **P0** | GitHub issue: [#34](https://github.com/techrote/ezvm/issues/34)

Dependencies: [DASH-01](DASH-01-evidence-and-replay.md).
Research: TRIO-FR-14, TRIO-FR-15 in the [field register](../../../research/TRIO-2026-10/README.md).

Read the [programme and common closure rules](../README.md) plus these RAG contracts:

- [00-SCOPE-AND-STATE](../../../rag/dashboard/00-SCOPE-AND-STATE.md)
- [05-PROVISIONING-AND-DEVBOX](../../../rag/dashboard/05-PROVISIONING-AND-DEVBOX.md)
- [06-TESTING-RELEASE-AND-RESEARCH](../../../rag/dashboard/06-TESTING-RELEASE-AND-RESEARCH.md)
- [02-HOST-QEMU-CONTRACT](../../../rag/02-HOST-QEMU-CONTRACT.md)
- [03-QCOW2-STATE-CONTRACT](../../../rag/03-QCOW2-STATE-CONTRACT.md)
- [05-NETWORK-SSH-CONTRACT](../../../rag/05-NETWORK-SSH-CONTRACT.md)
- [06-SECURITY-PORTABILITY-CONTRACT](../../../rag/06-SECURITY-PORTABILITY-CONTRACT.md)
- [07-CLI-STATE-CONTRACT](../../../rag/07-CLI-STATE-CONTRACT.md)
- [08-TESTING-CI-RELEASE](../../../rag/08-TESTING-CI-RELEASE.md)
- [DASH-08-LIFECYCLE-CONTRACT](../../../rag/DASH-08-LIFECYCLE-CONTRACT.md)

## Problem and baseline

A dashboard cannot offer reliable start/provision/one-click behavior while process lifetime and readiness errors remain ambiguous.

At prototype `d692be6`: EzVM has lifecycle/readiness contracts and two pre-existing owner patches. Historical TRIO start-pipe and setup incidents are documented; they have not all been re-proven against current source.
Reconcile the selected revision before editing; preserve working implementation.

## Implementation

1. Audit each recorded ACL, first-boot/WHPX, CPU-feature, SSH selection, start-pipe and timeout observation against the selected revision and owner patches. Produce a reproduction/unsupported/not-reproduced matrix before fixing.
2. Split confirmed independent defects into linked child implementation issues if needed; no broad rewrite. Keep this issue open until required lifecycle prerequisites are either fixed and verified or explicitly excluded by supported-host policy.
3. Implement bounded public start completion with independently owned VM lifetime where required; preserve process identity, logs and separate launch/readiness/tool/stop budgets.
4. Improve truthful readiness/recovery errors and standard-user prerequisites through existing PowerShell APIs. Update the relevant core RAG alongside any accepted behavior change.

## Acceptance criteria

- [ ] Public start result completes within its declared budget while the intended guest remains running; output-reader exit does not terminate it.
- [ ] Stale/ambiguous owner state is diagnosed and held, not 'repaired' by guessing or killing a reused PID.
- [ ] Standard-user Windows/WHPX evidence is recorded separately from stubs/TCG and unsupported cases explain remediation.
- [ ] Owner patches and the original live QEMU session are not used as disposable test targets.

## Test cases

These original requirements are retained. The software child adds native-process
and deterministic coverage for T01/T02/T03; existing core regressions remain
required. T04 still requires actual supported-host evidence, not a fixture PASS.

- **DASH-08-T01 — Bounded start lifetime:** A disposable runner holds the simulated VM open after public start returns; timeout/caller interruption preserves the documented process/log ownership.
- **DASH-08-T02 — Readiness stages:** SSH, cloud-init, coding-ready and tool deadlines fail independently with accurate errors and preserved diagnostic evidence.
- **DASH-08-T03 — Identity recovery:** Stale metadata, process-start mismatch, port collision and partial launch refuse unsafe recovery and never touch an unrelated fixture instance.
- **DASH-08-T04 — Standard-user integration:** Run approved dedicated Windows/WHPX start/stop/readiness cases, record exact source/runtime; unavailable hardware is SKIP, not a stub-equivalent PASS.

## Out of scope

Owner-patch cleanup, touching other VMs, the original QEMU start pipe, security/isolation/escape probing and a new global service.

## Closure evidence

Finding/reproduction matrix, narrowly scoped fix refs, core RAG changes, process tests and explicit standard-user/WHPX qualification.

Apply the programme's common closure rules: original criteria and tests accounted
for, actual source/result identities, reviewed implementation and RAG updates, and
verification at the accepted revision. A dependent gate stays closed until those
prerequisites are accepted. This document does not authorize a TRIO restart.

## Implementation checkpoint

Accepted dependency: DASH-01 on main `d5265c804d0d8494d8171482a85aca563b181e05`.
The [pre-fix matrix and qualification handoff](../../../research/TRIO-2026-10/DASH-08-LIFECYCLE.md)
records the captured-start reproduction and the distinct historical/unreproduced
findings. [Software child #44](https://github.com/techrote/ezvm/issues/44) owns the
native handle/deadline repair on `ezvm-034-lifecycle-prerequisites`.

No original acceptance criterion is checked off by this publication. Required
exact-head CI, review, merge/accepted-revision checks and actual standard-user
WHPX evidence remain separate. Parent #34 and PROVISION stay held; TRIO stays
paused. DASH-02 is a parallel issue, not a new prerequisite or a test target.
