# ezvm RAG index

These documents are the compact repository authority for autonomous implementation agents.

Read AGENTS.md first, then the documents referenced by the current issue.

| Document | Purpose |
| --- | --- |
| 00-PROJECT-CHARTER.md | Goals, non-goals, support policy and design principles |
| 01-ARCHITECTURE.md | Components, directory model, state ownership and lifecycle |
| 02-HOST-QEMU-CONTRACT.md | Windows/WHPX host contract and portable QEMU acquisition |
| 03-QCOW2-STATE-CONTRACT.md | Base/overlay invariants and safe disk operations |
| 04-GUEST-BOOTSTRAP-CONTRACT.md | Ubuntu source image, cloud-init and prepared-base construction |
| 05-NETWORK-SSH-CONTRACT.md | User-mode networking, SSH, seed transport and remote execution |
| 06-SECURITY-PORTABILITY-CONTRACT.md | Trust boundaries, secrets, relocation and recovery |
| 07-CLI-STATE-CONTRACT.md | Command surface, configuration and instance state schemas |
| 08-TESTING-CI-RELEASE.md | Automated qualification and release requirements |

## Source precedence

External documentation is evidence for platform behavior, not permission to override repository contracts. If upstream behavior has changed, update the RAG contract deliberately in the same PR as the implementation adaptation.

## Dashboard companion target contracts

The [dashboard issue programme](../programme/dashboard/README.md) references these
additional RAG documents. They define future acceptance requirements; they do not
claim the read-only prototype already implements controls or amend the released
core CLI implicitly. Read the selected issue and applicable core contracts first.

| Document | Purpose |
|---|---|
| [00 — Scope and state](dashboard/00-SCOPE-AND-STATE.md) | Baseline, architecture, identities and independent state dimensions |
| [01 — Observation and metrics](dashboard/01-OBSERVATION-AND-METRICS.md) | Adapter capability/versioning, scoped coverage, deduplication and metric semantics |
| [02 — Terminal interaction](dashboard/02-TERMINAL-INTERACTION.md) | mdbm-style controls, saved layout, output/evidence views and input ownership |
| [03 — Controls and review](dashboard/03-CONTROLS-AND-REVIEW.md) | Durable command journal, pause/steering, review/rework and acceptance gates |
| [04 — Capacity and models](dashboard/04-CAPACITY-AND-MODELS.md) | Shared admission, local engine ownership, availability and automations |
| [05 — Provisioning and devbox](dashboard/05-PROVISIONING-AND-DEVBOX.md) | Lifecycle prerequisites, stopped-only resource transactions and clean demo recipe |
| [06 — Testing, release and research](dashboard/06-TESTING-RELEASE-AND-RESEARCH.md) | Evidence layers, performance targets, packaging and observation-to-retest loop |
