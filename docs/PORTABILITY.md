# Reset, clone and move coding environments

ezvm keeps each instance's mutable disk above one immutable managed base. The
base can be a clean prepared coding image, a stateful snapshot, or an imported
standalone image. Every managed instance still has exactly one backing level.

## Choose the operation

| Operation | What the destination contains | Identity and storage |
| --- | --- | --- |
| Reset | The instance's existing base, with later overlay changes discarded | Same named instance and resource reservation; a new mutable overlay and fresh readiness proof |
| Fresh clone | The source's existing base, without the source's later overlay changes | New name, cloud identity and SSH reservation; new overlay on the same base |
| Stateful clone | The source's stopped guest-visible disk state | New name and identity; new overlay on an independent immutable derived base |
| Export | The source's stopped guest-visible disk state | Standalone QCOW2 plus provenance manifest; no backing dependency |
| Import | A validated standalone image | New name and identity; new overlay on an immutable imported base |
| Cold relocation | The complete stopped bundle | Preserved durable identities and relative backing paths; process paths revalidated under the new root |

These are offline disk operations. Stop the relevant instance first. Uncertain,
starting, running or stopping ownership is an error, even if a stored PID looks
old. A failed graceful stop does not authorize a disk copy or reset.

## Clean bases and sensitive snapshots

`base build` produces a clean prepared base: the reviewed build removes instance
SSH and machine identity and includes no user authentication. That is the normal
starting point for a new coding environment.

A stateful clone or import has a different purpose. Its immutable base preserves
guest data and can include source code, installed agents, browser state, tokens
and other authentication files. Immutability protects its bytes from accidental
change; it does not make the contents public or credential-free. Snapshot base
manifests explicitly record `kind: derived` or `kind: imported`,
`sensitiveState: true` and `guestIdentityResetRequired: true`.

**Reset returns to the instance's selected base.** Resetting an instance based on
a clean prepared image discards login state written into its overlay. Resetting
an instance based on a stateful snapshot can restore credentials already present
in that snapshot. Likewise, a fresh clone of a snapshot-based instance inherits
the snapshot's contents while excluding changes made later in the source
overlay. Use a clean prepared base when you want an environment without that
saved state.

Snapshot/imported bases are not selected implicitly as the newest clean base.
Ordinary `create` without `-BaseId` continues to select a prepared base. Selecting
another base explicitly is a deliberate choice of that baseline.

## Reset an instance

~~~powershell
.\ezvm.ps1 stop work
.\ezvm.ps1 reset work
.\ezvm.ps1 start work
~~~

Reset validates the base and a fresh replacement chain before changing the
active overlay. It preserves the old disk through the replacement transaction
and either completes or reports a recoverable artifact. It also reconciles
ephemeral launch and readiness state. The next start must prove the requested
guest identity, coding profile and workspace again before READY.

A `lifecycle-operation.json` journal is written before the first disk rename.
Until reset commits, the journal blocks startup and records the original and target
intent, original disk backup and archived launch state. A failed reset may need
explicit recovery from these paths; deleting the journal alone is unsafe. On
success the journal is removed and any recovery material that could not be
cleaned is returned visibly in the result.

Reset is not a secure-erasure operation. Files retained in a snapshot, an export,
another copy of the bundle, or a recovery artifact are separate copies.

## Clone an instance

Clone mode is explicit:

~~~powershell
.\ezvm.ps1 stop work
.\ezvm.ps1 clone work fresh-work -Mode fresh
.\ezvm.ps1 clone work saved-work -Mode stateful
~~~

Both modes derive CPU/RAM configuration and the coding profile from the source,
and allocate a distinct named instance and localhost SSH reservation. An
existing destination is refused.

Fresh mode creates an empty overlay against the same base. Stateful mode
flattens the stopped source chain into a standalone, content-addressed derived
base and places the destination's fresh overlay above it. The destination never
backs onto the source's mutable disk. Resetting or subsequently changing the
source therefore cannot change the clone's saved baseline.

The copied guest's old ezvm identity and READY file do not authorize destination
readiness. The destination receives its own identity and repeats normal live
readiness validation. Guest project files and agent authentication remain
stateful data; resetting ezvm machine identity does not log you out of vendors.

## Export and import

An export destination is a **new directory** outside managed runtime storage,
with an existing parent directory. It is published with these two files:

~~~text
saved-work-export/
    disk.qcow2
    manifest.json
~~~

~~~powershell
.\ezvm.ps1 stop work
.\ezvm.ps1 export work 'D:\VM exports\saved-work-export'
.\ezvm.ps1 import imported-work 'D:\VM exports\saved-work-export\disk.qcow2'
~~~

The export image contains the complete guest-visible disk and has no backing
file. The manifest records the source instance and base, export time, reviewed
QEMU identity, virtual size and resulting SHA-256. Export refuses an existing
destination and never uploads or shares the files.

Import validates image structure before admitting it into managed state. It
rejects backing chains, external data files, unsupported image features and
malformed QCOW2 metadata. A supplied or discovered export manifest must agree
with the actual image; a valid-looking filename or manifest alone is not proof.
The source is held against concurrent writes while a private staged copy is
validated and promoted into the immutable base store. The original input is
preserved.

An arbitrary standalone QCOW2 can be structurally importable without being a
usable coding guest. ezvm does not install Ubuntu, cloud-init or development
tools into an unrelated imported operating system. Boot and READY still require
the supported Ubuntu/cloud-init/`coding-default` environment and the live
identity/profile checks. Exporting a working ezvm coding guest is the normal
round-trip path. An imported image's software and contents retain the trust of
their source; digest validation is not malware scanning.

Import creates a new instance and refuses replacement of an existing one. A
source image inside managed runtime storage is refused; export it to a separate
directory before importing. Keep credentials-bearing exports and their
immutable imported bases private.

## Move the complete stopped folder

Stop every VM, validate the source bundle, then copy the complete folder:

~~~powershell
.\ezvm.ps1 list
.\ezvm.ps1 stop work
.\ezvm.ps1 stop saved-work
.\ezvm.ps1 portability check
~~~

Include source/configuration, managed QEMU, bases, instance directories and the
bundle's SSH keys/trust when preserving its existing host authentication. A
source-image cache may be retained for later builds. Copying only an overlay
does not produce a portable standalone image; use export for that purpose.

From the copied folder, run:

~~~powershell
.\ezvm.ps1 portability check
.\ezvm.ps1 doctor
.\ezvm.ps1 start saved-work
~~~

Relative backing references resolve beneath the new root without rebasing.
Durable `instance.json` contains identities and resources, not the old absolute
root. Reconciled stopped runtime metadata may still describe an old executable
or log path; a new start derives those paths again. Active, stale or ambiguous
process evidence must still be resolved safely and is not erased merely because
the folder moved.

Cold relocation transfers disk/configuration state, not running CPU state.
Keep the source copy stopped while using a copied bundle on the same host:
the two copies retain the same instance identities and SSH reservations. Using
the clone command is the way to create distinct instances in one bundle.

## If an operation fails

Follow the reported path and remediation. The source overlay remains the
authoritative data unless the operation explicitly reports a completed reset.
During an interrupted reset, `disk.qcow2` may already be the replacement. Use
the journal's original intent and disk-backup path to identify the preserved
source state, and keep startup blocked until recovery is reconciled.
Failed publication can leave a non-authoritative staging directory or an old
disk recovery file; preserve those when diagnosing the failure. Do not rename an
unvalidated partial file into `disk.qcow2`, overwrite an immutable base, or use
unsafe rebase to suppress a missing backing error.

Portability checking is validation, not automatic repair. A partial move,
missing base, changed digest, invalid intent, duplicate reservation or uncertain
QEMU owner remains a failure. Restore the complete expected layout and reconcile
ownership before retrying.

See the [QCOW2 contract](rag/03-QCOW2-STATE-CONTRACT.md),
[security contract](rag/06-SECURITY-PORTABILITY-CONTRACT.md) and
[coding guest guide](CODING-GUEST.md) for the detailed boundaries.
