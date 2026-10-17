# DASH-02 public observation fixtures

[schemas.json](schemas.json) records only synthetic structural samples and disposable
SQLite schema captures. It contains no real sessions, account credentials, private
logs or live engine responses. It is a compatibility projection, not a claim that all
OpenCode/engine releases have one schema.

`dashboard/tests/test_observation.py` materializes private temporary fixtures with
spaces/Unicode paths, aliased status ports, failed/oversized payloads and 1,100 sessions.
No fixture source is passed to a worker/VM/provider mutation endpoint. SQLite opens
only a disposable file-set copy; source sentinels and DB/WAL bytes are checked.

Run `python -B dashboard/qualify_observation.py --output <disposable-path>` from a
clean full Git checkout for an exact source/runtime/test/measurement receipt.
Explicit source-subset mode does not qualify a Git revision. See the
[research handoff](../../../docs/research/TRIO-2026-10/DASH-02-OBSERVATION.md) for case
mapping, limits and the separation from physical/live acceptance.
