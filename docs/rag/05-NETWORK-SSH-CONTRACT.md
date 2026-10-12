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
3. verify requested instance identity;
4. wait for cloud-init completion;
5. verify ezvm readiness marker.

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
`ssh.exe`, `scp.exe`, `ssh-keygen.exe` and `ssh-keyscan.exe`. Missing
tools fail with OpenSSH Client remediation and are also reported by `doctor`.

Host trust is bundle-scoped at
`runtime/keys/known-hosts/<instance>.known_hosts`. SSH/scp always use
`StrictHostKeyChecking=yes`, that managed file and an empty global-hosts source;
the user's global known_hosts is neither trusted implicitly nor modified.

For an untrusted first launch, `ssh-keyscan` material is written only to a
temporary candidate file. The candidate is promoted to managed trust **after**
controller-key authentication and the authenticated guest proves the requested
ezvm identity, completed cloud-init and readiness marker. If a previously trusted
instance presents different key material, EZVM-007 fails closed. Automatic
replacement is intentionally reserved for a later explicit reset/rebuild flow
that can prove an identity transition.

The configured 22000-22999 range is scanned under a bundle allocation lock and
must also be bindable on loopback. This is sufficient for the EZVM-007 launch
path; EZVM-008 owns durable per-instance allocation, persisted collision
accounting and full concurrent multi-instance resource management.

Per-launch `access.json` records only instance/launch identity, localhost SSH
endpoint, user/profile, provisioning state and READY timestamp. It is accepted
only when its launch ID matches a safely RUNNING EZVM-006 runtime state.
