# DASH-02 release gate: disposable Python capability probe

Status: **repair candidate; full Windows TCG qualification remains required**.
This records a new failure after the [TCG timer workaround](DASH-02-TCG-QUALIFICATION.md),
not acceptance of DASH-02, WHPX, the later portability stages or a TRIO restart.

## Observed failure, 17 October 2026

[Run 38996451290, job 117289977323](https://github.com/techrote/ezvm/actions/runs/38996451290/job/117289977323)
executed candidate `0d313f0f350c0af017fda205e1e2c556231cc0a1`, tree
`ba4be2d9aa5f1a90d8c7dca455c0b4cfee8c0132`, on GitHub-hosted Windows Server 2022,
PowerShell 5.1.20348.5622 and managed QEMU 11.1.0, using explicit TCG.

Source, concurrent secondary, same-instance restart and fresh-clone boots reached
authenticated READY and passed the effective kernel-option/IO-APIC/clock checks.
The **reset-source** boot then completed cloud-init and entered the coding profile:

```text
[131.760707] EZVM_GUEST_FINALIZE_STAGE=coding-profile
[224.750991] Python venv with pip is unavailable or exceeded its 90 second validation deadline
```

At 04:55 UTC the host correctly refused current-boot finalizer failure, exit 70.
The stateful-clone, imported-export and relocated-clone boots were **not reached**;
this run cannot qualify them. The prior early IO-APIC panic did not recur in the
boots observed here, but absence in these boots is not a general timing repair.

The roughly 93-second interval is consistent with the 90-second probe deadline.
However, the old probe discarded all child output and merged timeout and command
failure into one message. It did not retain a phase or numeric child exit. The
exact failing child, CPU cost and disk/scheduling contribution remain unknown;
no measured TCG storage bottleneck is claimed.

The [scoped amendment](https://github.com/techrote/ezvm/issues/28#issuecomment-6232225343)
was recorded before implementing this candidate.

## Candidate correction and unchanged requirements

The ordinary `python3 -m venv` path still executes real offline ensurepip, followed
by the venv interpreter-isolation assertion and live `python -m pip --version`.
There is no `--without-pip`, system-site-package shortcut, cached capability PASS,
downloaded installer or bypass of any existing account/workspace/SSH assertion.

Only disposable scratch placement and execution hygiene change: prefer an existing
root-controlled `/run` tmpfs, otherwise use the already-validated disk scratch
location. A unique 0700 directory belongs to the coding account; `TMPDIR` confines
nested temporary files to it. Explicit interpreter symlinks support a `noexec`
scratch mount, and `-I` excludes user-site/current-directory/PYTHON overrides.
The independent disk-backed workspace read/write check is unchanged. Tmpfs can
avoid temporary block-device writes but does not remove CPU work or guarantee
faster TCG execution; it may use swap.

All three commands share **one unchanged 90-second deadline**. Process tests
exposed a cleanup problem with TERM followed by a kill grace: the shell could
exit while an ensurepip-style descendant remained alive. The candidate therefore
uses `timeout --signal=KILL 90s` for this **disposable probe group only**, rather
than the initially proposed grace. The finalizer, its cleanup and QEMU are outside
that group. No VM is killed, and no extra success interval or automatic retry is
introduced. This is not containment against a deliberately escaped process group.

Fixed storage/stage markers and numeric command/outer exits distinguish command
phases without disclosing arbitrary child output. KILL status 137 is a failure,
not proof that the timeout rather than an external actor killed the command.
Existing failure cleanup removes owned scratch and invalidates stale READY.

This edits the **normal guest profile source**, not a hidden qualification-only
copy. The source digest changes through the existing recipe hash calculation;
installed-source/identity/READY matching is still mandatory. No intent, image,
profile version or old acceptance evidence is silently relabelled. The public
2400-second build and 900-second launch limits, Windows control plane, provider
pins, QEMU arguments, WHPX behaviour and original release assertions are unchanged.

## Executed local evidence

`python -I tests/guest/test_venv_probe.py` on disposable Linux/Python 3.13.5:
**15 tests passed, zero failures/errors/skips**, elapsed 8.142 seconds.
The test executes the extracted production probe and cleanup with explicit
filesystem/account adapters; it is not a whole-guest or Windows acceptance run.
Two cases performed real venv/ensurepip/pip execution as the non-root `nobody`
account on actual tmpfs and disk fallback. Their observed durations were 1.800
and 1.868 seconds respectively; these single native-host samples are **not** a
TCG speedup measurement or a performance acceptance threshold.

Other cases cover phase-specific failures, missing Python, private scratch and
exact argv, one shared deadline, a TERM handler, a TERM-ignoring child, an actual
ensurepip-style grandchild, unsafe parent paths/ownership and failed allocation.
They assert scratch removal, outside-sentinel preservation, failed-READY
invalidation and no live owned descendant. Fault deadlines alone are shortened
to one second by an adapter that asserts the production 90-second arguments.
Fixture cleanup pins original processes with pidfds after matching start identity.

| Authored evidence | SHA-256 |
|---|---|
| Guest `provision.sh` | `c2d9c15533b474e6f60cd2e354b6bf75a71c5ac698f03cb81efb47b07d725d10` |
| `tests/guest/test_venv_probe.py` | `af154bb10b1bf9f283382e25823c5b28e246ad6b48d6d1aeefcc164d41e383c4` |
| Local test log | `cd2891faa6e55d7c6a122ca0441079aa48319e836c1af7d8e8693b6b1a9f6f03` |

Normalized coding-profile digest changes from
`7d80c28c27e76d9ac1bcdc52ed3f3aa0d9699205aced977eb6f71f3936ca3940` to
`cde0fedef9ee9808daaf23d9d5f42282dc787a8f46ed542e912a9a194d2dc037`.
These identities describe authored bytes; they do not assert that a local partial
checkout is the full published candidate tree. No Windows PowerShell or local
QEMU execution is claimed.

## Publication and acceptance gate

Core CI adds a GitHub-hosted Ubuntu process-test job using the existing pinned
Python 3.12.10 setup. It records actual HEAD/tree, interpreter/OS, source/test hashes
and case results. Existing Windows PowerShell 5.1 and pinned PowerShell 7 suites
also assert the revised source contract. These checks complement, not replace,
one normal publication-triggered **complete Windows TCG release qualification**.

At the original `24ca91a` publication checkpoint, the old run remained failed and
boot success was still unobserved. The subsequent [run 39022570303](https://github.com/techrote/ezvm/actions/runs/39022570303)
recorded all eight authenticated READY boots and timer probes, then was cancelled
at approximately 180 minutes before final completion markers. The
[appended runtime preparation record](retests/DASH-02-RELEASE-RUNTIME.md) preserves
that partial result and the next bounded qualification decision.

Required candidate/integration checks, review, current-main reconciliation and
accepted-revision verification still govern merge and closure. The final record
belongs on [live issue #28](https://github.com/techrote/ezvm/issues/28); these dated
preparation records do not assert a complete release PASS. WHPX execution remains
explicitly SKIP and TRIO remains paused.

## Primary implementation references

- [Python 3.12 venv](https://docs.python.org/3.12/library/venv.html): default ensurepip bootstrap and explicit symlinks.
- [Python 3.12 ensurepip](https://docs.python.org/3.12/library/ensurepip.html): bundled, offline bootstrap.
- [Python 3.12 tempfile](https://docs.python.org/3.12/library/tempfile.html): TMPDIR selection.
- [Python isolated mode](https://docs.python.org/3.12/using/cmdline.html#cmdoption-I): environment and import-path isolation.
- [Linux tmpfs](https://docs.kernel.org/filesystems/tmpfs.html): virtual-memory-backed storage and swap qualification.
- [GNU timeout](https://www.gnu.org/software/coreutils/manual/html_node/timeout-invocation.html): process-group timeout and ambiguous KILL status 137.
