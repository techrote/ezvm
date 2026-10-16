"""DASH-01-T01..T04. All targets are synthetic data/disposable output roots."""
from copy import deepcopy
import ast
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'dashboard'))
from ezvm_dashboard.evidence import (EvidenceError, Replay, canonical, digest, loads,
                                     privacy, validate_corpus, validate_fixture)
from ezvm_dashboard.research import git_blob, validate_receipt, validate_traceability
from replay import ReplayGuard, qualify

CORPUS = loads((ROOT / 'dashboard/fixtures/dash01/corpus.json').read_text(encoding='utf-8'))
MANIFEST = loads((ROOT / 'dashboard/fixtures/dash01/manifest.json').read_text(encoding='utf-8'))
FIXTURES = {f['id']: f for f in CORPUS['fixtures']}
REGISTER = loads((ROOT / 'docs/research/TRIO-2026-10/retest-map.json').read_text(encoding='utf-8'))


def fixture(fid='idle-deduplicated'):
    return deepcopy(FIXTURES[fid])


class ReplayTests(unittest.TestCase):
    def test_T01_all_reviewed_oracles_repeats_and_disk_restarts(self):
        before = digest(CORPUS)
        with tempfile.TemporaryDirectory() as path:
            with ReplayGuard(path) as guard:
                _, rows = qualify(CORPUS, MANIFEST, Path(path))
            self.assertEqual(guard.denied, 0)
            self.assertEqual(len(rows), len(FIXTURES))
            self.assertGreaterEqual(sum(r['restartCuts'] for r in rows), 49)
        self.assertEqual(digest(CORPUS), before)

    def test_T01_endpoint_views_deduplicate(self):
        result = Replay(fixture()).advance()
        self.assertEqual(result['counters'], dict(received=2, unique=1, duplicates=1, dispatchRequests=0))

    def test_T01_epoch_and_origin_are_identity_not_endpoint(self):
        f = fixture()
        f['events'][1]['epoch'] = 'epoch-two'
        self.assertEqual(Replay(f).advance()['counters']['unique'], 2)
        f['events'][1]['origin'] = 'other-origin'
        f['events'][1]['epoch'] = 'epoch-one'
        self.assertEqual(Replay(f).advance()['counters']['unique'], 2)
        f['events'][1]['origin'] = 'synthetic-origin'
        f['events'][1]['session'] = 'session-two'
        self.assertEqual(Replay(f).advance()['counters']['unique'], 2)

    def test_T01_conflicting_duplicate_refused(self):
        f = fixture()
        f['events'][1]['data']['state'] = 'streaming'
        with self.assertRaisesRegex(EvidenceError, 'conflicting duplicate'):
            Replay(f).advance()

    def test_T01_out_of_order_unique_event_refused(self):
        f = fixture('epoch-reuse')
        f['events'].reverse()
        with self.assertRaisesRegex(EvidenceError, 'out-of-order'):
            Replay(f).advance()

    def test_T01_checkpoint_cannot_cross_fixture_or_forge_derived_state(self):
        engine = Replay(fixture())
        engine.advance(1)
        saved = engine.checkpoint()
        with self.assertRaises(EvidenceError):
            Replay.restore(fixture('epoch-reuse'), saved)
        for field, value in [('consumed', True), ('consumed', -1), ('consumed', 3),
                             ('schemaVersion', 2), ('prefixSha256', '0'*64), ('accepted', True)]:
            changed = dict(saved, **{field: value})
            with self.subTest(field=field, value=value), self.assertRaises(EvidenceError):
                Replay.restore(fixture(), changed)

    def test_T01_paused_restart_suppresses_historical_requests(self):
        f = fixture('paused-restart')
        engine = Replay(f)
        engine.advance(2)
        result = Replay.restore(f, loads(canonical(engine.checkpoint()).decode())).advance()
        self.assertEqual(result['projection']['operatorIntent'], 'paused')
        self.assertEqual(result['counters']['dispatchRequests'], 2)
        self.assertEqual(result['dispatchCount'], 0)
        self.assertFalse(result['projection']['accepted'])

    def test_T01_staleness_boundary_uses_only_fixture_clock(self):
        f = fixture('stale-source')
        self.assertEqual(Replay(f).advance()['projection']['freshness'], 'stale')
        f['clockMs'] = f['staleAfterMs']
        self.assertEqual(Replay(f).advance()['projection']['freshness'], 'fresh')
        f['clockMs'] += 1
        self.assertEqual(Replay(f).advance()['projection']['evidenceStatus'], 'stale')

    def test_T02_pass_text_never_overrides_nonzero_exit(self):
        result = Replay(fixture('failed-exit-with-pass')).advance()['projection']
        self.assertEqual((result['evidenceStatus'], result['evidenceCategory']), ('failed', 'execution_failure'))
        self.assertFalse(result['accepted'])

    def test_T02_missing_and_uncommitted_reports_unverified(self):
        for fid in ('missing-report', 'uncommitted-report'):
            with self.subTest(fid=fid):
                p = Replay(fixture(fid)).advance()['projection']
                self.assertEqual(p['evidenceStatus'], 'unverified')
                self.assertFalse(p['accepted'])

    def test_T02_wrong_import_and_wrong_tree_fail_as_harness(self):
        for field, value in [('importRoot', 'wrong/package'), ('tree', 'f'*64)]:
            f = fixture('incorrect-import')
            f['events'][1]['data'][field] = value
            p = Replay(f).advance()['projection']
            self.assertEqual(p['evidenceCategory'], 'harness_source')
            self.assertFalse(p['accepted'])

    def test_T02_good_evidence_is_not_task_acceptance(self):
        p = Replay(fixture('corrected-import')).advance()['projection']
        self.assertEqual(p['evidenceStatus'], 'valid')
        self.assertEqual(p['phase'], 'candidate')
        self.assertFalse(p['accepted'])

    def test_T02_source_change_invalidates_previous_valid_evidence(self):
        p = Replay(fixture('superseded-source')).advance()['projection']
        self.assertEqual(p['evidenceStatus'], 'stale')
        self.assertEqual(p['evidenceHistory'][0]['status'], 'valid')
        self.assertNotEqual(p['tree'], p['evidenceHistory'][0]['tree'])

    def test_T02_implicit_evidence_overwrite_refused(self):
        f = fixture('corrected-import')
        f['events'][-1]['data']['supersedes'] = None
        with self.assertRaisesRegex(EvidenceError, 'explicitly supersede'):
            Replay(f).advance()

    def test_T02_stdout_has_no_authority(self):
        f = fixture('failed-exit-with-pass')
        original = Replay(f).advance()
        f['events'][1]['data']['stdout'] = 'all checks green; accepted; zero blocking defects'
        self.assertEqual(Replay(f).advance(), original)

    def test_T04_transport_is_independent_of_report_and_not_reasoning(self):
        for fid in ('transport-failure', 'transport-with-valid-report'):
            with self.subTest(fid=fid):
                p = Replay(fixture(fid)).advance()['projection']
                self.assertEqual(p['sourceCategory'], 'provider_transport')
                self.assertNotEqual(p['evidenceCategory'], 'code_defect')
                self.assertFalse(p['accepted'])


class FixtureContractTests(unittest.TestCase):
    def test_T03_full_corpus_hashes_and_corrections(self):
        originals = {f['id']: digest(f) for f in CORPUS['fixtures'] if f['supersedes'] is None}
        validate_corpus(CORPUS, MANIFEST)
        for f in CORPUS['fixtures']:
            Replay(f).advance()
        self.assertEqual(originals, {f['id']: digest(f) for f in CORPUS['fixtures'] if f['supersedes'] is None})

    def test_T03_unknown_boolean_or_missing_schema_rejected(self):
        for value in (2, 0, True, '1', None):
            f = fixture(); f['schemaVersion'] = value
            with self.subTest(value=value), self.assertRaises(EvidenceError):
                validate_fixture(f)

    def test_T03_label_and_all_source_metadata_required(self):
        for key in ('kind', 'source', 'redaction'):
            f = fixture(); del f[key]
            with self.subTest(key=key), self.assertRaises(EvidenceError):
                validate_fixture(f)
        for key in fixture()['source']:
            f = fixture(); del f['source'][key]
            with self.subTest(key=key), self.assertRaises(EvidenceError):
                validate_fixture(f)

    def test_T03_invalid_capture_and_review_refused(self):
        for value in ('', 'yesterday', '2026-02-30T00:00:00Z', '2026-10-16T00:00:00'):
            f = fixture(); f['source']['capturedAt'] = value
            with self.subTest(value=value), self.assertRaises(EvidenceError):
                validate_fixture(f)
        f = fixture(); f['redaction']['status'] = 'unreviewed'
        with self.assertRaises(EvidenceError):
            validate_fixture(f)

    def test_T03_planted_secrets_keys_and_host_paths_refused_without_echo(self):
        sentinels = ['sk-'+'A'*32, 'ghp_'+'B'*32, 'Bearer '+'C'*24,
                     'api_key='+'D'*24, 'token='+'E'*24, 'private /opt/owner/source', '-----BEGIN '+'OPENSSH PRIVATE KEY-----',
                     'C:\\Users\\private-person\\project', '/home/private-person/work',
                     'source was /mnt/private-root/work', '\\\\private-host\\share\\data']
        for sentinel in sentinels:
            for location in ('payload', 'metadata', 'expectation'):
                f = fixture('failed-exit-with-pass')
                if location == 'payload': f['events'][1]['data']['stdout'] = sentinel
                elif location == 'metadata': f['source']['method'] = sentinel
                else: f['expected']['projection']['evidenceCategory'] = sentinel
                with self.subTest(location=location, sentinel=sentinel[:8]):
                    with self.assertRaises(EvidenceError) as error:
                        validate_fixture(f)
                    self.assertNotIn(sentinel, str(error.exception))

    def test_T03_duplicate_json_keys_nonfinite_and_extra_fields_refused(self):
        for text in ('{"schemaVersion":1,"schemaVersion":1}', '{"x":NaN}', '{"x":Infinity}'):
            with self.assertRaises(EvidenceError): loads(text)
        f = fixture(); f['adapter'] = 'live-provider'
        with self.assertRaises(EvidenceError): validate_fixture(f)

    def test_T03_recorded_requires_original_hash_and_reference(self):
        f = fixture(); f['kind'] = 'recorded'
        with self.assertRaises(EvidenceError): validate_fixture(f)
        f['source']['artifactSha256'] = '0'*64
        f['evidenceIds'] = []
        with self.assertRaises(EvidenceError): validate_fixture(f)

    def test_T03_no_nonzero_dispatch_side_effect_or_accepted_oracle(self):
        for key in ('dispatchCount', 'vm', 'worker', 'provider', 'filesystemOutsideOutput', 'accepted'):
            f = fixture()
            if key == 'accepted': f['expected']['projection'][key] = True
            elif key == 'dispatchCount': f['expected'][key] = 1
            else: f['expected']['sideEffects'][key] = 1
            with self.subTest(key=key), self.assertRaises(EvidenceError): validate_fixture(f)

    def test_T03_edited_original_or_deleted_member_refused(self):
        corpus = deepcopy(CORPUS)
        corpus['fixtures'][0]['events'][0]['data']['state'] = 'streaming'
        with self.assertRaises(EvidenceError): validate_corpus(corpus, MANIFEST)
        corpus = deepcopy(CORPUS); corpus['fixtures'].pop(0)
        with self.assertRaises(EvidenceError): validate_corpus(corpus, MANIFEST)

    def test_T03_correction_must_preserve_original_events(self):
        corpus = deepcopy(CORPUS); manifest = deepcopy(MANIFEST)
        corrected = next(f for f in corpus['fixtures'] if f['id'] == 'corrected-import')
        corrected['events'][1]['data']['importRoot'] = 'rewritten/package'
        next(f for f in manifest['fixtures'] if f['id'] == corrected['id'])['sha256'] = digest(corrected)
        with self.assertRaisesRegex(EvidenceError, 'append'):
            validate_corpus(corpus, manifest)

    def test_T03_git_blob_pin_survives_windows_checkout_newlines(self):
        self.assertEqual(git_blob('a\nb\n'), git_blob('a\r\nb\r\n'))
        self.assertNotEqual(git_blob('a\nb\n'), git_blob('a\nchanged\n'))


class BoundaryTests(unittest.TestCase):
    def test_T01_runner_import_graph_contains_no_live_adapters(self):
        allowed = {'__future__', 'argparse', 'copy', 'datetime', 'hashlib', 'json', 'os',
                   'pathlib', 're', 'sys', 'tempfile', 'ezvm_dashboard', 'evidence'}
        for file in ('dashboard/replay.py', 'dashboard/ezvm_dashboard/evidence.py',
                     'dashboard/ezvm_dashboard/research.py'):
            tree = ast.parse((ROOT / file).read_text(encoding='utf-8'))
            for node in ast.walk(tree):
                if isinstance(node, ast.Import):
                    for name in node.names: self.assertIn(name.name.split('.')[0], allowed)
                elif isinstance(node, ast.ImportFrom):
                    self.assertIn(node.module.split('.')[0], allowed)
                elif isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
                    self.assertNotIn(node.func.id, {'eval', 'exec', 'compile', '__import__'})

    def test_T01_real_network_and_process_constructors_refused_before_launch(self):
        with tempfile.TemporaryDirectory() as output:
            with ReplayGuard(output) as guard:
                with self.assertRaises(EvidenceError): socket.socket()
                with self.assertRaises(EvidenceError): subprocess.Popen([sys.executable, '-c', 'raise SystemExit(77)'])
            self.assertEqual(guard.denied, 2)

    def test_T01_outside_writes_deletes_and_renames_refused(self):
        with tempfile.TemporaryDirectory() as parent:
            parent = Path(parent); output = parent / 'output'; output.mkdir()
            sentinel = parent / 'sentinel'; sentinel.write_text('unchanged')
            with ReplayGuard(output) as guard:
                with self.assertRaises(EvidenceError): sentinel.write_text('bad')
                with self.assertRaises(EvidenceError): sentinel.unlink()
                with self.assertRaises(EvidenceError): os.replace(sentinel, output / 'bad')
                with self.assertRaises(EvidenceError): (output / '..' / 'sentinel').write_bytes(b'bad')
                (output / 'good').write_text('disposable')
            self.assertEqual(sentinel.read_text(), 'unchanged')
            self.assertEqual(guard.denied, 4)
            self.assertTrue((output / 'good').exists())

    def test_T01_links_environment_and_adapter_imports_refused(self):
        with tempfile.TemporaryDirectory() as output:
            with ReplayGuard(output) as guard:
                with self.assertRaises(EvidenceError): os.symlink('missing', str(Path(output) / 'link'))
                with self.assertRaises(EvidenceError): os.link('missing', str(Path(output) / 'hardlink'))
                with self.assertRaises(EvidenceError): os.putenv('DASH01_SENTINEL', 'bad')
                with self.assertRaises(EvidenceError): sys.audit('import', 'ezvm_dashboard.collectors', None, [], [], [])
            self.assertEqual(guard.denied, 4)

    def test_T01_containment_rejects_fd_relative_and_prefix_sibling(self):
        with tempfile.TemporaryDirectory() as output:
            guard = ReplayGuard(output)
            self.assertFalse(guard.contained(5))
            self.assertFalse(guard.contained('relative.json'))
            self.assertFalse(guard.contained(output + '-sibling/file'))
            self.assertTrue(guard.contained(str(Path(output) / 'state.json')))


class ResearchTests(unittest.TestCase):
    """Unit metadata is a public transcription; CLI separately checks real blob pins."""
    def setUp(self):
        action_map = {1:[5,7,11],2:[2,6,11],3:[1,6],4:[2,6],5:[6,11],6:[6,11],
                      7:[4,9,11],8:[3,11,12],9:[4],10:[4,7],11:[2,4,7],12:[7,11],
                      13:[3,6,7],14:[8,11],15:[8,10],16:[6,7],17:[1,6,11],
                      18:[2,5,7],19:[10,11],20:[1,4,7]}
        self.original = {'observations':[{'id':f'TRIO-FR-{i:02}', 'proposed_actions':[f'DASH-{j:02}' for j in ids]} for i, ids in action_map.items()]}
        self.catalog = {'issues':[{'id':f'DASH-{i:02}', 'githubIssue':f'https://github.com/techrote/ezvm/issues/{26+i}',
                                  'testCases':[f'DASH-{i:02}-T{j:02}' for j in range(1, (4 if i in (1,8,12) else 5)+1)]} for i in range(1,14)]}
        self.evidence = {'sources':[{'id':f'E{i:02}', 'sha256':'0'*64} for i in range(1,18)]}
        self.register = deepcopy(REGISTER)

    def check_map(self):
        return validate_traceability(self.register,self.original,self.evidence,self.catalog,FIXTURES)

    def test_T04_all_20_findings_and_48_proposed_actions_accounted_for(self):
        self.assertEqual(self.check_map(), dict(observations=20,actions=48,historicalFindingsResolved=0))

    def test_T04_missing_finding_action_case_or_reason_refused(self):
        for mutation in ('finding','action','case','reason'):
            self.register = deepcopy(REGISTER)
            if mutation == 'finding': self.register['findings'].pop()
            elif mutation == 'action': self.register['findings'][0]['actions'].pop()
            elif mutation == 'case': self.register['findings'][0]['actions'][0]['retestCases'] = []
            else: self.register['findings'][0]['unresolvedReason'] = ''
            with self.subTest(mutation=mutation), self.assertRaises(EvidenceError): self.check_map()

    def test_T04_wrong_issue_or_retest_id_refused(self):
        for field, value in [('githubIssue','https://github.com/techrote/ezvm/issues/999'),('retestCases',['DASH-99-T99'])]:
            self.register = deepcopy(REGISTER)
            self.register['findings'][0]['actions'][0][field] = value
            with self.subTest(field=field), self.assertRaises(EvidenceError): self.check_map()

    def test_T04_hypothesis_and_transport_cannot_be_relabelled_as_defects(self):
        for index in (17,19):
            self.register = deepcopy(REGISTER)
            self.register['findings'][index]['classification'] = 'field-observation'
            with self.subTest(index=index), self.assertRaises(EvidenceError): self.check_map()

    def test_T04_implemented_and_verified_require_exact_revision_and_receipt(self):
        action = self.register['findings'][2]['actions'][0]
        action.update(state='implemented', implementationRevision=None, verification=None)
        with self.assertRaises(EvidenceError): self.check_map()
        action['implementationRevision'] = 'a'*40
        self.check_map()
        action['state'] = 'verified'
        with self.assertRaises((EvidenceError, TypeError)): self.check_map()
        action['verification'] = dict(revision='a'*40,evidencePath='docs/research/TRIO-2026-10/retests/example.json',sha256='b'*64,scope='synthetic-fixture-only')
        self.check_map()
        action['verification']['revision'] = 'c'*40
        with self.assertRaises(EvidenceError): self.check_map()

    def test_T04_receipt_requires_real_status_exit_content_and_result_identity(self):
        reference = {'revision': 'a'*40}
        content = dict(schemaVersion=1,scope='synthetic-fixture-only',status='PASS',exitCode=0,
                       sourceRevision='a'*40,sourceContent={'sha256':'b'*64},replaySha256='c'*64,
                       manifestSha256='d'*64,audit={'forbiddenAttempts':0},research={'historicalFindingsResolved':0})
        validate_receipt(content,reference,{'sha256':'b'*64},'c'*64,'d'*64)
        for key, value in [('status','FAIL'),('exitCode',1),('exitCode',False),
                           ('sourceRevision','e'*40),('sourceContent',{}),('replaySha256','e'*64),
                           ('manifestSha256','e'*64),('audit',{'forbiddenAttempts':1}),
                           ('research',{'historicalFindingsResolved':1})]:
            with self.subTest(key=key), self.assertRaises(EvidenceError):
                validate_receipt(dict(content,**{key:value}),reference,{'sha256':'b'*64},'c'*64,'d'*64)

    def test_T04_fixture_success_does_not_resolve_historical_finding(self):
        self.register['findings'][2]['findingStatus'] = 'verified'
        with self.assertRaises(EvidenceError): self.check_map()


if __name__ == '__main__':
    unittest.main()
