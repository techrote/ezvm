# EzVM field research and improvement loop

This directory holds publishable summaries of first-person use, separate from product
contracts and raw runtime evidence. Initial study: [TRIO, October2026](TRIO-2026-10/README.md).
Current design response: [VM & AI dashboard](../design/VM-AI-DASHBOARD.md).

## Record once, derive views

Use a stable observation ID and an append-only history of corrections. Capture:

- User goal, context, exact source/runtime/profile/model configuration and date.
- What the operator observed; separate a hypothesis about why it happened.
- Evidence IDs, hashes, reproduction procedure, scope and confidence.
- Human intervention, useful outcome and the cost in waiting/repair/verification time.
- Proposed action, owner/issue reference, priority and a measurable retest criterion.
- Disposition: captured, triaged, proposed, scheduled, implemented, verified or deferred.

An observation is not fixed because a workaround succeeded or a dashboard was proposed.
Link observation → issue/ADR → change → test → measured field retest. Closure records the
actual revision and outcome; preserve the original symptom and uncertainty. Keep a
generated summary for humans instead of copying growing chronology into every handoff.

## Repository and private evidence

Commit redacted observations, schemas, reproducible fixtures, design decisions and outcomes.
Do not commit VM images, raw sessions/chain-of-thought, account identifiers, tokens, whole
agent databases or private terminal logs. Store those, when deliberately retained, outside
tracked source with a content-addressed manifest and controlled export. A public evidence
index can identify a local artifact by hash without exposing its private absolute location.

The initial study uses `observations.json` as its single register. `evidence-index.json`
contains hashes and descriptions; ignored `.ezvm/research/TRIO-2026-10/locations.json` maps
those IDs to this host's files. A fresh clone sees the summaries and knows which raw sources
are local-only. Missing raw evidence must be shown as unavailable, not reproduced PASS.

Add minimal redacted reproductions before publishing an implementation issue. Inspect
license and privacy of captured content. Repository-level links and summaries must be
portable; the current user's Windows paths belong only in the ignored location map.

## What to measure

For EzVM: time to first READY, start/stop/recovery reliability, standard-user compatibility,
operator interventions, provisioning accuracy, disk/memory headroom and portability.

For orchestration: time from task completion to next useful action, duplicate launches,
false completion claims accepted, stuck retries, correct pause recovery, review queue delay,
evidence completeness and controller overhead.

For model/configuration trials: accepted tasks and retained changes; independently found
defects; self-detected defects before feedback; repaired defects and repair rounds; failed
tool/context/provider attempts; token/time/resource costs; exact prompting and human help.
Use denominators and scope. Small helpers, broad implementation and independent reviews
are different experiments. Hold power, context, quant, runtime, MTP/cache policy and task
constant where possible; randomise/counterbalance repeated comparisons. Record confounds
when controls differ. No scalar model ranking from tokens/second or one successful slice.

## Cadence and ownership

Capture an observation when friction occurs. Triage at milestones or planned operator review;
do not interrupt every useful task to write a long report. Before a demo/release, select the
highest-impact repeated failures and retest resolved ones on the actual target environment.
This is a proposed working practice, not a newly created automation. A named human selects
scope and approves publication; implementation agents attach evidence and preserve provenance.
