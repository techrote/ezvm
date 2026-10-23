"""Fixed, diagnostic-only fresh-venv experiment; never a qualification oracle."""
import hashlib
import json
import math
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time


VARIANTS = ("current", "compiled", "combined-prefix", "no-version-pyc") * 2


def validate_records(records, attempt_id, build_id, bootstrap_sha):
    if not isinstance(records, list) or not 20 <= len(records) <= 100:
        raise ValueError("bounded-records-required")
    identity = records[0]
    schemas = {
        'identity': {'kind','cpus','python','bootstrapSha256','ensurepipSha256','wheelSha256','attemptId','buildId'},
        'variant-start': {'kind','sequence','variant','sharedLimitSeconds'},
        'variant-end': {'kind','sequence','variant','exit','wallSeconds','userSeconds','systemSeconds','pyFiles','pycFiles'},
        'stage-start': {'kind','stage','seconds'},
        'stage-end': {'kind','stage','exit','wallSeconds','userSeconds','systemSeconds'},
        'completed': {'kind','diagnosticOnly','qualificationPassed','variants'},
    }
    for record in records:
        if not isinstance(record, dict) or record.get('kind') not in schemas or set(record) != schemas[record['kind']]:
            raise ValueError('closed-record-schema-required')
        for key in ('seconds','wallSeconds','userSeconds','systemSeconds'):
            if key in record:
                value = record[key]
                if type(value) not in (int,float) or not math.isfinite(value) or not 0 <= value <= 1000000:
                    raise ValueError('bounded-numeric-time-required')
        for key in ('cpus','sequence','sharedLimitSeconds','exit','pyFiles','pycFiles','variants'):
            if key in record and (type(record[key]) is not int or not 0 <= record[key] <= 10000):
                raise ValueError('bounded-integer-required')
        for key in ('diagnosticOnly','qualificationPassed'):
            if key in record and type(record[key]) is not bool:
                raise ValueError('strict-boolean-required')
    if (not re.fullmatch('[a-f0-9]{32}', attempt_id) or not re.fullmatch('[a-f0-9]{32}', build_id)
            or not re.fullmatch('[a-f0-9]{64}', bootstrap_sha)
            or identity['attemptId'] != attempt_id or identity['buildId'] != build_id
            or identity['bootstrapSha256'] != bootstrap_sha):
        raise ValueError('fresh-exact-bootstrap-binding-required')
    if not isinstance(identity['python'],str) or not re.fullmatch(r'3\.12\.\d{1,3}',identity['python']):
        raise ValueError('supported-python-required')
    if identity.get("kind") != "identity" or identity.get("cpus") != 6:
        raise ValueError("guest-identity-required")
    for key in ("bootstrapSha256", "ensurepipSha256"):
        if not isinstance(identity.get(key), str) or len(identity[key]) != 64 or any(c not in "0123456789abcdef" for c in identity[key]):
            raise ValueError("guest-digest-required")
    if (not isinstance(identity.get("wheelSha256"), list) or len(identity["wheelSha256"]) != 1
            or len(identity["wheelSha256"][0]) != 64
            or any(c not in "0123456789abcdef" for c in identity["wheelSha256"][0])):
        raise ValueError("one-pinned-guest-wheel-required")
    position = 1
    for sequence, variant in enumerate(VARIANTS, 1):
        first = records[position]
        if first != dict(kind="variant-start", sequence=sequence, variant=variant, sharedLimitSeconds=90):
            raise ValueError("ordered-variant-required")
        position += 1
        names = ["layout", "bootstrap"] + ([] if variant == "combined-prefix" else ["prefix"]) + ["pip-version"]
        failed = False
        interrupted = False
        for name in names:
            record = records[position]
            if record.get("kind") == "variant-end":
                interrupted = True
                break
            if record.get("kind") != "stage-start" or record.get("stage") != name:
                raise ValueError("ordered-stage-start-required")
            position += 1
            record = records[position]
            if record.get("kind") == "variant-end":
                interrupted = True
                break
            if record.get("kind") != "stage-end" or record.get("stage") != name or type(record.get("exit")) is not int:
                raise ValueError("ordered-stage-end-required")
            for key in ("wallSeconds", "userSeconds", "systemSeconds"):
                value = record.get(key)
                if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
                    raise ValueError("finite-nonnegative-time-required")
            position += 1
            if record["exit"]:
                failed = True
                break
        last = records[position]
        if (last.get("kind") != "variant-end" or last.get("sequence") != sequence or last.get("variant") != variant
                or type(last.get("exit")) is not int or last["exit"] < 0 or last["exit"] > 255
                or (last["exit"] == 0 and (failed or interrupted))):
            raise ValueError("actual-variant-status-required")
        if interrupted and last["exit"] not in (124, 137):
            raise ValueError("bounded-interruption-required")
        for key in ("wallSeconds", "userSeconds", "systemSeconds"):
            value = last.get(key)
            if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
                raise ValueError("finite-nonnegative-time-required")
        position += 1
    if records[position:] != [dict(kind="completed", diagnosticOnly=True, qualificationPassed=False, variants=8)]:
        raise ValueError("unique-terminal-record-required")
    # Host-side public projection; never upload the parsed raw guest dictionary.
    return [{key: record[key] for key in sorted(schemas[record['kind']])} for record in records]


def emit(value):
    print("\nVENV_STAGE " + json.dumps(value, sort_keys=True, separators=(",", ":")), flush=True)


def stage(name, command, environment):
    import resource
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    start = time.monotonic()
    emit(dict(kind="stage-start", stage=name, seconds=start))
    # The outer GNU timeout owns this worker and all stage descendants. Tool text
    # is deliberately discarded: fixed metrics, never guest-controlled prose.
    completed = subprocess.run(command, env=environment, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL)
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    emit(dict(kind="stage-end", stage=name, exit=completed.returncode,
              wallSeconds=time.monotonic() - start,
              userSeconds=after.ru_utime - before.ru_utime,
              systemSeconds=after.ru_stime - before.ru_stime))
    if completed.returncode:
        raise SystemExit(completed.returncode)


def worker(variant, directory):
    directory = Path(directory)
    if variant not in set(VARIANTS) or directory.parent != Path("/var/lib/ezvm-stage"):
        raise RuntimeError("fixed-owned-experiment-required")
    environment = dict(os.environ)
    interpreter = directory / "env/bin/python"
    stage("layout", ["python3", "-m", "venv", "--without-pip", str(directory / "env")], environment)
    bootstrap = Path("/usr/local/lib/ezvm-stage-bootstrap.py").read_text()
    if variant == "compiled":
        old = 'return original([*args, "--no-compile"], additional_paths)'
        if bootstrap.count(old) != 1:
            raise RuntimeError("exact-bootstrap-required")
        bootstrap = bootstrap.replace(old, "return original(args, additional_paths)")
    if variant == "combined-prefix":
        bootstrap += "\nimport sys\nassert sys.prefix != sys.base_prefix\n"
    stage("bootstrap", [str(interpreter), "-c", bootstrap], environment)
    if variant != "combined-prefix":
        stage("prefix", [str(interpreter), "-c", "import sys; assert sys.prefix != sys.base_prefix"], environment)
    if variant == "no-version-pyc":
        # A measured candidate only: same actual installed CLI; optional caches
        # are omitted for this command. No product behavior changes here.
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
    stage("pip-version", [str(interpreter), "-m", "pip", "--version"], environment)


def experiment():
    import pwd
    import resource
    if os.geteuid() != 0 or os.cpu_count() != 6:
        raise RuntimeError("six-cpu-root-diagnostic-required")
    account = pwd.getpwnam("venvprobe")
    parent = Path("/var/lib/ezvm-stage")
    parent.mkdir(mode=0o711)
    # The root probe deliberately uses umask077. Grant traversal explicitly;
    # each separately allocated child remains mode0700 and probe-user owned.
    parent.chmod(0o711)
    subprocess.run(["runuser", "-u", "venvprobe", "--", "test", "-x", str(parent)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    source = Path("/usr/local/lib/ezvm-stage-bootstrap.py")
    binding = json.loads(Path('/usr/local/lib/ezvm-stage-binding.json').read_text())
    emit(dict(kind="identity", cpus=os.cpu_count(), python=sys.version.split()[0],
              attemptId=binding['attemptId'],buildId=binding['buildId'],
              bootstrapSha256=hashlib.sha256(source.read_bytes()).hexdigest(),
              ensurepipSha256=hashlib.sha256(Path("/usr/lib/python3.12/ensurepip/__init__.py").read_bytes()).hexdigest(),
              wheelSha256=[hashlib.sha256(p.read_bytes()).hexdigest()
                           for p in sorted(Path("/usr/share/python-wheels").glob("pip-*.whl"))]))
    for sequence, variant in enumerate(VARIANTS, 1):
        directory = Path(tempfile.mkdtemp(prefix="probe-", dir=parent))
        os.chown(directory, account.pw_uid, account.pw_gid)
        emit(dict(kind="variant-start", sequence=sequence, variant=variant, sharedLimitSeconds=90))
        start = time.monotonic()
        before = resource.getrusage(resource.RUSAGE_CHILDREN)
        command = ["runuser", "-u", "venvprobe", "--", "env", "-i",
                   "PATH=/usr/sbin:/usr/bin:/sbin:/bin", "HOME=/home/venvprobe",
                   "USER=venvprobe", "LOGNAME=venvprobe", "LC_ALL=C",
                   "timeout", "--kill-after=3", "90", "python3", __file__,
                   "--worker", variant, str(directory)]
        result = subprocess.run(command)
        after = resource.getrusage(resource.RUSAGE_CHILDREN)
        emit(dict(kind="variant-end", sequence=sequence, variant=variant, exit=result.returncode,
                  wallSeconds=time.monotonic() - start,
                  userSeconds=after.ru_utime - before.ru_utime,
                  systemSeconds=after.ru_stime - before.ru_stime,
                  pyFiles=len(list((directory / "env").rglob("*.py"))),
                  pycFiles=len(list((directory / "env").rglob("*.pyc")))))
        # Exact locally allocated scratch, after timeout has reaped its group.
        shutil.rmtree(directory)
    emit(dict(kind="completed", diagnosticOnly=True, qualificationPassed=False, variants=len(VARIANTS)))


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--worker":
        worker(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 1:
        experiment()
    elif len(sys.argv) == 6 and sys.argv[1] == "--validate":
        path = Path(sys.argv[2])
        if path.stat().st_size > 131072:
            raise SystemExit("bounded-records-required")
        approved = validate_records(json.loads(path.read_text(encoding="utf-8-sig")), *sys.argv[3:])
        print(json.dumps(approved,sort_keys=True,separators=(',',':')))
    else:
        raise SystemExit("fixed-mode-required")
