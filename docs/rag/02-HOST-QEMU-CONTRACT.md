# 02 — Host and QEMU contract

## Supported host baseline

v0.1 primary host:

- Windows x86-64;
- Windows 10 version 2004 or newer, or Windows 11;
- CPU virtualization enabled in firmware;
- Windows Hypervisor Platform optional feature installed;
- local filesystem capable of storing multi-gigabyte sparse/growable files.

QEMU documents WHPX as its Windows Hypervisor Platform accelerator and requires the Windows Hypervisor Platform feature.

Reference:
https://www.qemu.org/docs/master/system/whpx.html

The documented feature-enable command is:

~~~powershell
DISM /online /Enable-Feature /FeatureName:HypervisorPlatform /All
~~~

ezvm doctor may report or print this command. Normal runtime commands must not silently elevate or modify Windows features.

## Accelerator policy

Normal start uses WHPX.

TCG is allowed for:

- CI where WHPX/nested virtualization is unavailable;
- controlled troubleshooting;
- explicit user request.

A TCG fallback must be visible in status/output. Never silently degrade from WHPX to TCG and imply normal performance.

## Portable QEMU acquisition

Do not commit QEMU binaries to git.

QEMU upstream directs Windows users to Stefan Weil's Windows builds:

- https://www.qemu.org/download/#windows
- https://qemu.weilnetz.de/w64/

Those builds are distributed as Windows installer artifacts with published digest files. The installer packaging is NSIS and its normal install path requests administrative execution and writes system installation/uninstall metadata. That behavior is inappropriate for ezvm's repository-local portable runtime.

Therefore **normal ezvm bootstrap must not execute the QEMU installer**.

Instead, bootstrap must:

1. read a reviewed manifest that pins an exact QEMU Windows installer URL, filename and cryptographic digest;
2. download into a temporary/cache path;
3. verify the expected digest before treating the artifact as trusted;
4. obtain a reviewed, pinned official `7zr.exe` bootstrap extractor and a reviewed, pinned official full 7-Zip x64 self-extracting package; verify both expected digests before use;
5. use verified `7zr.exe` only to unpack the verified full 7-Zip package without installing it, then use its extracted `7z.exe` + `7z.dll` (which contain the NSIS handler absent from reduced 7zr/7za builds) to unpack the verified QEMU NSIS package into staging without running either installer;
6. identify and preserve the actual QEMU payload, required DLL/data/firmware files and licensing material while dropping NSIS-only installer scaffolding;
7. execute only the extracted QEMU tools for bounded version/functional validation;
8. atomically promote the validated staged runtime into runtime/qemu.

7-Zip documents support for unpacking NSIS archives. The implementation must verify the extraction layout of the exact pinned QEMU artifact rather than depending on an assumed directory tree.

Neither the QEMU package nor the extractor is committed to git.

Normal bootstrap must not require elevation, write the registry, mutate PATH or create system-wide uninstall state. Enabling Windows Hypervisor Platform remains a separate host prerequisite that may require administrator action.

The runtime destination is inside runtime/qemu. ezvm invokes QEMU tools by an absolute path derived from the current ezvm root.

## Version/provenance recording

### CI-PoC checked WHPX reset overlay

The reviewed manifest retains the exact original provider installer and extractor
pins, and adds a separately pinned ten-file QEMU 11.1.2 reset overlay. Its asset
must use the explicit `techrote/ezvm` tool-prerelease path and match the recorded
SHA-256 and size. The complete original provider payload is bound canonically
before replacement; all ZIP names/sizes are checked before any extraction, and
all ten extracted files are checked before any replacement. Unsafe paths,
duplicates, extra entries, hardlinks and digest/size mismatches fail closed.

The manifest also pins the entire resulting payload, including unchanged
firmware/resources and remaining DLLs. This binding is checked before executable
probing and during every later integrity check, independently of mutable local
inventory/provenance receipts. Bootstrap cleanup errors remain command failures.
The original provider version records its source artifact; effective runtime
version is the overlay's 11.1.2, which release/physical evidence must compare
exactly. Source commit/tree, build-manifest digest and observed overlay digest
are recorded separately from the original provider identity.

The reset policy defaults to AUTO. It enables checked partition reset only on
native AMD64 Windows clients whose reliable numeric version is 10.0/build 22000
or later and whose WHvResetPartition export is available. Unsupported/unknown
hosts retain the unchanged legacy reset path. Explicit ON rejects unsupported
capability before guest creation; OFF uses the legacy path. Selection is frozen
at accelerator initialization. Any attempted API reset that does not return
exact S_OK is fatal before board reset or resume. The callback runs after CPU
synchronization and before device/APIC reset; initial, snapshot and subsystem
reset behavior and other accelerators do not gain this callback.

The host baseline above remains Windows 10 2004+/Windows 11. Windows 10 behavior
with the overlaid binary is physically unmeasured, rather than inferred from
the preserved code. OFF reproduced the legacy reset failure on the Windows 11
test host; it is not a successful regression arm. See
[source/build/acquisition details](../../tools/qemu-whpx/README.md) and
[the build manifest](../../tools/qemu-whpx/build-manifest.json). The source asset
and matching runtime-library sources/notices accompany the tool prerelease.

### Required recorded identities

After bootstrap, record at least:

- manifest schema version;
- QEMU provider URL and downloaded filename;
- expected and observed QEMU artifact digest;
- extractor provider URL and downloaded filename;
- expected and observed extractor digest;
- extractor version where discoverable;
- qemu-system-x86_64 version output;
- qemu-img version output;
- bootstrap timestamp.

Mismatch between installed runtime and reviewed manifests is a doctor warning or error according to whether compatibility is known.

## Host preflight

doctor must report independently:

- OS and architecture;
- PowerShell version;
- hardware virtualization indicators when discoverable;
- Windows Hypervisor Platform feature state;
- presence and version of managed QEMU;
- writable runtime root;
- path constraints;
- available disk space;
- conflicting/stale ezvm process state if present.

Preflight must distinguish:

- unsupported;
- supported but not configured;
- configured and ready;
- unknown/cannot determine.

## QEMU machine/device baseline

Prefer an explicit modern PC machine and explicit devices rather than depending on mutable QEMU defaults.

For Linux guests, virtio storage and networking are preferred where supported by the Ubuntu image.

The production command builder must generate arguments as an array of tokens and test quoting rather than constructing one shell command string.

## Firmware

The Ubuntu cloud image selected for v0.1 is UEFI/GPT bootable. The implementation must use firmware supplied with the managed QEMU runtime in a way that remains relative to that runtime and does not require host firmware installation.

If writable UEFI variable state is used, it belongs to generated instance/runtime state, never the shared immutable firmware code file.

## Path portability

All managed runtime paths derive from the ezvm root.

Tests must include:

- a root path containing spaces;
- relocation to a different drive/root path;
- mixed slash inputs normalized to canonical Windows paths.

Do not embed the original absolute ezvm root into portable instance configuration unless the field is explicitly ephemeral and regenerated after relocation.

## Upstream references

- WHPX: https://www.qemu.org/docs/master/system/whpx.html
- QEMU download: https://www.qemu.org/download/
- QEMU Windows builds: https://qemu.weilnetz.de/w64/
- QEMU invocation: https://www.qemu.org/docs/master/system/qemu-manpage.html
- 7-Zip: https://www.7-zip.org/
- 7-Zip download: https://www.7-zip.org/download.html

## Implemented provider pins and bootstrap (EZVM-002)

The reviewed initial v0.1 host-tool pins are:

- Stefan Weil Windows QEMU provider build `20260811`, QEMU `11.1.0`,
  `qemu-w64-setup-20260811.exe`, SHA-512
  `5bcf9eed634e8575a37b74f445af41a2fe4106da512d0c30c368301d4c105037fdfab40a5287367a28a957624cddebbc8c07e16c88ab6634f554cdf3d16bf543`;
- official 7-Zip `26.04` bootstrap `7zr.exe`, SHA-256
  `256feca8e274e5da655e2a284fabafd9f554365eb164862089dacd4e8276d282`;
- official 7-Zip `26.04` x64 package `7z2604-x64.exe`, SHA-256
  `d54bf805f9f3704d1e8db2fa3498ae7ef2df0312b40b558e7c71c734430a665d`.

A Windows qualification run verified that this exact two-stage extractor chain
unpacks the pinned QEMU NSIS payload and that the resulting
`qemu-system-x86_64.exe` and `qemu-img.exe` both report the reviewed 11.1.0
provider build. Normal PR CI does not repeat the large provider download.

Bootstrap caches verified provider artifacts under `runtime/cache/downloads`,
stages extraction under `runtime`, performs executable/version and qemu-img
functional validation, writes reviewed provenance, then uses same-volume directory
renames to promote the staged runtime. Existing matching provenance is re-probed
and reused idempotently.

`doctor` is diagnostic only. In particular, feature detection never establishes
that WHPX execution itself has succeeded; physical/local accelerator qualification
remains a later release gate.

## Implemented runtime command baseline (EZVM-006)

Normal instance start invokes the repository-local `qemu-system-x86_64.exe` by
absolute path and uses explicit q35, virtio-blk, virtio-net, UEFI pflash, memory,
CPU, headless display, serial logging and user-mode networking arguments. WHPX is
the production accelerator. TCG appears only when an internal/test caller asks
for it explicitly; there is no automatic WHPX-to-TCG fallback.

The shared firmware code image is opened read-only. Writable UEFI variable state
is copied from the managed QEMU firmware template into each instance directory
and is validated as managed generated state before use.

Runtime management uses QMP over a TCP listener bound explicitly to `127.0.0.1` rather than SSH or a LAN-exposed management socket.
The control path performs the QMP greeting and `qmp_capabilities` negotiation
before issuing commands. Production graceful stop sends `system_powerdown` and
waits for process exit; timeout is reported without silently killing QEMU.

Serial and QEMU diagnostic logs live beneath the managed instance directory.

## Verified installed payload (EZVM-011)

Fresh bootstrap holds read-only handles to verified provider artifacts, rechecks
all hashes/sizes immediately before extraction, and builds a bounded inventory
from the extracted payload before version probes. `ezvm-payload.json` records
relative paths, byte lengths and SHA-256 for every payload file, including DLLs
and firmware. Its digest is recorded as `payloadManifestSha256` in the existing
version 1 provenance receipt. The inventory and reviewed-manifest association
are checked before probing an installed runtime or resolving a managed tool.
Added, missing or changed payload files fail closed. No artifact pin or WHPX
mitigation is relaxed.

Legacy installations without that receipt are not silently upgraded from their
installed bytes. Stop guests and builders, preserve the old QEMU directory at an
unused location outside runtime/qemu, then bootstrap again from reviewed pins;
base images, instances and keys are retained. Existing invalid runtime directories
are never automatically replaced. See [recovery](../TROUBLESHOOTING.md).
Receipts detect installed-payload drift within the trusted-host model; they are
not external signatures against a malicious owner rewriting source and receipts.
