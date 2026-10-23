"""Offline controls for diagnostic-only stage execution; no VM or credentials."""
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import sys
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("venv_stages", ROOT / "scripts/diagnostics/venv-stages.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class StageTests(unittest.TestCase):
    def test_record_oracle_rejects_partial_replayed_and_false_success(self):
        records = [dict(kind='identity', cpus=6, bootstrapSha256='a'*64,
                        ensurepipSha256='b'*64, wheelSha256=['c'*64],python='3.12.3',attemptId='d'*32,buildId='e'*32)]
        def validate(value):
            return module.validate_records(value,'d'*32,'e'*32,'a'*64)
        for sequence, variant in enumerate(module.VARIANTS, 1):
            records.append(dict(kind='variant-start', sequence=sequence, variant=variant, sharedLimitSeconds=90))
            names = ['layout', 'bootstrap'] + ([] if variant == 'combined-prefix' else ['prefix']) + ['pip-version']
            for name in names:
                records.append(dict(kind='stage-start', stage=name, seconds=1))
                records.append(dict(kind='stage-end', stage=name, exit=0, wallSeconds=1, userSeconds=.8, systemSeconds=.1))
            records.append(dict(kind='variant-end', sequence=sequence, variant=variant, exit=0,
                                wallSeconds=5, userSeconds=4, systemSeconds=.5, pyFiles=495, pycFiles=100))
        records.append(dict(kind='completed', diagnosticOnly=True, qualificationPassed=False, variants=8))
        self.assertTrue(validate(records))
        changes = []
        changes.append(records[:-1])
        replay = copy.deepcopy(records); replay[1]['sequence'] = 2; changes.append(replay)
        failed = copy.deepcopy(records); failed[3]['exit'] = 19; changes.append(failed)
        forged = copy.deepcopy(records); forged[-1]['qualificationPassed'] = True; changes.append(forged)
        bad = copy.deepcopy(records); bad[3]['wallSeconds'] = float('nan'); changes.append(bad)
        missing = copy.deepcopy(records); del missing[2]; changes.append(missing)
        extra = copy.deepcopy(records); extra[0]['private'] = 'PRIVATE_KEY'; changes.append(extra)
        replay = copy.deepcopy(records); replay[0]['attemptId'] = 'f'*32; changes.append(replay)
        wrong = copy.deepcopy(records); wrong[0]['bootstrapSha256'] = 'f'*64; changes.append(wrong)
        text = copy.deepcopy(records); text[0]['python'] = 'PRIVATE_TEXT'; changes.append(text)
        boolean = copy.deepcopy(records); boolean[-1]['qualificationPassed'] = 0; changes.append(boolean)
        for changed in changes:
            with self.assertRaises((ValueError, IndexError)):
                validate(changed)
        timed = copy.deepcopy(records)
        # First variant timed out in layout; all later variants remain measured.
        del timed[3:10]
        timed[3]['exit'] = 124
        self.assertTrue(validate(timed))
    def test_real_child_success_and_nonzero_exit(self):
        fake_resource = types.SimpleNamespace(RUSAGE_CHILDREN=0,
            getrusage=lambda _: types.SimpleNamespace(ru_utime=1, ru_stime=2))
        for status in (0, 19):
            output = io.StringIO()
            with patch.dict(sys.modules, resource=fake_resource), contextlib.redirect_stdout(output):
                if status:
                    with self.assertRaises(SystemExit) as failed:
                        module.stage("pip-version", [sys.executable, "-c", "raise SystemExit(19)"], dict(os.environ))
                    self.assertEqual(failed.exception.code, 19)
                else:
                    module.stage("pip-version", [sys.executable, "-c", "print('PRIVATE_TEXT')"], dict(os.environ))
            self.assertNotIn("PRIVATE_TEXT", output.getvalue())
            records = [json.loads(line.removeprefix("VENV_STAGE ")) for line in output.getvalue().splitlines() if line.startswith('VENV_STAGE ')]
            self.assertEqual([r["kind"] for r in records], ["stage-start", "stage-end"])
            self.assertEqual(records[1]["exit"], status)
            self.assertGreaterEqual(records[1]["wallSeconds"], 0)

    def test_exact_production_bootstrap_extract(self):
        profile = (ROOT / "guest/profiles/coding-default/v1/provision.sh").read_text()
        blocks = re.findall(r'<<"EZVM_PIP_BOOTSTRAP"\n(.*?)\nEZVM_PIP_BOOTSTRAP', profile, re.S)
        self.assertEqual(len(blocks), 1)
        compile(blocks[0], "production-bootstrap", "exec")
        self.assertEqual(blocks[0].count('return original([*args, "--no-compile"], additional_paths)'), 1)
        self.assertIn('if calls != 1:', blocks[0])

    def test_modes_preserve_actual_cli_and_prefix(self):
        self.assertEqual(len(module.VARIANTS), 8)
        self.assertEqual(module.VARIANTS[:4], module.VARIANTS[4:])
        source = Path(spec.origin).read_text()
        self.assertIn('[str(interpreter), "-m", "pip", "--version"]', source)
        self.assertIn('assert sys.prefix != sys.base_prefix', source)
        self.assertIn('"timeout", "--kill-after=3", "90"', source)

    def test_worker_rejects_unknown_mode_and_unowned_path(self):
        with self.assertRaisesRegex(RuntimeError, 'fixed-owned-experiment-required'):
            module.worker('arbitrary', '/var/lib/ezvm-stage/probe-a')
        with self.assertRaisesRegex(RuntimeError, 'fixed-owned-experiment-required'):
            module.worker('current', '/tmp/unowned')

    def test_actual_worker_command_routing_and_failed_stage_stops(self):
        profile = (ROOT / 'guest/profiles/coding-default/v1/provision.sh').read_text()
        bootstrap = re.findall(r'<<"EZVM_PIP_BOOTSTRAP"\n(.*?)\nEZVM_PIP_BOOTSTRAP', profile, re.S)[0]
        for variant in module.VARIANTS[:4]:
            commands = []
            def capture(name, command, environment):
                commands.append((name, command, dict(environment)))
            with patch.object(module, 'stage', side_effect=capture), patch.object(Path, 'read_text', return_value=bootstrap):
                module.worker(variant, '/var/lib/ezvm-stage/probe-a')
            expected = ['layout','bootstrap'] + ([] if variant == 'combined-prefix' else ['prefix']) + ['pip-version']
            self.assertEqual([c[0] for c in commands], expected)
            self.assertEqual(commands[0][1][:4], ['python3','-m','venv','--without-pip'])
            self.assertEqual(commands[-1][1][1:], ['-m','pip','--version'])
            actual_bootstrap = commands[1][1][2]
            if variant == 'compiled':
                self.assertIn('return original(args, additional_paths)', actual_bootstrap)
                self.assertNotIn('"--no-compile"', actual_bootstrap)
            else:
                self.assertIn('return original([*args, "--no-compile"], additional_paths)', actual_bootstrap)
            if variant == 'combined-prefix':
                self.assertTrue(actual_bootstrap.endswith('assert sys.prefix != sys.base_prefix\n'))
            else:
                self.assertEqual(commands[2][1][1:], ['-c','import sys; assert sys.prefix != sys.base_prefix'])
            if variant == 'no-version-pyc':
                self.assertEqual(commands[-1][2]['PYTHONDONTWRITEBYTECODE'], '1')
            for failed in ['bootstrap'] + ([] if variant == 'combined-prefix' else ['prefix']):
                reached = []
                def stop(name, command, environment):
                    reached.append(name)
                    if name == failed: raise SystemExit(19)
                with patch.object(module,'stage',side_effect=stop),patch.object(Path,'read_text',return_value=bootstrap):
                    with self.assertRaises(SystemExit) as error:
                        module.worker(variant,'/var/lib/ezvm-stage/probe-a')
                self.assertEqual(error.exception.code,19)
                self.assertNotIn('pip-version',reached)


if __name__ == '__main__':
    unittest.main()
