"""Exercise the exact guest bootstrap, including a real isolated offline install."""
import os
from pathlib import Path
import re
import subprocess
import sys
import types
from unittest.mock import patch

profile, root = map(Path, sys.argv[1:])
if sys.version_info[:2] != (3, 12):
    raise RuntimeError("guest bootstrap controls require CPython 3.12")
matches = re.findall(
    r'<<"EZVM_PIP_BOOTSTRAP"\n(.*?)\nEZVM_PIP_BOOTSTRAP',
    profile.read_text(encoding="utf-8").replace("\r\n", "\n"), re.S)
if len(matches) != 1:
    raise RuntimeError("expected one exact bootstrap body")
body = compile(matches[0], str(profile), "exec")

for case in ("delegate", "delegate-failure", "bootstrap-failure", "signature", "zero-calls", "double-calls"):
    arguments = ["install", "--no-cache-dir", "--no-index", "--find-links", "synthetic-wheels", "--upgrade", "pip"]
    unchanged = arguments[:]
    paths = ["synthetic-wheel"]
    delegated = []
    bootstrap_calls = []

    def original(args, additional_paths=None):
        delegated.append((args, additional_paths))
        if case == "delegate-failure":
            raise subprocess.CalledProcessError(17, "synthetic-pip")
        return 0

    if case == "signature":
        def original(args):
            raise AssertionError("unexpected interface must not execute")

    fake = types.ModuleType("ensurepip")
    fake._run_pip = original

    def bootstrap(**kwargs):
        bootstrap_calls.append(kwargs)
        if case == "bootstrap-failure":
            raise ValueError("synthetic bootstrap failure")
        for _ in range(0 if case == "zero-calls" else 2 if case == "double-calls" else 1):
            fake._run_pip(arguments, paths)

    fake.bootstrap = bootstrap
    failure = None
    with patch.dict(sys.modules, {"ensurepip": fake}):
        try:
            exec(body, {})
        except Exception as error:
            failure = error
    if fake._run_pip is not original:
        raise AssertionError("bootstrap mutation escaped its call")
    if arguments != unchanged:
        raise AssertionError("ensurepip's original argument list was mutated")
    if case == "delegate":
        if failure or len(delegated) != 1:
            raise AssertionError("exact delegation failed")
    elif case == "delegate-failure":
        if not isinstance(failure, subprocess.CalledProcessError) or failure.returncode != 17:
            raise AssertionError("original pip failure was swallowed")
    elif case == "bootstrap-failure":
        if not isinstance(failure, ValueError):
            raise AssertionError("bootstrap failure was swallowed")
    elif not isinstance(failure, RuntimeError):
        raise AssertionError("interface/call-count change must fail closed")
    if case == "signature":
        if bootstrap_calls or delegated:
            raise AssertionError("unsupported interface was admitted")
    elif bootstrap_calls != [{"upgrade": True, "default_pip": True}]:
        raise AssertionError("default bootstrap options changed")
    for args, additional_paths in delegated:
        if args != unchanged + ["--no-compile"] or additional_paths is not paths:
            raise AssertionError("bootstrap flags or wheel paths changed")
    print("PASS venv bootstrap " + case)

environment = {key: value for key, value in os.environ.items()
               if not key.startswith(("PYTHON", "PIP_"))}
for case in ("real-offline", "missing-wheel"):
    destination = root / case
    result = subprocess.run([sys.executable, "-m", "venv", "--without-pip", str(destination)],
                            env=environment, capture_output=True, timeout=30)
    if result.returncode:
        raise AssertionError("real isolated environment creation failed")
    executable = destination / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
    prefix = ""
    if case == "missing-wheel":
        missing = str(root / "deliberately-missing-pip.whl")
        prefix = ("import ensurepip\nensurepip._get_packages = lambda: {\"pip\": "
                  "ensurepip._Package(\"0\", None, " + repr(missing) + ")}\n")
    result = subprocess.run([str(executable), "-"], input=prefix + matches[0], text=True,
                            env=environment, capture_output=True, timeout=45)
    if case == "missing-wheel":
        if result.returncode == 0:
            raise AssertionError("missing bundled wheel falsely succeeded")
        probe = subprocess.run([str(executable), "-c", "import pip"], env=environment,
                               capture_output=True, timeout=10)
        if probe.returncode == 0:
            raise AssertionError("failed bootstrap used global pip")
    else:
        if result.returncode:
            raise AssertionError("real offline ensurepip bootstrap failed")
        probe = subprocess.run([str(executable), "-c",
                                "import os,sys,pip; assert sys.prefix != sys.base_prefix; "
                                "assert os.path.commonpath([os.path.realpath(pip.__file__), "
                                "os.path.realpath(sys.prefix)]) == os.path.realpath(sys.prefix)"],
                               env=environment, capture_output=True, timeout=10)
        if probe.returncode:
            raise AssertionError("pip must belong to the real isolated environment")
        version = subprocess.run([str(executable), "-m", "pip", "--version"], env=environment,
                                 capture_output=True, timeout=10)
        if version.returncode:
            raise AssertionError("bootstrapped pip command is unusable")
    print("PASS venv bootstrap " + case)
