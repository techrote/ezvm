# ezvm

Portable, disposable QEMU + QCOW2 coding-agent environments for Windows hosts.

## Current state

**EZVM-001 provides the control-plane foundation, EZVM-002 adds portable QEMU
bootstrap plus Windows host preflight, EZVM-003 adds verified Ubuntu source
acquisition, EZVM-004 adds reproducible prepared-base construction, EZVM-005
adds validated thin-overlay storage primitives, EZVM-006 adds headless
start/status/stop lifecycle control, EZVM-007 adds localhost-only managed SSH,
authenticated readiness, exec and file transfer, and EZVM-008 adds durable named
instances, resource profiles and concurrent SSH-port allocation. EZVM-009 adds
the versioned `coding-default` guest profile and verifies that the guest's coding
tools, account and workspace are usable before reporting READY. EZVM-010 adds
reset, explicit fresh/stateful cloning, standalone export/import and cold-bundle
portability validation. The project remains version `0.0.0-dev`.**
The checkout has reviewed QEMU/7-Zip manifests, repository-local verified runtime
bootstrap, `doctor`, and automated tests under Windows PowerShell 5.1 and
PowerShell 7.

The commands available on this branch are:

~~~powershell
.\ezvm.ps1 help
.\ezvm.ps1 version
.\ezvm.ps1 doctor
.\ezvm.ps1 bootstrap
.\ezvm.ps1 base acquire
.\ezvm.ps1 base build
.\ezvm.ps1 create <name> [-Profile light|normal|heavy] [-BaseId <base-id>] [-Cpus <n>] [-MemoryMiB <n>]
.\ezvm.ps1 list
.\ezvm.ps1 status <name>
.\ezvm.ps1 start <name>
.\ezvm.ps1 stop <name>
.\ezvm.ps1 ssh <name>
.\ezvm.ps1 exec <name> -- <command> [arguments]
.\ezvm.ps1 copy-to <name> <host-file> <guest-path>
.\ezvm.ps1 copy-from <name> <guest-path> <host-file>
.\ezvm.ps1 reset <name>
.\ezvm.ps1 clone <source> <destination> -Mode fresh|stateful
.\ezvm.ps1 export <name> <new-directory>
.\ezvm.ps1 import <name> <image-path> [-ManifestPath <manifest-path>] [-Profile light|normal|heavy] [-Cpus <n>] [-MemoryMiB <n>]
.\ezvm.ps1 portability check
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

`base acquire` downloads the exact reviewed Ubuntu 24.04 LTS Noble amd64 release
image into `runtime/cache/source-images`, verifies its repository-reviewed SHA-256
before atomic promotion, and records provenance beside it. Matching cached content
is rehashed and reused; corrupt or partial content is never accepted as authoritative.
The source image is not booted or modified by acquisition.

`base build` validates the managed QEMU runtime and verified Ubuntu source, boots
only a temporary QCOW2 overlay, feeds build-specific NoCloud data through a
loopback-only HTTP listener and QEMU `guestfwd`, validates the baseline toolset,
cleans cloud-init/machine/SSH identity, then flattens and checks a standalone
QCOW2. Accepted bases are content-addressed by their complete SHA-256, carry a
provenance manifest, and are marked read-only under `runtime/bases/<base-id>/`.
Failed builds retain non-authoritative staging evidence for diagnosis.

The reviewed build process is reproducible in configuration/provenance terms; it
does not claim byte-for-byte reproducibility when Ubuntu package repository state
or timestamps differ between builds.

EZVM-005 provides the internal storage layer used by later instance/lifecycle
commands: overlays store a relative QCOW2 backing reference to the exact
content-addressed prepared base, complete chains are validated with machine-readable
`qemu-img` output, stopped-only diagnostics require explicit lifecycle evidence,
and reset storage is replaced only after a candidate overlay validates. No public
instance-create/start command is introduced by EZVM-005.

The SSH start path waits beyond QEMU RUNNING until
the forwarded localhost SSH endpoint authenticates with the ezvm controller key,
the guest proves its requested instance/base/resource and coding-profile identity,
cloud-init reports completion, and the versioned readiness document and live
coding-environment checks pass. The controller private key and
per-instance known-hosts trust remain under ignored `runtime/keys`; only the
public key enters the instance NoCloud seed. SSH forwarding is explicitly bound
to `127.0.0.1`; no TAP, bridge or LAN listener is configured.

`exec` preserves the remote program's exit status and captured stdout/stderr.
The directional `copy-to` and `copy-from` commands use the same scoped key and
host-key policy.

EZVM-008 makes `runtime/instances/<name>/instance.json` the durable recoverable
instance authority. `create` resolves a named resource profile plus optional
CPU/RAM overrides, validates the prepared base, allocates a unique localhost SSH
port while holding the bundle allocation lock, and publishes the one-level QCOW2
overlay. `list` reconstructs the registry from instance directories instead of
trusting a separate opaque index. Starts reuse the persisted SSH reservation and
fail if another instance or unrelated listener conflicts with it. QMP and seed
ports remain ephemeral bound resources. Version `0.0.0-dev` is not the v0.1
release.

## Default coding guest

New instances use `coding-default` version `1`, independently of the
`light`/`normal`/`heavy` CPU and RAM resource profile. The prepared base supplies
Git, GCC/G++ and Make, CMake, Ninja, Python 3 with pip and venv, curl/wget, jq,
ripgrep, zip/unzip, rsync, tmux and OpenSSH. First-boot provisioning validates
these tools without reinstalling them.

SSH logs in as `coder`, with home `/home/coder` and a writable workspace at
`/home/coder/workspace`. The password is locked and SSH password authentication
is disabled. `coder` has unrestricted passwordless sudo **inside the guest**,
so coding agents can install dependencies in their disposable VM. Commands run
through sudo can alter all guest state, including any credentials in its overlay.

Install and authenticate your preferred coding agent inside that mutable overlay.
Node, Rust, uv and commercial agent CLIs are not preinstalled. Use reviewed,
version-pinned acquisition instructions; the default profile has no remote
`curl | shell` installer. Guest login state survives stop/restart. Reset returns
to the instance's selected base: a clean prepared base discards later login
state, while a stateful snapshot can restore authentication already saved in that
baseline. Stateful clones, exports and imported bases can contain credentials
and must be treated as sensitive.

See [Using the coding guest](docs/CODING-GUEST.md) for setup, credential
persistence, readiness diagnosis and future-profile guidance. Existing
`ezvm-core` version `1` instances remain visible to `list`, `status` and
`stop`, but cannot start under the new coding-ready contract. Create a new named
instance; the old overlay is retained without silent migration.

## Reset, clone and portability

Stop an instance before reset, clone or export. Every operation proves stopped
ownership and rejects ambiguous state. Clone mode must be explicit:

~~~powershell
.\ezvm.ps1 stop work
.\ezvm.ps1 clone work fresh-work -Mode fresh
.\ezvm.ps1 clone work saved-work -Mode stateful
.\ezvm.ps1 export work 'D:\VM exports\work'
.\ezvm.ps1 import imported-work 'D:\VM exports\work\disk.qcow2'
.\ezvm.ps1 reset work
~~~

Fresh mode creates an empty overlay on the source's existing base. Stateful mode
preserves its guest-visible disk in an independent immutable derived base, then
creates a new destination overlay. Both receive distinct instance identities and
SSH reservations. Export publishes a new directory containing a standalone
`disk.qcow2` and a digest/provenance manifest; it never uploads the result.
Import refuses external backing chains and normalizes the validated image into
one immutable base plus one mutable overlay. Structural import acceptance does
not promise an arbitrary image can satisfy the coding guest's boot/readiness
contract.

New instances and resets use version 2 durable intent with an explicit identity
generation. A normal stop/restart or cold relocation preserves this identity;
reset changes it, and copied guests must prove their destination identity before
READY. Version 1 complete coding-default intent remains supported without an
implicit rewrite during reads or ordinary starts.

For a cold move, cleanly stop **every VM**, run `.\ezvm.ps1 portability check`,
and copy the complete source/runtime folder. Run the check again from the new
root, followed by `doctor` and `start`. Relative backing paths need no rebase;
stopped runtime paths are revalidated and regenerated. Keep the original copy
stopped when using the relocated bundle on the same host.

See [Reset, clone and move coding environments](docs/PORTABILITY.md) for the full
semantics, sensitive-snapshot boundary and recovery behavior.

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

## EZVM-006 runtime lifecycle

EZVM-006 adds headless lifecycle control for already-created instances. `status
<name>` reconciles durable intent, runtime evidence and observed Windows process
identity. `start <name>` validates the complete EZVM-005 QCOW2 chain and starts
the managed QEMU executable with WHPX, explicit q35/virtio devices, per-instance
UEFI variables, serial/QEMU logs and a host-local QMP management channel. `stop
<name>` requests guest `system_powerdown` over QMP and waits for clean QEMU exit.

A stored PID is never sufficient to prove ownership. Active runtime evidence
includes process start time, managed QEMU executable path and a SHA-256
fingerprint of the observed argv, including the instance-specific QEMU name
marker. Stale or ambiguous ownership fails closed. A graceful-stop timeout does
not silently kill QEMU; the instance remains STOPPING until ownership is
reconciled.

The public start path uses WHPX and never silently substitutes TCG. Explicit TCG
is reserved for bounded qualification/troubleshooting paths.


## EZVM-007 SSH and readiness

Each launch uses QEMU user networking with a virtio NIC. The SSH forward has the
explicit form `hostfwd=tcp:127.0.0.1:<port>-:22`. A temporary loopback seed
server is exposed only to the guest through
`guestfwd=tcp:10.0.2.100:8000-tcp:127.0.0.1:<seed-port>`; SMBIOS points
NoCloud at `http://10.0.2.100:8000/`.

The controller identity is an Ed25519 keypair in `runtime/keys`. On Windows the
private-key ACL is restricted to the current user with `icacls`. ezvm requires
`ssh.exe`, `scp.exe` and `ssh-keygen.exe`; `doctor` reports a concrete
OpenSSH Client remediation if any are unavailable.

Host-key checking is never disabled. First-use/re-key bootstrap uses `ssh.exe`
with `StrictHostKeyChecking=accept-new` only against an empty launch-local
candidate known-hosts file, with `UpdateHostKeys=no` and Ed25519 host keys.
Normal SSH/scp uses `StrictHostKeyChecking=yes` against the managed per-instance
file. The temporary candidate becomes durable trust only after managed-key SSH
succeeds and the guest proves the exact requested ezvm identity, completed
cloud-init, validated coding-ready document and live guest checks. A changed key
therefore never overwrites existing
trust merely because a new SSH endpoint was observed. Failed or mismatched
identity proof leaves the previous trust entry untouched. `ssh-keyscan` is not
used: affected Windows OpenSSH builds can fail its KEX negotiation against modern
Ubuntu OpenSSH even when `ssh.exe` itself is compatible.

Launch SSH metadata lives in per-instance `access.json`, separately from durable
instance intent and process-lifecycle state. Its version 2 schema records base,
resource-profile and coding-profile identity, including the provisioning version
and digest. It contains no relocatable absolute path and is valid only while its
launch ID matches the current RUNNING QEMU process. Durable SSH reservations and
resource profiles are reconstructed from `instance.json` by the EZVM-008 registry.
