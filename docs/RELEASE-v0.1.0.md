# ezvm v0.1.0 release notes

ezvm v0.1.0 is the first programme release of the Windows-first portable
QEMU + QCOW2 coding-VM manager.

The tag publication workflow prepends the exact tag target commit to the GitHub
release body. The release ZIP contains RELEASE-METADATA.json with the exact
source commit/tree and per-file SHA-256 values.

## Supported baseline

- Host: Windows 10 version 2004+ or Windows 11 x86-64 client
- Normal accelerator: Windows Hypervisor Platform (WHPX)
- Public control plane: Windows PowerShell 5.1 and current PowerShell 7
- Guest: Ubuntu Server 24.04 LTS (Noble) amd64
- Guest control: QEMU user-mode NAT plus localhost-only managed OpenSSH
- Disk model: one immutable managed base -> one mutable QCOW2 overlay

## Reviewed external pins

QEMU provider:

- Stefan Weil QEMU for Windows
- QEMU version: 11.1.0
- provider build: 20260811
- artifact: qemu-w64-setup-20260811.exe
- SHA-512:
  5bcf9eed634e8575a37b74f445af41a2fe4106da512d0c30c368301d4c105037fdfab40a5287367a28a957624cddebbc8c07e16c88ab6634f554cdf3d16bf543

Extractor:

- 7-Zip 26.04
- 7zr.exe SHA-256:
  256feca8e274e5da655e2a284fabafd9f554365eb164862089dacd4e8276d282
- 7z2604-x64.exe SHA-256:
  d54bf805f9f3704d1e8db2fa3498ae7ef2df0312b40b558e7c71c734430a665d

Ubuntu source:

- Canonical Noble publication: 20260926
- ubuntu-24.04-server-cloudimg-amd64.img
- SHA-256:
  6a81c37564db9b1ee84e141922625e1d7c5b389b99bb3c572e0243607d5bb4d2

The release artifact contains none of these third-party binaries. Normal ezvm
bootstrap/acquisition downloads and verifies them from the reviewed providers.

## Release qualification

The final EZVM-012 release candidate must have all of the following on the exact
candidate commit before the tag is created:

- repository/RAG/schema/generated-artifact/secret contract PASS;
- full Windows PowerShell 5.1 control-plane suite PASS;
- full pinned PowerShell 7 control-plane suite PASS;
- deterministic package regression PASS;
- the bounded EZVM-012 real release qualification PASS.

The real release lane starts from a copied clean source root and executes doctor,
verified QEMU bootstrap, verified Ubuntu acquisition, prepared-base construction,
authenticated coding READY, real exec/SCP, two concurrently running instances
with distinct resources, stop/restart persistence, reset, fresh and stateful
clone behavior, standalone export/import, cold relocation, destination
doctor/portability validation, relocated restart and clean shutdown.

### Accelerator evidence

Hosted final qualification uses **explicit QEMU TCG**. This proves the complete
orchestration and guest workflow but is not a WHPX performance or runtime PASS.

**WHPX execution is an explicit capability SKIP in hosted release
qualification.** WHPX argument construction/capability detection are covered by
the control-plane suite. A supported physical/local Windows host can execute the
documented [WHPX qualification procedure](WHPX-QUALIFICATION.md).

The exact successful release-candidate CI and real-run URLs are recorded on the
EZVM-012 PR/issue before merge/tag publication. A release is not accepted merely
because these workflows exist.

## State and credential compatibility

- New v0.1 durable instance intent is schema version 2.
- Complete schema version 1 intent remains readable according to the existing
  compatibility contract; unsupported historical guest profiles are not silently
  upgraded.
- Existing disks/bases are never rewritten merely to migrate metadata.
- Pre-EZVM-011 QEMU runtimes lacking a verified payload inventory require a
  verified rebootstrap while preserving bases, instances and keys.
- Clean prepared bases contain no user authentication.
- Stateful snapshots/exports/imports can contain guest credentials and are
  explicitly sensitive.
- Reset is not secure erasure and can restore credentials already present in a
  sensitive snapshot baseline.

## Known limitations and non-goals

- No hosted WHPX execution PASS.
- Windows client x86-64 hosts are the v0.1 support target; Windows Server,
  Linux/macOS hosts and ARM are outside the supported host baseline.
- No live migration or suspend-state portability.
- No TAP/bridge/LAN-facing networking in the default workflow.
- No GPU/USB passthrough.
- No guarantee against a QEMU/WHPX escape, hostile guest kernel, malicious
  firmware/upstream binary, or hostile local administrator.
- coder can become guest root with passwordless sudo.
- Portability is cold disk/configuration portability only.
- Explicit stateful copies can preserve vendor-agent authentication and other
  sensitive guest data.

See [Getting started](GETTING-STARTED.md), [Portability](PORTABILITY.md),
[Troubleshooting](TROUBLESHOOTING.md), [Coding guest](CODING-GUEST.md), and
[Third-party notices](../THIRD-PARTY-NOTICES.md).
