# VM & AI dashboard for EzVM

**Draft proposal, 16 October 2026.** The first [read-only prototype](../DASHBOARD.md)
now implements tiled observation. Worker control, resource mutation and new guest
profiles remain proposals. The TRIO programme remains paused. This describes an
optional post-v0.1 companion; it does not revise the
released [architecture](../rag/01-ARCHITECTURE.md) or [CLI contract](../rag/07-CLI-STATE-CONTRACT.md).

## Product direction

Future execution is specified by the [implementation/testing issues](../programme/dashboard/README.md)
and their linked [dashboard RAG contracts](../rag/README.md#dashboard-companion-target-contracts).
This document retains product rationale; the issue series supersedes the original
delivery sketch and does not imply proposed actions are implemented or authorized.

Give a person one terminal workspace for answering:

1. Which VM, workers and local engines are actually doing something?
2. What changed, what evidence exists, and what needs my attention?
3. What resources and provider allowances are available for the next task?
4. Can I pause, steer, request a review, or change capacity without losing the work?

The dashboard should make a small agentic development team understandable to someone who
does not want to manage many terminals, API endpoints and scripts. It should also support
the person investigating why that team is unreliable. Expert detail is available by
expansion; ordinary actions use task names and outcomes rather than endpoint jargon.

The field test is formative research on one Windows host and one project. Its incidents
justify capabilities and tests, not a universal model leaderboard. Follow the
[research register](../research/TRIO-2026-10/README.md) and
[delivery slices](VM-AI-DASHBOARD-DELIVERY.md) for evidence and proposed work.

## Starting recommendation

- An optional **host-side terminal application**, initially Python with prompt_toolkit as
  the leading candidate, around the existing PowerShell control plane.
- A read-only first release: VM/worker inventory, harmonised metrics, activity/results,
  evidence and recording. Next add durable queues and explicit worker controls; then
  provisioning and a reproducible demonstration profile.
- One collector per source and one command owner per managed scope. Opening a second view
  must not create a second inference actor or a second scheduler.
- Small prepared workflows: **Implement → independent review → rework → verify**. Provide
  editable queues before attempting a general visual workflow language.
- Separate **worker activity**, **task acceptance**, **engine state**, **provider availability**
  and **VM lifecycle**. Never turn an idle API or green test count into an accepted task.

### What exists today, and what is proposed

Inspected local EzVM source: `b6abdf8`, with the owner's existing Keys.ps1 and Runtime.ps1
patches. These were read and left untouched. No remote branch freshness is asserted.

| Area | Existing basis | Proposed addition |
|---|---|---|
| VM management | Versioned JSON CLI; instance intent; lifecycle/process identity; SSH/exec/copy; profiles | Responsive overview, action journal, lightweight observed-resource sampling |
| Resources | CPU/RAM selectable at create/import; immutable base and mutable overlay | Explicit reconfigure/grow workflows with requested/effective/guest-observed comparison |
| Workers | TRIO OpenCode session APIs, scoped worktrees, admission helpers | Versioned adapters, stable ownership, task-to-attempt registry, evidence gates |
| Metrics | Strata monitor; deduplicated OpenCode usage audit; NVIDIA dispatch ledger | Common metric vocabulary, source provenance, freshness, coverage and correlation |
| Terminal access | SSH, tmux, exact OpenCode attach commands | Bounded transcript panes and one attach view per selected session |
| Recovery | Git bundles, manifests, hashes and manually reconciled handoffs | Restart capsule and a generated operational summary from structured records |
| Devbox | coding-default v1 plus manually built field-test environment | Versioned clean agentic-demo profile and guided setup |

There is no current public resize/reconfigure command in the inspected CLI. Do not build
buttons that silently edit instance JSON. The reported captured-start pipe problem must
be addressed or explicitly contained before using captured `start -Json` for orchestration.

## Terminal workspace

Wide layout, illustrative only (no live telemetry):

```text
 EzVM   Workspace  VM  Workers  Queue  Evidence  Layout  Help        [PAUSED]
 Scope: demo-box / project-a     [Overview] [Metrics] [Workflow] [Resources]
 +-- VMs & workers --------+-- Selected worker / activity --------------------+
 | demo-box  READY        | builder-1   local / model + quant   [M] [S] [x] |
 |  builder-1  paused     | Task: repair release lifecycle  | Attempt 3      |
 |  reviewer-2 queued    | Activity | Terminal | Diff | Checks | Report      |
 | Engines               | > pytest ...       exit 0        source abc123   |
 |  local: loaded, idle  | Candidate saved; independent review still needed |
 | Providers             | [Attach] [Steer] [Queue review] [Pause options]   |
 |  cloud-a cooldown     +--------------------------------------------------+
 | Tasks                 | Metrics: selected / VM / all   range: last 15m  |
 |  review-7 waiting     | Tokens fresh/cache/output  rate+definition  age |
 +-----------------------+--------------------------------------------------+
 | Attention: review blocked on source change; cloud-a retries held          |
 +-------------------------------------------------------------------------+
 Ctrl+P commands   Tab focus   Ctrl+T restore tiles   F1 help   Esc back
```

Offer saved layouts: **Overview**, **Metrics**, **Workflow**, **Compare**, and **Resources**.
Overview has an inventory pane, selected-worker activity pane, and compact shared metrics.
Compare can tile two to four workers with one shared header, not four heavyweight native
OpenCode clients. Metrics can expand to all active workers/providers/engines with filters,
sorting and drill-down. Completed work remains searchable in history.

Borrow interaction conventions from [mdbm's workspace](https://github.com/techrote/mdbm)
and [product specification](https://github.com/techrote/mdbm/blob/main/docs/MDBM_PRODUCT_SPEC.md):
stable tile identities, hide/restore/swap, draggable dividers, Tab/Shift+Tab navigation,
Alt-number focus, Ctrl+P palette, Ctrl+T recovery, F10 menus, F1 help and Escape dismissal.
Retain pane scroll/filter state. Clicking an unfocused control should also act on it;
wheel scrolling belongs to its pane. Divider edits preview and can be cancelled. Modal
dismissal consumes the click. At small sizes show the focused pane instead of unusable tiles.

These are interaction inspirations, not a promise of complete mdbm compatibility or code
reuse. Start with restrained themes, visible focus, textual status labels and reduced
motion. Keyboard equivalents must exist for every mouse action. Minimum useful layouts:
80×24 focused view, 120×40 overview, 160×48 comparison; verify real Windows Terminal input.

### Activity, terminal and results

- **Activity** is a structured timeline: queued prompt, provider wait, available reasoning
  summary, tool command, exit code, source modification, commit, check and reviewer verdict.
  Preserve exact tool output behind expansion; never invent hidden reasoning.
- **Terminal** initially offers a sanitised bounded log view plus explicit attach to the
  exact session or a guest tmux pane. A transcript is labelled as such, not a terminal emulator.
  Live full-screen terminal embedding is a separate feasibility gate.
- **Results** show source/worktree identity, changed paths, check log links, exit status,
  test counts and the commit/tree that was tested. A report without a committed artifact is
  visibly incomplete. A green component is distinct from a green integrated issue.
- Scrollback stays put when the user reads older output; show new-line count and a Follow
  button. Search/copy must not replay terminal control sequences. Raw output remains an
  explicit local export; secret-bearing output is excluded from shareable reports.
- Interactive attach has an obvious input mode and an escape route back to the dashboard.
  Read-only views never forward keys, clicks or bracketed paste to workers. Closing a viewer
  does not abort a worker. Quitting the dashboard explains whether its controller continues.

## Harmonised metrics

Use a common presentation with provider-specific semantics retained. Every sample carries
source, scope, timestamp/age, unit, interval, observation method and quality:
`reported`, `measured`, `derived`, `estimated`, `unavailable` or `stale`.
Unknown values display `—`, never zero. Record requested, effective and observed settings
separately. An adapter capability table determines which controls and measures are available.

| View | Common fields | Important distinctions |
|---|---|---|
| Worker | Provider/model/runtime, task/role/root, state, elapsed, last tool/change, attempts, tokens, context, pending steering | API busy vs provider wait vs tool execution vs possible stall; elapsed is not inference time |
| Request | Admission/send/first token/end times, attempt ID, HTTP/finish reason, input/cache/output/reasoning, retries | Dispatch time is not provider arrival; errors may return no usage |
| Provider pool | Active/reserved slots, dispatch RPM, minimum gap, cooldown, retry count, quota if exposed | Configured allowance differs from measured use and provider-account limits |
| Local engine | Actual model + quant/file digest, context/KV mode, slots, queue, prefill/decode, cache/MTP, load mode | Workers sharing one model are not multiple model loads; requested resident can be effective mapped |
| Host/VM | CPU, RAM available/used, swap, disk capacity/free, host commit, GPU UUID/VRAM/temp/power | Guest load and host QEMU load have different denominators; inference GPU is host-side |
| Outcomes | Accepted tasks, failed checks, repair rounds, reviewer findings, human interventions, accepted-work time | Token throughput alone is not coding quality; failed transport is not a reasoning verdict |

Store raw provider usage beside a normalised representation. Map cached input, fresh input,
output and reasoning only when inclusion relationships are known. Reasoning can be included
inside output on one source and separate on another; a component sum is valid only for
disjoint categories. Keep provider-reported totals separate and flag discrepancies.

Deduplicate by stable origin and request/message IDs, not server port: several OpenCode
servers can expose the same database. Prefer API/event ingestion; a version-pinned read-only
database snapshot is an explicit fallback. Cumulative session totals are a cross-check, not
extra usage to add. Account for compaction and helper calls where visible. Missing failed or
cancelled request usage remains an uncovered quantity. Engine and OpenCode usage for the
same request must be linked or shown separately, never summed as two requests.

Rates are labelled: live decode window, completed-request decode mean, newly processed
prefill tokens/second, end-to-end generated tokens/second, or admission RPM. Compare like
windows; aggregate compatible rates by summing counts and denominators, not averaging TPS
arbitrarily. Remote decoding without inference timing is `unavailable`; token arrival rate
may be shown under its own label. Shared engine GPU power is not attributed to workers
without an explicit estimation method. Monetary spend, free-tier status, usage credits,
tokens and local electricity estimates are separate fields.

## Human orchestration

### Vocabulary and state

Represent **Task → Attempt → Worker session → Model request → Tool execution → Artifact**.
A task can have multiple attempts and several contributor/reviewer identities. A loaded
runtime, native terminal viewer and automation controller are separate owned processes.

Task flow: `draft → queued → running → candidate → awaiting review → rework/verified →
integration → postmerge checks → accepted`. Allow `blocked`, `cancelled` and `paused` with
explicit reasons; preserve the underlying phase. Independent review freezes the exact
candidate commit/tree and records reviewer identity, prompt scope and source imports.
Any later source change makes that verdict stale until reviewed or explicitly re-scoped.

Session observation uses `unknown`, `idle`, `requesting`, `streaming`, `tool-running`,
`retry-wait`, `disconnected`, `stopping`, `stopped`. A pause is an operator intent with its
own pending/acknowledged state, not an invented provider capability.

### Controls and their meaning

| Human action | Behaviour |
|---|---|
| Queue independent review | Freeze candidate, choose checklist/reviewer policy, create isolated worktree and explicit import root; run when eligible |
| Request rework | Select findings and source revision; create bounded attempt linked to the original review, retaining original report |
| Steer | Edit a prompt, preview target/session and delivery boundary; show queued/delivered/acknowledged separately; no automatic interrupt |
| Pause dispatch | Stop new tasks/retries under the chosen scope; existing work continues and UI says so |
| Drain then pause | Hold future work and await the current action/task boundary supported by the adapter; display outstanding activity |
| Interrupt now | Request exact owned-session abort, capture WIP and partial usage, report actual acknowledgment; never imply tools/children stopped without proof |
| Resume | Reconcile paused intent, actual sessions, WIP and leases; preview the next queued action and avoid duplicate workers |
| Change model | Finish/drain the current attempt or explicitly interrupt; start a new attributed attempt, preserve old context/evidence, recheck hardware/admission |
| Mark accepted | Check configured criteria and evidence; any human override records which gate was waived and why |

Programme pause has precedence over task queues, provider quota reset and timers. It must
persist across dashboard/controller/host restarts. Quota becoming available must not wake
paused work. Pause intent and abort failure remain visible until reconciled. A worker may
have already sent a request or started a tool; the UI cannot promise that cancellation
undoes effects or refunds tokens. Do not emulate a safe pause by suspending arbitrary OS
processes mid-write. Unsupported controls are disabled with a concrete explanation.

### Availability and policies

User-editable pools describe permitted provider/model identities, roles, maximum workers,
concurrent local sequences, allowed GPU UUIDs, resource reserve, context/output budgets,
free-only policy, fallback order, quiet hours and maximum task/repair/check budgets. Show
why a queued item is waiting and which change could make it eligible. Model availability
has states such as healthy, untested, cooling, quota-limited, disabled and unavailable;
the registry is dated and refreshable, not a hard-coded promise about free services.

Choose review independence explicitly: different session is the minimum; different model
or provider may be preferred, but is not proof of independent reasoning. Freeze the author
candidate; preserve observed author, reviewer and controller contributions. Never erase
earlier findings when a repair succeeds.

All admission paths, including retries, use one pool-scoped reservation/rate controller.
Use atomic leases, durable attempt IDs and conservative reconciliation after a timeout.
UI freshness failure must not create a free slot. Shared provider limits apply across
models and VMs that use that pool; unrelated account activity may remain invisible. The
TRIO settings (3 NVIDIA workers, target34/hard38RPM, ~1.77s spacing) are an imported policy
example, not universal service limits or defaults.

Allow event-driven automation templates: review when a candidate is committed; hold after
repeated identical failures; request a bounded repair; notify when a gate needs judgment;
stop new launches under a resource threshold. Each has trigger, scope, preconditions,
budget, cooldown, idempotency key, expiry and visible run history. Begin with dry-run
previews. No automated main merge or provider upgrade in the initial scope. The scheduler
must have an explicit owner; it must not duplicate an existing external continuation.

## VM and provisioning interface

Use “VM” consistently: this is QEMU, not a container. Show allocated vCPU/RAM, guest-observed
resources, base/profile/version, accelerator, filesystem sizes and host headroom separately.
Disk display includes virtual capacity, allocated overlay bytes, guest filesystem free,
backing-base size and host-volume free. Resource requests must account for local inference
RAM/commit/VRAM and other VMs without changing their allocations.

Proposed change flow: **preview → quiesce owned workers → prove VM stopped → apply supported
change → start/readiness → verify effective/guest values → offer explicit worker resume**.
Keep requested configuration staged until validation. A CPU/RAM edit must also handle
EzVM's persisted intent/readiness identity consistently; editing one JSON file is insufficient.

First resource mutation release: stopped-only CPU/RAM reconfiguration and disk **growth**.
Disk growth is a journalled multi-step storage operation: checked source identity and space,
recoverable old overlay/configuration, stopped image change, guest partition/filesystem
growth, then capacity and readiness verification. Handle partially completed growth without
pretending to shrink back. Never modify a backing base, operate on another VM, or copy a
live disk as a clean backup. Shrink, hotplug and VM suspend are deferred. Proposed controls
must call accepted EzVM APIs; disabled until the underlying contracts and recovery tests exist.

## Architecture and implementation choice

```text
 Terminal UI (views/input only) ───── read snapshots/events ─────┐
       │ typed command + expected revision + intent ID          │
       v                                                       │
 Optional session controller / action broker ─── durable journal + read model
       ├─ EzVM adapter → versioned PowerShell JSON/lifecycle locks
       ├─ guest adapter → scoped SSH collector / OpenCode / tmux
       ├─ engine adapters → Strata / LM Studio / future capabilities
       └─ provider pool → admission/retry/availability policy
```

Keep PowerShell5.1-compatible CLI authoritative for VM lifecycle. The optional companion
can bundle a pinned Python environment; no new Windows service, browser, Docker or WSL
dependency in EzVM's core path. A user-launched controller may persist for unattended work
only with explicit lifetime ownership. First milestone can be entirely read-only in one
process; add the command owner when orchestration is introduced.

Use a local transactional journal/read model (SQLite is the initial candidate), versioned
records and append-only evidence references. Collectors are cancellable and bounded; slow
SSH/provider calls do not block input. Use event streams where supported, reconnect with
deduplication and backfill, and bounded polling elsewhere. No HTTP mutation is sent merely
because a view was opened. Normalise request identity, scope and timestamps at ingestion.

Existing APIs inform adapter spikes: [OpenCode server](https://opencode.ai/docs/server/)
provides session/status/message/event interfaces and per-session abort. Read its live schema
and version before assuming support. It is not a VM manager or a general checkpoint/resume
protocol. Strata's local monitor and token-audit helpers are working references to extract
from, not dependencies to copy wholesale with their hard-coded ports, paths and GPU index.

| Initial adapter | Read path | Control boundary |
|---|---|---|
| EzVM | Existing JSON status/intent plus separate guest resource samples | Accepted CLI lifecycle operations; provisioning additions wait for new contracts |
| OpenCode | Scoped sessions, messages, tools and events; explicit version discovery | Documented session prompt/abort capabilities; graceful boundary pause requires additional coordination |
| NVIDIA/free endpoints through OpenCode | OpenCode usage plus owned request-dispatch/error telemetry where present | Shared pool admission; provider-specific cooldown/availability; no assumption of a quota API |
| Strata | Observed local `/metrics` and settings, version-pinned | Separate verified runtime lifecycle; no inference sent by metrics collection |
| LM Studio | Adapter against the installed SDK/API and actual loaded-model configuration | Explicit per-instance device selection plus physical verification; no automatic CLI loader fallback |
| Other engines/providers | Capability discovery and recorded fixtures before support | Unsupported fields/actions remain unavailable; no inferred universal pause or usage protocol |

Account configuration stores secret references in the platform's credential mechanism;
the dashboard does not copy key values into task records, logs or exports. Model registry
and endpoint changes are separate explicit setup actions, not a side effect of monitoring.

For UI selection, [prompt_toolkit](https://python-prompt-toolkit.readthedocs.io/en/master/pages/full_screen_apps.html)
offers composable full-screen layouts and key bindings and aligns with the mdbm reference.
[Textual](https://textual.textualize.io/guide/input/) is the alternative spike for richer
widgets; [Ratatui](https://ratatui.rs/) is a packaging/performance alternative if a native
binary becomes the priority. Choose after a small real-Windows mouse/resize/async/attach
prototype. Do not turn the paused TRIO widget library into an EzVM dependency, copy mdbm's
single-file architecture, or assume either project is licensed for reuse without checking.

Metrics remain observational. Guest text and model output are data, never host command
authority. Explicit adapters accept typed identifiers/arguments and existing ownership
checks. Use existing authenticated guest transport and a host-private controller channel;
loopback binding alone is not a complete trust boundary. There is no new security probing
in this planning work. Historical boundary findings need separate owner-authorized triage.

## Demonstration devbox

Use the current VM as a **recipe and test corpus**, not a redistributable image. It contains
project history, accumulated experiments and potentially account state. Build a clean,
versioned `agentic-demo` profile from a verified base with pinned tools and license metadata.

First run: prerequisites → host/resource check → download plan and disk estimate → clean
profile install → choose local or free endpoint → optional account setup → small verified
coding exercise. Later launches can be one click. Hardware/virtualisation prerequisites,
model downloads and provider registration are honest first-run steps, not hidden promises.

Offer local-first and optional free-endpoint paths. Neither requires a paid subscription
in the supported demonstration, but free endpoint availability/terms/limits can change.
Never fall back to paid inference silently. If no local hardware or free quota is available,
offer a clearly labelled replay of a recorded exercise, not simulated live success. Pin
model/runtime combinations per hardware tier only after actual qualification; do not make
this host's TITAN profile a universal recommendation.

The exercise should show one small implementation, a review with an observable finding,
a repair and verified result. Explain what the human chose and what the worker did. Measure
time to first accepted change, manual interventions, download/storage cost, failures and
restart recovery. Bundle no tokens, accounts, private SSH identity, authenticated overlay
or raw reasoning logs. Review software/model/base-image redistribution terms before packaging.

## Acceptance and open decisions

Initial success: a new operator can identify the active worker, explain why one is waiting,
find the tested source/result, queue a review, pause future work and later recover the same
queue without double execution. A developer can trace each displayed metric to its source.

The prototype now establishes prompt_toolkit as the implementation baseline; a change
requires a measured unmet requirement and recorded decision. Remaining decisions include
live terminal embedding vs attach-only; unattended controller lifetime; first supported hardware/model tiers; model
adapter version support; distribution license. Tiling, mdbm-style controls, strict pause
intent, evidence-backed acceptance and research traceability are the recommended direction.

Draft performance targets to validate, not measurements: under100ms p95 UI input response;
visible samples every1–2s with age labels; no blocking render on a10s unavailable source;
bounded scrollback/history cache; approximately1% single-core idle controller cost and
under200MiB UI+collector RSS on the reference host. Document any revised targets and results.

Design sources accessed16 October2026. The mdbm alpha explicitly lists Windows terminal
acceptance limits; matching its controls does not inherit qualification. No model worker,
VM mutation, remote issue, dependency installation or benchmark was launched for this plan.
