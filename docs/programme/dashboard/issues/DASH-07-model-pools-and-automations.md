# DASH-07 — Add model availability, shared admission pools and bounded automations

Status: **PLANNED** | Priority: **P1** | GitHub issue: **not published**

Dependencies: [DASH-05](DASH-05-durable-commands-and-pause.md), [DASH-06](DASH-06-review-rework-and-evidence.md).
Research: TRIO-FR-01, TRIO-FR-10, TRIO-FR-11, TRIO-FR-12, TRIO-FR-13, TRIO-FR-16, TRIO-FR-18, TRIO-FR-20 in the [field register](../../../research/TRIO-2026-10/README.md).

Read the [programme and common closure rules](../README.md) plus these RAG contracts:

- [00-SCOPE-AND-STATE](../../../rag/dashboard/00-SCOPE-AND-STATE.md)
- [03-CONTROLS-AND-REVIEW](../../../rag/dashboard/03-CONTROLS-AND-REVIEW.md)
- [04-CAPACITY-AND-MODELS](../../../rag/dashboard/04-CAPACITY-AND-MODELS.md)
- [06-TESTING-RELEASE-AND-RESEARCH](../../../rag/dashboard/06-TESTING-RELEASE-AND-RESEARCH.md)
- [08-TESTING-CI-RELEASE](../../../rag/08-TESTING-CI-RELEASE.md)

## Problem and baseline

Users need predictable local/free allocation, provider concurrency/rate control and automation that respects pause and cost constraints.

At prototype `d692be6`: The prototype displays source metrics but does not configure admission/model policy. TRIO's existing caps and preferences are field-test policy, not product defaults.
Reconcile the selected revision before editing; preserve working implementation.

## Implementation

1. Provide editable model/role availability, dated capabilities, local/remote preference, free-only spend policy, fallback order, expiry and queue waiting explanations.
2. Implement shared pool worker leases and separate request admission, including retries/fallbacks, conservative unknown occupancy, cooldown/backoff and bounded provider errors.
3. Add exclusive local-model switch/load ownership with verified effective configuration and physical GPU UUID allocation before inference. Shared workers use measured sequence capacity of one runtime.
4. Add dry-run-first review/rework/hold/notify automation templates with explicit scheduler owner, deduplication, expiry, budget, cooldown and run history. External schedules are referenced, not cloned.

## Acceptance criteria

- [ ] Configured worker and request limits apply across all registered endpoints/VMs sharing a pool, including duplicates and retries.
- [ ] Unknown capacity holds dispatch; expired leases cannot silently reuse a possibly occupied GPU/model.
- [ ] Useful local work is not reloaded away, physical placement is verified and free-only policy cannot fall through to paid inference.
- [ ] Automations cannot override owner pause or replay completed actions on restart/time-zone changes.

## Test cases

These are required future cases, not claims of existing or passing tests. Use
fixtures/process stubs first; physical/live qualification is separately identified.

- **DASH-07-T01 — Global admission race:** Concurrent reservation from two controllers, duplicate model sessions, tool gaps and lease expiry respect one shared cap; status timeout never frees a slot.
- **DASH-07-T02 — Rate and cooldown:** Rolling-window boundaries, minimum spacing, retry-after, 429 below the local cap and fallback retries pass the same request gate.
- **DASH-07-T03 — Local placement:** Synthetic UUID/index swap, unavailable explicit loader and requested/effective mode mismatch hold inference; no auto-loader fallback or owner-device test is used.
- **DASH-07-T04 — Shared runtime policy:** Two workers within qualified sequence capacity coexist; switch while useful work runs is refused/drained explicitly; local availability preference is explained.
- **DASH-07-T05 — Automation and spend:** Duplicate triggers, expired model registry, clock changes and quota reset while paused dispatch nothing unauthorized; free-only never chooses a paid model.

## Out of scope

Automatic provider registration/upgrades, probing forbidden GPUs, treating the historic TRIO cap as universal and unbounded autonomous model promotion.

## Closure evidence

Policy schema/UI, shared admission race results, physical-placement adapter fixtures, automation history/replay tests and dated capability provenance.

Apply the programme's common closure rules: original criteria and tests accounted
for, actual source/result identities, reviewed implementation and RAG updates, and
verification at the accepted revision. A dependent gate stays closed until those
prerequisites are accepted. This document does not authorize a TRIO restart.
