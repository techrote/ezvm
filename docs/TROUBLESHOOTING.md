# Troubleshooting and evidence-preserving recovery

## Diagnose before changing state

```powershell
.\ezvm.ps1 status coding-work
.\ezvm.ps1 diagnose coding-work
.\ezvm.ps1 diagnose coding-work -Json | ConvertFrom-Json
# Only after positively proven stopped ownership:
.\ezvm.ps1 diagnose coding-work -CheckImage
```

`diagnose` is a bounded host-side report, not a repair command. A completed
report uses exit 0 even when `data.status` is `attention`; inspect `findings`
and `imageCheck`, rather than treating the command's exit as guest readiness.
Invalid syntax or inability to invoke the command is still an error. Default
inspection does not run QEMU, read disk contents or change instance metadata.
`-CheckImage` additionally obtains the instance coordination lock, rechecks
stopped ownership and exact intent, verifies raw QCOW2 dependency headers, base
provenance/digests and the managed tool inventory, then runs the existing
non-repairing image check. It never uses force-share, repair, commit or rebase.
The lock file can be created/reused; no disk or instance metadata is repaired.

A report is an observation, not permission to mutate a file later. An agent can
change guest state after READY. A process can exit or another process can start
after inspection. Lifecycle operations must perform their own checks.

## Older QEMU installations need a verified rebootstrap

EZVM-011 adds `runtime/qemu/ezvm-payload.json` and a SHA-256 reference to it in
`ezvm-provenance.json`. The inventory is generated only from newly extracted,
hash-verified provider packages and covers executables, DLLs, firmware and other
payload files. Existing installations without it are refused **before any
version probe**. Do not generate an inventory from unexplained installed bytes.

First stop all instances cleanly, using the previously accepted control plane
when necessary. Confirm there are no QEMU owners or active base builders; an
UNKNOWN/STALE owner is not a clean stop. Preserve the old **QEMU directory only**
outside `runtime/qemu`, using an unused destination on the same disk. Keep
`runtime/bases`, `runtime/instances`, `runtime/keys` and cache content unchanged.
Then run:

```powershell
.\ezvm.ps1 bootstrap
.\ezvm.ps1 doctor
.\ezvm.ps1 diagnose coding-work -CheckImage
```

Bootstrap reuses only cache objects that match the reviewed digest and size.
It will not replace a present invalid runtime or update its receipt in place.
Preserve a damaged runtime for analysis; do not merely edit its receipt hashes.
The inventory detects changes since verified extraction, not compromise of a
host owner capable of changing the source, binaries and receipts together.

## Common failure modes

| Finding or symptom | Safe next action |
| --- | --- |
| Missing prepared base | Restore the exact recorded `base-<sha256>` directory, including image and manifest, from a complete stopped bundle backup. A new build has a new identity and is not an in-place substitute. |
| Base digest/provenance mismatch | Preserve both files. Determine whether the bundle is incomplete or damaged; restore a matching known pair. Never edit the expected digest to accept unexplained bytes. |
| Broken backing reference or unexpected depth | Recover the original complete layout. Normal cold relocation needs no rebase. Do not use unsafe rebase, commit or a child overlay of another instance. |
| Dirty, corrupt, leaked-cluster or check failure | Keep the original and a proven-stopped independent copy. No repair has been attempted. Any specialist image repair must be explicitly chosen on a copy, not run automatically on the only evidence. |
| QEMU start failure / STARTING | Preserve `runtime.json` and the named QEMU/serial logs. Check verified runtime, firmware, resources and port ownership. A launch timeout can leave a live process; use `stop` only when identity is proven. |
| Failed cloud-init / profile | Preserve guest logs and the staging disk. Inspect `cloud-init status --long`, `journalctl -u ezvm-instance-finalize.service` and `/var/lib/ezvm/provisioning-failed` in a trusted guest diagnostic session. Never fabricate READY or relax its checks. |
| SSH identity or host-key mismatch | Keep controller keys and scoped `known-hosts` unchanged. Reconcile instance/controller identity; a supported start must authenticate the expected generation and current-boot finalization before new trust is promoted. Do not disable strict checking. |
| Port collision | Identify the listener or a duplicate active bundle. Stop the correct owner. Do not edit reservations to conceal a duplicate running environment. |
| STALE / reused PID / UNKNOWN | Inspect all QEMU processes, not just the stored PID. Match executable, creation time and argument identity. A vanished/reused PID does not prove the disk was cleanly stopped. Do not delete runtime state to force CREATED. |
| Junction, symbolic link, alternate stream or device path | Stop affected work, preserve the redirected target, and restore an ordinary local layout. Do not recursively delete a directory through the rejected path. |
| Controller key ACL or pair mismatch | Restore the matching private/public pair on an ACL-capable local filesystem. Existing mismatched files are preserved. The generated public half may be reconstructed only from the verified existing private half. |
| Failed copy-from | The old explicit destination is preserved until the staged transfer succeeds and is atomically promoted. Inspect the nonzero SCP error; do not infer success from partial output. |

Default diagnosis does not claim to read guest logs, authenticate a failed SSH
endpoint, rehash every base, or infer the exact cause of a STARTING state.
It supplies the safe next diagnostic steps. Raw serial/QEMU and user-requested
remote command output can contain guest-controlled text; review before sharing.
Never upload a full bundle, key directory, seed or guest authentication state as
an ordinary bug report.

## Interrupted reset

`lifecycle-operation.json` is a deliberate recovery barrier. Its presence keeps
start/reset/copy operations from treating a half-transaction as complete.

After establishing that no process owns the disk, preserve the entire instance
directory **together with its exact backing base**. Keep the journal, both intent
versions, any `.disk-backup-*` image, `.reset-*` archive, active disk and launch
state. Do not interpret paths in a damaged journal as instructions to execute.
The diagnostic command lists only bounded, directly observed artifact names.

Recover a coherent transaction state, not individual convenient files. The
original disk belongs with the original intent/generation and original launch
state. The replacement disk belongs with the committed target intent/generation.
Restore a known complete pre-operation backup into a separate stopped recovery
bundle when available. Otherwise inspect which atomic renames actually completed
and validate the candidate disk/base relationship before choosing a state.
Deleting only the journal, retrying reset, or combining the new intent with the
old disk is not recovery. This release does not automate that ambiguous choice.

## Interrupted clone, import, export or base build

`.snapshot-*`, `.build-*` and `.publish-*` under bases are non-authoritative
staging. An export's `.ezvm-export-*` staging directory is beside its requested
external destination; diagnosis intentionally does not search unrelated host
folders. A new clone/import directory may have incomplete intent or provenance.
Keep its `origin.json`, disk and relevant immutable base together when present.
Never infer acceptance from the directory name alone.

The source disk is not overwritten by clone/export/import. Prefer repeating the
operation with a new destination after resolving its cause and proving the source
stopped. Preserve the failed staging until its data has been accounted for.
Staging and backups can contain credentials just as successful snapshots can.
Base-build seed files are now removed after success or failure; its disk, logs and
redacted failure summary remain useful evidence. No recipe embeds user credentials.

## Isolation and credential limitations

Run only normal coding-agent workloads inside the intended trust boundary. ezvm
reduces host integration but does not guarantee protection from QEMU/WHPX or
kernel escapes, malicious firmware/upstream binaries, or a hostile local
administrator. Guest `coder` has passwordless guest-root access. Keep unrelated
credentials in separate VMs. Immutable **clean prepared** bases are credential-free;
explicit derived/imported snapshots preserve user state and are marked sensitive.
Reset is neither secure erasure nor vendor logout: credentials saved in a snapshot
baseline can return. No operation automatically uploads an image.

The controller-key directory and private key require a verified current-user-only
Windows ACL. Broad explicit entries are removed, and permission changes refuse
hard-linked private-key files. Filesystems unable to enforce that policy fail
closed; relocating to another Windows account requires that account to own the
copied bundle and be able to set the required ACL. Public/private pairing is
checked without emitting private material.

## Platform references

- [Microsoft reparse points](https://learn.microsoft.com/en-us/windows/win32/fileio/reparse-points)
- [Microsoft file handle information and link counts](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/ns-fileapi-by_handle_file_information)
- [Microsoft ACL inheritance protection](https://learn.microsoft.com/en-us/dotnet/api/system.security.accesscontrol.objectsecurity.setaccessruleprotection)
- [QEMU offline image checking and repair warnings](https://www.qemu.org/docs/master/tools/qemu-img.html)
