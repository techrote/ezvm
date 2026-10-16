# DASH-01 — Build the evidence fixtures and research feedback loop

Status: **REVIEW** | Priority: **P0** | GitHub issue: [#27](https://github.com/techrote/ezvm/issues/27)

Dependencies: None.
Research: TRIO-FR-03, TRIO-FR-17, TRIO-FR-20 in the [field register](../../../research/TRIO-2026-10/README.md).

Read the [programme and common closure rules](../README.md) plus these RAG contracts:

- [00-SCOPE-AND-STATE](../../../rag/dashboard/00-SCOPE-AND-STATE.md)
- [06-TESTING-RELEASE-AND-RESEARCH](../../../rag/dashboard/06-TESTING-RELEASE-AND-RESEARCH.md)
- [08-TESTING-CI-RELEASE](../../../rag/08-TESTING-CI-RELEASE.md)

## Problem and baseline

Repeated false-success claims, contradictory summaries and provider failures need reproducible fixtures before more dashboard behavior is automated.

At prototype `d692be6`: The TRIO register contains 20 observations and an evidence index; prototype tests use small synthetic fixtures. There is no complete replay corpus or executable trace from each finding to its retest.
Reconcile the selected revision before editing; preserve working implementation.

## Implementation

1. Define a versioned, redacted fixture envelope with source/version/capture metadata, synthetic-vs-recorded label, expected projection and expected side-effect count.
2. Add idle, streaming, tool-running, retry/quota, transport failure, stale source, incorrect-import, missing-report, failed-exit-with-PASS-text and paused-restart scenarios. Include corrected/superseding evidence without deleting originals.
3. Map every proposed action in the existing TRIO register to an issue and retest case; record unresolved hypotheses explicitly. Add a small ADR/evidence template and immutable original artifact references.
4. Build a deterministic replay runner that never opens a live network/process/inference adapter. Keep large/raw/private logs outside the repo.

The implementation is now present in the [public corpus and runner](../../../../dashboard/fixtures/dash01/README.md): 16 synthetic fixtures, 49 restart cut-points, pure projections and guarded disposable I/O. The original read-only application and core control plane are preserved. The [research handoff](../../../research/TRIO-2026-10/DASH-01-REPLAY.md) documents all 20 observations / 48 proposed actions, immutable originals, explicit unresolved work and bounded verification states.

## Acceptance criteria

- [ ] Replaying the corpus has zero VM, worker, provider and filesystem mutations outside its disposable fixture output.
- [ ] Each published fixture is reviewable without private logs and has an expected result; corrections preserve original identities.
- [ ] The research register can distinguish proposed, implemented and verified findings with exact revision/evidence links.

The checklist remains open until required CI, review and accepted-revision evidence are recorded; implementation and local test success alone do not close this issue.

## Test cases

The following original requirements are implemented by `dashboard/tests/test_evidence.py` and the offline runner. They remain synthetic/process-boundary evidence, not physical/live qualification.

- **DASH-01-T01 — Replay determinism:** Replay the same event stream twice and after restart; projections and dedup counters match the expected fixture, with dispatch count zero.
- **DASH-01-T02 — False-success evidence:** A PASS text/nonzero exit, missing committed report and wrong source assertion remain failed or unverified, never accepted.
- **DASH-01-T03 — Fixture privacy and provenance:** Detect planted token/private-key/host-path sentinels and reject a missing synthetic/recorded label or source metadata; original fixture hashes remain unchanged after a correction.
- **DASH-01-T04 — Research traceability:** All 20 existing observations resolve to issue IDs and retest coverage or an explicit unresolved reason; model transport errors are not scored as reasoning defects.

## Out of scope

Live inference, provider-account access, reproducing historical security/isolation incidents, and declaring the field findings resolved.

## Closure evidence

Corpus manifest, replay output/hashes, observation-to-case map and ADR template; preserve original private evidence outside published fixtures.

Run `python -B -m unittest discover -s dashboard/tests -p test_evidence.py -v` and `python -B dashboard/replay.py --source-revision <exact-checkout-commit>`. The latter verifies the unchanged original research blobs and emits an execution receipt with actual source-content hashes. The dedicated DASH-01 workflow runs Windows/Linux replay; Windows also runs the existing dashboard suite and programme integrity check. Core repository/Windows checks remain required. Exact run and accepted-source identities belong in the issue/PR and committed retest receipts, not inferred from PASS prose.

Apply the programme's common closure rules: original criteria and tests accounted
for, actual source/result identities, reviewed implementation and RAG updates, and
verification at the accepted revision. A dependent gate stays closed until those
prerequisites are accepted. This document does not authorize a TRIO restart.
