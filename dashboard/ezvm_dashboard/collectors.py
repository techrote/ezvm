"""Bounded observation adapters. No model, session or VM mutation methods."""
from __future__ import annotations

import concurrent.futures
import ctypes
import json
import os
from pathlib import Path
import re
import subprocess
import threading
import time
from urllib.parse import urlparse
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener

import psutil

from .model import Sample, safe


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ValueError('Read-only collector refuses redirects')


def get_json(base, path, timeout=2):
    parts = urlparse(base)
    if parts.scheme != 'http' or parts.hostname not in ('127.0.0.1', 'localhost', '::1') or parts.username or parts.query or parts.fragment or parts.path not in ('', '/'):
        raise ValueError('Engine endpoint must be plain loopback HTTP with no credentials/path')
    if path not in ('/metrics', '/settings', '/api/v0/models'):
        raise ValueError('Endpoint is not in the read-only allowlist')
    request = Request(base.rstrip('/') + path, headers={'Accept': 'application/json'}, method='GET')
    with build_opener(ProxyHandler({}), NoRedirect()).open(request, timeout=timeout) as response:
        data = response.read(4_000_001)
        if len(data) > 4_000_000:
            raise ValueError('Metrics response exceeded collector bound')
        return json.loads(data)


def read_json(path):
    data = Path(path).read_bytes()
    if len(data) > 4_000_000:
        raise ValueError('Configuration/state file too large')
    return json.loads(data.decode('utf-8-sig'))


def load_config(root, path=None):
    if path is not None and not Path(path).is_file():
        raise ValueError('Explicit dashboard configuration file does not exist')
    path = Path(path) if path else root / 'runtime/dashboard/config.json'
    config = read_json(path) if path.is_file() else {'schemaVersion': 1, 'instance': None, 'engines': []}
    if not isinstance(config, dict) or config.get('schemaVersion') != 1:
        raise ValueError('Unsupported dashboard config schemaVersion')
    allowed = {'schemaVersion', 'instance', 'workspace', 'session_prefix', 'policy_file', 'ports', 'engines', 'history_limit', 'status_roots'}
    if set(config) - allowed:
        raise ValueError('Unknown dashboard configuration fields: ' + ', '.join(set(config) - allowed))
    if config.get('instance') and not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,63}', config['instance']):
        raise ValueError('Invalid enrolled VM name')
    workspace = config.setdefault('workspace', '/home/coder/workspace')
    if not isinstance(workspace, str) or not workspace.startswith('/') or '\n' in workspace or '..' in workspace.split('/'):
        raise ValueError('Guest workspace must be a normal absolute path')
    if not isinstance(config.get('session_prefix', ''), str):
        raise ValueError('session_prefix must be text')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+', config.get('policy_file', 'OWNER-MODEL-POLICY.json')):
        raise ValueError('policy_file must be a direct-child filename')
    config.setdefault('ports', [4098])
    if not isinstance(config['ports'], list) or not 1 <= len(config['ports']) <= 4 or any(type(p) is not int or not 1024 <= p <= 65535 for p in config['ports']):
        raise ValueError('Configure one to four explicit guest OpenCode ports')
    for key, default, lo, hi in [('history_limit', 40, 1, 200), ('status_roots', 8, 1, 32)]:
        config.setdefault(key, default)
        if type(config[key]) is not int or not lo <= config[key] <= hi:
            raise ValueError(f'{key} outside supported bounds')
    engines = config.setdefault('engines', [])
    if not isinstance(engines, list) or len(engines) > 4:
        raise ValueError('At most four explicitly enrolled engines')
    ids = set()
    for engine in engines:
        if not isinstance(engine, dict) or set(engine) != {'id', 'kind', 'url'} or engine['kind'] not in ('strata', 'lmstudio'):
            raise ValueError('Engine requires id/kind/url; supported kinds strata,lmstudio')
        if not re.fullmatch(r'[a-z0-9_-]+', engine['id']) or engine['id'] in ids:
            raise ValueError('Engine IDs must be distinct simple names')
        ids.add(engine['id'])
        u = urlparse(engine['url'])
        if u.scheme != 'http' or u.hostname not in ('localhost', '127.0.0.1', '::1') or u.username or u.path not in ('', '/') or u.query or u.fragment:
            raise ValueError('Only explicit loopback engine endpoints are supported')
    return config


def host_sample(root):
    vm = psutil.virtual_memory()
    result = {'memory_total': vm.total, 'memory_available': vm.available,
              'cpu_percent': psutil.cpu_percent(interval=.15), 'cpus': psutil.cpu_count(),
              'disk_free': psutil.disk_usage(str(root)).free, 'gpus': []}
    if os.name == 'nt':
        class Info(ctypes.Structure):
            _fields_ = [('cb', ctypes.c_ulong)] + [(n, ctypes.c_size_t) for n in ['CommitTotal', 'CommitLimit', 'CommitPeak', 'PhysicalTotal', 'PhysicalAvailable', 'SystemCache', 'KernelTotal', 'KernelPaged', 'KernelNonpaged', 'PageSize']] + [(n, ctypes.c_ulong) for n in ['HandleCount', 'ProcessCount', 'ThreadCount']]
        value = Info()
        value.cb = ctypes.sizeof(value)
        if ctypes.WinDLL('psapi').GetPerformanceInfo(ctypes.byref(value), value.cb):
            result['commit_available'] = (value.CommitLimit - value.CommitTotal) * value.PageSize
    try:
        process = subprocess.run(['nvidia-smi', '--query-gpu=index,uuid,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit', '--format=csv,noheader,nounits'], capture_output=True, text=True, timeout=3, creationflags=hidden())
        if process.returncode:
            raise ValueError('nvidia-smi exited nonzero')
        for line in process.stdout.splitlines():
            values = [v.strip() for v in line.split(',')]
            if len(values) == 9:
                result['gpus'].append(dict(zip(['index', 'uuid', 'name', 'util', 'used_mib', 'total_mib', 'temp', 'power', 'limit'], values)))
    except (OSError, ValueError, subprocess.TimeoutExpired):
        result['gpu_error'] = 'GPU counters unavailable (no loader invoked)'
    return result


def hidden():
    return subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0


def inventory_sample(root):
    rows = []
    for directory in sorted((root / 'runtime/instances').glob('*')):
        if not directory.is_dir():
            continue
        try:
            intent = read_json(directory / 'instance.json')
            runtime = read_json(directory / 'runtime.json') if (directory / 'runtime.json').is_file() else {}
            row = {'name': directory.name, 'intent': intent, 'recorded_state': runtime.get('state', 'CREATED'),
                   'accelerator': runtime.get('accelerator'), 'process': 'not observed'}
            if runtime.get('pid'):
                try:
                    from datetime import datetime
                    p = psutil.Process(runtime['pid'])
                    expected = datetime.fromisoformat(runtime['processStartTimeUtc'].replace('Z', '+00:00')).timestamp()
                    if abs(p.create_time() - expected) < 2 and os.path.normcase(p.exe()) == os.path.normcase(runtime['qemuExecutable']):
                        row.update(process='identity matched', process_rss=p.memory_info().rss)
                    else:
                        row['process'] = 'identity mismatch'
                except (psutil.Error, KeyError, ValueError):
                    row['process'] = 'unavailable / process absent'
            rows.append(row)
        except (OSError, ValueError, TypeError) as exc:
            rows.append({'name': directory.name, 'error': safe(type(exc).__name__)})
    return {'vms': rows, 'note': 'Passive persisted state + PID/start/executable check; not fresh EzVM READY qualification.'}


def guest_sample(root, config, selected=None):
    name = config.get('instance')
    if not name:
        return {'workers': [], 'usage': [], 'errors': ['No guest enrolled; edit runtime/dashboard/config.json']}
    access = read_json(root / 'runtime/instances' / name / 'access.json')
    runtime = read_json(root / 'runtime/instances' / name / 'runtime.json')
    intent = read_json(root / 'runtime/instances' / name / 'instance.json')
    if access.get('state') != 'READY' or access.get('launchId') != runtime.get('launchId') or access.get('baseId') != intent.get('baseId') or access.get('sshHost') != '127.0.0.1' or access.get('sshPort') != intent.get('sshPort'):
        raise ValueError('Guest access does not match persisted READY launch/intent; no SSH probe sent')
    if not re.fullmatch(r'[a-z_][a-z0-9_-]*', access.get('sshUser', '')):
        raise ValueError('Invalid guest SSH user')
    keys = root / 'runtime/keys'
    key = keys / 'controller_ed25519'
    known = keys / 'known-hosts' / (name + '.known_hosts')
    if not key.is_file() or not known.is_file():
        raise ValueError('Existing managed SSH identity/trust unavailable; no keys created')
    # Existing identity is only referenced by SSH; never read or rewritten here.
    ssh = str(Path(os.environ.get('SystemRoot', r'C:\Windows')) / 'System32/OpenSSH/ssh.exe') if os.name == 'nt' else 'ssh'
    args = [ssh, '-F', 'NUL' if os.name == 'nt' else '/dev/null', '-T', '-o', 'BatchMode=yes',
            '-o', 'StrictHostKeyChecking=yes', '-o', 'UpdateHostKeys=no', '-o', 'IdentitiesOnly=yes',
            '-o', 'ConnectTimeout=4', '-o', 'ServerAliveInterval=3', '-o', 'ServerAliveCountMax=2',
            '-o', 'UserKnownHostsFile=' + str(known), '-i', str(key), '-p', str(access['sshPort']),
            access['sshUser'] + '@127.0.0.1', 'python3 -']
    settings = {k: config[k] for k in ('instance', 'workspace', 'ports', 'history_limit', 'status_roots')}
    settings.update(session_prefix=config.get('session_prefix', ''), policy_file=config.get('policy_file', 'OWNER-MODEL-POLICY.json'), selected=selected)
    code = 'CONFIG = ' + repr(settings) + '\n' + Path(__file__).with_name('guest_probe.py').read_text(encoding='utf-8')
    # The configured 32-root maximum can require 24s of failed HTTP batches.
    # This remains off the UI thread, with only one in-flight guest sample.
    process = subprocess.run(args, input=code, capture_output=True, text=True, encoding='utf-8', timeout=40, creationflags=hidden())
    if process.returncode:
        raise RuntimeError('Read-only guest probe failed: ' + safe(process.stderr[-700:]))
    if len(process.stdout) > 4_000_000:
        raise ValueError('Guest sample exceeded bound')
    return json.loads(process.stdout)


def engine_sample(engine):
    if engine['kind'] == 'strata':
        data = get_json(engine['url'], '/metrics')
        # Only the bounded metrics payload, never prompts or request bodies.
        return {'kind': 'strata', 'engine': data.get('engine', {}), 'live': data.get('live', {}),
                'requests': data.get('requests', [])[:8], 'totals': data.get('totals', {})}
    data = get_json(engine['url'], '/api/v0/models')
    return {'kind': 'lmstudio', 'models': data.get('data', []),
            'note': 'Model state from LM Studio API; per-worker decode rate not exposed here.'}


class Collector:
    """At most one in-flight sample per source; UI reads a cached snapshot."""
    def __init__(self, root, config):
        self.root, self.config = root, config
        self.selected = None
        self.lock = threading.Lock()
        self.stop_event = threading.Event()
        self.samples = {}
        self.pending = {}
        self.pool = concurrent.futures.ThreadPoolExecutor(max_workers=7, thread_name_prefix='ezvm-read')
        self.jobs = {'host': (3, lambda: host_sample(root)), 'inventory': (10, lambda: inventory_sample(root)),
                     'guest': (8, lambda: guest_sample(root, config, self.selected))}
        for engine in config['engines']:
            self.jobs['engine:' + engine['id']] = (3, lambda e=engine: engine_sample(e))
        self.thread = None

    def start(self):
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        while not self.stop_event.is_set():
            self.tick()
            self.stop_event.wait(.15)

    def tick(self):
        with self.lock:
            for key, future in list(self.pending.items()):
                if future.done():
                    previous = self.samples.setdefault(key, Sample())
                    try:
                        data = future.result()
                        if key == 'guest' and previous.data.get('resources') and data.get('resources'):
                            before = previous.data['resources'].get('cpu_ticks')
                            after = data['resources'].get('cpu_ticks')
                            if before and after:
                                delta = [b-a for a,b in zip(before, after)]
                                if sum(delta) > 0 and all(x >= 0 for x in delta):
                                    data['resources']['cpu_percent'] = 100*(sum(delta)-delta[3]-delta[4])/sum(delta)
                        previous.data, previous.updated, previous.error = data, time.time(), ''
                    except Exception as exc:
                        previous.error = safe(str(exc), 500)
                    del self.pending[key]
            for key, (interval, function) in self.jobs.items():
                sample = self.samples.setdefault(key, Sample())
                if key not in self.pending and time.time() - sample.attempted >= interval:
                    sample.attempted = time.time()
                    self.pending[key] = self.pool.submit(function)

    def snapshot(self):
        with self.lock:
            return {key: Sample(value.data, value.updated, value.attempted, value.error) for key, value in self.samples.items()}

    def refresh(self):
        with self.lock:
            for sample in self.samples.values():
                sample.attempted = 0

    def select(self, sid):
        if self.selected != sid:
            self.selected = sid
            with self.lock:
                if 'guest' in self.samples:
                    self.samples['guest'].attempted = 0

    def close(self):
        self.stop_event.set()
        if self.thread:
            self.thread.join(timeout=1)
        self.pool.shutdown(wait=False, cancel_futures=True)
