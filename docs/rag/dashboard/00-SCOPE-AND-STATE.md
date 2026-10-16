# Dashboard RAG 00 — Scope, authority and state

Status: **target contract for future dashboard issues**, not a claim of implemented
features. Read [AGENTS](../../../AGENTS.md), the selected issue and the
[programme](../../programme/dashboard/README.md). Existing EzVM RAG remains binding.
A future issue updates this contract and its tests together when a design changes.

## Implemented baseline

The optional read-only companion at `d692be6` uses a PowerShell 5.1 launcher and
an isolated Python/prompt_toolkit runtime. Its modules are under
`dashboard/ezvm_dashboard/`. It observes host state, one explicitly enrolled guest,
OpenCode history/scoped status and Strata/LM Studio endpoints. See the
[current guide](../../DASHBOARD.md) and [actual verification](../../DASHBOARD-VERIFICATION.md).
Reconcile live HEAD before implementation; this reference is a baseline, not a pin
that allows overwriting later work.

It has no command broker, work queue, provisioning controls or persistent layout.
Do not invent a clean release qualification: the prototype's control-plane run
had 346 passes and one dirty-tree release-package guard failure. The owner's
`Keys.ps1` and `Runtime.ps1` patches are outside the dashboard change.

## Architecture

The UI renders cached observations and typed user intents. Adapters own source
semantics and capability declarations. A future optional controller owns mutations,
admission, durable action records and reconciliation. The existing PowerShell CLI
remains the VM lifecycle authority. No browser, Docker, WSL or Windows service is
required in the normal path. No TRIO product module is a dependency.

Controller ownership is explicit: one writer per configured scope, multiple readers.
A viewer exiting detaches; it never implicitly aborts workers. A controller must
show whether its lifetime continues after a viewer closes. Until DASH-05 is accepted,
the only supported lifetime is the current read-only viewer.

## Identities

| Entity | Identity and required relationship |
|---|---|
| VM | EzVM root identity, instance name/generation; current launch/process separate |
| Project | VM, repository identity, accepted baseline, candidate and restart checkpoint |
| Task | Stable ID, original criteria, scope, dependencies, paused intent, policy revision |
| Attempt | Task, unique attempt ID, role, model/runtime, base/worktree/tree, limits |
| Session | Stable source origin plus session ID; endpoint and directory are attributes |
| Request/tool | Source record ID plus source epoch; attempt/session, timings and result |
| Artifact/review | Content hash, producer, source/tested tree, reviewer and original record |
| Action | Intent ID, target identity, expected revision, authorization and policy revision |

A port or PID alone is never identity. Two endpoint views of one session do not
become two workers. The current directory is not automatically the restart source.
When tests run over WIP, record source/patch digests before and after; commit HEAD
alone cannot identify the tested tree.

## State dimensions

Keep these independent:

- Task phase: draft, queued, running, candidate, awaiting-review, rework, verified,
  integrating, postmerge-checks, accepted; blocked/cancelled/paused preserve phase.
- Session observation: unknown, idle, requesting, streaming, tool-running,
  retry-wait, disconnected, stopping, stopped, with age and source.
- Operator intent: dispatch enabled, paused, drain requested, interrupt requested.
- Evidence status: absent, pending, valid, stale, failed, human override.

Idle, tokens emitted, a test count or a model's PASS text cannot imply acceptance.
Changing the reviewed source invalidates its acceptance applicability.

## Storage and compatibility

Every durable JSON envelope uses integer `schemaVersion`. Keep generated local
state under ignored `runtime/dashboard/`; distinguish preferences, policy,
observations, action journal and evidence. Journal implementation may use SQLite,
but its external/export schema is versioned. Atomic updates, migrations with
preimages and crash recovery precede controls. Unknown schema fails closed for
mutations while preserving inspectable data.

Do not replace the programme's manual pause with inferred API idle. TRIO remains
paused until the owner explicitly resumes it. Documentation, fixtures and release
plans do not grant permission to launch workers or change the owner's machines.
