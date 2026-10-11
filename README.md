# ezvm

Portable, disposable QEMU + QCOW2 coding-agent environments for Windows hosts.

## Target experience

From one folder:

~~~powershell
.\ezvm.ps1 doctor
.\ezvm.ps1 bootstrap
.\ezvm.ps1 base acquire
.\ezvm.ps1 base build
.\ezvm.ps1 create steelmoth
.\ezvm.ps1 start steelmoth
.\ezvm.ps1 ssh steelmoth
~~~

The intended v0.1 architecture is:

- repository-local PowerShell control plane;
- repository-local, hash-verified QEMU Windows runtime;
- WHPX hardware acceleration;
- pinned official Ubuntu Server 24.04 LTS cloud image;
- reproducibly built immutable prepared base;
- one thin QCOW2 overlay per coding-agent instance;
- headless QEMU;
- user-mode NAT;
- localhost-only SSH forwarding;
- cold portability by copying the stopped ezvm folder.

## Current state

The repository is in programme/bootstrap state. Implementation is defined by the dependency-ordered GitHub issues in:

- docs/programme/IMPLEMENTATION-PROGRAMME.md

Repository-local implementation authority and RAG material is under:

- AGENTS.md
- docs/rag/

The programme is deliberately issue-driven. Each implementation issue contains an autonomous execution prompt and requires implementation, tests, PR review, green automated checks, merge and post-merge verification.

## Design constraints

v0.1 intentionally avoids:

- system-wide QEMU installation;
- hand-maintained opaque golden images;
- arbitrary multi-level QCOW2 chains;
- bridged/TAP networking;
- Docker or WSL as required components;
- GUI management;
- committing VM images, installers, keys or credentials.

## External platform authority

Key upstream references are recorded in docs/rag. The principal sources are QEMU's WHPX, qemu-img and networking documentation, Ubuntu cloud-image releases, and cloud-init's QEMU/NoCloud documentation.

## License

No project license has been selected yet. Third-party QEMU and Ubuntu artifacts are not intended to be committed into this repository.
