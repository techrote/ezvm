# DASH-05 — Add the durable command broker and operator pause/steering controls

Status: **PLANNED** | Priority: **P0** | GitHub issue: **not published**

Dependencies: [DASH-11](DASH-11-recovery-and-performance-gates.md).
Research: TRIO-FR-01, TRIO-FR-18 in the [field register](../../../research/TRIO-2026-10/README.md).

Read the [programme and common closure rules](../README.md) plus these RAG contracts:

- [00-SCOPE-AND-STATE](../../../rag/dashboard/00-SCOPE-AND-STATE.md)
- [03-CONTROLS-AND-REVIEW](../../../rag/dashboard/03-CONTROLS-AND-REVIEW.md)
- [04-CAPACITY-AND-MODELS](../../../rag/dashboard/04-CAPACITY-AND-MODELS.md)
- [06-TESTING-RELEASE-AND-RESEARCH](../../../rag/dashboard/06-TESTING-RELEASE-AND-RESEARCH.md)
- [08-TESTING-CI-RELEASE](../../../rag/08-TESTING-CI-RELEASE.md)

## Problem and baseline

Pause, retry and crash behavior must be correct before the UI can send prompts or launch/interrupt owned workers.

At prototype `d692be6`: The dashboard is read-only; there is no durable command owner. The paused TRIO policy is observed, not controlled by the viewer.
Reconcile the selected revision before editing; preserve working implementation.

## Implementation

1. Implement a separately testable typed command service with one writer per scope, expected revisions, stable target ownership and journaled intent/dispatch/acknowledgment/verified-result states.
2. Provide explicit pause-dispatch, supported drain, interrupt, resume and steering semantics. Show pending/failed/unsupported controls; never use generic OS suspension as pause.
3. Reconcile uncertain dispatch after crash/timeout before retry. Add a minimal conservative admission reservation interface; full configurable pools arrive in DASH-07, not an unguarded launch path.
4. Provide preview/target/scope and policy checks independent of UI controls. Define explicit controller lifetime versus viewer detach; migration/restoration begins held.

## Acceptance criteria

- [ ] Pause survives quota reset, retry timers and controller restart and blocks new prompts/launches in its scope.
- [ ] A duplicate click or crash around dispatch cannot blindly duplicate a worker/prompt; ambiguous effects require reconciliation.
- [ ] Only exact owned identities can be controlled; stale revisions and unsupported capabilities are refused.
- [ ] Acknowledged interruption does not claim children/tools stopped without observation; steering acknowledgment is not claimed obedience.

## Test cases

These are required future cases, not claims of existing or passing tests. Use
fixtures/process stubs first; physical/live qualification is separately identified.

- **DASH-05-T01 — Dispatch crash matrix:** Crash before intent, before send, after send before ack and after ack; count actual stub worker/prompt effects and require reconciliation where idempotency is unavailable.
- **DASH-05-T02 — Pause precedence:** Pause races retry, quota restoration and restart; no new dispatch occurs. Drain and immediate interrupt preserve different pending states.
- **DASH-05-T03 — Ownership and concurrency:** Two viewers, expired writer lease, reused session/PID and unrelated session cannot bypass the writer or target checks.
- **DASH-05-T04 — Interrupt/steer truth:** Abort ack with a running tool remains stopping; unsupported drain is disabled; queued/expired/delivered steering is attributable to its intended session.
- **DASH-05-T05 — Viewer lifetime:** Close/reopen a viewer without killing controller/workers or resuming paused work; controller exit policy and recovery are exercised explicitly.

## Out of scope

Automatic main merge, provisioning, subscription/account operations, global process suspension and control of the paused TRIO programme during development.

## Closure evidence

Command/state schema, capability tests, crash/dispatch-count oracles, pause persistence results and explicit lifetime ADR.

Apply the programme's common closure rules: original criteria and tests accounted
for, actual source/result identities, reviewed implementation and RAG updates, and
verification at the accepted revision. A dependent gate stays closed until those
prerequisites are accepted. This document does not authorize a TRIO restart.
