# 04 — Guest bootstrap contract

## Source guest

v0.1 uses an official Ubuntu Server 24.04 LTS amd64 cloud image.

Use the released-image channel, not an unpinned daily image, for normal base construction.

References:

- https://cloud-images.ubuntu.com/releases/noble/
- https://docs.cloud-init.io/en/latest/howto/launch_qemu.html
- https://docs.cloud-init.io/en/latest/reference/datasources/nocloud.html
- https://docs.cloud-init.io/en/latest/reference/cli.html

## Source pinning

manifests/ubuntu-noble-amd64.json must identify an exact source artifact, not merely a mutable current URL.

Record at least:

- schema version;
- Ubuntu release;
- architecture;
- dated source URL;
- expected SHA-256;
- source filename;
- source publication/release identifier.

Normal acquisition verifies the embedded expected digest before the image is accepted into runtime/cache/source-images.

Updating the pin is a repository change subject to review.

## Why cloud images

The official cloud image already provides:

- a bootable Ubuntu Server system;
- cloud-init;
- virtio-capable Linux drivers;
- a compact source image suitable for QEMU.

This avoids interactive OS installation.

## NoCloud transport

Do not add an ISO-generation dependency merely to feed cloud-init.

cloud-init supports NoCloud seed discovery through SMBIOS/DMI and an HTTP seed URL. QEMU user networking exposes a guest-visible host/gateway and supports guest forwarding.

The implementation should provide user-data and meta-data from a temporary minimal host-side HTTP server, and inject a NoCloud seed URL via SMBIOS.

Seed URLs must include a trailing slash.

The seed server is temporary and serves only the expected cloud-init files.

## Prepared-base build

The prepared base is not the downloaded Ubuntu source image.

Build sequence:

1. verify the pinned source image;
2. create a temporary writable QCOW2 overlay on the source;
3. generate build-specific cloud-init metadata/user-data;
4. boot the staging VM under the normal QEMU runtime;
5. wait for cloud-init completion and an explicit ezvm provisioning success marker;
6. run validation inside the guest;
7. remove transient credentials and build-only material;
8. clean cloud-init state so cloned instances receive first-boot identity again;
9. reset machine identity using supported cloud-init clean behavior;
10. shut the guest down cleanly;
11. flatten/convert the staging disk chain into a new standalone prepared base;
12. verify the prepared base has no backing file;
13. hash the prepared base and write its manifest;
14. mark it immutable by policy and never boot it writable.

cloud-init documents cloud-init clean --machine-id as best practice when preparing a golden image. The implementation must also clean the datasource/seed state required for first-boot instance provisioning.

## Base provenance manifest

Each prepared base manifest records:

- base ID;
- schema version;
- source-image manifest identity and digest;
- provisioning source revision or digest;
- QEMU version;
- build timestamp;
- guest OS identification;
- guest cloud-init version;
- installed baseline tool/profile version;
- resulting base digest;
- virtual size.

The base ID must not be reused for different content.

## Base provisioning scope

Base provisioning should contain stable, generally useful development prerequisites, for example:

- ca-certificates;
- curl/wget;
- git;
- build-essential;
- cmake;
- ninja-build;
- Python 3 and venv support;
- jq;
- ripgrep;
- unzip/zip;
- rsync;
- tmux;
- openssh-server.

Language/toolchain ecosystems that change rapidly should be controlled by the guest coding profile rather than silently drifting in the base.

## Instance first boot

Each instance overlay starts from a cloud-init-clean prepared base.

Instance-specific cloud-init supplies:

- unique instance-id;
- hostname;
- coder user policy;
- controller public SSH key;
- instance marker containing ezvm/base/profile identity;
- any small instance-specific configuration.

Private SSH keys are never included in the prepared base or cloud-init data served to the guest.

## Readiness

A VM is not READY merely because TCP port 22 accepts a connection.

Readiness requires:

- SSH authentication works;
- cloud-init reports completion;
- the expected ezvm instance marker exists;
- instance identity matches the requested instance;
- optional coding profile readiness marker is valid.

## Failure behavior

Provisioning failure preserves logs and the staging overlay for diagnosis where safe.

A failed or partially provisioned staging disk must never be promoted to an immutable prepared base.
