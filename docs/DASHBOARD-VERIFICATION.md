# Read-only dashboard verification — 16 October 2026

Build: `0.1.0-alpha.1`, local branch `ezvm-dashboard-readonly`, Windows x64,
Python 3.12.10, public launcher tested with Windows PowerShell 5.1.26100.9444.
The host's existing `trio-lab` VM and idle local engines were observation sources.
No worker, VM or inference workload was launched for this dashboard exercise.

## Automated and process checks

- **25/25 dashboard tests passed.** Includes actual prompt_toolkit keyboard and
  SGR mouse sequences through Windows pipe input; one-click selection after focus
  change; divider commit/cancel; modal click-through prevention; per-tile wheel;
  hide/reveal; selected-row scrolling; Unicode cell clipping; small terminal layouts;
  SQLite snapshot identity/deduplication and no fixture-file mutations; missing,
  partial-failure and stale telemetry; single in-flight reads; HTTP GET allowlists;
  redirect rejection; configuration and stale READY metadata refusal.
- **PowerShell 5.1 repository contract passed**, including the newly staged sources,
  JSON and PowerShell launch/setup scripts. `git diff --check` passed.
- **Existing PowerShell 5.1 control-plane suite: 346 passed, 1 failed, 0 skipped.**
  The deterministic release-package test refused the modified tracked working tree,
  as its release guard requires. Both pre-existing owner source patches remain
  untouched; no release package or clean-tree PASS is claimed. The dashboard has
  not changed the release guard to hide this failure.
- **Live PowerShell launcher `-Once` passed**, collecting real host, guest, scoped
  OpenCode and local-engine data. `-Json` produced the versioned observation snapshot.
- A single interactive dashboard was launched in Windows Terminal. Its Python
  process remained live while collecting. Automated input tests use a pipe and
  dummy output, not a physical mouse/screenshot inspection of Windows Terminal.
- **Input dispatch measurement:** 40 synthetic focus changes through Win32 pipe
  input: median 0.40ms, p95 1.03ms. This measures dispatch to UI state change, not
  physical screen paint or human input latency; it is not full DASH-03 qualification.
- **Live viewer overhead:** over 67.6 seconds, its Python process averaged 3.33% of
  one logical CPU core and ended at 55.1MiB working set / 43.0MiB private memory.
  This excludes short-lived SSH and nvidia-smi children and is one paused-workload
  sample, not a full-host overhead or active-worker scalability measurement.

Layout tests exercised 80×24, 120×40, 160×48 and 40×12. Physical terminal mouse
qualification at each of those sizes remains **not performed**. No claim of remote
CI, packaged release qualification, other OS support, live provider-generation
testing, or full future DASH acceptance is made.

## Live observations and pause boundary

At the 16 October live check:

- Guest policy `owner_paused=true`, registered actors `[]`; continuation remained
  paused. There were 238 enrolled historical sessions, with 60 displayed by the
  installed configuration. Eight scoped roots across four existing ports were read
  with zero failed status requests; no sampled worker was busy. Older unsampled roots
  remain explicitly unobserved.
- Guest allocation: 8 vCPU / 16,384MiB; observed guest filesystem about 61.0GiB,
  45.6GiB free. Allocation was displayed, not modified.
- Strata remained idle at **220 runtime requests / 163,444 output tokens** across
  the live checks. The viewer issues no inference requests. GPU power limits,
  model placement and VM allocations were not changed.
- Existing owner changes in `Keys.ps1` and `Runtime.ps1` retained their prior SHA256
  identities (`3f1c78f7…510c5` and `28c7dd33…f7bb`). They are outside this change.

Private validation artifacts are under ignored `runtime/dashboard/`:
`dashboard-tests.log`, `control-plane-tests.log`, `live-observation.json`,
`input-performance.json` and process observations. They may contain local project
paths/output and are intentionally not committed as public fixtures.

## Remaining limits

This is a working read-only prototype. Activity is a bounded stored transcript,
not terminal attachment. Status discovery is scoped, not exhaustive across every
old unenrolled session. Provider cost/quota and per-worker decode speed are unknown
where no source supplies them. State is retained while tiles are hidden, but layout
is not saved across restarts. Slow reads remain bounded and independent of UI input;
exit may wait for a read already in progress. Future orchestration/provisioning
controls require their own reviewed command path and are absent from this build.
