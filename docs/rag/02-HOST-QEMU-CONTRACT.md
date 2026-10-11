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

The bootstrap implementation downloads a specific Windows build recorded in manifests/qemu-windows.json and verifies the recorded cryptographic digest before executing or extracting it.

QEMU upstream currently directs Windows users to Stefan Weil's Windows binaries:

- https://www.qemu.org/download/#windows
- https://qemu.weilnetz.de/w64/

The provider publishes installer digest files alongside installers. The manifest must pin an exact artifact and expected digest rather than scraping "latest" at normal runtime.

The Windows installer supports unattended local-directory installation in existing ecosystem usage. Implementation must verify the exact command behavior against the pinned installer before relying on it.

The runtime destination is inside runtime/qemu. ezvm must invoke QEMU by absolute path and must not depend on PATH mutation.

## Version/provenance recording

After bootstrap, record at least:

- manifest schema version;
- provider URL;
- downloaded filename;
- expected digest;
- observed digest;
- qemu-system-x86_64 version output;
- qemu-img version output;
- bootstrap timestamp.

Mismatch between installed runtime and manifest is a doctor warning or error according to whether compatibility is known.

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
