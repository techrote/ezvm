# DASH-02 — Harden scoped observation adapters and registered-worker discovery

Status: **REVIEW** | Priority: **P0** | GitHub issue: [#28](https://github.com/techrote/ezvm/issues/28)

Dependencies: [DASH-01](DASH-01-evidence-and-replay.md), accepted on `d5265c804d0d8494d8171482a85aca563b181e05`.
Research: TRIO-FR-02, TRIO-FR-04, TRIO-FR-11, TRIO-FR-18 in the [field register](../../../research/TRIO-2026-10/README.md).

Read the [programme and common closure rules](../README.md) plus these RAG contracts:

- [00-SCOPE-AND-STATE](../../../rag/dashboard/00-SCOPE-AND-STATE.md)
- [01-OBSERVATION-AND-METRICS](../../../rag/dashboard/01-OBSERVATION-AND-METRICS.md)
- [06-TESTING-RELEASE-AND-RESEARCH](../../../rag/dashboard/06-TESTING-RELEASE-AND-RESEARCH.md)
- [08-TESTING-CI-RELEASE](../../../rag/08-TESTING-CI-RELEASE.md)

## Problem and baseline

Operators need trustworthy identities and bounded coverage; a timed-out or unsampled source must not create an apparent idle/free worker slot.

The integrated prototype read real sources but capped selected/recent polling and assumed the observed SQLite layout. DASH-02 separates read boundaries from cached aggregation and preserves the existing view controls. Core PowerShell and owner patches remain untouched.

## Implementation

1. Separate adapters from snapshot aggregation with explicit capability/version envelopes. Keep current live sources and add schema fixtures; reject unsupported DB/API versions without corrupting or modifying them.
2. Register stable origins/actors and schedule selected, active and older registered roots without starvation. Expose coverage, maximum age, limits and historical-unregistered state rather than claiming exhaustive machine-wide discovery.
3. Reconcile VM launch/process and session/worktree identities; show accepted baseline, candidate and restart root separately when declared. Resolve imported-source assertions and executable wrapper paths correctly.
4. Bound concurrency, read size, poll/backfill cost and cancellation independently. Retain stale samples with errors; improve configuration validation and collector error visibility without network/model probes.

Implemented contracts, limits and migration are in the [DASH-02 handoff](../../../research/TRIO-2026-10/DASH-02-OBSERVATION.md). Only registered actors are polled; selection is not enrollment. Source SQLite/WAL files are copied through bounded read-only file handles into disposable output before SQLite is opened. SSH validates live process identity and strict existing managed trust; only the sampler's own child can be cancelled.

## Acceptance criteria

- [ ] Every registered actor is sampled within a declared bounded cycle or visibly overdue; unrelated roots are not enrolled implicitly.
- [ ] The same session exposed on multiple ports has one identity; partial failure is unknown and cannot authorize admission.
- [ ] A 10-second stalled source leaves other sources and UI input responsive; one in-flight sample per source and zero mutation calls are proven.

The source checkpoint remains REVIEW until exact-head CI, review, integration and accepted-revision evidence are recorded on #28. No criterion or numeric target has been waived.

## Test cases

These cases are implemented in `dashboard/tests/test_observation.py`. Schema and endpoint data are explicitly synthetic; real owned subprocesses and prompt_toolkit pipe input are separately identified. No physical terminal or live-worker qualification is inferred.

- **DASH-02-T01 — Identity aliases and reuse:** Two endpoints share one DB/session; reused PID, new launch generation and moved root do not inherit old readiness or control identity.
- **DASH-02-T02 — Coverage fairness:** More registered roots than a polling batch, an old active root and continuously changing selection still receive bounded service; unsampled history stays unobserved.
- **DASH-02-T03 — Failure isolation:** Timeout, malformed payload, unsupported schema, oversized response and missing trust file preserve last-good age/error and never fall back to a write/bootstrap/load.
- **DASH-02-T04 — Source and scope:** Own-root imports pass, another checkout fails; executable wrappers are treated as files; paths with spaces/Unicode and non-enrolled roots follow the scope contract.
- **DASH-02-T05 — Resource bounds:** Stress at least 1,000 session records and delayed endpoints; record polls, CPU/RAM and maximum source age rather than only pass counts.

## Out of scope

Worker commands, broad process discovery beyond declared scope, key creation, inference qualification and native terminal attachment.

## Closure evidence

The [schema fixtures](../../../../dashboard/fixtures/dash02/schemas.json), capability table, source/identity negatives and measured test receipt bind these requirements to implementation. Run `python -B dashboard/qualify_observation.py --output <disposable-receipt-path>` from a clean Git checkout. The harness records actual HEAD/tree, source hashes, dependency versions, per-test results, all five case groups, 10-second input/failure measurements, 1,100-session polling cost and maximum age. Its explicit `--allow-source-subset` mode is supplementary local evidence only, never exact-checkout qualification.

The dedicated pinned Windows lane retains its JSON receipt. Existing DASH-01, full Windows control-plane CI, programme validation and real-release workflows remain independent requirements. Relevant RAG/user docs and research scope are updated; original research and DASH-01 sources/receipts are preserved. A dependent gate stays closed until all prerequisites are accepted. No TRIO restart is authorized.
