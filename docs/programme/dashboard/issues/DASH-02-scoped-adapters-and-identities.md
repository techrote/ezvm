# DASH-02 — Harden scoped observation adapters and registered-worker discovery

Status: **PLANNED** | Priority: **P0** | GitHub issue: [#28](https://github.com/techrote/ezvm/issues/28)

Dependencies: [DASH-01](DASH-01-evidence-and-replay.md).
Research: TRIO-FR-02, TRIO-FR-04, TRIO-FR-11, TRIO-FR-18 in the [field register](../../../research/TRIO-2026-10/README.md).

Read the [programme and common closure rules](../README.md) plus these RAG contracts:

- [00-SCOPE-AND-STATE](../../../rag/dashboard/00-SCOPE-AND-STATE.md)
- [01-OBSERVATION-AND-METRICS](../../../rag/dashboard/01-OBSERVATION-AND-METRICS.md)
- [06-TESTING-RELEASE-AND-RESEARCH](../../../rag/dashboard/06-TESTING-RELEASE-AND-RESEARCH.md)
- [08-TESTING-CI-RELEASE](../../../rag/08-TESTING-CI-RELEASE.md)

## Problem and baseline

Operators need trustworthy identities and bounded coverage; a timed-out or unsampled source must not create an apparent idle/free worker slot.

At prototype `d692be6`: collectors.py and guest_probe.py already read real sources. The prototype samples selected/recent roots (8 by default), not every registered historical root, and assumes the observed OpenCode SQLite layout.
Reconcile the selected revision before editing; preserve working implementation.

## Implementation

1. Separate adapters from snapshot aggregation with explicit capability/version envelopes. Keep current live sources and add schema fixtures; reject unsupported DB/API versions without corrupting or modifying them.
2. Register stable origins/actors and schedule selected, active and older registered roots without starvation. Expose coverage, maximum age, limits and historical-unregistered state rather than claiming exhaustive machine-wide discovery.
3. Reconcile VM launch/process and session/worktree identities; show accepted baseline, candidate and restart root separately when declared. Resolve imported-source assertions and executable wrapper paths correctly.
4. Bound concurrency, read size, poll/backfill cost and cancellation independently. Retain stale samples with errors; improve configuration validation and collector error visibility without network/model probes.

## Acceptance criteria

- [ ] Every registered actor is sampled within a declared bounded cycle or visibly overdue; unrelated roots are not enrolled implicitly.
- [ ] The same session exposed on multiple ports has one identity; partial failure is unknown and cannot authorize admission.
- [ ] A 10-second stalled source leaves other sources and UI input responsive; one in-flight sample per source and zero mutation calls are proven.

## Test cases

These are required future cases, not claims of existing or passing tests. Use
fixtures/process stubs first; physical/live qualification is separately identified.

- **DASH-02-T01 — Identity aliases and reuse:** Two endpoints share one DB/session; reused PID, new launch generation and moved root do not inherit old readiness or control identity.
- **DASH-02-T02 — Coverage fairness:** More registered roots than a polling batch, an old active root and continuously changing selection still receive bounded service; unsampled history stays unobserved.
- **DASH-02-T03 — Failure isolation:** Timeout, malformed payload, unsupported schema, oversized response and missing trust file preserve last-good age/error and never fall back to a write/bootstrap/load.
- **DASH-02-T04 — Source and scope:** Own-root imports pass, another checkout fails; executable wrappers are treated as files; paths with spaces/Unicode and non-enrolled roots follow the scope contract.
- **DASH-02-T05 — Resource bounds:** Stress at least 1,000 session records and delayed endpoints; record polls, CPU/RAM and maximum source age rather than only pass counts.

## Out of scope

Worker commands, broad process discovery beyond declared scope, key creation, inference qualification and native terminal attachment.

## Closure evidence

Adapter capability/version table, recorded schema samples, source/identity fixture results and measured coverage/overhead report.

Apply the programme's common closure rules: original criteria and tests accounted
for, actual source/result identities, reviewed implementation and RAG updates, and
verification at the accepted revision. A dependent gate stays closed until those
prerequisites are accepted. This document does not authorize a TRIO restart.
