"""Execute the guest's real shell probe in disposable Linux boundary fixtures.

Filesystem/account adapters map only fixed managed paths and `coder` to a
pre-existing unprivileged fixture account. The probe and cleanup are extracted
from the production recipe; no alternative copy of the probe is implemented.
Native cases run real venv/ensurepip/pip. Fault cases use tiny owned executables
and shorten only the fixture timeout, while asserting the production 90s argv.
This is not Windows/QEMU or whole-guest acceptance.
"""
from __future__ import annotations

import hashlib
import signal
import json
import os
from pathlib import Path
import pwd
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "guest/profiles/coding-default/v1/provision.sh"
TEXT = SOURCE.read_text(encoding="utf-8").replace("\r\n", "\n")
BEGIN, END = "# BEGIN EZVM_PYTHON_VENV_PROBE\n", "# END EZVM_PYTHON_VENV_PROBE"
if TEXT.count(BEGIN) != 1 or TEXT.count(END) != 1:
    raise RuntimeError("Expected one production probe, not a copied fixture implementation")
BLOCK = TEXT.split(BEGIN, 1)[1].split(END, 1)[0]
REAL_PYTHON = Path(sys._base_executable).resolve()
MEASUREMENTS: list[dict] = []


def function(name: str) -> str:
    start = TEXT.index(name + "() {\n")
    return TEXT[start:TEXT.index("\n}\n", start) + 3]


def executable(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")
    path.chmod(0o755)


class ProbeFixture:
    def __init__(self, case: str = "native", storage: str = "tmpfs"):
        self.work = Path(tempfile.mkdtemp(prefix="ezvm guest probe "))
        self.work.chmod(0o755)
        self.account = pwd.getpwnam("nobody")
        self.bin = self.work / "bin"
        self.bin.mkdir(mode=0o755)
        self.state = self.work / "state"
        self.state.mkdir(mode=0o755)
        self.run = self.work / "run"
        self.run.mkdir(mode=0o755)
        self.trace = self.work / "trace"
        self.trace.mkdir(mode=0o700)
        os.chown(self.trace, self.account.pw_uid, self.account.pw_gid)
        # RAM-backed native execution is real, including a noexec-capable mount.
        parent = "/dev/shm" if storage == "tmpfs" else str(self.work)
        self.scratch = Path(tempfile.mkdtemp(prefix="ezvm-venv-fixture-", dir=parent))
        self.scratch.chmod(0o755)
        (self.state / "ready.json").write_text("old-ready-sentinel\n")
        (self.work / "outside.txt").write_text("outside-sentinel\n")
        self.case, self.storage = case, storage
        trace = str(self.trace)
        if case == "native":
            (self.bin / "python3").symlink_to(REAL_PYTHON)
        else:
            # Generated only under this fixture. Interpreter links resolve off
            # tmpfs so a noexec scratch mount cannot invalidate the test double.
            stub = f'''#!{REAL_PYTHON} -I
import json, os, pathlib, signal, subprocess, sys, tempfile, time
case = {case!r}
with open({trace!r} + '/pids.jsonl', 'a') as log:
    log.write(json.dumps([os.getpid(), pathlib.Path('/proc/self/stat').read_text().split()[21]]) + '\\n')
args = sys.argv[1:]
with open({trace!r} + '/commands.jsonl', 'a') as log:
    log.write(json.dumps({{'args': args, 'tmpdir': tempfile.gettempdir(), 'mode': os.stat(tempfile.gettempdir()).st_mode & 0o777, 'uid': os.getuid()}}) + '\\n')
if args[:4] == ['-I', '-m', 'venv', '--symlinks']:
    if case == 'create-fails':
        print('UNREDACTED_CHILD_OUTPUT_SENTINEL', file=sys.stderr)
        sys.exit(17)
    if case == 'missing-python':
        sys.exit(127)
    if case in ('deadline', 'kill-grace', 'late-success', 'grandchild'):
        if case == 'kill-grace':
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
        if case == 'late-success':
            signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
        if case == 'grandchild':
            subprocess.Popen([sys.executable, '-I', __file__, 'grandchild-child'])
        time.sleep(60)
    target = pathlib.Path(args[4]) / 'bin'
    target.mkdir(parents=True)
    (target / 'python').symlink_to({str(self.bin / 'python3')!r})
elif args == ['grandchild-child']:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    time.sleep(60)
elif args[:2] == ['-I', '-c']:
    if case == 'interpreter-fails':
        sys.exit(18)
elif args == ['-I', '-m', 'pip', '--version']:
    if case == 'pip-fails':
        print('UNREDACTED_CHILD_OUTPUT_SENTINEL')
        sys.exit(19)
else:
    sys.exit(99)
'''
            executable(self.bin / "python3", stub)
        executable(self.bin / "timeout", f'''#!/bin/sh
set -eu
[ "$1" = --signal=KILL ] && [ "$2" = 90s ] || exit 98
printf '%s\\n' '90s; KILL' > {shlex.quote(trace + '/timeout-argv')}
if [ {shlex.quote(case)} = deadline ] || [ {shlex.quote(case)} = kill-grace ] || [ {shlex.quote(case)} = late-success ] || [ {shlex.quote(case)} = grandchild ]; then
    shift 2
    exec /usr/bin/timeout --signal=KILL 1s "$@"
fi
exec /usr/bin/timeout "$@"
''')
        # Redirect fixed production state paths in the cleanup function only.
        # All commands in BLOCK are unchanged; adapters check original argv.
        cleanup = function("cleanup").replace("/var/lib/ezvm", shlex.quote(str(self.state)))
        root_path = function("root_path").replace("root_path()", "original_root_path()", 1)
        preamble = f'''set -eu
umask 077
PATH={shlex.quote(str(self.bin))}:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
failure_message='coding profile validation failed'
state_safe=1
venv_directory=''
ready_temporary=''
coder_uid={self.account.pw_uid}
coder_gid={self.account.pw_gid}
{cleanup}
{function('fail')}
{root_path}
trap 'cleanup $?' 0
root_path() {{
    [ "$1" = /run ] && [ "$2" = directory ] || exit 98
    original_root_path {shlex.quote(str(self.run))} directory
}}
stat() {{
    if [ "$*" = '-f -c %T -- /run' ]; then
        printf '%s\\n' {shlex.quote('tmpfs' if storage == 'tmpfs' else 'ext2/ext3')}
    else
        /usr/bin/stat "$@"
    fi
}}
mktemp() {{
    if [ "$1" = -d ]; then
        [ "$2" = {shlex.quote(('/run' if storage == 'tmpfs' else '/var/lib/ezvm') + '/.venv-check.XXXXXX')} ] || exit 98
        [ {shlex.quote(case)} != allocation-fails ] || return 1
        /usr/bin/mktemp -d {shlex.quote(str(self.scratch) + '/.venv-check.XXXXXX')}
    else
        /usr/bin/mktemp "$@"
    fi
}}
runuser() {{
    [ "$1:$2:$3" = '-u:coder:--' ] || exit 98
    shift 3
    exec_args_ok=0
    for arg in "$@"; do
        case "$arg" in TMPDIR={shlex.quote(str(self.scratch))}/*) exec_args_ok=1 ;; esac
    done
    [ "$exec_args_ok" = 1 ] || exit 98
    /usr/sbin/runuser -u nobody -- "$@"
}}
'''
        self.script = preamble + BLOCK

    def run_probe(self) -> subprocess.CompletedProcess[str]:
        began = time.monotonic()
        result = subprocess.run(["/bin/sh", "-c", self.script], text=True, capture_output=True, timeout=100)
        self.elapsed = time.monotonic() - began
        if self.case == "native":
            MEASUREMENTS.append({"case": "real-venv-" + self.storage, "elapsedSeconds": self.elapsed,
                                 "exitCode": result.returncode, "stderr": result.stderr})
        return result

    def check_preservation(self, testcase: unittest.TestCase, success: bool) -> None:
        testcase.assertEqual(list(self.scratch.iterdir()), [], "owned scratch must be removed")
        testcase.assertEqual((self.work / "outside.txt").read_text(), "outside-sentinel\n")
        testcase.assertEqual((self.state / "ready.json").exists(), success)
        testcase.assertEqual((self.state / "provisioning-failed").exists(), not success)
        testcase.assertNotIn("UNREDACTED_CHILD_OUTPUT_SENTINEL", "".join(
            p.read_text() for p in self.state.iterdir() if p.is_file()))

    def live_owned_children(self) -> list[tuple[int, str]]:
        path = self.trace / "pids.jsonl"
        alive = []
        if path.exists():
            for line in path.read_text().splitlines():
                pid, start = json.loads(line)
                proc = Path("/proc") / str(pid) / "stat"
                try:
                    fields = proc.read_text().split()
                except FileNotFoundError:
                    continue
                if fields[21] == start and fields[2] != "Z":
                    alive.append((pid, start))
        return alive

    def close(self) -> None:
        # A failing regression must still clean up only positively identified
        # fixture processes, never leave its deliberately stalled child behind.
        for pid, expected_start in self.live_owned_children():
            try:
                descriptor = os.pidfd_open(pid)
            except ProcessLookupError:
                continue
            try:
                fields = (Path("/proc") / str(pid) / "stat").read_text().split()
                if fields[21] == expected_start:
                    signal.pidfd_send_signal(descriptor, signal.SIGKILL)
            except (ProcessLookupError, FileNotFoundError):
                pass
            finally:
                os.close(descriptor)
        shutil.rmtree(self.scratch)
        shutil.rmtree(self.work)


class VenvProbeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if sys.platform != "linux" or os.geteuid() != 0:
            raise RuntimeError("Run these disposable Linux fixtures as root; do not report a platform SKIP as PASS")
        for name in ("/usr/bin/timeout", "/usr/sbin/runuser", "/bin/sh", "/dev/shm"):
            if not Path(name).exists():
                raise RuntimeError("Required Linux fixture capability missing: " + name)
        fs = subprocess.check_output(["stat", "-f", "-c", "%T", "/dev/shm"], text=True).strip()
        if fs != "tmpfs":
            raise RuntimeError("Native tmpfs case requires a real tmpfs mount")

    def fixture(self, *args: str) -> ProbeFixture:
        f = ProbeFixture(*args)
        self.addCleanup(f.close)
        return f

    def test_native_venv_ensurepip_and_pip_on_real_tmpfs(self) -> None:
        self.native("tmpfs")

    def test_native_venv_ensurepip_and_pip_on_disk_fallback(self) -> None:
        self.native("disk")

    def native(self, storage: str) -> None:
        f = self.fixture("native", storage)
        result = f.run_probe()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        for phase in ("create", "interpreter", "pip"):
            self.assertIn("EZVM_GUEST_VENV_STAGE=" + phase, result.stderr)
        self.assertIn("EZVM_GUEST_VENV_STORAGE=" + storage, result.stderr)
        self.assertIn("EZVM_GUEST_VENV_COMPLETE=1", result.stderr)
        f.check_preservation(self, True)

    def test_private_coder_tempfiles_environment_and_exact_command_order(self) -> None:
        f = self.fixture("success")
        result = f.run_probe()
        self.assertEqual(result.returncode, 0, result.stderr)
        records = [json.loads(line) for line in (f.trace / "commands.jsonl").read_text().splitlines()]
        self.assertEqual(len(records), 3)
        self.assertEqual(records[0]["args"][:4], ["-I", "-m", "venv", "--symlinks"])
        self.assertEqual(records[1]["args"], ["-I", "-c", "import sys; assert sys.prefix != sys.base_prefix"])
        self.assertEqual(records[2]["args"], ["-I", "-m", "pip", "--version"])
        self.assertTrue(all(r["uid"] == f.account.pw_uid and r["uid"] != 0 and r["mode"] == 0o700 for r in records))
        self.assertEqual(len({r["tmpdir"] for r in records}), 1)
        self.assertTrue(records[0]["tmpdir"].startswith(str(f.scratch) + "/.venv-check."))
        self.assertEqual((f.trace / "timeout-argv").read_text(), "90s; KILL\n")
        f.check_preservation(self, True)

    def test_create_failure_is_not_a_timeout_or_ready(self) -> None:
        self.command_failure("create-fails", "create", 17)

    def test_interpreter_failure_stops_before_pip(self) -> None:
        self.command_failure("interpreter-fails", "interpreter", 18)

    def test_pip_failure_is_not_a_timeout_or_ready(self) -> None:
        self.command_failure("pip-fails", "pip", 19)

    def test_missing_python_is_not_reported_as_success(self) -> None:
        self.command_failure("missing-python", "create", 127)

    def command_failure(self, case: str, phase: str, status: int) -> None:
        f = self.fixture(case)
        result = f.run_probe()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"EZVM_GUEST_VENV_STEP_FAILURE={phase}; exit={status}", result.stderr)
        self.assertIn(f"EZVM_GUEST_VENV_EXIT={status}", result.stderr)
        self.assertNotIn("EZVM_GUEST_VENV_COMPLETE", result.stderr)
        self.assertNotIn("UNREDACTED_CHILD_OUTPUT_SENTINEL", result.stdout + result.stderr)
        if phase != "pip":
            self.assertNotIn("EZVM_GUEST_VENV_STAGE=pip", result.stderr)
        f.check_preservation(self, False)

    def test_shared_deadline_fails_closed_and_cleans(self) -> None:
        self.deadline("deadline", 137)

    def test_term_ignoring_child_is_killed_and_not_ready(self) -> None:
        self.deadline("kill-grace", 137)

    def test_term_handler_cannot_convert_the_hard_deadline_to_success(self) -> None:
        self.deadline("late-success", 137)

    def test_hard_deadline_stops_an_ensurepip_style_grandchild(self) -> None:
        self.deadline("grandchild", 137)

    def deadline(self, case: str, status: int) -> None:
        f = self.fixture(case)
        result = f.run_probe()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"EZVM_GUEST_VENV_EXIT={status}", result.stderr)
        self.assertNotIn("EZVM_GUEST_VENV_COMPLETE", result.stderr)
        self.assertLess(f.elapsed, 5, "shortened process fault fixture did not terminate")
        if case == "grandchild":
            self.assertEqual(len((f.trace / "pids.jsonl").read_text().splitlines()), 2,
                             "the descendant test must actually spawn its grandchild")
        self.assertFalse(f.live_owned_children(), "deadline left a fixture child running")
        f.check_preservation(self, False)

    def test_unsafe_run_permissions_refuse_before_allocation(self) -> None:
        f = self.fixture("success")
        f.run.chmod(0o777)
        self.unsafe_root(f)

    def test_symlink_run_refuses_before_allocation(self) -> None:
        f = self.fixture("success")
        f.run.rmdir()
        f.run.symlink_to(f.state, target_is_directory=True)
        self.unsafe_root(f)

    def test_foreign_owned_run_refuses_before_allocation(self) -> None:
        f = self.fixture("success")
        os.chown(f.run, f.account.pw_uid, f.account.pw_gid)
        self.unsafe_root(f)

    def unsafe_root(self, f: ProbeFixture) -> None:
        result = f.run_probe()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("EZVM_GUEST_VENV_STAGE=", result.stderr)
        f.check_preservation(self, False)

    def test_allocation_failure_cannot_preserve_stale_ready(self) -> None:
        f = self.fixture("allocation-fails")
        result = f.run_probe()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not allocate", result.stderr)
        f.check_preservation(self, False)


if __name__ == "__main__":
    print(json.dumps({"scope": "Linux shell/process fixtures; not whole-guest or Windows TCG acceptance",
                      "python": sys.version, "sourceSha256": hashlib.sha256(SOURCE.read_bytes()).hexdigest()}), flush=True)
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(VenvProbeTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    print(json.dumps({"testsRun": result.testsRun, "failures": len(result.failures),
                      "errors": len(result.errors), "skips": len(result.skipped),
                      "measurements": MEASUREMENTS}, sort_keys=True), flush=True)
    sys.exit(0 if result.wasSuccessful() and result.testsRun and not result.skipped else 1)
