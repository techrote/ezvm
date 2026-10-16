"""Run DASH-01 offline evidence qualification; stdout is the retainable JSON receipt.

Usage: python -B dashboard/replay.py --source-revision <checked-out commit>
Only a new disposable temporary directory is writable during replay. No adapters,
network clients, VM commands, inference calls or child processes are constructed.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import os
from pathlib import Path
import sys
import tempfile

sys.dont_write_bytecode = True
from ezvm_dashboard.evidence import (EvidenceError, Replay, REV, canonical, digest,
                                     loads, require, validate_corpus)
from ezvm_dashboard.research import validate_repository


class ReplayGuard:
    """Regression tripwire, NOT an OS sandbox for adversarial Python/native code."""
    def __init__(self, output):
        self.output = os.path.normcase(os.path.realpath(output))
        self.active = False
        self.denied = 0
        self.output_writes = 0
        sys.addaudithook(self.audit)

    def __enter__(self):
        self.active = True
        return self

    def __exit__(self, *args):
        self.active = False

    def reject(self):
        self.denied += 1
        raise EvidenceError('replay attempted a forbidden side effect')

    def contained(self, path):
        if not isinstance(path, (str, bytes, os.PathLike)):
            return False
        path = os.fsdecode(path)
        if not os.path.isabs(path):
            return False
        resolved = os.path.normcase(os.path.realpath(path))
        try:
            return os.path.commonpath([resolved, self.output]) == self.output
        except ValueError:
            return False

    def audit(self, event, args):
        if not self.active:
            return
        if event.startswith(('socket.', 'subprocess.', 'ctypes.', 'winreg.')) or event in {
                'os.system', 'os.exec', 'os.posix_spawn', 'os.fork', 'os.forkpty',
                'os.kill', 'os.killpg', 'os.startfile', 'os.startfile/2',
                'os.putenv', 'os.unsetenv', 'os.chdir', 'os.symlink', 'os.link'}:
            self.reject()
        if event == 'import' and args[0].split('.')[-1] in {'collectors', 'guest_probe', 'app', 'ui'}:
            self.reject()
        if event == 'open':
            path, mode, flags = args
            if (mode and any(c in mode for c in 'wax+')) or flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_APPEND):
                if not self.contained(path):
                    self.reject()
                self.output_writes += 1
        elif event in {'os.remove', 'os.rmdir', 'os.mkdir', 'os.chmod', 'os.chown', 'os.truncate', 'os.utime'}:
            if not self.contained(args[0]):
                self.reject()
        elif event == 'os.rename':
            if not self.contained(args[0]) or not self.contained(args[1]):
                self.reject()


def qualify(corpus, manifest, output):
    fixtures = validate_corpus(corpus, manifest)
    rows = []
    for fid, fixture in fixtures.items():
        before = digest(fixture)
        expected = fixture['expected']
        first = Replay(fixture).advance()
        require(first == expected, 'fixture projection/counters differ from reviewed expectation: ' + fid)
        require(Replay(fixture).advance() == first, 'repeat replay differs: ' + fid)
        restarts = 0
        for cut in range(len(fixture['events']) + 1):
            prefix = Replay(fixture)
            prefix.advance(cut)
            path = output / (fid + '-checkpoint.json')
            path.write_bytes(canonical(prefix.checkpoint()) + b'\n')
            restarted = Replay.restore(fixture, loads(path.read_text(encoding='utf-8')))
            require(restarted.advance() == first, 'restart replay differs: ' + fid)
            restarts += 1
        require(digest(fixture) == before, 'replay changed original fixture')
        (output / (fid + '-result.json')).write_bytes(canonical(first) + b'\n')
        rows.append({'fixtureId': fid, 'fixtureSha256': before,
                     'resultSha256': digest(first), 'restartCuts': restarts,
                     'result': first, 'status': 'PASS'})
    return fixtures, rows


def source_identity(root):
    files = ['dashboard/replay.py', 'dashboard/ezvm_dashboard/evidence.py',
             'dashboard/ezvm_dashboard/research.py', 'dashboard/tests/test_evidence.py',
             'dashboard/fixtures/dash01/corpus.json', 'dashboard/fixtures/dash01/manifest.json']
    hashes = {}
    for path in files:
        content = (root / path).read_text(encoding='utf-8').replace('\r\n', '\n').encode('utf-8')
        hashes[path] = hashlib.sha256(content).hexdigest()
    return {'algorithm': 'sha256-utf8-lf-v1', 'files': hashes, 'sha256': digest(hashes)}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-revision', required=True)
    args = parser.parse_args(argv)
    require(REV.fullmatch(args.source_revision), 'source revision must be a full commit SHA')
    root = Path(__file__).resolve().parent.parent
    started = datetime.now(timezone.utc).isoformat()
    fixture_root = root / 'dashboard/fixtures/dash01'
    with tempfile.TemporaryDirectory(prefix='ezvm-dash01-') as directory:
        output = Path(directory).resolve()
        with ReplayGuard(output) as guard:
            corpus = loads((fixture_root / 'corpus.json').read_text(encoding='utf-8'))
            manifest = loads((fixture_root / 'manifest.json').read_text(encoding='utf-8'))
            fixtures, rows = qualify(corpus, manifest, output)
            source = source_identity(root)
            research = validate_repository(root, manifest, fixtures, source, digest(rows))
            require(guard.denied == 0, 'forbidden replay operation was attempted')
        receipt = {'schemaVersion': 1, 'scope': 'synthetic-fixture-only', 'status': 'PASS',
                   'sourceRevision': args.source_revision,
                   'revisionAuthority': 'caller-declared checkout; sourceContent is independently hashed',
                   'sourceContent': source, 'exitCode': 0, 'startedAt': started,
                   'completedAt': datetime.now(timezone.utc).isoformat(),
                   'runtime': {'python': sys.version, 'platform': sys.platform},
                   'replaySha256': digest(rows), 'manifestSha256': digest(manifest),
                   'cases': ['DASH-01-T01', 'DASH-01-T02', 'DASH-01-T03', 'DASH-01-T04'],
                   'research': research, 'fixtures': rows,
                   'audit': {'forbiddenAttempts': guard.denied, 'disposableOutputWrites': guard.output_writes},
                   'limits': ['Not live/hardware qualification', 'No historical finding resolved',
                              'T03 adversarial leak rejection is additionally exercised by test_evidence.py']}
    print(canonical(receipt).decode('utf-8'))
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (EvidenceError, OSError, KeyError, TypeError, RecursionError) as exc:
        # Do not echo unreviewed input, secrets, host paths or traceback in export output.
        print('DASH-01 FAIL: ' + type(exc).__name__, file=sys.stderr)
        raise SystemExit(1)
