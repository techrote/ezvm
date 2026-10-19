from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import sys
import time

from .collectors import Collector, load_config
from .model import Sample, safe
from .ui import DashboardControl, make_application


class DemoCollector:
    """Clearly labelled synthetic UI fixture; performs no I/O."""
    def __init__(self):
        self.config = {'instance': 'DEMO — SYNTHETIC DATA'}
        self.selected = None
        self.data = {'inventory': {'vms': [{'name': 'example-vm', 'recorded_state': 'RUNNING', 'process': 'synthetic', 'intent': {'cpus': 4, 'memoryMiB': 8192}}]},
                     'host': {'cpus': 8, 'cpu_percent': 12, 'memory_total': 32*2**30, 'memory_available': 18*2**30, 'disk_free': 100*2**30},
                     'guest': {'policy': {'owner_paused': True, 'actors': []}, 'session_count': 2,
                               'workers': [{'id': 'demo-1', 'title': 'DEMO: review candidate', 'state': 'idle', 'provider': 'example-free', 'model': 'example-model', 'root': '/demo/review'},
                                           {'id': 'demo-2', 'title': 'DEMO: provider unavailable', 'state': 'unknown', 'provider': 'example-cloud', 'model': 'example-model', 'root': '/demo/build'}],
                               'detail': {'id': 'demo-1', 'head': 'synthetic', 'changes': ' M demo.py', 'events': [{'kind': 'tool', 'name': 'bash', 'status': 'completed', 'exit': 0, 'title': 'Synthetic test output', 'output': '2 tests passed\nIndependent acceptance is still outstanding.'}]},
                               'usage': [{'provider': 'example-free', 'model': 'example-model', 'messages': 2, 'with_usage': 1, 'input': 200, 'cache_read': 100, 'output': 50, 'reasoning': 10}],
                               'status_coverage': {'roots_sampled': 2}},
                     'engine:demo': {'kind': 'strata', 'engine': {'model': 'SYNTHETIC', 'max_context': 32768}, 'live': {'state': 'idle', 'queued': 0}}}

    def snapshot(self):
        return {k: Sample(v, time.time()) for k,v in self.data.items()}

    def refresh(self):
        pass

    def select(self, sid):
        self.selected = sid

    def start(self):
        pass

    def close(self):
        pass


def clean(value):
    if isinstance(value, str):
        return safe(value, max(1200,len(value)))
    if isinstance(value, dict):
        return {k: clean(v) for k,v in value.items()}
    if isinstance(value, list):
        return [clean(v) for v in value]
    return value


def main(argv=None):
    parser=argparse.ArgumentParser(description='Read-only EzVM VM/worker/model dashboard. No launch, prompt, abort or provisioning commands.')
    parser.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[2])
    parser.add_argument('--config',type=Path)
    parser.add_argument('--once',action='store_true',help='One bounded collection then a terminal snapshot')
    parser.add_argument('--json',action='store_true',help='One JSON observation (implies --once); local output may include project text')
    parser.add_argument('--demo',action='store_true',help='Synthetic fixture, no external calls')
    parser.add_argument('--width',type=int,default=140)
    parser.add_argument('--height',type=int,default=45)
    args=parser.parse_args(argv)
    if (args.once or args.json) and hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    try:
        collector=DemoCollector() if args.demo else Collector(args.root.resolve(),load_config(args.root.resolve(),args.config))
    except (OSError,ValueError,TypeError) as exc:
        print('Dashboard configuration error: '+safe(exc),file=sys.stderr)
        return 2
    if not(args.once or args.json) and not(sys.stdin.isatty() and sys.stdout.isatty()):
        print('Interactive dashboard needs a terminal. Use --once or --json for observation.',file=sys.stderr)
        collector.close()
        return 2
    try:
        collector.start()
        if args.once or args.json:
            deadline=time.monotonic()+18
            while time.monotonic()<deadline:
                samples=collector.snapshot()
                if args.demo or (len(samples)==len(collector.jobs) and all(s.updated or s.error for s in samples.values())):
                    break
                time.sleep(.1)
            samples=collector.snapshot()
            if args.json:
                payload={'schemaVersion':1,'readOnly':True,'synthetic':args.demo,'capturedAt':datetime.now(timezone.utc).isoformat(),
                         'sources':{k:{'observedAt':s.updated or None,'ageSeconds':time.time()-s.updated if s.updated else None,'error':s.error or None,'data':s.data} for k,s in samples.items()}}
                print(json.dumps(clean(payload),ensure_ascii=True,indent=2))
            else:
                view=DashboardControl(collector)
                for line in view.render(max(40,min(240,args.width)),max(12,min(100,args.height))):
                    print(''.join(text for style,text in line).rstrip())
            guest = samples.get('guest', Sample())
            return 1 if (not args.demo and collector.config.get('instance') and (guest.error or not guest.updated)) else 0
        app,_=make_application(collector)
        app.run()
        return 0
    except KeyboardInterrupt:
        return 0
    finally:
        collector.close()


if __name__=='__main__':
    raise SystemExit(main())
