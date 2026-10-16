"""DASH-01 fixture contract and pure replay. No live adapters or acceptance API.

This is a synthetic evidence oracle, not the future DASH-05/06 controller.
All clocks, source identities and results come from validated fixture data.
"""
from __future__ import annotations

from copy import deepcopy
from datetime import datetime
import hashlib
import json
import re

VERSION = 1
STATES = {'unknown', 'idle', 'requesting', 'streaming', 'tool-running',
          'retry-wait', 'disconnected', 'stopping', 'stopped'}
CATEGORIES = {'none', 'provider_transport', 'provider_quota', 'harness_source',
              'context_tool', 'code_defect', 'execution_failure'}
COUNTERS = ('received', 'unique', 'duplicates', 'dispatchRequests')
EFFECTS = ('vm', 'worker', 'provider', 'filesystemOutsideOutput')
ID = re.compile(r'[a-z][a-z0-9-]{0,63}\Z')
SHA = re.compile(r'[0-9a-f]{64}\Z')
REV = re.compile(r'[0-9a-f]{40}\Z')
PRIVATE = re.compile(
    r'(?i)(?:-----BEGIN [A-Z ]*PRIVATE KEY-----|'
    r'\b(?:sk-[a-z0-9_-]{12,}|gh[pousr]_[a-z0-9]{12,}|github_pat_[a-z0-9_]{12,}|AKIA[A-Z0-9]{16})\b|'
    r'\bbearer\s+\S+|(?:api[_-]?key|access[_-]?token|token|password|secret)\s*[=:]\s*\S+|'
    r'\b[a-z]:[\\/]|\\\\[^\\\s]+\\|(?:^|\s)/(?!/)[^\s]|file://)')


class EvidenceError(ValueError):
    """A fixture or its provenance is not safe/complete enough to replay."""


def require(condition, message):
    if not condition:
        raise EvidenceError(message)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'),
                      ensure_ascii=False, allow_nan=False).encode('utf-8')


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def _pairs(items):
    result = {}
    for key, value in items:
        require(key not in result, 'duplicate JSON key')
        result[key] = value
    return result


def loads(text):
    require(len(text) <= 2_000_000, 'JSON input exceeds limit')
    try:
        return json.loads(text, object_pairs_hook=_pairs,
                          parse_constant=lambda _: (_ for _ in ()).throw(EvidenceError('nonfinite JSON')))
    except (ValueError, RecursionError) as exc:
        raise EvidenceError('invalid JSON') from exc


def keys(value, expected):
    require(type(value) is dict and set(value) == set(expected.split()), 'schema fields mismatch')


def integer(value, minimum=0, maximum=2**53 - 1):
    require(type(value) is int and minimum <= value <= maximum, 'invalid integer')


def identifier(value):
    require(type(value) is str and ID.fullmatch(value) is not None, 'invalid identity')


def sha(value):
    require(type(value) is str and SHA.fullmatch(value) is not None, 'invalid SHA-256')


def privacy(value, depth=0):
    """Reject known leak signatures, not a universal secret detector or exporter."""
    require(depth <= 24, 'fixture nesting exceeds limit')
    if isinstance(value, dict):
        for key, child in value.items():
            privacy(key, depth + 1)
            privacy(child, depth + 1)
    elif isinstance(value, list):
        require(len(value) <= 1000, 'fixture list exceeds limit')
        for child in value:
            privacy(child, depth + 1)
    elif isinstance(value, str):
        require(len(value) <= 2048, 'fixture string exceeds limit')
        require(not PRIVATE.search(value), 'privacy sentinel detected')
        require(not value.startswith(('/', '~/', '~\\')), 'absolute/private path rejected')
        require(all(ord(c) >= 32 or c in '\n\t' for c in value), 'control character rejected')
    else:
        require(value is None or type(value) in (bool, int), 'non-JSON fixture value')


def validate_event(event, clock):
    keys(event, 'id origin epoch session at kind data view')
    for field in ('id', 'origin', 'epoch', 'session', 'view'):
        identifier(event[field])
    integer(event['at'], maximum=clock)
    data = event['data']
    if event['kind'] == 'observation':
        keys(data, 'state category')
        require(data['state'] in STATES and data['category'] in CATEGORIES, 'unknown observation')
        require(data['category'] != 'provider_transport' or data['state'] == 'disconnected', 'transport state mismatch')
        require(data['category'] != 'provider_quota' or data['state'] == 'retry-wait', 'quota state mismatch')
    elif event['kind'] == 'evidence':
        keys(data, 'tree importRoot exitCode report stdout supersedes')
        sha(data['tree'])
        require(type(data['importRoot']) is str and re.fullmatch(r'[a-z0-9_-]+(?:/[a-z0-9_-]+)*', data['importRoot']), 'invalid import root')
        integer(data['exitCode'], -2147483648, 2147483647)
        require(type(data['stdout']) is str, 'invalid stdout')
        if data['supersedes'] is not None:
            identifier(data['supersedes'])
        if data['report'] is not None:
            keys(data['report'], 'id sha256 committed')
            identifier(data['report']['id'])
            sha(data['report']['sha256'])
            require(type(data['report']['committed']) is bool, 'invalid committed flag')
    elif event['kind'] == 'candidate':
        keys(data, 'tree')
        sha(data['tree'])
    elif event['kind'] == 'dispatch-request':
        keys(data, 'action')
        require(data['action'] in ('start', 'resume', 'retry', 'infer'), 'unknown recorded action')
    else:
        raise EvidenceError('unsupported event kind')


def validate_fixture(fixture):
    privacy(fixture)
    keys(fixture, 'schemaVersion id kind source redaction observations evidenceIds supersedes clockMs staleAfterMs initial events expected')
    integer(fixture['schemaVersion'], VERSION, VERSION)
    identifier(fixture['id'])
    require(fixture['kind'] in ('synthetic', 'recorded'), 'missing synthetic/recorded label')
    source = fixture['source']
    keys(source, 'name version revision capturedAt method artifactSha256')
    for field in ('name', 'version', 'method'):
        require(type(source[field]) is str and bool(source[field].strip()), 'missing source metadata')
    require(type(source['revision']) is str and REV.fullmatch(source['revision']), 'missing source revision')
    try:
        require(source['capturedAt'].endswith('Z'), 'capture time must be UTC')
        datetime.fromisoformat(source['capturedAt'][:-1] + '+00:00')
    except (TypeError, AttributeError, ValueError) as exc:
        raise EvidenceError('invalid capture timestamp') from exc
    if fixture['kind'] == 'recorded':
        sha(source['artifactSha256'])
        require(bool(fixture['evidenceIds']), 'recorded fixture needs original artifact reference')
    else:
        require(source['artifactSha256'] is None, 'synthetic fixture must not impersonate a raw artifact')
    keys(fixture['redaction'], 'status recipe reviewer')
    require(fixture['redaction']['status'] == 'reviewed', 'publication review required')
    for field in ('recipe', 'reviewer'):
        require(type(fixture['redaction'][field]) is str and fixture['redaction'][field].strip(), 'missing redaction provenance')
    for field, pattern in [('observations', r'TRIO-FR-(?:0[1-9]|1[0-9]|20)'), ('evidenceIds', r'E(?:0[1-9]|1[0-7])')]:
        require(type(fixture[field]) is list and len(set(fixture[field])) == len(fixture[field]), 'duplicate research identity')
        require(all(type(v) is str and re.fullmatch(pattern, v) for v in fixture[field]), 'unknown research identity')
    integer(fixture['clockMs'])
    integer(fixture['staleAfterMs'], 1)
    keys(fixture['initial'], 'tree importRoot operatorIntent phase')
    sha(fixture['initial']['tree'])
    require(re.fullmatch(r'[a-z0-9_-]+(?:/[a-z0-9_-]+)*', fixture['initial']['importRoot']), 'invalid expected import root')
    require(fixture['initial']['operatorIntent'] == 'paused', 'replay initial intent must stay held')
    require(fixture['initial']['phase'] == 'candidate', 'unsupported initial phase')
    require(type(fixture['events']) is list and 0 < len(fixture['events']) <= 1000, 'empty/oversized event stream')
    for event in fixture['events']:
        validate_event(event, fixture['clockMs'])
    if fixture['supersedes'] is not None:
        keys(fixture['supersedes'], 'id sha256 reason')
        identifier(fixture['supersedes']['id'])
        sha(fixture['supersedes']['sha256'])
        require(bool(fixture['supersedes']['reason'].strip()), 'correction reason required')
    expected = fixture['expected']
    keys(expected, 'projection counters dispatchCount sideEffects')
    keys(expected['projection'], 'phase operatorIntent session lastKnownSession freshness tree evidenceStatus sourceCategory evidenceCategory evidenceHistory accepted')
    keys(expected['counters'], 'received unique duplicates dispatchRequests')
    for value in expected['counters'].values():
        integer(value)
    require(expected['projection']['accepted'] is False, 'replay cannot claim acceptance')
    integer(expected['dispatchCount'], 0, 0)
    keys(expected['sideEffects'], 'vm worker provider filesystemOutsideOutput')
    for value in expected['sideEffects'].values():
        integer(value, 0, 0)
    return fixture


def validate_corpus(corpus, manifest):
    keys(corpus, 'schemaVersion fixtures')
    integer(corpus['schemaVersion'], VERSION, VERSION)
    keys(manifest, 'schemaVersion hashAlgorithm fixtures originalArtifacts')
    integer(manifest['schemaVersion'], VERSION, VERSION)
    require(manifest['hashAlgorithm'] == 'sha256-canonical-json-v1', 'unknown hash algorithm')
    require(type(corpus['fixtures']) is list and 1 <= len(corpus['fixtures']) <= 1000, 'empty/oversized corpus')
    fixtures = {}
    for fixture in corpus['fixtures']:
        validate_fixture(fixture)
        require(fixture['id'] not in fixtures, 'duplicate fixture identity')
        fixtures[fixture['id']] = fixture
    require(type(manifest['fixtures']) is list and len(manifest['fixtures']) == len(fixtures), 'manifest membership mismatch')
    locked = {}
    for entry in manifest['fixtures']:
        keys(entry, 'id sha256')
        identifier(entry['id'])
        sha(entry['sha256'])
        require(entry['id'] not in locked and entry['id'] in fixtures, 'manifest duplicate/unknown fixture')
        require(digest(fixtures[entry['id']]) == entry['sha256'], 'fixture hash mismatch')
        locked[entry['id']] = entry['sha256']
    for fixture in fixtures.values():
        previous = fixture['supersedes']
        if previous is not None:
            require(previous['id'] != fixture['id'] and locked.get(previous['id']) == previous['sha256'], 'missing/changed original fixture')
            old = fixtures[previous['id']]
            require(len(fixture['events']) > len(old['events']) and fixture['events'][:len(old['events'])] == old['events'], 'correction must append to original events')
            require(fixture['initial'] == old['initial'], 'correction cannot rewrite initial identity')
        visited = set()
        current = fixture
        while current['supersedes'] is not None:
            require(current['id'] not in visited, 'correction cycle')
            visited.add(current['id'])
            current = fixtures[current['supersedes']['id']]
    return fixtures


class Replay:
    """Single fixture journal, deduped by origin/epoch/session/record, never endpoint."""
    def __init__(self, fixture):
        self.fixture = deepcopy(validate_fixture(fixture))
        self.cursor = 0
        self.seen = {}
        self.counters = dict.fromkeys(COUNTERS, 0)
        self.tree = fixture['initial']['tree']
        self.observation = None
        self.history = []
        self.effective = None
        self.last_at = -1

    def advance(self, count=None):
        end = len(self.fixture['events']) if count is None else self.cursor + count
        integer(end, self.cursor, len(self.fixture['events']))
        while self.cursor < end:
            event = self.fixture['events'][self.cursor]
            self._apply(event)
            self.cursor += 1
        return self.result()

    def _apply(self, event):
        key = tuple(event[k] for k in ('origin', 'epoch', 'session', 'id'))
        semantic = {k: v for k, v in event.items() if k != 'view'}
        fingerprint = digest(semantic)
        if key in self.seen:
            require(self.seen[key] == fingerprint, 'conflicting duplicate event')
            self.counters['received'] += 1
            self.counters['duplicates'] += 1
            return
        require(event['at'] >= self.last_at, 'out-of-order unique event')
        data = event['data']
        if event['kind'] == 'evidence':
            # Record IDs used by supersession are unique within this fixture journal.
            require(not any(row['id'] == event['id'] for row in self.history), 'ambiguous evidence identity')
            require((self.effective is None and data['supersedes'] is None) or
                    (self.effective is not None and data['supersedes'] == self.effective['id']),
                    'new evidence must explicitly supersede the effective record')
            status, category = 'valid', 'none'
            if data['tree'] != self.tree or data['importRoot'] != self.fixture['initial']['importRoot']:
                status, category = 'failed', 'harness_source'
            elif data['exitCode'] != 0:
                status, category = 'failed', 'execution_failure'
            elif data['report'] is None or not data['report']['committed']:
                status, category = 'unverified', 'missing_report'
            row = {'id': event['id'], 'status': status, 'category': category,
                   'tree': data['tree'], 'supersedes': data['supersedes']}
            self.history.append(row)
            self.effective = row
        elif event['kind'] == 'observation':
            self.observation = event
        elif event['kind'] == 'candidate':
            self.tree = data['tree']
        elif event['kind'] == 'dispatch-request':
            self.counters['dispatchRequests'] += 1
        self.last_at = event['at']
        self.seen[key] = fingerprint
        self.counters['received'] += 1
        self.counters['unique'] += 1

    def result(self):
        known = self.observation['data']['state'] if self.observation else 'unknown'
        freshness = 'unknown'
        source_category = self.observation['data']['category'] if self.observation else 'none'
        category = 'none'
        if self.observation:
            freshness = 'stale' if self.fixture['clockMs'] - self.observation['at'] > self.fixture['staleAfterMs'] else 'fresh'
        evidence_status = 'absent'
        if self.effective:
            evidence_status = self.effective['status']
            category = self.effective['category']
            if evidence_status == 'valid' and (self.effective['tree'] != self.tree or freshness == 'stale'):
                evidence_status, category = 'stale', 'stale_source'
        projection = {'phase': self.fixture['initial']['phase'], 'operatorIntent': 'paused',
                      'session': known if freshness == 'fresh' else 'unknown',
                      'lastKnownSession': known, 'freshness': freshness, 'tree': self.tree,
                      'evidenceStatus': evidence_status, 'sourceCategory': source_category, 'evidenceCategory': category,
                      'evidenceHistory': deepcopy(self.history), 'accepted': False}
        return {'projection': projection, 'counters': dict(self.counters), 'dispatchCount': 0,
                'sideEffects': dict.fromkeys(EFFECTS, 0)}

    def checkpoint(self):
        # Derived state is never trusted from disk. Rebuild the verified journal prefix.
        return {'schemaVersion': VERSION, 'fixtureSha256': digest(self.fixture),
                'consumed': self.cursor, 'prefixSha256': digest(self.fixture['events'][:self.cursor])}

    @classmethod
    def restore(cls, fixture, checkpoint):
        keys(checkpoint, 'schemaVersion fixtureSha256 consumed prefixSha256')
        integer(checkpoint['schemaVersion'], VERSION, VERSION)
        integer(checkpoint['consumed'], 0, len(fixture['events']))
        require(checkpoint['fixtureSha256'] == digest(fixture), 'checkpoint fixture mismatch')
        require(checkpoint['prefixSha256'] == digest(fixture['events'][:checkpoint['consumed']]), 'checkpoint prefix mismatch')
        result = cls(fixture)
        result.advance(checkpoint['consumed'])
        return result
