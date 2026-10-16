# Dashboard RAG 02 — Terminal interaction and activity views

Status: target contract. The prototype already uses prompt_toolkit; retain it unless
a recorded unmet requirement justifies a bounded alternative spike.
Reference: [mdbm](https://github.com/techrote/mdbm). Reuse its interaction ideas,
not source/assets without a separate license decision.

## Tiled workspace

Preserve stable tile identities independently of their positions. Focus, selection,
scroll position, filter, split ratios and hidden state survive hide/restore; accepted
layout preferences later survive restart via atomic, versioned local preferences.
Invalid/out-of-bounds preferences recover to defaults without losing worker state.

Tab/Shift+Tab cycle visible tiles; Alt+1..4 reveal/focus; Ctrl+P/F10 opens searchable
commands; Ctrl+T restores; F1 helps; Escape dismisses/cancels; Ctrl+Q exits viewer.
Each mouse operation has a keyboard alternative. Click a control in an unfocused
pane once to focus and act. Wheel scrolls only the pane under the pointer.

Dividers are one cell, draggable with left or right button; preview while dragging,
release commits and Escape restores the pre-drag geometry. Resize during a drag
must not leave invalid focus/capture. Overlays own pointer/input; outside dismissal
consumes that click. Small terminals show a focused pane with every hidden pane
reachable. The current narrow threshold is 105 columns / 29 rows.

## Activity and evidence

Observe structured tool events and bounded transcript tails. Keep the selected
session by identity even as the list reorders. Show session/source age, exact root,
model, task/attempt where known, tool start/end/exit and artifact references.
Checks and Report filters do not infer acceptance. Future artifact views verify
the referenced file/hash and distinguish a committed report from model prose.

A user reading older output stays there, with a new-output indicator and explicit
Follow control. Bound scrollback/backfill and label truncation/rotation. Search/copy
must strip or neutralize terminal control sequences, including clipboard/title
effects. Keep raw local export an explicit action; no automatic public upload.
Do not copy provider secrets or raw reasoning into the research corpus.

## Viewing versus controlling

Read-only panes never forward keys, mouse events or paste into a worker. They
cannot create prompts, inference, processes or review jobs. Optional exact external
attach needs an explicit target and input-mode distinction; reuse one owned viewer
where possible. Closing a viewer is not session cancellation.

Embedded PTY is optional DASH-12 work. It needs bounded scrollback, resize, terminal
restore, one input owner and a reliable escape back to the dashboard. Read-only
monitor mode must be mechanically separated from writable attach. An external
terminal is the fallback if embedding cannot meet the contract.

## Human workflow views

Before controls ship, explain unavailable actions. Future controls display:
target and source revision; next action; waiting reason/capacity; pause pending vs
acknowledged; review candidate/finding links; model/role policy; and evidence still
required. Prefer concrete task names and outcomes over raw endpoint jargon.
Never render a model-generated button/command as operator authorization.

## Required qualification

Automated real parser/event tests cover key sequences, SGR clicks/wheel/drag,
focus changes, overlays, resize, Unicode wide/combining characters, output floods
and unavailable collectors. Test 80x24, 120x40 and 160x48 plus a smaller fallback.

Record separate physical Windows Terminal mouse/keyboard results at those sizes.
Pipe-input success is useful but not physical-terminal qualification. Measure
input dispatch and input-to-visible-paint separately where tooling permits.
The initial target is p95 input response under 100ms during a 10-second source
stall; unavailable physical measurement is an explicit qualification gap.
