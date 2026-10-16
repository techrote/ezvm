# Dashboard records and control contracts — draft

Companion to the [product proposal](VM-AI-DASHBOARD.md). These are proposed schemas and
behaviour, not implemented EzVM API changes. Use `schemaVersion` consistently with EzVM.

## Identity and durable records

| Record | Required identity and information |
|---|---|
| VmRef | EzVM root identity, instance identity/generation, name, intended resources; observed process identity separate |
| ProjectRef | VM/root, repository identity, accepted branch/commit, active restart checkpoint; never infer current source from a folder name |
| Task | UUID, user-visible name, original criteria, dependencies, scope, phase, policy revision, budget ledger and paused intent |
| Attempt | UUID, task ID, attempt number, base commit, worktree, source roots, role, model/runtime fingerprint, limits, timestamps, outcome |
| WorkerSession | Stable origin/server identity, directory scope, session ID, owner, attempt link, observed state/age and capability set |
| ModelRequest | Origin request/message ID, attempt, provider/model, timing, retry parent, usage raw/normalised, finish/error reason |
| ToolExecution | Stable execution ID, owning attempt/session, command description, started/completed, exit code, actual source tree and output references |
| Artifact | Content hash, kind, relative recovery location, producer and tested/reviewed source identity |
| Review | Author candidate hash, reviewer session/model, independence policy, criteria/results, finding IDs, committed report and evidence |
| ActionIntent | UUID, actor, target scope, expected state revision, typed parameters, policy revision, authorization basis, dispatch/ack/result |
| PoolLease | Pool ID, holder/attempt, reservation/heartbeat/expiry, actual reconciliation and release evidence |
| Observation | Research ID, dated first-person observation, evidence IDs, confidence, hypothesis, proposed action and retest result |

An OpenCode port is an endpoint, not permanent session identity. A worktree's branch label
is not unique contributor identity. A checked-out HEAD during uncommitted tests is not a
tested-tree hash. Capture a tree/patch digest at verification start and end; fail an acceptance
claim if the tested tree changed unexpectedly. Retain full reviewed history when importing
work, and validate all unique provenance records instead of deduplicating branch names.

Events include a unique ID, source epoch/sequence where provided, event time, ingestion time,
scope, type and payload schema. Use monotonic clocks for elapsed time inside a process;
cross-host wall-time ordering carries clock uncertainty. Replayed events update projections
idempotently. Corrections append a superseding event, preserving original observations.

## Example metric envelope

Illustrative shape only; `null` deliberately means unknown:

```json
{
  "schemaVersion": 1,
  "scope": {"kind": "worker", "id": "example-worker"},
  "metric": "request.decode_tokens_per_second",
  "value": null,
  "unit": "tokens/second",
  "quality": "unavailable",
  "reason": "adapter does not expose decode duration",
  "observedAt": "2026-10-16T14:00:00Z",
  "windowSeconds": null,
  "source": {"adapter": "example", "version": "1", "recordId": "request-7"},
  "method": "requires generated token count and decode-only duration"
}
```

Normalised usage retains optional fields for fresh input, cached read/write, output and
reasoning; an inclusion map describes overlap. An adapter either proves a disjoint total,
shows a provider-reported total, or leaves aggregate unknown. Maintain coverage counts:
requests observed, requests with usage, incomplete requests, records excluded and reason.

When a source reports an updated final usage record, replace that record's contribution
transactionally; do not append another billable-looking total. Provider-account spend and
quota are unavailable unless actually exposed. Cost policy is independent of metric display.

## Command execution and failure handling

All mutations pass through one typed command service, independently testable without the
terminal. It checks ownership, current policy and expected revision, records intent before
dispatch, and records acknowledgment and verified result separately. Model-supplied output
does not create a command. A view's stale row cannot target a newly reused session/PID.

An external API may not provide idempotent execution. After a timeout, reconcile by stable
attempt/session metadata and observable effects before retrying. If ambiguity remains,
hold with `needs reconciliation`; do not promise exactly-once network delivery. Controller
restart never blindly replays pending starts, prompts, merges or provisioning changes.

Only enrolled/owned worker sessions are controllable. Discovered unrelated sessions may be
shown as external/read-only. An endpoint timeout is `unknown`, not `idle`. The existing
TRIO guard is a field-test reference, not a finished global admission protocol: one branch
converts scoped URL errors to empty maps. That code-inspection concern needs a separate
failure test; no over-admission incident is asserted from it.

Pool reservation and request throttling are distinct. Count live workers across tool gaps;
all retries re-enter request admission. Owner pause first prevents new leases/admissions,
then applies the selected drain/interrupt action to owned existing work. Expired leases
require actual reconciliation before reallocating possibly occupied GPU/model slots.

Local model changes acquire an engine lease, drain users and preserve the old configuration.
After a load, verify effective context/mode and physical GPU UUID/memory before the first
inference request. An index-only saved choice cannot survive a hardware change unchecked.
Capability failure stops the load workflow; no fallback to an unverified automatic loader.

## Work verification and review queue

Each queued item describes its exact input artifact and required output. Review queues can
use same/different-model preferences, available capacity, bounded duration and independence
constraints. A review on an earlier tree cannot silently accept a later repair.

Evidence gates are predicates over artifacts, not strings in model prose. Example gates:
clean intended diff; source-root assertions; focused checks; original criterion evidence;
committed report; all intended histories/provenance preserved; full issue CI; mandatory
postmerge CI. Projects choose their gates; TRIO's six-cycle limit is a project policy.

Verification budget uses an invocation ledger across attempts/phases. Bind real runs to
their tested tree and log artifacts. Detect un-ticketed runs and reconcile them honestly;
do not rerun green CI simply to repair counters or documentation. Budget exhaustion holds
work for a decision; it does not weaken checks. Reserve postmerge capacity when the project
requires that gate. A separate fast check does not count as full CI unless policy says so.

Steering includes target, text, delivery mode (`next boundary` or adapter-supported immediate
message), expiration and user identity. Show whether the provider acknowledged receipt;
that is not proof the model obeyed it. A changed task scope creates an explicit amendment.

## Terminal and collector bounds

Prefer structured tool events for observation. Native attach remains a separate viewer and
can be detached/reused without changing worker lifecycle. Embedding a PTY requires explicit
input ownership, escape handling, resize propagation, terminal restoration and bounded
scrollback tests; do not fake it by concatenating raw ANSI output into the dashboard.

Use one source subscription with fan-out to panes. Persist cursors/IDs for bounded backfill.
Apply timeouts and backpressure independently per source; show dropped/rotated output and
retained artifact location. Visible panes can refresh rapidly; hidden panes consume cached
data. Do not spawn one whole native client per tile or poll every directory on every frame.

Guest metrics can use a versioned read-only collector through existing SSH, without a new
guest service initially. Collect CPU deltas, available RAM/swap and filesystem statistics
in one bounded sample. Host collector measures process load, commit and GPU identity.
Avoid repeated expensive whole-payload hashes for routine telemetry; mutation paths retain
the existing validation requirements. Small-status API needs measured latency first.

## Persistence, research and export

Proposed ignored layout: `runtime/dashboard/<schema>/` for journal, cache, layout and policy;
per-project evidence references point at recoverable local artifacts. Use atomic writes,
migrations with retained preimages, and bounded retention. Disk pressure may prune verified
disposable caches only under policy; never silently remove evidence needed by open tasks.

User configuration, runtime observations and historical research are separate. A mutable
model registry is not a static release contract. Generated CURRENT-style summaries cite
ledger revision and timestamps; original reports stay immutable. Export selected source,
evidence and hashes into a restart capsule; a history hash proves integrity, not correctness.

Public research contains redacted observations and reproductions. Raw prompts/reasoning,
terminal output, account metadata and database contents are private by default. Export
previews enumerate included files and allow review. Do not automate telemetry uploads.

## Failure cases required before enabling controls

1. Two views enqueue the same action; controller crash occurs before/after dispatch.
2. VM goes away, session port changes, session ID appears through two servers, or PID is reused.
3. Provider retries while owner pauses; quota resets while paused; cancel acknowledges but a
   tool child remains active; API status query times out.
4. Cached usage is corrected; reasoning overlaps output; usage never arrives after a failure.
5. Model source changes after review; generic Python imports a different checkout; prose says
   PASS while exit is non-zero; report exists only as uncommitted WIP.
6. Local model requests too much context or lands on a disallowed device; requested mode
   differs from actual mode; two workers compete for one runtime.
7. Disk growth is interrupted at every stage, the guest sees old geometry, or host space falls
   below required reserve. Read-only observation does not mutate another VM.
8. Terminal input is captured in the wrong pane, modal dismissal clicks through, collector
   stalls under10-second network latency, or repeated attach views exhaust memory.

Use stubs/recorded fixtures first and dedicated test VMs for later qualification. Real
standard-user WHPX/Windows Terminal checks are distinct from unit/TCG results. Do not
reopen the paused TRIO programme or run probes merely because these tests are proposed.
