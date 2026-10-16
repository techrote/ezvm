# DASH-13 — Add reproducible dashboard CI, packaging and compatibility checks

Status: **PLANNED** | Priority: **P0** | GitHub issue: [#39](https://github.com/techrote/ezvm/issues/39)

Dependencies: [DASH-01](DASH-01-evidence-and-replay.md), [DASH-02](DASH-02-scoped-adapters-and-identities.md), [DASH-03](DASH-03-tiled-workspace-and-activity.md), [DASH-04](DASH-04-usage-and-performance-ledger.md).
Research: TRIO-FR-15, TRIO-FR-19 in the [field register](../../../research/TRIO-2026-10/README.md).

Read the [programme and common closure rules](../README.md) plus these RAG contracts:

- [00-SCOPE-AND-STATE](../../../rag/dashboard/00-SCOPE-AND-STATE.md)
- [06-TESTING-RELEASE-AND-RESEARCH](../../../rag/dashboard/06-TESTING-RELEASE-AND-RESEARCH.md)
- [08-TESTING-CI-RELEASE](../../../rag/08-TESTING-CI-RELEASE.md)

## Problem and baseline

A prototype tied to a developer checkout is not yet a maintainable or reproducible optional EzVM feature.

At prototype `d692be6`: The optional launcher/setup and hash-pinned three-wheel environment work locally. Dashboard tests are not a dedicated hosted CI lane, and clean dashboard release/package qualification is not established.
Reconcile the selected revision before editing; preserve working implementation.

## Implementation

1. Add a first-party dashboard check entry point and pinned Windows x64 CI lane for fixture/adapter/UI tests. Verify actual Python/PowerShell versions; keep networkless test execution after dependency setup.
2. Define optional dashboard source/package contents and version policy without making the core PowerShell CLI depend on Python. Pin/hash-verify dependencies and interpreter acquisition if offered; include notices.
3. Test clean-checkout/package setup and launch without developer paths, plus spaces/Unicode paths, offline runtime and missing/bad dependencies. Add schema migration/preimage tests for accepted persistent state.
4. Integrate issue/RAG/catalog validation and docs links into appropriate fast checks. Preserve existing release dirty-tree/secret/runtime-artifact guards; unrelated owner patches are not bundled or cleaned up to obtain PASS.

## Acceptance criteria

- [ ] A clean supported Windows checkout/package can install verified dependencies and launch the read-only dashboard without private paths/config.
- [ ] Core ezvm help/version/control-plane tests work without the optional Python environment.
- [ ] CI reports actual executed/skipped coverage and fails on zero tests, bad pins, invalid docs/catalog or generated/private artifacts.
- [ ] No clean-release claim is made while tracked source is dirty; no real VM/account/inference is needed for mandatory fixture CI.

## Test cases

These are required future cases, not claims of existing or passing tests. Use
fixtures/process stubs first; physical/live qualification is separately identified.

- **DASH-13-T01 — Pinned setup:** Bad digest, wrong Python architecture/version, interrupted install and absent network fail or recover clearly; system Python/PATH remain unchanged.
- **DASH-13-T02 — Clean package:** Inspect packaged files for runtime DBs/keys/logs/VM disks; launch from spaces/Unicode and a relocated clean directory using explicit config.
- **DASH-13-T03 — Optional dependency boundary:** Remove optional environment in an isolated fixture; core CLI stays functional and dashboard gives concrete setup guidance.
- **DASH-13-T04 — Versioned tests and migrations:** Run dashboard fixtures on the declared Windows Python/PowerShell matrix, reject empty/all-skipped success, and retain old state on failed migration.
- **DASH-13-T05 — Release and plan guards:** Dirty source cannot package as clean; malformed dependency graph/RAG reference/issue case and private artifact sentinel fail the relevant fast check.

## Out of scope

Publishing a release in this documentation task, bypassing release guards, altering owner patches, mandatory new host services and silent interpreter installation.

## Closure evidence

CI/check scripts, pinned manifests/notices, clean-package qualification, core optionality checks and actual release-source identity.

Apply the programme's common closure rules: original criteria and tests accounted
for, actual source/result identities, reviewed implementation and RAG updates, and
verification at the accepted revision. A dependent gate stays closed until those
prerequisites are accepted. This document does not authorize a TRIO restart.
