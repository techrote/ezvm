# DASH-02 scoped observation implementation and research handoff

Issue: [#28](https://github.com/techrote/ezvm/issues/28). Publication checkpoint (2026-10-18):
**REVIEW**, not accepted merely because local tests pass. Reconcile the live PR/issue
for exact head, required CI, merge and accepted revision. Baseline is accepted
DASH-01 main `d5265c804d0d8494d8171482a85aca563b181e05`.

## Decision and compatibility

The prior selected/recent cap could starve old registered workers. A rotating lane
now reserves service independently of selected/active priority. Explicit registration
is control-independent observer scope, not permission to launch, resume or admit work.
Selecting unregistered history deliberately does not generate a status request.

Read boundaries are in `dashboard/ezvm_dashboard/adapters.py`; guest collection and
host aggregation remain separate. Existing prompt_toolkit controls, passive host
metrics and all core PowerShell APIs are preserved. The original 25 dashboard tests
remain, with their guest fixture explicitly registering the two intended actors and
using the new bounded read seam. Their formerly unregistered automatic polling is
replaced by the issue's explicit-registration contract, not a relaxed assertion.

| Adapter | Tested structural contract | Capability / failure policy |
|---|---|---|
| Host resources | psutil API plus fixed nvidia-smi query | Passive counters; unavailable GPU data never triggers loading |
| EzVM records | intent v1/v2, runtime v1, access v2 | Current PID/start/executable/argv and launch; no readiness/control authority |
| Guest SQLite | user_version=0; required session/message/part fields | Two stable bounded DB/WAL captures; query only disposable copy; unknown layout refused |
| OpenCode status | idle/busy/retry map; validated retry fields | Only registered directories; every alias must succeed for current known state |
| Strata | metrics engine/live/totals/requests projection v1 | Reported fields only; configured/effective/requested context stay distinct |
| LM Studio | v0 models data-list projection | Metadata GET only; never loads a model |

[Schema samples](../../../dashboard/fixtures/dash02/schemas.json) are explicitly
synthetic, based on the existing accepted reader and captured PRAGMA layouts from
disposable fixtures. They are not a private DB export, vendor-wide version promise
or live hardware result. Unknown explicit versions/required types are refused.
The guest requires Python 3.11+ for SQLite limits; pinned hosted tests use 3.12.10.

## Boundaries and evidence interpretation

Origin/epoch/session identities are independent of port aliases. A new VM launch,
durable generation, source DB identity or moved registered root invalidates cached
observations. Host process identity includes the core little-endian argument
fingerprint, not PID alone. Pre/post SSH identity checks discard cross-launch output.
Source declarations distinguish accepted baseline, candidate and restart paths;
wrappers are files. Path checks are not attestation of a live worker's imported code.

SSH sends reviewed source over stdin using strict existing managed trust. Its
OpenSSH path quoting mirrors [core Ssh.ps1](https://github.com/techrote/ezvm/blob/d5265c804d0d8494d8171482a85aca563b181e05/src/EzVm/Ssh.ps1),
including spaces, percent tokens and environment-expansion refusal. Global trust
fallback, key creation and bootstrap are absent. Generated modules compile separately;
a subprocess regression catches future-import/import-path serialization failures.

[SQLite documents](https://www.sqlite.org/wal.html#read_only_databases) that read-only
WAL connections can create sidecars. Therefore no SQLite connection opens the source.
Two equal bounded DB/WAL file-set captures, pre/post metadata and rollback-journal
refusal precede disposable querying. In a changing or oversized DB, this sampler
fails visibly rather than claiming a coherent snapshot. It is not a hostile-code
sandbox or a backup API. Git clean filters are refused before worktree refresh;
external diff/textconv and fsmonitor are disabled. Both status and diff explicitly
exclude submodule worktrees, whose independent filters are outside the parent
configuration check. The Changes view labels nested submodule changes unobserved.
A real parent/submodule negative control first proves its sentinel filter can run,
then verifies the observer retains parent edits without executing that filter or
changing fixture bytes. Only owned sampler children may be terminated.
Source/fixture sentinels and source DB/WAL bytes stay unchanged.

HTTP's ordinary socket timeout measures inactivity, so trickled status headers or
chunk framing can defeat a body-loop deadline. Each allowlisted GET now owns a
numeric-loopback socket and a short-lived watchdog that shuts down only that
socket on the absolute deadline or cancellation. Closing the viewer propagates
cancellation to active engine reads. Actual urllib/http.client parser regressions
cover headers, chunk framing, cancelled valid JSON prefixes and premature EOF
before the declared content length. Separate real loopback tests cover socket
ownership, concurrent requests and cancellation. Each call constructs a fresh
handler chain and closes its response stream even when redirects are refused.
No provider mutation or request retry is introduced, and completed requests retire
their watchdog.

Limits are explicit: 256 actor entries, 1..4 distinct ports, batch 1..32, eight guest
GETs, seven independent host jobs, one in-flight per source; 64 MB DB/16 MB WAL,
10,000 recent sessions plus registered lookups, 20,000 messages, 45 detail parts,
4 MB combined pipe/HTTP data, 3-second/10-million-instruction SQLite budget and
40-second guest child budget. No duplicate retry is admitted while one is in flight.
Late results are discarded. Host-declared registrations stay visibly unknown even
when the first sample fails. Last-good data/age survive errors; state never becomes
idle/free merely because polling failed. CLI one-shot expiry is nonzero.

For N eligible roots and batch B, the reserved lane is max(1,B-1) when N>B, otherwise
B. Declared full-cycle bound is ceil(N/reserved)*48 seconds; unavailable/overdue actors
are listed explicitly. Selection churn does not reset cursor or poll timing. The
bound is not a p95 or an inference-admission promise. Guest policy-only identities
cannot be discovered through an unavailable SSH source and are not invented on host.

## Required cases and measurement procedure

`dashboard/tests/test_observation.py` implements DASH-02-T01..T05. Tests cover alias
identity, PID/launch/root reuse, fair service under changing selection, unsupported
schemas, malformed/oversized JSON, source immutability, missing trust, partial failure,
owned-child cancellation, imports/wrapper files, source declarations and publication
schema samples. Existing UI mouse/keyboard tests remain intact.

T03 uses an actual prompt_toolkit Application with pipe input and DummyOutput while
a single source stalls for ten seconds. It records 20 input dispatch latencies,
p95/max, CPU, wall time, RSS, healthy polls and slow-source call count. This is real
input dispatch but not physical terminal paint. The acceptance assertion remains
p95 below 100 ms and one in-flight stalled sample; no threshold is raised here.

T05 constructs 1,100 session records and 17 registered roots, batch three/two alias
ports, nine cycles and delayed GET stubs. It records exactly 54 polls, CPU/wall time,
sampled peak process RSS and maximum source age; all registrations receive service.
It does not measure a real provider or qualify the DASH-11 idle CPU/memory budget.

Run from a clean full checkout:

```powershell
python -B dashboard/qualify_observation.py --output "$env:TEMP/dash02-observation.json"
```

The receipt binds actual Git HEAD/tree, source hashes before/after, runtime/dependency
versions, every test result and all five case groups. A source-subset run must use
`--allow-source-subset`; its null commit/tree and false checkoutQualification forbid
relabeling it exact-checkout acceptance. The dedicated Windows workflow uses existing
hash-pinned dependencies and Python 3.12.10; it retains the public JSON receipt.
DASH-01 CI still runs the full Windows dashboard suite and its original Linux replay;
the existing core CI and real-release checks remain mandatory. The added Linux
guest-probe process lane supplements both Windows control-plane lanes.

Initial local development used Python 3.13.5 / psutil 7.2.2 / prompt_toolkit 3.0.52 /
wcwidth 0.7.0 on a reconstructed authored-file set. It is supplementary Linux evidence,
not the pinned Windows checkout. Actual hosted results, revision IDs and receipt
hashes belong in the live PR/issue and retained appended receipts, not guessed here.

## Research feedback and unresolved scope

This is an appended scoped retest mapping, not a rewrite of the original field
register or DASH-01 receipt. The original observations/evidence index and all six
DASH-01 source/test/corpus hashes are unchanged. The original retest-map remains its
DASH-01 checkpoint; this handoff records the new adapter scope without falsely
upgrading all historical findings.

| Observation | Implemented scoped retest | Still unresolved |
|---|---|---|
| TRIO-FR-02 | T01/T02/T04: launch/root identity, fair registered roots, separate restart path | Original live restart incident and complete workflow restart capsule |
| TRIO-FR-04 | T04: own-root path assertion, foreign checkout refusal, executable wrappers as files | Independent proof of what a live worker actually executed |
| TRIO-FR-11 | T03/T04: schema versions and configured/effective/requested context separation | Live engine runtime/context/GPU qualification |
| TRIO-FR-18 | T02/T03/T05: failed/overdue sources never become admission authority | Historical over-admission remains a hypothesis; no control/admission code is qualified |

No historical finding is declared resolved. No private raw evidence, provider account,
worker, GPU or original owner environment was accessed. TRIO remains paused. Read-only
release, performance, packaging, worker controls and provisioning retain their later
programme gates. The implementation has no write/admission API to enable them.
