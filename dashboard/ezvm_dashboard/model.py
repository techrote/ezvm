"""Pure presentation/state primitives. No network or process operations."""
from __future__ import annotations

from dataclasses import dataclass, field
import re
import time
import unicodedata

from wcwidth import wcwidth


def safe(value, limit=1200):
    """Never forward terminal escape/control sequences from worker output."""
    text = str(value if value is not None else '—')[:limit * 3]
    text = re.sub(r'\x1b\][^\x07]*(?:\x07|\x1b\\)', '', text)
    text = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', text)
    # Best-effort local display redaction; not a claim of safe public export.
    text = re.sub(r'(?i)(bearer\s+|(?:api[_-]?key|token|password)\s*[=:]\s*)\S+', r'\1[redacted]', text)
    return ''.join(c if c in '\n\t' or unicodedata.category(c)[0] != 'C' else '�' for c in text)[:limit]


def cells(text, width):
    result = []
    used = 0
    for char in safe(text, max(1, len(str(text)))).replace('\t', '    ').replace('\n', ' '):
        size = max(0, wcwidth(char))
        if used + size > max(0, width):
            break
        result.append(char)
        used += size
    return ''.join(result) + ' ' * max(0, width - used)


def number(value, decimals=0):
    if value is None:
        return '—'
    try:
        return f'{float(value):,.{decimals}f}'
    except (TypeError, ValueError):
        return '—'


def gib(value):
    return '—' if value is None else number(value / 2**30, 1)


@dataclass
class Sample:
    data: dict = field(default_factory=dict)
    updated: float = 0
    attempted: float = 0
    error: str = ''

    def label(self):
        if not self.updated:
            return 'unavailable' if self.error else 'waiting'
        age = max(0, time.time() - self.updated)
        return f'{"STALE " if self.error else ""}{age:.0f}s ago'


@dataclass
class TileState:
    focus: int = 0
    hidden: set = field(default_factory=set)
    swapped: bool = False
    maximized: bool = False
    x_ratio: float = .28
    y_ratio: float = .54
    scroll: dict = field(default_factory=lambda: {i: 0 for i in range(4)})
    drag: tuple | None = None

    def visible(self):
        return [i for i in range(4) if i not in self.hidden]

    def cycle(self, step=1):
        visible = self.visible()
        if visible:
            self.focus = visible[(visible.index(self.focus) + step) % len(visible)]

    def reveal(self, tile):
        self.hidden.discard(tile)
        self.focus = tile

    def hide(self, tile):
        if len(self.visible()) > 1:
            self.hidden.add(tile)
            if self.focus == tile:
                self.focus = self.visible()[0]

    def restore(self):
        self.hidden.clear()
        self.maximized = False

    def begin_drag(self, axis):
        self.drag = (axis, self.x_ratio, self.y_ratio)

    def cancel(self):
        if self.drag:
            _, self.x_ratio, self.y_ratio = self.drag
            self.drag = None

    def geometry(self, width, height):
        """Return tile rectangles plus divider hit geometry in terminal cells."""
        body_y, body_h = 3, max(1, height - 5)
        visible = self.visible()
        if width < 105 or height < 29 or self.maximized or len(visible) == 1:
            return {self.focus: (0, body_y, width, body_h)}, []
        left = [i for i in (0, 3) if i in visible]
        right = [i for i in ((2, 1) if self.swapped else (1, 2)) if i in visible]
        split = max(24, min(width - 45, int(width * self.x_ratio))) if left and right else 0
        result, dividers = {}, []
        if split:
            dividers.append(('x', split, body_y, 1, body_h))
        for group, x, w in [(left, 0, split if split else width), (right, split + 1 if split else 0, width - split - 1 if split else width)]:
            if not group:
                continue
            if len(group) == 1:
                result[group[0]] = (x, body_y, w, body_h)
            else:
                top = max(7, min(body_h - 7, int(body_h * self.y_ratio)))
                result[group[0]] = (x, body_y, w, top)
                result[group[1]] = (x, body_y + top + 1, w, body_h - top - 1)
                dividers.append(('y', x, body_y + top, w, 1))
        return result, dividers


def merge_worker_rows(rows):
    """Same logical origin/session through multiple endpoints is one worker."""
    merged = {}
    for row in rows:
        key = (row.get('origin'), row['id'])
        previous = merged.get(key)
        if previous is None or row.get('observedAt', 0) >= previous.get('observedAt', 0):
            merged[key] = row
    return sorted(merged.values(), key=lambda r: r.get('updated', 0), reverse=True)
