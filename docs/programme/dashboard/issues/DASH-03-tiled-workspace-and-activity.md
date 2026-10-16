# DASH-03 — Finish mdbm-style tiles, saved layouts and evidence browsing

Status: **PLANNED** | Priority: **P0** | GitHub issue: **not published**

Dependencies: [DASH-02](DASH-02-scoped-adapters-and-identities.md).
Research: TRIO-FR-08, TRIO-FR-13 in the [field register](../../../research/TRIO-2026-10/README.md).

Read the [programme and common closure rules](../README.md) plus these RAG contracts:

- [00-SCOPE-AND-STATE](../../../rag/dashboard/00-SCOPE-AND-STATE.md)
- [02-TERMINAL-INTERACTION](../../../rag/dashboard/02-TERMINAL-INTERACTION.md)
- [06-TESTING-RELEASE-AND-RESEARCH](../../../rag/dashboard/06-TESTING-RELEASE-AND-RESEARCH.md)
- [08-TESTING-CI-RELEASE](../../../rag/08-TESTING-CI-RELEASE.md)

## Problem and baseline

People must navigate long-running work and evidence without many memory-heavy viewer processes or accidental worker input.

At prototype `d692be6`: The prototype has clickable tiles, splitter drag/cancel, palette, focus/hide/restore and bounded transcript tabs. It has no saved layout, output search/copy, structured report-file browser or physical Windows Terminal qualification.
Reconcile the selected revision before editing; preserve working implementation.

## Implementation

1. Persist versioned layout/preferences atomically and restore valid focus/selection/scroll/filter state. Supply reset-to-default and migration behavior; keep preferences independent of task pause.
2. Add bounded output search/copy, follow/unread indication and explicit truncation/backfill. Browse referenced reports/check artifacts with source/hash/commit status instead of equating model text with a report.
3. Complete keyboard parity, narrow layouts, resize-during-drag and overlay focus behavior. Add an attention/waiting-reason view using declared observations, with unavailable future actions explained.
4. Record the prompt_toolkit decision and revisit trigger in an ADR. Keep one collector feed; do not create a full OpenCode client per tile. Exact external viewer attachment is separate from read-only transcript input.

## Acceptance criteria

- [ ] Mouse and keyboard achieve the same view operations; a dismiss click never reaches an underlying control.
- [ ] Hide/restore and restart preserve legitimate preferences; corrupt/migrated layouts recover without affecting worker state.
- [ ] A reader stays on historical output until Follow is chosen; report status reflects actual referenced evidence and stale identity.
- [ ] Actual Windows Terminal checks at 80x24, 120x40 and 160x48 are recorded separately from pipe-parser tests.

## Test cases

These are required future cases, not claims of existing or passing tests. Use
fixtures/process stubs first; physical/live qualification is separately identified.

- **DASH-03-T01 — Interaction matrix:** Real key/SGR parser plus physical mouse: first click after focus change, wheel locality, both-button dividers, Escape rollback, modal dismissal and focus after resize/hide.
- **DASH-03-T02 — Layout persistence:** Crash during preference write, stale tile IDs, out-of-range geometry and smaller restart terminal produce valid reachable panes and preserve the prior recoverable file.
- **DASH-03-T03 — Output handling:** Flood wide/combining Unicode and terminal escape sequences; bound memory, keep scroll position, mark truncation, and prevent clipboard/title effects during read/copy.
- **DASH-03-T04 — Artifact truth:** Uncommitted/missing report, mismatched hash and source changes are visibly distinct from verified committed evidence; PASS prose cannot change acceptance.
- **DASH-03-T05 — Responsiveness:** Measure dispatch/paint separately under a 10-second collector stall; p95 target under 100ms. Record physical-test SKIPs and collector/child overhead.

## Out of scope

Worker prompt input, embedded PTY, automated task acceptance and a wholesale toolkit rewrite without evidence.

## Closure evidence

ADR, layout migration fixtures, keyboard/mouse matrix, artifact identity checks and latency/memory measurements with exact environment.

Apply the programme's common closure rules: original criteria and tests accounted
for, actual source/result identities, reviewed implementation and RAG updates, and
verification at the accepted revision. A dependent gate stays closed until those
prerequisites are accepted. This document does not authorize a TRIO restart.
