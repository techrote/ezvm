"""DASH-02 T01..T05: public synthetic fixtures and owned-process boundaries."""
import asyncio
from concurrent.futures import Future
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import psutil
from ezvm_dashboard import adapters as a
from ezvm_dashboard.collectors import Collector, engine_sample, guest_sample, guest_payload, load_config, ssh_config_path
from ezvm_dashboard.guest_probe import collect
from ezvm_dashboard.model import Sample

METRICS = {}


def files(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob('*') if p.is_file()}


class Fixture:
    def __init__(self, root, count=12, registered=9):
        self.home = Path(root)
        self.workspace = self.home / 'workspace space 界'
        self.workspace.mkdir()
        self.dbpath = self.home / '.local/share/opencode/opencode.db'
        self.dbpath.parent.mkdir(parents=True)
        self.db = sqlite3.connect(self.dbpath)
        self.db.executescript('CREATE TABLE session(id TEXT PRIMARY KEY,title TEXT,directory TEXT,time_updated INTEGER); CREATE TABLE message(id TEXT PRIMARY KEY,session_id TEXT,data TEXT,time_created INTEGER); CREATE TABLE part(data TEXT,time_created INTEGER,session_id TEXT);')
        self.roots = []
        for i in range(count):
            directory = self.workspace / f'root-{i:04d}'
            directory.mkdir()
            self.roots.append(str(directory))
            self.db.execute('INSERT INTO session VALUES(?,?,?,?)', (f's{i:04d}', f'enrolled-{i}', str(directory), i))
        self.db.execute('INSERT INTO session VALUES(?,?,?,?)', ('outside', 'enrolled-outside', str(self.home), count + 1))
        self.db.execute('INSERT INTO message VALUES(?,?,?,?)', ('message', 's0000', json.dumps({'role': 'assistant', 'providerID': 'fixture', 'modelID': 'not-a-live-model', 'tokens': {'input': 10, 'output': 5}}), 1))
        self.db.commit()
        self.config = {'instance': 'fixture', 'workspace': str(self.workspace), 'ports': [4096, 4098],
                       'history_limit': 40, 'status_roots': 3, 'session_prefix': 'enrolled-',
                       '_vm_generation': 'g1', '_launch': 'launch1',
                       'registered_actors': [{'session': f's{i:04d}'} for i in range(registered)]}
        self.polls = []

    def close(self):
        self.db.close()

    @contextmanager
    def environment(self, responder=None):
        def response(base, path, timeout, opener=None):
            self.polls.append((base, path))
            return responder(base, path) if responder else {}
        with patch('ezvm_dashboard.guest_probe.Path.home', return_value=self.home), \
             patch('ezvm_dashboard.guest_probe._resources', return_value={'cpu_ticks': [1] * 8}), \
             patch('ezvm_dashboard.guest_probe._git_detail'), \
             patch('ezvm_dashboard.guest_probe.get_json', side_effect=response):
            yield

    def sample(self, responder=None):
        with self.environment(responder):
            result = collect(self.config)
        self.config['_poll_state'] = result['_poll_state']
        return result


class AdapterTests(unittest.TestCase):
    def test_t01_process_identity_requires_start_executable_and_arguments(self):
        runtime = {'pid': 42, 'processStartTimeUtc': '2026-10-16T12:00:00Z', 'qemuExecutable': str(Path('/fixture/qemu').absolute()),
                   'argumentFingerprint': a.argument_fingerprint(['-name', 'guest=ezvm-fixture']), 'launchId': 'launch1'}
        observed = {'pid': 42, 'started': datetime(2026, 10, 16, 12, tzinfo=timezone.utc).timestamp(),
                    'executable': runtime['qemuExecutable'], 'arguments': ['-name', 'guest=ezvm-fixture']}
        self.assertTrue(a.process_matches(runtime, observed))
        for field, value in [('pid', 43), ('started', observed['started'] + .1),
                             ('executable', str(Path('/other/qemu').absolute())), ('arguments', [])]:
            self.assertFalse(a.process_matches(runtime, dict(observed, **{field: value})))
        self.assertFalse(a.process_matches(dict(runtime, launchId=''), observed))

    def test_t01_argument_fingerprint_is_little_endian_length_prefixed_utf8(self):
        expected = hashlib.sha256(b'\x02\0\0\0\x01\0\0\0x\x03\0\0\0\xe7\x95\x8c').hexdigest()
        self.assertEqual(a.argument_fingerprint(['x', '界']), expected)

    def test_t01_partial_alias_failure_is_unknown_even_when_another_is_busy(self):
        self.assertEqual(a.reconcile_status('s', [{'s': {'type': 'busy'}}, None]), ('unknown', 'busy'))
        self.assertEqual(a.reconcile_status('s', [{}, None])[0], 'unknown')
        self.assertEqual(a.reconcile_status('s', [{}, {}])[0], 'idle')

    def test_t02_cursor_reserves_fair_service_under_selection_churn(self):
        for batch in (1, 2, 3, 8):
            roots = [f'r{i:02d}' for i in range(19)]
            cursor, seen = 0, set()
            for i in range(19):
                selected, cursor = a.poll_batch(roots, cursor, batch, [roots[(i * 3) % 19], roots[-1]])
                self.assertLessEqual(len(selected), batch)
                seen.update(selected)
            self.assertEqual(seen, set(roots))

    def test_t03_status_layout_refuses_unknown_and_malformed_versions(self):
        for value in ([], {'s': {'type': 'future'}}, {'s': []}, {'s': {'type': 'retry', 'attempt': True}}):
            with self.assertRaises(ValueError):
                a.status_map(value)
        a.status_map({'s': {'type': 'retry', 'attempt': 1, 'message': 'fixture', 'next': 10}})

    def test_t03_json_rejects_duplicates_nonfinite_and_oversize(self):
        for value in ('{"a":1,"a":2}', '{"a":NaN}', '{"a":1e999}', '[' * 49 + '0' + ']' * 49, ' ' * (a.MAX_BYTES + 1)):
            with self.assertRaises(ValueError):
                a.loads(value)

    def test_t03_read_response_never_accepts_truncated_valid_prefix(self):
        with self.assertRaises(ValueError):
            a.read_response(io.BytesIO(b'{}' + b' ' * 100), limit=32)
        self.assertEqual(a.read_response(io.BytesIO(b'{}'), limit=2), b'{}')
        with self.assertRaises(TimeoutError):
            a.read_response(io.BytesIO(b'{}'), deadline=time.monotonic() - 1)

    def test_t03_get_allowlist_is_read_only_no_proxy_no_redirect(self):
        for url in ('http://example.com:8000', 'http://user:pass@localhost:8000', 'http://localhost:80',
                    'http://localhost:8000/path', 'http://localhost:8000#fragment', 'http://localhost:99999'):
            with self.assertRaises(ValueError):
                a.endpoint(url)
        with patch('ezvm_dashboard.adapters.build_opener') as opener:
            with self.assertRaises(ValueError):
                a.get_json('http://localhost:8000', '/v1/chat/completions')
            opener.assert_not_called()
            opener.return_value.open.return_value = io.BytesIO(b'{}')
            a.get_json('http://localhost:8000', '/metrics')
            request = opener.return_value.open.call_args.args[0]
            self.assertEqual(request.method, 'GET')
            self.assertIsNone(request.data)
            self.assertTrue(request.full_url.startswith('http://127.0.0.1:8000'))
        with self.assertRaises(ValueError):
            a.NoRedirect().redirect_request(None, None, None, None, None, None)

    def test_t03_process_output_bound_terminates_only_owned_child(self):
        start = time.monotonic()
        with self.assertRaises(ValueError):
            a.run_read([sys.executable, '-c', 'import sys,time;sys.stdout.write("x"*200000);sys.stdout.flush();time.sleep(20)'], limit=1000, timeout=4)
        self.assertLess(time.monotonic() - start, 4)

    def test_t03_process_nonzero_exit_is_not_success(self):
        result = a.run_read([sys.executable, '-c', 'print("PASS");raise SystemExit(7)'])
        self.assertEqual(result.returncode, 7)
        self.assertIn('PASS', result.stdout)

    def test_t03_process_cancellation_has_independent_bound(self):
        cancelled = threading.Event()
        timer = threading.Timer(.15, cancelled.set)
        timer.start()
        start = time.monotonic()
        try:
            with self.assertRaises(TimeoutError):
                a.run_read([sys.executable, '-c', 'import time;time.sleep(20)'], timeout=10, cancel=cancelled)
        finally:
            timer.join()
        self.assertLess(time.monotonic() - start, 3)

    def test_t03_engine_schema_refusal_and_context_provenance(self):
        engine = {'id': 'fixture', 'kind': 'strata', 'url': 'http://127.0.0.1:8000'}
        with patch('ezvm_dashboard.collectors.get_json', return_value={'schemaVersion': 2}):
            with self.assertRaises(ValueError):
                engine_sample(engine)
        with patch('ezvm_dashboard.collectors.get_json', return_value={'engine': {'max_context': 123}, 'live': {}}):
            data = engine_sample(engine)
        self.assertEqual(data['context']['configured'], 123)
        self.assertIsNone(data['context']['effective'])
        self.assertIsNone(data['context']['requested'])
        self.assertFalse(data['adapter']['controlEligible'])

    def test_t04_import_must_belong_to_candidate_and_wrapper_is_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            candidate, other = root / 'candidate 界 space', root / 'other'
            candidate.mkdir(); other.mkdir()
            source = candidate / 'module.py'; source.write_text('# synthetic\n')
            foreign = other / 'module.py'; foreign.write_text('# synthetic\n')
            wrapper = root / 'python-wrapper'; wrapper.write_text('# synthetic file, never executed\n')
            row = {'candidate_root': str(candidate), 'restart_root': str(other), 'accepted_baseline': 'a' * 40,
                   'import_path': str(source), 'executable': str(wrapper)}
            result = a.source_assertions(root, row, candidate)
            self.assertEqual(result['assertion'], 'own-root-file')
            self.assertEqual(result['restart_root'], str(other.resolve()))
            self.assertEqual(result['executable'], str(wrapper.resolve()))
            with self.assertRaises(ValueError):
                a.source_assertions(root, dict(row, import_path=str(foreign)), candidate)
            with self.assertRaises(ValueError):
                a.source_assertions(root, dict(row, executable=str(other)), candidate)

    def test_t04_configuration_types_bounds_and_duplicates(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); path = root / 'config.json'
            bad = [{'schemaVersion': True}, {'schemaVersion': 1, 'instance': []},
                   {'schemaVersion': 1, 'ports': [4098, 4098]}, {'schemaVersion': 1, 'workspace': '/root/../other'},
                   {'schemaVersion': 1, 'policy_file': '..'}, {'schemaVersion': 1, 'registered_actors': [{'session': True}]},
                   {'schemaVersion': 1, 'registered_actors': [{'session': 's'}, {'session': 's'}]},
                   {'schemaVersion': 1, 'engines': [{'id': [], 'kind': 'strata', 'url': 'http://localhost:8000'}]}]
            for value in bad:
                path.write_text(json.dumps(value))
                with self.subTest(value=value), self.assertRaises(ValueError):
                    load_config(root, path)
            self.assertEqual(load_config(root)['registered_actors'], [])
            self.assertFalse((root / 'runtime').exists())

    def test_t03_missing_trust_has_no_process_or_key_creation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            access = {'sshPort': 22000, 'sshUser': 'coder'}
            with patch('ezvm_dashboard.collectors._guest_identity', return_value=(access, {}, {})), \
                 patch('ezvm_dashboard.collectors.run_read') as run:
                with self.assertRaisesRegex(ValueError, 'trust unavailable'):
                    guest_sample(root, {'instance': 'fixture'})
                run.assert_not_called()
            self.assertFalse((root / 'runtime').exists())

    def test_t04_reviewed_guest_stdin_payload_compiles_independent_modules(self):
        # Exercise the actual serialized payload in a separate interpreter. No SSH,
        # engine or host DB access: a nonexistent workspace must fail at its guard.
        with tempfile.TemporaryDirectory() as directory:
            workspace = str(Path(directory) / 'absent space 界')
            code = guest_payload({'workspace': workspace})
            compile(code, '<fixture-payload>', 'exec')
            result = a.run_read([sys.executable, '-B', '-'], input=code, timeout=4)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Enrolled workspace unavailable', result.stderr)
            self.assertNotIn('SyntaxError', result.stderr)
            self.assertNotIn('ImportError', result.stderr)

    def test_t04_git_worktree_filters_are_never_invoked(self):
        from ezvm_dashboard.guest_probe import _git_detail
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = {'detail': {'root': str(root)}}
            calls = []
            def run(argv, **kwargs):
                calls.append(argv)
                if 'config' in argv:
                    return types.SimpleNamespace(returncode=0, stdout='filter.fixture.clean\n')
                return types.SimpleNamespace(returncode=0, stdout='a' * 40)
            with patch('ezvm_dashboard.guest_probe.run_read', side_effect=run):
                _git_detail(result, root)
            self.assertEqual(len(calls), 2)
            self.assertFalse(any('status' in argv or 'diff' in argv for argv in calls))
            self.assertIn('unavailable', result['detail']['changes'])


    def test_t04_ssh_trust_path_quoting_and_no_global_trust_fallback(self):
        value = ssh_config_path('/fixture space 界/100%/known', expand_tokens=True)
        self.assertEqual(value, '"/fixture space 界/100%%/known"')
        for path in ('/fixture/${ENV}/known', '/fixture/line\nbreak'):
            with self.assertRaises(ValueError):
                ssh_config_path(path, expand_tokens=True)
        with tempfile.TemporaryDirectory(prefix='ezvm space ') as directory:
            root = Path(directory)
            keys = root / 'runtime/keys'; (keys / 'known-hosts').mkdir(parents=True)
            (keys / 'controller_ed25519').write_text('synthetic inert test file')
            (keys / 'known-hosts/fixture.known_hosts').write_text('synthetic inert test file')
            access = {'sshPort': 22000, 'sshUser': 'coder'}
            runtime = {'launchId': 'fixture', 'pid': 1, 'processStartTimeUtc': 'fixture', 'argumentFingerprint': 'fixture'}
            intent = {'identityGeneration': 'a' * 32, 'baseId': 'fixture'}
            before = files(root)
            with patch('ezvm_dashboard.collectors._guest_identity', return_value=(access, runtime, intent)), \
                 patch('ezvm_dashboard.collectors.run_read', return_value=types.SimpleNamespace(
                     returncode=0, stdout='{"schemaVersion":1,"workers":[]}', stderr='')) as run:
                guest_sample(root, {'instance': 'fixture'})
            argv = run.call_args.args[0]
            self.assertIn('UserKnownHostsFile=' + ssh_config_path(keys / 'known-hosts/fixture.known_hosts', True), argv)
            self.assertIn('GlobalKnownHostsFile=' + ssh_config_path('NUL' if os.name == 'nt' else '/dev/null'), argv)
            self.assertIn('StrictHostKeyChecking=yes', argv)
            self.assertIn('UpdateHostKeys=no', argv)
            self.assertNotIn('accept-new', ' '.join(argv))
            self.assertEqual(files(root), before)


    def test_t03_published_schema_samples_match_executable_contracts(self):
        document = json.loads((Path(__file__).resolve().parents[1] / 'fixtures/dash02/schemas.json').read_text())
        self.assertEqual(document['kind'], 'synthetic-schema-samples')
        for sample in document['opencodeStatus']['samples']:
            a.status_map(sample)
        for sample in document['opencodeStatus']['refused']:
            with self.assertRaises(ValueError):
                a.status_map(sample)
        for kind in ('strata', 'lmstudio'):
            with patch('ezvm_dashboard.collectors.get_json', return_value=document[kind]['sample']):
                self.assertFalse(engine_sample({'id': 'fixture', 'kind': kind, 'url': 'http://127.0.0.1:8000'})['adapter']['controlEligible'])
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(directory)
            try:
                with a.database_snapshot(fixture.dbpath) as db:
                    for table, columns in document['sqlite']['requiredColumns'].items():
                        captured = {row[1]: row[2] for row in db.execute(f'PRAGMA table_info({table})')}
                        self.assertTrue(all(captured[k] == v for k, v in columns.items()))
            finally:
                fixture.close()


    def test_t03_registered_actor_is_visible_before_first_failed_sample(self):
        collector = Collector(Path('.'), {'engines': [], 'registered_actors': [{'session': 'fixture'}]})
        try:
            snapshot = collector.snapshot()['guest'].data
            self.assertEqual(snapshot['workers'][0]['state'], 'unknown')
            self.assertEqual(snapshot['status_coverage']['overdue'], ['fixture'])
            future = Future(); future.set_exception(ValueError('Missing managed trust'))
            collector.pending['guest'] = future
            collector.jobs = {}
            collector.tick()
            snapshot = collector.snapshot()['guest']
            self.assertEqual(snapshot.data['status_coverage']['sampled'], 0)
            self.assertIn('trust', snapshot.error)
            self.assertFalse(snapshot.data['workers'][0]['controlEligible'])
        finally:
            collector.close()


    def test_t03_once_deadline_without_guest_result_is_not_success(self):
        from ezvm_dashboard import app
        source = types.SimpleNamespace(config={'instance': 'fixture'}, jobs={'guest': (8, None)},
            snapshot=lambda: {'guest': Sample()}, start=lambda: None, close=lambda: None)
        with patch('ezvm_dashboard.app.Collector', return_value=source), \
             patch('ezvm_dashboard.app.load_config', return_value={'instance': 'fixture'}), \
             patch('ezvm_dashboard.app.time.monotonic', side_effect=[0, 19]), \
             patch('ezvm_dashboard.app.sys.stdout', new_callable=io.StringIO):
            self.assertEqual(app.main(['--json']), 1)



class RegisteredGuestTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.fixture = Fixture(self.temp.name)

    def tearDown(self):
        self.fixture.close()
        self.temp.cleanup()

    def test_t01_alias_ports_do_not_duplicate_workers_or_usage(self):
        data = self.fixture.sample()
        self.assertEqual(len({w['id'] for w in data['workers']}), len(data['workers']))
        self.assertEqual(data['usage'][0]['input'], 10)
        self.assertTrue(all(w['controlEligible'] is False for w in data['workers']))

    def test_t02_old_registered_roots_outside_history_limit_rotate(self):
        self.fixture.config['history_limit'] = 1
        seen = set()
        for i in range(5):
            self.fixture.config['selected'] = f's{i:04d}'
            data = self.fixture.sample()
            seen.update(w['id'] for w in data['workers'] if w.get('ageSeconds') is not None)
        self.assertTrue({f's{i:04d}' for i in range(9)} <= seen)
        self.assertEqual(data['status_coverage']['registered'], 9)

    def test_t02_unregistered_history_never_polled_or_enrolled_by_selection(self):
        self.fixture.config['selected'] = 's0011'
        result = self.fixture.sample()
        row = next(w for w in result['workers'] if w['id'] == 's0011')
        self.assertEqual(row['state'], 'unobserved')
        self.assertEqual(row['registration'], 'historical-unregistered')
        self.assertNotIn('outside', {w['id'] for w in result['workers']})
        self.assertFalse(any('root-0011' in path for _, path in self.fixture.polls))

    def test_t01_new_launch_or_moved_root_invalidates_cached_identity(self):
        self.fixture.config['status_roots'] = 1
        first = self.fixture.sample()
        one = next(w for w in first['workers'] if w['id'] == 's0000')
        self.fixture.config['_launch'] = 'launch2'
        self.fixture.config['selected'] = 's0008'
        second = self.fixture.sample()
        two = next(w for w in second['workers'] if w['id'] == 's0000')
        self.assertNotEqual(one['identity'], two['identity'])
        self.db_update_root('s0000', self.fixture.roots[10])
        third = self.fixture.sample()
        three = next(w for w in third['workers'] if w['id'] == 's0000')
        self.assertNotEqual(two['identity'], three['identity'])

    def db_update_root(self, sid, root):
        self.fixture.db.execute('UPDATE session SET directory=? WHERE id=?', (root, sid))
        self.fixture.db.commit()

    def test_t03_failure_retains_last_good_timestamp_but_unknown_current_state(self):
        self.fixture.config['status_roots'] = 32
        first = self.fixture.sample(lambda base, path: {'s0000': {'type': 'busy'}})
        def failed(base, path):
            if ':4098' in base:
                raise TimeoutError('synthetic failed endpoint')
            return {}
        second = self.fixture.sample(failed)
        row = next(w for w in second['workers'] if w['id'] == 's0000')
        self.assertEqual(row['state'], 'unknown')
        self.assertEqual(row['lastKnownState'], 'busy')
        root = row['root']
        self.assertEqual(first['_poll_state']['roots'][root]['good'], second['_poll_state']['roots'][root]['good'])
        self.assertGreater(second['status_coverage']['failure_count'], 0)

    def test_t03_source_database_and_wal_unchanged(self):
        self.fixture.db.execute('PRAGMA journal_mode=WAL')
        self.fixture.db.execute('INSERT INTO message VALUES(?,?,?,?)', ('wal-message', 's0000', '{}', 2))
        self.fixture.db.commit()
        before = files(self.fixture.home)
        self.fixture.sample()
        self.assertEqual(before, files(self.fixture.home))

    def test_t03_schema_version_failure_preserves_source(self):
        self.fixture.db.execute('PRAGMA user_version=999'); self.fixture.db.commit()
        before = files(self.fixture.home)
        with self.assertRaisesRegex(ValueError, 'user_version'):
            self.fixture.sample()
        self.assertEqual(before, files(self.fixture.home))

    def test_t03_missing_schema_column_is_actionable_and_nonmutating(self):
        self.fixture.db.execute('ALTER TABLE message RENAME COLUMN data TO incompatible'); self.fixture.db.commit()
        before = files(self.fixture.home)
        with self.assertRaisesRegex(ValueError, 'DB layout: message'):
            self.fixture.sample()
        self.assertEqual(before, files(self.fixture.home))

    def test_t04_bad_registered_source_is_visibly_unknown(self):
        self.fixture.config['registered_actors'][0]['root'] = self.fixture.roots[1]
        result = self.fixture.sample()
        row = next(w for w in result['workers'] if w['id'] == 's0000')
        self.assertEqual(row['state'], 'unknown')
        self.assertIn('root differs', row['error'])
        self.assertIn('s0000', result['status_coverage']['overdue'])

    def test_t02_missing_actor_remains_visible_not_silently_unregistered(self):
        self.fixture.config['registered_actors'].append({'session': 'missing'})
        result = self.fixture.sample()
        row = next(w for w in result['workers'] if w['id'] == 'missing')
        self.assertEqual(row['state'], 'unknown')
        self.assertEqual(result['status_coverage']['registered'], 10)


class AggregationTests(unittest.TestCase):
    def test_t03_stale_last_good_is_retained_without_overlap(self):
        collector = Collector(Path('.'), {'engines': []})
        collector.jobs = {'x': (99, lambda: {})}
        collector.samples['x'] = Sample({'value': 7}, time.time(), time.time())
        future = Future(); collector.pending['x'] = future
        try:
            for _ in range(4):
                collector.tick()
            self.assertIs(collector.pending['x'], future)
            future.set_exception(TimeoutError('fixture timeout'))
            collector.tick()
            self.assertEqual(collector.snapshot()['x'].data, {'value': 7})
            self.assertIn('timeout', collector.snapshot()['x'].error)
        finally:
            collector.close()

    def test_t03_late_success_is_discarded_and_no_overlapping_retry(self):
        collector = Collector(Path('.'), {'engines': []})
        collector.jobs = {'x': (99, lambda: {})}
        collector.samples['x'] = Sample({'value': 7}, time.time(), time.time())
        future = Future(); collector.pending['x'] = future
        collector._started['x'] = time.monotonic() - 10
        try:
            collector.tick()
            self.assertIs(collector.pending['x'], future)
            future.set_result({'value': 99})
            collector.tick()
            self.assertEqual(collector.snapshot()['x'].data, {'value': 7})
            self.assertIn('Late', collector.snapshot()['x'].error)
        finally:
            collector.close()

    def test_t02_selection_churn_does_not_accelerate_polling(self):
        collector = Collector(Path('.'), {'engines': []})
        collector._attempt['guest'] = 123
        try:
            for i in range(100):
                collector.select(str(i))
            self.assertEqual(collector._attempt['guest'], 123)
        finally:
            collector.close()

    def test_t03_error_snapshot_invalidates_idle_without_rewriting_good_data(self):
        collector = Collector(Path('.'), {'engines': []})
        original = {'workers': [{'id': 's', 'state': 'idle', 'registration': 'registered', 'ageSeconds': 1}],
                    'status_coverage': {'cycle_bound_seconds': 48}}
        collector.samples['guest'] = Sample(original, time.time(), time.time(), 'read failed')
        try:
            self.assertEqual(collector.snapshot()['guest'].data['workers'][0]['state'], 'unknown')
            self.assertEqual(original['workers'][0]['state'], 'idle')
        finally:
            collector.close()


class StressTests(unittest.TestCase):
    def test_t05_thousand_session_stress_records_cost_and_coverage(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Fixture(directory, count=1100, registered=17)
            process = psutil.Process()
            rss = [process.memory_info().rss]
            stop = threading.Event()
            def memory():
                while not stop.wait(.01):
                    rss.append(process.memory_info().rss)
            monitor = threading.Thread(target=memory); monitor.start()
            started, cpu = time.monotonic(), time.process_time()
            max_age = 0
            try:
                for i in range(9):
                    fixture.config['selected'] = f's{i:04d}'
                    def delayed(base, path):
                        time.sleep(.01)
                        return {}
                    result = fixture.sample(delayed)
                    max_age = max(max_age, result['status_coverage']['oldest_age_seconds'] or 0)
                self.assertEqual(result['session_count'], 1100)
                self.assertEqual(result['status_coverage']['sampled'], 17)
                self.assertEqual(result['status_coverage']['overdue'], [])
                self.assertEqual(len(fixture.polls), 9 * 3 * 2)
                METRICS['T05'] = {'sessions': 1100, 'registered': 17, 'batch': 3, 'ports': 2,
                    'polls': len(fixture.polls), 'cycles': 9, 'wallSeconds': time.monotonic() - started,
                    'cpuSeconds': time.process_time() - cpu, 'peakSampledRssBytes': max(rss),
                    'maximumSourceAgeSeconds': max_age, 'declaredCycleBoundSeconds': result['status_coverage']['cycle_bound_seconds'],
                    'kind': 'synthetic-schema/delayed-GET-stub; not physical performance acceptance'}
                print('DASH02_T05=' + json.dumps(METRICS['T05'], sort_keys=True))
            finally:
                stop.set(); monitor.join(); fixture.close()



class ResponsivenessTests(unittest.TestCase):
    def test_t03_ten_second_stall_leaves_real_ui_input_and_other_sources_live(self):
        from prompt_toolkit.input import create_pipe_input
        from prompt_toolkit.output import DummyOutput
        from ezvm_dashboard.ui import make_application
        collector = Collector(Path('.'), {'engines': [], 'instance': 'synthetic'})
        calls = {'slow': 0, 'healthy': 0}
        entered = threading.Event()
        def slow():
            calls['slow'] += 1
            entered.set()
            time.sleep(10)
            raise TimeoutError('Synthetic ten-second source stall')
        def healthy():
            calls['healthy'] += 1
            return {'cpus': 1}
        collector.jobs = {'guest': (99, slow), 'host': (.05, healthy)}
        latencies = []
        started, cpu = time.monotonic(), time.process_time()
        collector.start()
        self.assertTrue(entered.wait(2))
        async def run():
            with create_pipe_input() as pipe:
                app, view = make_application(collector, input=pipe, output=DummyOutput())
                task = asyncio.create_task(app.run_async())
                try:
                    await asyncio.sleep(.15)
                    for i in range(20):
                        text = f'marker{i}'
                        mark = time.perf_counter()
                        pipe.send_text('\x06' + text)
                        while view.query != text:
                            self.assertLess(time.perf_counter() - mark, 2, 'Input dispatch stalled')
                            await asyncio.sleep(.002)
                        latencies.append(time.perf_counter() - mark)
                        await asyncio.sleep(.4)
                    while time.monotonic() - started < 10.2:
                        await asyncio.sleep(.05)
                finally:
                    pipe.send_text('\x11')
                    await asyncio.wait_for(task, 3)
        try:
            asyncio.run(run())
            self.assertEqual(calls['slow'], 1)
            self.assertGreater(calls['healthy'], 30)
            p95 = sorted(latencies)[18]
            self.assertGreater(p95, 0, 'Latency clock must resolve actual dispatch')
            self.assertLess(p95, .1, 'Required input-dispatch p95 <100ms')
            self.assertIn('stall', collector.snapshot()['guest'].error)
            METRICS['T03'] = {'stallSeconds': 10, 'slowCalls': calls['slow'], 'healthyPolls': calls['healthy'],
                'inputSamples': len(latencies), 'inputP95Seconds': p95, 'inputMaxSeconds': max(latencies),
                'inputClock': 'perf_counter', 'inputClockResolutionSeconds': time.get_clock_info('perf_counter').resolution,
                'wallSeconds': time.monotonic() - started, 'cpuSeconds': time.process_time() - cpu,
                'rssBytes': psutil.Process().memory_info().rss,
                'kind': 'real prompt_toolkit pipe dispatch/DummyOutput; not physical terminal paint'}
            print('DASH02_T03=' + json.dumps(METRICS['T03'], sort_keys=True))
        finally:
            collector.close()

    def test_t04_ui_exposes_coverage_and_separate_source_declarations(self):
        from ezvm_dashboard.ui import DashboardControl
        collector = Collector(Path('.'), {'engines': []})
        data = {'workers': [{'id': 's', 'title': 'fixture', 'state': 'unknown', 'registration': 'registered',
                            'source': {'candidate_root': '/candidate', 'restart_root': '/restart',
                                       'accepted_baseline': 'a'*40, 'import_path': '/candidate/module.py',
                                       'executable': '/wrapper', 'assertion': 'own-root-file'}}],
                'status_coverage': {'registered': 1, 'sampled': 0, 'overdue': ['s'], 'cycle_bound_seconds': 48},
                'detail': {'id': 's'}}
        collector.samples['guest'] = Sample(data, time.time())
        try:
            view = DashboardControl(collector)
            view.inventory_lines(collector.snapshot())
            text = '\n'.join(view.activity_lines(collector.snapshot()))
            for value in ('/candidate', '/restart', '/wrapper', 'Accepted baseline (declared)'):
                self.assertIn(value, text)
            footer = '\n'.join(''.join(t for _, t in row) for row in view.render(160, 48))
            self.assertIn('Registered 0/1', footer)
        finally:
            collector.close()

if __name__ == '__main__':
    unittest.main()
