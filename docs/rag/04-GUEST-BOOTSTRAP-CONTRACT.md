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
- openssh-server and the OpenSSH client tools required by guest control.

The `coding-default` version 1 profile validates the accepted stable baseline
without installing it again. Node, Rust, uv and vendor-specific agent CLIs are
outside this profile. Adding one requires an explicit reviewed acquisition and
version policy; an unpinned remote shell installer is not an accepted extension.

## Instance first boot

Ordinary instance overlays start from a cloud-init-clean prepared base. Explicit
stateful clones/imports can start from an immutable snapshot with existing guest
state; EZVM-010 initializes their destination identity as specified below.

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
- the complete versioned ezvm identity matches the requested instance, base,
  resource profile and coding profile name/version/digest;
- the coding readiness document matches that identity and records completed
  provisioning;
- fresh guest checks prove the required tools, account policy and writable
  workspace are usable.

## Failure behavior

Provisioning failure preserves logs and the staging overlay for diagnosis where safe.

A failed or partially provisioned staging disk must never be promoted to an immutable prepared base.

## Implemented source acquisition contract (EZVM-003)

`manifests/ubuntu-noble-amd64.json` is the reviewed v0.1 source authority. The
initial accepted pin is Canonical's dated Noble publication `20260926`,
`ubuntu-24.04-server-cloudimg-amd64.img`, with SHA-256
`6a81c37564db9b1ee84e141922625e1d7c5b389b99bb3c572e0243607d5bb4d2`.

`ezvm base acquire` downloads only to a unique temporary file under the managed
source-image cache, verifies the repository-reviewed digest, then atomically moves
verified bytes to the authoritative cache path. A valid cached object is rehashed
and reused without network access. A corrupt cache object is removed before
reacquisition; an interrupted or mismatching transfer leaves no corrupt object at
the authoritative path.

A sidecar provenance JSON records the reviewed manifest digest, provider,
release/publication identity, source URL, image digest, size and recording time.
The source image itself is not booted or modified by acquisition. "Immutable"
therefore means a managed policy enforced by repeated content verification and by
later consumers treating the source as read-only input; it does not depend on a
filesystem read-only attribute.

A checksum downloaded alongside the image is never runtime trust authority.
Updating the image pin requires a reviewed repository manifest change.

## Implemented prepared-base provisioning (EZVM-004)

The reviewed baseline recipe installs the stable development prerequisites listed
above and validates their expected commands before a base can be accepted. The
staging disk is expanded to 16 GiB so the Ubuntu first-boot grow/resize path has
room for the baseline packages.

Base provisioning does not create or inject an ezvm SSH controller key. Instead,
the guest reports build qualification through its emulated serial console. The
cloud-init `runcmd` queues a transient `Type=oneshot` systemd unit with
`systemd-run --no-block`; the non-blocking launch is mandatory because the
finalizer itself waits on `cloud-init status --wait`. A blocking oneshot launch
would deadlock cloud-final against that completion wait. Once cloud-init is done,
the finalizer validates the baseline commands, records guest OS/cloud-init
identity, removes SSH host keys and any authorized-key files, cleans cloud-init
state and machine identity, emits explicit build/TOOLS/CLEAN/READY markers, then
powers off.

The cleanup path uses `cloud-init clean --logs --machine-id`, which cloud-init
documents as golden-image practice. Where the guest cloud-init version exposes
`--seed`, it is used; the seed directory is also removed explicitly so older
Ubuntu-supported cloud-init versions are handled without depending on that newer
CLI option.

The host accepts no base unless the serial evidence proves:

- the READY marker belongs to the current random build ID;
- baseline tool validation succeeded;
- cloud-init/machine identity cleanup succeeded;
- guest OS and cloud-init version facts were returned.

This avoids treating a mere QEMU exit as provisioning success.


## Implemented instance first boot and readiness (EZVM-007 / EZVM-009)

For complete schema version 1 intent, an instance launch derives a stable cloud
instance ID from the durable instance name, base ID and creation timestamp. New
schema version 2 intent additionally binds its explicit identity generation.
Its NoCloud data supplies a
deterministic hostname, creates the locked-password `coder` account with the
ezvm controller **public** Ed25519 key, and writes
`/etc/ezvm/identity.json`. Schema version 2 contains instance, base, resource
profile and cloud instance identities plus `provisioningProfile`,
`provisioningVersion` and `provisioningDigest`. Controller private-key bytes
never enter user-data, meta-data or the prepared base.

For schema version 1 intent, a non-blocking transient systemd finalizer waits for
`cloud-init status --wait`, then applies and validates the repository-controlled
coding profile. Successful completion publishes `/var/lib/ezvm/ready.json` with
the same versioned identity and `provisioningState: complete`. Failure leaves an
explicit provisioning failure marker and no accepted READY document.

The host does not classify the guest READY from TCP reachability. It requires,
within one bounded launch-readiness deadline:

1. the localhost forwarded SSH port to accept connections;
2. authentication with the managed controller private key under scoped host-key
   verification;
3. the authenticated guest identity document to match the requested
   instance/base/resource profile/cloud instance ID and coding profile
   name/version/digest exactly;
4. `cloud-init status` to return exit code 0 and report exactly `done`;
5. for schema version 2 intent, successful finalizer completion in the current
   guest boot;
6. the complete ready document to match the same identity and record completed
   provisioning;
7. live required-tool, coder-account and workspace validation to succeed.

Identity mismatch, missing required tools or invalid account/workspace policy
cannot produce READY even if an older readiness file remains. Cloud-init or
profile failure is a hard failure. Transient startup waits and live profile
validation share one launch-readiness deadline. A successful proof returned
after that deadline is rejected.

## Versioned coding-default policy (EZVM-009)

Repository authority is `guest/profiles/coding-default/v1/profile.json` and
`provision.sh`. The host resolves an explicitly supported name/version and
rejects unknown schema fields and unsupported versions. It computes a SHA-256
over the normalized UTF-8 contents of both files, with filenames and NUL
delimiters separating them. CRLF and LF checkouts produce the same digest.
This provisioning-source identity is carried through guest identity, ready and
host access state; it is not a separately downloaded checksum. The host checks
that the guest's installed sources match the expected recipe before accepting
live validation. `light`/`normal`/`heavy` remain resource profiles with separate
meaning.

The policy requires `coder` with home `/home/coder`, Bash, a locked password and
public-key SSH. SSH password authentication is disabled. Its workspace is
`/home/coder/workspace`, owned by `coder` and writable by that account. Repeated
provisioning preserves workspace contents and does not recursively change
ownership of user files. Unsafe account/workspace state fails clearly.

The disposable guest deliberately grants `coder` unrestricted passwordless
sudo, `ALL=(ALL:ALL) NOPASSWD:ALL`. This grants root within the guest; it neither
requires Windows elevation nor grants host administrator rights. Treat every
agent running as coder as capable of modifying the whole guest and reading
other credentials stored there.

The profile checks the stable command set, Python venv support and the accepted
OpenSSH server/client configuration. It performs no package download or install
on instance first boot. User-selected agent software and authentication are
installed later into the writable overlay, as described in
[the guest guide](../CODING-GUEST.md).

Future profiles require a new reviewed version directory and explicit resolver,
schema and test support. Reuse an existing immutable base only when its baseline
already satisfies the new profile; otherwise build a new base. Existing
`ezvm-core`/`1` instances are retained for list/status/stop but start refuses
their unqualified provisioning identity. Create a new named instance instead of
silently relabelling the old overlay or changing its backing base.

## Snapshot identity initialization (EZVM-010)

New version 2 durable intent records a random `identityGeneration`. The host
derives a stable cloud instance ID and DMI UUID from that generation. Clone and
import allocate new generations; reset replaces the previous generation. Normal
stop/restart and a complete cold-root move preserve it.

Version 2 provisioning installs a persistent guest finalizer after cloud-final.
For a new generation it replaces only the managed inbound coder authorization,
generates the guest's own Ed25519 host key, writes the generation's machine/DBus
identity and performs one guest reboot so the running OS adopts that identity.
This initialization and reboot consume the existing launch-readiness deadline;
they are not a retry of a failed qualification. Later boots validate the stable
identity and key and rerun coding-profile validation without repeating the
identity reset. Complete older version 1 intent keeps its accepted bootstrap
behavior and original identity derivation.

Every version 2 launch requires the finalizer to finish successfully in the
current boot. Its service retains that completion state for the rest of the
boot. A previous boot's READY document cannot authorize early READY on normal
restart or cold relocation, even when the durable generation and guest identity
are unchanged. Waiting for current-boot completion shares the original absolute
launch-readiness deadline with cloud-init, identity and live profile checks.

The copied image's source identity, cloud-init cache and old READY marker never
qualify the destination. Before the normal strict readiness parser, a read-only
host-selected check verifies the expected DMI identity and completed adoption
of the destination generation, together with successful finalizer completion in
the current boot. Its narrowly defined pending result allows initialization and
finalization to finish within the existing bound. An unpromoted SSH
candidate learned during that transition is discarded; only final exact
identity/profile and live checks can establish managed trust and READY.

Workspace files, installed agent software and outgoing credentials are copied
state and remain intact. Identity initialization does not scrub vendor login
state. An imported guest whose cloud-init is disabled, or which trusts a manual
cache instead of consuming the destination NoCloud seed, cannot reach READY;
structural QCOW2 acceptance is separate from supported coding-guest bootstrap.

## Base input and seed cleanup (EZVM-011)

Both reviewed base seed templates and coding-profile sources are bounded UTF-8
inputs and reject high-confidence private-key/token patterns before generation.
Only the controller public key is supplied to an instance. Base-build seed files
are removed in final cleanup after success or failure; remaining staging disks,
serial logs and redacted failure summaries are retained for diagnosis. This
supersedes the older optional retention of base-build seed files. An in-memory
seed server is always stopped at the caller's completion/timeout boundary and
releases its payload references; this is not a promise of cryptographic memory
erasure, pagefile erasure or removal of guest-side cloud-init records.

## Disposable Python capability probe

The coding profile still creates an ordinary isolated Python virtual environment,
including the standard **offline ensurepip bootstrap**, then executes its own
interpreter-isolation assertion and `python -m pip --version`. Neither
`--without-pip`, system-site-package inheritance, cached READY nor a downloaded
installer can substitute for those live checks. They run as the unprivileged
coding account on every provision and live validation.

The per-invocation, mode-0700 scratch directory prefers the existing `/run`
filesystem only when it is `tmpfs`; the parent must pass the normal root-ownership,
no-symlink and no-group/world-write checks. Otherwise the already-validated
`/var/lib/ezvm` disk location remains the fallback. No mount is created or changed.
`TMPDIR` also directs nested ensurepip temporary files into that private directory.
The interpreter is explicitly symlinked and invoked with `-I`; the probe executes
modules through that interpreter rather than executable scripts on a potentially
`noexec` scratch mount. The independent disk-backed workspace read/write test is
unchanged. Tmpfs avoids needless transient disk writes, not CPU work, and may use
swap under memory pressure; it is not a guarantee of TCG performance.

All three commands share the unchanged **90-second** timeout. Only this disposable
probe process group is hard-stopped on expiry; the guest finalizer/cleanup and
QEMU are outside it. This avoids a terminating shell abandoning a still-running
bootstrap descendant. There is no extra success grace period. A nonzero exit,
including KILL status 137, remains failure, removes stale READY and cleans owned
scratch. Status 137 alone cannot distinguish the deadline from an external kill.
Fixed storage/stage markers and numeric child/outer exit codes are emitted; raw
child output is suppressed, not copied into public diagnostics.

The recipe edit changes the normal provisioning-source digest. Existing installed
source/identity/READY digest comparisons remain mandatory; no stale evidence is
accepted and no durable intent, image or profile version is silently relabelled.
The host's 2400-second base-build and 900-second launch deadlines are unchanged.

`tests/guest/test_venv_probe.py` executes the extracted production probe and cleanup
with explicit filesystem/account adapters in disposable Linux fixtures. Native
cases exercise real venv/ensurepip/pip as a non-root account on tmpfs and disk;
process fault cases cover phase failures, short fixture deadlines, descendants,
unsafe parent paths and stale-READY invalidation. Core CI runs these alongside,
not instead of, the Windows PowerShell suites and full Windows TCG qualification.
See the [failure and evidence record](../research/TRIO-2026-10/DASH-02-VENV-PROBE.md).
