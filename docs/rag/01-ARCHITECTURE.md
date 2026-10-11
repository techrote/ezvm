# 01 — Architecture

## High-level model

ezvm has four layers:

1. repository-controlled source and manifests;
2. downloaded host runtime and source-image cache;
3. immutable prepared bases;
4. mutable per-instance overlays and state.

The repository controls behavior. Generated runtime state is intentionally untracked.

## Target layout

~~~text
ezvm/
├── ezvm.ps1
├── src/
│   └── EzVm/
├── config/
│   └── defaults.json
├── manifests/
│   ├── qemu-windows.json
│   └── ubuntu-noble-amd64.json
├── guest/
│   ├── base-cloud-init/
│   └── instance-cloud-init/
├── tests/
├── docs/
├── runtime/                       # gitignored
│   ├── qemu/
│   ├── cache/
│   │   ├── downloads/
│   │   └── source-images/
│   ├── keys/
│   ├── bases/
│   │   └── <base-id>/
│   │       ├── base.qcow2
│   │       └── manifest.json
│   ├── instances/
│   │   └── <name>/
│   │       ├── disk.qcow2
│   │       ├── instance.json
│   │       ├── runtime.json
│   │       └── logs/
│   └── locks/
└── .github/
~~~

Exact names may evolve through accepted issues, but ownership boundaries must remain clear.

## Control plane

The public entry point is ezvm.ps1. Implementation should be decomposed into modules instead of a monolithic script.

Logical subsystems:

- configuration and path resolution;
- manifest/download verification;
- host capability detection;
- QEMU command construction;
- qemu-img operations;
- cloud-init seed serving;
- instance registry and port allocation;
- process/state lifecycle;
- SSH/exec/copy helpers;
- portability/export/import operations.

## Source image and prepared base

The Ubuntu source image is an upstream artifact and remains immutable.

A prepared base is produced by a controlled build:

~~~text
pinned Ubuntu source
        |
        v
temporary provisioning overlay
        |
        +-- boot with cloud-init
        +-- install common coding dependencies
        +-- clean instance identity/cloud-init state
        +-- shut down cleanly
        |
        v
qemu-img convert/flatten
        |
        v
immutable prepared base
~~~

The resulting prepared base receives a stable base ID and manifest containing provenance.

## Instance disk model

v0.1 deliberately uses only:

~~~text
prepared-base.qcow2  <-  instance/disk.qcow2
~~~

No child overlays of instance overlays.

This makes reset, relocation validation and corruption diagnosis tractable.

## Runtime state model

Persistent configuration and ephemeral process state are separate.

instance.json contains durable instance intent such as:

- schema version;
- instance name;
- base ID;
- CPU count;
- memory;
- assigned SSH port;
- creation timestamp;
- optional profile name.

runtime.json is replaceable process state such as:

- QEMU PID;
- process start timestamp;
- QEMU executable path;
- QEMU argument fingerprint;
- last observed lifecycle state.

A stale runtime.json is never sufficient evidence that a process is the VM. Process identity must be revalidated.

## Lifecycle

Expected states:

~~~text
ABSENT
  -> CREATED
  -> STARTING
  -> RUNNING
  -> STOPPING
  -> STOPPED

CREATED/STOPPED -> RESETTING -> CREATED
STOPPED -> CLONING/EXPORTING
~~~

Destructive storage operations are forbidden while the instance is STARTING, RUNNING or STOPPING.

## Portability boundary

A portable copy consists of repository source plus runtime state while all VMs are cleanly stopped.

Saved CPU execution state is not portable scope. Portability means disk/configuration portability, not live-state migration.

## Concurrency

Multiple instances may run simultaneously. Any resource allocated globally within an ezvm root, especially host-forwarded ports and lock files, must use atomic allocation or equivalent collision prevention.

## Compatibility philosophy

Configuration and state schemas carry schemaVersion fields. Breaking changes require an explicit migration path or a clear refusal with remediation. Silent reinterpretation of old state is not allowed.
