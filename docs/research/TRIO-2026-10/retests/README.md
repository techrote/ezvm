# DASH-01 retained qualification receipts

## Initial implemented source

Implementation commit: `7c4b9373e4ba3f8fd1518b05218eed8008e368b7`.
Git tree: `ca4475adbec465ec5f8bbf1925b431c40197c74b`.
Baseline: `20dfca35bdd2fc8eab0b5fc52ae1b612b14d0e5e`.
[PR #41](https://github.com/techrote/ezvm/pull/41) is stacked on prototype PR #40;
these receipts do not imply either PR is merged or any release gate is accepted.

[Offline CI run](https://github.com/techrote/ezvm/actions/runs/38950387369):
Windows job `117139991252` and Linux job `117139990883` both passed.
Windows Server 2022 image `20261012.333.1`, Python 3.12.10: **64/64 tests PASS**,
including 25 unchanged dashboard tests and 39 DASH-01 tests. Linux Python 3.12.10
passed the 39 standard-library-only DASH-01 tests. No physical terminal or live
worker/VM/inference acceptance is claimed.

Commands executed by CI:

```text
python -B -m unittest discover -s dashboard/tests -v
python -B -m unittest discover -s dashboard/tests -p test_evidence.py -v
python -B dashboard/replay.py --source-revision 7c4b9373e4ba3f8fd1518b05218eed8008e368b7
./scripts/Test-DashboardPlan.ps1
```

The first unit-test command is Windows; the second is Linux. Windows also ran the
programme check: 13 issues, 62 required case IDs, 20 observations, 5 gates, 171 local
links and an acyclic dependency graph. All commands returned zero. The first-party
core CI and the separate real-release gate retain their own status; they are not
relabelled PASS by this record.

## Retained Windows receipt

[7c4b9373-windows.json](7c4b9373-windows.json) is the unmodified downloaded JSON,
not a newly executed or reconstructed result. Its per-fixture projections retain
failed/unverified/stale outcomes where expected; all 16 fixture assertions and 49
restart cuts passed with zero forbidden attempts and zero dispatch.

The artifact ZIP ID was `12068261140`, SHA-256
`d589977cc98bc51c25569a1d2ad334114c49f8fc6e089c8b4bf131a8f1c50145`.
Raw UTF-8 JSON file SHA-256 (including final LF):
`69a5d97b006ea1995f30e0287b61ddecd6b6fa95ab43b8bf54c4ddba1443f063`.
Canonical JSON SHA-256 used by the traceability ledger:
`714f4684755aadd676f8758949a5b64f1c6c3cf3d6b88ccf24b10c5d0a9cf8bb`.
Source-content identity:
`36b727fc8288f61c5a5094da861cc5181179e141b4a6e7c45fa30af6b9017707`.
Deterministic replay identity:
`ce302bf88db1cef4dd34f96a156dd06d413395f4d6c6b6a3065a08c36d1cb469`.

Replay ran from `2026-10-16T18:50:39.178327+00:00` to
`2026-10-16T18:50:39.287953+00:00`, exit 0. This duration is the fixture runner,
not the complete CI job or a physical performance qualification.

## Traceability interpretation

The three DASH-01 action references (FR-03, FR-17, FR-20) are verified only for
this synthetic-fixture implementation and cite the tested source/receipt above.
All 20 historical finding statuses remain proposed; the other 45 action references
remain proposed. The receipt verifies the original public observation/evidence blobs,
not access to private raw evidence. No TRIO restart occurred.

A later source/corpus change must supply new applicable evidence or downgrade these
action references; the validator rejects a stale receipt. Do not edit this original
receipt to claim a later source passed. Append a new record instead.
