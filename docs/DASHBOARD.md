# Read-only VM & AI dashboard

The optional Windows terminal companion (`0.1.0-alpha.1`) displays EzVM instance
records, an explicitly enrolled Linux guest, OpenCode sessions/usage and enrolled
Strata/LM Studio engines. It cannot start/resume workers, submit inference, provision
VMs or change TRIO pause policy. It is separate from the released ezvm.ps1 CLI.

## Launch

From a checkout whose optional runtime is already installed, in Windows Terminal:

```powershell
.\dashboard.ps1
```

For a new checkout, use an existing Windows x64 Python 3.11 or newer:

```powershell
.\scripts\Setup-Dashboard.ps1 -Python 'C:\Path With Spaces\python.exe'
Copy-Item .\dashboard\config.example.json .\runtime\dashboard\config.json
# Edit the copy to enroll the intended existing VM and optional engines.
.\dashboard.ps1
```

Setup creates only runtime/dashboard/venv and installs the three existing pinned,
hash-checked wheels. It does not install Python or change the system interpreter.
The lock targets Windows x64. Linux fixture results are supplementary, not a claim
of packaged cross-platform support. The guest sampler requires Python 3.11 or newer.
No helper is installed in the guest; reviewed source is sent over existing SSH.

Without configuration only passive host/instance information is shown. A missing
explicit `-Config` file is an error. No guest, engine or worker is enrolled by default.
Keep an existing owner configuration intact; the viewer never rewrites it.

```powershell
.\dashboard.ps1 -Once  # Bounded live text observation
.\dashboard.ps1 -Json  # Local machine-readable observation, schemaVersion 1
.\dashboard.ps1 -Demo  # Explicitly synthetic UI, no external calls
```

An enrolled guest that produces no result before the one-shot deadline returns a
nonzero exit, not a success claim. Partial telemetry remains labelled unknown/error.
Output can contain local project paths and model/tool text; it is not a safe public
export. Display redaction is best-effort and terminal control sequences are stripped.

## Tiled controls

Use at least 120x35 for four tiles; 140x45 is more comfortable. Below 105 columns or
29 rows the focused tile fills the workspace. Alt+1 through Alt+4 still reach every
tile. Use a Unicode-capable terminal font. Interaction is independently implemented
with prompt_toolkit, with [mdbm](https://github.com/techrote/mdbm) as a design reference.

| Control | Result |
|---|---|
| Click a tile/control | Focus and act in one click |
| Mouse wheel | Scroll the pointed tile |
| Drag a divider with either button | Preview split; release commits, Escape cancels |
| [M] / Enter | Maximize or restore focused tile |
| [x] / Ctrl+T | Hide tile / restore all |
| Tab / Shift+Tab | Cycle visible tiles |
| Alt+1..4 | Reveal and focus a tile |
| Ctrl+P / F10 / [Commands] | Searchable palette, split sizing and tile swapping |
| Ctrl+F | Filter titles/models; Enter applies |
| Up/Down in worker tile | Select a session and keep it visible |
| PageUp/PageDown/Home/End | Scroll focused tile |
| F | Follow activity output |
| F5 / [Refresh] | Refresh observations, not workers |
| F1 / Escape | Help / dismiss overlay or cancel drag |
| Ctrl+Q / [Quit] | Close viewer only |

Outside clicks dismiss overlays without click-through. Scroll state is retained
within the viewer; layouts are not yet saved across launches. Maximize for long lines.

## Registering workers and source declarations

DASH-02 polls only actor session IDs explicitly listed in `registered_actors` or in
the enrolled workspace's owner-policy `actors`. A scoped history row or mouse
selection does not enroll a worker. Existing session-prefix filtering still applies.
Unregistered history remains visible as historical-unregistered/unobserved.

Add registrations to the ignored local configuration, for example:

```json
{
  "schemaVersion": 1,
  "instance": "example-vm",
  "workspace": "/home/coder/workspace",
  "session_prefix": "EXAMPLE-",
  "ports": [4098],
  "status_roots": 8,
  "registered_actors": [{"session": "example-session-id"}],
  "engines": []
}
```

At most 256 combined config/policy actor entries and four distinct ports are allowed.
Duplicate conflicting registrations are refused. Optional actor fields are `root`,
`accepted_baseline` (exact Git SHA), `candidate_root`, `restart_root`, `import_path`
and `executable`. Roots must remain inside the enrolled workspace. Import assertions
must name files in the candidate root; wrappers are files, not installation folders.
The UI labels baseline/candidate/restart separately. These are declarations and path
checks, not proof of execution or acceptance. Optional `origin_id` and `origin_epoch`
let the operator declare logical source identity without using endpoint ports.

## What the tiles mean

**VMs & workers:** persisted intent/state plus a separate PID/start/executable/argv
identity observation. Only the enrolled VM is SSH-probed. Registration coverage,
oldest source age, declared cycle and overdue identities are visible. Missing actors
stay unknown; no actor state authorizes admission or control.

**Worker activity:** the last 45 stored parts, with output tails up to 5,000 characters,
tool exit metadata and read-only worktree information. Checks is a text filter, not
an acceptance oracle. Report is model prose, not an audited artifact browser. No
reasoning parts or tool input arguments are displayed; no keystrokes reach workers.
Git worktree reads refuse configured external clean filters; external diff/textconv
and fsmonitor are disabled. An unavailable Git view does not become an empty proof.

**Models & usage:** reported engine speed/context/queue/history, or a bounded enrolled
OpenCode usage window. Input/cache/output/reasoning remain separate; missing values
are not zero. No invented grand token total, billing, quota or worker GPU attribution.
Ports never multiply messages; engine counters remain separate. Scan limits and
truncation are visible, rather than calling a bounded window all-time history.

**Resources:** allocated versus observed guest CPU/RAM, interval CPU/load, filesystem,
swap, QEMU RSS, host RAM/commit/disk/CPU and reported physical GPU metrics. The first
guest sample has no CPU interval. Provisioning remains display-only.

## Observation limits and read-only boundary

The pause banner is last-observed policy with age, not a pause command. Partial status
failure is unknown even when another alias says busy or returns an empty map. Last
known activity is preserved separately and is never a free-slot assertion.

Registered roots rotate through a reserved fairness lane; selected/active roots may
use spare capacity. For N eligible roots and batch B, service is bounded by
`ceil(N / max(1, B-1)) * 48 seconds` when N>B (use B when N<=B), or the actor is visibly
overdue. The conservative 48 seconds covers a 40-second sampler and 8-second period.
Selection cannot reset the cursor or accelerate polling. Failed/overdue sources keep
last-good data and age. Unavailable guest-only policy cannot be enumerated from host.

Limits: 64 MB DB, 16 MB WAL, two matching source-file captures; 10,000 recent session
rows plus independent registered-ID lookups; 20,000 recent messages; 3 seconds or
10 million SQLite VM instructions; 4 MB combined process/HTTP output. These are
hard read bounds, not idle-performance targets. A busy/oversized/unsupported database
is unavailable; it is never repaired, migrated or opened by SQLite at its source.
SQLite operates only on a disposable query-only copy. Source file contents and
sidecars are preserved; ordinary OS read metadata is not a telemetry write API.

Only fixed loopback GETs are allowed (Strata /metrics, LM Studio /api/v0/models,
OpenCode scoped /session/status). Proxy routing and redirects are disabled. No
provider account search, inference prompt or model-load request occurs.

Host/engine periods are 3 seconds, guest 8 and inventory 10. Each source has one
in-flight job; at most seven host jobs and eight guest GETs execute concurrently.
Reads have independent output, time and cancellation bounds. Closing signals only
the sampler's owned children; no VM/worker process is stopped. Persisted READY text
is not fresh readiness qualification; existing managed trust must match before SSH.

## Validation and next work

```powershell
& .\runtime\dashboard\venv\Scripts\python.exe -B -m unittest discover -s dashboard/tests -v
& .\runtime\dashboard\venv\Scripts\python.exe -B dashboard/qualify_observation.py --output "$env:TEMP/dash02-observation.json"
```

Tests use disposable synthetic data, owned subprocesses and real prompt_toolkit pipe
input. The [DASH-02 handoff](research/TRIO-2026-10/DASH-02-OBSERVATION.md) separates
those measurements from physical terminal paint, WHPX and live-worker acceptance.
[Prototype verification](DASHBOARD-VERIFICATION.md) remains historical evidence.
The [issue programme](programme/dashboard/README.md) owns remaining layout, ledger,
packaging, performance and control gates. No worker controls or TRIO restart are
implied by this read-only implementation.
