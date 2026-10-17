# AGENTS.md

## Purpose

ezvm is a Windows-first portable QEMU + QCOW2 environment manager for disposable coding-agent virtual machines.

The project is intentionally small in concept: a repository-controlled PowerShell control plane manages a repository-local QEMU runtime, immutable prepared base images, thin per-instance QCOW2 overlays, QEMU user-mode networking and SSH-based guest control.

## Authority order

For any implementation task, authority is ordered as follows:

1. current repository state on the default branch;
2. the current GitHub issue body and all issue comments;
3. this file;
4. docs/rag documents referenced by the issue;
5. docs/programme/IMPLEMENTATION-PROGRAMME.md;
6. historical handoff text.

Never assume a stale commit hash, branch, version, port or external download remains authoritative. Reconcile live state first.

## Required pre-work

Before editing for any issue:

1. fetch and inspect current main;
2. read the complete issue and all comments;
3. inspect open and recently merged PRs touching the same subsystem;
4. read this file;
5. read every RAG document listed in the issue;
6. inspect current CI and tests;
7. identify dependency issues and confirm they are accepted or merge-safe.

If existing implementation already satisfies part of the issue, preserve it and adjust scope rather than reimplementing blindly.

## Non-negotiable architecture rules

- Windows x86-64 is the primary host target for v0.1.
- PowerShell 5.1 compatibility is required for the public control path unless an issue explicitly changes the contract.
- QEMU is installed only into repository-local runtime state. Do not require a system-wide QEMU installation.
- WHPX is the normal accelerator. TCG may be used for diagnostic or CI fallback, but must not be presented as equivalent performance.
- Large binaries, QEMU installers, cloud images, VM disks, private keys, tokens and other runtime artifacts must never be committed.
- Downloaded external artifacts must be pinned and hash-verified according to repository manifests.
- Managed base images are immutable once any overlay depends on them, including explicit derived/imported snapshots.
- v0.1 supports one backing level: immutable managed base -> instance overlay. A managed base is either a clean prepared image or an explicit sensitive derived/imported snapshot. Do not create arbitrary backing chains.
- Backing references must remain relocation-safe and must be validated before a VM is started.
- Default networking is QEMU user-mode NAT. SSH forwarding binds to 127.0.0.1 only.
- Do not introduce TAP, bridged networking, Hyper-V virtual switches, Docker, WSL or a background service into the v0.1 critical path.
- Credentials must not be baked into source cloud images or clean prepared base images. Explicit stateful derived/imported snapshots may preserve guest credentials; label them sensitive and never treat them as clean prepared images.
- Destructive actions require positive instance identification and must fail closed on ambiguous state.
- A running VM must never be copied, rebased, reset or flattened as though it were cleanly stopped.

## Coding and interface rules

- Prefer small PowerShell modules with pure functions around path calculation, configuration validation and QEMU argument generation.
- External process invocation must capture exit code and useful stderr/stdout.
- Quote and normalize Windows paths deliberately. Test paths containing spaces.
- Machine-readable state is JSON with an explicit schemaVersion.
- User-facing commands must return non-zero exit status on failure.
- Commands must be idempotent where the operation naturally permits it.
- Errors must describe remediation, not merely the failing command.

## Testing rules

Every issue must add or extend automated tests for its acceptance criteria.

Use three layers where applicable:

1. pure unit tests for configuration, paths, state transitions and command construction;
2. process-level tests with stubbed or real lightweight executables;
3. bounded QEMU integration tests where CI permits them.

Never silently convert a hardware or environment limitation into a PASS. If a check cannot run, emit an explicit SKIP with the reason and keep other coverage authoritative.

### Temporary CI-PoC hosted TCG exception (owner instruction, 2026-10-17)

The owner explicitly deferred the approximately three-hour automatic hosted TCG
release qualification until the end of the Runloc CI proof of concept. For
same-repository PR branches beginning `ci-poc-` and the existing
`ezvm-ci-whpx-pilot` branch, `.github/workflows/ezvm-012-real-release.yml` therefore
skips only its full TCG release job and emits an explicit deferral notice.
Manual `workflow_dispatch` remains available; other same-repository PRs retain
the complete job, and fork PRs retain the existing refusal to run it.

This scoped scheduling exception supersedes the requirement to wait for this
automatic full TCG run on those CI-PoC PRs. Keep repository/control-plane checks,
both supported Windows PowerShell lanes, standard-user ACL regressions and all
other applicable checks. Deferred TCG coverage is unmeasured, not PASS; physical
WHPX acceptance and functional failure handling are unchanged. Do not alter
branch protection or apply this exception to unrelated work.

Remove this exception and its workflow notice/condition, or replace them with
the reviewed qualified-WHPX/hosted-fallback policy, when
[Runloc CI-POC-003 / #23](https://github.com/techrote/runloc/issues/23) completes.
Restore automatic hosted qualification before treating the temporary deferral
as a permanent release policy. See the testing RAG's
[decision table](docs/rag/08-TESTING-CI-RELEASE.md#temporary-ci-poc-hosted-tcg-deferral).

## Branch, PR and merge workflow

Each implementation issue is completed end-to-end by the executing agent.

1. Create or reuse a dedicated branch named for the issue, normally ezvm-XXX-short-name.
2. Implement the complete in-scope change.
3. Run all relevant local tests and repository-wide fast checks.
4. Review the diff for scope creep, secrets, generated artifacts, unsafe paths, stale docs and regression risk.
5. Push the branch and open a PR whose body:
   - references the issue;
   - contains Closes #<issue-number>;
   - summarizes behavior and tests;
   - records any explicit SKIP or environment limitation.
6. Monitor automated checks without tight polling. When waiting for CI, check at approximately 120-second intervals.
7. Investigate and fix every relevant failure. Do not merge known-red CI.
8. Reconcile any concurrent main changes before merge.
9. Merge only after required automated checks are green and review threads are resolved. Prefer squash merge unless repository policy has changed.
10. Verify the resulting main commit and post-merge CI/status.
11. Close the issue only when its acceptance criteria are actually satisfied.

Do not put text in PR bodies that resembles GitHub command syntax except the intentional Closes line.

## Model guidance

Use the strongest available coding model with High reasoning effort for normal implementation. Use Extra High reasoning, when available, for final review of QCOW2 chain operations, QEMU process/state transitions, destructive lifecycle commands, credential boundaries and release qualification.

## Documentation discipline

If implementation changes a contract described in docs/rag, update the relevant RAG document in the same PR. The code and the RAG documentation must not knowingly disagree.
