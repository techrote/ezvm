# DASH-06 — Build independent review, rework and evidence-gated task queues

Status: **PLANNED** | Priority: **P1** | GitHub issue: **not published**

Dependencies: [DASH-05](DASH-05-durable-commands-and-pause.md).
Research: TRIO-FR-02, TRIO-FR-03, TRIO-FR-04, TRIO-FR-05, TRIO-FR-06, TRIO-FR-13, TRIO-FR-16, TRIO-FR-17 in the [field register](../../../research/TRIO-2026-10/README.md).

Read the [programme and common closure rules](../README.md) plus these RAG contracts:

- [00-SCOPE-AND-STATE](../../../rag/dashboard/00-SCOPE-AND-STATE.md)
- [03-CONTROLS-AND-REVIEW](../../../rag/dashboard/03-CONTROLS-AND-REVIEW.md)
- [06-TESTING-RELEASE-AND-RESEARCH](../../../rag/dashboard/06-TESTING-RELEASE-AND-RESEARCH.md)
- [08-TESTING-CI-RELEASE](../../../rag/08-TESTING-CI-RELEASE.md)

## Problem and baseline

Review and repair must advance the correct candidate with accountable provenance and carried verification budgets.

At prototype `d692be6`: Original criteria, candidate refs, report/provenance rows and CI budgets currently require manual handoff and inspection; the viewer only observes them.
Reconcile the selected revision before editing; preserve working implementation.

## Implementation

1. Implement task/attempt DAG and human queue controls for independent review, selected-finding rework and bounded re-scope. Display dependency/capacity/evidence wait reasons.
2. Freeze candidate/source-tree identity, explicit imports and original criteria; create isolated review inputs and expose same-session/different-session/model/provider independence policy.
3. Keep stable finding IDs and original reports; classify harness versus product versus transport failures. Invalidate a verdict's applicability when source changes.
4. Implement configurable acceptance predicates, whole-issue versus component evidence and actual CI invocation ledger with reserved postmerge capacity. Validate full incoming source histories and every unique contributor record.
5. Generate concise current/restart views from ledger revisions; preserve corrections as new records and show stale handoffs rather than accumulating contradictory authority.

## Acceptance criteria

- [ ] Queue review produces reproducible frozen inputs; later edits cannot silently inherit acceptance.
- [ ] Rework follows selected supported findings with bounded scope and preserves original reports/actual contributor identities.
- [ ] Un-ticketed actual CI runs are reconciled into the same issue budget; unchanged green runs are not repeated for bookkeeping.
- [ ] Integration readiness and postmerge acceptance remain separate; no automatic main merge ships in this issue.

## Test cases

These are required future cases, not claims of existing or passing tests. Use
fixtures/process stubs first; physical/live qualification is separately identified.

- **DASH-06-T01 — DAG and review inputs:** Cycle/missing dependency rejected; frozen author candidate and reviewer root are correct; wrong import fails before a positive finding can qualify.
- **DASH-06-T02 — Evidence versus prose:** PASS/nonzero exit, missing report, stale tree, incorrect report counts and uncommitted output never satisfy acceptance predicates.
- **DASH-06-T03 — Repair history:** New source invalidates old applicability; corrected harness finding preserves original evidence and does not masquerade as a product regression.
- **DASH-06-T04 — Provenance integration:** Report-only import fails; full histories pass; distinct rows with the same branch label survive union; immutable report blobs stay identical.
- **DASH-06-T05 — Budget and restart:** Unexpected actual CI, failed packaging and mandatory postgate consume the configured carried budget; restart preserves candidate/queue and holds dispatch.

## Out of scope

TRIO source implementation, hard-coded six-cycle policy for all projects, inference-quality ranking and automatic main merge.

## Closure evidence

Task/attempt/review schemas, gate predicates, queue/repair fixtures, budget reconciliation tests and restart capsule example.

Apply the programme's common closure rules: original criteria and tests accounted
for, actual source/result identities, reviewed implementation and RAG updates, and
verification at the accepted revision. A dependent gate stays closed until those
prerequisites are accepted. This document does not authorize a TRIO restart.
