# ezvm implementation programme

## Programme objective

Deliver v0.1 of a portable Windows-first QEMU + QCOW2 coding-agent VM manager through dependency-ordered GitHub issues. Every issue is intended to be executable by a coding agent without additional design assistance.

## Plan review

The initial concept was:

- portable QEMU folder;
- one Ubuntu golden QCOW2 image;
- thin per-agent overlays;
- headless QEMU/WHPX;
- user networking and SSH;
- PowerShell helpers for create/start/reset/clone.

That concept is sound, but a design review identified failure modes that should be fixed before implementation.

### Review finding 1 — a hand-built golden image is opaque

A manually installed base is easy once but difficult to rebuild, audit or update.

Improvement: build the prepared base from a pinned official Ubuntu cloud image plus repository-controlled cloud-init/provisioning.

### Review finding 2 — bundling or normally installing QEMU defeats portability

Committing QEMU binaries would bloat the repository and obscure provenance. Executing the current Windows NSIS installer as an installer also conflicts with ezvm's no-system-install goal because that path requests administrator execution and writes machine installation metadata.

Improvement: keep QEMU out of git. Pin the exact Windows QEMU package and digest, and separately pin an official standalone 7-Zip extractor and digest. Verify both before use, extract the verified NSIS package into repository-local staging without running the installer, validate the QEMU binaries, then promote the payload into runtime/qemu. Normal bootstrap therefore requires no registry writes, PATH mutation or elevation.

### Review finding 3 — a cloud-init ISO generator creates an unnecessary dependency

Improvement: use cloud-init NoCloud seed discovery through SMBIOS and a temporary host HTTP endpoint reachable from QEMU user networking. No mkisofs/cloud-localds dependency is required on Windows.

### Review finding 4 — arbitrary QCOW2 chains become fragile when moved

Improvement: v0.1 allows one backing level only: immutable prepared base -> mutable instance overlay. Use relative backing paths where appropriate and validate the complete chain before start.

### Review finding 5 — copying or resetting a running VM risks corruption

Improvement: model VM lifecycle explicitly, validate QEMU process identity and forbid storage mutation while a VM is running or ambiguous.

### Review finding 6 — bridged networking adds host configuration and attack surface

Improvement: use QEMU user-mode NAT by default. Bind SSH forwarding to 127.0.0.1. Keep TAP/bridging out of v0.1.

### Review finding 7 — portability needs schema and relocation tests, not only relative paths

Improvement: persistent JSON state has schemaVersion, generated runtime state is separable, and CI tests roots with spaces plus simulated drive/root relocation.

### Review finding 8 — CI cannot assume WHPX is available

Improvement: separate pure/control-plane coverage from accelerator smoke coverage. CI must report capability-based SKIP honestly and can use TCG only for bounded integration tests.

## Improved target architecture

~~~text
repository source + manifests
          |
          +--> verified/extracted QEMU runtime
          |
          +--> pinned Ubuntu cloud source
                      |
                      v
             reproducible base builder
                      |
                      v
             immutable prepared base
                /       |       \
               v        v        v
          overlay A overlay B overlay C
               |        |        |
               +--- QEMU/WHPX ----+
                       |
                 user-mode NAT
                       |
              localhost SSH ports
~~~

## Issue dependency graph

~~~text
EZVM-001
  ├── EZVM-002
  └── EZVM-003

EZVM-002 + EZVM-003
        |
     EZVM-004
        |
     EZVM-005

EZVM-002 + EZVM-005
        |
     EZVM-006
        |
     EZVM-007
        |
     EZVM-008

EZVM-004 + EZVM-007
        |
     EZVM-009

EZVM-005 + EZVM-008
        |
     EZVM-010

EZVM-006..010
        |
     EZVM-011
        |
     EZVM-012
~~~

## Issue catalogue

| Code | GitHub | Title | Depends on | Primary outcome |
| --- | --- | --- | --- | --- |
| EZVM-001 | [#2](https://github.com/techrote/ezvm/issues/2) | Repository foundation, CLI skeleton and CI contract | none | Testable PowerShell project skeleton and baseline CI |
| EZVM-002 | [#3](https://github.com/techrote/ezvm/issues/3) | Portable QEMU acquisition and Windows host preflight | 001 | Verified repository-local QEMU plus doctor |
| EZVM-003 | [#4](https://github.com/techrote/ezvm/issues/4) | Pinned Ubuntu cloud-image acquisition and verification | 001 | Immutable verified source-image cache |
| EZVM-004 | [#5](https://github.com/techrote/ezvm/issues/5) | Reproducible prepared-base builder with cloud-init | 002, 003 | Rebuildable coding-agent base image |
| EZVM-005 | [#6](https://github.com/techrote/ezvm/issues/6) | QCOW2 overlay lifecycle and integrity tooling | 004 | Create/inspect/reset-safe thin disks |
| EZVM-006 | [#7](https://github.com/techrote/ezvm/issues/7) | Headless QEMU runtime, state machine and graceful shutdown | 002, 005 | Reliable VM start/status/stop |
| EZVM-007 | [#8](https://github.com/techrote/ezvm/issues/8) | User-mode networking, SSH readiness, exec and file transfer | 006 | Usable headless guest control |
| EZVM-008 | [#9](https://github.com/techrote/ezvm/issues/9) | Instance registry, resource profiles and concurrent port allocation | 005, 007 | Multiple safe concurrent named agents |
| EZVM-009 | [#10](https://github.com/techrote/ezvm/issues/10) | Guest coding-agent provisioning profile and readiness contract | 004, 007 | Useful repeatable coding environment |
| EZVM-010 | [#11](https://github.com/techrote/ezvm/issues/11) | Clone, reset, export, import and relocation-safe portability | 005, 008 | Practical disposable/copyable VM workflow |
| EZVM-011 | [#12](https://github.com/techrote/ezvm/issues/12) | Security hardening, secret boundaries and failure recovery | 006-010 | Fail-closed destructive operations and recovery |
| EZVM-012 | [#13](https://github.com/techrote/ezvm/issues/13) | End-to-end qualification, packaging and v0.1 release | 011 | Release evidence and portable package workflow |

## Parallelism

After EZVM-001, EZVM-002 and EZVM-003 may proceed in parallel.

Most later tasks intentionally serialize around the base and disk contracts. Avoid parallel implementation that edits the same lifecycle/state modules until their dependency is merged.

## Definition of done for every issue

The issue body is an execution prompt, not merely a feature description.

Each issue must:

- reconcile live repository state before implementation;
- read AGENTS.md and every referenced RAG document;
- implement all in-scope behavior;
- add tests for acceptance criteria;
- update RAG docs if contracts change;
- run the repository test suite;
- perform a final diff/risk review;
- create a dedicated PR with Closes #<issue>;
- monitor and fix automated checks;
- merge only when required CI is green;
- verify post-merge main state;
- avoid claiming unexecuted capability checks passed.

## v0.1 release gate

EZVM-012 may tag/release v0.1 only when the repository demonstrates:

- deterministic manifest verification;
- clean base build contract;
- valid QCOW2 chain operations;
- safe lifecycle state handling;
- concurrent unique SSH forwarding;
- reset/clone/export/import semantics;
- relocation tests;
- no committed generated runtime data or credentials;
- user documentation sufficient to bootstrap on a fresh compatible Windows host.
