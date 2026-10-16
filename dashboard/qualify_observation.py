"""DASH-02 exact-checkout qualification receipt; no live VM/provider adapters."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import importlib.metadata
import json
from pathlib import Path
import platform
import subprocess
import sys
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    'dashboard/ezvm_dashboard/app.py', 'dashboard/ezvm_dashboard/adapters.py', 'dashboard/ezvm_dashboard/collectors.py',
    'dashboard/ezvm_dashboard/guest_probe.py', 'dashboard/ezvm_dashboard/model.py',
    'dashboard/ezvm_dashboard/ui.py', 'dashboard/tests/test_dashboard.py',
    'dashboard/tests/test_observation.py', 'dashboard/fixtures/dash02/schemas.json',
    'dashboard/qualify_observation.py', '.github/workflows/dash02-observation.yml',
]


def content():
    files = {name: hashlib.sha256((ROOT / name).read_text(encoding='utf-8').replace('\r\n', '\n').encode('utf-8')).hexdigest()
             for name in SOURCES}
    return {'algorithm': 'sha256-utf8-lf-v1', 'files': files,
            'sha256': hashlib.sha256(json.dumps(files, sort_keys=True, separators=(',', ':')).encode()).hexdigest()}


def git(*args):
    result = subprocess.run(['git', '-C', str(ROOT), *args], capture_output=True, text=True, timeout=10)
    if result.returncode:
        raise ValueError('Exact checkout Git identity unavailable')
    return result.stdout.strip()


class Results(unittest.TextTestResult):
    def startTest(self, test):
        self.started = time.monotonic()
        super().startTest(test)

    def record(self, test, status):
        self.records.append({'test': test.id(), 'status': status,
                             'seconds': time.monotonic() - self.started})

    def addSuccess(self, test):
        super().addSuccess(test)
        self.record(test, 'PASS')

    def addFailure(self, test, error):
        super().addFailure(test, error)
        self.record(test, 'FAIL')

    def addError(self, test, error):
        super().addError(test, error)
        self.record(test, 'ERROR')

    def addSkip(self, test, reason):
        super().addSkip(test, reason)
        self.record(test, 'SKIP')

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.records = []


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--allow-source-subset', action='store_true', help='Local supplementary tests only; no accepted-checkout claim')
    args = parser.parse_args()
    started = datetime.now(timezone.utc).isoformat()
    before = content()
    revision, tree = None, None
    if not args.allow_source_subset:
        revision, tree = git('rev-parse', 'HEAD'), git('rev-parse', 'HEAD^{tree}')
        if git('status', '--porcelain', '--untracked-files=no'):
            raise ValueError('Tracked source is dirty; refusing exact-checkout receipt')
    sys.path.insert(0, str(ROOT / 'dashboard/tests'))
    import test_observation
    result = unittest.TextTestRunner(verbosity=2, resultclass=Results).run(
        unittest.defaultTestLoader.loadTestsFromModule(test_observation))
    after = content()
    passed = result.wasSuccessful() and result.testsRun > 0 and not result.skipped and before == after
    if revision is not None:
        passed = passed and git('rev-parse', 'HEAD') == revision and not git('status', '--porcelain', '--untracked-files=no')
    records = result.records
    cases = {}
    for i in range(1, 6):
        rows = [r for r in records if f'.test_t{i:02d}_' in r['test']]
        ok = bool(rows) and all(r['status'] == 'PASS' for r in rows)
        passed = passed and ok
        cases[f'DASH-02-T{i:02d}'] = {'status': 'PASS' if ok else 'FAIL', 'assertionTests': len(rows)}
    report = {'schemaVersion': 1, 'scope': 'synthetic-and-owned-process-boundaries',
        'status': 'PASS' if passed else 'FAIL', 'sourceRevision': revision, 'sourceTree': tree,
        'checkoutQualification': revision is not None, 'sourceContent': before,
        'sourceUnchanged': before == after, 'startedAt': started,
        'completedAt': datetime.now(timezone.utc).isoformat(),
        'runtime': {'python': sys.version, 'platform': platform.platform(),
                    'dependencies': {name: importlib.metadata.version(name) for name in ('psutil', 'prompt_toolkit', 'wcwidth')}},
        'testsRun': result.testsRun, 'failures': len(result.failures), 'errors': len(result.errors),
        'skips': len(result.skipped), 'cases': cases, 'tests': records, 'measurements': test_observation.METRICS,
        'limits': ['No live model/VM/worker or physical terminal qualification',
                   'No DASH-11 idle/performance release-gate acceptance', 'TRIO remains paused']}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, sort_keys=True, indent=2, allow_nan=False) + '\n', encoding='utf-8')
    print('DASH02_RECEIPT_SHA256=' + hashlib.sha256(args.output.read_bytes()).hexdigest())
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
