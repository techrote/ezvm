# DASH-10 — Build a reproducible local/free agentic demonstration devbox

Status: **PLANNED** | Priority: **P1** | GitHub issue: **not published**

Dependencies: [DASH-06](DASH-06-review-rework-and-evidence.md), [DASH-07](DASH-07-model-pools-and-automations.md), [DASH-09](DASH-09-previewable-provisioning.md), [DASH-13](DASH-13-ci-packaging-and-compatibility.md).
Research: TRIO-FR-15, TRIO-FR-19 in the [field register](../../../research/TRIO-2026-10/README.md).

Read the [programme and common closure rules](../README.md) plus these RAG contracts:

- [00-SCOPE-AND-STATE](../../../rag/dashboard/00-SCOPE-AND-STATE.md)
- [04-CAPACITY-AND-MODELS](../../../rag/dashboard/04-CAPACITY-AND-MODELS.md)
- [05-PROVISIONING-AND-DEVBOX](../../../rag/dashboard/05-PROVISIONING-AND-DEVBOX.md)
- [06-TESTING-RELEASE-AND-RESEARCH](../../../rag/dashboard/06-TESTING-RELEASE-AND-RESEARCH.md)
- [02-HOST-QEMU-CONTRACT](../../../rag/02-HOST-QEMU-CONTRACT.md)
- [03-QCOW2-STATE-CONTRACT](../../../rag/03-QCOW2-STATE-CONTRACT.md)
- [05-NETWORK-SSH-CONTRACT](../../../rag/05-NETWORK-SSH-CONTRACT.md)
- [06-SECURITY-PORTABILITY-CONTRACT](../../../rag/06-SECURITY-PORTABILITY-CONTRACT.md)
- [07-CLI-STATE-CONTRACT](../../../rag/07-CLI-STATE-CONTRACT.md)
- [08-TESTING-CI-RELEASE](../../../rag/08-TESTING-CI-RELEASE.md)

## Problem and baseline

A person without paid AI subscriptions needs an honest, repeatable route to a small accepted agentic coding exercise.

At prototype `d692be6`: The current TRIO lab provides lived-experience research and recipes. Its authenticated history/overlay is not a redistributable clean devbox.
Reconcile the selected revision before editing; preserve working implementation.

## Implementation

1. Define a clean versioned agentic-demo provisioning profile with pinned verified tools, runtime/model manifests, licenses, download sizes and hardware requirements.
2. Provide guided first-run prerequisite/resource/download/account choices and resumable setup, then one-click subsequent launch through accepted EzVM APIs.
3. Offer a qualified local-first route and optional separately configured free endpoints; show changing eligibility/limits and refuse silent paid fallback. Label replay when live hardware/quota is absent.
4. Ship a small exercise with implementation, independent supported review finding, repair and objective verification. Capture downloads, elapsed time, interventions and restart outcomes without collecting raw secrets/reasoning.

## Acceptance criteria

- [ ] A clean supported host reaches one accepted small change and review/repair outcome using a permitted local/free route.
- [ ] No credential, personal lab overlay/history or undisclosed paid-service dependency enters the image/package.
- [ ] Interrupted downloads/setup resume from verified artifacts; first-run prerequisites are not hidden by a 'one click' label.
- [ ] Hardware/model tiers and provider availability are dated measured claims with explicit unsupported cases.

## Test cases

These are required future cases, not claims of existing or passing tests. Use
fixtures/process stubs first; physical/live qualification is separately identified.

- **DASH-10-T01 — Clean recipe:** Rebuild from pinned clean base; inspect manifest/output for planted lab account/SSH/token/history sentinels and verify hashes/licenses.
- **DASH-10-T02 — Setup recovery:** Interrupt download/install/readiness; bad hash, low disk/RAM and absent virtualization are actionable and do not corrupt accepted base state.
- **DASH-10-T03 — Local/free availability:** Free quota unavailable, registration absent and no suitable hardware lead to hold or labelled replay; paid fallback dispatch count is zero.
- **DASH-10-T04 — Demonstration result:** Frozen exercise candidate, independent review, repair and final numerical/behavioral checks produce attributable artifacts, not just narration.
- **DASH-10-T05 — Fresh-host qualification:** Record exact supported Windows/VM/model/runtime versions, time/download/intervention totals and held restart; distinguish live from replay runs.

## Out of scope

Redistributing the current TRIO image, universal hardware compatibility claims, mandatory paid APIs and unattended account/credential enrollment.

## Closure evidence

Profile/manifests, license review, clean-image checks, exercise artifacts and reproducible fresh-host qualification report.

Apply the programme's common closure rules: original criteria and tests accounted
for, actual source/result identities, reviewed implementation and RAG updates, and
verification at the accepted revision. A dependent gate stays closed until those
prerequisites are accepted. This document does not authorize a TRIO restart.
