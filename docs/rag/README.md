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
