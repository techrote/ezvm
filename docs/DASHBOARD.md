# Read-only VM & AI dashboard

The first dashboard is an optional Windows terminal companion, version
`0.1.0-alpha.1`. It displays real EzVM instance records, an enrolled Linux guest,
OpenCode sessions and usage, and explicitly configured Strata/LM Studio engines.
It does not start or resume workers, submit inference, change provisioning, or
change the TRIO pause policy. It is separate from the released `ezvm.ps1` CLI.

## Launch

This checkout's runtime environment and `trio-lab` observation configuration are
already installed. In Windows Terminal, from the repository root:

```powershell
.\dashboard.ps1
```

Use a terminal at least 120 columns by 35 rows for four tiles; 140 by 45 is more
comfortable. Below 105 columns or 29 rows, the focused tile occupies the workspace.
Alt+1 through Alt+4 still reach every tile. Use a Unicode-capable terminal font.

For a new checkout, use an existing Windows x64 Python 3.11 or newer:

```powershell
.\scripts\Setup-Dashboard.ps1 -Python 'C:\Path With Spaces\python.exe'
Copy-Item .\dashboard\config.example.json .\runtime\dashboard\config.json
# Edit the copied config to explicitly enroll the intended existing VM/engines.
.\dashboard.ps1
```

Setup creates only `runtime/dashboard/venv` and installs the three pinned,
hash-checked wheels from `dashboard/requirements.txt`. It does not install Python
or change the system interpreter. Runtime state and dependencies are Git-ignored.
The lock currently targets Windows x64; other platforms are not qualified.

Without configuration, the dashboard displays passive host/instance information
and enrolls no guest or engine. `-Config <file>` uses an explicit configuration;
a missing explicit file is an error. The example deliberately has no VM selected.
The existing TRIO configuration selects only `trio-lab`, `/home/coder/workspace`,
`TRIO-` session titles and the four previously established OpenCode ports.

Other useful commands:

```powershell
.\dashboard.ps1 -Once       # One live text snapshot; no interactive terminal needed
.\dashboard.ps1 -Json       # One machine-readable live snapshot, schemaVersion 1
.\dashboard.ps1 -Demo       # Explicitly labelled synthetic UI; no external calls
```

Snapshots can contain project paths and model/tool output. They are local research
artifacts, not automatically safe public exports. Display redaction is best-effort;
terminal escape/control sequences are stripped.

## Tiled controls

The interaction reference is [mdbm](https://github.com/techrote/mdbm). This is an
independent implementation using prompt_toolkit, not copied mdbm source.

| Control | Result |
|---|---|
| Click a tile or a control | Focus and act in one click |
| Mouse wheel | Scroll the tile under the pointer |
| Drag a divider, left or right button | Preview a new split; release commits, Escape cancels |
| `[M]` / Enter | Maximize or restore the focused tile |
| `[x]` / Ctrl+T | Hide a tile / restore all tiles |
| Tab / Shift+Tab | Cycle visible tiles |
| Alt+1…4 | Reveal and focus a particular tile |
| Ctrl+P / F10 / `[Commands]` | Searchable command palette, including split sizing and tile swapping |
| Ctrl+F | Filter session titles/models; Enter applies |
| Up / Down in worker tile | Select another session and keep it visible |
| PageUp / PageDown / Home / End | Scroll focused tile |
| F | Toggle following the bottom of worker activity |
| F5 / `[Refresh]` | Request fresh observations |
| F1 / Escape | Help / dismiss overlay or cancel divider drag |
| Ctrl+Q / `[Quit]` | Close this viewer only |

Outside clicks dismiss an overlay without clicking through. Hide/restore retains
tile scroll state within the running viewer. Layout is not yet saved across launches.
Long output lines are clipped; maximize the activity tile to see more.

## What the tiles mean

**VMs & workers:** instance intent, persisted lifecycle state, a separate PID/start
time/executable identity observation, and scoped OpenCode session history. Click a
session to inspect it. The default view shows the enrolled VM; the palette can show
all passive host instance records. Other VMs are never SSH-probed.

**Worker activity:** bounded recent model text and tool output, tool completion/exit
metadata where supplied, selected-session usage, worktree HEAD, read-only Git status
and diff statistics. Activity/Changes/Checks/Report tabs change the view. Checks is a
text filter, not a CI acceptance oracle. Report shows model text, not an audited
report-file browser. Last 45 stored parts and 5,000-character output tails are read;
reasoning parts and tool input arguments are not displayed. This is a transcript,
not an interactive PTY, and no keystrokes are forwarded to workers.

**Models & usage:** local engine state and reported speed/context/queue/history;
an alternative Usage tab aggregates all enrolled OpenCode history by provider/model.
NVIDIA and free OpenCode models appear through their actual OpenCode records.
Input, cache reads/writes, output and reasoning are kept as separate normalized
categories. The UI does not invent a cross-provider token grand total, billing
cost, remaining quota, or per-worker GPU rate. Missing usage is not assumed zero.
One database snapshot prevents summing the same message once per server port.
Strata runtime counters remain separate from OpenCode message counters.

**Resources:** allocated versus guest-observed CPU/RAM, guest interval CPU/load,
filesystem and swap, profile information, QEMU RSS, host RAM/commit/disk/CPU,
and physical GPU temperatures, VRAM, utilization and power readings. Provisioning
is display-only. The first guest sample has no CPU interval and shows an em dash.

## Observation limits and read-only boundary

- The pause banner is the **last observed** owner-policy flag, with sample age. It
  does not pause anything itself. An idle API is not task acceptance.
- Guest observation reads `/proc`, filesystem capacity, the policy file, and the
  existing OpenCode SQLite database (`mode=ro`, `query_only`, snapshot transaction).
  It sends a bounded Python program over existing managed SSH; no guest helper is
  installed. SSH uses strict existing host trust, never enrolls or rewrites keys.
- Scoped `GET /session/status` covers enrolled actors, the selected session and
  recent roots, up to `status_roots` (default 8). History display defaults to 40
  sessions (this installation: 60). This is **not exhaustive discovery of every
  historical, unenrolled running session**. Unsampled roots say `unobserved`.
  A partial status-source failure yields `unknown`, not `idle`. Coverage and failed
  read counts are visible. Busy/retry observations take precedence over idle.
- Host engine requests are only allowlisted loopback GETs: Strata `/metrics` and
  LM Studio `/api/v0/models`. Redirects and proxy routing are disabled for both
  host engine and guest status requests. No provider inference endpoint is called.
- Refresh periods are host/engines 3 seconds, guest 8 seconds and inventory 10
  seconds. Each source has at most one in-flight request. Slow/unavailable sources
  retain their last sample with an error and age; UI input stays independent.
  Guest SSH is bounded to 40 seconds to include failed multi-root status batches.
  Exit may wait for an outstanding bounded read to finish.
- Persisted READY/RUNNING text is not a new EzVM readiness qualification. The viewer
  does not launch lifecycle diagnostics, storage tools, GPUs or inference.
- No worker pausing/resuming, review queues, steering, provisioning changes,
  automation editing, worktree merges or public exports are implemented here.

## Validation and next work

Run the isolated tests without a VM, GPU, provider account or network:

```powershell
& .\runtime\dashboard\venv\Scripts\python.exe -X utf8 -m unittest discover -s dashboard\tests -v
```

See [verification](DASHBOARD-VERIFICATION.md) for the actual local checks and their
limits. The [design](design/VM-AI-DASHBOARD.md), [contracts](design/VM-AI-DASHBOARD-CONTRACTS.md)
and [delivery slices](design/VM-AI-DASHBOARD-DELIVERY.md) remain the wider proposal.
The [implementation/testing issue series](programme/dashboard/README.md) now owns
the actionable scope, dependencies and closure evidence for that future work.
Next useful work is persisted layouts, exhaustive registered-worker discovery with
bounded scheduling, event/latency history, replayable adapter fixtures and a reviewed
command broker for future human orchestration. None of those controls is implied by
the current read-only release.
