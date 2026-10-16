# Proposed delivery slices and decision gates

Status: local issue drafts, **not GitHub issues and not scheduled work**. IDs `DASH-*`
are stable planning identifiers, not allocations in the EZVM implementation programme.
Use [the proposal](VM-AI-DASHBOARD.md), [contracts](VM-AI-DASHBOARD-CONTRACTS.md) and
[research register](../research/TRIO-2026-10/README.md) together.

Implementation checkpoint, 16 October 2026: the [read-only companion](../DASHBOARD.md)
now covers a first subset of DASH-02/03/04, with synthetic fixtures for DASH-01.
This does not close these broader slices. In particular, exhaustive active-worker
discovery, saved layouts, physical Windows Terminal input-latency qualification,
provider rate/quota history and the full replay corpus remain outstanding.
See [the verification record](../DASHBOARD-VERIFICATION.md) rather than treating
this draft's acceptance list as a claim that every item has passed.

## Sequence

```text
DASH-01 evidence/fixtures ── DASH-02 read adapters ── DASH-03 tiled read-only UI
                                  │                          │
                                  └── DASH-04 metrics ───────┘
                                             │
                                  DASH-05 command journal/pause
                                             │
                                  DASH-06 review/rework queues
                                             │
                                  DASH-07 availability/automation

DASH-08 lifecycle hardening ── DASH-09 provisioning ── DASH-10 clean demo profile
             ↑                    ↑                        ↑
       DASH-01 evidence       DASH-05 controls         read-only UI + queues

DASH-11 restart/recovery qualification applies across the controlled releases.
DASH-12 embedded terminal spike is optional; exact attach works first.
```

### DASH-01 — Research ledger and replay corpus

Priority P0; no live inference dependency. Seed observations from TRIO with exact source
identities and explicit confidence. Extract small redacted fixtures for idle/stream/tool/retry,
quota, stale status, false-success prose, source mismatch and paused restart.

Acceptance: every proposed slice traces to observations; fixtures are labelled synthetic or
recorded with capture metadata; no keys/whole DB/raw reasoning are published. Replaying
fixtures cannot invoke a command. Done means usable corpus, not all field findings resolved.

### DASH-02 — Adapter and identity spike

P0, depends01. Read EzVM instance state, one scoped guest OpenCode server and the local
engine adapter(s). Enrol sources explicitly. Sample real endpoint schemas/version into private
evidence. Define stable IDs, capabilities, freshness and unknown states.

Acceptance: multiple endpoints exposing one session are deduplicated; timeout is unknown;
read-only collection cannot call mutation routes; slow source does not block others;
scope/import identities resolve. Log resource overhead. No worker launch required.

### DASH-03 — mdbm-style terminal workspace

P0, depends02. Prototype prompt_toolkit and compare a narrowly scoped Textual version only
if the first fails required interactions. Implement inventory/activity/metrics/attention panes,
tile controls, palette, resize and focus recovery. Confirm toolkit choice in a short ADR.

Acceptance: real Windows Terminal mouse/keyboard checks at80×24/120×40/160×48; click actions
work after focus change; no modal click-through; Escape cancels split preview; hide/restore
retains state; bounded transcript survives large output and missing collector. Report p95
input latency and idle CPU/RAM. UI exit never aborts VM/workers.

### DASH-04 — Common usage and performance ledger

P0, depends02, can proceed with03. Implement normalisation/provenance/coverage, engine and
provider panels, context/request history and source-specific counters. Prefer adapter API;
version-pinned DB reader is optional fallback.

Acceptance: fixture totals reproduce known message ledger exactly; duplicate servers/events
do not inflate counts; corrected final usage updates rather than doubles; overlapping
reasoning/output is handled; unknown values stay unknown; same engine/API request is not
double-counted. Rate charts label windows and dispatch vs arrival. Surface quota separately.

**Read-only release gate:**01–04 accepted plus bounded overhead and replay tests. This is
already useful and should ship before task automation or embedded full-screen terminals.

### DASH-05 — Durable controls and pause semantics

P0 for any mutation, depends02–04. Add typed action journal, ownership/revision checks,
single controller, admission leases and pause/drain/interrupt/resume/steer controls.

Acceptance: crash/retry cannot duplicate a prompt or worker through blind replay; unknown
dispatch is held for reconciliation; programme pause survives quota reset and host/controller
restart; interrupted tools remain visible until stopped; external sessions cannot be aborted.
Use adapters with real capability tests, not generic OS suspension. No paid fallback.

### DASH-06 — Independent review and rework queue

P1, depends05. DAG of bounded tasks, candidate freezing, review policy, finding-based rework,
source roots, evidence gates, budget ledger and preserved provenance. Simple controls first.

Acceptance: “queue review” creates a reproducible reviewer input; author change invalidates
the old verdict; correct report and tested tree are required; full incoming histories/unique
contributors survive integration; same-model/different-model reviews are distinguished;
no acceptance from tokens/idle/prose/counts. Dry-run all actions and reserve project postgate.

### DASH-07 — Capacity, model preferences and automations

P1, depends05–06. Shared provider pools, local-runtime leases, free-only policies, roles,
fallbacks, quiet hours, context limits, cooldowns and bounded automation templates.

Acceptance: at most configured workers globally across registered sources; all retries pass
admission; unknown capacity fails closed; disabled or expired model is explained; local device
UUID/load config is verified before inference; useful work is not reloaded away. Automation
has dry-run, dedup, expiry and run history and cannot override owner pause or spend policy.

### DASH-08 — EzVM lifecycle integration prerequisites

P0 before managed starts or “one click”, depends01. Triage recorded standard-user ACL,
WHPX/first-boot, CPU-feature, SSH selection, start-pipe, timeout and stale-recovery findings
against current source and the owner's patches. These are historical reports, not freshly
reproduced defects. Separate operational UX fixes from any security-boundary investigation.

Acceptance: bounded public start result with detached lifetime; separate readiness/tool/stop
budgets; truthful readiness/recovery/error reasons; actual Windows standard-user/WHPX checks
and explicit unsupported cases; repository tests and postmerge verification. No blanket
approval to edit owner patches or perform isolation probes is supplied by this plan.

### DASH-09 — Previewable provisioning changes

P1, depends05+08. Underlying CLI/API first, UI second: stopped-only CPU/RAM and disk growth,
consistent identity/readiness migration, host headroom and recovery journal.

Acceptance: requested/effective/guest-observed values agree; running/ambiguous state refuses;
each growth stage can recover; backing base untouched; no automatic shrink; other VMs
unchanged. A rollback description distinguishes pre-growth restore from irreversible later
guest writes. Workers require explicit resume after readiness. Use dedicated fixture VMs.

### DASH-10 — Clean free/local demonstration devbox

P1 after08 and a usable UI/queue. Rebuild a reviewed profile from clean base plus pinned
tools/model manifest; provide guided first-run and one-click subsequent launch.

Acceptance: zero paid-service dependency in demonstrated path; no bundled accounts/tokens;
installation is resumable and hash-verified; source/license/size requirements displayed;
fresh machine test reaches one accepted small change with review/repair; free-quota failure
is explained and replay clearly labelled. Hardware tiers only after measured qualification.
Track download/time/intervention totals; publish exact supported versions and limitations.

### DASH-11 — Recovery, performance and field qualification

P0 release gate, spans02–10. Fault injection for disconnected guest/provider, killed UI,
controller crash, output flood, disk pressure and migrated hardware IDs. Reopen a restart
capsule without model calls first. Validate paused and active restoration separately.

Acceptance: no silent auto-resume, lost evidence, duplicate action or corrupted counter;
real Windows mouse/focus/resize/attach qualification; measured UI/collector budget;
source/test/report identities and postmerge gates recorded; research outcomes updated with
the exact tested revision. Do not substitute a release checklist for executable evidence.

### DASH-12 — Optional embedded terminal

P2; depends03+05. Investigate bounded PTY rendering, Unicode/control-sequence handling,
resize, copy and input ownership. This must earn its complexity over exact external attach.

Acceptance: a full-screen child can be entered/exited without losing dashboard focus or
terminal mode; one input owner; no replayed side-effect escapes; output and memory bounded;
closing the pane leaves the intended session alive. Otherwise retain attach-only approach.

## Scope and initial decision

Recommended next authorised implementation is01–04, beginning with recorded fixtures and
a read-only Windows TUI spike. Keep resource mutations and automatic workflow execution
behind their own acceptance gates. No estimate is promised before API/terminal spikes.

Do not schedule these slices or resume TRIO from this document. When selected for execution,
reconcile current main/issues/PRs, create real EzVM issues with source references and test
criteria, then follow AGENTS.md. Preserve current owner source patches and avoid mixing them
into a dashboard change. Create separate accepted contract updates when APIs actually change.
