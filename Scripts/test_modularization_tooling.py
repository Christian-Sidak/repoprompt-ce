#!/usr/bin/env python3
"""Catalog, placement, test routing, affected-target, and CI-gate unit tests."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import modularization_affected_tests as affected  # noqa: E402
import modularization_ci_build as ci_build  # noqa: E402
import modularization_modules as modules  # noqa: E402
import modularization_test_target as target  # noqa: E402


def fixture(root: Path) -> tuple[dict, dict]:
    rows = {
        'RepoPromptApp': {'source_root': 'Sources/RepoPrompt', 'allowed_dependencies': ['Core'],
                          'test_target': 'RepoPromptTests'},
        'Core': {'source_root': 'Sources/Core', 'allowed_dependencies': [],
                 'test_target': 'CoreTests', 'app_free_tests': True},
        'CoreTests': {'source_root': 'Tests/CoreTests', 'allowed_dependencies': ['Core']},
        'RepoPromptTests': {'source_root': 'Tests/RepoPromptTests', 'allowed_dependencies': ['RepoPromptApp']},
    }
    catalog = {'modules': rows, 'moved_families': {'Core': {
        'owner': 'Core', 'former_app_roots': ['Sources/RepoPrompt/Infrastructure/Core'],
        'former_app_files': ['Sources/RepoPrompt/Infrastructure/OldCore.swift'],
    }}}
    package = {'targets': [{'name': name, 'path': row['source_root'],
                            'dependencies': [{'byName': [dependency]} for dependency in row['allowed_dependencies']]}
                           for name, row in rows.items()]}
    for row in rows.values():
        (root / row['source_root']).mkdir(parents=True, exist_ok=True)
    (root / 'Scripts/modularization').mkdir(parents=True, exist_ok=True)
    (root / 'Scripts/modularization/modules.json').write_text(json.dumps(catalog))
    return package, catalog


class CatalogTests(unittest.TestCase):
    def test_allowed_edges_imports_and_new_file_placement(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package, catalog = fixture(root)
            (root / 'Sources/Core/Core.swift').write_text('import Foundation\n')
            with mock.patch.object(modules, 'added_swift_paths', return_value=set()):
                self.assertEqual(modules.check(root, package, catalog), [])
                (root / 'Sources/Core/Core.swift').write_text('import RepoPromptApp\n')
                self.assertTrue(any('undeclared first-party import' in error
                                    for error in modules.check(root, package, catalog)))
            with mock.patch.object(modules, 'added_swift_paths', return_value={
                'Sources/RepoPrompt/Infrastructure/Core/New.swift'
            }):
                self.assertTrue(any('new Swift source belongs in Core' in error
                                    for error in modules.check(root, package, catalog)))

    def test_owning_test_closure_must_exclude_app(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package, catalog = fixture(root)
            catalog['modules']['CoreTests']['allowed_dependencies'].append('RepoPromptApp')
            with mock.patch.object(modules, 'added_swift_paths', return_value=set()):
                self.assertTrue(any('transitively build RepoPromptApp' in error
                                    for error in modules.check(root, package, catalog)))

    def test_filter_resolves_only_exact_app_free_suite(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            _, catalog = fixture(root)
            (root / 'Tests/CoreTests/FeatureTests.swift').write_text('final class FeatureTests {}\n')
            (root / 'Tests/RepoPromptTests/AppTests.swift').write_text('final class AppTests {}\n')
            self.assertEqual(target.resolve(root, 'FeatureTests/testOne'), 'CoreTests')
            self.assertIsNone(target.resolve(root, 'AppTests'))
            self.assertIsNone(target.resolve(root, 'Feature.*'))
            self.assertEqual(affected.select(root, ['Sources/Core/Core.swift'], catalog), ['CoreTests'])
            self.assertEqual(affected.select(root, ['Package.swift'], catalog), ['CoreTests'])

    def test_ci_typecheck_warning_classification(self) -> None:
        warning = '/checkout/Sources/RepoPrompt/App/X.swift:3:4: warning: expression took 502ms to type-check'
        self.assertEqual(ci_build.classify_warning(warning), ('expression', 502))
        self.assertIsNone(ci_build.classify_warning(warning.replace('Sources/RepoPrompt/', 'Sources/Core/')))


if __name__ == '__main__':
    unittest.main()
