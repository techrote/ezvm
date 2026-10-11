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

The seed server:

- serves only `GET`/`HEAD` for exactly `/user-data` and `/meta-data`;
- returns 404 for every other path and 405 for unsupported methods;
- uses no directory traversal or generic file serving;
- has a bounded lifetime controlled by the build timeout;
- does not log user-data or meta-data bodies.

The base-build path deliberately has no SSH host forwarding and no build SSH key.
Outbound user-mode networking remains available so Ubuntu package acquisition can
complete.

