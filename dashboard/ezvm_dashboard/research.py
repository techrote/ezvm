"""Offline traceability checks. Historical observations remain immutable proposals."""
from __future__ import annotations

import hashlib
from pathlib import Path

from .evidence import REV, digest, identifier, integer, keys, loads, privacy, require, sha

BASELINE = '20dfca35bdd2fc8eab0b5fc52ae1b612b14d0e5e'
ORIGINALS = {
    'docs/research/TRIO-2026-10/observations.json': 'd2ef3057d8f68fd6eacd0bdc097fd89c4d4fdec5',
    'docs/research/TRIO-2026-10/evidence-index.json': '3438550d210633cf6375f98c9dbe596b0f3a6942',
}


def git_blob(text):
    """Git text identity, with checkout CRLF normalized to LF (not a raw-file hash)."""
    content = text.replace('\r\n', '\n').encode('utf-8')
    return hashlib.sha1(b'blob ' + str(len(content)).encode('ascii') + b'\0' + content).hexdigest()


def validate_traceability(register, observations, evidence, catalog, fixtures):
    privacy(register)
    keys(register, 'schemaVersion study originalRevision findings')
    integer(register['schemaVersion'], 1, 1)
    require(register['study'] == 'TRIO-2026-10' and register['originalRevision'] == BASELINE, 'wrong study identity')
    original = {row['id']: row for row in observations['observations']}
    require(set(original) == {f'TRIO-FR-{i:02}' for i in range(1, 21)}, 'original study must contain all 20 observations')
    issues = {row['id']: row for row in catalog['issues']}
    sources = {row['id']: row for row in evidence['sources']}
    require(len(register['findings']) == 20, 'traceability needs 20 findings')
    seen = set()
    action_count = 0
    for row in register['findings']:
        keys(row, 'observationId classification findingStatus fixtureIds unresolvedReason actions')
        oid = row['observationId']
        require(oid in original and oid not in seen, 'missing/duplicate observation mapping')
        seen.add(oid)
        require(row['findingStatus'] == 'proposed', 'fixture tests do not resolve historical findings')
        require(row['classification'] in ('field-observation', 'hypothesis', 'provider-transport'), 'invalid finding classification')
        if oid == 'TRIO-FR-18':
            require(row['classification'] == 'hypothesis', 'unreproduced admission concern must stay a hypothesis')
        if oid == 'TRIO-FR-20':
            require(row['classification'] == 'provider-transport', 'transport must not be scored as model reasoning')
        require(type(row['unresolvedReason']) is str and row['unresolvedReason'].strip(), 'historical limitation required')
        require(type(row['fixtureIds']) is list and len(set(row['fixtureIds'])) == len(row['fixtureIds']), 'invalid coverage')
        require(set(row['fixtureIds']) <= set(fixtures), 'unknown fixture coverage')
        for fid in row['fixtureIds']:
            require(oid in fixtures[fid]['observations'], 'fixture does not name observation')
        actions = row['actions']
        require(type(actions) is list and len(actions) == len(original[oid]['proposed_actions']), 'missing proposed action')
        mapped = set()
        for action in actions:
            keys(action, 'issueId githubIssue retestCases state implementationRevision verification unresolvedReason')
            aid = action['issueId']
            require(aid in issues and aid not in mapped, 'unknown/duplicate issue mapping')
            mapped.add(aid)
            require(action['githubIssue'] == issues[aid]['githubIssue'], 'wrong GitHub issue link')
            require(type(action['retestCases']) is list and bool(action['retestCases']), 'missing retest cases')
            require(len(set(action['retestCases'])) == len(action['retestCases']) and set(action['retestCases']) <= set(issues[aid]['testCases']), 'unknown/duplicate retest case')
            require(action['state'] in ('proposed', 'implemented', 'verified'), 'unknown action state')
            require(type(action['unresolvedReason']) is str and action['unresolvedReason'].strip(), 'action scope/limitation required')
            if action['state'] == 'proposed':
                require(action['implementationRevision'] is None and action['verification'] is None, 'proposed action cannot claim execution')
            else:
                require(type(action['implementationRevision']) is str and REV.fullmatch(action['implementationRevision']), 'implemented action needs exact revision')
                if action['state'] == 'implemented':
                    require(action['verification'] is None, 'implemented is not verified')
                else:
                    check = action['verification']
                    keys(check, 'revision evidencePath sha256 scope')
                    require(check['revision'] == action['implementationRevision'], 'verification/source revision mismatch')
                    require(check['scope'] == 'synthetic-fixture-only', 'historical resolution not authorized')
                    require(type(check['evidencePath']) is str and check['evidencePath'].startswith('docs/research/TRIO-2026-10/retests/') and '..' not in check['evidencePath'] and '\\' not in check['evidencePath'], 'invalid evidence path')
                    sha(check['sha256'])
            action_count += 1
        require(mapped == set(original[oid]['proposed_actions']), 'action set changed')
    for fixture in fixtures.values():
        require(set(fixture['evidenceIds']) <= set(sources), 'unknown original evidence')
        if fixture['kind'] == 'recorded':
            require(fixture['source']['artifactSha256'] in {sources[e]['sha256'] for e in fixture['evidenceIds']}, 'recorded artifact hash mismatch')
        for oid in fixture['observations']:
            mapped = next(row for row in register['findings'] if row['observationId'] == oid)
            require(fixture['id'] in mapped['fixtureIds'], 'unmapped fixture observation')
    return {'observations': len(seen), 'actions': action_count, 'historicalFindingsResolved': 0}


def validate_receipt(content, reference, source_content, replay_hash, manifest_hash):
    require(type(content) is dict and content.get('schemaVersion') == 1, 'missing versioned verification receipt')
    require(content.get('scope') == 'synthetic-fixture-only' and content.get('status') == 'PASS', 'receipt scope/status mismatch')
    require(type(content.get('exitCode')) is int and content['exitCode'] == 0, 'receipt exit is not successful')
    require(content.get('sourceRevision') == reference['revision'], 'receipt source revision mismatch')
    require(source_content is not None and content.get('sourceContent') == source_content, 'receipt tested content differs from current implementation')
    require(replay_hash is not None and content.get('replaySha256') == replay_hash, 'receipt replay output mismatch')
    require(content.get('manifestSha256') == manifest_hash, 'receipt corpus manifest mismatch')
    require(content.get('audit', {}).get('forbiddenAttempts') == 0, 'receipt contains forbidden attempts')
    require(content.get('research', {}).get('historicalFindingsResolved') == 0, 'receipt claims historical resolution')


def validate_repository(root, manifest, fixtures, source_content=None, replay_hash=None):
    root = Path(root).resolve()
    require(manifest['originalArtifacts'] == [
        {'path': path, 'revision': BASELINE, 'gitBlob': blob}
        for path, blob in ORIGINALS.items()], 'immutable original references changed')
    originals = {}
    for path, expected in ORIGINALS.items():
        text = (root / path).read_text(encoding='utf-8')
        require(git_blob(text) == expected, 'historical original blob changed')
        originals[path] = loads(text)
    research = root / 'docs/research/TRIO-2026-10'
    register = loads((research / 'retest-map.json').read_text(encoding='utf-8'))
    catalog = loads((root / 'docs/programme/dashboard/catalog.json').read_text(encoding='utf-8'))
    result = validate_traceability(register, originals[next(iter(ORIGINALS))],
                                  originals[list(ORIGINALS)[1]], catalog, fixtures)
    for row in register['findings']:
        for action in row['actions']:
            receipt = action['verification']
            if receipt is not None:
                path = (root / receipt['evidencePath']).resolve()
                require(path.is_relative_to(research.resolve()), 'evidence path escapes research root')
                content = loads(path.read_text(encoding='utf-8'))
                require(digest(content) == receipt['sha256'], 'verification receipt hash mismatch')
                validate_receipt(content, receipt, source_content, replay_hash, digest(manifest))
    return result
