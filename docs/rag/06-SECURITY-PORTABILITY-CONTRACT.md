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
- guest network traffic;
- explicit derived/imported guest snapshots, which can retain user data and
  authentication even though their stored bytes are immutable.

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

Clean prepared bases built by ezvm must not contain user authentication tokens.
Derived/imported snapshot bases are explicitly sensitive state with distinct
schema/kind provenance; they are never presented as clean prepared images.

Per-instance agent credentials may live in that instance overlay if the user
chooses to authenticate there. They survive normal stop/restart. Reset returns
to the instance's chosen base: credentials written only into the overlay are
discarded, while credentials already saved in a snapshot baseline can return.
An intentional stateful clone/export/import can preserve authentication along
with other guest data. Snapshot manifests explicitly record sensitive state;
they do not contain credential bytes themselves. No command uploads or shares
these images automatically.

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

The same sensitivity applies to immutable derived/imported bases, fresh clones
from them, and failed snapshot staging. A file being read-only, standalone or
digest-verified says nothing about whether its guest contents are safe to share.

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

Failed build staging retains disks and raw serial diagnostics under
`runtime/bases/.build-*` for diagnosis. EZVM-011 removes its generated seed files
after success or failure. The reviewed base-build seed is credential-free by
construction; retained logs must still be reviewed before sharing.

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

## Offline transformations and copied identities (EZVM-010)

Reset, both clone modes and export prove stopped source ownership under the
lifecycle lock. Import requires a new destination and rejects sources inside
managed runtime, preventing an active managed disk from being reinterpreted as
an unrelated input. Exclusive Windows file access protects the caller's import
while ezvm takes and hashes its private copy. The importer checks QCOW2 headers
before QEMU processing so external backing or data-file metadata cannot cause
unrequested host-file traversal.

Import validates a storage format, not guest trustworthiness. A user-supplied
guest can run arbitrary software when deliberately started, and an unrelated OS
may never satisfy coding READY. The supported round trip is a stopped ezvm
coding guest exported and imported with its provenance manifest.

New/reset instances have an explicit identity generation. Clone/import boots
must replace copied inbound controller authorization and regenerate guest
machine/SSH host identity before destination READY. Outgoing SSH keys, project
files and vendor-agent authentication are preserved state, not automatically
removed credentials. The host never trusts a copied source READY marker as
destination proof.

Cold portability preserves bundle keys only when those files are included in
the user's copy. It revalidates stopped ownership and regenerates launch paths,
without weakening the existing stale/unknown process refusal. Copying a complete
bundle does not give its instances new names or reservations; keep the original
copy stopped while using the moved copy on the same host.

## Host-side hardening and diagnosis (EZVM-011)

Filesystem mutation uses a common regular-local-path guard. On Windows it rejects
device/UNC namespaces, drive-relative spelling, alternate streams, device names,
trailing dots/spaces and control characters before normalization. Existing
ancestors are checked all the way to the volume root, including dangling links
and links above the selected bundle. Storage containment checks remain separate.
Recursive cleanup preflights a bounded tree and deletes bottom-up without
following a reparse point. Read-only attribute changes refuse shared hard-link
targets. These checks address malformed or redirected layouts; they are not
race-proof against a malicious local administrator changing every syscall target.

JSON and other control files use bounded reads. Download URLs and filenames are
validated before cache deletion. Download transactions serialize by destination;
cleanup owns only its temporary file and never deletes another publisher's
final destination. Redirects remain HTTPS, exclude embedded credentials, have a
five-hop bound and share a total transfer deadline and byte cap. All reviewed
hash/size checks still precede extraction or boot. Installed QEMU payloads now
have a manifest-bound inventory verified before execution; see the host contract.

Controller private keys remain host-side, with verified exact Windows ACLs and
public/private pairing. Source/build/profile guards reject high-confidence token
formats without echoing them. Structured error/failure summaries redact known
credential formats, authorization headers and sensitive URL fields before
truncation. This is not a universal secret detector: raw guest output, explicit
exec stdout/stderr, underlying exception data and retained raw diagnostic logs
still require manual review before sharing. No real credentials are test fixtures.

`diagnose <name>` provides bounded host-only findings and recovery guidance.
`-CheckImage` adds locked, stopped-only header/provenance/digest/integrity checks,
never automatic repair or a STALE-to-STOPPED rewrite. Default inspection is
read-only; deep inspection may create/reuse a coordination lock. Reset barriers,
original disks and staging are preserved when recovery is ambiguous. Detailed
recovery procedures and legacy-QEMU rebootstrap are in
[TROUBLESHOOTING.md](../TROUBLESHOOTING.md).
