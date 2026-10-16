# DASH-01 public replay corpus (envelope v1)

`corpus.json` contains 16 hand-authored **synthetic** fixture envelopes. They are
failure-class reconstructions, not copies or replays of private TRIO logs.
`manifest.json` locks every complete envelope by canonical SHA-256 and names the
immutable original public research blobs at the programme publication revision.
No account, VM, database, raw prompt, private reasoning or host path is required.

The expected projections and counters are literal reviewed oracles, not generated
by the replay engine. A successful test of a negative example still projects failed,
unverified or stale evidence. Even valid fixture evidence never accepts a task.

| Fixture | Expected boundary |
|---|---|
| idle-deduplicated | One origin/epoch/session/record observed at two endpoint views counts once. |
| streaming; tool-running | Activity is observable, not completion or acceptance. |
| retry-quota | Quota retry is visible without a guessed provider root cause. |
| transport-failure | No-response transport is not a model reasoning defect or free capacity. |
| stale-source | A stale observation also invalidates applicability of previously valid evidence. |
| incorrect-import | Wrong source root is failed harness evidence. |
| missing-report; uncommitted-report | Missing committed evidence stays unverified. |
| failed-exit-with-pass | A nonzero exit beats PASS text. |
| paused-restart | Historical resume and retry requests cannot dispatch or unpause. |
| corrected-import | Explicit corrected evidence preserves the original failed result. |
| superseded-source; corrected-source | A changed tree needs new evidence; the original remains intact. |
| epoch-reuse | Reused record IDs in a new source epoch are not duplicates. |
| transport-with-valid-report | Transport category remains visible alongside valid report evidence. |

## Envelope and event contract

Every envelope has integer `schemaVersion`, immutable `id`, `kind` (synthetic or
recorded), source name/version/revision/UTC capture/method and a reviewed redaction
record. The source revision identifies the researched baseline; the executing
implementation is separately identified by the replay receipt's commit assertion
and independently computed source-content hashes. A recorded fixture also needs a
raw artifact hash matching a referenced public evidence-index entry. That check
validates the published reference, not access to or rehashing of the private raw file.
There are currently **no recorded fixtures**.

`initial` names a synthetic content tree, relative import alias, candidate phase and
held operator intent. `clockMs` and `staleAfterMs` are explicit integer fixture time;
wall clock is never consulted by projection. Events use origin, epoch, session and
record ID for identity. Endpoint `view` is an attribute. Conflicting duplicates,
unknown schemas/kinds, out-of-order unique events and ambiguous evidence replacement
fail closed. Reusing an evidence ID is forbidden; new evidence must explicitly
supersede the effective record. Report metadata and commit flags are simulated data,
not verification of any real repository's report.

`expected` contains the complete projection, received/unique/duplicate/request
counters, dispatch count and VM/worker/provider/outside-output mutation counts.
All dispatch and forbidden mutation expectations must be integer zero. Session,
source freshness, operator intent and evidence applicability remain separate.
No live-adapter serialization compatibility or production acceptance API is claimed.

A correction is a **new envelope ID** with `supersedes: {id, sha256, reason}`. It
must retain the original initial identity and full event prefix, then append its
correction. Never regenerate the manifest to hide an edited or deleted original.
Both originals and corrections remain separately replayable and hash-checked.

## Run and retain evidence

From a source checkout, Python 3.10+ can run the standard-library-only replay:

```powershell
python -B -m unittest discover -s dashboard/tests -p test_evidence.py -v
$revision = (git rev-parse HEAD).Trim()
python -B dashboard/replay.py --source-revision $revision
```

The runner checks every expected result twice and after disk checkpoint/restart at
every cut (49 cuts for this corpus). Checkpoints persist a fixture hash and verified
journal prefix, never trusted derived acceptance state. Only a fresh disposable
output directory is written; it is removed on exit. Stdout is the retainable JSON
receipt, including per-fixture results/hashes, actual Python/platform, start/end,
source content identity, original-research checks and audited operation counts.
The caller may explicitly redirect stdout into its own evidence directory.

`replaySha256` is deterministic across runs/platforms; execution timestamps and
runtime metadata are deliberately not part of that deterministic payload. Hashes
use UTF-8 canonical JSON (sorted keys, compact separators, no nonfinite values).
Source-content and original Git-blob checks normalize checkout CRLF to LF and are
explicitly not claims about raw Windows file-byte hashes.

The source commit argument is caller-declared. CI checks out the exact head, prints
its real commit/tree, runs the suite and records the independently computed content
identity. Do not relabel a dirty/local result as an exact clean checkout result.

## Boundaries and privacy

Replay imports no VM, process, network, guest or inference adapter. Runtime audit
hooks reject socket/process/native-loader operations, environment changes, links,
and writes/deletes/renames outside the disposable root. Tests exercise real API
constructors and unchanged external sentinels, rather than trusting a zero counter
alone. The audit guard is a regression tripwire for this trusted Python runner,
**not an OS security sandbox for arbitrary hostile Python/native extensions**.

The closed envelope and recursive privacy check reject planted token, key and host
path signatures, including metadata/expected-result fields. This is not a universal
secret detector or an automatic public-log exporter. Human/maintainer content review
and explicit source/redaction metadata remain required; raw/private logs stay out.

See the [traceability ledger](../../../docs/research/TRIO-2026-10/retest-map.json)
and [research handoff](../../../docs/research/TRIO-2026-10/DASH-01-REPLAY.md).
TRIO remains paused; this harness grants no restart or live-test permission.
