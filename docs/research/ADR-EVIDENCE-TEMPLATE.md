# ADR / evidence record template

Copy this template to a new dated record. Never overwrite an original failure or
claim; append a correction with the original ID, immutable URL and content hash.
Keep raw prompts, reasoning, accounts, host paths and full databases private.

## Decision identity and context

Record ID; status (proposed / implemented / verified); scope; date; author/reviewer;
issue IDs; observation IDs; original public evidence IDs and pinned revision URLs.
Separate measured observations, code-inspection hypotheses and design inference.

## Choice and alternatives

Decision, alternatives, measured reason, expected consequences, limitations and
revisit trigger. Explain which existing implementation is preserved. A fixture
result is not a live capability, product acceptance or historical defect resolution.

## Executable evidence

Case IDs; exact command and harness revision; clean commit and Git tree, or explicit
WIP before/after patch digests; expected and observed imports/source; runtime/tool
versions; fixture label/version/hash; actual start/end and exit status; per-case
PASS/FAIL/SKIP with reason; raw-byte versus canonical hash algorithm; public result
paths and hashes; unchanged-target assertions for refusals; side-effect counts.
Never turn PASS stdout plus a nonzero exit into successful evidence.

## Qualification and corrections

Implemented revision; reviewed revision; accepted revision; CI/run evidence;
remaining hardware/live gates; unresolved confounds and next retest. For corrections,
name the superseded ID/hash, preserve its original content, and explain the changed
classification. Provider transport, source/harness failure, code defect and human
intervention must not be merged into a model reasoning score.
