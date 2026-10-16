# Dashboard delivery overview

The detailed delivery sketch has been expanded into the authoritative
[implementation/testing issue series](../programme/dashboard/README.md), with
[seven dashboard RAG contracts](../rag/README.md#dashboard-companion-target-contracts).
Use those issue bodies for future execution. This page is navigation, not a second
status or acceptance ledger.

The original DASH-01..12 identifiers are preserved; DASH-13 adds explicit
CI/packaging work. All are repository-local planned issues, not published GitHub
numbers. The existing read-only prototype is a partial foundation, not completion
of the whole observation gate. TRIO remains paused.

## Sequence

```text
DASH-01 fixtures/research -> DASH-02 scoped adapters
                              |                  |
                        DASH-03 tiles      DASH-04 metrics
                              +--------+---------+
                                       v
                                DASH-13 CI/package
                                       v
                                DASH-11 read-only qualification
                                       v
                                DASH-05 commands/pause
                                       v
                                DASH-06 reviews/rework
                                       v
                                DASH-07 pools/automations

DASH-01 -> DASH-08 lifecycle prerequisites
DASH-05 + DASH-08 -> DASH-09 provisioning
DASH-06 + DASH-07 + DASH-09 + DASH-13 -> DASH-10 clean demo devbox
DASH-03 + DASH-05 -> DASH-12 optional terminal embedding decision
```

Each arrow includes the issue catalogue's full prerequisites. DASH-11 establishes
reusable fault/performance tests and the read-only gate; later control issues extend
those tests at their actual mutation boundaries. DASH-12 is optional and does not
block the other gates.

See the [catalogue](../programme/dashboard/catalog.json) for machine-readable
scope/dependencies/RAG/research/test-case references, and run:

```powershell
.\scripts\Test-DashboardPlan.ps1
```

This integrity check has no VM, model, network or worker side effects. It checks
planning consistency, not product acceptance. Publication, implementation and
TRIO restart are separate actions.
