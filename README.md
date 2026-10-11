# ezvm

Portable, disposable QEMU + QCOW2 coding-agent environments for Windows hosts.

## Current state

**EZVM-001 provides the control-plane foundation and EZVM-002 adds portable QEMU
bootstrap plus Windows host preflight; the project remains version `0.0.0-dev`.**
The checkout has reviewed QEMU/7-Zip manifests, repository-local verified runtime
bootstrap, `doctor`, and automated tests under Windows PowerShell 5.1 and
PowerShell 7.

The commands available on this branch are:

~~~powershell
.\ezvm.ps1 help
.\ezvm.ps1 version
.\ezvm.ps1 doctor
.\ezvm.ps1 bootstrap
~~~

Running with no command also shows help. Unknown commands and malformed arguments
return exit code 2. JSON results can be piped directly to `ConvertFrom-Json`:

~~~powershell
$result = .\ezvm.ps1 version -Json | ConvertFrom-Json
$result.data.version
~~~

If the host's execution policy blocks local scripts, a process-scoped invocation
can run the checked-out source without changing the machine's policy:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ezvm.ps1 help
~~~

`bootstrap` downloads only reviewed hash-pinned QEMU and 7-Zip artifacts, verifies
them before execution/extraction, unpacks QEMU's NSIS package without running the
installer, validates the resulting QEMU tools, then atomically promotes them into
`runtime/qemu`. It does not elevate, install QEMU system-wide, write uninstall
registry state, or modify PATH.

`doctor` independently reports host OS/architecture, PowerShell, virtualization
indicators, WHPX feature state, managed QEMU, runtime writeability, path/disk
conditions and visible stale runtime state. It never enables WHPX and never claims
that WHPX execution succeeded merely from feature detection.

Ubuntu image acquisition and VM lifecycle commands are delivered by subsequent
programme issues. Version `0.0.0-dev` is not the v0.1 release.

## Planned target experience

From one folder:

~~~powershell
.\ezvm.ps1 doctor
.\ezvm.ps1 bootstrap
.\ezvm.ps1 base acquire
.\ezvm.ps1 base build
.\ezvm.ps1 create steelmoth
.\ezvm.ps1 start steelmoth
.\ezvm.ps1 ssh steelmoth
~~~

The intended v0.1 architecture is:

- repository-local PowerShell control plane;
- repository-local, hash-verified QEMU Windows runtime;
- WHPX hardware acceleration;
- pinned official Ubuntu Server 24.04 LTS cloud image;
- reproducibly built immutable prepared base;
- one thin QCOW2 overlay per coding-agent instance;
- headless QEMU;
- user-mode NAT;
- localhost-only SSH forwarding;
- cold portability by copying the stopped ezvm folder.

## Configuration and development

Repository defaults live in [config/defaults.json](config/defaults.json). Optional
local overrides live in the ignored `runtime/config.json`; both carry
`schemaVersion: 1`. Partial nested overrides inherit unspecified defaults. For
example:

~~~json
{
  "schemaVersion": 1,
  "defaultProfile": "light",
  "profiles": { "normal": { "memoryMiB": 12288 } }
}
~~~

Reading defaults or displaying help does not create runtime directories. All
managed paths are derived from the current checkout, including when its path
contains spaces or it was copied without a `.git` directory. Unknown settings,
invalid types and unsupported schema versions fail with remediation.

The module interface and exact configuration/JSON contracts are documented in
[the CLI and state contract](docs/rag/07-CLI-STATE-CONTRACT.md). Test instructions
and the versioned test harness are described in [tests/README.md](tests/README.md).

Implementation follows the dependency-ordered
[programme](docs/programme/IMPLEMENTATION-PROGRAMME.md), [AGENTS.md](AGENTS.md) and
[RAG authority](docs/rag/README.md). Each issue includes implementation, tests,
PR review, green automated checks, merge and verification of the merged commit.

## Design constraints

v0.1 intentionally avoids:

- system-wide QEMU installation;
- hand-maintained opaque golden images;
- arbitrary multi-level QCOW2 chains;
- bridged/TAP networking;
- Docker or WSL as required components;
- GUI management;
- committing VM images, installers, keys or credentials.

## External platform authority

Key upstream references are recorded in docs/rag. The principal sources are QEMU's WHPX, qemu-img and networking documentation, Ubuntu cloud-image releases, and cloud-init's QEMU/NoCloud documentation.

## License

No project license has been selected yet. Third-party QEMU and Ubuntu artifacts are not intended to be committed into this repository.
