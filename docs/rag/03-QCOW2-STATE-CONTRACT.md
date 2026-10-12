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
immutable managed base <- mutable instance overlay
~~~

An instance overlay must never be used as the backing file for another managed instance overlay.

An immutable managed base is either a clean prepared image or an explicitly
derived/imported standalone snapshot. Snapshots preserve guest content and are
labelled sensitive; they do not inherit the clean prepared-image credential
claim. Both base kinds obey the same content identity, read-only and one-level
backing rules.

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

### Fresh clone from the source's existing base

Create a new empty overlay against the source's same immutable base. Source
overlay changes are excluded. When that base is a stateful snapshot, its saved
contents are still inherited; fresh clone does not silently switch to an older
clean prepared base.

### Stateful clone

Create an independent disk containing the source instance's current guest-visible content. The source must be stopped. Use qemu-img conversion/flattening semantics so the new result does not depend on the source instance overlay.

Do not implement a child overlay of the source instance as a shortcut.

## Export semantics

Export is for backing-independent portability.

A stopped instance may be exported to a standalone qcow2 image using qemu-img convert. The export must be validated as having no backing file.

An export manifest records source instance, base ID, creation time, qemu-img version and digest.

EZVM-010 publishes a new export directory containing `disk.qcow2` and
`manifest.json`. The directory rename is the publication point, so consumers do
not receive a final image without its manifest. Existing destinations and
destinations inside managed runtime state are refused. The manifest includes
the source's full durable intent, overlay and base-manifest hashes, base kind,
QEMU provenance, virtual size and resulting image digest. It explicitly marks
the content as potentially sensitive.

## Import semantics

Import never trusts a filename alone.

Validate format, backing status, size and manifest. A standalone imported image may need normalization into ezvm's managed layout. It must not introduce an unexpected external backing path.

Import inspects a bounded QCOW2 header before invoking QEMU on the image. It
refuses backing files, external data files, encryption, internal snapshots,
unsupported feature flags/extensions and malformed/truncated metadata. The
caller input is exclusively opened on Windows, copied to private staging and
hashed against that copy. QEMU operates on the staged copy. A supplied export
manifest must match the image digest and virtual size. Structurally valid
standalone images may be imported without claiming guest boot/profile support.

Accepted imports are normalized into standalone read-only bases with schema
version 2 provenance and a fresh instance overlay. The source is preserved.
Import creates a new instance; it does not replace an existing instance or open
a source from inside managed runtime state as an unrelated external image.

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

## Public reset, snapshots and relocation (EZVM-010)

The public reset/clone/export APIs obtain proven stopped ownership under the
instance lifecycle lock. Publication of a new named instance also holds the
bundle allocation lock. Running, transitional, stale or unknown ownership never
becomes offline safety merely because an operation would be convenient.

Reset preserves the selected base and SSH/resource reservation while replacing
the overlay and identity generation. Readiness and process evidence are
reconciled as part of that transaction. Failure must restore the original disk
and durable intent together, or leave an explicit recovery artifact rather than
an apparently completed half-reset. Prepared-base bytes are never rewritten.

A `lifecycle-operation.json` journal blocks startup before the first reset disk
rename and remains until the new disk, regenerated intent and archived launch state
have committed. It records the original/target intent and relative recovery
artifact names. A failed transaction requires explicit recovery; deleting the
journal alone or retrying reset blindly is not recovery. Successful reset
reports any remaining disk/archive artifacts whose cleanup did not finish.

Derived/imported snapshot bases have content-addressed IDs, read-only images
and schema version 2 manifests. Their manifests record `kind`,
`sensitiveState`, `guestIdentityResetRequired`, source provenance and the QEMU
identity. Reusing already validated identical bytes never overwrites their
existing provenance. A new clone/import records its own operation provenance in
the destination's `origin.json`.

Reset always returns to the chosen base. It can therefore restore credentials
saved inside a sensitive snapshot. Fresh clone likewise excludes only later
overlay changes; it retains the selected baseline. These operations are neither
secure erasure nor a vendor logout.

`portability check` validates all named instances and complete backing chains
under the current root after every VM has stopped. Normal cold relocation copies
the complete root and requires no rebase. Old absolute paths in known stopped
runtime metadata do not become durable configuration; a new launch derives
executable, firmware and log paths from the current root. Unknown/stale active
ownership remains a refusal, and the checker performs no automatic repair.
