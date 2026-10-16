# Dashboard RAG 01 — Observations, identity and metrics

Status: target contract; implemented subset is documented in
[the guide](../../DASHBOARD.md). Read [scope/state](00-SCOPE-AND-STATE.md).

## Read path and capabilities

Each adapter declares source ID, version/schema support, scope, capabilities,
read method, refresh bound and last successful observation. First-party adapters:
EzVM passive state/process identity, an explicitly enrolled guest over existing SSH,
OpenCode API/event/history, Strata, LM Studio. Provider models used through OpenCode
are observed through OpenCode; direct provider APIs are optional separately enrolled
adapters, not a prerequisite or a credential-discovery mechanism.

Prefer versioned APIs. A read-only database adapter declares tested schema versions,
uses a consistent query-only snapshot and refuses unsupported layouts with an
actionable error. Never modify an engine's database to obtain telemetry.

Observe all **registered** actors, including old roots, under a bounded rotating
scheduler. Selected/root-priority sampling must not starve other registered actors.
Show registration count, sampled count, oldest age and discovery limitations.
Unregistered history remains explicitly historical/unobserved. This is bounded
coverage, not a promise to discover every process or unrelated account request.

A stale READY file cannot authorize a mutation. Existing managed SSH trust stays
strict; read collection cannot enroll keys or bootstrap a VM. Loopback endpoints
are explicitly enrolled; redirects, proxies and arbitrary output-derived URLs are
not followed. Do not load a model or send a probe prompt to obtain metrics.

## Observation envelope

Each value needs scope/identity, metric name, value or null, unit, event time,
observed time, age, window, source record/version, method and quality. Quality is
reported, measured, derived, estimated, unavailable or stale; include an unavailable
reason. Unknown never becomes zero. Requested, configured, effective and physically
observed resource/model values are distinct.

Use monotonic elapsed time inside one process. Cross-host timing carries clock
uncertainty; ingestion time does not replace provider timing silently. Each source
has an independent timeout, backoff and bounded buffer; render never waits for I/O.

## Usage ledger

The deduplication key is stable origin + request/message ID, with source epoch when
needed. Engine and OpenCode records of the same generation are linked when provable
or displayed separately; never summed by convenience. Duplicate ports are not usage.
A corrected final record replaces that record's aggregate contribution transactionally,
preserving an audit trail. Restart/backfill is idempotent.

Retain raw provider usage and normalized input/cache-read/cache-write/output/reasoning.
Record field inclusion/overlap. A total is either provider-reported, a proven disjoint
sum, or unknown. An absent/error response is not zero usage. Show observed records,
records with usable usage, incomplete records and exclusions with reasons. Include
compaction/helper calls when their provenance is visible. Historical imports retain
capture provenance and coverage limits.

Cost, quota, free-tier eligibility, local electricity estimates and tokens are separate.
Do not claim free inference remains available from an old registry entry. Model/
transport/harness/source failures have separate classifications.

## Rates and resources

Name the window and denominator for live decode, completed decode, prefill, arrival
rate and end-to-end output rate. Aggregate compatible counts/durations, not arithmetic
means of unlike TPS values. Remote decode duration remains unavailable if only wall
time is known. Provider request charts show admission, dispatch and retry times
separately; dispatch is not observed provider arrival. Rolling-window RPM/minimum
gap counts include retries and display gaps in capture.

Host CPU, guest CPU and QEMU CPU have distinct denominators. Show RAM available,
commit headroom, swap, host free space, overlay allocation/virtual capacity and guest
filesystem free separately when available. GPU identity uses physical UUID plus current
index; shared engine power is not attributed to workers without a labelled estimate.

## Acceptance examples

Two ports returning message A once each count A once. A usage correction from 20 to
24 output tokens yields 24, not 44. Output 30 including reasoning 10 does not become
40. A timed-out root is unknown even if another port returns an empty map. Reused
PID with a different start time cannot inherit prior process identity. Simulated
latency, output flood and schema failure never block UI input or trigger a write.
