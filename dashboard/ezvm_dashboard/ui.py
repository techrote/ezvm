"""Cell-native, mouse-controlled read-only tiles, using prompt_toolkit terminal I/O."""
from __future__ import annotations

from datetime import datetime
import time

from prompt_toolkit.application import Application
from prompt_toolkit.key_binding import KeyBindings
from prompt_toolkit.layout import Layout, Window
from prompt_toolkit.layout.controls import UIContent, UIControl
from prompt_toolkit.mouse_events import MouseEventType, MouseButton
from prompt_toolkit.styles import Style
from wcwidth import wcwidth

from .model import TileState, Sample, safe, cells, number, gib


TITLES = ['VMs & workers', 'Worker activity', 'Models & usage', 'Resources']


class DashboardControl(UIControl):
    def __init__(self, collector):
        self.collector = collector
        self.state = TileState()
        self.application = None
        self.width, self.height = 120, 40
        self.hits = []
        self.rectangles = {}
        self.rows = []
        self.workers = []
        self.selected_id = None
        self.overlay = None
        self.query = ''
        self.choice = 0
        self.activity_mode = 'Activity'
        self.metrics_mode = 'Engines'
        self.follow = False
        self.filter_text = ''
        self.all_vms = False
        self.scroll_limits = {}
        self.reveal_selection = False

    def is_focusable(self):
        return True

    def invalidate(self):
        if self.application:
            self.application.invalidate()

    def put(self, x, y, text, style='', width=None):
        if not 0 <= y < self.height:
            return
        available = min(self.width - x, width if width is not None else self.width - x)
        for char in cells(text, max(0, available)):
            size = max(0, wcwidth(char))
            if size == 0:
                # Combining marks are appended to the previous complete glyph.
                if x > 0:
                    p = x-1
                    while p > 0 and self.rows[y][p][0] == '':
                        p -= 1
                    self.rows[y][p] = (self.rows[y][p][0] + char, style)
                continue
            if x >= 0 and x + size <= self.width:
                self.rows[y][x] = (char, style)
                for offset in range(1, size):
                    self.rows[y][x+offset] = ('', style)
            x += size

    def button(self, x, y, text, action, style='class:button'):
        self.put(x, y, text, style, len(text))
        self.hits.append((x, y, len(text), 1, action))

    def commands(self):
        commands = [('Refresh observations (no worker action)', 'refresh'),
                    ('Restore all tiles', 'restore'), ('Maximize / restore focused tile', 'maximize'),
                    ('Swap activity and metrics tiles', 'swap'), ('Hide focused tile', 'hide'),
                    ('Follow activity output on/off', 'follow'), ('Filter workers by title/model', 'filter'),
                    ('Show all VM records / enrolled VM only', 'vms'),
                    ('Activity: tool transcript', 'mode:Activity'), ('Activity: Git changes', 'mode:Changes'),
                    ('Activity: check outputs', 'mode:Checks'), ('Activity: model report text', 'mode:Report'),
                    ('Metrics: local engines', 'metrics:Engines'), ('Metrics: provider/model usage', 'metrics:Usage'),
                    ('Narrower inventory column', 'narrow'), ('Wider inventory column', 'wide'),
                    ('Shorter upper tiles', 'short'), ('Taller upper tiles', 'tall'),
                    ('Help and read-only boundaries', 'help'), ('Quit dashboard; leave VM/workers alone', 'quit')]
        commands += [('Focus ' + title, 'focus:' + str(i)) for i, title in enumerate(TITLES)]
        return [(title, action) for title, action in commands if self.query.lower() in title.lower()]

    def action(self, action):
        if action == 'quit':
            if self.application:
                self.application.exit()
        elif action == 'refresh':
            self.collector.refresh()
        elif action == 'restore':
            self.state.restore()
        elif action == 'maximize':
            self.state.maximized = not self.state.maximized
        elif action == 'swap':
            self.state.swapped = not self.state.swapped
        elif action == 'hide':
            self.state.hide(self.state.focus)
        elif action == 'follow':
            self.follow = not self.follow
        elif action == 'vms':
            self.all_vms = not self.all_vms
            self.state.scroll[0] = 0
        elif action in ('palette', 'filter', 'help'):
            self.overlay, self.query, self.choice = action, '', 0
        elif action == 'narrow':
            self.state.x_ratio = max(.20, self.state.x_ratio - .04)
        elif action == 'wide':
            self.state.x_ratio = min(.5, self.state.x_ratio + .04)
        elif action == 'short':
            self.state.y_ratio = max(.25, self.state.y_ratio - .05)
        elif action == 'tall':
            self.state.y_ratio = min(.75, self.state.y_ratio + .05)
        elif action.startswith('focus:'):
            self.state.reveal(int(action[6:]))
        elif action.startswith('hide:'):
            self.state.hide(int(action[5:]))
        elif action.startswith('max:'):
            self.state.reveal(int(action[4:]))
            self.state.maximized = not self.state.maximized
        elif action.startswith('mode:'):
            self.activity_mode = action[5:]
            self.state.scroll[1] = 0
        elif action.startswith('metrics:'):
            self.metrics_mode = action[8:]
            self.state.scroll[2] = 0
        elif action.startswith('worker:'):
            self.select(action[7:])
        self.invalidate()

    def select(self, sid):
        self.selected_id = sid
        self.reveal_selection = True
        self.state.scroll[1] = 0
        self.collector.select(sid)

    def selected(self):
        return next((w for w in self.workers if w['id'] == self.selected_id), {})

    def inventory_lines(self, samples):
        lines = []
        inventory = samples.get('inventory', Sample())
        lines.append((f'VM observation: {inventory.label()}', None))
        all_vms = inventory.data.get('vms', [])
        visible = all_vms if self.all_vms else [v for v in all_vms if v['name'] == self.collector.config.get('instance')]
        if not self.collector.config.get('instance'):
            visible = all_vms
        for vm in visible:
            lines.append((f'{vm["name"]}  {vm.get("recorded_state", "unknown")}', None))
            lines.append((f'  {vm.get("process", vm.get("error", "—"))}', None))
        if len(visible) < len(all_vms):
            lines.append((f'  +{len(all_vms)-len(visible)} VM records (palette: show all)', None))
        guest = samples.get('guest', Sample())
        data = guest.data
        self.workers = data.get('workers', [])
        if not self.selected_id and self.workers:
            self.select(self.workers[0]['id'])
        policy = data.get('policy', {})
        lines += [('', None), (f'Workers: {guest.label()}', None),
                  (f'Roster {len(policy.get("actors", []))} | history {len(self.workers)}/{data.get("session_count", "—")}', None)]
        if self.filter_text:
            lines.append(('Filter: ' + self.filter_text, None))
        for worker in self.workers:
            if self.filter_text.lower() not in (worker.get('title', '') + worker.get('model', '')).lower():
                continue
            marker = '>' if worker['id'] == self.selected_id else ' '
            lines.append((f'{marker} {worker.get("state", "unknown")} | {worker["title"]}', 'worker:' + worker['id']))
        if not self.workers:
            lines.append(('No session records available', None))
        for error in data.get('errors', []):
            lines.append(('Telemetry: ' + safe(error), None))
        return lines

    def activity_lines(self, samples):
        guest = samples.get('guest', Sample())
        selected = self.selected()
        detail = guest.data.get('detail', {})
        lines = [f'{selected.get("title", "Select a worker session")}',
                 f'{selected.get("provider", "—")} / {selected.get("model", "—")}',
                 f'State: {selected.get("state", "unknown")} | observed {guest.label()} | acceptance: not inferred',
                 f'Root: {selected.get("root", "—")}']
        if detail.get('id') != self.selected_id:
            return lines + ['', 'Reading selected session (other panes remain live)…']
        usage = selected.get('usage', {})
        lines += [f'Usage: input {number(usage.get("input"))} / cache read {number(usage.get("cache_read"))} / output {number(usage.get("output"))} / reasoning {number(usage.get("reasoning"))}',
                  f'HEAD: {detail.get("head", "unavailable")}', '']
        if self.activity_mode == 'Changes':
            return lines + ['GIT STATUS (read only)', safe(detail.get('changes') or '(clean / no changes reported)', 12000),
                            '', 'DIFF SUMMARY', safe(detail.get('diff_stat') or '(no unstaged diff)', 12000)]
        events = detail.get('events', [])
        for event in events:
            if event['kind'] == 'text':
                if self.activity_mode in ('Report', 'Activity'):
                    lines += ['MODEL TEXT — a claim, not acceptance', safe(event.get('text', ''), 5000), '']
            elif self.activity_mode != 'Report':
                title = str(event.get('title') or event.get('name') or '')
                output = str(event.get('output') or '')
                if self.activity_mode == 'Checks' and not any(x in (title + output).lower() for x in ('test', 'pytest', 'pass', 'fail', 'check', 'exit', 'ci.py')):
                    continue
                lines += [f'TOOL {event.get("name")} [{event.get("status")}] exit={event.get("exit", "—")}',
                          title, safe(output, 5000), '']
        if not events:
            lines.append('No recent text/tool output returned.')
        lines.append('Bounded transcript: last45 parts, output tails only. No terminal input is forwarded.')
        return lines

    def metric_lines(self, samples):
        if self.metrics_mode == 'Usage':
            guest = samples.get('guest', Sample())
            rows = guest.data.get('usage', [])
            lines = [f'Enrolled OpenCode history | {guest.label()}',
                     'Provider/model  | input | cache read | output | reasoning',
                     'Raw OpenCode-normalized categories; no cross-field grand total.',
                     'One database snapshot: duplicate ports NOT added. Includes compaction.', '']
            for row in rows:
                lines += [row['provider'] + ' / ' + row['model'],
                          f'  {number(row.get("input"))} | {number(row.get("cache_read"))} | {number(row.get("output"))} | {number(row.get("reasoning"))}',
                          f'  usage {row["with_usage"]}/{row["messages"]} messages; cache writes {number(row.get("cache_write"))}']
            lines += ['', 'Missing/error usage is not zero cost. Provider billing/quota: unavailable.',
                      'Engine totals below are a separate source and are NEVER added to these totals.']
            return lines
        lines = []
        for key, sample in samples.items():
            if not key.startswith('engine:'):
                continue
            data = sample.data
            lines.append(f'{key[7:].upper()}  | {sample.label()}')
            if sample.error:
                lines += ['  ' + sample.error, '']
            if data.get('kind') == 'strata':
                engine, live, totals = data.get('engine', {}), data.get('live', {}), data.get('totals', {})
                lines += [f'Model: {engine.get("model", "—")}',
                          f'Runtime {engine.get("version", "—")} | {live.get("state", "unknown")} | queue {number(live.get("queued"))}',
                          f'Context {number(live.get("prompt_tokens"))}/{number(engine.get("max_context"))} configured | KV {engine.get("kv", "—")}',
                          f'Decode live {number(live.get("tok_s"), 1)} / mean {number(live.get("tok_s_mean"), 1)} tok/s',
                          f'Prefill mean {number(live.get("prefill_tok_s_mean"), 1)} tok/s | output {number(live.get("generated"))}/{number(live.get("max_tokens"))}',
                          f'Runtime totals {number(totals.get("requests"))} requests | {number(totals.get("output_tokens"))} output',
                          'Recent completed requests: context / output / decode tok/s / wall sec']
                for r in data.get('requests', [])[:5]:
                    lines.append(f'  {number(r.get("prompt_total", r.get("prompt_tokens")))} / {number(r.get("output_tokens"))} / {number(r.get("decode_tok_s"), 1)} / {number(r.get("duration_s"), 1)}  {r.get("finish", "—")}')
            elif data.get('kind') == 'lmstudio':
                for model in data.get('models', [])[:25]:
                    lines += [f'{model.get("id", "unknown model")}',
                              f'  {model.get("state", "unknown")} | quant {model.get("quantization", "—")} | context {number(model.get("max_context_length"))}']
            lines.append('')
        if not lines:
            lines = ['No local engines enrolled. Configure explicit loopback endpoints.']
        return lines + ['Local engine rates are not provider/worker attribution.', 'Use [Usage] for all enrolled provider/model message counters.']

    def resource_lines(self, samples):
        host = samples.get('host', Sample())
        h = host.data
        guest = samples.get('guest', Sample())
        g = guest.data.get('resources', {})
        lines = [f'HOST | {host.label()}', f'CPU {number(h.get("cpu_percent"), 1)}% / {h.get("cpus", "—")} logical',
                 f'RAM available {gib(h.get("memory_available"))}/{gib(h.get("memory_total"))} GiB',
                 f'Commit available {gib(h.get("commit_available"))} GiB', f'Host volume free {gib(h.get("disk_free"))} GiB', '']
        for gpu in h.get('gpus', []):
            lines += [f'GPU {gpu["index"]} {gpu["name"]}', f'{gpu["uuid"]}',
                      f'{gpu["util"]}%  {gpu["temp"]}C  {gpu["used_mib"]}/{gpu["total_mib"]} MiB',
                      f'{gpu["power"]}/{gpu["limit"]} W (observed only)', '']
        name = self.collector.config.get('instance') or 'not enrolled'
        host_lines = lines
        lines = [f'GUEST {name} | {guest.label()}']
        vm = next((v for v in samples.get('inventory', Sample()).data.get('vms', []) if v.get('name') == name), {})
        intent = vm.get('intent', {})
        lines += [f'Allocated: {intent.get("cpus", "—")} vCPU / {number(intent.get("memoryMiB"))} MiB',
                  f'Observed: {g.get("cpus", "—")} vCPU / {gib(g.get("memory_total"))} GiB',
                  f'CPU interval {number(g.get("cpu_percent"), 1)}% | load {g.get("load", "—")}',
                  f'RAM available {gib(g.get("memory_available"))} GiB | swap {gib(g.get("swap_used"))}',
                  f'Filesystem free {gib(g.get("disk_free"))}/{gib(g.get("disk_total"))} GiB',
                  f'Profile {intent.get("profile", "—")} / {intent.get("provisioningProfile", "—")}',
                  f'QEMU RSS {gib(vm.get("process_rss"))} GiB | {vm.get("accelerator", "—")}', '',
                  'Provisioning is display-only in this release.']
        return lines + [''] + host_lines

    def render(self, width, height):
        self.width, self.height = max(1, width), max(1, height)
        self.rows = [[(' ', '') for _ in range(self.width)] for _ in range(self.height)]
        self.hits = []
        samples = self.collector.snapshot()
        guest = samples.get('guest', Sample())
        policy = guest.data.get('policy', {})
        pause = 'OWNER PAUSED' if policy.get('owner_paused') else ('POLICY UNKNOWN' if policy.get('owner_paused') is None else 'policy not paused')
        pause += ' | ' + guest.label()
        title = ' EzVM  /  OBSERVE ONLY  /  ' + pause
        self.put(0, 0, title, 'class:banner', self.width)
        x = 1
        for text, action in [('[Commands]', 'palette'), ('[Restore]', 'restore'), ('[Swap]', 'swap'), ('[Refresh]', 'refresh'), ('[Help]', 'help'), ('[Quit]', 'quit')]:
            if x + len(text) < self.width:
                self.button(x, 1, text, action)
            x += len(text) + 1
        self.put(1, 2, f'{datetime.now().strftime("%H:%M:%S")}  Scope: {self.collector.config.get("instance") or "host only"}  |  mouse: focus / scroll / resize  |  Ctrl+P commands', 'class:muted')
        self.rectangles, dividers = self.state.geometry(self.width, self.height)
        contents = {0: self.inventory_lines(samples), 1: [(s, None) for line in self.activity_lines(samples) for s in line.splitlines() or ['']],
                    2: [(s, None) for line in self.metric_lines(samples) for s in line.splitlines() or ['']],
                    3: [(s, None) for line in self.resource_lines(samples) for s in line.splitlines() or ['']]}
        for axis, x, y, w, h in dividers:
            for yy in range(y, y+h):
                self.put(x, yy, '│' if axis == 'x' else '─'*w, 'class:divider', w)
            self.hits.append((x, y, w, h, 'divider:' + axis))
        for tile, (x, y, w, h) in self.rectangles.items():
            style = 'class:focus' if self.state.focus == tile else 'class:header'
            self.put(x, y, f' {tile+1} {TITLES[tile]}', style, w)
            if w >= 16:
                self.button(x+w-9, y, '[M]', 'max:' + str(tile), style)
                self.button(x+w-5, y, '[x]', 'hide:' + str(tile), style)
            extra = 0
            if tile == 1:
                xx = x+1
                for mode in ('Activity', 'Changes', 'Checks', 'Report'):
                    label = '['+mode+']'
                    if xx+len(label) < x+w:
                        self.button(xx, y+1, label, 'mode:'+mode, 'class:chosen' if mode == self.activity_mode else 'class:button')
                    xx += len(label)+1
                extra = 1
            elif tile == 2:
                self.button(x+1, y+1, '[Engines]', 'metrics:Engines', 'class:chosen' if self.metrics_mode == 'Engines' else 'class:button')
                self.button(x+12, y+1, '[Usage]', 'metrics:Usage', 'class:chosen' if self.metrics_mode == 'Usage' else 'class:button')
                extra = 1
            body = max(0, h-1-extra)
            maximum = max(0, len(contents[tile])-body)
            self.scroll_limits[tile] = maximum
            if tile == 0 and self.reveal_selection:
                selected_row = next((i for i, (_, action) in enumerate(contents[tile]) if action == 'worker:' + str(self.selected_id)), None)
                if selected_row is not None:
                    current = self.state.scroll[tile]
                    self.state.scroll[tile] = min(current, selected_row) if selected_row < current else max(current, selected_row-body+1)
                self.reveal_selection = False
            if tile == 1 and self.follow:
                self.state.scroll[tile] = maximum
            offset = min(self.state.scroll[tile], maximum)
            self.state.scroll[tile] = offset
            for i, (line, action) in enumerate(contents[tile][offset:offset+body]):
                yy = y+1+extra+i
                line_style = 'class:chosen' if action == 'worker:' + str(self.selected_id) else ''
                self.put(x+1, yy, line, line_style, max(0, w-2))
                if action:
                    self.hits.append((x, yy, w, 1, action))
        errors = [(key, s.error) for key, s in samples.items() if s.error]
        coverage = samples.get('guest', Sample()).data.get('status_coverage', {})
        note = f'Scoped status: {coverage.get("roots_sampled", "—")} roots / {coverage.get("failure_count", "—")} failed reads; idle ≠ accepted; unobserved ≠ idle'
        if errors:
            note = 'UNAVAILABLE / STALE  ' + ' | '.join(k+': '+v for k,v in errors)
        self.put(0, self.height-2, note, 'class:warning' if errors else 'class:muted', self.width)
        self.put(0, self.height-1, ' Ctrl+P commands  Tab focus  Alt+1..4 tiles  Ctrl+T restore  F5 refresh  F1 help  Ctrl+Q quit', 'class:footer', self.width)
        if self.overlay:
            self.draw_overlay()
        return [[(style, char) for char, style in row if char] for row in self.rows]

    def draw_overlay(self):
        w, h = min(86, self.width), min(21, self.height-2)
        x, y = max(0, (self.width-w)//2), max(0, (self.height-h)//2)
        self.overlay_rect = (x,y,w,h)
        # Overlay owns pointer actions exclusively, including dismissal.
        self.hits = []
        for yy in range(y,y+h):
            self.put(x, yy, '', 'class:dialog', w)
        if self.overlay == 'help':
            text = [' HELP — READ ONLY', '', 'Tab / Shift+Tab: focus a tile. Alt+1..4: reveal/focus.',
                    'Click controls; wheel scrolls only the pointed tile.',
                    'Drag dividers with either button. Escape rolls back.',
                    '[M] maximizes; [x] hides; Ctrl+T restores all tiles.',
                    'Ctrl+P / F10: searchable command palette; F5 refresh.',
                    'Ctrl+F: filter workers. Enter/arrow keys select sessions.',
                    'PageUp/Down, Home/End scroll the focused pane.',
                    'F toggles follow for activity. Use maximize for long lines.', '',
                    'Activity is a bounded transcript, NOT an interactive terminal.',
                    'No prompts, worker resumes, aborts, VM writes or model loads.',
                    'SSH probe only reads metrics, SQLite and Git status.',
                    'Persisted VM status is NOT a fresh READY qualification.',
                    'Engine counters are separate from worker usage.',
                    'Ctrl+Q exits this viewer; current VM/workers continue.', '', 'Escape or outside click closes this overlay.']
        elif self.overlay == 'filter':
            text = [' FILTER WORKERS', '', '> '+self.query, '', 'Enter applies; empty clears; Escape cancels.']
        else:
            commands = self.commands()
            self.choice = min(self.choice, max(0,len(commands)-1))
            text = [' COMMANDS  (type to search, arrows/Enter to choose)', '> '+self.query, '']
            start = max(0, self.choice-(h-5))
            for i,(title,action) in enumerate(commands[start:start+h-3],start):
                text.append(('> ' if i == self.choice else '  ') + title)
                self.hits.append((x+1,y+len(text)-1,w-2,1,'command:'+action))
        for i,line in enumerate(text[:h]):
            self.put(x+1,y+i,line,'class:dialog',max(0,w-2))

    def create_content(self, width, height):
        rows = self.render(width,height)
        return UIContent(get_line=lambda i: rows[i], line_count=len(rows), show_cursor=False)

    def mouse_handler(self, event):
        x,y = event.position.x,event.position.y
        kind = event.event_type
        if self.state.drag:
            if kind in (MouseEventType.MOUSE_MOVE, MouseEventType.MOUSE_UP):
                if self.state.drag[0] == 'x':
                    self.state.x_ratio=max(.2,min(.5,x/max(1,self.width)))
                else:
                    self.state.y_ratio=max(.25,min(.75,(y-3)/max(1,self.height-5)))
                if kind == MouseEventType.MOUSE_UP:
                    self.state.drag=None
                self.invalidate()
                return None
        if self.overlay:
            if kind == MouseEventType.MOUSE_DOWN:
                ox,oy,w,h=self.overlay_rect
                if not (ox<=x<ox+w and oy<=y<oy+h):
                    self.overlay=None
                else:
                    for hx,hy,hw,hh,action in self.hits:
                        if hx<=x<hx+hw and hy<=y<hy+hh and action.startswith('command:'):
                            self.overlay=None
                            self.action(action[8:])
                            break
                self.invalidate()
            return None
        tile=next((i for i,(tx,ty,tw,th) in self.rectangles.items() if tx<=x<tx+tw and ty<=y<ty+th),None)
        if kind in (MouseEventType.SCROLL_UP,MouseEventType.SCROLL_DOWN):
            if tile is not None:
                delta=-3 if kind==MouseEventType.SCROLL_UP else 3
                self.state.scroll[tile]=max(0,min(self.scroll_limits.get(tile,0),self.state.scroll[tile]+delta))
                if tile==1:self.follow=False
                self.invalidate()
            return None
        if kind==MouseEventType.MOUSE_DOWN:
            if tile is not None:self.state.focus=tile
            for hx,hy,hw,hh,action in self.hits:
                if hx<=x<hx+hw and hy<=y<hy+hh:
                    if action.startswith('divider:'):
                        self.state.begin_drag(action[8:])
                    elif event.button==MouseButton.LEFT:
                        self.action(action)
                    break
            self.invalidate()
        return None


def make_application(collector, input=None, output=None):
    control=DashboardControl(collector)
    keys=KeyBindings()
    def bind(key, action):
        @keys.add(key)
        def handler(event):
            control.action(action)
    for key,action in [('c-q','quit'),('c-p','palette'),('f10','palette'),('c-t','restore'),('f5','refresh'),('f1','help'),('c-f','filter')]:
        bind(key,action)
    for i in range(4):
        @keys.add('escape',str(i+1))
        def focus(event, tile=i):control.action('focus:'+str(tile))
    @keys.add('tab')
    def tab(event):
        if not control.overlay:control.state.cycle();control.invalidate()
    @keys.add('s-tab')
    def backtab(event):
        if not control.overlay:control.state.cycle(-1);control.invalidate()
    @keys.add('escape')
    def escape(event):
        control.state.cancel();control.overlay=None;control.invalidate()
    @keys.add('up')
    @keys.add('down')
    def arrows(event):
        delta=-1 if event.key_sequence[0].key=='up' else 1
        if control.overlay=='palette':control.choice=max(0,control.choice+delta)
        elif not control.overlay and control.state.focus==0 and control.workers:
            rows=[w for w in control.workers if control.filter_text.lower() in (w.get('title','')+w.get('model','')).lower()]
            if rows:
                index=next((i for i,w in enumerate(rows) if w['id']==control.selected_id),0)
                control.select(rows[max(0,min(len(rows)-1,index+delta))]['id'])
        elif not control.overlay:
            tile=control.state.focus
            control.state.scroll[tile]=max(0,min(control.scroll_limits.get(tile,0),control.state.scroll[tile]+delta));control.follow=False
        control.invalidate()
    @keys.add('pageup')
    @keys.add('pagedown')
    @keys.add('home')
    @keys.add('end')
    def scroll(event):
        if control.overlay:return
        tile=control.state.focus;key=event.key_sequence[0].key
        val={'home':0,'end':control.scroll_limits.get(tile,0),'pageup':control.state.scroll[tile]-10,'pagedown':control.state.scroll[tile]+10}[key]
        control.state.scroll[tile]=max(0,min(control.scroll_limits.get(tile,0),val));control.follow=False;control.invalidate()
    @keys.add('enter')
    def enter(event):
        if control.overlay=='palette':
            commands=control.commands()
            if commands:
                action=commands[min(control.choice,len(commands)-1)][1];control.overlay=None;control.action(action)
        elif control.overlay=='filter':control.filter_text=control.query;control.state.scroll[0]=0;control.overlay=None
        elif not control.overlay:control.action('maximize')
        control.invalidate()
    @keys.add('backspace')
    def backspace(event):
        if control.overlay in ('palette','filter'):control.query=control.query[:-1];control.choice=0;control.invalidate()
    @keys.add('<any>')
    def text(event):
        if control.overlay in ('palette','filter'):
            control.query=(control.query+safe(event.data,80))[:80];control.choice=0
        elif not control.overlay and event.data.lower()=='f':control.action('follow')
        control.invalidate()
    app=Application(layout=Layout(Window(control)),key_bindings=keys,full_screen=True,mouse_support=True,
                    refresh_interval=1,style=Style.from_dict({'banner':'bg:#18334a #ffffff bold','header':'bg:#263745 #d4e0e8',
                    'focus':'bg:#2e606c #ffffff bold','button':'#84cbd6','chosen':'bg:#284a57 #ffffff',
                    'muted':'#a3b4c0','divider':'#66818c','footer':'bg:#18334a #d4e0e8',
                    'warning':'#f0c36c','dialog':'bg:#273f52 #ffffff'}),input=input,output=output)
    control.application=app
    return app,control
