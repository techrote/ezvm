# DASH-02 release runtime preparation evidence

Recorded **2026-10-18**. The controlled Windows preflight passed. The replacement
complete release qualification is **pending**; this record does not establish a
release PASS, physical WHPX acceptance or permission to restart TRIO.
Subsequent exact-candidate and accepted-main results belong on
[live issue #28](https://github.com/techrote/ezvm/issues/28); this dated record
preserves the preparation decision and its evidence.

## Cancelled complete release attempt

[Release run 39022570303, job 117367136257](https://github.com/techrote/ezvm/actions/runs/39022570303/job/117367136257)
tested commit `24ca91a430b478f01c31118acf1c9ea019acd8b9`, tree
`4a08ea55ecce1a0cde55265bb086117d6f16828a`, on `windows-2022` using Windows
PowerShell `5.1.20348.5622` and explicit TCG. Its conclusion is **cancelled**.
The qualification step ran from 2026-10-17 09:49:33 UTC to 12:49:56 UTC, about
180 minutes 23 seconds. This is consistent with the 180-minute containment
timeout; the log does not identify the cancellation actor or exact interrupted
statement.

The log records all **eight authenticated READY events**: source, concurrent
secondary, source restart, fresh clone, reset source, stateful clone, imported
guest and relocated stateful guest. Each subsequent timer probe passed with
`hpet` and advancing uptime. The prepared-base build took about 792 seconds;
all logged launch-to-READY intervals were below 900 seconds. The tiny real-image
suite, which does not boot guests, consumed about 39 minutes 27 seconds. These
measurements motivated checking host control-plane overhead before another full
attempt.

Relocated doctor passed at 12:29:33 UTC; the final relocated READY was recorded
at 12:43:08 UTC and its timer probe passed at 12:43:15 UTC. The log then records
source-root restoration during cleanup and cancellation. It contains none of
the required trailing PASS markers below, nor the final completion timestamp
and exported-image digest. Earlier successes therefore remain partial evidence.

```text
EZVM010_REAL_COLD_RELOCATION_READY
EZVM010_REAL_RELATIVE_BACKING_AND_RUNTIME_REGENERATION
EZVM010_REAL_GRACEFUL_STOP
EZVM011_REAL_COMPLETE_SECURITY_AND_PORTABILITY
EZVM012_REAL_RELOCATED_DOCTOR_AND_RESTART
EZVM012_REAL_COMPLETE_END_TO_END
```

## Controlled preflight identity and retained receipts

[Diagnostic run 39085865423, job 117552170393](https://github.com/techrote/ezvm/actions/runs/39085865423/job/117552170393)
completed successfully on the isolated push-only `ezvm-028-sha-preflight` branch.
It ran no QEMU executable or guest and did not trigger the full release scenario.

| Identity | Value |
| --- | --- |
| Diagnostic commit | `337da8870ff7af12704a5b1a61c22cf2ea158df4` |
| Diagnostic tree | `276bb88b5d367c4dcf85c3007abca96f0c7b9c97` |
| Artifact ID | `12121131075` |
| Benchmark script SHA-256 | `6af8d14e244f78cde65a98fa9c6062acaaf1996b3768e563972283fcdace88d8` |

The [published benchmark script](https://github.com/techrote/ezvm/blob/337da8870ff7af12704a5b1a61c22cf2ea158df4/scripts/Measure-EzVmHashProviders.ps1)
checks the clean source commit/tree and every module file hash before and after
execution. The two JSON files below are exact copies of the downloaded artifact's
`ps51/receipt.json` and `ps7/receipt.json`, preserving their original bytes.
Two exact-path `.gitattributes` entries preserve these receipts' CRLF bytes;
ordinary repository source retains its existing LF normalization.
The artifact archive is identified separately; it is not a new test result.

| Retained receipt or downloaded archive | Bytes | SHA-256 |
| --- | ---: | --- |
| [337da887-sha-preflight-ps51.json](337da887-sha-preflight-ps51.json) | 39,316 | `e0e788c11a6619784ac9477b479cb4b39086a0ca1dd3d19895b7f535ee206207` |
| [337da887-sha-preflight-ps7.json](337da887-sha-preflight-ps7.json) | 23,984 | `2b92d5ae2c9929a528f980322778111e29e4d5f1dff2c05dfc614ca2e2ab0863` |
| Downloaded `hosted-results.zip` | 8,514 | `430728e32d660d000c4137d6d5e4efe6709853d22b685682b38c23a4d0f92e86` |

## Measurements and rejected hash-provider hypothesis

Both engines ran sequentially in the same hosted Windows job: Windows NT
10.0.20348.0, four logical processors, AMD EPYC 7763, 64-bit processes. The
engines were Desktop `5.1.20348.5622` / CLR `4.0.30319.42000` and the existing
pinned Core `7.6.6` / CLR `10.0.12`.

The legacy factory was `HashAlgorithm.Create($Algorithm)`. The candidate used
`SHA256Cng` / `SHA512Cng` on Windows Desktop and parameterless `SHA256.Create()` /
`SHA512.Create()` on Core. Only that factory expression changed in an owned
temporary module copy. The production `Assert-EzVmQemuPayloadIntegrity` validator
was byte-identical between variants. Its SHA-256 was
`116066239f090bb68a1856c2747dce88b577a293b34f3d2078ffc3f3a9b28c47`;
the original `Download.ps1` SHA-256 was
`b2fe8282bb575115a86b387d578c36f8056675213a4c1c5d2b968f99e6271194`.

Each comparison used four measured trials per variant after a recorded warmup,
in seeded, balanced AB/BA order. File trials opened an ordinary uncompressed,
nonsparse 128 MiB file with the production read/share semantics, required a full
read and checked independently calculated SHA256/SHA512 digests. The synthetic
QEMU inventory contained that file, 1,000 files of 4 KiB and three 4 KiB tool or
dependency placeholders: 1,004 files and 138,326,016 bytes.

| Median wall time, milliseconds | PS 5.1 legacy | PS 5.1 CNG | PS 7 legacy | PS 7 candidate |
| --- | ---: | ---: | ---: | ---: |
| 128 MiB SHA256 | 150.54 | 150.92 | 160.87 | 154.72 |
| 128 MiB SHA512 | 322.93 | 322.53 | 325.58 | 332.33 |
| Complete synthetic payload validator | 4,561.46 | 4,610.28 | 1,742.64 | 1,762.44 |

**The CNG optimization hypothesis was rejected:** it delivered no useful Windows
PowerShell 5.1 improvement. The production hash factory remains unchanged.
The recorded legacy types were `SHA256Managed` / `SHA512Managed`; FIPS policy
and any inner provider were not measured, so their role cannot be inferred.
The unchanged validator's PS 7 median was about **2.62 times faster** on this
fixture. Similar direct byte-hash times suggest surrounding runtime/control-plane
work is relevant; this experiment does not attribute the gap to an exact function.

Both variants in both engines rejected a same-size payload mutation with its
original timestamp restored after a successful scan, then accepted the restored
bytes. Each passed the seven unchanged download tests and four algorithm-case
checks, with zero failures or skips. Both receipts report unchanged source,
fixture cleanup and exit zero. No validation cache was introduced. OS file
caches were not flushed, engine order was sequential, and the timed validator
excluded module import. This synthetic result does not predict complete guest,
disk, relocation or release duration.

## Chosen preparation and remaining gate

The complete release harness now explicitly invokes the existing official
PowerShell 7 pin in [tests/tooling.json](../../../../tests/tooling.json), installed
under `RUNNER_TEMP` by
[Install-TestPowerShell.ps1](../../../../scripts/Install-TestPowerShell.ps1) with
the existing size and SHA-256 checks. The workflow verifies and records the
actual `Core/7.6.6` executable before invoking the full portability/security/release
scenario. This narrows the change to the harness runtime; public PowerShell 5.1
support and both Windows core/standard-user ACL test lanes remain required.

All existing QEMU work, integrity checks and acceptance assertions remain. The
2400-second base-build, 900-second READY, 90-second guest-venv probe and 180-minute
job bounds remain unchanged, as do explicit TCG/WHPX reporting and the existing
branch-scoped CI-PoC deferral. DASH-02 receives no such deferral. The next complete
run must independently finish and emit every required final PASS marker. Until
then, complete release qualification remains pending and TRIO remains paused.
