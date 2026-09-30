#!/usr/bin/env python3
"""One clean CI build of root test bundles with import and type-check ratchets."""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

from modularization_ci_artifact import SWIFT_TESTING_IMPORT, test_source_hashes

ROOT = Path(__file__).resolve().parent.parent
BASELINE = ROOT / 'docs/migrations/build-modularization/build-ratchets.json'
APP_WARNING = re.compile(r'(?:^|[/ ])(Sources/RepoPrompt/[^:\n]+\.swift):(\d+):(\d+): warning: (.+)')
DURATION = re.compile(r'\b(\d+)ms\b')


def classify_warning(line: str) -> tuple[str, int, tuple[str, str, str, str]] | None:
    match = APP_WARNING.search(line)
    if not match:
        return None
    message = match.group(4)
    duration = DURATION.search(message)
    if not duration or 'type-check' not in message:
        return None
    kind = 'expression' if 'expression' in message.lower() else 'function_body'
    return kind, int(duration.group(1)), match.groups()


def record_warning(
    line: str,
    counts: dict[str, int],
    seen: set[tuple[str, str, str, str]],
) -> None:
    warning = classify_warning(line)
    if not warning:
        return
    kind, duration, key = warning
    if duration < (1000 if kind == 'function_body' else 500) or key in seen:
        return
    seen.add(key)
    counts[kind] += 1


def main() -> int:
    baseline = json.loads(BASELINE.read_text(encoding='utf-8'))['typecheck']
    command = [
        'swift', 'build', '--build-tests', '--explicit-target-dependency-import-check', 'error',
        '-Xswiftc', '-Xfrontend', '-Xswiftc', '-warn-long-function-bodies=999',
        '-Xswiftc', '-Xfrontend', '-Xswiftc', '-warn-long-expression-type-checking=499',
    ]
    counts = {'function_body': 0, 'expression': 0}
    seen: set[tuple[str, str, str, str]] = set()
    print('$ ' + ' '.join(command), flush=True)
    process = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, bufsize=1)
    assert process.stdout is not None
    for line in process.stdout:
        print(line, end='', flush=True)
        record_warning(line, counts, seen)
    code = process.wait()
    if code:
        return code
    print(f'type-check ratchet: app bodies >=1000ms {counts["function_body"]}/{baseline["function_bodies_1000ms"]}; '
          f'expressions >=500ms {counts["expression"]}/{baseline["expressions_500ms"]}', flush=True)
    if counts['function_body'] > baseline['function_bodies_1000ms'] or counts['expression'] > baseline['expressions_500ms']:
        print('type-check ratchet regressed', file=sys.stderr)
        return 1
    if any(SWIFT_TESTING_IMPORT.search(path.read_text(encoding='utf-8', errors='ignore'))
           for path in (ROOT / 'Tests').rglob('*.swift')):
        print('CI shard direct XCTest runner cannot run Swift Testing; add a separate runner before introducing it',
              file=sys.stderr)
        return 1
    listing = subprocess.run(['swift', 'test', 'list', '--skip-build'], cwd=ROOT,
                             capture_output=True, text=True)
    if listing.returncode:
        print(listing.stderr, file=sys.stderr)
        return listing.returncode
    if not any('/' in line for line in listing.stdout.splitlines()):
        print('test listing is empty after build; refusing to publish CI artifact', file=sys.stderr)
        return 1
    destination = ROOT / '.build/modularization/ci-test-list.txt'
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(listing.stdout, encoding='utf-8')
    (destination.parent / 'test-source-sha256.json').write_text(
        json.dumps({'source_sha256': test_source_hashes(ROOT)}, sort_keys=True) + '\n', encoding='utf-8')
    print(f'captured {len(listing.stdout.splitlines())} test-list lines at {destination}', flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
