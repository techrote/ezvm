"""Sent to an enrolled guest's python3 stdin. Reads only; no installed guest files.

CONFIG is supplied as a Python literal by the host. All HTTP calls are GET;
SQLite is opened mode=ro/query_only. No prompt/session/lifecycle write endpoint.
"""
import concurrent.futures
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import time
from urllib.parse import urlencode
from urllib.request import HTTPRedirectHandler, ProxyHandler, build_opener


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ValueError('Scoped status collector refuses redirects')


def collect(config):
    workspace = Path(config['workspace']).resolve()
    result = {'observedAt': time.time(), 'workspace': str(workspace), 'errors': []}
    mem = {}
    for line in Path('/proc/meminfo').read_text().splitlines():
        key, value = line.split(':', 1)
        mem[key] = int(value.strip().split()[0]) * 1024
    result['resources'] = {
        'cpus': os.cpu_count(), 'load': list(os.getloadavg()),
        'memory_total': mem['MemTotal'], 'memory_available': mem['MemAvailable'],
        'swap_used': mem['SwapTotal'] - mem['SwapFree'],
        'disk_total': shutil.disk_usage(workspace).total,
        'disk_free': shutil.disk_usage(workspace).free,
        'cpu_ticks': [int(n) for n in Path('/proc/stat').read_text().splitlines()[0].split()[1:9]],
    }
    policy = workspace / config.get('policy_file', 'OWNER-MODEL-POLICY.json')
    if policy.parent.resolve() != workspace:
        raise ValueError('Policy must be a direct child of the enrolled workspace')
    try:
        p = json.loads(policy.read_text())
        result['policy'] = {'owner_paused': p.get('owner_paused'), 'status': p.get('status'),
                            'actors': p.get('actors', []), 'max_nvidia_workers': p.get('max_nvidia_workers')}
    except (OSError, ValueError):
        result['policy'] = {'owner_paused': None, 'actors': [], 'status': 'not configured / unavailable'}

    dbpath = Path.home() / '.local/share/opencode/opencode.db'
    if not dbpath.is_file():
        result.update(workers=[], usage=[], errors=['OpenCode database not found; worker telemetry unavailable'])
        return result
    db = sqlite3.connect(dbpath.as_uri() + '?mode=ro', uri=True, timeout=2)
    db.execute('PRAGMA query_only=ON')
    db.execute('BEGIN')
    sessions = []
    for sid, title, directory, updated in db.execute('SELECT id,title,directory,time_updated FROM session ORDER BY time_updated DESC'):
        root = Path(directory)
        if root.resolve().is_relative_to(workspace) and title.startswith(config.get('session_prefix', '')):
            sessions.append({'id': sid, 'title': title, 'root': directory, 'updated': updated,
                             'origin': config['instance'] + ':opencode-db', 'state': 'unobserved'})
    owned = {s['id']: s for s in sessions}
    groups, totals, last = {}, {}, {}
    for mid, sid, data in db.execute('SELECT id,session_id,data FROM message ORDER BY time_created'):
        if sid not in owned:
            continue
        info = json.loads(data)
        if info.get('role') != 'assistant':
            continue
        model = info.get('model') or {}
        provider = info.get('providerID') or model.get('providerID') or 'unknown'
        modelid = info.get('modelID') or model.get('modelID') or 'unknown'
        tokens = info.get('tokens') or {}
        cache = tokens.get('cache') or {}
        values = {'input': tokens.get('input'), 'cache_read': cache.get('read'),
                  'cache_write': cache.get('write'), 'output': tokens.get('output'),
                  'reasoning': tokens.get('reasoning'), 'reported_total': tokens.get('total')}
        # Each message primary key occurs once in this snapshot; ports are not summed.
        for group in (groups.setdefault((provider, modelid), {'messages': 0, 'with_usage': 0}),
                      totals.setdefault(sid, {'messages': 0, 'with_usage': 0})):
            group['messages'] += 1
            group['with_usage'] += int(bool(tokens) and any(isinstance(v, (int, float)) and v > 0 for v in values.values()))
            for key, value in values.items():
                if isinstance(value, (int, float)) and not isinstance(value, bool) and value >= 0:
                    group[key] = group.get(key, 0) + value
                    group[key + '_records'] = group.get(key + '_records', 0) + 1
        last[sid] = {'provider': provider, 'model': modelid, 'last_usage': values,
                     'finish': info.get('finish'), 'has_error': bool(info.get('error'))}
    result['usage'] = [dict(provider=k[0], model=k[1], **v) for k, v in sorted(groups.items())]
    limit = config.get('history_limit', 40)
    actors = {a.get('session') for a in result['policy']['actors']}
    selected = config.get('selected')
    workers = [s for i, s in enumerate(sessions) if i < limit or s['id'] in actors or s['id'] == selected]
    for s in workers:
        s.update(last.get(s['id'], {}))
        s['usage'] = totals.get(s['id'], {})
    result['workers'] = workers
    result['session_count'] = len(sessions)
    result['usage_note'] = 'OpenCode message snapshot; all enrolled history; raw normalized fields, no combined token total. Missing/error usage not inferred. Engine counters separate.'

    detail = owned.get(selected) or (workers[0] if workers else None)
    result['detail'] = {}
    if detail:
        events = []
        for data, created in db.execute('SELECT data,time_created FROM part WHERE session_id=? ORDER BY time_created DESC LIMIT 45', (detail['id'],)):
            part = json.loads(data)
            kind = part.get('type')
            if kind == 'tool':
                state = part.get('state') or {}
                metadata = state.get('metadata') or {}
                events.append({'kind': 'tool', 'time': created, 'name': part.get('tool'),
                               'status': state.get('status'), 'title': str(state.get('title') or '')[:300],
                               'exit': metadata.get('exit'), 'output': str(state.get('output') or state.get('error') or '')[-5000:]})
            elif kind == 'text':
                events.append({'kind': 'text', 'time': created, 'text': str(part.get('text', ''))[-5000:]})
        result['detail'] = {'id': detail['id'], 'root': detail['root'], 'events': list(reversed(events))}
        path = Path(detail['root']).resolve()
        if path.is_relative_to(workspace) and path.is_dir():
            def git(*args):
                try:
                    p = subprocess.run(['git', '--no-optional-locks', '-C', str(path), *args],
                                       capture_output=True, text=True, timeout=2)
                    return p.stdout[:12000] if p.returncode == 0 else '(unavailable)'
                except (OSError, subprocess.TimeoutExpired):
                    return '(unavailable)'
            result['detail']['head'] = git('rev-parse', 'HEAD').strip()
            result['detail']['changes'] = git('status', '--short')
            result['detail']['diff_stat'] = git('diff', '--stat')
    db.rollback()
    db.close()

    # Bounded scoped status sampling; unsampled sessions stay explicitly unobserved.
    # Registered actors and the selected session always take priority over recent history.
    directories = []
    for s in sorted(workers, key=lambda x: (x['id'] != selected, x['id'] not in actors, -x['updated'])):
        if s['root'] not in directories:
            directories.append(s['root'])
    directories = directories[:config.get('status_roots', 8)]
    ports = config.get('ports', [4098])
    opener = build_opener(ProxyHandler({}), NoRedirect())
    def status(pair):
        port, directory = pair
        url = f'http://127.0.0.1:{port}/session/status?' + urlencode({'directory': directory})
        try:
            with opener.open(url, timeout=1.5) as response:
                data = json.loads(response.read(2_000_000))
            if not isinstance(data, dict):
                raise ValueError('unexpected status format')
            return port, directory, data, None
        except Exception as exc:
            return port, directory, {}, type(exc).__name__
    observations = {}
    failures = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        for port, directory, states, error in pool.map(status, [(p, d) for p in ports for d in directories]):
            observations[(port, directory)] = None if error else states
            if error:
                failures.append(f'{port}: {error}')
    for s in workers:
        if s['root'] not in directories:
            continue
        successful = [observations[(p, s['root'])] for p in ports if observations[(p, s['root'])] is not None]
        explicit = [(p, observations[(p, s['root'])].get(s['id'])) for p in ports
                    if observations[(p, s['root'])] is not None and s['id'] in observations[(p, s['root'])]]
        active = [(p, v) for p, v in explicit if v.get('type') in ('busy', 'retry')]
        if active:
            s['state'] = active[0][1].get('type', 'unknown')
            s['endpoint'] = active[0][0]
        elif len(successful) == len(ports):
            s['state'] = 'idle'
        else:
            s['state'] = 'unknown'
        s['observedAt'] = time.time()
    result['status_coverage'] = {'roots_sampled': len(directories), 'ports': ports,
                                 'failure_count': len(failures), 'failure_examples': sorted(set(failures))[:4],
                                 'note': 'Only enrolled actors, selected and recent roots sampled. Unobserved is not idle; idle is not accepted.'}
    return result


if __name__ == '__main__':
    print(json.dumps(collect(CONFIG), ensure_ascii=True))
