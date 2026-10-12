# EZVM-011 hardening review record

Base reviewed: `35c6e7408b1a96bd872fac584e43117aea3ea4c6` (accepted EZVM-010).
This record maps risks to implementation and regression ownership; test/run
acceptance is recorded separately in the implementation PR. It is not a claim of
independent penetration testing or protection against guest-root attestation fraud.

| Boundary | Concrete change or retained guard | Regression owner |
| --- | --- | --- |
| Download cache | Guard before deletion; per-artifact lock; own-temp-only cleanup; HTTPS redirects/total/byte bounds | Security, Download |
| JSON/control state | All-ancestor reparse refusal; bounded UTF-8 reads; atomic replacement retained | Security, Json |
| Cleanup | Preflight bounded descendants; nonrecursive bottom-up unlink; no outside target attribute change | Security, Storage, Portability |
| QEMU/extractors | Hold/reverify downloaded inputs; inventory extracted bytes; refuse changed installed files before version probe or tool resolution | Security, Qemu |
| Ubuntu source / prepared base | Reviewed digest before use; no user credentials in either seed template; immutable publication rules retained | Security, SourceImage, BaseBuilder |
| Controller identity | Exact verified ACL, hard-link refusal, lock and actual derived public/private comparison | Security, Ssh |
| Seed lifetime | Bounded payload/client/log history; close sockets and clear payload references; remove build seed files on failure | Security, SeedServer, Recovery |
| SCP host output | Explicit outside-runtime filename, private same-directory staging, atomic publication on success only | Security; real security extension |
| Mutable QCOW2 | Raw-header dependency refusal before production traversal; invariant/positive-owner guards retained | Security, Snapshots, Portability |
| Runtime/PID reuse | No weakened matching or implicit force stop; bounded Windows query; diagnosis cannot rewrite STALE/UNKNOWN | Runtime, Recovery |
| Staging/reset recovery | Journal barriers and original data remain; bounded diagnosis never follows journal instructions | Recovery, Portability |
| Secret summaries | High-confidence source/base token guards and redaction before truncation; raw explicit output remains documented | Security, Repository |
| Guest readiness | Exact identity/current-boot finalizer/live checks unchanged; no threshold relaxation | PortabilityIdentity, CodingReadiness; real portability |

## Explicit residual boundaries

The trusted host owner controls source, manifests, runtime receipts and keys.
The local payload inventory is not a signature against that owner. Path checks
are not kernel-enforced race protection against a concurrent hostile administrator.
An explicit user-selected external file can contain secrets even when its name is
innocuous. Token patterns are a bounded backstop, not proof of no possible secret.
Raw guest logs and requested remote output require review before publication.

Safe recovery deliberately refuses ambiguous half-transactions rather than
choosing which disk/intent is correct. No automatic repair, unsafe rebase, commit,
force-share, PID-only kill, relaxed SSH trust or guest-readiness bypass was added.
Sensitive snapshots remain distinct from credential-free clean prepared images.
No provider/version pins, guest profile versions or WHPX settings were changed.
