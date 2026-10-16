# DASH-04 — Implement a provenance-aware usage and performance ledger

Status: **PLANNED** | Priority: **P0** | GitHub issue: **not published**

Dependencies: [DASH-02](DASH-02-scoped-adapters-and-identities.md).
Research: TRIO-FR-07, TRIO-FR-09, TRIO-FR-10, TRIO-FR-11, TRIO-FR-20 in the [field register](../../../research/TRIO-2026-10/README.md).

Read the [programme and common closure rules](../README.md) plus these RAG contracts:

- [00-SCOPE-AND-STATE](../../../rag/dashboard/00-SCOPE-AND-STATE.md)
- [01-OBSERVATION-AND-METRICS](../../../rag/dashboard/01-OBSERVATION-AND-METRICS.md)
- [06-TESTING-RELEASE-AND-RESEARCH](../../../rag/dashboard/06-TESTING-RELEASE-AND-RESEARCH.md)
- [08-TESTING-CI-RELEASE](../../../rag/08-TESTING-CI-RELEASE.md)

## Problem and baseline

Comparing workers and providers requires honest field semantics, coverage and request timing rather than inflated totals or invented decode rates.

At prototype `d692be6`: The prototype aggregates OpenCode input/cache/output/reasoning by provider/model and separately displays Strata/LM Studio state. It lacks durable corrections/history, rate-window charts and a full normalized metric envelope.
Reconcile the selected revision before editing; preserve working implementation.

## Implementation

1. Implement the normalized envelope and raw-source retention, overlap/inclusion map, coverage counts and transactional per-message correction. Add resumable deduplicated ingestion/backfill.
2. Expose harmonized worker/model/provider views and context/request histories. Correlate engine and OpenCode records only with evidence; otherwise retain separate totals.
3. Ingest owned admission/dispatch/retry/error telemetry where available. Show rolling RPM, minimum dispatch gap, 429/cooldown and capture gaps with explicit windows; quota/spend stay unavailable unless sourced.
4. Separate requested/effective/physical model settings and host/guest/disk/GPU denominators. Persist bounded history/retention without deleting evidence needed by open tasks.

## Acceptance criteria

- [ ] Known fixture totals reproduce exactly after duplicate delivery, final correction and restart; overlapping reasoning/output is never silently double-counted.
- [ ] Unknown cost/quota/decode timing remains unknown; configured caps are not described as provider limits.
- [ ] Rate calculations include retry attempts, distinguish admission/dispatch/arrival and expose missing coverage; runtime and agent totals are not added twice.

## Test cases

These are required future cases, not claims of existing or passing tests. Use
fixtures/process stubs first; physical/live qualification is separately identified.

- **DASH-04-T01 — Usage correction:** Repeated message and revised final usage replace one contribution; stream/restart/backfill yields the same aggregate, including compaction/helper records.
- **DASH-04-T02 — Provider semantics:** Disjoint and overlapping token categories, absent/error usage and provider totals produce the declared total or unknown with coverage, not an arbitrary sum.
- **DASH-04-T03 — Request timing:** Boundary events in rolling 60s windows, retries, clock skew and capture gaps yield exact fixture RPM/minimum dispatch intervals; arrival time is never fabricated.
- **DASH-04-T04 — Model/resource identity:** Mapped versus requested resident mode, changed context/quant and GPU index movement remain separate observations; power is not silently assigned to workers.
- **DASH-04-T05 — History bounds:** Rotation, disk-pressure retention and concurrent reads retain open-task evidence and bounded memory while preserving source provenance.

## Out of scope

Inference benchmarking, paid cost/account APIs without explicit enrollment, attribution from guesswork and an automatic model leaderboard.

## Closure evidence

Versioned ledger/schema, provider inclusion mapping, deterministic totals/rate oracles and a documented retention/migration policy.

Apply the programme's common closure rules: original criteria and tests accounted
for, actual source/result identities, reviewed implementation and RAG updates, and
verification at the accepted revision. A dependent gate stays closed until those
prerequisites are accepted. This document does not authorize a TRIO restart.
