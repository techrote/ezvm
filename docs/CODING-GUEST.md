# Using the coding guest

New ezvm instances use the repository-controlled `coding-default` profile,
version `1`. A successful `start` means the requested guest has authenticated
over localhost SSH and passed its versioned coding-environment checks.

## Create and enter an instance

After `doctor`, QEMU bootstrap, source acquisition and prepared-base construction
have succeeded, run these commands from the ezvm folder in PowerShell:

~~~powershell
.\ezvm.ps1 create work -Profile normal
.\ezvm.ps1 start work
.\ezvm.ps1 ssh work
~~~

The `-Profile` option selects CPU/RAM defaults: `light`, `normal` or `heavy`.
All three use the same `coding-default` guest profile. `create` selects the most
recent valid prepared base unless you provide `-BaseId`.

Inside the guest, work as `coder` in `/home/coder/workspace`:

~~~sh
cd /home/coder/workspace
mkdir first-project
cd first-project
git init
python3 -m venv .venv
. .venv/bin/activate
~~~

The example creates a local project and Python environment; it does not install
or authenticate a commercial coding agent. The host can also invoke tools
without opening an interactive session:

~~~powershell
.\ezvm.ps1 exec work -- git --version
.\ezvm.ps1 exec work -- python3 --version
~~~

## What is installed

| Area | Default tools and behavior |
| --- | --- |
| Source control | Git |
| Native builds | GCC, G++, Make, CMake and Ninja |
| Python | Python 3, pip and venv with a real venv/pip readiness check |
| Downloads and data | CA certificates, curl, wget and jq |
| Searching | ripgrep (`rg`) |
| Archives and transfer | zip, unzip and rsync |
| Terminal work | tmux and Bash |
| Guest control | OpenSSH server/client, sudo and cloud-init |

These stable dependencies are installed while building the prepared base. The
instance profile validates and configures the existing environment without
downloading or reinstalling packages at first boot. The exact baseline package
and required-command sets live in `guest/base-cloud-init/baseline.json` and
`guest/profiles/coding-default/v1/profile.json`.

Node, Rust, uv and vendor-specific agent CLIs are not preinstalled. Version 1 is
a stable environment for adding the tools you choose, and does not promise an
identical Ubuntu package version across separately rebuilt bases. Each accepted
base has its own immutable content identity and provenance.

## User, workspace and privileges

The normal login is `coder`, its home is `/home/coder`, and its workspace is
`/home/coder/workspace`. The workspace is owned by coder with mode `0750`.
Repeated provisioning preserves files already inside it; it does not recursively
change their ownership.

The coder password is locked. SSH permits public-key authentication, disables
password and keyboard-interactive authentication, and disables direct root SSH
login. Only the ezvm controller public key enters the instance's cloud-init
seed. The controller private key remains in the host's ignored runtime state.

`coder` has unrestricted passwordless sudo inside the VM:
`ALL=(ALL:ALL) NOPASSWD:ALL`. This lets a coding agent install project dependencies
without interactive guest-password prompts. It also means any agent running as
coder can become guest root, change the whole guest and read credentials stored
there. Use separate instances for work that should not share that trust. This
does not grant Windows administrator rights or mount the host filesystem.

## Install and authenticate your preferred agent

Install your chosen agent after entering the guest. Its executable, language
runtime, configuration and login state should be written into the instance
overlay, typically under coder's home or another normal guest path.

Use this installation procedure:

1. Read the agent vendor's official installation and authentication instructions.
   Select an explicit agent version and any required runtime version.
2. Prefer a versioned package or release artifact. Review the provider and
   verify its expected checksum or signature before running downloaded code.
   Keep the chosen version and provenance with your project/setup notes.
3. Install into the guest as coder where supported. Use guest sudo when the
   documented package installation requires it. Do not turn an unpinned
   remote `curl | shell` command into automatic profile provisioning.
4. Authenticate through the vendor's supported interactive or device-login
   flow inside that instance. Keep tokens and login files out of repository
   source, base recipes, profile manifests and shared diagnostics.
5. Run the vendor's version/status check and use the agent from your workspace.

The supported extension point is this mutable guest environment. ezvm does not
manage a vendor account or promise that a particular external installer will
remain compatible forever. If the tool needs Node, Rust or another runtime,
apply the same explicit version and acquisition policy to that dependency.

## What survives lifecycle operations

| Operation | Guest files, installed agents and authentication |
| --- | --- |
| Normal stop and restart | Preserved in the same overlay; an external provider can still expire or revoke a login. |
| Reset to the prepared base | Overlay state is discarded, including installed agents and guest login state. Reinstall and reauthenticate. |
| Intentional stateful clone/export | Can preserve source, software and credentials from the guest. Treat the resulting copy as sensitive. |
| Copy the complete ezvm folder after cleanly stopping every VM | Preserves included overlays and optional bundle SSH identity; destination runtime state is revalidated. |

`stop` and `start` are available now. Public reset/clone/export/import commands
are planned under EZVM-010; these persistence rules define their required
behavior, not additional commands available in this change. Never copy a live
VM disk as though it were cleanly stopped. Do not share an authenticated overlay
or export without deliberately deciding what credentials it contains.

## Readiness and diagnosis

Guest `/etc/ezvm/identity.json` records schema version 2, the instance, exact base,
resource profile, cloud instance ID, and coding profile name/version/digest.
`/var/lib/ezvm/ready.json` must contain the same identity and
`provisioningState: complete`. Host `access.json` records this launch's accepted
profile identity separately from durable `instance.json` and QEMU process state.

Before `start` returns READY, ezvm checks completed cloud-init, the full identity
and ready documents, the installed profile sources, and live tools, Python venv,
account/password/SSH/sudo policy and workspace. An old `ready.json` cannot hide a
missing required tool or a wrong profile. Readiness is a point-in-time check at
launch; it is not continuous enforcement against later guest changes.

If provisioning fails, inspect the error and the instance's runtime logs. In an
already available guest diagnostic session, `/var/lib/ezvm/provisioning-failed`
and `/var/log/ezvm-cloud-init-status.log` provide the profile/cloud-init failure
reason. Do not make the VM appear ready by editing its marker. Fix the actual
tool/account/configuration failure or create a fresh named instance from a valid
base, retaining the failed overlay when its files need recovery.

## Existing instances and future profiles

Instances created before EZVM-009 may record `ezvm-core` version `1`. Their
complete durable intent remains readable through `list`, `status` and `stop`.
Starting them under the new coding-ready contract fails with recreation guidance.
Create a new instance with a different name; ezvm preserves the old overlay and
does not silently reset, upgrade or relabel it. The older incomplete EZVM-006
intent format also remains unsupported.

To introduce a future profile, add a reviewed version directory such as a new
version under `guest/profiles/`, with explicit identity, required commands and
acquisition policy. Update the resolver, seed/state contract and tests to support
it. Public `create` currently exposes resource selection only; arbitrary guest
profile selection is not implemented.

Create a new named instance for a newly supported profile version. If the current
base already has the required stable dependencies, it can remain the backing
base; otherwise build a new immutable base with its own identity. Never edit an
existing prepared base in place or overwrite a released profile recipe to
silently change what an existing instance means. Changing profile source changes
its digest and requires explicit compatibility handling.
