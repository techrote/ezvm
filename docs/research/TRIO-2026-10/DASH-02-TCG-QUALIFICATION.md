# DASH-02 release gate: legacy timer self-check under hosted TCG

## Observed failure, not a dashboard test failure

[Release run 38977204627, job 117229632749](https://github.com/techrote/ezvm/actions/runs/38977204627/job/117229632749)
tested `b88ddf949d34bcb5e02b1b5452c63bc39184751f`, tree
`ed29d40e456be0b74335672628a15598b9ee1d5e`, on GitHub `windows-2022`.
Core Windows CI and DASH-01/DASH-02 passed. Real concurrency, stop/restart,
fresh clone and source reset also passed before the stateful clone failed.

The clone serial log records Linux `6.8.0-142-generic` panicking at guest
0.015 seconds in `check_timer -> setup_IO_APIC`: `IO-APIC + timer doesn't work`.
It never reached cloud-init or SSH. The reported SSH timeout was the remaining
844 seconds of the unchanged 900-second launch budget. This was not the
180-minute workflow timeout or a failed DASH-02 observation assertion.

Original public disposable-CI log SHA-256:
`3e4a9c23e55d0c541c60e5a2b640bd270cce877653b535e932a4374774bab1e3`.
[Read-only extraction](https://github.com/techrote/ezvm/actions/runs/38994853619)
retained the log and targeted clone section, artifact `12085729235`, archive
SHA-256 `60fca3b43daaf580b73245df9d42932a73e9f387f0448339420ee31400e80baf`.
The original failed run remains failed; extraction is not a VM qualification.

## Primary-source rationale and alternatives

The [kernel maintainer discussion](https://lkml.indiana.edu/hypermail/linux/kernel/2004.0/02257.html)
describes the same legacy self-check failing under VM scheduling delay and
recommends `no_timer_check` when QEMU's timer routing is sane. The
[kernel parameter documentation](https://www.kernel.org/doc/html/v6.6/admin-guide/kernel-parameters.html)
defines this as disabling the broken-timer-source test, not disabling APIC or
timers. [QEMU issue 2832](https://gitlab.com/qemu-project/qemu/-/issues/2832)
also records intermittent hosted-runner panics at this check under another
accelerator. That corroborates the mechanism; it does not prove this Windows
runner's precise scheduler cause or establish a general QEMU fix.

Blind retries, longer READY deadlines, `noapic`, CPU/security mitigation changes
and a production guest-policy change were rejected. The selected candidate is
an explicit **disposable release TCG fixture workaround**, recorded before
implementation on [issue #28](https://github.com/techrote/ezvm/issues/28#issuecomment-6228558921).

## Bounded contract amendment

`Invoke-EzVm010RealPortability.ps1 -ReleaseQualification -TcgTimerCheckWorkaround`
adds one GRUB fragment and runs `update-grub` in the new fixture base. The helper
is pure; the harness writes only its freshly copied template. Original/effective
UTF-8 template hashes are logged, and normal base provenance covers the changed
recipe. The finalizer still requires successful cloud-init before publication.
Repeated/malformed template adjustment fails closed.

After every authenticated READY (including reset, fresh/stateful clone, import
and cold relocation), the additional probe requires exactly one effective
`no_timer_check`, positive IO-APIC interrupt counts, a named clocksource and
advancing uptime across sleep. A missing option or broken timer remains a
failure. Broad APIC-disable/mitigations-off options are refused. This is not a
physical timer/performance measurement or a replacement for any release case.

The **initial vendor-image boot remains unmodified** because GRUB is configured
inside that build. The workaround applies to subsequent prepared-base boots;
an initial build panic still fails, without automatic retry. No claim of immunity
for every hosted boot is made. Any future upstream fix should be qualified before
removing this explicit compatibility mode.

The public module, default guest recipe, WHPX behavior, QEMU/CPU arguments,
provider pins, security settings, original release assertions and the 2400/900
second operation deadlines are unchanged. The flag is refused without explicit
release mode. Source packaging excludes this test-only helper and does not ship
the adjusted template or fixture base. No original TRIO environment is involved.

## Evidence boundary

`tests/TcgQualification.Tests.ps1` covers pure generation, provenance, refusal,
unchanged source and deadline boundaries. Windows execution and the full new
release run retain separate results on PR #42. Source/fixture checks alone are
not a recovered clone boot, a complete release PASS, or DASH-02 acceptance.
