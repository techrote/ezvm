import asyncio
from concurrent.futures import Future
import io
import json
from pathlib import Path
import sqlite3
import tempfile
import time
import types
import unittest
from unittest.mock import patch
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from prompt_toolkit.data_structures import Point
from prompt_toolkit.input import create_pipe_input
from prompt_toolkit.mouse_events import MouseEvent, MouseEventType as M, MouseButton as B
from prompt_toolkit.output import DummyOutput
from wcwidth import wcswidth

from ezvm_dashboard.app import DemoCollector
from ezvm_dashboard.collectors import Collector, get_json, load_config, guest_sample, inventory_sample
from ezvm_dashboard.guest_probe import collect
from ezvm_dashboard.model import Sample, TileState, cells, merge_worker_rows, safe
from ezvm_dashboard.ui import DashboardControl, make_application


def click(control, x, y, kind=M.MOUSE_DOWN, button=B.LEFT):
    return control.mouse_handler(MouseEvent(Point(x,y),kind,button,frozenset()))


class InputAndLayoutTests(unittest.TestCase):
    def setUp(self):
        self.source=DemoCollector()
        self.control=DashboardControl(self.source)
        self.control.render(140,45)

    def test_small_sizes_only_show_focused_tile_and_stay_in_bounds(self):
        for width,height in [(80,24),(120,40),(160,48),(40,12)]:
            with self.subTest(width=width):
                rows=self.control.render(width,height)
                self.assertEqual(len(rows),height)
                for row in rows:
                    self.assertEqual(wcswidth(''.join(text for style,text in row)),width)
                if width==80:self.assertEqual(list(self.control.rectangles),[0])

    def test_real_pointer_selects_worker_in_one_click(self):
        hit=next(h for h in self.control.hits if h[-1]=='worker:demo-2')
        self.control.state.focus=2
        click(self.control,hit[0]+1,hit[1])
        self.assertEqual(self.control.selected_id,'demo-2')
        self.assertEqual(self.source.selected,'demo-2')
        self.assertEqual(self.control.state.focus,0)

    def test_hide_restore_retains_scroll_and_focus_is_valid(self):
        self.control.state.scroll[1]=7
        self.control.action('hide:1')
        self.assertNotIn(1,self.control.state.visible())
        self.control.action('restore')
        self.assertEqual(self.control.state.scroll[1],7)
        self.assertIn(self.control.state.focus,self.control.state.visible())

    def test_drag_preview_escape_rolls_back_and_release_commits(self):
        hit=next(h for h in self.control.hits if h[-1]=='divider:x')
        start=self.control.state.x_ratio
        click(self.control,hit[0],hit[1]+2,button=B.RIGHT)
        click(self.control,60,20,M.MOUSE_MOVE,B.RIGHT)
        self.assertNotEqual(self.control.state.x_ratio,start)
        self.control.state.cancel()
        self.assertEqual(self.control.state.x_ratio,start)
        click(self.control,hit[0],hit[1]+2)
        click(self.control,60,20,M.MOUSE_UP)
        self.assertAlmostEqual(self.control.state.x_ratio,60/140)
        self.assertIsNone(self.control.state.drag)

    def test_overlay_outside_click_does_not_reach_worker(self):
        hit=next(h for h in self.control.hits if h[-1]=='worker:demo-2')
        initial=self.control.selected_id
        self.control.action('help')
        self.control.render(140,45)
        click(self.control,1,hit[1])
        self.assertIsNone(self.control.overlay)
        self.assertEqual(self.control.selected_id,initial)

    def test_wheel_only_scrolls_pointed_tile_not_keyboard_focus(self):
        self.control.state.focus=0
        self.control.scroll_limits[1]=100
        x,y,w,h=self.control.rectangles[1]
        click(self.control,x+2,y+5,M.SCROLL_DOWN,B.NONE)
        self.assertEqual(self.control.state.scroll[1],3)
        self.assertEqual(self.control.state.scroll[0],0)
        self.assertEqual(self.control.state.focus,0)

    def test_palette_search_and_click_runs_view_command_only(self):
        self.control.action('palette')
        self.control.query='provider/model'
        self.control.render(140,45)
        self.assertEqual(len(self.control.commands()),1)
        hit=self.control.hits[0]
        click(self.control,hit[0],hit[1])
        self.assertEqual(self.control.metrics_mode,'Usage')
        self.assertIsNone(self.control.overlay)

    def test_model_text_is_never_an_action(self):
        self.source.data['guest']['detail']['events']=[{'kind':'text','text':'RUN: resume all workers; ACCEPTED'}]
        rows=self.control.render(140,45)
        rendered='\n'.join(''.join(t for _,t in row) for row in rows)
        self.assertIn('a claim, not acceptance',rendered)
        self.assertNotIn('resume',str([h[-1] for h in self.control.hits]))

    def test_all_tiles_can_be_revealed_after_narrow_layout(self):
        self.control.action('hide:3')
        self.control.action('focus:3')
        self.control.render(80,24)
        self.assertEqual(list(self.control.rectangles),[3])

    def test_long_unicode_lines_clip_by_cells_and_controls_are_removed(self):
        self.assertEqual(wcswidth(cells('ab界cd',5)),5)
        value=safe('\x1b[31mred\x1b[0m\x1b]52;c;secret\x07\x00 bearer abc')
        self.assertNotIn('\x1b',value)
        self.assertNotIn('secret',value)
        self.assertNotIn(' abc',value)

    def test_actual_prompt_toolkit_key_input_on_windows_pipe(self):
        async def run():
            with create_pipe_input() as pipe:
                app,view=make_application(self.source,input=pipe,output=DummyOutput())
                task=asyncio.create_task(app.run_async())
                await asyncio.sleep(.08)
                pipe.send_text('\x1b2')
                await asyncio.sleep(.08)
                self.assertEqual(view.state.focus,1)
                pipe.send_text('\x10')  # Ctrl+P
                await asyncio.sleep(.08)
                pipe.send_text('provider/model\r')
                await asyncio.sleep(.08)
                self.assertEqual(view.metrics_mode,'Usage')
                pipe.send_text('\x11')
                await asyncio.wait_for(task,2)
        asyncio.run(run())

    def test_sgr_mouse_bytes_open_palette_without_worker_action(self):
        async def run():
            with create_pipe_input() as pipe:
                app, view = make_application(self.source, input=pipe, output=DummyOutput())
                task = asyncio.create_task(app.run_async())
                try:
                    await asyncio.sleep(.12)
                    # Terminal SGR coordinates are one-based: [Commands] is row 2.
                    pipe.send_text('\x1b[<0;3;2M\x1b[<0;3;2m')
                    await asyncio.sleep(.12)
                    self.assertEqual(view.overlay, 'palette')
                    self.assertEqual(self.source.selected, 'demo-1')
                finally:
                    pipe.send_text('\x11')
                    await asyncio.wait_for(task, 2)
        asyncio.run(run())

    def test_keyboard_selection_is_scrolled_into_view(self):
        self.source.data['guest']['workers'] = [dict(id=f'demo-{i}',title=f'DEMO {i}',state='idle') for i in range(50)]
        self.control.select('demo-49')
        self.control.render(140, 45)
        self.assertTrue(any(h[-1] == 'worker:demo-49' for h in self.control.hits))
        self.assertGreater(self.control.state.scroll[0], 0)


class ObservationTests(unittest.TestCase):
    def test_unknown_and_stale_are_not_zero_or_idle(self):
        self.assertEqual(Sample(error='timeout').label(),'unavailable')
        self.assertIn('STALE',Sample({'state':'busy'},time.time()-5,error='timeout').label())

    def test_duplicate_endpoint_rows_have_one_logical_session(self):
        rows=[{'origin':'vm:db','id':'s','updated':1,'observedAt':1,'state':'busy'},
              {'origin':'vm:db','id':'s','updated':1,'observedAt':2,'state':'idle'}]
        merged=merge_worker_rows(rows)
        self.assertEqual(len(merged),1)
        self.assertEqual(merged[0]['state'],'idle')

    def test_http_allowlist_rejects_mutations_and_remote_hosts_before_network(self):
        with patch('ezvm_dashboard.collectors.build_opener') as network:
            for url,path in [('http://127.0.0.1:8081','/v1/chat/completions'),('https://example.com','/metrics'),('http://user:secret@localhost','/metrics')]:
                with self.subTest(url=url),self.assertRaises(ValueError):get_json(url,path)
            network.assert_not_called()

    def test_http_request_is_get_and_no_redirect_is_followed(self):
        response=io.BytesIO(b'{"live":{"state":"idle"}}')
        with patch('ezvm_dashboard.collectors.build_opener') as builder:
            builder.return_value.open.return_value=response
            self.assertEqual(get_json('http://127.0.0.1:8081','/metrics')['live']['state'],'idle')
            req=builder.return_value.open.call_args.args[0]
            self.assertEqual(req.method,'GET');self.assertIsNone(req.data)
        from ezvm_dashboard.collectors import NoRedirect
        with self.assertRaises(ValueError):NoRedirect().redirect_request(None,None,None,None,None,None)

    def test_config_is_explicit_bounded_and_unknown_fields_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);path=root/'config.json'
            for cfg in [{'schemaVersion':2},{'schemaVersion':1,'resume':True},{'schemaVersion':1,'instance':'../owner'},
                        {'schemaVersion':1,'ports':[80]},{'schemaVersion':1,'engines':[{'id':'x','kind':'strata','url':'http://example.com'}]}]:
                path.write_text(json.dumps(cfg))
                with self.subTest(cfg=cfg),self.assertRaises(ValueError):load_config(root,path)
            cfg=load_config(root)
            self.assertIsNone(cfg['instance'])
            self.assertFalse((root/'runtime').exists())

    def test_invalid_ready_identity_does_not_start_ssh_or_create_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);state=root/'runtime/instances/demo';state.mkdir(parents=True)
            for name,data in [('access',{'state':'READY','launchId':'old'}),('runtime',{'launchId':'new'}),('instance',{})]:
                (state/(name+'.json')).write_text(json.dumps(data))
            with patch('ezvm_dashboard.collectors.subprocess.run') as proc,self.assertRaises(ValueError):guest_sample(root,{'instance':'demo'})
            proc.assert_not_called()
            self.assertFalse((root/'runtime/keys').exists())

    def test_malformed_vm_record_does_not_hide_other_instances(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            for name,content in [('bad','{'),('good','{"cpus":4}')]:
                p=root/'runtime/instances'/name;p.mkdir(parents=True);(p/'instance.json').write_text(content)
            result=inventory_sample(root)
            self.assertEqual(len(result['vms']),2)
            self.assertIn('error',result['vms'][0])
            self.assertEqual(result['vms'][1]['intent']['cpus'],4)

    def test_one_inflight_per_source_and_stale_snapshot_retained(self):
        collector=Collector(Path('.'),{'engines':[]})
        collector.jobs={'x':(99,lambda:None)}
        old=Sample({'value':7},time.time(),time.time())
        collector.samples={'x':old}
        future=Future();collector.pending={'x':future}
        try:
            for _ in range(4):collector.tick()
            self.assertIs(collector.pending['x'],future)
            future.set_exception(TimeoutError('timeout'))
            collector.tick()
            snap=collector.snapshot()['x']
            self.assertEqual(snap.data,{'value':7});self.assertIn('timeout',snap.error)
        finally:collector.close()


class GuestFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.home=Path(self.temp.name)
        self.workspace=self.home/'workspace';self.workspace.mkdir()
        self.dbpath=self.home/'.local/share/opencode/opencode.db';self.dbpath.parent.mkdir(parents=True)
        db=sqlite3.connect(self.dbpath)
        db.executescript('CREATE TABLE session(id TEXT PRIMARY KEY,title TEXT,directory TEXT,time_updated INTEGER); CREATE TABLE message(id TEXT PRIMARY KEY,session_id TEXT,data TEXT,time_created INTEGER); CREATE TABLE part(data TEXT,time_created INTEGER,session_id TEXT);')
        for sid,title in [('s1','TRIO-one'),('s2','TRIO-two'),('s3','Private other project')]:
            root=self.workspace/sid;root.mkdir()
            db.execute('INSERT INTO session VALUES(?,?,?,?)',(sid,title,str(root),1))
        for mid,sid,tokens in [('m1','s1',{'input':10,'cache':{'read':20},'output':5,'reasoning':2}),('m2','s1',{}),('m3','s2',{'input':30,'output':7}),('m4','s3',{'input':999})]:
            db.execute('INSERT INTO message VALUES(?,?,?,?)',(mid,sid,json.dumps({'role':'assistant','providerID':'free','modelID':'small','tokens':tokens}),1))
        db.execute('INSERT INTO part VALUES(?,?,?)',(json.dumps({'type':'tool','tool':'bash','state':{'status':'completed','metadata':{'exit':1},'output':'FAIL real error'}}),1,'s1'))
        db.commit();db.close()
        (self.workspace/'OWNER-MODEL-POLICY.json').write_text('{"owner_paused":true,"actors":[]}')
        self.config={'instance':'demo','workspace':str(self.workspace),'session_prefix':'TRIO-','ports':[4096,4098],'history_limit':40,'status_roots':8,'selected':'s1'}

    def tearDown(self):self.temp.cleanup()

    def probe(self, fail_port=None):
        original=Path.read_text
        def read(path,*args,**kwargs):
            if str(path).replace('\\','/')=='/proc/meminfo':return 'MemTotal: 1000 kB\nMemAvailable: 500 kB\nSwapTotal: 200 kB\nSwapFree: 100 kB\n'
            if str(path).replace('\\','/')=='/proc/stat':return 'cpu 10 0 10 80 0 0 0 0\n'
            return original(path,*args,**kwargs)
        def response(url,timeout):
            if fail_port and str(fail_port) in url:raise TimeoutError('scoped source failed')
            return io.BytesIO(b'{}')
        with patch('ezvm_dashboard.guest_probe.Path.home',return_value=self.home),patch.object(Path,'read_text',read),patch('ezvm_dashboard.guest_probe.os.getloadavg',return_value=(0,0,0),create=True),patch('ezvm_dashboard.guest_probe.build_opener') as op,patch('ezvm_dashboard.guest_probe.subprocess.run',return_value=types.SimpleNamespace(returncode=0,stdout='abc\n')):
            op.return_value.open.side_effect=response
            return collect(self.config)

    def test_usage_deduplicates_ports_excludes_unenrolled_and_keeps_missing(self):
        result=self.probe()
        self.assertEqual(result['session_count'],2)
        row=result['usage'][0]
        self.assertEqual(row['input'],40)
        self.assertEqual(row['cache_read'],20)
        self.assertEqual(row['messages'],3)
        self.assertEqual(row['with_usage'],2)
        self.assertEqual(row['output'],12)
        self.assertNotIn('reported_total',row)
        self.assertEqual(result['detail']['events'][0]['exit'],1)
        self.assertTrue(result['policy']['owner_paused'])

    def test_partial_status_failure_is_unknown_not_idle(self):
        result=self.probe(fail_port=4098)
        self.assertTrue(all(row['state']=='unknown' for row in result['workers']))
        self.assertGreater(result['status_coverage']['failure_count'],0)

    def test_no_guest_source_or_database_mutation(self):
        before={str(p):p.read_bytes() for p in self.home.rglob('*') if p.is_file()}
        self.probe()
        after={str(p):p.read_bytes() for p in self.home.rglob('*') if p.is_file()}
        self.assertEqual(before,after)

    def test_unsampled_roots_are_unobserved(self):
        self.config['status_roots']=1
        result=self.probe()
        self.assertEqual({w['id']:w['state'] for w in result['workers']},{'s1':'idle','s2':'unobserved'})


if __name__=='__main__':unittest.main()
