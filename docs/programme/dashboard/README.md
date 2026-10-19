# VM & AI dashboard implementation and testing programme

This is the executable issue series for dashboard work, published as GitHub issues
#27 through #39 with version-controlled specifications below. Publication does not
schedule work or restart TRIO. Stable DASH identifiers and the existing core
EZVM-001..012 issue numbers are unchanged.

## Current implementation and scope

The read-only prototype is integrated. DASH-01 is **accepted** on main
`d5265c804d0d8494d8171482a85aca563b181e05` through PR #41; exact-main
[offline evidence](https://github.com/techrote/ezvm/actions/runs/38967949101) and
[core CI](https://github.com/techrote/ezvm/actions/runs/38967949193) passed.
The versioned DASH-01 review checkpoint is reconciled here with live issue #27.

DASH-02's registered observation implementation is recorded as **review** at the
2026-10-18 publication checkpoint; see the
[adapter and research handoff](../../research/TRIO-2026-10/DASH-02-OBSERVATION.md).
Subsequent acceptance is recorded on [live issue #28](https://github.com/techrote/ezvm/issues/28)
with the tested candidate, required checks, merged main and accepted-revision
verification. A closed flag without that evidence is insufficient. The dated
catalogue below records publication state, not a later live capability gate.
DASH-03/04 retain partial foundations, not completed acceptance. All remaining
issues are planned. TRIO remains paused and no capability release gate is opened
by these scoped fixture and adapter changes. See [the guide](../../DASHBOARD.md)
and [prototype measurements](../../DASHBOARD-VERIFICATION.md).

Use the field study as first-person product research, not as a universal model
ranking or a reason to redistribute the authenticated VM. The future demonstration
is a clean recipe with measured local/free support.

## Issue catalogue

| Issue | GitHub | Implementation/testing outcome | Priority | Dependencies | State |
|---|---|---|---|---|---|
| [DASH-01](issues/DASH-01-evidence-and-replay.md) | [#27](https://github.com/techrote/ezvm/issues/27) | Build the evidence fixtures and research feedback loop | P0 | — | accepted |
| [DASH-02](issues/DASH-02-scoped-adapters-and-identities.md) | [#28](https://github.com/techrote/ezvm/issues/28) | Harden scoped observation adapters and registered-worker discovery | P0 | DASH-01 | review |
| [DASH-03](issues/DASH-03-tiled-workspace-and-activity.md) | [#29](https://github.com/techrote/ezvm/issues/29) | Finish mdbm-style tiles, saved layouts and evidence browsing | P0 | DASH-02 | planned |
| [DASH-04](issues/DASH-04-usage-and-performance-ledger.md) | [#30](https://github.com/techrote/ezvm/issues/30) | Implement a provenance-aware usage and performance ledger | P0 | DASH-02 | planned |
| [DASH-05](issues/DASH-05-durable-commands-and-pause.md) | [#31](https://github.com/techrote/ezvm/issues/31) | Add the durable command broker and operator pause/steering controls | P0 | DASH-11 | planned |
| [DASH-06](issues/DASH-06-review-rework-and-evidence.md) | [#32](https://github.com/techrote/ezvm/issues/32) | Build independent review, rework and evidence-gated task queues | P1 | DASH-05 | planned |
| [DASH-07](issues/DASH-07-model-pools-and-automations.md) | [#33](https://github.com/techrote/ezvm/issues/33) | Add model availability, shared admission pools and bounded automations | P1 | DASH-05, DASH-06 | planned |
| [DASH-08](issues/DASH-08-lifecycle-prerequisites.md) | [#34](https://github.com/techrote/ezvm/issues/34) | Qualify lifecycle prerequisites for dashboard-managed devboxes | P0 | DASH-01 | planned |
| [DASH-09](issues/DASH-09-previewable-provisioning.md) | [#35](https://github.com/techrote/ezvm/issues/35) | Implement previewable stopped-only provisioning and recoverable disk growth | P1 | DASH-05, DASH-08 | planned |
| [DASH-10](issues/DASH-10-clean-demo-devbox.md) | [#36](https://github.com/techrote/ezvm/issues/36) | Build a reproducible local/free agentic demonstration devbox | P1 | DASH-06, DASH-07, DASH-09, DASH-13 | planned |
| [DASH-11](issues/DASH-11-recovery-and-performance-gates.md) | [#37](https://github.com/techrote/ezvm/issues/37) | Establish recovery, pause and performance release gates | P0 | DASH-02, DASH-03, DASH-04, DASH-13 | planned |
| [DASH-12](issues/DASH-12-optional-terminal-embedding.md) | [#38](https://github.com/techrote/ezvm/issues/38) | Evaluate bounded embedded terminal viewing and explicit input ownership | P2 | DASH-03, DASH-05 | planned |
| [DASH-13](issues/DASH-13-ci-packaging-and-compatibility.md) | [#39](https://github.com/techrote/ezvm/issues/39) | Add reproducible dashboard CI, packaging and compatibility checks | P0 | DASH-01, DASH-02, DASH-03, DASH-04 | planned |

The [catalogue JSON](catalog.json) holds stable IDs, paths, dependencies, RAG and
research references, case IDs and release gates. The issue bodies own substantive
scope and test assertions. Update both in the same change and reconcile the linked
GitHub body. Publication alone accepts no future issue. DASH-02's dated review
checkpoint is not accepted-revision qualification; reconcile its live acceptance
record and accepted main before starting dependent work. This permits the final
acceptance evidence to be appended after merge without rerunning unchanged heavy
green qualification solely to update a historical source checkpoint.

## Execution order and release gates

1. **Foundation:** DASH-01, then DASH-02.
2. **Observation finish:** DASH-03 and DASH-04 can proceed independently after02.
   DASH-08 lifecycle triage can proceed after01 in isolated fixtures.
3. **Read-only qualification:** DASH-13 packages/tests the observation feature;
   DASH-11 supplies the reusable recovery/performance harness and closes the
   read-only gate. Numeric IDs preserve earlier references, not execution order.
4. **Human controls:** DASH-05, then06, then07. Each adds its own actual crash/pause
   tests to the harness; DASH-11 does not pre-qualify code that does not yet exist.
5. **Provisioning:** DASH-09 after05 and08; controlled resource changes remain
   disabled before the accepted API and recovery tests exist.
6. **Demonstration:** DASH-10 after06/07/09/13, including their transitive gates.
7. **Optional:** DASH-12 after03/05; its measured no-go does not block useful
   read-only or workflow releases.

| Gate | Required accepted issues | What may be claimed |
|---|---|---|
| READONLY | DASH-01, DASH-02, DASH-03, DASH-04, DASH-13, DASH-11 plus prerequisites | Release qualified observation; does not enable worker/VM mutations. |
| CONTROL | DASH-05, DASH-06, DASH-07 plus prerequisites | Owned pause/steering/review/rework and policy-bound automation after all transitive prerequisites. |
| PROVISION | DASH-08, DASH-09 plus prerequisites | Accepted stopped-only resource changes through authoritative APIs; separate explicit resume. |
| DEVBOX | DASH-10 plus prerequisites | Qualified clean local/free recipe and demonstration, including all transitive prerequisites. |
| EMBED | DASH-12 plus prerequisites | Measured go/no-go for embedding; not a dependency of the other release gates. |

These are capability release gates, not permission to mutate the owner's paused
TRIO environment. Work in disposable test roots/VMs where live qualification is
authorized. Never use the original QEMU start pipe or owner patches as test fixtures.

## Authority and implementation handoff

Read [AGENTS](../../../AGENTS.md), this programme, the selected issue, its linked
RAG, and the relevant accepted source/tests. Core
[architecture](../../rag/01-ARCHITECTURE.md),
[security/portability](../../rag/06-SECURITY-PORTABILITY-CONTRACT.md) and
[test/release rules](../../rag/08-TESTING-CI-RELEASE.md) remain binding.
The [dashboard RAG index](../../rag/README.md#dashboard-companion-target-contracts)
defines target contracts; it does not document proposed controls as current APIs.

The narrative [design](../../design/VM-AI-DASHBOARD.md) remains rationale.
For dashboard execution, issue bodies and linked RAG are more specific than the
earlier delivery sketch. Contract changes require matching implementation/tests
and a recorded reason. Do not silently redefine the released core v0.1 contract.

Before assignment, reconcile the selected source, owner changes and accepted
dependencies. Inspect remote main/issues/comments only when remote operations are
authorized; otherwise state the local baseline and external review gap. Preserve
mixed contributions and exclude the owner's unrelated Keys.ps1 / Runtime.ps1 patches.

## Common closure requirements

Every issue must deliver:

- Intended implementation with the existing working subset preserved.
- All listed acceptance cases, positive and negative, with actual commands, exits,
  source/tested-tree identity, fixture/hardware/runtime versions and artifact hashes.
  New case IDs in this programme are requirements, not tests claimed to exist.
- Explicit PASS/FAIL/SKIP reasons; no physical-terminal/WHPX/live-model claim from
  dummy output, TCG or replay. Unsupported acceptance stays visibly open.
- Relevant core and dashboard checks, reviewed diff, RAG/user docs and research
  retest updates. Verify the accepted revision; do not close on an unmerged WIP report.
- Publication/review/merge under the applicable repository workflow when authorized.
  A local-only completion record must state that remote checks are unverified.

Staged release gates cannot waive mandatory evidence. A documented optional
DASH-12 no-go is an explicit allowed outcome; other acceptance waivers need a
deliberate scope/contract amendment rather than a prose success claim.
Do not rerun unchanged heavy green tests only to repair documentation.

## Tracking and validation

State flow: planned -> ready (dependencies accepted) -> in-progress -> review ->
accepted; use blocked with a reason and preserve prior phase. State changes must
cite source/evidence and, after publication, actual GitHub identity. This catalogue
is a plan, not a second runtime work queue.

```powershell
.\scripts\Test-DashboardPlan.ps1
```

The check verifies IDs, files, RAG/research links, dependency acyclicity, gate
references, case IDs and required issue sections. It runs on PowerShell 5.1 without
Python, network, VM or model access. It does not validate product acceptance.
The original publication check covered 13 issues, 62 case IDs, 20 observations and
five gates, including seven negative integrity fixtures. That is planning evidence,
not product acceptance. Current CI validates the updated catalogue separately.

Maintain [TRIO research traceability](../../research/TRIO-2026-10/README.md):
observation -> issue -> fixture -> accepted revision -> retest. Keep original
evidence immutable and private raw data private; add corrections rather than
rewriting the historical record.
