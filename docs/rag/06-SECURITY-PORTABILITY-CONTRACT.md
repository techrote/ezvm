# 06 — Security and portability contract

## Threat model

ezvm is designed to isolate normal coding-agent workloads from the Windows host more strongly than running those tools directly on the host.

It is not a claim of perfect containment against a malicious guest kernel, a QEMU/WHPX vulnerability, hostile firmware or compromised upstream binaries.

## Trust boundaries

Trusted/control-plane material:

- repository source and reviewed manifests;
- managed QEMU runtime after digest verification;
- verified Ubuntu source image;
- prepared-base provenance;
- host-side ezvm SSH private key.

Mutable/untrusted or semi-trusted material:

- coding-agent instance overlays;
- downloaded source repositories inside guests;
- package-manager content;
- agent-generated files;
- guest network traffic.

## Secrets

Never commit:

- private SSH keys;
- API keys;
- GitHub tokens;
- cloud credentials;
- agent login state;
- .env files;
- generated cloud-init containing secrets;
- full runtime directories.

Prepared bases must not contain user authentication tokens.

Per-instance agent credentials may live in that instance overlay if the user
chooses to authenticate there. They survive normal stop/restart and are lost when
reset replaces the overlay. An intentional stateful clone/export can preserve
them along with other guest data, so that copy is sensitive. Public
reset/clone/export/import commands remain EZVM-010 work; documenting their
contract does not make those commands available yet.

## Default host exposure

- SSH forward binds to 127.0.0.1.
- Cloud-init seed service remains host-local and is guest-forwarded.
- No shared host filesystem is mounted into guests by default.
- No SMB host sharing by default.
- No clipboard integration by default.

## QEMU security options

Do not disable QEMU/WHPX security mitigations merely for speed as a default.

Any performance option that weakens documented isolation must be opt-in, named accordingly and documented with the tradeoff.

## Destructive-operation safeguards

reset, destroy, rebase-like repair, import replacement and similar operations must:

1. resolve the named instance exactly;
2. validate instance state/schema;
3. prove the relevant QEMU process is not running;
4. validate target paths are inside the managed runtime root;
5. refuse symlink/junction/path traversal surprises where they could redirect deletion;
6. use bounded/atomic replacement strategy;
7. leave diagnostic evidence on failure.

Never recursively delete a path derived from unchecked user input.

## PID reuse

A stored PID is not enough to identify a running instance.

Validate process identity using available Windows process metadata, including executable path and other recorded launch fingerprints. If identity is ambiguous, report UNKNOWN/STALE and refuse destructive operations until reconciled.

## Portability definition

Supported portability is cold portability.

All VMs must be cleanly stopped before copying the ezvm root.

A valid moved root contains:

- source/control plane;
- managed QEMU runtime if already bootstrapped;
- source cache as desired;
- prepared bases;
- instance overlays;
- durable instance configuration;
- bundle-scoped SSH trust/key material if the user wants identities to move with it.

Do not copy transient lock/PID state as authoritative runtime truth. It is revalidated/regenerated on the destination.

## Relocation test

At minimum, automated tests simulate:

- source root A with spaces;
- target root B with a different prefix/drive-like path;
- unchanged relative base/overlay layout;
- regenerated absolute QEMU invocation paths;
- preserved valid relative QCOW2 backing reference.

## Export safety

An exported standalone instance may contain credentials and source code from inside the guest.

The export command must warn/document that fact and never upload/share automatically.

## Supply chain

External downloads are pin-controlled.

Normal bootstrap must not execute a downloaded QEMU installer before its expected digest matches.

Normal source-image acquisition must not boot an Ubuntu image before its expected digest matches.

Manifest refresh is a reviewed source change, not an automatic trust-on-first-use update.

## Failure recovery

Recovery commands distinguish:

- stale runtime metadata;
- missing base;
- backing mismatch;
- dirty/unclean image;
- failed cloud-init;
- failed QEMU start;
- SSH identity mismatch;
- port collision.

Diagnostics should preserve evidence rather than immediately deleting the artifact that explains the failure.

## Prepared-base credential boundary (EZVM-004)

The base-build cloud-init recipe contains no private key, API token, GitHub token
or commercial-agent credential. Host control of the build does not require SSH.

Before READY, guest finalization removes generated SSH host keys and
`authorized_keys` files, then cleans cloud-init and machine identity. The
resulting prepared base therefore carries neither controller authentication nor a
build-specific SSH identity.

Failed build staging may retain seed text and serial diagnostics under
`runtime/bases/.build-*` for diagnosis. The reviewed base-build seed is
credential-free by construction; future work must not reuse this retention policy
for secret-bearing instance seeds without explicit redaction/cleanup rules.

Prepared-base manifests store artifact/provisioning hashes and version identities,
not host absolute paths or credentials. Normal cold relocation therefore derives
all executable and disk paths again from the moved ezvm root.
## EZVM-005 storage path and lifecycle safeguards

Storage operations canonicalize paths for containment decisions while preserving
relative QCOW2 backing names for portability. Managed instance/base paths are
checked against the current ezvm root, and existing path segments are refused if
they are reparse points that could redirect storage access outside the managed
tree.

Instance names are constrained before filesystem paths are derived. Destructive
or offline-mutating storage operations require a versioned lifecycle guard whose
state is explicitly `proven-safe`; absent metadata is not interpreted as
stopped. RUNNING, STARTING, STOPPING and UNKNOWN/ambiguous evidence all refuse
mutation or `qemu-img check`.

Reset promotion uses same-filesystem file renames and preserves the old overlay
until a replacement chain has fully validated. If promotion cannot complete, the
implementation restores the original where possible and otherwise reports the
exact recovery artifact instead of guessing or deleting evidence.

## Runtime process identity and management boundary (EZVM-006)

`runtime.json` is process evidence, not process authority. A recorded active
launch is accepted only when Windows process observation proves all of:

- the recorded PID still identifies one process;
- the process executable is the managed QEMU executable;
- its creation/start time matches the recorded launch;
- its observed argv still contains this instance's QEMU name marker;
- a SHA-256 fingerprint of the observed argv matches the recorded launch.

Missing/reused/fingerprint-mismatched evidence is STALE when there is no distinct
owner candidate. A separate QEMU process carrying the same instance marker, a
corrupt runtime file, or an unqueryable process identity is UNKNOWN. Both states
fail closed for storage mutation.

QMP management binds explicitly to `127.0.0.1` on an ephemeral runtime port and is not exposed on a LAN interface. The public
lifecycle surface exports graceful start/status/stop, not a generic QMP `quit`
shortcut. Normal stop requests guest powerdown and never converts its timeout
into an implicit process kill. A force-stop feature, if introduced later, must be
separate, explicit and identity-validated.

## Coding-profile privilege and credential boundary (EZVM-009)

The `coding-default`/`1` guest identity is `coder`, with home `/home/coder`
and workspace `/home/coder/workspace`. Its password is locked, SSH password
authentication is disabled and the accepted instance seed carries only the
controller public key. No user token, agent login state or private key belongs
in the profile source, build seed, prepared base or readiness marker.

`coder` deliberately receives `ALL=(ALL:ALL) NOPASSWD:ALL` within the disposable
guest. An agent can therefore install development packages and alter the whole
guest without an interactive password prompt. This is not a privilege boundary
between coder and guest root: software run as coder can reach other credentials
stored in that VM. Keep unrelated trust domains in separate instances. This
guest privilege does not change Windows elevation, host sharing or networking.

The profile validates the existing baseline toolset; it neither downloads
additional ecosystems nor executes vendor-agent installers. A future automatic
installer must be version-pinned, reviewable and verify downloaded artifacts
before execution. User-selected agent installation and vendor authentication
take place within the mutable overlay using the vendor's reviewed instructions.
Do not inject credentials through committed configuration or log them in
readiness/qualification evidence.

Guest identity and readiness documents carry schema version 2, base/resource
and coding-profile name/version/digest. A completed marker is accepted only with
fresh authenticated tool/account/workspace checks. This prevents accidental
false readiness from stale or mismatched guest state; it is not tamper-resistant
attestation against guest root, which can modify guest state and responses.

Profile provisioning preserves workspace contents and avoids recursive ownership
changes. Profile upgrades use new reviewed version paths; baseline changes use
new immutable base identities. Legacy `ezvm-core`/`1` overlays are left intact
for inspection/stop or a future explicit migration, and cannot silently acquire
the `coding-default` identity.
