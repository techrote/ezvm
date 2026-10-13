# WHPX qualification procedure

Hosted CI for ezvm v0.1.0 does not expose a supported Windows-client WHPX
environment, so the release gate records WHPX execution as **SKIP**, never PASS.

Use this procedure only on a compatible physical/local Windows 10 2004+ or
Windows 11 x86-64 client with firmware virtualization enabled and Windows
Hypervisor Platform installed.

## Preconditions

From a normal unelevated PowerShell session:

~~~powershell
.\ezvm.ps1 doctor -Json | ConvertFrom-Json
~~~

The host-os, hardware-virtualization, whpx, runtime-write, path, disk-space and
openssh-client checks should be ready. If WHPX is not enabled, enable it from an
elevated shell and reboot as documented in
[Getting started](GETTING-STARTED.md). Do not change QEMU security mitigations or
force an unsupported host into a PASS.

## Qualification

Use a fresh source checkout/package or a known clean v0.1.0 working directory:

~~~powershell
.\ezvm.ps1 bootstrap
.\ezvm.ps1 base acquire
.\ezvm.ps1 base build
.\ezvm.ps1 create whpx-v01 -Profile normal
.\ezvm.ps1 start whpx-v01
.\ezvm.ps1 status whpx-v01 -Json | ConvertFrom-Json
.\ezvm.ps1 exec whpx-v01 -- sh -lc "printf 'WHPX_OK\n'; uname -a; git --version; python3 --version"
.\ezvm.ps1 stop whpx-v01
.\ezvm.ps1 diagnose whpx-v01 -CheckImage
.\ezvm.ps1 portability check
~~~

The public base build and start paths use WHPX; there is no silent TCG fallback.
Preserve the command outputs and QEMU/runtime evidence long enough to confirm:

- doctor reported WHPX configured;
- prepared-base construction completed under WHPX;
- start reached authenticated coding READY;
- runtime evidence records accelerator whpx;
- the guest command succeeded;
- graceful shutdown completed;
- stopped image/portability validation passed.

A TCG run, WHPX feature detection alone, or successful WHPX argv construction is
not equivalent evidence.

## Stop conditions

Stop and preserve diagnostics rather than weakening acceptance if any of these
occurs:

- doctor does not classify the host as supported/configured;
- QEMU reports WHPX initialization failure;
- lifecycle ownership is STALE/UNKNOWN;
- guest READY times out or identity/profile checks fail;
- storage/backing validation fails;
- graceful shutdown does not prove STOPPED;
- any step would require disabling a mitigation, changing guest acceptance
  criteria, force-opening a disk, deleting runtime evidence, or rebasing a chain
  merely to continue.

The hosted v0.1.0 release remains valid without this optional local evidence; it
simply continues to state WHPX runtime qualification as unexecuted.
