# Dashboard RAG 01 — Observations, identity and metrics

Status: observation boundaries implemented by DASH-02; broader usage/rate contracts
remain targets for DASH-04 and later issues. Read [scope/state](00-SCOPE-AND-STATE.md),
[the guide](../../DASHBOARD.md) and the [DASH-02 handoff](../../research/TRIO-2026-10/DASH-02-OBSERVATION.md).

## Read path and capabilities

Each adapter declares source ID, version/schema support, scope, capabilities,
read method, refresh bound and last successful observation. First-party adapters:
EzVM passive state/process identity, an explicitly enrolled guest over existing SSH,
OpenCode API/history, Strata, LM Studio. Provider models used through OpenCode are
observed through OpenCode; direct provider APIs remain optional separately enrolled
future adapters, not a credential-discovery mechanism.

DASH-02 emits `schemaVersion=1`, `contract=ezvm-observation-v1`, source ID,
structural source version, read method, `capabilities=[observe]` and
`controlEligible=false`. Structural compatibility does not claim every upstream
release is qualified. The [schema samples](../../../dashboard/fixtures/dash02/schemas.json)
are explicitly synthetic projections, with disposable SQLite schema captures.
Unknown required types, status variants or explicit versions fail closed.

SQLite is opened only on a disposable bounded copy of the DB/WAL file set. Two
matching captures reject concurrent changes; a nonempty rollback journal is refused.
The copy is query-only and has byte, row, instruction and time limits. No SQLite
connection opens the source DB. This avoids source-side WAL shared-memory creation:
[SQLite's WAL contract](https://www.sqlite.org/wal.html#read_only_databases) allows
read-only connections to create sidecars. Do not assert immutable on a live source.

Observe all **registered** actors, including old roots, under a bounded rotating
scheduler. Selected/active priority cannot consume the reserved rotating lane.
Registration comes from explicit config or the enrolled workspace's owner-policy
actors. Prefix/path matching limits visible history; it does not enroll that history.
Selection is not enrollment. Show registration count, sampled count, oldest age,
cycle bound, failed reads and overdue identities. This is not broad discovery.

Host-declared actors are visible as unknown before the first successful sample.
Guest-only policy registrations cannot be enumerated while the guest is unavailable;
the UI reports source failure rather than claiming the host declaration is complete.
Missing registered sessions or mismatched source roots remain visibly unknown.

A stale READY file cannot authorize a mutation. Existing managed SSH trust stays
strict; reads cannot enroll keys or bootstrap a VM. Passive pre/post checks bind
instance name, durable generation, current launch, PID/start/executable/argument
fingerprint, base and SSH reservation. Trust paths use the core OpenSSH quoting
contract, including percent escaping and environment-expansion refusal; no global
known-host fallback is used. Redirects, proxies and output-derived URLs are refused.
Only allowlisted loopback GETs are used; no prompt, model load or provider probe.

## Observation envelope

Each value needs scope/identity, metric name, value or null, unit, event time,
observed time, age, window, source record/version, method and quality. Quality is
reported, measured, derived, estimated, unavailable or stale; include an unavailable
reason. Unknown never becomes zero. Requested, configured, effective and physically
observed resource/model values are distinct. DASH-02 labels missing requested or
effective model context unknown rather than copying the configured limit.

Use monotonic elapsed time inside one process. Cross-host timing carries clock
uncertainty; ingestion time does not replace provider timing silently. Each source
has independent deadlines and bounded buffers; rendering never waits for I/O.
There is one in-flight job per source, at most seven host jobs and eight guest GETs.
Late results are discarded; failures retain last-good data/age and mark current
state unknown. Closing cancels only owned sampler children, never an observed PID.

Registered origin/session identities include source epoch; endpoint ports are aliases,
not identity components. Launch/root changes invalidate poll cache. Accepted baseline,
candidate root and restart root are separate declarations. An import path must be a
file within the candidate root; an executable wrapper is a file, not a directory.
These checks do not attest which code a live worker executed or authorize acceptance.

## Usage ledger

The deduplication key is stable origin + request/message ID, with source epoch when
needed. Engine and OpenCode records of the same generation are linked when provable
or displayed separately; never summed by convenience. Duplicate ports are not usage.
A future durable corrected-record ledger replaces aggregate contributions
transactionally and preserves an audit trail; restart/backfill must be idempotent.

Retain raw provider usage and normalized input/cache-read/cache-write/output/reasoning.
Record field inclusion/overlap. A total is provider-reported, a proven disjoint sum,
or unknown. An absent/error response is not zero usage. Show records with usable
usage, incomplete records and exclusions. DASH-02 reads a bounded snapshot and labels
session/message scan limits and truncation; it no longer calls this all-time history.
Compaction/helper calls are included only when their provenance is visible within
that window. Historical imports retain provenance and coverage limits.

Cost, quota, free-tier eligibility, local electricity estimates and tokens are separate.
Do not claim free inference remains available from an old registry entry. Model,
transport, harness and source failures remain separate evidence categories.

## Rates and resources

Name the window and denominator for live decode, completed decode, prefill, arrival
rate and end-to-end output rate. Aggregate compatible counts/durations, not arithmetic
means of unlike TPS values. Remote decode duration remains unavailable if only wall
time is known. Future provider request charts distinguish admission, dispatch and
retry; dispatch is not observed provider arrival. Rolling RPM includes retries and
displays capture gaps. DASH-02 does not implement a provider admission ledger.

Host CPU, guest CPU and QEMU CPU have distinct denominators. Show RAM available,
commit headroom, swap, host free space, overlay allocation/virtual capacity and guest
filesystem free separately when available. GPU identity uses physical UUID plus current
index; shared engine power is not attributed to workers without a labelled estimate.

## Acceptance examples

Two ports returning message A once each count A once. Future ledger correction from
20 to 24 output tokens yields 24, not 44. Output 30 including reasoning 10 does not
become 40. A timed-out root is unknown even if another port reports busy or an empty
map; last-known activity remains evidence, never a free slot. A reused PID cannot
inherit process identity. Delayed reads, output floods and schema failures cannot
block UI dispatch or trigger writes, bootstrap, key enrollment or inference.

DASH-02 T01..T05 and `dashboard/qualify_observation.py` implement the scoped adapter,
fairness and failure tests. The 10-second pipe-input test measures dispatch, not
physical paint; the 1,100-session test measures bounded synthetic cost. Neither
accepts DASH-11 idle/performance budgets or any capability release gate.
