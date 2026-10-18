# Third-party notices and acquisition provenance

The normal ezvm v0.1.0 source package does **not** bundle QEMU, 7-Zip,
Ubuntu cloud images, VM disks, private keys, user credentials, or other
third-party binary payloads. ezvm downloads the reviewed artifacts directly
from their providers during bootstrap/base acquisition and verifies the
repository-pinned digests before use.

This file records provenance and upstream licensing references; it does not
relicense third-party software.

## Optional terminal dashboard

The optional dashboard installs the following pinned packages into a dedicated,
ignored virtual environment. Their wheels and installed license files are not
committed or bundled with EzVM source. Exact artifact hashes are in
`dashboard/requirements.txt`; setup requires hash verification and binary wheels.

- prompt_toolkit 3.0.53: BSD-3-Clause, https://github.com/prompt-toolkit/python-prompt-toolkit
- wcwidth 0.2.13: MIT, https://github.com/jquast/wcwidth
- psutil 7.2.2: BSD-3-Clause, https://github.com/giampaolo/psutil

The tiled interaction reference is https://github.com/techrote/mdbm. No mdbm
source or assets are copied into this implementation.

## QEMU for Windows

- Project: QEMU
- Windows provider used by the reviewed manifest: Stefan Weil QEMU for Windows
- Pinned ezvm provider artifact: QEMU 11.1.0, provider build 20260811
- Upstream project: https://www.qemu.org/
- Windows builds: https://qemu.weilnetz.de/w64/
- Licensing information: https://www.qemu.org/docs/master/about/license.html

The QEMU installer is downloaded and verified at runtime, then extracted into
repository-local generated state. It is not contained in the ezvm release ZIP.

The CI-PoC manifest additionally pins a separately published ten-file QEMU 11.1.2
reset overlay, built from upstream commit
`4fc49f46dc95d4a27de2509e7fceb2931e91faeb` plus the complete GPL-2.0-or-later
patch in [tools/qemu-whpx/upstream.patch](tools/qemu-whpx/upstream.patch).
Its exact source is commit `9866111e7605d9776939c26ced6e090cb7d7ec20`, tree
`94d28970e0ee00333cd763111e8ebaf571ffcc27`. The original provider retains its
firmware/resources; the overlay redistributes no firmware.

The [build manifest](tools/qemu-whpx/build-manifest.json) pins both overlay and
corresponding-source assets. The source asset contains QEMU/keycodemapdb Git
objects with their shallow boundaries, build instructions, all 15 runtime-library
license notices and the eight matching official MSYS2 source archives. Those
archives and component licenses are indexed in
[runtime-sources.json](tools/qemu-whpx/runtime-sources.json). The DLLs are GLib,
libiconv, gettext runtime, PCRE2, libslirp, winpthreads, zstd and zlib; each retains
its original license. No third-party binary enters the EzVM source package.

## 7-Zip extractor

- Project: 7-Zip
- Pinned ezvm version: 26.04
- Runtime bootstrap artifacts: official 7zr.exe and 7z2604-x64.exe
- Upstream project and licensing information: https://www.7-zip.org/

The extractor artifacts are downloaded and verified at runtime. They are not
contained in the ezvm release ZIP.

## Ubuntu cloud image

- Provider: Canonical Ubuntu Cloud Images
- Guest baseline: Ubuntu Server 24.04 LTS (Noble) amd64
- Pinned publication: 20260926
- Pinned filename: ubuntu-24.04-server-cloudimg-amd64.img
- Pinned SHA-256:
  6a81c37564db9b1ee84e141922625e1d7c5b389b99bb3c572e0243607d5bb4d2
- Provider: https://cloud-images.ubuntu.com/releases/noble/

The cloud image is downloaded and verified into generated runtime/cache state.
It is not contained in the ezvm release ZIP. Software inside Ubuntu remains
subject to the licenses of its respective packages and providers.
