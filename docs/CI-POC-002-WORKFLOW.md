# Trusted manual CI-PoC002 workflow

This publication makes `.github/workflows/ezvm-ci-poc-002.yml` available for an
explicit owner dispatch. It registers no runner and starts no qualification by
itself. Runloc issue22 owns the ephemeral registration, reusable backing host,
job source/candidate approval and final evidence/cleanup acceptance.

The definition accepts only owner dispatches in techrote/ezvm, a first attempt,
and the exact fresh UUID-labelled runner selected by the host. It checks out
Runloc `22cdae183bd1c2d56a880879ad88bb63ffb1888d`, which pins the public
eight-CPU EzVM candidate. It invokes the reviewed outer supervisor, first exact
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
