# Dashboard RAG 05 — VM lifecycle, provisioning and demonstration profile

Status: target requirements for DASH-08/09/10. Existing
[QEMU](../02-HOST-QEMU-CONTRACT.md), [storage](../03-QCOW2-STATE-CONTRACT.md),
[SSH](../05-NETWORK-SSH-CONTRACT.md), [portability](../06-SECURITY-PORTABILITY-CONTRACT.md)
and [CLI](../07-CLI-STATE-CONTRACT.md) contracts still govern implementation.
Proposed API spellings are not accepted CLI commands.

## Lifecycle prerequisites

A public start call has a bounded result independent of the VM's intended lifetime.
Separate budgets for process launch, boot/readiness, guest tools and stop. Preserve
the native process identity and output evidence needed for diagnosis. Readiness
distinguishes configured intent, live process, authenticated guest identity and
coding-ready qualification. Recovery handles stale records without assuming safe
ownership or blindly killing a PID.

Historical ACL, first-boot/WHPX, CPU feature, SSH selection and start-pipe findings
are hypotheses/reproductions tied to revisions, not blanket current defects.
Inventory the owner's two patches and test applicability before proposing a change.
Do not overwrite them or use the owner's original live QEMU start session as a test.
Use isolated fixture roots and separately authorized disposable VMs.

## Provisioning transaction

Initial supported changes: **stopped-only** vCPU/RAM and virtual disk growth.
Hotplug, shrink, arbitrary backing chains and automatic worker resume are excluded.

1. Preview target identity/revision, requested vs effective resources, host reserves,
   worker implications, exact stages and recovery limitations.
2. Quiesce only owned work according to an explicit command; prove VM stopped and
   lock its exact generation. Unknown/running state refuses mutation.
3. Preserve intent and recoverable stopped overlay evidence before disk change.
   Managed backing bases remain immutable.
4. Apply supported CLI/API operations, updating intent and readiness identities
   consistently; never implement provisioning by editing one JSON file from the UI.
5. Start only when authorized in the plan; verify readiness and guest geometry.
   Partition/filesystem growth is its own supported, journalled guest operation.
6. Compare requested/effective/guest values and offer a separate explicit worker resume.

Persist stages and verify effects on restart. Disk enlargement followed by guest
writes cannot be undone by shrinking metadata. Recovery may continue growth or
restore a proven pre-change stopped snapshot, with explicit data-loss implications.
Never take a live disk copy and call it a clean rollback. Other VMs and bases must
remain byte/identity unchanged. No host driver/pagefile or other-VM resource edits.

## Clean devbox recipe

The field-test VM informs a recipe and fixtures; it is not the distributable artifact.
Build a clean versioned profile from verified base + pinned tools + reviewed model/
runtime manifests. No accounts, tokens, private SSH identities, authenticated
overlays, raw reasoning or personal project history are bundled.

The first-run plan displays prerequisites, licenses, hashes, download sizes, disk/RAM/
commit requirements and optional account setup. Installation is resumable with explicit
partial-state reporting. A supported local-first path requires no paid subscription/API.
Optional free endpoints may need accounts and can become unavailable; never hide this
or fall back to paid use. Offer labelled replay when live prerequisites are absent.

“One click” describes a prepared subsequent launch, not a guarantee that a clean
machine has virtualization, a suitable GPU or downloaded weights. Hardware/model
tiers require measured qualification on exact versions; no extrapolation from one
TITAN configuration or small-context test.

## Demonstration acceptance

A clean exercise produces a small implementation, independent review with a supported
finding, repair and verified outcome. Preserve identities and measured interventions,
downloads, time to first accepted change and restart recovery. Include a small seeded
defect/fixture where useful; distinguish replay from live inference. Close acceptance
only on actual artifacts/checks, not the model's narration. No paid model or real
devices are required for fixture tests; live qualification needs an explicitly
available permitted local/free configuration.
