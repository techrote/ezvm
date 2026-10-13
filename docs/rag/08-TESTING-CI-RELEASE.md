# 08 — Testing, CI and release contract

## Test philosophy

The control plane should be highly testable without booting a VM. QEMU integration then verifies the boundaries that mocks cannot.

Every implementation issue owns tests for the behavior it adds.

## Foundation test entry points (EZVM-001)

Run `scripts/Test-Repository.ps1` for repository-contract validation, and
`tests/Run-Tests.ps1` for the control-plane suite. Both are first-party PowerShell
source and require no VM or downloaded test module. The test harness is explicitly
versioned as `1.0.0` in source and `tests/tooling.json`; a harness change must keep
that identity coherent. Detailed commands and test ownership are in
[tests/README.md](../../tests/README.md).

The suite discovers `*.Tests.ps1` files and rejects empty or all-skipped success.
Each test reports PASS, FAIL or an explicit capability SKIP, followed by totals.
Failures terminate non-zero. Native-process fixtures, copied checkouts, malformed
state and isolated git repositories are generated only in temporary directories.

CI has separate Windows PowerShell 5.1 and PowerShell 7 test lanes, with assertions
that the intended engine is actually executing. The PowerShell 7 test runtime is
pinned in `tests/tooling.json`, downloaded from its official release, hash-checked
and extracted into the runner's temporary directory. This makes the tested engine
independent of a runner image's bundled version, without installing it globally.
The repository contract remains an independent check. Checkout is pinned to a
reviewed full commit SHA, workflow permissions are read-only and jobs have bounded
timeouts.

Local PowerShell 7 on a non-Windows host can provide additional control-plane
evidence, but does not substitute for either Windows lane. Windows file-lock and
native argument parsing tests must execute on Windows before this issue is
accepted. No QEMU, guest boot or WHPX execution is part of EZVM-001 acceptance.

## Required CI layers

### Repository contract

Fast checks on every PR:

- expected authority/RAG files exist;
- issue-code programme remains coherent;
- forbidden generated/binary runtime artifacts are not tracked;
- JSON manifests/configs parse;
- PowerShell source has no obvious syntax errors.

### PowerShell unit tests

Run the supported control-plane tests under Windows PowerShell 5.1.

Also run under current PowerShell 7 where practical to prevent accidental incompatibility in either direction.

Use a pinned Pester release or another explicitly versioned test harness rather than an unbounded latest dependency.

### Pure lifecycle tests

Without QEMU, test:

- instance-name validation;
- path normalization and relocation;
- config precedence;
- state-machine transitions;
- PID/process identity decisions using fixtures/mocks;
- port allocation collisions;
- QEMU/qemu-img argument arrays;
- destructive-path guards;
- schema migration/refusal.

### Tool-boundary tests

With a managed or fixture QEMU toolchain where reasonable, test:

- qemu-img create/info output handling;
- one-level backing validation;
- flatten/export behavior on synthetic small images;
- malformed chain rejection.

### VM integration

Bounded integration may use TCG on CI if WHPX is unavailable.

Integration should prove the orchestration path, not performance.

When the runner does not expose nested virtualization/WHPX:

- record a clear SKIP for WHPX execution;
- still test WHPX capability detection and argument construction;
- never report WHPX runtime PASS.

## Network tests

Tests cover:

- SSH hostfwd binds 127.0.0.1;
- unique port allocation;
- seed guestfwd construction;
- seed server rejects unexpected paths;
- timeouts terminate cleanly.

Do not require public inbound network access in CI.

## Portability tests

Use temporary roots with:

- spaces;
- long-ish directory names;
- changed root prefix;
- simulated drive-style paths where possible.

Verify no persistent configuration unnecessarily captures the old absolute root.

## Safety tests

Explicit regression tests are required for:

- refusing reset/export/clone when running;
- stale PID detection;
- deletion path escaping runtime root;
- broken backing path;
- base digest mismatch;
- unexpected chain depth;
- download digest mismatch;
- SSH identity mismatch.

## PR gate

A PR is mergeable only when all required automated checks are green.

Capability-based skips must be visible in logs and justified by runner capability, not by test failure.

Agents wait at approximately 120-second intervals when monitoring CI rather than tight-loop polling.

## Release contents

A normal GitHub release should contain the small ezvm control-plane package/source, manifests and documentation.

Do not casually redistribute third-party QEMU or Ubuntu binaries inside the release artifact. Normal bootstrap obtains pinned external artifacts from their documented providers.

A user's already-bootstrapped ezvm working directory can itself be copied between their machines as cold portable state.

## Release evidence

v0.1 release notes must state:

- commit/tag;
- supported host/guest baseline;
- pinned QEMU provider/version;
- pinned Ubuntu source release/digest identity;
- CI results;
- which accelerator integration was actually executed;
- known limitations;
- migration compatibility for state schema.

## Release acceptance scenario

A documented clean-host scenario must cover:

1. clone/unpack ezvm;
2. doctor;
3. bootstrap QEMU;
4. acquire Ubuntu source;
5. build prepared base;
6. create/start instance;
7. authenticated SSH/exec;
8. create/start second concurrent instance;
9. stop/restart;
10. reset one;
11. stateful clone/export;
12. cold relocation to another root;
13. re-run doctor and start after relocation.

Where CI cannot execute a platform capability, retain automation for every surrounding contract and document the unexercised capability precisely.

## EZVM-002 bootstrap/preflight coverage

Normal CI uses deterministic tiny provider/extraction fixtures to cover digest
acceptance/rejection, interrupted transfers, unexpected extraction layouts,
reviewed-version mismatch, idempotent bootstrap, paths containing spaces,
absolute managed-tool invocation, PATH/registry independence and doctor
classification. It never downloads the large QEMU provider artifact on every PR.

Provider-pin refreshes require an explicit bounded Windows verification of the real
reviewed artifacts. The initial EZVM-002 verification proved the verified
7zr -> full 7-Zip -> QEMU NSIS extraction chain and real QEMU/qemu-img version
probes. WHPX execution is not part of this issue's PASS evidence and remains
explicitly unclaimed.

## EZVM-003 acquisition coverage

Normal pull-request CI exercises source acquisition entirely with deterministic
small fixtures. The suite covers matching and mismatching digests, interrupted
downloads, atomic promotion, cached-good idempotency, corrupt-cache replacement
and failure, roots containing spaces, strict manifest/release/architecture
validation, malformed provenance recovery and source-image non-mutation.

Normal CI deliberately does not download the multi-hundred-megabyte Ubuntu image.
The reviewed manifest digest is provider-reconciled when the manifest changes;
provider revalidation is separate evidence and never substitutes a freshly
downloaded checksum for the reviewed repository pin.

## EZVM-004 base-builder coverage

Normal PR CI keeps the large provider artifacts out of the fast test path. Fixture
coverage exercises:

- deterministic baseline/seed generation and provisioning-source digesting;
- explicit q35/virtio/OVMF/NoCloud QEMU argument arrays;
- WHPX-vs-explicit-TCG selection with no silent fallback;
- loopback-only seed listener, exact path/method restrictions and expiry;
- verified source/QEMU prerequisite refusal;
- staging overlay, flatten, no-backing and qemu-img-check state transitions;
- content-addressed immutable/read-only publication;
- byte-identical base reuse without replacement;
- guest/cloud-init failure and flatten failure with zero authoritative promotion;
- serial READY/tool/cleanup/build-ID evidence parsing;
- source-image non-mutation and spaces in managed roots.

A separate bounded real-provider integration run is required before EZVM-004 is
accepted. Hosted execution may use TCG to prove real Ubuntu cloud-init,
guestfwd/SMBIOS seed discovery, package provisioning, cleanup and qemu-img
flattening. Such evidence is an orchestration PASS only. WHPX remains an explicit
capability SKIP until it runs on a suitable Windows host.
## EZVM-005 storage coverage

Fast Windows CI uses deterministic QCOW2 metadata runners to exercise:

- explicit overlay/backing formats and relative backing generation;
- exact one-level chain acceptance;
- complete-root relocation without rebase;
- missing/wrong/external/deeper backing rejection;
- prepared-base digest/provenance mismatch;
- malformed machine-readable qemu-img output;
- lifecycle refusal for missing/running/transitional/unknown evidence;
- stopped-only integrity results without repair;
- replacement validation before reset mutation;
- original-overlay restoration after failed replacement promotion;
- prepared-base byte preservation and absence of commit/rebase shortcuts.

A separate bounded Windows lane bootstraps the reviewed managed QEMU runtime and
uses real `qemu-img` against tiny synthetic QCOW2 images. It proves real thin
overlay creation, machine-readable backing-chain enumeration, integrity checking,
real second-level-chain rejection, cold relocation of the storage layout, and a
reset-safe replacement. EZVM-005 performs no guest execution, so WHPX is not an
applicable acceptance capability.

## EZVM-006 runtime coverage

Fast Windows CI uses injected QEMU-process and QMP boundaries to cover explicit
WHPX/TCG argv, headless q35/virtio/UEFI configuration, host-local management,
CREATED-to-RUNNING start, duplicate-start refusal, backing-chain refusal before
launch, graceful powerdown, bounded shutdown without kill, stale PID, PID reuse,
argv fingerprint mismatch, corrupt runtime state, untracked QEMU ownership,
startup timeout, lifecycle-lock contention and storage-guard integration.

A separate bounded Windows smoke lane uses the reviewed repository-local QEMU
binary under explicit TCG to exercise the real host management transport and
Windows process-command-line observation. Hosted CI must report WHPX execution as
SKIP unless the runner actually exposes a usable WHPX environment; TCG smoke
evidence is not WHPX evidence.


## EZVM-007 SSH/network coverage

Fast Windows CI covers:

- explicit `hostfwd=tcp:127.0.0.1:<port>-:22` and instance NoCloud guestfwd;
- loopback-only seed transport through the existing seed-server suite;
- public-key-only instance seed generation with exact identity markers;
- scoped strict known-hosts argv and absence of
  `StrictHostKeyChecking=no`;
- first-use candidate trust, port-independent trusted key continuity and
  unexpected host-key replacement refusal;
- command/scp argument boundaries including spaces and shell-significant
  characters;
- authenticated identity mismatch;
- cloud-init incomplete, failed and completed states;
- total readiness timeout;
- remote non-zero exit propagation versus SSH transport exit 255;
- configured-range port collision handling;
- explicit missing OpenSSH-tool remediation.

EZVM-007 does not claim WHPX execution on GitHub-hosted runners. Any bounded
software-virtualization qualification must identify TCG explicitly; construction
tests and TCG evidence do not become a WHPX PASS.

## EZVM-008 registry/concurrency coverage

Fast control-plane coverage now includes:

- conservative valid/invalid instance names and Windows reserved names;
- default profiles plus explicit CPU/RAM overrides;
- complete durable instance-intent round-trip and legacy-schema refusal;
- registry reconstruction from instance directories and fail-closed
  directory/intent disagreement;
- relocation of durable instance state without old-root absolute paths;
- several instances receiving distinct persisted SSH reservations;
- collision avoidance against a real unrelated loopback listener;
- competing allocation-lock attempts and stale lock-file reuse;
- orchestration of multiple independently RUNNING synthetic QEMU owners with
  distinct persisted SSH forwards.

These tests exercise concurrency/state construction without claiming WHPX
execution. Real guest/network qualification remains owned by the relevant
bounded QEMU workflows.

## EZVM-009 coding-profile coverage

Fast Windows PowerShell 5.1 and PowerShell 7 coverage includes:

- strict profile schema, supported name/version and complete required-command
  validation;
- deterministic manifest/recipe source digesting across CRLF and LF checkouts;
- generated public-key-only NoCloud content, locked coder password, guest sudo
  policy and predictable home/workspace paths;
- source rejection for private-key/token-like material and unresolved
  placeholders;
- separate resource and coding-profile identities in durable intent and
  version 2 guest/access state;
- full ready-document completion and identity validation, including mismatched
  instance/base/profile/version/digest and malformed evidence;
- missing-tool and failed live-profile refusal without retaining stale READY or
  promoting SSH trust;
- non-zero cloud-init status and late-success refusal within the unchanged
  total readiness deadline;
- legacy `ezvm-core` intent remaining inspectable/stoppable while unsupported
  starts fail without rewriting that intent or its overlay.

`Profiles.Tests.ps1` owns profile source and seed contracts;
`CodingReadiness.Tests.ps1` owns the additional readiness/parser adversarial
cases. The existing SSH, runtime and registry suites cover their updated
boundaries. Static or mocked guest checks alone cannot prove real provisioning
idempotence, effective privilege policy or usable Python venv support.

The separate `EZVM-009 real coding-profile qualification` workflow runs
`scripts/Invoke-EzVm009RealProfile.ps1` on Windows using the reviewed managed
QEMU runtime and explicit TCG. Its job is labelled
`Real coding-default profile (Windows TCG; WHPX SKIP)`. It builds the accepted
base, creates a normal coding-default instance, validates versioned READY and
account/workspace/SSH/sudo policy, creates a real Python venv and compiles small
C/C++ programs. It repeats provisioning while preserving a workspace sentinel,
stops/restarts the guest, and removes a required tool temporarily to prove stale
readiness cannot pass. The qualification restores that tool, verifies recovery
and shuts the guest down cleanly.

The existing base-build bound remains 2400 seconds and each launch-readiness
bound remains 900 seconds. The enclosing workflow is bounded at 90 minutes to
include provisioning, restart and negative/recovery checks. A failure stays a
failure; only the unavailable WHPX execution capability is an explicit SKIP.
The workflow's existence is not acceptance evidence: retain the successful run
URL and exact tested commit in the PR/issue before claiming EZVM-009 qualified.
No live vendor account or credential is used as a persistence test fixture.

## EZVM-010 portability coverage

Fast control-plane coverage owns public reset/clone/export/import/portability
parsing, lifecycle locks and running/unknown refusal, transaction rollback,
immutable snapshot provenance, standalone QCOW2 header boundaries, optional
export-manifest validation, relocation of stopped runtime evidence and explicit
identity generations. The copied-guest readiness tests keep source identities
unacceptable, distinguish narrowly valid initialization-pending evidence from
malformed proofs, preserve managed trust on failure and enforce the shared
absolute launch deadline through identity adoption.

The separate `EZVM-010 real portability qualification` workflow runs
`scripts/Invoke-EzVm010RealPortability.ps1` on Windows with the reviewed managed
QEMU runtime. Its job is named
`Real QCOW2 and Ubuntu portability (Windows TCG; WHPX SKIP)`. It first uses tiny
real QCOW2 images to prove reset/fresh/stateful content semantics, source
independence, no backing file after export, matching manifest digest/size,
standalone import, malformed/external-backing refusal and data preservation
after a refused export. It also proves that fresh/reset on a sensitive snapshot
returns to that snapshot's saved baseline.

The same isolated root, whose path contains spaces, builds one real Ubuntu base
and executes five sequential guest starts: source, reset source, stateful clone,
imported export, and relocated clone. The scenario verifies:

- live running-source transformation/portability refusal;
- absence of the source workspace, synthetic auth and outbound SSH fixtures
  after reset to the clean base;
- copied workspace preservation after source reset;
- byte preservation of clearly synthetic auth and outbound SSH fixtures across
  clone, import and relocation, independently checked using SHA-256;
- exact destination controller public key in managed inbound `authorized_keys`;
- distinct cloud/machine/SSH host identity for reset, clone and import;
- an imported copy independent of later clone-only changes;
- complete stopped source/runtime copy to a different root with spaces,
  preserving relative chains and durable intent without metadata deletion or
  rebase;
- successful relocated READY with regenerated executable paths and unchanged
  guest identity, original sentinel and independent clone sentinel;
- clean final shutdown and whole-bundle validation.

The accepted base-build bound remains 2400 seconds and each launch-readiness
bound remains 900 seconds, including any required first-generation reboot.
The enclosing workflow has a 150-minute limit for one build, five starts,
storage transformations and cleanup. There is no automatic qualification retry
or conversion of failures into skips. WHPX execution alone is explicitly SKIP;
TCG proves orchestration and correctness, not WHPX performance. Source tests and
the presence of this workflow are not acceptance evidence: retain the actual
successful run URL and exact tested commit before claiming the real scenario
passed. Only synthetic content is used; no vendor credentials are involved.

## EZVM-011 hardening qualification

`Security.Tests.ps1` and `Recovery.Tests.ps1` add executable negative coverage
for cache/JSON redirection, dangling links and ancestor escape, safe cleanup,
Windows ADS/device spellings, exact ACL/hard-link refusal, public/private pairing,
staged transfer failure, installed executable/DLL/firmware tampering, legacy
receipt refusal, acquisition-stage revalidation, token-free base inputs,
bounded seed lifetime/client/log state, diagnostic redaction and preserved
reset/staging evidence. Existing storage/portability tests retain running-image,
PID reuse, interrupted replacement and one-level-chain coverage. Both required
Windows PowerShell lanes run the Windows-only cases; non-Windows skips are not
Windows qualification.

The owner-approved expensive qualification runs the existing complete real
portability scenario with `-SecurityQualification` on Avrea Windows 2025 8-vCPU.
It retains all twelve acceptance markers and the 2400-second build / 900-second
READY bounds. Additional checks use actual SSH/SCP for a binary file round trip,
preserve an existing host destination after remote transfer failure, reject
copying into managed runtime, and refuse diagnostic image checking while running.
No real credentials, uploaded disks or relaxed acceptance thresholds are involved.
WHPX execution remains explicitly SKIP; TCG is not WHPX qualification.
