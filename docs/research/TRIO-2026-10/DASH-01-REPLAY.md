# DASH-01 implementation and evidence handoff

Issue: [#27](https://github.com/techrote/ezvm/issues/27). State: **review** until the
implementation, required CI and accepted-revision verification are published.
TRIO remains paused. No historical finding is declared resolved.

## Delivered boundary

The [public corpus](../../../dashboard/fixtures/dash01/README.md) adds 16 synthetic
scenarios, fixed-clock replay, origin/epoch/session/record deduplication, all-cut
checkpoint recovery, explicit correction chains and zero dispatch. The live
read-only application and all EzVM core modules are unchanged.

`dashboard/ezvm_dashboard/evidence.py` is the pure envelope/projection layer;
`dashboard/replay.py` owns guarded disposable I/O; `research.py` verifies the original
research blob pins and the observation/action/retest ledger. `test_evidence.py`
executes DASH-01-T01 through T04, including adversarial privacy and side-effect tests.
The dedicated CI lane tests Python 3.12.10 on Windows and Linux. Windows additionally
runs the existing dashboard suite with its existing hash-pinned dependencies.
This adds issue-owned evidence checks; it does not complete DASH-13 packaging work.

## Research status and exact provenance

[retest-map.json](retest-map.json) maps **all 20 observations and all 48 proposed
actions** to actual GitHub issues and their required retest case sets. Per-observation
fixture IDs show bounded coverage; explicit reasons preserve everything not tested.
Future issue case lists are requirements, not claimed implemented test coverage.
TRIO-FR-18 remains a code-inspection hypothesis, not an established over-admission
incident. TRIO-FR-20 remains provider-transport classification, not a reasoning score.

Original `observations.json` and `evidence-index.json` are byte-preserved in Git at
publication revision `20dfca35bdd2fc8eab0b5fc52ae1b612b14d0e5e`; the manifest pins
both original Git blob identities. Their 17 raw artifact references remain local-only.
No private raw file was opened, recovered, copied or rehashed in this task.

Each mapped action has `state`, `implementationRevision`, `verification` and an
unresolved reason. Proposed actions cannot claim execution. Implemented actions
require a full revision and no verification claim. Verified fixture work requires a
matching-revision, committed public receipt with canonical hash, zero exit, matching
current implementation/corpus/replay identities and zero forbidden attempts. These
states describe the action's bounded retest, **not resolution of the historical
finding**; `findingStatus` remains proposed. A missing or inconsistent receipt fails
repository replay rather than silently retaining verified status.

Exact implementation/CI/accepted-revision identities are appended in the issue/PR
and in `retests/` receipts when available. The source argument is caller-declared;
CI commit/tree output plus independent source-content hashes identify the tested
checkout. Documentation-only status updates do not silently change the tested code.

## ADR: use a closed offline oracle before adding live controls

**Decision:** use a standard-library-only, closed JSON envelope and pure projector,
with a small disposable-I/O runner. Reconstruct checkpoints from a verified immutable
journal prefix instead of trusting serialized task/acceptance state.

**Alternatives:** replay through the existing live collectors would risk opening
process/network adapters; a production broker/journal would prematurely implement
DASH-05/06; publishing historical raw logs would violate privacy/provenance boundaries.
The existing read-only UI is therefore not changed or falsely qualified by this work.

**Consequences:** synthetic PASS/FAIL/stale/unverified behavior is reproducible,
corrections retain original identities, and data cannot request dispatch. The audit
hook and closed import graph are regression safeguards, not a general hostile-code
sandbox. Privacy signatures are defense in depth, not universal redaction proof.

**Revisit:** when DASH-02 defines actual adapter envelopes, add explicit conversion
fixtures and preserve these original cases. When DASH-05/06 adds controls/acceptance,
extend its own crash/authorization tests; do not repurpose this runner to execute
recorded instructions. Recorded fixtures require reviewed provenance before admission.

Use the [ADR/evidence template](../ADR-EVIDENCE-TEMPLATE.md) for new decisions and
append-only corrections. Live inference, provider accounts, original owner patches,
VM lifecycle/security reproduction and physical terminal qualification remain out
of scope. All programme capability release gates remain closed.
