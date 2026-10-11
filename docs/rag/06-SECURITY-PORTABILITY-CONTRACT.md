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

Per-instance agent credentials may live in that instance overlay if the user chooses to authenticate there, but reset/export behavior must make that persistence clear.

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
