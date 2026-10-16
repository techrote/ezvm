# TRIO field study — October2026

Status: initial research extraction for dashboard planning,16 October2026. The coding
programme is paused. Accepted TRIO001..007 and the later partial restart checkpoint are
different artifacts; this study does not declare TRIO finished.

The [dashboard issue series](../../programme/dashboard/README.md) now links all
20 observations to concrete implementation/testing issues. Its catalogue preserves
the original DASH-01..12 action IDs and adds DASH-13 for CI/packaging. The original
evidence/observations remain unchanged; planned retests are not resolved findings.

The study observed a Windows-hosted EzVM coding guest with local inference on a TITAN RTX,
NVIDIA endpoints and OpenCode free models. The operator used custom scripts for admission,
telemetry, independent review, artifact exports and manual recovery. Later authorised Codex
wrap-up corrected small unfinished components and reconciled the project. Attribution to
local/free workers, cloud workers and controller intervention remains distinct.

## Authoritative study records

- [observations.json](observations.json): stable `TRIO-FR-*` observations, evidence links,
  limitations, proposed dashboard slices and retest criteria. All are proposals/triage,
  not newly reproduced or resolved defects.
- [evidence-index.json](evidence-index.json): source hashes, provenance and local-only status.
  Raw evidence remains in the field-test workspace; its private locations are ignored.
- [Dashboard proposal](../../design/VM-AI-DASHBOARD.md),
  [record/control contracts](../../design/VM-AI-DASHBOARD-CONTRACTS.md) and
  [delivery slices](../../design/VM-AI-DASHBOARD-DELIVERY.md): design responses, not current APIs.

The pre-TRIO EzVM audit is recorded as **historical reported evidence**. We did not rerun its
WHPX, lifecycle or boundary experiments during this planning task. The two existing owner
source patches remain untouched. A code-inspection concern in the ad-hoc admission helper
is explicitly a hypothesis requiring a failure test, not a measured concurrency violation.

## Main lessons to act on

1. Persistent ownership and pause intent matter more than whether an API currently says idle.
2. A source change, a passing test, a committed report and an accepted issue are different facts.
3. Provider/model names alone do not explain throughput or failures; actual settings,
   source identity, human help and error category must accompany comparisons.
4. A terminal client, worker and loaded model are different resource consumers. Monitoring
   should not multiply clients until the machine runs short of memory.
5. Reconstructing state from prose handoffs and many worktrees is expensive. Structured
   task/evidence records should generate the operational summary and restart package.
6. The devbox demonstration should be rebuilt from a clean recipe. The evolved lab VM is
   valuable research material, not a credential-free redistributable base by assumption.

## Limits and next evidence

One operator, one host and one large project are not a representative usability study or a
general model benchmark. Several failures were prompt, harness, context or provider errors.
Independent reviews were valuable but also needed verification. No unobserved account usage
or full-context model capability is inferred from logs.

Next research should include a new user completing a small local/free workflow, on a clean
profile, with no operator-specific helper knowledge. Record time to useful result and every
manual intervention. Test recovery after a deliberately paused session using fixtures first.
Select hardware tiers only after measuring actual memory, storage and throughput requirements.
Publish outcomes with exact revisions and unchanged failing examples, not only successful demos.
