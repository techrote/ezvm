# DASH-11 — Establish recovery, pause and performance release gates

Status: **PLANNED** | Priority: **P0** | GitHub issue: [#37](https://github.com/techrote/ezvm/issues/37)

Dependencies: [DASH-02](DASH-02-scoped-adapters-and-identities.md), [DASH-03](DASH-03-tiled-workspace-and-activity.md), [DASH-04](DASH-04-usage-and-performance-ledger.md), [DASH-13](DASH-13-ci-packaging-and-compatibility.md).
Research: TRIO-FR-01, TRIO-FR-02, TRIO-FR-05, TRIO-FR-06, TRIO-FR-07, TRIO-FR-08, TRIO-FR-12, TRIO-FR-14, TRIO-FR-17, TRIO-FR-19 in the [field register](../../../research/TRIO-2026-10/README.md).

Read the [programme and common closure rules](../README.md) plus these RAG contracts:

- [00-SCOPE-AND-STATE](../../../rag/dashboard/00-SCOPE-AND-STATE.md)
- [01-OBSERVATION-AND-METRICS](../../../rag/dashboard/01-OBSERVATION-AND-METRICS.md)
- [02-TERMINAL-INTERACTION](../../../rag/dashboard/02-TERMINAL-INTERACTION.md)
- [06-TESTING-RELEASE-AND-RESEARCH](../../../rag/dashboard/06-TESTING-RELEASE-AND-RESEARCH.md)
- [08-TESTING-CI-RELEASE](../../../rag/08-TESTING-CI-RELEASE.md)

## Problem and baseline

A read-only baseline needs real qualification, and future mutations need a reusable crash/replay harness rather than a final prose checklist.

At prototype `d692be6`: The prototype has 25 focused tests, one live paused-host sample and pipe-dispatch measurements. Physical terminal qualification, complete overhead accounting and controlled-restart tests remain open.
Reconcile the selected revision before editing; preserve working implementation.

## Implementation

1. Build the reusable fault harness and evidence format for disconnect, timeout, flood, disk pressure, identity change, UI exit and controller restart using disposable fixtures.
2. Close the read-only release gate on exact candidate/package source with source coverage, duplicate-usage, actual Windows Terminal and measured overhead tests.
3. Define extension hooks and mandatory cases that DASH-05 through DASH-10 must add at each new mutation boundary. This issue establishes the harness; it does not claim unimplemented controls have passed.
4. Implement a read-only restart capsule/preflight for candidate/evidence/source/policy identities; opening it must not call a model or resume anything.
5. Update research retest state from actual results. Keep the prototype's 3.33%-of-one-core sample visible until optimized or a target revision is justified.

## Acceptance criteria

- [ ] Read-only source/identity, terminal, pause/no-dispatch, retention and performance gates have reproducible evidence at the accepted revision.
- [ ] A restored capsule is inspectable without inference; missing/stale evidence is held and diagnosed.
- [ ] The harness can inject each documented failure independently, and later control issues include explicit extension cases in their closure evidence.
- [ ] Performance target changes are recorded decisions, not silent denominator or threshold changes.

## Test cases

These are required future cases, not claims of existing or passing tests. Use
fixtures/process stubs first; physical/live qualification is separately identified.

- **DASH-11-T01 — Fault isolation:** 10-second network failure, stopped fixture guest, malformed provider data and output flood preserve UI input and other source updates.
- **DASH-11-T02 — Restart integrity:** Crash/reopen snapshots with duplicates, migrated schema and missing artifact; no dispatch, lost provenance or inflated counters; exact restart source is shown.
- **DASH-11-T03 — Resource budget:** Measure long-lived UI/collectors plus separately reported child/guest overhead, >=1,000 history records and repeated viewer cycles; target <200MiB and <=1% one-core idle or explicit reviewed revision.
- **DASH-11-T04 — Physical terminal matrix:** 80x24/120x40/160x48 mouse, keyboard, resize/focus and output behavior; p95 target <100ms with precise measurement method and genuine capability SKIPs.
- **DASH-11-T05 — Extension contract:** A dummy command adapter's before/after-dispatch crashes and pause races produce the expected held/reconciled result; later actual adapters must rerun their own boundary cases.

## Out of scope

Claiming all future control tests are already implemented, changing TRIO pause, owner-machine fault injection and treating fixtures as WHPX/live-model qualification.

## Closure evidence

Reusable harness, read-only release matrix, performance/terminal report, restart capsule fixture and observation-to-retest updates.

Apply the programme's common closure rules: original criteria and tests accounted
for, actual source/result identities, reviewed implementation and RAG updates, and
verification at the accepted revision. A dependent gate stays closed until those
prerequisites are accepted. This document does not authorize a TRIO restart.
