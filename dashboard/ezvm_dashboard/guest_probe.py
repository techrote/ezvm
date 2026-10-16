"""Enrolled guest read sampler. Sent to python3 stdin, never installed in the guest.

Source DB/WAL bytes are read into a disposable snapshot before SQLite is opened.
Registration and rotating cursors are viewer-memory state, not worker control.
"""
from __future__ import annotations

import concurrent.futures
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import time
from urllib.parse import urlencode
from urllib.request import build_opener, ProxyHandler

from ezvm_dashboard.adapters import (MAX_ACTORS, MESSAGE_SCAN, SESSION_SCAN,
    NoRedirect, capability, database_snapshot, get_json, identity, loads,
    poll_batch, read_json, reconcile_status, require, run_read, scoped_path,
    source_assertions, status_map)


ACTOR_FIELDS = {'session', 'root', 'accepted_baseline', 'candidate_root',
                'restart_root', 'import_path', 'executable'}


def _resources(workspace):
    mem = {}
    for line in Path('/proc/meminfo').read_text().splitlines():
        key, value = line.split(':', 1)
        mem[key] = int(value.strip().split()[0]) * 1024
    disk = shutil.disk_usage(workspace)
    return {'cpus': os.cpu_count(), 'load': list(os.getloadavg()),
            'memory_total': mem['MemTotal'], 'memory_available': mem['MemAvailable'],
            'swap_used': mem['SwapTotal'] - mem['SwapFree'],
            'disk_total': disk.total, 'disk_free': disk.free,
            'cpu_ticks': [int(n) for n in Path('/proc/stat').read_text().splitlines()[0].split()[1:9]]}


def _session(row, workspace, prefix, origin, epoch):
    sid, title, directory, updated = row
    require(isinstance(sid, str) and 0 < len(sid) <= 256 and isinstance(title, str)
            and len(title) <= 4096 and isinstance(directory, str) and len(directory) <= 4096
            and type(updated) is int, 'Unsupported session row')
    if not title.startswith(prefix):
        return None
    try:
        root = scoped_path(workspace, directory, exists=False)
    except ValueError:
        return None
    return {'id': sid, 'title': title, 'root': str(root), 'updated': updated,
            'origin': origin, 'epoch': epoch, 'state': 'unobserved',
            'registration': 'historical-unregistered', 'controlEligible': False}


def _policy(workspace, config):
    path = workspace / config.get('policy_file', 'OWNER-MODEL-POLICY.json')
    require(path.parent.resolve() == workspace and path.resolve().parent == workspace,
            'Policy must remain a direct child of enrolled workspace')
    try:
        raw = read_json(path)
        require(isinstance(raw, dict) and isinstance(raw.get('actors', []), list), 'Unsupported policy layout')
        require(len(raw.get('actors', [])) <= MAX_ACTORS, 'Policy actor limit exceeded')
        return {'owner_paused': raw.get('owner_paused'), 'status': raw.get('status'),
                'actors': raw.get('actors', []), 'max_nvidia_workers': raw.get('max_nvidia_workers')}
    except FileNotFoundError:
        return {'owner_paused': None, 'actors': [], 'status': 'not configured / unavailable'}


def _usage(db, owned):
    groups, totals, last = {}, {}, {}
    scanned = 0
    # Backfill is bounded and labelled, never called an exhaustive lifetime total.
    for mid, sid, data in db.execute('SELECT id,session_id,substr(data,1,65537) FROM message ORDER BY time_created DESC,id DESC LIMIT ?', (MESSAGE_SCAN + 1,)):
        scanned += 1
        if scanned > MESSAGE_SCAN:
            break
        if sid not in owned:
            continue
        require(isinstance(data, str) and len(data) <= 65536, 'Message record exceeds read limit')
        info = loads(data)
        require(isinstance(info, dict), 'Unsupported message JSON layout')
        if info.get('role') != 'assistant':
            continue
        model, tokens = info.get('model') or {}, info.get('tokens') or {}
        require(isinstance(model, dict) and isinstance(tokens, dict), 'Unsupported message usage layout')
        cache = tokens.get('cache') or {}
        require(isinstance(cache, dict), 'Unsupported cache usage layout')
        provider = info.get('providerID') or model.get('providerID') or 'unknown'
        modelid = info.get('modelID') or model.get('modelID') or 'unknown'
        require(isinstance(provider, str) and isinstance(modelid, str), 'Unsupported provider/model identity')
        values = {'input': tokens.get('input'), 'cache_read': cache.get('read'),
                  'cache_write': cache.get('write'), 'output': tokens.get('output'),
                  'reasoning': tokens.get('reasoning'), 'reported_total': tokens.get('total')}
        for group in (groups.setdefault((provider, modelid), {'messages': 0, 'with_usage': 0}),
                      totals.setdefault(sid, {'messages': 0, 'with_usage': 0})):
            group['messages'] += 1
            usable = {k: v for k, v in values.items() if type(v) in (int, float) and math.isfinite(v) and v >= 0}
            group['with_usage'] += int(bool(usable))
            for key, value in usable.items():
                group[key] = group.get(key, 0) + value
                group[key + '_records'] = group.get(key + '_records', 0) + 1
        last.setdefault(sid, {'provider': provider, 'model': modelid, 'last_usage': values,
                            'finish': info.get('finish'), 'has_error': bool(info.get('error'))})
    return [dict(provider=k[0], model=k[1], **v) for k, v in sorted(groups.items())], totals, last, min(scanned, MESSAGE_SCAN), scanned > MESSAGE_SCAN


def _detail(db, worker):
    if not worker:
        return {}
    events = []
    for data, created in db.execute('SELECT substr(data,1,65537),time_created FROM part WHERE session_id=? ORDER BY time_created DESC LIMIT 45', (worker['id'],)):
        require(isinstance(data, str) and len(data) <= 65536, 'Part exceeds read limit')
        part = loads(data)
        require(isinstance(part, dict), 'Unsupported part layout')
        if part.get('type') == 'tool':
            state = part.get('state') or {}
            require(isinstance(state, dict), 'Unsupported tool state')
            metadata = state.get('metadata') or {}
            require(isinstance(metadata, dict), 'Unsupported tool metadata')
            events.append({'kind': 'tool', 'time': created, 'name': part.get('tool'),
                           'status': state.get('status'), 'title': str(state.get('title') or '')[:300],
                           'exit': metadata.get('exit'), 'output': str(state.get('output') or state.get('error') or '')[-5000:]})
        elif part.get('type') == 'text':
            events.append({'kind': 'text', 'time': created, 'text': str(part.get('text', ''))[-5000:]})
    return {'id': worker['id'], 'root': worker['root'], 'source': worker.get('source', {}),
            'events': list(reversed(events))}


def _git_detail(result, workspace):
    detail = result['detail']
    if not detail:
        return
    path = scoped_path(workspace, detail['root'])
    # Worktree refresh/diff may execute clean filters. Refuse those repositories
    # instead of silently invoking a configured external command during observation.
    env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
    env.update(GIT_OPTIONAL_LOCKS='0', GIT_TERMINAL_PROMPT='0', GIT_CONFIG_NOSYSTEM='1')
    argv = ['git', '--no-optional-locks', '-c', 'core.fsmonitor=false', '-C', str(path)]
    try:
        filters = run_read(argv + ['config', '--name-only', '--get-regexp', r'^filter\.'],
                           timeout=1, limit=12000, env=env)
        safe_worktree = filters.returncode == 1 and not filters.stdout
    except (OSError, ValueError, TimeoutError):
        safe_worktree = False
    for field, args in [('head', ['rev-parse', 'HEAD']), ('changes', ['status', '--short']),
                        ('diff_stat', ['diff', '--no-ext-diff', '--no-textconv', '--stat'])]:
        if field != 'head' and not safe_worktree:
            detail[field] = '(unavailable: configured filters or unverified Git configuration)'
            continue
        try:
            process = run_read(argv + args, timeout=1, limit=12000, env=env)
            detail[field] = process.stdout.strip() if process.returncode == 0 else '(unavailable)'
        except (OSError, ValueError, TimeoutError):
            detail[field] = '(unavailable / bounded read failed)'


def _poll(config, result, workers, registrations, cache_key):
    now = time.monotonic()
    old = config.get('_poll_state') or {}
    if old.get('key') != cache_key:
        old = {}
    roots = {w['root'] for w in workers if w['registration'] == 'registered' and not w.get('error')}
    cache = {root: row for root, row in old.get('roots', {}).items() if root in roots}
    priority = [w['root'] for w in workers if w['id'] == config.get('selected')]
    priority += [root for root, row in cache.items() if row.get('active')]
    batch = config.get('status_roots', 8)
    chosen, cursor = poll_batch(roots, old.get('cursor', 0), batch, priority)
    ports = config.get('ports', [4098])
    def request(pair):
        port, root = pair
        try:
            data = get_json(f'http://127.0.0.1:{port}', '/session/status?' + urlencode({'directory': root}),
                            timeout=.75, opener=build_opener(ProxyHandler({}), NoRedirect()))
            return root, port, status_map(data), None
        except Exception as exc:
            return root, port, None, type(exc).__name__ + ': ' + str(exc)[:180]
    observed = {}
    # A maximum of eight bounded GETs run concurrently. Host enforces a separate
    # total guest-process budget and can cancel only its own SSH child.
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        for root, port, data, error in pool.map(request, [(p, r) for r in chosen for p in ports]):
            observed.setdefault(root, {})[port] = (data, error)
    failures = []
    for root in chosen:
        prior = cache.get(root, {})
        views = [observed[root][p][0] for p in ports]
        errors = [observed[root][p][1] for p in ports if observed[root][p][1]]
        if errors:
            failures.extend(errors)
        cache[root] = {'attempted': now, 'good': prior.get('good'),
                       'states': prior.get('states', {}), 'active': prior.get('active', False),
                       'error': '; '.join(errors)[:600]}
        if not errors:
            states = {w['id']: reconcile_status(w['id'], views)[0] for w in workers if w['root'] == root}
            cache[root].update(good=time.monotonic(), states=states,
                               active=any(v in ('busy', 'retry') for v in states.values()))
    # Forty seconds for the host's independent guest deadline, plus eight seconds
    # between attempts. The UI marks overdue rather than promising a stalled slot.
    reserved = max(1, batch - 1) if len(roots) > batch else max(1, batch)
    cycle = math.ceil(len(roots) / reserved) * 48 if roots else 0
    end = time.monotonic()
    ages, overdue, sampled = [], [], 0
    for worker in workers:
        if worker['registration'] != 'registered':
            continue
        row = cache.get(worker['root'], {})
        age = max(0, end - row['good']) if row.get('good') is not None else None
        if age is not None:
            ages.append(age)
            sampled += 1
        invalid = bool(worker.get('error')) or row.get('error') or age is None or age > cycle
        worker.update(state='unknown' if invalid else row.get('states', {}).get(worker['id'], 'unknown'),
                      lastKnownState=row.get('states', {}).get(worker['id'], 'unobserved'),
                      ageSeconds=age, error=worker.get('error') or row.get('error'),
                      observedAt=time.time() - age if age is not None else None)
        if invalid:
            overdue.append(worker['id'])
    result['status_coverage'] = {'registered': len(registrations), 'sampled': sampled,
        'registered_roots': len(roots), 'roots_sampled': len(chosen), 'ports': ports,
        'cycle_bound_seconds': cycle, 'oldest_age_seconds': max(ages) if ages else None,
        'overdue': overdue, 'failure_count': len(failures), 'failure_examples': sorted(set(failures))[:4],
        'polls': len(chosen) * len(ports), 'concurrency_limit': 8,
        'historical_unregistered': sum(w['registration'] != 'registered' for w in workers),
        'note': 'Registered roots rotate; historical-unregistered is unobserved. No admission authority.'}
    result['_poll_state'] = {'key': cache_key, 'cursor': cursor, 'roots': cache}


def collect(config):
    workspace = Path(config['workspace']).resolve()
    require(workspace.is_dir(), 'Enrolled workspace unavailable')
    result = {'schemaVersion': 1, 'observedAt': time.time(), 'workspace': str(workspace),
              'errors': [], 'controlEligible': False}
    result['resources'] = _resources(workspace)
    result['policy'] = _policy(workspace, config)
    raw_actors = list(config.get('registered_actors', [])) + result['policy']['actors']
    require(len(raw_actors) <= MAX_ACTORS, 'Combined registration limit exceeded')
    registrations = {}
    for actor in raw_actors:
        require(isinstance(actor, dict) and isinstance(actor.get('session'), str)
                and 0 < len(actor['session']) <= 256, 'Registered actor requires a session ID')
        declaration = {k: v for k, v in actor.items() if k in ACTOR_FIELDS}
        sid = actor['session']
        require(sid not in registrations or registrations[sid] == declaration, 'Conflicting actor registration')
        registrations[sid] = declaration
    dbpath = Path.home() / '.local/share/opencode/opencode.db'
    stat = dbpath.stat()
    origin = config.get('origin_id') or config['instance'] + ':opencode-db'
    epoch = identity(config.get('_vm_generation'), config.get('origin_epoch', 'declared-default'),
                     stat.st_dev, stat.st_ino, getattr(stat, 'st_birthtime_ns', None))
    result['adapter'] = capability('opencode-sqlite', origin, 'user_version=0;session-message-part-v1', 'stable-file-set/disposable-query-only')
    result['status_adapter'] = capability('opencode-status', origin, 'idle-busy-retry-v1', 'allowlisted-GET')
    prefix = config.get('session_prefix', '')
    with database_snapshot(dbpath) as db:
        sessions = []
        scanned = 0
        for raw in db.execute('SELECT id,title,directory,time_updated FROM session ORDER BY time_updated DESC,id DESC LIMIT ?', (SESSION_SCAN + 1,)):
            scanned += 1
            if scanned > SESSION_SCAN:
                break
            row = _session(raw, workspace, prefix, origin, epoch)
            if row:
                sessions.append(row)
        owned = {w['id']: w for w in sessions}
        for sid, declaration in registrations.items():
            raw = db.execute('SELECT id,title,directory,time_updated FROM session WHERE id=?', (sid,)).fetchone()
            worker = _session(raw, workspace, prefix, origin, epoch) if raw else None
            if worker is None:
                worker = {'id': sid, 'title': sid, 'root': '', 'origin': origin, 'epoch': epoch,
                          'state': 'unknown', 'error': 'Registered session missing or outside enrolled scope',
                          'controlEligible': False}
            else:
                try:
                    if declaration.get('root'):
                        require(scoped_path(workspace, declaration['root']) == Path(worker['root']),
                                'Registered root differs from observed session root')
                    worker['source'] = source_assertions(workspace, declaration, worker['root'])
                except (OSError, ValueError) as exc:
                    worker['error'] = str(exc)
            worker['registration'] = 'registered'
            worker['identity'] = identity(origin, epoch, sid, worker['root'], config.get('_launch'))
            owned[sid] = worker
        workers = [owned[w['id']] for w in sessions[:config.get('history_limit', 40)]]
        for sid in [*registrations, config.get('selected')]:
            if sid in owned and not any(w['id'] == sid for w in workers):
                workers.append(owned[sid])
        usage, totals, last, messages_scanned, truncated = _usage(db, owned)
        for worker in workers:
            worker.update(last.get(worker['id'], {}))
            worker['usage'] = totals.get(worker['id'], {})
        result.update(workers=workers, usage=usage, session_count=len(sessions),
                      history_scan={'session_rows': min(scanned, SESSION_SCAN), 'session_limit': SESSION_SCAN,
                                    'sessions_truncated': scanned > SESSION_SCAN,
                                    'message_rows': messages_scanned, 'message_limit': MESSAGE_SCAN,
                                    'messages_truncated': truncated})
        selected = owned.get(config.get('selected')) or (workers[0] if workers else None)
        result['detail'] = _detail(db, selected if selected and selected.get('root') else None)
    try:
        _git_detail(result, workspace)
    except (OSError, ValueError) as exc:
        result['errors'].append('Git/source observation unavailable: ' + str(exc)[:200])
    cache_key = identity(origin, epoch, config.get('_launch'), sorted((s, owned[s]['root']) for s in registrations), config.get('ports'))
    _poll(config, result, workers, registrations, cache_key)
    coverage = result['status_coverage']
    result['errors'] += [w['error'] for w in workers if w.get('error')][:8]
    result['coverage_note'] = (f"Registered {coverage['sampled']}/{coverage['registered']} sampled; "
        f"overdue/unavailable {len(coverage['overdue'])}; cycle <= {coverage['cycle_bound_seconds']}s; "
        f"oldest {coverage['oldest_age_seconds']}; {coverage['polls']} GETs this batch")
    result['usage_note'] = 'Bounded OpenCode snapshot; read history_scan limits/truncation. Ports never summed; usage is not billing or admission.'
    return result


if __name__ == '__main__':
    print(json.dumps(collect(CONFIG), ensure_ascii=True, allow_nan=False))
