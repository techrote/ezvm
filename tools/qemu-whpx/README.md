# Checked WHPX partition reset build

This directory records the narrow QEMU correction needed by the Windows WHPX
CI-PoC. It is separate from an EzVM product release. Full original physical
release/portability qualification remains required on the final integration.

Upstream QEMU v11.1.2 commit `4fc49f46dc95d4a27de2509e7fceb2931e91faeb`
reproduced the first identity-reboot failure on the supported Windows 11 host.
The reviewed build is commit `9866111e7605d9776939c26ced6e090cb7d7ec20`,
tree `94d28970e0ee00333cd763111e8ebaf571ffcc27`.
`upstream.patch` contains the complete change from that upstream commit,
including the Windows build-only optional-symlink-bundle adjustment.

The x86 WHPX reset hook runs after CPU synchronization and before board/device
reset. It checks that all VPs are stopped, requires exact API `S_OK`, and clears
five interrupt-window cache fields only after successful partition reset.
An attempted API failure exits nonzero before device reset or CPU resume.

The `partition-reset` accelerator property defaults to `auto`. Native AMD64
Windows client version 10.0, build 22000 or newer, and the dynamically resolved
`WHvResetPartition` export are both required to enable it. Unsupported or unknown
hosts retain the old reset path in AUTO; explicit ON refuses them before guest
creation. OFF retains the legacy path. Selection is recorded and frozen before
partition creation. Windows 10 behavior with this new binary is physically
unmeasured; preserving its legacy implementation is not a qualification claim.

The original provider installer and extractor remain pinned. A separately
hash-pinned ZIP supplies exactly two EXEs and eight DLLs. Bootstrap verifies the
entire original provider inventory before applying the overlay, then verifies
the complete resulting payload before executable probing. It records source and
artifact provenance and enforces the resulting inventory before later execution.
No firmware/resource files are redistributed in the overlay.

The tool prerelease provides the ten-file overlay, a build manifest, and a
corresponding-source ZIP. The source ZIP contains QEMU and keycodemapdb bare Git
repositories with explicit shallow boundaries, this patch/build script, license
notices, and the eight matching official MSYS2 source archives listed in
`runtime-sources.json`. It contains no private working checkout or credentials.
QEMU changes retain QEMU's GPL-2.0-or-later licensing; DLL notices and source
packages retain their individual licenses.

To reconstruct the build, extract the source ZIP, clone its repositories with
`git -c core.autocrlf=false -c core.eol=lf clone --no-local qemu.git qemu-policy-source`
and the same clone options for
`keycodemapdb.git` into `qemu-policy-source/subprojects/keycodemapdb`.
Verify the commits/trees in the build manifest. Use the recorded MSYS2 UCRT64
toolchain and exact package identities, then run `bash build.sh` from the
containing directory. The build disables downloads and debug information;
the bindir/datadir relationship is portable. There is no host Developer Mode,
administrator, global PATH, firewall or virtualization-policy requirement.

The frozen build passed all 11 native reset unit groups. The private preceding
experiment passed two fresh authenticated second-boot/normal-stop WHPX controls.
The shipping build's bounded AUTO and ON reset/relocation probes passed; OFF
reproduced the legacy VP-exit failure and its multi-arm driver remained failed.
The bounded TCG reset probe passed. These controls do not replace the complete
original qualification or the owner-deferred hosted TCG gate.
