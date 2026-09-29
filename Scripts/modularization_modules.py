#!/usr/bin/env python3
"""Validate the first-party module catalog, allowed edges, imports, and placement."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = Path('Scripts/modularization/modules.json')
IMPORT = re.compile(r'^\s*(?:@testable\s+)?import\s+([A-Za-z_][A-Za-z_0-9]*)\b', re.M)


def added_swift_paths(root: Path) -> set[str]:
    """New files in the PR range and working tree; clean main has no PR additions."""
    base = subprocess.run(
        ['git', 'merge-base', 'HEAD', 'origin/main'], cwd=root,
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    changed = subprocess.run(
        ['git', 'diff', '--name-status', '-M', base], cwd=root,
        capture_output=True, text=True, check=True,
    ).stdout.splitlines()
    result = set()
    for line in changed:
        fields = line.split('\t')
        if fields[0].startswith(('A', 'R', 'C')):
            result.add(fields[-1])
    untracked = subprocess.run(
        ['git', 'ls-files', '--others', '--exclude-standard'], cwd=root,
        capture_output=True, text=True, check=True,
    ).stdout.splitlines()
    result.update(untracked)
    return {path for path in result if path.endswith('.swift')}


def check(root: Path, package: dict, catalog: dict) -> list[str]:
    errors: list[str] = []
    modules = catalog['modules']
    targets = {target['name']: target for target in package['targets']}
    if set(modules) != set(targets):
        errors.append(f"catalog target drift: missing {sorted(set(targets)-set(modules))}; removed {sorted(set(modules)-set(targets))}")
    for name, entry in modules.items():
        target = targets.get(name)
        if target is None:
            continue
        if entry['source_root'] != target.get('path'):
            errors.append(f"{name}: source root changed from {entry['source_root']} to {target.get('path')}")
        declared = {dependency['byName'][0] for dependency in target.get('dependencies', []) if 'byName' in dependency}
        allowed = set(entry['allowed_dependencies'])
        if declared != allowed:
            errors.append(f"{name}: direct edges {sorted(declared)} do not match allowed {sorted(allowed)}")
        if entry.get('app_free_tests'):
            test_target = entry.get('test_target')
            if not test_target or test_target not in modules:
                errors.append(f"{name}: app-free owning test target missing")
            else:
                pending = [test_target]
                seen = set()
                while pending:
                    current = pending.pop()
                    if current in seen:
                        continue
                    seen.add(current)
                    pending.extend(modules.get(current, {}).get('allowed_dependencies', []))
                if 'RepoPromptApp' in seen:
                    errors.append(f"{name}: owning tests transitively build RepoPromptApp")
        source_root = root / entry['source_root']
        if not source_root.is_dir():
            continue
        for path in source_root.rglob('*.swift'):
            for imported in IMPORT.findall(path.read_text(encoding='utf-8', errors='replace')):
                if imported in targets and imported != name and imported not in declared:
                    errors.append(f"{path.relative_to(root)}: undeclared first-party import {imported}")
    added = added_swift_paths(root)
    for family, entry in catalog.get('moved_families', {}).items():
        owner = entry['owner']
        if owner not in modules:
            errors.append(f"{family}: unknown owner {owner}")
        for path in sorted(added):
            if path in entry.get('former_app_files', []) or any(
                path.startswith(old.rstrip('/') + '/') for old in entry.get('former_app_roots', [])
            ):
                errors.append(f"{family}: new Swift source belongs in {owner}, not {path}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT)
    args = parser.parse_args()
    root = args.root.resolve()
    catalog = json.loads((root / CATALOG).read_text(encoding='utf-8'))
    package = json.loads(subprocess.check_output(['swift', 'package', 'dump-package'], cwd=root, text=True))
    errors = check(root, package, catalog)
    for error in errors:
        print(f'modules: {error}', file=sys.stderr)
    if errors:
        return 1
    print(f'modules: {len(catalog["modules"])} target rows and placement rules ok')
    return 0


if __name__ == '__main__':
    sys.exit(main())
