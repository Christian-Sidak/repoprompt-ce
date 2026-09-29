#!/usr/bin/env python3
"""Scan first-party Swift imports, including access and attribute prefixes."""

from __future__ import annotations

import argparse
import re
from pathlib import Path

# Attributes and access modifiers may precede `import` in Swift. Keep the scan
# line-based so a comment or unrelated declaration cannot supply a prefix.
IMPORT = re.compile(
    r'^[ \t]*(?:(?:@[A-Za-z_]\w*(?:\([^\n)]*\))?|'
    r'(?:public|internal|private|fileprivate|package))[ \t]+)*'
    r'import[ \t]+(?:(?:typealias|struct|class|enum|protocol|let|var|func)[ \t]+)?'
    r'([A-Za-z_]\w*)\b',
    re.M,
)
UI_MODULES = frozenset({'AppKit', 'SwiftUI'})


def imported_modules(source: str) -> list[str]:
    return IMPORT.findall(source)


def forbidden_ui_imports(roots: list[Path]) -> list[str]:
    violations = []
    for root in roots:
        if not root.is_dir():
            continue
        for path in sorted(root.rglob('*.swift')):
            for number, line in enumerate(path.read_text(encoding='utf-8', errors='replace').splitlines(), 1):
                if UI_MODULES.intersection(imported_modules(line)):
                    violations.append(f'{path}:{number}: {line.strip()}')
    return violations


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--forbid-ui', action='store_true', required=True)
    parser.add_argument('roots', nargs='+', type=Path)
    args = parser.parse_args()
    violations = forbidden_ui_imports(args.roots)
    for violation in violations:
        print(violation)
    return 1 if violations else 0


if __name__ == '__main__':
    raise SystemExit(main())
