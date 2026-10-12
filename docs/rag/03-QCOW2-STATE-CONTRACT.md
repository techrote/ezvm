# 03 — QCOW2 state contract

## Purpose

QCOW2 is the persistence mechanism that makes ezvm instances cheap, disposable and portable. Disk operations are therefore safety-critical.

Primary references:

- https://www.qemu.org/docs/master/system/images.html
- https://www.qemu.org/docs/master/tools/qemu-img.html
- https://www.qemu.org/docs/master/interop/qcow2.html

## v0.1 chain invariant

Exactly one backing level is supported:

~~~text
immutable prepared base <- mutable instance overlay
~~~

An instance overlay must never be used as the backing file for another managed instance overlay.

## Base immutability

Once an overlay has been created against a prepared base, that base is immutable.

Never:

- boot the base writable;
- modify it in place;
- replace its contents while preserving its base ID;
- run qemu-img commit from an instance into the base.

A changed base is a new base with a new base ID and provenance manifest.

## Overlay creation

QEMU documents that a relative backing filename is resolved relative to the directory containing the new image.

The implementation should use the functional equivalent of:

~~~text
qemu-img create -f qcow2 -F qcow2 -b <relative-base-path> <instance-overlay>
~~~

The exact stored backing path must be inspected after creation and must remain valid after moving the complete ezvm root.

Do not use unsafe backing creation merely to suppress path errors.

## Chain validation before start

Before QEMU starts an instance, validate at least:

- overlay exists;
- overlay format is qcow2;
- backing format is qcow2;
- backing file resolves inside the managed ezvm runtime root;
- resolved backing file is the base recorded by instance.json;
- base manifest exists;
- base fingerprint/provenance matches recorded instance metadata;
- qemu-img can enumerate the complete backing chain;
- chain depth is exactly the v0.1 expected depth.

Use machine-readable qemu-img output where available instead of parsing human output.

## Integrity checks

qemu-img info --backing-chain is the normal structural inspection tool.

qemu-img check is allowed only on stopped images and should be used for explicit diagnostic/repair workflows, not blindly on every start.

Repair operations must not be automatic unless the operation is proven non-destructive and the user requested repair.

## Reset

Reset means discard the mutable overlay and create a fresh overlay against the same immutable base.

Safe reset sequence:

1. prove the instance is stopped;
2. validate the intended base;
3. create the replacement overlay at a temporary path;
4. validate the replacement chain;
5. atomically replace or rename according to Windows filesystem semantics;
6. remove old mutable state only after replacement succeeds;
7. clear stale runtime state.

A failed reset must leave either the original usable overlay or a clearly recoverable backup. It must not silently leave a half-created active disk.

## Clone semantics

Two clone meanings must remain distinct.

### Thin clone from clean base

Create a new empty overlay against the same prepared base. This creates a fresh environment, not a copy of the source instance state.

### Stateful clone

Create an independent disk containing the source instance's current guest-visible content. The source must be stopped. Use qemu-img conversion/flattening semantics so the new result does not depend on the source instance overlay.

Do not implement a child overlay of the source instance as a shortcut.

## Export semantics

Export is for backing-independent portability.

A stopped instance may be exported to a standalone qcow2 image using qemu-img convert. The export must be validated as having no backing file.

An export manifest records source instance, base ID, creation time, qemu-img version and digest.

## Import semantics

Import never trusts a filename alone.

Validate format, backing status, size and manifest. A standalone imported image may need normalization into ezvm's managed layout. It must not introduce an unexpected external backing path.

## Relocation

Moving the complete stopped ezvm root must preserve relative backing relationships without rebase.

If validation discovers a broken backing path after an unsupported partial move, ezvm must fail closed and explain the expected base location. v0.1 should prefer reconstructing a known relative relationship over unsafe qemu-img rebase.

## Running-image prohibition

While QEMU owns an image, do not:

- reset;
- clone through offline qemu-img;
- export through offline qemu-img;
- rebase;
- check/repair;
- copy the file as a consistent backup.

The lifecycle subsystem is the authority for whether an instance is safely stopped.

## Prepared-base publication (EZVM-004)

Base construction never writes the verified Ubuntu source image. It creates a
temporary qcow2 overlay with the source as its backing file and expands only that
overlay's virtual size for provisioning.

After the staging guest powers off cleanly, managed `qemu-img convert` flattens
the guest-visible staging chain into a new qcow2. Acceptance requires:

- `qemu-img info --output=json` reports `qcow2`;
- no backing filename is present;
- the virtual size is positive;
- `qemu-img check` succeeds while the new image is stopped;
- the resulting SHA-256 is recorded and becomes the content-addressed base ID.

Only after those checks, read-only marking, digest verification and full manifest
validation succeed **inside the non-authoritative `.publish-*` directory** does
the candidate move into its authoritative `base-<sha256>` directory. The
same-volume directory rename is the publication commit point; there is no
post-publication validation step that can fail while leaving an invalid
authoritative-looking directory. A build, flatten or candidate-validation failure
leaves no authoritative base. Non-authoritative `.build-*` staging is retained
with `failure.json` where possible so diagnosis does not require destructive
repair.
## Implemented overlay lifecycle (EZVM-005)

Overlay creation uses the managed `qemu-img` with explicit QCOW2 overlay and
backing formats and without unsafe backing creation. The backing name stored in
the overlay is relative to the directory containing the overlay, matching QEMU's
documented relative-backing resolution rule.

`Test-EzVmInstanceOverlay` / `Test-EzVmInstanceStorage` are the authoritative
v0.1 chain validators. They require:

- exactly two images in `qemu-img info --backing-chain --output=json`;
- a QCOW2 overlay with an explicit QCOW2 backing format;
- a non-absolute stored backing name;
- resolved backing containment under the managed base root;
- exact equality with the prepared base identified by the caller's base ID;
- a valid immutable prepared-base manifest/digest/read-only state;
- no backing file beneath the prepared base;
- matching positive virtual sizes.

A complete cold-root move therefore needs no rebase: the same stored relative
reference resolves under the new root. Broken/partial moves, external backing
targets, wrong base identities, malformed JSON and deeper chains are refused
rather than rewritten.

Stopped-image integrity checks require explicit `proven-safe` lifecycle
evidence and use `qemu-img check --output=json -f qcow2` without repair options.
Corruptions, leaks and check errors remain diagnostic results; repair is never
automatic.

Reset-safe storage replacement validates a fresh same-directory overlay before
the active disk is touched. The existing disk is moved to a recoverable backup,
the validated candidate is atomically promoted, and the backup is restored if
promotion fails. Normal storage code contains no `qemu-img commit` or automatic
rebase path and never deliberately removes prepared-base write protection.

## Runtime ownership integration (EZVM-006)

Before start, EZVM-006 calls the EZVM-005 complete backing-chain validator and
refuses launch on any missing, external, wrong-base, wrong-format or deeper chain.

The runtime lifecycle subsystem is now the authority that produces EZVM-005
storage guards. Only reconciled CREATED or STOPPED state yields
`proven-safe`. STARTING, RUNNING and STOPPING map to active guard states;
STALE, UNKNOWN and ambiguous ownership map to `unknown` and therefore refuse
offline/destructive image operations.

A graceful stop timeout deliberately leaves runtime state STOPPING and QEMU
ownership active. It is not converted into STOPPED merely because the requested
shutdown did not finish within the configured bound.

## Instance creation ownership (EZVM-008)

Public `create` validates the selected immutable prepared base before publishing
a durable instance. It then creates exactly one thin overlay using the existing
prepared-base -> instance-overlay invariant. The instance directory is new for
the transaction; if create fails before completion, ezvm attempts to remove only
that newly-created managed directory rather than leaving a partially authoritative
instance.

The recoverable durable authority remains `instance.json` plus the one-level
overlay. Registry enumeration does not infer a valid instance from a stray disk
or directory that lacks valid intent metadata.
