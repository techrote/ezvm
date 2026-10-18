# CI-POC-002 qualification resources

The owner requested eight virtual CPUs and no overall qualification time limit
for the next trusted Actions execution on the reusable Windows/WHPX backing host.
Runloc issue22 owns runner registration, source pinning, receipt validation and
owned cleanup. CI-POC-001 remains completed on its previously recorded sources.

The original full release/portability harness now accepts `-QualificationCpus 8`.
It changes only its new disposable source copy: a normal runtime configuration
override sets all named profiles to eight CPUs while preserving their memory,
and the copied prepared-base recipe uses eight CPUs. Product defaults and the
immutable checkout remain unchanged. The normal-profile assertion, all original
release markers and per-operation deadlines still apply. Each authenticated
READY response is followed by matching durable-intent and guest online-CPU
assertions, including restart and relocation. Missing or mismatching evidence
fails the harness. Omitting the option retains the original resources.

This changed harness requires fresh exact-source full physical acceptance.
Earlier four-CPU receipts do not qualify it. The host-side supervisor and runner
job explicitly select `-NoOverallTimeout`; elapsed time remains measured. The
backing environment is reusable, while every GitHub runner registration and its
job workspace are single-use. Hosted full TCG remains deferred under issue23.
