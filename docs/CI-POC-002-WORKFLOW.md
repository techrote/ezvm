# Trusted manual CI-PoC002 workflow

This publication makes `.github/workflows/ezvm-ci-poc-002.yml` available for an
explicit owner dispatch. It registers no runner and starts no qualification by
itself. Runloc issue22 owns the ephemeral registration, reusable backing host,
job source/candidate approval and final evidence/cleanup acceptance.

The definition accepts only owner dispatches in techrote/ezvm, a first attempt,
and the exact fresh UUID-labelled runner selected by the host. It checks out
Runloc `d3be2aa7677c338fab86508da6f390fcae1bc541`, which pins the public
resource-parameterized EzVM candidate with six guest vCPUs. It invokes the reviewed outer supervisor, first exact
preflight then the complete original release/portability scenario. Probe mode
does only bounded preflight and cannot claim physical qualification.

Both qualification supervisor invocations explicitly select NoOverallTimeout.
The former90-minute workflow setting is removed from this new execution path;
GitHub's own default360-minute job cancellation policy still applies. Original
operation limits, all release assertions, source identities, numeric exits,
all24 markers and normal owned cleanup remain required. No raw logs, ownership
leases, keys or disks are uploaded; only the helper's allowlisted public folder.

After normal publication, the host binds the exact reviewed workflow hash and
a `ci-poc-002-<workflow-commit>` tag to an immutable commit before registration.
A successful job must be tied to actual run/job/runner API identities and host
cleanup proof. The used registration is single-use; a fresh registration may
reuse the same qualified backing environment. This publication does not merge
the candidate PR46, claim a completed Actions qualification, change CI gates or
restart the owner-deferred hosted TCG qualification.
# Native PowerShell script policy

Both Windows script steps use a dedicated PowerShell process with
`-ExecutionPolicy Bypass -File`. This applies only to that process; the host's
execution policy is unchanged. The first real Actions attempt
[`39126080753`](https://github.com/techrote/ezvm/actions/runs/39126080753)
failed before checkout because the default `powershell` shell could not load
Actions' generated script under the host policy. The listener exited normally,
registration40 was removed, and no qualification harness ran. That attempt
remains failed evidence, not a physical result.

The checkout action receives process-local `core.autocrlf=false` and
`core.eol=lf` through Git's configuration environment. This matches Runloc's
reviewed clone procedure and preserves exact extensionless LICENSE bytes.
On native Windows, `text=auto` can otherwise produce CRLF even when autocrlf is
false but eol remains native. Actions run39126788794 stopped at the immutable
source guard before preflight because of this LICENSE conversion. The guard
is unchanged; no host Git setting, tracked source, candidate or assertion is
relaxed. A fresh full attempt must use the repinned merged definition.

The owner reduced the next guest allocation from eight to six vCPUs after the
interrupted native run39127529716. This definition pins the reviewed six-vCPU
controller/oracle. All eight authenticated READY observations and24 completion
markers remain required. The EzVM candidate helper already supports this
allocation; its immutable product source is unchanged. The GitHub runner is
native on the physical Windows PC; the EzVM Linux guest uses WHPX. No GitHub
hosted compute or runner-inside-guest isolation is claimed.

The host operator now uses a visible Explorer-owned console rather than a Codex
terminal child. Its lifetime was tested independently by terminating the
launching process Job and observing the console continue, then observing its
actual clean exit0. Closing that independent console, sleeping/signing out or
rebooting the PC can still interrupt qualification. No host service is added.
