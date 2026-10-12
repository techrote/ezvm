# 05 — Networking and SSH contract

## Default network

Use QEMU user-mode networking for v0.1.

QEMU documents that user-mode networking:

- requires no administrator privilege;
- provides DHCP/NAT to the guest;
- uses 10.0.2.0/24 by default;
- exposes the host/gateway at 10.0.2.2 by default;
- blocks unsolicited inbound access unless explicit forwarding is configured.

References:

- https://www.qemu.org/docs/master/system/devices/net.html
- https://www.qemu.org/docs/master/system/qemu-manpage.html

## Guest NIC

Use an explicit virtio network device supported by the Ubuntu guest rather than relying on a changing QEMU default NIC model.

## SSH forwarding

Each running instance receives a unique host TCP port.

The forwarding contract is equivalent to:

~~~text
hostfwd=tcp:127.0.0.1:<allocated-port>-:22
~~~

Binding to 127.0.0.1 is mandatory by default. Do not expose guest SSH on all host interfaces.

Default allocation range should be configurable. A reasonable initial range is 22000-22999.

## SSH client

The v0.1 implementation may use the Windows OpenSSH client when ssh.exe/scp.exe are present.

doctor and relevant commands must detect the client explicitly. If missing, fail with clear remediation instead of pretending the VM failed.

Do not place passwords on ssh command lines.

## Host key policy

Do not globally disable host-key checking.

ezvm should maintain a bundle-local known-hosts file or equivalent scoped SSH trust state.

Resetting/rebuilding an instance can change its host key. ezvm must update only the scoped entry associated with that managed instance/forwarded port after proving the instance identity through the provisioning contract.

Never modify the user's global known_hosts as an implicit side effect.

## Controller key policy

Generate or import an ezvm-scoped SSH keypair into runtime/keys.

The private key is runtime state, gitignored and permission-restricted where Windows permits.

Only the public key enters instance cloud-init.

The prepared base contains no ezvm private key and no user-specific credential.

## Cloud-init seed transport

cloud-init supports a NoCloud HTTP seed URL through SMBIOS.

Prefer keeping the seed listener host-local rather than exposing a temporary HTTP listener to the LAN.

QEMU user networking supports guestfwd. A safe design is:

~~~text
guest requests: 10.0.2.100:<guest-seed-port>
        |
        v
QEMU user guestfwd
        |
        v
127.0.0.1:<temporary-host-seed-port>
~~~

The SMBIOS NoCloud seed URL points at the guest-visible forwarding address.

The minimal seed server should:

- bind only to loopback;
- serve only GET/HEAD as needed;
- expose only user-data and meta-data for the active build/instance;
- return failure for unknown paths;
- terminate after provisioning or timeout;
- avoid logging credential-like user-data unnecessarily.

## Readiness polling

After QEMU starts:

1. wait for the host-forwarded SSH port;
2. attempt authenticated SSH with bounded timeout;
3. verify requested instance, base, resource and coding-profile identity;
4. wait for cloud-init completion;
5. validate the complete versioned coding-ready document and its completion state;
6. run fresh tool/account/workspace checks through the authenticated session.

All loops require a total timeout and useful progress/error output.

## exec

ezvm exec <instance> -- <command> runs a non-interactive command through SSH and returns the guest command exit status where practical.

Do not hide remote stderr or coerce a non-zero guest command to success.

## ssh

ezvm ssh <instance> opens an interactive session using the instance's managed key, known-hosts scope and port.

## File transfer

A copy/scp helper may wrap scp.exe.

Paths must be unambiguous about host-to-guest and guest-to-host direction. Tests must cover spaces in host paths.

## Network non-goals

v0.1 does not automatically configure:

- TAP adapters;
- Windows bridges;
- Hyper-V switches;
- direct LAN addressing;
- inbound port forwarding other than explicitly managed localhost forwards.

These may be future opt-in features.

## Implemented base-build seed transport (EZVM-004)

Prepared-base construction uses a minimal TCP HTTP implementation rather than
Windows HTTP.sys, so normal use does not require URL reservations or elevation.
The listener binds explicitly to `127.0.0.1` on an ephemeral host port.

QEMU user networking maps the fixed guest-only endpoint
`10.0.2.100:8000` to that loopback listener with `guestfwd`. SMBIOS carries
`ds=nocloud;s=http://10.0.2.100:8000/`; the trailing slash is mandatory.

The direct `guestfwd=...-tcp:127.0.0.1:<port>` target is a QEMU chardev that
persists for the VM lifetime. The seed server therefore keeps that accepted
host-side TCP connection open and parses multiple sequential HTTP requests from
the same stream. Closing the host socket after the first seed request would make
later NoCloud fetches retry against a dead forwarding channel.

The seed server:

- serves only `GET`/`HEAD` for the standard NoCloud paths
  `/user-data`, `/meta-data`, `/vendor-data`, and `/network-config`;
- returns the reviewed user/meta content and explicit empty 200 responses for
  vendor/network data so current cloud-init does not spend its datasource retry
  budget on absent optional seed files;
- returns 404 for every other path and 405 for unsupported methods;
- uses no directory traversal or generic file serving;
- has a bounded lifetime controlled by the build timeout;
- records only requested path names/counts for diagnostics, never seed bodies.

The base-build path deliberately has no SSH host forwarding and no build SSH key.
Outbound user-mode networking remains available so Ubuntu package acquisition can
complete.


## Implemented instance SSH transport and trust (EZVM-007)

Normal instance launches extend the existing explicit QEMU user netdev with:

~~~text
hostfwd=tcp:127.0.0.1:<ssh-port>-:22
guestfwd=tcp:10.0.2.100:8000-tcp:127.0.0.1:<seed-host-port>
~~~

and SMBIOS NoCloud discovery at `http://10.0.2.100:8000/`. Both host endpoints
are loopback-only. There is no omitted hostfwd bind address and no TAP/bridge
configuration.

The controller Ed25519 key lives under `runtime/keys`; only its public half is
served to cloud-init. Windows private-key creation is followed by an ACL
restriction to the current user. The required command-line client boundary is
`ssh.exe`, `scp.exe` and `ssh-keygen.exe`. Missing tools fail with OpenSSH
Client remediation and are also reported by `doctor`. `ssh-keyscan` is
deliberately not in the runtime boundary because affected Win32-OpenSSH builds
can negotiate a KEX they do not implement against modern OpenSSH servers.

Host trust is bundle-scoped at
`runtime/keys/known-hosts/<instance>.known_hosts`. Normal SSH/scp use
`StrictHostKeyChecking=yes`, `UpdateHostKeys=no`, Ed25519 host keys, that
managed file and an empty global-hosts source. This prevents the OpenSSH client
itself from rewriting managed trust behind ezvm's state machine; the user's
global known_hosts is neither trusted implicitly nor modified.

For an untrusted first launch or possible re-key, ezvm creates an empty
launch-local candidate file and invokes `ssh.exe` with
`StrictHostKeyChecking=accept-new` **only for that candidate**. Host-key
selection is constrained to Ed25519 and `UpdateHostKeys=no` prevents additional
keys being learned behind the state machine. This is not a global bypass: once a
candidate exists, subsequent connections must match it.

The candidate is promoted to managed trust **after** controller-key
authentication and the authenticated guest proves the requested ezvm identity,
completed cloud-init, the coding-ready document and live environment checks.
Existing managed trust remains
untouched until that proof succeeds; failure or identity mismatch leaves it
intact. This is the controlled reset/rebuild re-key path.

The configured 22000-22999 range is scanned under a bundle allocation lock and
must also be bindable on loopback. EZVM-008 persists the selected port in each
instance's durable intent and enforces collision accounting across named
instances, as described below.

Per-launch `access.json` schema version 2 records instance/launch/base identity,
localhost SSH endpoint, coder user, resource profile, cloud instance ID, coding
profile name/version/digest, provisioning state and READY timestamp. It is
accepted only when its launch ID matches a safely RUNNING runtime state.

## Durable SSH allocation (EZVM-008)

The host SSH port is now assigned during instance creation and persisted in
`instance.json`; normal starts do not choose a fresh port. Allocation is
serialized by the bundle SSH-allocation lock and excludes both ports reserved by
other valid instance intents and ports that cannot be bound on
`127.0.0.1`.

Before start, ezvm reconstructs allocation authority, proves that the persisted
port is not reserved by another instance, and verifies current loopback
availability while still holding the allocation lock. The lock remains held
through QEMU startup until QEMU reaches RUNNING, at which point the QEMU
`hostfwd` owns the reservation. A race with an unrelated non-ezvm process can
therefore still make QEMU fail, but it cannot silently redirect or share the
managed endpoint.

The temporary NoCloud listener remains an already-bound ephemeral loopback port,
and QMP continues to use an independently locked ephemeral port. Neither is
persisted as portable instance intent.

## Coding readiness and fresh checks (EZVM-009)

SSH authentication authorizes the readiness probe; it does not by itself prove
the guest is ready for coding. The probe returns the complete
`/etc/ezvm/identity.json` and `/var/lib/ezvm/ready.json` documents. Both must use
the expected schema version 2 and match the requested instance, base, resource
profile, cloud instance ID and supported coding profile name/version/digest.
The ready document must also contain `provisioningState: complete`.
`cloud-init status` must both return exit code 0 and report exactly `done`.

The same authenticated attempt checks required commands, Python venv support,
the locked-password coder account, SSH password policy, guest sudo policy and
workspace ownership/writeability. A missing tool or broken account/workspace
cannot be hidden by an old readiness file. Mismatched identity, malformed state
or completed-but-invalid provisioning fails instead of promoting trust or
recording READY. Missing/incomplete startup evidence can be polled only within
the existing total readiness deadline. Live checks consume that same deadline:
a late successful proof is rejected. An individual authenticated probe is capped
at 120 seconds, the guest validator at 110 seconds and its Python venv check at
90 seconds; none extends the total launch budget.

These checks describe readiness at the successful launch probe. Agent activity
can subsequently change the guest; READY is not continuous enforcement or
remote attestation against a guest controlled by root. Each later start requires
the authenticated live checks again.

## Copied guest identity and trust (EZVM-010)

New/reset instances use an explicit durable identity generation. The host binds
the generation into cloud-init/DMI identity, and the guest initializes a distinct
machine ID and Ed25519 host key before READY. The first initialization performs
one guest reboot inside the same total launch-readiness budget. A normal restart
or complete cold relocation preserves the adopted key and machine identity.

Version 2 intent still requires successful finalizer completion in the current
guest boot before READY on every launch. The finalizer service retains its
successful completion state for that boot. An unchanged generation and matching
READY document from a previous boot cannot authorize READY while the current
boot's finalizer is pending. This applies equally to normal restart and cold
relocation.

A copied snapshot can briefly expose the source SSH key and source READY file
while its destination initialization is pending. The schema version 2 readiness
path first checks expected DMI identity, the destination generation marker and
adoption by the running boot, and successful finalizer completion in that boot.
Only the exact bounded pending protocol is retryable. Unpromoted candidate trust
is discarded during that transition, so the source's transient key cannot
prevent learning the destination key. Malformed proofs still fail closed.
Existing managed trust is retained until the final normal authenticated
identity, cloud-init, coding marker and live checks pass. After live validation,
the probe rechecks the same completed finalizer execution in the current boot
and the unchanged READY document before reporting success.
Current-boot completion supplements those checks: cloud-init must still report
exactly `done` with exit code 0, the complete identity and READY documents must
match, and live profile validation must succeed. All waiting and validation
consume the original absolute launch-readiness deadline.

Publishing PROVISIONING or READY also holds the instance lifecycle lock and
rechecks the exact durable intent, original launch ID and positively reconciled
RUNNING process. A late SSH result from a stopped, reset or superseded launch
cannot replace current access or managed trust. Guest waiting holds no lifecycle
lock, so stop remains available; final publication consumes the original deadline.

Destination provisioning replaces the managed inbound
`/home/coder/.ssh/authorized_keys` with the current controller public key.
Outgoing SSH identities/known-hosts and vendor-agent authentication remain guest
data and can be preserved in a stateful clone or export. No controller private
key enters the guest seed, snapshot provenance or readiness logs.
