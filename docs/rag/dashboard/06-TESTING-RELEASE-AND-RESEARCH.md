# Dashboard RAG 06 — Tests, release gates and research feedback

Status: test contract for the [dashboard issue series](../../programme/dashboard/README.md).
The existing [EzVM test/release contract](../08-TESTING-CI-RELEASE.md) remains binding.
A plan is not permission to execute destructive or live-worker tests on paused TRIO.

## Evidence layers

1. Pure/synthetic fixtures: identities, normalization, task/state transitions,
   budgets, admission, view geometry and config migration. No VM/GPU/account needed.
2. Process/adapter tests: stubbed endpoints, read-only SQLite snapshots, actual
   prompt_toolkit parser/input, filesystem/process argument boundaries and crashes
   inside disposable harnesses. Assert calls/writes, not only rendered strings.
3. Qualified integration: real Windows Terminal; dedicated disposable QEMU/WHPX
   instance where authorized; exact local/free model/runtime and clean devbox.
   Record capability SKIP honestly. TCG, dummy output and replay are separate evidence.

Baseline commands exist today:

```powershell
.\scripts\Test-DashboardPlan.ps1
& .\runtime\dashboard\venv\Scripts\python.exe -X utf8 -m unittest discover -s dashboard\tests -v
.\scripts\Test-Repository.ps1 -Root (Get-Location).Path
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
```

The first command is the issue-series integrity check. Future cases in issue bodies
are test requirements, not a claim those suites already exist. New setup/CI is
DASH-13 work. No dependency installation is required to validate this plan.

## Required evidence record

For every acceptance case retain: case ID, PASS/FAIL/SKIP/reason, source commit and
tested-tree identity, command/harness revision, source import assertions where
relevant, exit, start/end, artifact hashes and actual executing environment.
An expected negative test records both the refusal and unchanged target state.
A script that prints PASS but returns nonzero is failed evidence.

Issue closure needs the scoped implementation, required positive/negative tests,
review, docs/contract alignment and verification at the resulting accepted revision.
Never mark an issue done from a launch, idle API, pass count or uncommitted report.
Carry project verification budgets; do not import TRIO's numeric limit as an EzVM default.
Do not repeat unchanged green heavy tests just to repair prose.

## Release gates and performance

DASH-11 first establishes crash/replay/performance harnesses and the read-only gate.
DASH-05 through DASH-10 then extend that harness at each mutation boundary; testing
is not deferred to a final checklist. DASH-13 supplies reproducible dependency and
packaging/CI mechanics; it does not bypass the existing dirty-tree release guard.

Measure 80x24, 120x40 and 160x48, plus resize/collapse. Target p95 input response
under 100ms during a 10-second failed source. Declare measured dispatch versus
physical paint. First proposed idle budget is <=1% of one logical core and <200MiB
combined UI/long-lived collectors on the reference host; account separately for
short-lived children and guest collectors. The prototype measured 3.33% for its
Python process alone, so this CPU target is **not yet met**. Optimize or explicitly
revise it with measured tradeoffs; never change the denominator silently.

Test output flooding, >1,000 historical sessions, slow endpoints, partial status,
multiple registered roots and repeat open/close. Bound memory, polls, backfill and
artifact retention. Host CPU/RAM, guest CPU/RAM and inference load are separate.
An active-workload result must not be invented by resuming paused TRIO.

## Packaging and migrations

Pin interpreter/tool/dependency artifacts and hashes appropriate to the supported
Windows x64 environment; include licenses. The optional dashboard must not make the
core CLI require Python. Test clean source checkout and source/package launch without
developer paths, spaces/Unicode paths, offline runtime after setup, bad hashes, missing
dependencies and schema migration interruption. No runtime databases, secrets, VM disks,
model weights or raw session logs are shipped in source packages.

Observe -> controlled workflow -> provisioning/devbox are separate release gates.
Unsupported capabilities stay disabled. A restored controller/capsule starts held
until reconciliation and explicit resume; rollback preserves evidence and pause.

## Research loop

Use stable TRIO-FR IDs and the [existing register](../../research/TRIO-2026-10/README.md).
Link observation -> issue -> fixture -> implementation revision -> retest. Preserve
original evidence and append corrections; a hypothesis is not a confirmed defect.
Distinguish model quality, provider transport, harness error and orchestration failure.

Add concise ADRs for toolkit, event/journal design, attach mode and packaging choices.
Decision files record alternatives, measured reasons, consequences and revisit trigger.
Public research is redacted/reviewed; raw prompts/reasoning, account data and full DBs
remain private. Export previews enumerate content and hashes; no telemetry upload.
One field test can motivate an issue without proving a universal model ranking.
