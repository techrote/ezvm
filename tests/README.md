# Tests and repository checks

The EZVM-001 foundation can be tested without QEMU, a guest image, WHPX or a
system-wide VM installation. Git is required for repository-contract tests.

## Run the checks

From the repository root, run both checks under Windows PowerShell 5.1:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\scripts\Test-Repository.ps1
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
```

Repeat the suite under current PowerShell 7:

```powershell
pwsh.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
```

The execution-policy option applies to that process; it does not change the
machine's stored policy. A repository check examines tracked files, so add new
source files to the Git index before using it to validate a proposed change.

The suite prints individual `PASS`, `FAIL` and explicit `SKIP` lines, then totals.
A failed assertion, discovery failure, zero discovered tests or all-skipped suite
terminates non-zero. Failures are never automatically converted to skips.

## Test ownership

| File | Behavior covered |
| --- | --- |
| `Cli.Tests.ps1` | Human/JSON help and version, empty input, malformed/unknown commands, actual child-process exit codes, JSON pipelines, raw `-File` output without a test prelude, incomplete checkouts and copied roots with spaces and brackets. |
| `Configuration.Tests.ps1` | Published defaults, nested runtime overrides, source preservation, fresh return values, schema/type/range/unknown-field refusal and dictionary-member shadowing. |
| `Paths.Tests.ps1` | Source-derived roots, unrelated working directories, complete derived layout, no discovery side effects, relative roots and cold relocation without Git metadata. |
| `Json.Tests.ps1` | UTF-8 data and timestamp round-trips, schema refusal, serialization limits, byte-preserving failed writes, failed replacement cleanup and Windows file locks. |
| `Process.Tests.ps1` | Native argument tokens, UTF-8 stdout/stderr, exact non-zero exit propagation, concurrent pipe draining, zero-byte stdin, console encoding/reader preservation, redirected callers, working directories, launch failures and bounded timeouts. |
| `Repository.Tests.ps1` | Positive and negative isolated Git fixtures for the repository guard, CRLF normalization with real whitespace-error detection, plus proof that an empty/failed harness exits non-zero. |
| `fixtures/NativeArguments.cs` | Source-only Windows argv reporter and raw stdin byte counter, compiled into a temporary directory by the Windows .NET Framework compiler. |
| `fixtures/ProcessFixture.ps1` | Deterministic lightweight child behavior for process-boundary tests. |

Fixtures are created beneath unique `ezvm tests ...` directories in the operating
system's temporary area and removed in `finally` blocks. Negative repository tests
force-add synthetic artifacts only to their own temporary Git repositories. No
test changes the working checkout's Git index or writes a real disk image/key.

The checked-in `.gitattributes` keeps source text normalized to LF. Fixture Git
configuration permits intended CRLF-to-LF conversion; it does not disable
whitespace checks. A regression materializes actual CRLF source bytes, confirms
the index holds LF, and proves a real space before a CRLF newline still fails.
The encoded-command test wrapper suppresses its own module-autoload progress;
an independent raw `-File` child verifies the application's JSON output without
inheriting that test prelude. Stderr is always checked without filtering.

On a non-Windows host, file-lock replacement, native Windows argument parsing and
the native raw-byte stdin check are three explicit capability skips. The stdin
check uses a BOM-bearing parent console encoding, verifies zero bytes reach the
child, preserves the caller's encoding and buffered input reader after successful
and failed launches, and exercises a redirected caller without a console window.
Such a local run is additional evidence; all three checks must execute on Windows
before acceptance. The foundation declares no
QEMU/guest/WHPX execution success, because those implementations belong to later
issues.

## Versioned test tooling

`TestHarness.ps1` is the first-party harness, version **1.0.0**, pinned by the same
repository commit as the implementation. `tooling.json` records that version and
declares no external harness package dependency. No Pester module or unbounded
package feed is needed.

GitHub Actions executes three independent checks on `windows-2022`:

| Check | Actual test engine |
| --- | --- |
| Repository contract | Windows PowerShell 5.1 |
| Control plane | Windows PowerShell 5.1 |
| Control plane | Pinned PowerShell 7.6.6 |

`scripts/Invoke-CiCheck.ps1` verifies the executing engine's version before running
its check. Both suite lanes include positive and negative repository fixtures.
The standalone repository lane checks the actual tracked checkout, including any
force-added runtime artifact outside the fixture source directories.

The PowerShell 7 lane downloads the official portable Windows x64 ZIP to
`RUNNER_TEMP`, checks its expected length and SHA-256 **before extraction or
execution**, and invokes its explicit `pwsh.exe` path. It does not run an
installer, alter `PATH`, or rely on the runner's bundled PowerShell 7 version.
Downloads have three attempts with a 60-second timeout per attempt. The entire
job has a ten-minute limit.

The current runtime pin in `tooling.json` is:

- Version: `7.6.6`.
- [Official Windows x64 ZIP](https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/PowerShell-7.6.6-win-x64.zip).
- Expected size: `106328873` bytes.
- SHA-256: `02fe458be20493fbdf43f61ea20610b811ee6c738ab1676c61b9cfcd1a33c860`.

To update the pin, verify the exact asset and digest from an official
[PowerShell release](https://github.com/PowerShell/PowerShell/releases), update
`tooling.json` and the workflow label together, then run both Windows lanes.
Timestamp-preserving JSON reads use `DateKind String` on PowerShell 7.5+; older
PowerShell 7 must not replace the pinned current lane.

Checkout uses `actions/checkout` v4.2.2, pinned to verified upstream commit
`11bd71901bbe5b1630ceea73d27597364c9af683`. Workflow permissions are `contents: read`,
checkout credentials are not persisted, and no QEMU or Ubuntu artifact is fetched.

## Repository guard

`scripts/RepositoryContract.psm1` validates the complete NUL-delimited Git-tracked
file list, independently of `.gitignore`. It requires all authority/RAG and
foundation files to be tracked and present, and verifies each EZVM-001 through
EZVM-012 catalogue row links to its correct issue exactly once.

The guard rejects generated runtime/cache/artifact/test-output directories even
when nested or differently cased; VM disks, installers, archives, binary libraries
and secret-like filenames; private-key headers hidden in ordinary text; common
executable/archive/disk signatures; binary NUL content; symbolic links; and source
files larger than 5 MiB. The size limit keeps this control-plane repository small;
a future legitimate large source asset requires a deliberate contract change.

Every tracked JSON file must parse, and every tracked `.ps1`, `.psm1` and `.psd1`
file is parsed by the executing PowerShell engine. Current committed changes,
staged changes and unstaged changes retain Git whitespace-error checks. A new
temporary repository with no commit still receives staged and working-tree checks.

## Add a test

Add a `*.Tests.ps1` file next to the existing suites and register named cases:

```powershell
Add-EzVmTest -Name 'Subsystem: observable behavior' -ScriptBlock {
    Assert-EzVmEqual -Actual (Some-Operation) -Expected 'expected value'
    Assert-EzVmThrows -ScriptBlock { Invalid-Operation } -MessagePattern 'remediation'
}
```

The harness provides `Assert-EzVmTrue`, `Assert-EzVmEqual` (scalar/array values),
`Assert-EzVmThrows`, temporary directory/checkout helpers and an independent
PowerShell child-process helper. Use `-Data` to pass table-driven case data to a
test's `param($case)`. Use `-SkipReason` only for an explicit unavailable platform
capability; assertions and errors must remain failures. Keep the harness source
version and `tooling.json` coherent when changing harness behavior.
## EZVM-005 storage tests

`Storage.Tests.ps1` owns deterministic thin-overlay, backing-chain, relocation,
lifecycle-guard, integrity-check and reset-safety coverage. The separate
`EZVM-005 real qemu-img qualification` Actions workflow bootstraps the reviewed
portable QEMU runtime and exercises the same storage boundary with tiny generated
QCOW2 images. These disk fixtures exist only in ignored runner/temp storage and
are never committed.

## EZVM-006 runtime tests

`Runtime.Tests.ps1` owns deterministic lifecycle, process-identity, QEMU argv,
QMP orchestration, timeout and locking coverage. `Cli.Tests.ps1` covers the
public status/start/stop parsing and absent/error behavior.

The `EZVM-006 real QMP qualification` workflow bootstraps the reviewed Windows
QEMU runtime and exercises the actual host management/process-observation boundary
under explicit TCG. It does not claim WHPX execution on a hosted runner.


### EZVM-007 SSH/network tests

`Ssh.Tests.ps1` owns localhost-only SSH/NoCloud QEMU argv, controller public-key
seed generation, scoped host trust, remote argv/scp path construction, readiness
identity/cloud-init/marker validation, bounded timeout, remote exit-code
propagation, configured-range collision handling and missing OpenSSH diagnostics.
The existing `SeedServer.Tests.ps1` remains authoritative for loopback binding,
method/path rejection and bounded NoCloud HTTP behavior.

## EZVM-009 coding-profile tests

`Profiles.Tests.ps1` covers the strict `coding-default` version 1 manifest,
required commands, manifest/recipe source digest, normalized line endings,
credential/placeholder rejection and generated coding-profile seed content.
`CodingReadiness.Tests.ps1` exercises complete version 2 identity/ready evidence,
completion state, unsupported/mismatched profiles and versions, missing required
tools and stale READY/trust refusal. Existing SSH, registry and runtime suites
also exercise the updated state and legacy-profile boundaries.

The `EZVM-009 real coding-profile qualification` workflow runs the reviewed
Windows QEMU under explicit TCG. Its
`Real coding-default profile (Windows TCG; WHPX SKIP)` job uses
`scripts/Invoke-EzVm009RealProfile.ps1` to exercise actual Ubuntu first boot,
versioned coding readiness, coder/password/sudo/SSH policy, workspace ownership,
Python venv/pip and compiler use. Repeated provisioning and stop/restart must
preserve a synthetic workspace sentinel. Temporarily removing ripgrep must
invalidate readiness without changing managed SSH trust; restoration must
allow verified recovery and graceful stop.

This lane keeps the accepted 2400-second base-build and 900-second per-launch
readiness bounds, within a 90-minute workflow limit for the full scenario. It
does not claim WHPX execution or commercial-agent authentication. Its result and
tested commit must be recorded as separate acceptance evidence; source fixtures
and workflow configuration alone are not a guest integration PASS.
