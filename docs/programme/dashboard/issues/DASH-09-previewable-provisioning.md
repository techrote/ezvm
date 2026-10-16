# DASH-09 — Implement previewable stopped-only provisioning and recoverable disk growth

Status: **PLANNED** | Priority: **P1** | GitHub issue: **not published**

Dependencies: [DASH-05](DASH-05-durable-commands-and-pause.md), [DASH-08](DASH-08-lifecycle-prerequisites.md).
Research: TRIO-FR-07 in the [field register](../../../research/TRIO-2026-10/README.md).

Read the [programme and common closure rules](../README.md) plus these RAG contracts:

- [00-SCOPE-AND-STATE](../../../rag/dashboard/00-SCOPE-AND-STATE.md)
- [03-CONTROLS-AND-REVIEW](../../../rag/dashboard/03-CONTROLS-AND-REVIEW.md)
- [05-PROVISIONING-AND-DEVBOX](../../../rag/dashboard/05-PROVISIONING-AND-DEVBOX.md)
- [06-TESTING-RELEASE-AND-RESEARCH](../../../rag/dashboard/06-TESTING-RELEASE-AND-RESEARCH.md)
- [02-HOST-QEMU-CONTRACT](../../../rag/02-HOST-QEMU-CONTRACT.md)
- [03-QCOW2-STATE-CONTRACT](../../../rag/03-QCOW2-STATE-CONTRACT.md)
- [05-NETWORK-SSH-CONTRACT](../../../rag/05-NETWORK-SSH-CONTRACT.md)
- [06-SECURITY-PORTABILITY-CONTRACT](../../../rag/06-SECURITY-PORTABILITY-CONTRACT.md)
- [07-CLI-STATE-CONTRACT](../../../rag/07-CLI-STATE-CONTRACT.md)
- [08-TESTING-CI-RELEASE](../../../rag/08-TESTING-CI-RELEASE.md)

## Problem and baseline

Users need capacity changes without inconsistent intent/readiness identities, live-disk copying or false rollback promises.

At prototype `d692be6`: The dashboard displays CPU/RAM/disk observations. The earlier TRIO growth was an operational procedure, not a supported dashboard provisioning transaction.
Reconcile the selected revision before editing; preserve working implementation.

## Implementation

1. Design and accept underlying PowerShell CLI/API semantics before adding UI controls. Preview exact VM generation, current/requested/effective values, headroom, stages and worker implications.
2. Journal and lock stopped-only CPU/RAM changes with consistent intent/readiness invalidation and requalification. Quiescing/starting are explicit typed actions, not silent UI side effects.
3. Add supported virtual disk/partition/filesystem growth stages with verified stopped recovery material, immutable backing base and stage-by-stage reconciliation.
4. After readiness compare guest-observed values; offer a separate worker resume. State the difference between continuing a partial growth and restoring a pre-growth snapshot after possible guest writes.

## Acceptance criteria

- [ ] Running or ambiguous identity refuses before mutation; only the selected VM changes.
- [ ] Every growth stage has a tested recover/continue decision; no automatic shrink or live-disk 'backup'.
- [ ] Requested/effective/guest-observed CPU/RAM/disk and readiness identity agree on success; failure exposes exact partial state.
- [ ] Host reserve includes other VM and local inference demands without changing their allocations.

## Test cases

These are required future cases, not claims of existing or passing tests. Use
fixtures/process stubs first; physical/live qualification is separately identified.

- **DASH-09-T01 — Preview and refusal:** Insufficient host headroom, stale revision, active/unknown VM and unsupported filesystem produce a clear preview/refusal and zero writes.
- **DASH-09-T02 — CPU/RAM identity:** Stopped change invalidates old readiness coherently; restart observes new resources and does not auto-resume workers.
- **DASH-09-T03 — Growth crash stages:** Inject interruption before/after snapshot, image growth, guest geometry update and readiness; each resumes or restores only with explicit supported semantics.
- **DASH-09-T04 — Isolation and immutability:** Selected overlay/config changes as expected; backing-base and unrelated fixture-instance hashes/identities remain unchanged.
- **DASH-09-T05 — Real qualification:** Use an approved disposable VM to grow a known supported filesystem and verify capacity/data/readiness; record limitation rather than substitute metadata-only PASS.

## Out of scope

Disk shrink, resource hotplug, automatic worker resume, host driver/pagefile changes and modifications to the current TRIO VM for testing.

## Closure evidence

Accepted CLI/RAG transaction contract, journal schema, stage crash matrix and disposable-VM before/after identity/capacity evidence.

Apply the programme's common closure rules: original criteria and tests accounted
for, actual source/result identities, reviewed implementation and RAG updates, and
verification at the accepted revision. A dependent gate stays closed until those
prerequisites are accepted. This document does not authorize a TRIO restart.
