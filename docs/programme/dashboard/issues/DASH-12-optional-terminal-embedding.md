# DASH-12 — Evaluate bounded embedded terminal viewing and explicit input ownership

Status: **PLANNED** | Priority: **P2** | GitHub issue: [#38](https://github.com/techrote/ezvm/issues/38)

Dependencies: [DASH-03](DASH-03-tiled-workspace-and-activity.md), [DASH-05](DASH-05-durable-commands-and-pause.md).
Research: TRIO-FR-08 in the [field register](../../../research/TRIO-2026-10/README.md).

Read the [programme and common closure rules](../README.md) plus these RAG contracts:

- [00-SCOPE-AND-STATE](../../../rag/dashboard/00-SCOPE-AND-STATE.md)
- [02-TERMINAL-INTERACTION](../../../rag/dashboard/02-TERMINAL-INTERACTION.md)
- [03-CONTROLS-AND-REVIEW](../../../rag/dashboard/03-CONTROLS-AND-REVIEW.md)
- [06-TESTING-RELEASE-AND-RESEARCH](../../../rag/dashboard/06-TESTING-RELEASE-AND-RESEARCH.md)
- [08-TESTING-CI-RELEASE](../../../rag/08-TESTING-CI-RELEASE.md)

## Problem and baseline

Embedding may improve activity monitoring, but it must justify complexity and avoid orphan viewers, input leaks and terminal corruption.

At prototype `d692be6`: The current dashboard shows a stored transcript. It does not attach a PTY or forward worker input.
Reconcile the selected revision before editing; preserve working implementation.

## Implementation

1. Compare exact external attach with a bounded embedded PTY spike using disposable child sessions. Record memory, input/resize behavior, complexity and a go/no-go ADR.
2. If embedding is retained, separate read-only monitor from explicitly writable attach, enforce one input owner and provide a visible mode plus reliable escape back.
3. Bound scrollback, Unicode/control-sequence handling, resize propagation and backpressure. Avoid terminal/clipboard effects from replayed output.
4. Reuse/retire only the exact owned viewer; closing its pane keeps the intended worker session alive. Keep external attach as fallback if qualification fails.

## Acceptance criteria

- [ ] One input owner exists; read-only mode forwards zero key/mouse/paste bytes to the child.
- [ ] A full-screen child can be entered/exited/resized without losing dashboard focus or terminal modes.
- [ ] Output/memory are bounded and pane close leaves the intended session alive.
- [ ] A measured no-go with usable exact external attach can close this optional investigation; it does not silently promise embedding.

## Test cases

These are required future cases, not claims of existing or passing tests. Use
fixtures/process stubs first; physical/live qualification is separately identified.

- **DASH-12-T01 — Input ownership:** Two views contend, focus changes during paste and pause occurs; only explicitly selected writable owner receives intended input.
- **DASH-12-T02 — Terminal restoration:** Child crash, resize storm and full-screen exit restore dashboard modes/focus; Escape route is reliable.
- **DASH-12-T03 — Untrusted output:** Replay control/clipboard/title sequences and large Unicode output without side effects or unbounded scrollback.
- **DASH-12-T04 — Viewer lifetime:** Close/reopen and repeated attach do not abort workers or accumulate orphan clients; measure memory versus external attach.

## Out of scope

Arbitrary terminal writes in read-only panes, implicit session creation, modifying the worker terminal implementation and blocking the core read-only release.

## Closure evidence

Attach/embedding ADR, real terminal/input-ownership results, viewer-lifetime tests and measured go/no-go decision.

Apply the programme's common closure rules: original criteria and tests accounted
for, actual source/result identities, reviewed implementation and RAG updates, and
verification at the accepted revision. A dependent gate stays closed until those
prerequisites are accepted. This document does not authorize a TRIO restart.
