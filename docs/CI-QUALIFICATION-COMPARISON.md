# Hosted TCG and optional private WHPX qualification

This branch prepares an explicitly dispatched, paired comparison. It does not
register a runner, install a service, change host privileges, or alter existing VMs.
Run a clean local pilot first; register an on-demand private runner only if measured
results and host prerequisites justify it. No WHPX performance PASS is claimed yet.

## Two independent lanes

The existing release workflow always uses GitHub-hosted `windows-2022` and TCG.
The optional private workflow uses WHPX. Both accept one exact candidate SHA and
comparison ID. They use the same full release/portability assertions, changing only
the explicit accelerator and its required evidence. Neither cancels the other.

The private lane is a **separate workflow**, not a required matrix leg or a dependency
of the hosted job. Its absence, queue or failure cannot delay hosted completion.
Keep only the intended hosted release check required in branch protection. A pending
optional private run must not become a generic "all checks must finish" merge gate.

The host-side dispatcher sends the hosted request **before** checking private
availability. It then requires an online, idle Windows/X64 runner with both
`ezvm-whpx` and a unique custom label equal to that runner's registered name.
No runner, busy runner, unknown inventory or failed optional dispatch is reported
explicitly while the hosted workflow continues. A runner may still disconnect
after the availability check; that optional queue does not block the hosted run.
Cancel abandoned optional queued runs rather than treating job execution timeout
as a queue timeout (GitHub can queue an unmatched runner for 24 hours).

Repository currently has no private runner registered. Ordinary PRs still start the
hosted workflow; private comparisons are explicit on-demand dispatches in this first
version. Automatic opt-in comparisons of approved PRs are a later controller extension.

## Clean pilot

Use a separate clean Git checkout containing this harness, with no owner patches.
The script records commit/tree, account/host, requested accelerator, timestamps,
actual exit, completion markers and total wall time under ignored
`runtime/qualification-pilot/`. Log lines have host UTC timestamps. The underlying
qualification creates its own fresh temporary roots/VMs; it never reuses trio-lab.

```powershell
.\scripts\Invoke-EzVmQualificationPilot.ps1 -Root (Get-Location).Path -Accelerator whpx -ExpectedCommit '<40-character SHA>' -PreflightOnly
# After prerequisite checks pass, omit -PreflightOnly for the full timed pilot.
```

Preflight uses synthetic non-key ACL fixtures and checks free RAM/disk. Failure
does not create a guest or claim a speed measurement. It neither elevates itself
nor applies the owner's two patches. The complete run preserves existing internal
launch/readiness/stop deadlines; caller interruption may leave diagnostic fixture
roots, which must be reconciled by exact ownership rather than globally killing QEMU.
The original TRIO QEMU session and other user VMs must never be used as cleanup targets.

Default qualification remains TCG for existing callers. WHPX must be requested;
base metadata and every READY result must agree with it. Feature detection alone,
PASS text with nonzero exit, or incomplete logs cannot yield a WHPX PASS.

## On-demand runner, after a successful pilot

Use the official Windows x64 Actions runner on a dedicated trusted host/account,
in foreground and preferably ephemeral (one accepted job), with no service install.
Register explicit custom labels `ezvm-whpx,<unique-runner-name>`. Do not install it
inside the Linux TRIO VM or expose it to arbitrary public-fork PR execution.
No permanent administrator token is added to workflow secrets by this design;
the explicit host dispatcher uses the host's existing GitHub CLI authorization.

The reviewed workflow files must exist on the repository's default branch before
GitHub can dispatch them. After accepted workflow/harness publication and runner
registration:

```powershell
.\scripts\Start-EzVmQualificationComparison.ps1 -CandidateSha '<approved exact SHA>' -WorkflowRef main
```

This is a write action: it dispatches hosted execution even when private execution
is unavailable. Only invoke it deliberately for reviewed same-repository source.
The dispatcher does not install or start the private runner. Its registration and
online status are prerequisites, not facts inferred from a cached local PID.

Compare logs/receipts by candidate SHA, comparison ID, accelerator, host CPU/RAM,
source tree, cache warmth and exact start/end scope. TCG-vs-WHPX measures two
deployment configurations, not pure machine speed. Run local TCG separately if
isolating host performance becomes necessary. Do not reuse mutable qualification
VMs or skip fresh-base assertions to improve the number.

## Checks and limitations

```powershell
.\scripts\Test-QualificationComparison.ps1
.\scripts\Test-Repository.ps1 -Root (Get-Location).Path
```

The focused tests assert actual stub dispatch counts/order for online/offline/busy/
unknown/failing runners, shared candidate identity, no false PASS, and the original
guest-start function's effective-accelerator refusal. They are not physical WHPX,
registered-runner or GitHub workflow execution qualification.

GitHub routing reference: https://docs.github.com/en/actions/reference/runners/self-hosted-runners
Runner setup: https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/add-runners
WHPX: https://www.qemu.org/docs/master/system/whpx.html
