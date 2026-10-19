"""Observation adapters plus bounded cached aggregation. No control operations."""
from __future__ import annotations

from copy import deepcopy
import concurrent.futures
import ctypes
import json
from itertools import islice
import os
from pathlib import Path
import re
import subprocess
import threading
import time
from urllib.request import build_opener, ProxyHandler

import psutil

from . import adapters
from .adapters import NoRedirect, capability, endpoint, identity, read_json, require, run_read
from .model import Sample, safe


ACTOR_FIELDS = {'session', 'root', 'accepted_baseline', 'candidate_root',
                'restart_root', 'import_path', 'executable'}


def get_json(base, path, timeout=2, *, cancel=None):
    # Validate before even constructing the transport (also a regression seam).
    endpoint(base)
    require(path in ('/metrics', '/settings', '/api/v0/models'), 'Endpoint not in read-only allowlist')
    return adapters.get_json(base, path, timeout, opener=build_opener, cancel=cancel)


def load_config(root, path=None):
    root = Path(root)
    if path is not None and not Path(path).is_file():
        raise ValueError('Explicit dashboard configuration file does not exist')
    path = Path(path) if path else root / 'runtime/dashboard/config.json'
    config = read_json(path) if path.is_file() else {'schemaVersion': 1, 'instance': None, 'engines': []}
    require(isinstance(config, dict) and type(config.get('schemaVersion')) is int and config['schemaVersion'] == 1,
            'Unsupported dashboard config schemaVersion')
    allowed = {'schemaVersion', 'instance', 'workspace', 'session_prefix', 'policy_file', 'ports',
               'engines', 'history_limit', 'status_roots', 'registered_actors', 'origin_id', 'origin_epoch'}
    require(not set(config) - allowed, 'Unknown dashboard configuration fields')
    name = config.setdefault('instance', None)
    require(name is None or isinstance(name, str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,63}', name),
            'Invalid enrolled VM name')
    workspace = config.setdefault('workspace', '/home/coder/workspace')
    require(isinstance(workspace, str) and len(workspace) <= 4096 and workspace.startswith('/')
            and not workspace.startswith('//') and '..' not in workspace.split('/')
            and all(ord(c) >= 32 for c in workspace), 'Guest workspace must be a normal absolute path')
    require(isinstance(config.get('session_prefix', ''), str) and len(config.get('session_prefix', '')) <= 256,
            'session_prefix must be bounded text')
    policy = config.get('policy_file', 'OWNER-MODEL-POLICY.json')
    require(isinstance(policy, str) and re.fullmatch(r'[A-Za-z0-9_-][A-Za-z0-9_.-]{0,127}', policy)
            and policy not in ('.', '..'), 'policy_file must be a direct-child filename')
    ports = config.setdefault('ports', [4098])
    require(isinstance(ports, list) and 1 <= len(ports) <= 4
            and all(type(p) is int and 1024 <= p <= 65535 for p in ports)
            and len(set(ports)) == len(ports), 'Configure one to four distinct guest OpenCode ports')
    for key, default, lo, hi in [('history_limit', 40, 1, 200), ('status_roots', 8, 1, 32)]:
        config.setdefault(key, default)
        require(type(config[key]) is int and lo <= config[key] <= hi, key + ' outside supported bounds')
    for key in ('origin_id', 'origin_epoch'):
        if key in config:
            require(isinstance(config[key], str) and re.fullmatch(r'[A-Za-z0-9:._-]{1,128}', config[key]),
                    key + ' must be a stable declared identifier')
    actors = config.setdefault('registered_actors', [])
    require(isinstance(actors, list) and len(actors) <= adapters.MAX_ACTORS, 'Registration limit exceeded')
    ids = set()
    for actor in actors:
        require(isinstance(actor, dict) and not set(actor) - ACTOR_FIELDS
                and isinstance(actor.get('session'), str) and 0 < len(actor['session']) <= 256,
                'Actor requires a session and supported source declaration fields')
        require(actor['session'] not in ids, 'Duplicate actor registration')
        ids.add(actor['session'])
        for key, value in actor.items():
            require(isinstance(value, str) and 0 < len(value) <= 4096
                    and all(ord(c) >= 32 for c in value), 'Actor field must be bounded plain text')
        if 'accepted_baseline' in actor:
            require(re.fullmatch('[0-9a-f]{40}', actor['accepted_baseline']), 'Baseline requires exact Git SHA')
    engines = config.setdefault('engines', [])
    require(isinstance(engines, list) and len(engines) <= 4, 'At most four enrolled engines')
    ids = set()
    for engine in engines:
        require(isinstance(engine, dict) and set(engine) == {'id', 'kind', 'url'}
                and engine['kind'] in ('strata', 'lmstudio'), 'Engine requires id/kind/url')
        require(isinstance(engine['id'], str) and re.fullmatch(r'[a-z0-9_-]{1,64}', engine['id'])
                and engine['id'] not in ids, 'Engine IDs must be distinct simple names')
        ids.add(engine['id'])
        endpoint(engine['url'])
    return config


def hidden():
    return 0x08000000 if os.name == 'nt' else 0


def host_sample(root, cancel=None):
    vm = psutil.virtual_memory()
    result = {'memory_total': vm.total, 'memory_available': vm.available,
              'cpu_percent': psutil.cpu_percent(interval=.15), 'cpus': psutil.cpu_count(),
              'disk_free': psutil.disk_usage(str(root)).free, 'gpus': [],
              'adapter': capability('host', 'host', psutil.__version__, 'passive-counters')}
    if os.name == 'nt':
        class Info(ctypes.Structure):
            _fields_ = [('cb', ctypes.c_ulong)] + [(n, ctypes.c_size_t) for n in ['CommitTotal', 'CommitLimit', 'CommitPeak', 'PhysicalTotal', 'PhysicalAvailable', 'SystemCache', 'KernelTotal', 'KernelPaged', 'KernelNonpaged', 'PageSize']] + [(n, ctypes.c_ulong) for n in ['HandleCount', 'ProcessCount', 'ThreadCount']]
        value = Info()
        value.cb = ctypes.sizeof(value)
        if ctypes.WinDLL('psapi').GetPerformanceInfo(ctypes.byref(value), value.cb):
            result['commit_available'] = (value.CommitLimit - value.CommitTotal) * value.PageSize
    try:
        process = run_read(['nvidia-smi', '--query-gpu=index,uuid,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit', '--format=csv,noheader,nounits'],
                           timeout=3, limit=64000, cancel=cancel)
        require(process.returncode == 0, 'nvidia-smi exited nonzero')
        for line in process.stdout.splitlines()[:32]:
            values = [v.strip() for v in line.split(',')]
            if len(values) == 9:
                result['gpus'].append(dict(zip(['index', 'uuid', 'name', 'util', 'used_mib', 'total_mib', 'temp', 'power', 'limit'], values)))
    except (OSError, ValueError, TimeoutError):
        result['gpu_error'] = 'GPU counters unavailable (no loader invoked)'
    return result


def observed_process(runtime):
    p = psutil.Process(runtime['pid'])
    with p.oneshot():
        return {'pid': p.pid, 'started': p.create_time(), 'executable': p.exe(),
                'arguments': p.cmdline()[1:], 'rss': p.memory_info().rss}


def inventory_sample(root):
    rows = []
    # This is the repository's instance directory, not broad machine discovery.
    for i, directory in enumerate(sorted(islice((root / 'runtime/instances').glob('*'), 257))):
        if i >= 256:
            rows.append({'name': '(inventory limit)', 'error': 'More than 256 entries; remaining state unobserved'})
            break
        if not directory.is_dir():
            continue
        try:
            intent = read_json(directory / 'instance.json')
            runtime = read_json(directory / 'runtime.json') if (directory / 'runtime.json').is_file() else {}
            require(isinstance(intent, dict) and isinstance(runtime, dict), 'Invalid instance layout')
            row = {'name': directory.name, 'intent': intent, 'recorded_state': runtime.get('state', 'CREATED'),
                   'accelerator': runtime.get('accelerator'), 'process': 'not observed', 'controlEligible': False,
                   'generation': intent.get('identityGeneration'), 'launch': runtime.get('launchId')}
            if runtime.get('pid'):
                try:
                    observed = observed_process(runtime)
                    row['process'] = 'identity matched' if adapters.process_matches(runtime, observed) else 'identity mismatch'
                    if row['process'] == 'identity matched':
                        row['process_rss'] = observed['rss']
                except (psutil.Error, KeyError, ValueError, TypeError):
                    row['process'] = 'unavailable / process absent'
            rows.append(row)
        except (OSError, ValueError, TypeError) as exc:
            rows.append({'name': directory.name, 'error': safe(str(exc), 200)})
    return {'vms': rows, 'adapter': capability('ezvm-passive', str(root), 'intent-v1/v2;runtime-v1', 'PID/start/executable/argv'),
            'note': 'Passive identity is not fresh EzVM READY qualification or control authority.'}


def _guest_identity(root, name):
    directory = root / 'runtime/instances' / name
    require(directory.resolve().is_relative_to(root.resolve()), 'Instance state escapes managed root')
    access, runtime, intent = [read_json(directory / (key + '.json')) for key in ('access', 'runtime', 'instance')]
    require(all(isinstance(v, dict) for v in (access, runtime, intent)), 'Malformed guest state')
    require(access.get('state') == 'READY' and runtime.get('state') == 'RUNNING'
            and isinstance(runtime.get('launchId'), str) and runtime['launchId']
            and access.get('launchId') == runtime['launchId'] and access.get('baseId') == intent.get('baseId')
            and isinstance(intent.get('baseId'), str) and intent['baseId']
            and access.get('sshHost') == '127.0.0.1' and access.get('sshPort') == intent.get('sshPort')
            and type(access.get('sshPort')) is int and 1024 <= access['sshPort'] <= 65535,
            'Guest access does not match READY launch/intent; no SSH probe sent')
    require(type(runtime.get('schemaVersion')) is int and runtime['schemaVersion'] == 1
            and type(intent.get('schemaVersion')) is int and intent['schemaVersion'] in (1, 2)
            and type(access.get('schemaVersion')) is int and access['schemaVersion'] == 2,
            'Unsupported EzVM state schema; no SSH probe sent')
    require(intent.get('name') == name and runtime.get('instanceName') == name
            and access.get('instanceName') == name, 'Instance identity mismatch')
    if intent['schemaVersion'] == 2:
        require(isinstance(intent.get('identityGeneration'), str) and
                re.fullmatch('[0-9a-f]{32}', intent['identityGeneration']), 'Invalid VM identity generation')
    require(adapters.process_matches(runtime, observed_process(runtime)), 'Live QEMU identity mismatch; no SSH probe sent')
    require(isinstance(access.get('sshUser'), str) and re.fullmatch(r'[a-z_][a-z0-9_-]*', access['sshUser']),
            'Invalid guest SSH user')
    return access, runtime, intent


def ssh_config_path(path, expand_tokens=False):
    """Mirror core Ssh.ps1 quoting: OpenSSH reparses the scalar inside argv."""
    value = str(path)
    require(value and all(ord(c) >= 32 for c in value), 'Invalid SSH configuration path')
    if os.name == 'nt':
        value = value.replace('\\', '/')
    if expand_tokens:
        require('${' not in value, 'SSH known-host path cannot contain environment expansion')
        value = value.replace('%', '%%')
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'


def guest_payload(settings):
    """Compile each reviewed module independently; future imports keep their scope."""
    directory = Path(__file__).resolve().parent
    require(Path(adapters.__file__).resolve() == directory / 'adapters.py', 'Imported adapter source is another checkout')
    support = (directory / 'adapters.py').read_text(encoding='utf-8')
    guest = (directory / 'guest_probe.py').read_text(encoding='utf-8')
    return ("import sys, types\np = types.ModuleType('ezvm_dashboard'); p.__path__ = []\n"
            "sys.modules['ezvm_dashboard'] = p\nm = types.ModuleType('ezvm_dashboard.adapters')\n"
            "sys.modules['ezvm_dashboard.adapters'] = m\n" +
            'exec(compile(' + repr(support) + ", '<reviewed-read-adapters>', 'exec'), m.__dict__)\n" +
            'g = {"__name__": "__main__", "CONFIG": ' + repr(settings) + '}\n' +
            'exec(compile(' + repr(guest) + ", '<reviewed-guest-sampler>', 'exec'), g)\n")


def guest_sample(root, config, selected=None, poll_state=None, cancel=None):
    name = config.get('instance')
    if not name:
        return {'schemaVersion': 1, 'workers': [], 'usage': [], 'errors': ['No guest enrolled; edit runtime/dashboard/config.json']}
    access, runtime, intent = _guest_identity(root, name)
    keys = root / 'runtime/keys'
    key, known = keys / 'controller_ed25519', keys / 'known-hosts' / (name + '.known_hosts')
    require(key.is_file() and known.is_file(), 'Existing managed SSH identity/trust unavailable; no keys created')
    require(keys.resolve().is_relative_to(root.resolve()), 'Managed key directory redirected outside root')
    require(key.resolve().is_relative_to(keys.resolve()) and known.resolve().is_relative_to(keys.resolve()), 'Managed SSH trust path redirected')
    ssh = str(Path(os.environ.get('SystemRoot', r'C:\Windows')) / 'System32/OpenSSH/ssh.exe') if os.name == 'nt' else 'ssh'
    args = [ssh, '-F', 'NUL' if os.name == 'nt' else '/dev/null', '-T', '-o', 'BatchMode=yes',
            '-o', 'StrictHostKeyChecking=yes', '-o', 'UpdateHostKeys=no', '-o', 'IdentitiesOnly=yes',
            '-o', 'ConnectTimeout=4', '-o', 'ServerAliveInterval=3', '-o', 'ServerAliveCountMax=2',
            '-o', 'UserKnownHostsFile=' + ssh_config_path(known, expand_tokens=True),
            '-o', 'GlobalKnownHostsFile=' + ssh_config_path('NUL' if os.name == 'nt' else '/dev/null'),
            '-o', 'HostKeyAlgorithms=ssh-ed25519', '-o', 'PasswordAuthentication=no',
            '-o', 'KbdInteractiveAuthentication=no', '-o', 'PreferredAuthentications=publickey',
            '-o', 'ConnectionAttempts=1', '-i', str(key), '-p', str(access['sshPort']),
            access['sshUser'] + '@127.0.0.1', 'python3 -']
    settings = {k: v for k, v in config.items() if k not in ('engines', 'schemaVersion')}
    settings.update(selected=selected, _poll_state=poll_state,
                    _vm_generation=intent.get('identityGeneration') or identity(intent.get('createdAt'), intent['baseId']),
                    _launch=identity(runtime['launchId'], runtime['pid'], runtime['processStartTimeUtc'], runtime['argumentFingerprint']))
    code = guest_payload(settings)
    process = run_read(args, input=code, timeout=40, limit=adapters.MAX_BYTES, cancel=cancel)
    require(process.returncode == 0, 'Read-only guest probe failed: ' + safe(process.stderr[-700:]))
    data = adapters.loads(process.stdout)
    require(isinstance(data, dict) and type(data.get('schemaVersion')) is int and data['schemaVersion'] == 1
            and isinstance(data.get('workers'), list) and len(data['workers']) <= 457,
            'Unsupported guest observation envelope')
    after_access, after_runtime, after_intent = _guest_identity(root, name)
    require(all(after_access.get(k) == access.get(k) for k in ('state', 'launchId', 'baseId', 'sshHost', 'sshPort', 'sshUser'))
            and all(after_runtime.get(k) == runtime.get(k) for k in ('launchId', 'pid', 'processStartTimeUtc', 'qemuExecutable', 'argumentFingerprint'))
            and all(after_intent.get(k) == intent.get(k) for k in ('identityGeneration', 'createdAt', 'baseId', 'name')),
            'Guest identity changed during observation')
    return data


def engine_sample(engine, cancel=None):
    data = get_json(engine['url'], '/metrics' if engine['kind'] == 'strata' else '/api/v0/models', cancel=cancel)
    require(isinstance(data, dict) and ('schemaVersion' not in data or
            type(data['schemaVersion']) is int and data['schemaVersion'] == 1), 'Unsupported engine envelope version')
    meta = capability(engine['kind'], engine['id'], engine['kind'] + '-layout-v1', 'allowlisted-GET')
    if engine['kind'] == 'strata':
        for key in ('engine', 'live', 'totals'):
            require(isinstance(data.get(key, {}), dict), 'Unsupported Strata ' + key + ' layout')
        requests = data.get('requests', [])
        require(isinstance(requests, list) and len(requests) <= 2000 and all(isinstance(r, dict) for r in requests), 'Unsupported Strata requests')
        return {'kind': 'strata', 'engine': data.get('engine', {}), 'live': data.get('live', {}),
                'requests': requests[:8], 'totals': data.get('totals', {}), 'adapter': meta,
                'context': {'requested': None, 'configured': data.get('engine', {}).get('max_context'),
                            'effective': data.get('engine', {}).get('effective_context'),
                            'observed_prompt': data.get('live', {}).get('prompt_tokens')}}
    models = data.get('data')
    require(isinstance(models, list) and len(models) <= 256 and all(isinstance(m, dict) for m in models), 'Unsupported LM Studio v0 models layout')
    return {'kind': 'lmstudio', 'models': models, 'adapter': meta,
            'note': 'Reported model state only; no load, inference or effective-context probe.'}


class Collector:
    """One in-flight sample per source. Monotonic deadlines; rendering never waits for I/O."""
    def __init__(self, root, config):
        self.root, self.config = root, config
        self.selected = None
        self.lock = threading.Lock()
        self.stop_event = threading.Event()
        self.samples, self.pending = {}, {}
        declared = config.get('registered_actors', [])
        if declared:
            self.samples['guest'] = Sample({'workers': [dict(id=a['session'], title=a['session'],
                registration='registered', state='unknown', controlEligible=False,
                error='Not yet sampled', ageSeconds=None) for a in declared],
                'status_coverage': {'registered': len(declared), 'sampled': 0,
                    'overdue': [a['session'] for a in declared], 'oldest_age_seconds': None,
                    'note': 'Host-declared registrations only; guest policy roster not yet observed'}})
        self._attempt, self._good, self._started, self._late = {}, {}, {}, set()
        self._poll_state = None
        self.pool = concurrent.futures.ThreadPoolExecutor(max_workers=7, thread_name_prefix='ezvm-read')
        self.jobs = {'host': (3, lambda: host_sample(root, self.stop_event)),
                     'inventory': (10, lambda: inventory_sample(root)),
                     'guest': (8, lambda: guest_sample(root, config, self.selected, self._poll_state, self.stop_event))}
        for engine in config['engines']:
            self.jobs['engine:' + engine['id']] = (3, lambda e=engine: engine_sample(e, self.stop_event))
        self.thread = None

    def start(self):
        require(not self.stop_event.is_set(), 'Collector already closed')
        if self.thread is None:
            self.thread = threading.Thread(target=self.run, daemon=True)
            self.thread.start()

    def run(self):
        while not self.stop_event.is_set():
            self.tick()
            self.stop_event.wait(.05)

    def tick(self):
        now = time.monotonic()
        with self.lock:
            for key, future in list(self.pending.items()):
                sample = self.samples.setdefault(key, Sample())
                started = self._started.setdefault(key, now)
                bound = 42 if key == 'guest' else 6
                if now - started > bound:
                    self._late.add(key)
                    sample.error = 'Sample deadline exceeded; source unknown; no overlapping retry'
                if future.done():
                    try:
                        require(key not in self._late, 'Late sample discarded after deadline')
                        data = future.result()
                        require(isinstance(data, dict), 'Adapter must return an observation object')
                        if key == 'guest':
                            before = sample.data.get('resources', {}).get('cpu_ticks')
                            after = data.get('resources', {}).get('cpu_ticks')
                            if before and after and len(before) == len(after) >= 5:
                                delta = [b - a for a, b in zip(before, after)]
                                if sum(delta) > 0 and min(delta) >= 0:
                                    data['resources']['cpu_percent'] = 100 * (sum(delta) - delta[3] - delta[4]) / sum(delta)
                            self._poll_state = data.get('_poll_state')
                        sample.data, sample.updated, sample.error = data, time.time(), ''
                        self._good[key] = now
                    except Exception as exc:
                        sample.error = safe(str(exc), 500)
                    del self.pending[key]
                    self._started.pop(key, None)
                    self._late.discard(key)
            if self.stop_event.is_set():
                return
            for key, (interval, function) in self.jobs.items():
                sample = self.samples.setdefault(key, Sample())
                attempted = self._attempt.setdefault(key, now - max(0, time.time() - sample.attempted) if sample.attempted else -float('inf'))
                if key not in self.pending and now - attempted >= interval:
                    self._attempt[key], sample.attempted, self._started[key] = now, time.time(), now
                    self.pending[key] = self.pool.submit(function)

    def snapshot(self):
        now = time.monotonic()
        with self.lock:
            snapshot = {k: (v.data, v.updated, v.attempted, v.error, self._good.get(k)) for k, v in self.samples.items()}
        result = {}
        for key, (data, updated, attempted, error, good) in snapshot.items():
            data = deepcopy(data)
            elapsed = max(0, now - good) if good is not None else 0
            if good is not None:
                updated = time.time() - elapsed
            if key == 'guest':
                data.pop('_poll_state', None)
                for worker in data.get('workers', []):
                    if worker.get('ageSeconds') is not None:
                        worker['ageSeconds'] += elapsed
                    cycle = data.get('status_coverage', {}).get('cycle_bound_seconds', 0)
                    if error or worker.get('ageSeconds', 0) is not None and worker.get('ageSeconds', 0) > cycle:
                        worker.setdefault('lastKnownState', worker.get('state', 'unknown'))
                        worker['state'] = 'unknown'
                        worker['error'] = error or 'Source overdue'
                if error:
                    data.setdefault('errors', []).append(error)
                coverage = data.get('status_coverage', {})
                if coverage.get('oldest_age_seconds') is not None:
                    coverage['oldest_age_seconds'] += elapsed
                if coverage:
                    coverage['overdue'] = [w['id'] for w in data.get('workers', []) if w.get('registration') == 'registered' and w.get('state') == 'unknown']
            result[key] = Sample(data, updated, attempted, error)
        return result

    def refresh(self):
        with self.lock:
            # Keep the fairness cursor and single-inflight discipline.
            for key in self.jobs:
                self._attempt[key] = -float('inf')

    def select(self, sid):
        with self.lock:
            self.selected = sid
        # Selection changes priority next cycle, never the poll cadence or cursor.

    def close(self):
        self.stop_event.set()
        if self.thread:
            self.thread.join(timeout=1)
        self.pool.shutdown(wait=False, cancel_futures=True)
