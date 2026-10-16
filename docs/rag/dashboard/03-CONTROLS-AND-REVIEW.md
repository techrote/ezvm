# Dashboard RAG 03 — Commands, pause, review and acceptance

Status: future control contract; no such controls are enabled in the prototype.
Read [state](00-SCOPE-AND-STATE.md) and [capacity](04-CAPACITY-AND-MODELS.md).

## One command authority

All mutations go through typed commands outside the UI. Check enrolled ownership,
target identity/generation, expected state revision, capability and current policy.
Record intent durably **before** dispatch. Record dispatch, acknowledgment, verified
result and reconciliation separately. Every action carries its operator/authorization
basis, policy revision, unique intent ID and bounded scope.

Suggested action states: proposed, validated, reserved, dispatching, acknowledged,
verified, failed, needs-reconciliation, cancelled. Before/after-dispatch crashes
must be replay-tested. A network timeout is not proof nothing happened; reconcile
stable attempt/session metadata and effects before retry. Ambiguity holds the action.
Do not promise exactly-once transport or blindly replay a prompt/start/merge.

A single-writer lease/lock prevents two dashboards controlling one scope. Its expiry
alone cannot prove old workers stopped. Stale generation/revision and external
sessions fail closed. UI/model output never constructs an executable command.

## Operator verbs

| Verb | Required semantics |
|---|---|
| Pause dispatch | Persist intent; block new tasks, prompts and retries under the scope |
| Drain then pause | Block future dispatch; await a supported current boundary; show pending work |
| Interrupt | Preserve WIP/usage, request exact owned-session abort, then verify remaining tool activity |
| Resume | Explicit operator action after reconciliation; preview the next eligible attempt |
| Steer | Exact target/text/boundary/expiry; queued, delivered and acknowledged are distinct |
| Change model | End/drain or explicitly interrupt old attempt; create a new attributed attempt |

An adapter may not support boundary drain or interruption. Disable unsupported verbs
with a reason; do not emulate safe pause using generic OS process suspension.
Acknowledged abort is not proof all tool children stopped or effects were undone.
Pause wins over quota reset, retry timers, restart, automation and model fallback.
No automatic resume on reopening a viewer or restoring a capsule.

## Review/rework queue

Task DAG edges require verified prerequisites. Freeze candidate commit **and**
tested-tree/WIP digest, original criteria, source import roots, retained report
hashes and author provenance. Create an isolated reviewer attempt with explicit
independence policy: different session minimum, optional different model/provider.
The UI must distinguish those levels; a different model alone proves nothing.

Findings have stable IDs, severity, supported contract, evidence and classification:
product defect, harness error, transport failure, documentation issue or unresolved.
A rework attempt links selected findings and the precise input revision. Preserve
original reports; append corrections. New source makes old review applicability stale.
Use tests that demonstrate behavior, not only printed PASS or duplicated assertions.

Queue states include waiting for capacity, dependency, evidence, policy or user
judgment. Explain the reason. Bounded failures hold/re-scope work according to policy;
they do not silently raise budgets or promote a fallback model.

## Integration and verification gates

Projects define evidence gates: intended clean diff, explicit imports, focused checks,
original criteria, committed review/report, full incoming history/provenance, whole
issue CI and required postmerge checks. Imported report-only tips cannot substitute
for source history. Unique contributor rows sharing a branch label are still unique.

Carry actual verification invocations across attempts/phases. Capture command, exit,
source identity, timestamps and log hashes. Reconcile un-ticketed actual runs without
rerunning unchanged green CI merely to fix bookkeeping. Reserve any required postmerge
slot. TRIO's six-cycle limit is an imported project example, not a universal default.

Initial queue release does **not** automatically merge main. An accepted integration
command requires its own policy and verified gates; postmerge failures remain visible.
Human overrides name the waived gate/reason and never rewrite the original test result.
