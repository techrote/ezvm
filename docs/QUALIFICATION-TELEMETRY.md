# Optional full-qualification timing evidence

The original release/portability harness accepts `-TelemetryPath` for the Runloc
[CI-POC-001](https://github.com/techrote/runloc/issues/21) investigation. This is
observation of the existing scenario, not a replacement qualification or a cache.
No telemetry is installed or written when the parameter is omitted.

```powershell
.\scripts\Invoke-EzVm010RealPortability.ps1 -Root '<clean pinned checkout>' -ReleaseQualification -Accelerator whpx -TelemetryPath '<owned existing directory>\timing.jsonl'
```

The caller must already have completed the exact synthetic ACL and host preflight.
The caller owns the process containment, hard wall, source verification, private
output directory and fixture disposal. This option does not provide those controls
or authorize runner registration. A complete physical result still needs the full
original marker set, actual exit zero, requested/observed accelerator agreement,
unchanged source, and independent clean owned shutdown evidence.

## Measured operations

`scripts/QualificationTelemetry.ps1` temporarily wraps a fixed set of functions
in the **already loaded qualification module**. Each wrapper forwards the original
bound parameters to the original scriptblock in that module's session state.
The original functions, assertions, source files, return objects, errors and
deadlines remain in use. Wrappers are removed before the relocated module is
loaded, then installed into that module while retaining the observation session.
The module's default root must change normally during the cold relocation.

| Category | Observed functions/work |
|---|---|
| acquisition | QEMU installation and source-image acquisition |
| validation | QEMU payload integrity, prepared-base verification, instance storage, portable bundle, doctor |
| image | Native qemu-img commands and managed clone/export/import/reset |
| base-build | Complete prepared-base build, including its nested validation/image work |
| ready | Authenticated READY, including its nested validation and SSH work |
| shutdown | Original graceful-stop operation |
| process | Other original native process calls, with only an allowlisted tool name |

The qemu-img action is restricted to `info`, `compare`, `create`, `convert`,
`check`, `rebase`, `resize`, `--version`, or `other`. Raw arguments, paths,
usernames, guest output, stderr and exception text never enter telemetry.

Every `Get-EzVmFileDigest` call is timed, including repeated checks of the same
files. Fixed counters classify hashes as `manifest`, `qemu-payload`, `base-image`,
`source-image`, or `other`. Each counter records calls, failed calls, elapsed
seconds, and successfully hashed bytes when a known file kind's size was readable.
Unknown files expose no size. These are observation counters, not hash caching:
all original hashing and integrity checks still execute. Failed size observation
does not prevent the original hash operation from deciding its result.

Per-file hash events would multiply rapidly because the managed runtime verifies
its payload for repeated tool lookups. Counters instead appear as inclusive deltas
on each enclosing terminal event, and as totals on the terminal qualification
event. This records the repeated cost without writing one log entry per file.

## JSONL schema version 1

The file is UTF-8 without a BOM, with one JSON object per LF-terminated line.
Every record has these fields:

| Field | Meaning |
|---|---|
| `schemaVersion` | Integer `1` |
| `sequence` | Strictly increasing record number starting at 1 |
| `utc` | Host UTC timestamp in round-trip format |
| `elapsedSeconds` | Monotonic session time when the record is written |
| `event` | `start`, `end`, `failure`, or `identity` |
| `operationId` | Monotonically allocated span ID, reused for its terminal event |
| `parentOperationId` | Enclosing span ID; null for the qualification root and identities |
| `operation` | Fixed function name; `full-release` for the root; `verified-identity` for an identity |
| `category` | Category from the table, `qualification`, or `identity` |

`start` events contain `details`, which is empty except for allowlisted native
tool/action labels. `end` and `failure` contain `durationSeconds` plus
`digestTotals`, a fixed-kind map of `{calls, failedCalls, bytes, elapsedSeconds}`.

`identity` events contain `details` with `kind`, `sha256`, `sizeBytes`, and an
optional version. The kinds are `qemu-system`, `qemu-img`, `source-image`, and
`prepared-base`. The two actual QEMU binaries receive explicit SHA-256 readings
after the original verified bootstrap. The source and prepared-base digests come
from the results just validated by the original acquisition/base checks; large
images are not hashed again solely to publish the identity. These extra binary
identity reads are themselves included in the root hash counters.

## Interpretation and failure semantics

Durations are **inclusive**. READY and base-build intervals contain their nested
hashing/validation/process intervals. Do not sum overlapping category totals as
though they were disjoint wall time. Use parent IDs to choose disjoint intervals,
or the qualification root's aggregate hash counters for whole-session totals.
Timings include observer overhead and do not establish a machine-speed comparison.
The observer starts after the initial source-only fixture copy/module import;
the external controller's wall clock must cover the entire attempt and cleanup.

A `failure` event means the observed function threw. Expected negative controls
also throw, so nested failure events can belong to a successful original scenario.
A process returning nonzero without `ThrowOnError` still produces an `end` event;
the unchanged calling assertion interprets that process result. Neither event
type is independently a PASS verdict. The `full-release` root ends only after the
original cleanup/restoration attempts. The caller must also reject the original
cleanup/restore error markers because those errors are caught by the harness.

The output must be an absolute fresh file under an existing directory without
reparse-point ancestors. `CreateNew` refuses overwriting earlier evidence. Output
is bounded to 8 MiB. Writer errors, broken nesting or size exhaustion latch an
incomplete-evidence state and refuse subsequent observed work. An observer failure
must not replace an already propagating original terminating error; the latch
still prevents a later complete observed result. Truncated evidence, missing root
termination, a failed exit or an incomplete original marker set cannot qualify.

## Retained regression coverage

`tests/QualificationTelemetry.Tests.ps1` runs in the ordinary first-party suite.
It checks module default roots and object identity, bound arguments, nested spans
and repeated hashing without event floods, error propagation and prior output,
actual lightweight native-process results/nonzero exits, writer-failure latching,
fresh-file/byte bounds, and observer rebinding to a different module root.
These tests do not execute QEMU or claim Windows/WHPX qualification.

On a base-build failure the full harness also writes bounded tails of the exact
owned `.build-<32-hex-ID>/failure.json` and `serial.log` files to its private
diagnostic output before the supervisor removes the mutable fixture. At most four
stages, a 256-KiB byte tail per file, 200 lines and 4,096 characters per line are
retained. All ancestors must be regular paths and log files must have a single
link. Each copied line has a `BASE_LOG_LINE=` prefix so guest prose cannot enter
the host completion-marker oracle. Seed data, disks and key files are excluded.
Serial text remains diagnostic only and is not
included in public qualification receipts or used to override a failed exit.
