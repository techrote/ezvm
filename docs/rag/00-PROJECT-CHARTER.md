# 00 — Project charter

## Mission

ezvm provides the smallest practical portable virtual-machine workflow for coding agents on Windows:

- clone/copy one folder to another compatible Windows PC;
- bootstrap a private QEMU runtime into that folder;
- build or acquire one verified immutable Linux base;
- create cheap disposable QCOW2 instance overlays;
- run headless accelerated VMs;
- control them through SSH;
- reset, clone and move environments without a conventional hypervisor installation.

## Primary user story

A user keeps ezvm and its runtime directory on a normal local disk or portable storage. On a Windows x86-64 host with hardware virtualization and Windows Hypervisor Platform enabled, the user can create an agent VM, start it, SSH/exec into it, stop it, reset it and move the complete ezvm folder to another compatible host.

## v0.1 goals

- Windows 10 2004+ and Windows 11 x86-64 host support where QEMU WHPX is supported.
- No required system-wide QEMU installation.
- PowerShell control plane.
- QEMU WHPX acceleration.
- Ubuntu Server 24.04 LTS amd64 guest baseline.
- Official Ubuntu cloud image as the root source artifact.
- Hash-pinned external artifact acquisition.
- Reproducible prepared base construction.
- Thin one-level QCOW2 overlays.
- Headless operation.
- User-mode NAT with localhost-only SSH forwarding.
- Multiple concurrent named instances.
- Safe create/start/status/ssh/exec/stop/reset/clone/export/import workflows.
- Tests that can run on ordinary GitHub-hosted CI, with explicit capability skips where nested virtualization is unavailable.

## Non-goals for v0.1

- GUI VM management.
- Windows guests.
- macOS/Linux host support.
- ARM host or guest support.
- TAP/bridge networking.
- LAN-facing services by default.
- GPU passthrough or USB passthrough.
- Live migration.
- Suspend/resume VM-state portability.
- Multi-level snapshot trees.
- Kubernetes, Docker or WSL as required components.
- Treating the VM boundary as a complete sandbox against hostile kernel-level guest workloads.

## Design principles

### Portable by layout

The repository and generated runtime state use relative relationships wherever QEMU safely supports them. Moving the top-level folder between drive letters must not require editing every instance.

### Rebuildable over artisanal

Do not rely on a hand-maintained golden image whose provenance is unknown. A prepared base is generated from a pinned official source image plus repository-controlled provisioning.

### Immutable bases

Once overlays exist, their backing base must not be modified in place. New base revisions get new immutable identities.

### Thin disposable instances

Normal instance state belongs in a QCOW2 overlay, not in a full base copy.

### Least host integration

Only Windows Hypervisor Platform enablement is expected to require one-time administrative configuration. Normal ezvm operation must not require elevation.

### Safe defaults

Networking is NATed, SSH binds to localhost, secrets stay out of git, destructive commands validate state, and ambiguous conditions fail closed.

## Success criteria for v0.1

From a fresh repository checkout on a compatible Windows host, a user can:

1. run doctor and receive precise prerequisite status;
2. bootstrap the pinned QEMU runtime;
3. acquire and verify the pinned Ubuntu source image;
4. build the prepared coding-agent base;
5. create two named instances;
6. run both concurrently with unique SSH ports;
7. execute commands in each guest over SSH;
8. stop and restart them without state loss;
9. reset one instance without affecting the other;
10. copy the stopped ezvm folder to another compatible path/drive and start the instances there;
11. export an independent instance image when backing-file independence is required.

## Upstream references

- QEMU downloads: https://www.qemu.org/download/
- QEMU Windows Hypervisor Platform: https://www.qemu.org/docs/master/system/whpx.html
- QEMU disk images: https://www.qemu.org/docs/master/system/images.html
- qemu-img: https://www.qemu.org/docs/master/tools/qemu-img.html
- QEMU user networking: https://www.qemu.org/docs/master/system/qemu-manpage.html
- Ubuntu cloud images: https://cloud-images.ubuntu.com/releases/noble/
- cloud-init QEMU how-to: https://docs.cloud-init.io/en/latest/howto/launch_qemu.html
- cloud-init NoCloud: https://docs.cloud-init.io/en/latest/reference/datasources/nocloud.html
