# Dashboard RAG 04 — Capacity, model policy and automations

Status: future policy/control contract. Observing capacity does not grant permission
to load a model or launch a worker. Read [commands](03-CONTROLS-AND-REVIEW.md).

## User-editable policies

Pools have stable IDs and scopes across all registered controllers/VMs that share
the provider allowance or local runtime. Configure allowed provider/model identities,
roles, worker cap, request rate/window/minimum spacing, context/output bounds,
cooldown/backoff, local sequences, resource reserves and allowed GPU UUIDs.
Keep preferred local/remote allocation and fallback order explicit so available
local capacity cannot be silently abandoned. A waiting task explains its constraint.

Registry entries include observation date, capability provenance, support status
(healthy, untested, cooling, quota-limited, disabled, unavailable), expiry and spend
policy. Subscription/account setup is separate and explicit. No silent paid fallback.
The prior TRIO 3-worker / target34 / hard38RPM configuration is an imported example,
not a claimed provider service limit or a product default.

## Admission protocol

Worker reservation and request admission are different ledgers. Reserve before
launch; count a live worker during tool gaps and retries. Every request attempt,
including retry and model fallback, re-enters the shared rate gate. Use a monotonic
rolling window for one controller and a single shared authority per pool; surface
scope limitations if unrelated account traffic is invisible.

Unknown occupancy/status fails closed for new admission. Expired leases need actual
reconciliation before reclaiming capacity. Provider 429s can occur below the local
rate cap: record retry-after where supplied, bounded jitter/backoff, cooldown and
coverage. Never infer a universal minimum safe delay from one field run.

## Local engine ownership

Multiple workers may share **one loaded model** only when the runtime supports and
has measured concurrent sequence capacity. A worker slot is not a model instance.
Model reload/switch needs an exclusive engine lease, drain, a recoverable configuration
preimage and verification of effective settings and physical allocation before
inference. Preserve useful active work; no speculative reload from a metrics pane.

Bind device choice to physical UUID and validate current enumeration after hardware
change. Requested/effective context, quant/file digest, KV/MTP, load mode and worker
capacity are recorded. Unknown device allocation holds inference. Do not fall back
to an automatic CLI loader when explicit per-instance placement is unavailable.
Host/device acceptance uses synthetic adapter failures first; never reproduce the
prior forbidden-device incident on the owner's hardware.

Respect host RAM/commit/VRAM reserve and configured thermal threshold. A loaded-model
failure or repeated quality failure may justify a **policy-authorized** fallback;
token throughput alone cannot promote a model. Preserve actual author contributions.

## Automations

An automation has owner, trigger, scope, preconditions, action template, budget,
dedup key, cooldown, expiry, notification policy and visible run history. Begin with
dry-run previews. Initial templates: queue review on a verified candidate; request
bounded rework for selected findings; hold on repeated failures; notify on required
judgment; prevent new work below resource reserve.

Triggers cannot override pause, spend policy, admission or evidence gates. One
scheduler owns a trigger; imported external schedules are referenced, not duplicated.
Clock/time-zone changes and restart cannot replay completed actions. Expired
availability blocks launch with an explanation. Auto-upgrade, account creation and
automatic main merges are outside the initial automation release.

## Tests that distinguish policy from UI

Race simultaneous reservations; retry during pause; stale status at lease expiry;
429 below configured RPM; duplicate timer firing; expired model availability;
hardware UUID/index swap; requested/effective mode mismatch; two workers sharing
one engine; and an attempted switch while useful work is active. Each fixture
asserts the actual dispatch/load count, not merely a disabled button.
