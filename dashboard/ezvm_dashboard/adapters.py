"""DASH-02 read boundaries and versioned observation contracts (stdlib only).

This module is also sent, as reviewed source, to the enrolled guest's stdin.
It does not expose a worker, provider, VM, bootstrap or model-load operation.
"""
from __future__ import annotations

from contextlib import contextmanager
from datetime import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import struct
import subprocess
import tempfile
import threading
import time
from urllib.parse import urlparse
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener

MAX_BYTES = 4_000_000
MAX_ACTORS = 256
SESSION_SCAN = 10_000
MESSAGE_SCAN = 20_000
DB_BYTES = 64_000_000
WAL_BYTES = 16_000_000
CONTRACT = 'ezvm-observation-v1'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def identity(*parts):
    return hashlib.sha256(json.dumps(parts, ensure_ascii=True, separators=(',', ':')).encode()).hexdigest()


def capability(adapter, source, version, method):
    return {'schemaVersion': 1, 'adapter': adapter, 'sourceId': source,
            'sourceVersion': version, 'contract': CONTRACT, 'method': method,
            'capabilities': ['observe'], 'controlEligible': False}


def loads(data):
    def pairs(values):
        result = {}
        for key, value in values:
            require(key not in result, 'Duplicate JSON key')
            result[key] = value
        return result
    require(len(data) <= MAX_BYTES, 'JSON exceeds read limit')
    try:
        result = json.loads(data, object_pairs_hook=pairs,
                            parse_constant=lambda value: (_ for _ in ()).throw(ValueError('Nonfinite JSON')))
    except (RecursionError, UnicodeError) as exc:
        raise ValueError('Invalid JSON encoding/nesting') from exc
    stack = [(result, 0)]
    while stack:
        item, depth = stack.pop()
        require(depth <= 48, 'JSON nesting exceeds bound')
        if isinstance(item, dict):
            stack.extend((v, depth + 1) for v in item.values())
        elif isinstance(item, list):
            stack.extend((v, depth + 1) for v in item)
        elif isinstance(item, float):
            require(math.isfinite(item), 'Nonfinite JSON number')
    return result


def read_bytes(path, limit=MAX_BYTES):
    """Limit before allocation; never open with a write/create flag."""
    with Path(path).open('rb') as stream:
        data = stream.read(limit + 1)
    require(len(data) <= limit, 'File exceeds read limit')
    return data


def read_json(path):
    return loads(read_bytes(path).decode('utf-8-sig'))


def scoped_path(root, value, *, file=False, exists=True):
    root = Path(root).resolve()
    require(isinstance(value, (str, Path)), 'Path must be text')
    path = Path(value)
    require(path.is_absolute(), 'Declared path must be absolute')
    path = path.resolve()
    require(path.is_relative_to(root), 'Path escapes enrolled workspace')
    if exists:
        require(path.is_file() if file else path.is_dir(),
                'Declared executable/import is not a file' if file else 'Declared root is not a directory')
    return path


def source_assertions(workspace, row, actual_root):
    """Declarations are not proof of accepted code; wrappers are files, not roots."""
    candidate = scoped_path(workspace, row.get('candidate_root') or actual_root)
    actual = scoped_path(workspace, actual_root)
    require(candidate == actual, 'Candidate root differs from observed session root')
    result = {'candidate_root': str(candidate), 'accepted_baseline': row.get('accepted_baseline'),
              'restart_root': None, 'import_path': None, 'executable': None,
              'assertion': 'not-declared', 'controlEligible': False}
    baseline = result['accepted_baseline']
    require(baseline is None or isinstance(baseline, str) and re.fullmatch('[0-9a-f]{40}', baseline),
            'Accepted baseline must be a declared exact Git revision')
    if row.get('restart_root'):
        result['restart_root'] = str(scoped_path(workspace, row['restart_root']))
    if row.get('import_path'):
        result['import_path'] = str(scoped_path(candidate, row['import_path'], file=True))
        result['assertion'] = 'own-root-file'
    if row.get('executable'):
        result['executable'] = str(scoped_path(workspace, row['executable'], file=True))
    return result


def endpoint(base):
    require(isinstance(base, str), 'Endpoint must be text')
    u = urlparse(base)
    require(u.scheme == 'http' and u.hostname in ('localhost', '127.0.0.1', '::1')
            and u.username is None and u.password is None and not u.query and not u.fragment
            and u.path in ('', '/') and u.port is not None and 1024 <= u.port <= 65535,
            'Endpoint must be explicit plain loopback HTTP without credentials/path')
    # No proxy and no DNS resolution even for the allowed localhost spelling.
    host = '[::1]' if u.hostname == '::1' else '127.0.0.1'
    return f'http://{host}:{u.port}'


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ValueError('Read-only collector refuses redirects')


def read_response(response, limit=MAX_BYTES, deadline=None):
    data = bytearray()
    while True:
        if deadline is not None and time.monotonic() >= deadline:
            raise TimeoutError('Response exceeded total deadline')
        chunk = response.read1(min(65536, limit + 1 - len(data)))
        if not chunk:
            return bytes(data)
        data.extend(chunk)
        require(len(data) <= limit, 'Response exceeds read limit')


def get_json(base, path, timeout=1.5, *, opener=None):
    base = endpoint(base)
    require(path in ('/metrics', '/settings', '/api/v0/models') or
            path.startswith('/session/status?directory='), 'Endpoint not in read-only allowlist')
    deadline = time.monotonic() + timeout
    request = Request(base + path, headers={'Accept': 'application/json'}, method='GET')
    opener = opener or build_opener(ProxyHandler({}), NoRedirect())
    with opener.open(request, timeout=timeout) as response:
        return loads(read_response(response, deadline=deadline))


def run_read(argv, *, input=None, timeout=3, limit=MAX_BYTES, cancel=None, env=None):
    """Bound stdout+stderr while reading, wall time, and cancellation independently.

    Only the exact child created here is terminated. Never kill a discovered PID,
    guest VM, worker or provider. No shell expansion; callers own fixed read argv.
    """
    flags = subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0
    process = subprocess.Popen(argv, stdin=subprocess.PIPE if input is not None else subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0,
                               creationflags=flags, env=env)
    buffers = [bytearray(), bytearray()]
    total = 0
    lock = threading.Lock()
    overflow = threading.Event()
    reader_errors = []
    def reader(stream, index):
        nonlocal total
        try:
            while chunk := stream.read(65536):
                with lock:
                    total += len(chunk)
                    if total > limit:
                        overflow.set()
                        return
                    buffers[index].extend(chunk)
        except (OSError, ValueError) as exc:
            reader_errors.append(exc)
    threads = [threading.Thread(target=reader, args=(stream, index), daemon=True)
               for index, stream in enumerate((process.stdout, process.stderr))]
    def writer():
        try:
            remaining = memoryview(input.encode('utf-8'))
            while remaining:
                written = process.stdin.write(remaining)
                if not written:
                    break
                remaining = remaining[written:]
            process.stdin.close()
        except (OSError, ValueError):
            pass
    if input is not None:
        threads.append(threading.Thread(target=writer, daemon=True))
    for thread in threads:
        thread.start()
    deadline = time.monotonic() + timeout
    failure = None
    try:
        while process.poll() is None or any(t.is_alive() for t in threads):
            if overflow.is_set():
                failure = ValueError('Process output exceeds read limit')
                break
            if cancel is not None and cancel.is_set():
                failure = TimeoutError('Read sample cancelled')
                break
            if time.monotonic() >= deadline:
                failure = TimeoutError('Read sample deadline exceeded')
                break
            time.sleep(.01)
        if overflow.is_set():
            failure = ValueError('Process output exceeds read limit')
        if failure:
            raise failure
        if reader_errors:
            raise OSError('Read sample pipe failed') from reader_errors[0]
        return subprocess.CompletedProcess(argv, process.returncode,
            buffers[0].decode('utf-8', 'replace'), buffers[1].decode('utf-8', 'replace'))
    finally:
        if process.poll() is None:
            process.kill()
        process.wait(timeout=2)
        for thread in threads:
            thread.join(timeout=.1)
        for stream in (process.stdin, process.stdout, process.stderr):
            if stream:
                stream.close()


def argument_fingerprint(arguments):
    parts = [struct.pack("<i", len(arguments))]
    for argument in arguments:
        data = argument.encode("utf-8")
        parts.extend((struct.pack("<i", len(data)), data))
    return hashlib.sha256(b"".join(parts)).hexdigest()


def process_matches(runtime, observed):
    """Passive identity only, never EzVM readiness or permission to control."""
    try:
        expected = datetime.fromisoformat(runtime['processStartTimeUtc'].replace('Z', '+00:00')).timestamp()
        return (type(runtime['pid']) is int and runtime['pid'] > 0 and
                runtime['pid'] == observed['pid'] and
                abs(expected - observed['started']) < .01 and
                os.path.normcase(os.path.abspath(runtime['qemuExecutable'])) ==
                os.path.normcase(os.path.abspath(observed['executable'])) and
                isinstance(runtime['launchId'], str) and bool(runtime['launchId']) and
                runtime['argumentFingerprint'] == argument_fingerprint(observed['arguments']))
    except (KeyError, TypeError, ValueError):
        return False


def poll_batch(roots, cursor, batch, priority=None):
    """Reserve a rotating lane; selection churn cannot reset the cursor."""
    roots = sorted(set(roots))
    if not roots:
        return [], 0
    width = min(batch, len(roots))
    reserved = max(1, width - 1) if len(roots) > width else width
    start = cursor % len(roots)
    chosen = [roots[(start + i) % len(roots)] for i in range(reserved)]
    for root in list(priority or []) + [roots[(start + i) % len(roots)] for i in range(len(roots))]:
        if len(chosen) >= width:
            break
        if root in roots and root not in chosen:
            chosen.append(root)
    return chosen, (start + reserved) % len(roots)


def status_map(data):
    require(isinstance(data, dict) and len(data) <= SESSION_SCAN, 'Unsupported status-map layout')
    for sid, row in data.items():
        require(isinstance(sid, str) and 0 < len(sid) <= 256 and isinstance(row, dict),
                'Unsupported status-map entry')
        kind = row.get('type')
        require(kind in ('idle', 'busy', 'retry'), 'Unsupported OpenCode status type')
        if kind == 'retry':
            require(type(row.get('attempt')) is int and row['attempt'] >= 0
                    and isinstance(row.get('message'), str)
                    and type(row.get('next')) in (int, float) and math.isfinite(row['next']),
                    'Unsupported OpenCode retry layout')
    return data


def reconcile_status(sid, views):
    """Positive busy remains last-known; partial failure is always unknown."""
    good = [v for v in views if v is not None]
    known = [v[sid]['type'] for v in good if sid in v]
    last = next((k for k in ('retry', 'busy', 'idle') if k in known), 'idle' if good else 'unknown')
    return ('unknown' if len(good) != len(views) else last), last


@contextmanager
def database_snapshot(path):
    """Open SQLite only on disposable bytes, including WAL; source never opened by SQLite.

    Two matching bounded file-set reads plus pre/post metadata reject changing
    captures. Do not assert immutable=1 on an engine-owned live database.
    """
    path = Path(path).resolve()
    def capture():
        result = {}
        for suffix, limit in (('', DB_BYTES), ('-wal', WAL_BYTES), ('-journal', WAL_BYTES)):
            item = Path(str(path) + suffix)
            if not item.exists():
                require(suffix != '', 'OpenCode database missing')
                result[suffix] = None
                continue
            require(item.is_file() and not item.is_symlink(), 'Unsafe database sidecar')
            before = item.stat()
            data = read_bytes(item, limit)
            after = item.stat()
            require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
                    (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns),
                    'Database changed during bounded snapshot; retry next poll')
            require(suffix != '-journal' or not data, 'Rollback journal present; source snapshot unavailable')
            result[suffix] = data
        return result
    first = capture()
    second = capture()
    require(first == second, 'Database/WAL changed between snapshot reads; retry next poll')
    del second
    require(first[''][:16] == b'SQLite format 3\x00', 'Unsupported database header')
    with tempfile.TemporaryDirectory(prefix='ezvm-observation-') as temporary:
        target = Path(temporary) / 'snapshot.db'
        for suffix, data in first.items():
            if data is not None:
                Path(str(target) + suffix).write_bytes(data)
        del first
        db = sqlite3.connect(target.as_uri() + '?mode=ro', uri=True, timeout=.25)
        try:
            db.execute('PRAGMA query_only=ON')
            db.execute('PRAGMA trusted_schema=OFF')
            db.execute('PRAGMA temp_store=MEMORY')
            db.setlimit(sqlite3.SQLITE_LIMIT_LENGTH, 1_000_000)
            deadline = time.monotonic() + 3
            steps = 0
            def budget():
                nonlocal steps
                steps += 1
                return int(steps > 10_000 or time.monotonic() >= deadline)
            db.set_progress_handler(budget, 1000)
            db.execute('BEGIN')
            require(db.execute('PRAGMA user_version').fetchone()[0] == 0, 'Unsupported OpenCode DB user_version')
            for table, columns in {'session': {'id': 'TEXT', 'title': 'TEXT', 'directory': 'TEXT', 'time_updated': 'INTEGER'},
                                   'message': {'id': 'TEXT', 'session_id': 'TEXT', 'data': 'TEXT', 'time_created': 'INTEGER'},
                                   'part': {'session_id': 'TEXT', 'data': 'TEXT', 'time_created': 'INTEGER'}}.items():
                actual = {row[1]: row[2].upper() for row in db.execute(f'PRAGMA table_info({table})')}
                require(all(actual.get(key) == value for key, value in columns.items()),
                        'Unsupported OpenCode DB layout: ' + table)
            yield db
        finally:
            db.rollback()
            db.close()
