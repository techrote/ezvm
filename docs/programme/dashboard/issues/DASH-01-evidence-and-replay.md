# DASH-01 — Build the evidence fixtures and research feedback loop

Status: **ACCEPTED** | Priority: **P0** | GitHub issue: [#27](https://github.com/techrote/ezvm/issues/27)

Dependencies: None.
Research: TRIO-FR-03, TRIO-FR-17, TRIO-FR-20 in the [field register](../../../research/TRIO-2026-10/README.md).

Read the [programme and common closure rules](../README.md) plus these RAG contracts:

- [00-SCOPE-AND-STATE](../../../rag/dashboard/00-SCOPE-AND-STATE.md)
- [06-TESTING-RELEASE-AND-RESEARCH](../../../rag/dashboard/06-TESTING-RELEASE-AND-RESEARCH.md)
- [08-TESTING-CI-RELEASE](../../../rag/08-TESTING-CI-RELEASE.md)

## Problem and baseline

Repeated false-success claims, contradictory summaries and provider failures need reproducible fixtures before more dashboard behavior is automated.

At prototype `d692be6` the TRIO register contained 20 observations and an evidence index but lacked a complete replay corpus or executable trace to retests. The accepted implementation preserves the working application, core and original research artifacts.

## Implementation

1. Define a versioned, redacted fixture envelope with source/version/capture metadata, synthetic-vs-recorded label, expected projection and expected side-effect count.
2. Add idle, streaming, tool-running, retry/quota, transport failure, stale source, incorrect-import, missing-report, failed-exit-with-PASS-text and paused-restart scenarios. Include corrected/superseding evidence without deleting originals.
3. Map every proposed action in the existing TRIO register to an issue and retest case; record unresolved hypotheses explicitly. Add a small ADR/evidence template and immutable original artifact references.
4. Build a deterministic replay runner that never opens a live network/process/inference adapter. Keep large/raw/private logs outside the repo.

The [public corpus and runner](../../../../dashboard/fixtures/dash01/README.md) supply 16 synthetic fixtures, all 49 restart cuts and guarded disposable I/O. The [research handoff](../../../research/TRIO-2026-10/DASH-01-REPLAY.md) records all 20 observations and 48 action references, with explicitly bounded verification.

## Acceptance criteria

- [x] Replaying the corpus has zero VM, worker, provider and filesystem mutations outside its disposable fixture output.
- [x] Each published fixture is reviewable without private logs and has an expected result; corrections preserve original identities.
- [x] The research register can distinguish proposed, implemented and verified findings with exact revision/evidence links.

## Test cases

- **DASH-01-T01 — Replay determinism:** Replay the same event stream twice and after restart; projections and dedup counters match the expected fixture, with dispatch count zero.
- **DASH-01-T02 — False-success evidence:** A PASS text/nonzero exit, missing committed report and wrong source assertion remain failed or unverified, never accepted.
- **DASH-01-T03 — Fixture privacy and provenance:** Detect planted token/private-key/host-path sentinels and reject a missing synthetic/recorded label or source metadata; original fixture hashes remain unchanged after a correction.
- **DASH-01-T04 — Research traceability:** All 20 existing observations resolve to issue IDs and retest coverage or an explicit unresolved reason; model transport errors are not scored as reasoning defects.

## Out of scope

Live inference, provider-account access, reproducing historical security/isolation incidents, and declaring the field findings resolved.

## Closure evidence

PR #41 merged as `d5265c804d0d8494d8171482a85aca563b181e05`, tree `9416befc914dafcdefbc5c9bcc605b1ddd53e082`, matching the all-green candidate tree. Exact-main [DASH-01 run 38967949101](https://github.com/techrote/ezvm/actions/runs/38967949101) and [CI run 38967949193](https://github.com/techrote/ezvm/actions/runs/38967949193) completed successfully. The candidate's real-release run `38951076106` also passed. Live issue #27 carries the acceptance record. This documentation reconciles its formerly stale REVIEW label; no original fixture, original receipt or historical finding is rewritten.

Run `python -B -m unittest discover -s dashboard/tests -p test_evidence.py -v` and `python -B dashboard/replay.py --source-revision <exact-checkout-commit>`. Retained [receipts](../../../research/TRIO-2026-10/retests/README.md) preserve execution and content hashes. These tests do not qualify live controls or physical terminals. Dependent release gates retain every remaining prerequisite. No TRIO restart is authorized.
