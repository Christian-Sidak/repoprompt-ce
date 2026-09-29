#!/usr/bin/env python3
"""T0 move-audit, access-lift, and test-import tests in isolated Git fixtures."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import modularization_access_lift as access  # noqa: E402
import modularization_move_audit as audit  # noqa: E402
import modularization_retarget_test_imports as retarget  # noqa: E402


def write(root: Path, name: str, text: str) -> None:
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def git(root: Path, *args: str) -> None:
    subprocess.run(["git", *args], cwd=root, check=True, stdout=subprocess.DEVNULL)


class GitFixture(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        git(self.root, "init", "-q")
        git(self.root, "config", "user.email", "test@example.invalid")
        git(self.root, "config", "user.name", "Test")
        write(self.root, "Package.swift", '.target(name: "NewModule"),\n')
        write(self.root, "Sources/OldModule/Thing.swift", "internal struct Thing {\n    let value = 1\n}\n")
        write(self.root, "Sources/OldModule/Client.swift", "import OldModule\ninternal func client() {}\n")
        git(self.root, "add", ".")
        git(self.root, "commit", "-qm", "base")

    def commit(self) -> dict:
        git(self.root, "add", "-A")
        git(self.root, "commit", "-qm", "head")
        return audit.audit("HEAD^", "HEAD", self.root)

    def test_r100_move_and_json_manifest(self) -> None:
        target = self.root / "Sources/NewModule/Thing.swift"
        target.parent.mkdir(parents=True)
        (self.root / "Sources/OldModule/Thing.swift").rename(target)
        report = self.commit()
        self.assertEqual(report["violations"], [])
        self.assertEqual(report["moves"][0]["similarity"], 100)
        self.assertIn("manifest", json.loads(json.dumps(report)))

    def test_access_only_move_pairs_delete_and_add(self) -> None:
        (self.root / "Sources/OldModule/Thing.swift").unlink()
        write(self.root, "Sources/NewModule/Thing.swift", "package struct Thing {\n    let value = 1\n}\n")
        report = self.commit()
        self.assertEqual(report["violations"], [])
        self.assertEqual(report["moves"][0]["base_sha256"], report["moves"][0]["head_sha256"])

    def test_body_and_whitespace_changes_fail(self) -> None:
        (self.root / "Sources/OldModule/Thing.swift").unlink()
        write(self.root, "Sources/NewModule/Thing.swift", "package struct Thing {\n    let value = 2\n}\n")
        self.assertTrue(self.commit()["violations"])

    def test_modified_client_access_and_first_party_import_only(self) -> None:
        write(self.root, "Sources/OldModule/Client.swift", "import NewModule\npackage func client() {}\n")
        self.assertEqual(self.commit()["violations"], [])

    def test_modified_client_body_and_external_import_fail(self) -> None:
        write(self.root, "Sources/OldModule/Client.swift", "import Foundation\npackage func client() { print(1) }\n")
        self.assertTrue(self.commit()["violations"])

    def test_non_swift_and_discovery_parity(self) -> None:
        write(self.root, "README.md", "changed\n")
        report = self.commit()
        self.assertTrue(report["violations"])
        self.assertTrue(audit.audit("HEAD^", "HEAD", self.root, 10, 11)["violations"])

    def test_import_in_move_must_be_first_party(self) -> None:
        (self.root / "Sources/OldModule/Thing.swift").unlink()
        write(self.root, "Sources/NewModule/Thing.swift", "import Foundation\npackage struct Thing {\n    let value = 1\n}\n")
        self.assertTrue(self.commit()["violations"])

    def test_unchanged_external_import_in_move_passes(self) -> None:
        original = self.root / "Sources/OldModule/Thing.swift"
        original.write_text("import Foundation\n" + original.read_text())
        git(self.root, "add", ".")
        git(self.root, "commit", "-qm", "external import in base")
        target = self.root / "Sources/NewModule/Thing.swift"
        target.parent.mkdir(parents=True)
        original.rename(target)
        self.assertEqual(self.commit()["violations"], [])

    def test_cli_exit_and_json(self) -> None:
        (self.root / "Sources/OldModule/Thing.swift").rename(self.root / "Sources/OldModule/Other.swift")
        self.commit()
        destination = self.root / "report.json"
        result = subprocess.run([sys.executable, str(SCRIPT_DIR / "modularization_move_audit.py"),
                                 "--base", "HEAD^", "--json", str(destination), "--tests-before", "2",
                                 "--tests-after", "2"], cwd=self.root, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(destination.read_text())["violations"], [])


class NormalizationTests(unittest.TestCase):
    def test_access_head_only_and_whitespace_preserved(self) -> None:
        self.assertEqual(audit.normalize_access("@MainActor public struct Thing {}\n"),
                         "@MainActor struct Thing {}\n")
        self.assertEqual(audit.normalize_access("public  struct Thing {}\n"), " struct Thing {}\n")
        self.assertEqual(audit.normalize_access("let text = \"public struct Foo\"\n"),
                         "let text = \"public struct Foo\"\n")


class HelperTests(unittest.TestCase):
    def test_access_lift_unique_cross_module_and_dry_run(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write(root, "Sources/One/Thing.swift", "@MainActor internal struct Thing {}\n")
            write(root, "Sources/Two/Client.swift", "let thing = Thing()\n")
            log = f"{root}/Sources/Two/Client.swift:1:13: error: 'Thing' is inaccessible due to 'internal' protection level\n"
            changes, notes = access.proposals(log, root)
            self.assertEqual(notes, [])
            self.assertEqual(changes[root / "Sources/One/Thing.swift"], "@MainActor package struct Thing {}\n")
            self.assertEqual((root / "Sources/One/Thing.swift").read_text(), "@MainActor internal struct Thing {}\n")

    def test_access_lift_missing_scope_and_ambiguous_skip(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            write(root, "Sources/One/Foo.swift", "struct Foo {}\n")
            write(root, "Sources/Three/Foo.swift", "struct Foo {}\n")
            write(root, "Sources/Two/Client.swift", "let value = Foo()\n")
            changes, notes = access.proposals("Sources/Two/Client.swift:1:13: error: cannot find 'Foo' in scope\n", root)
            self.assertEqual(changes, {})
            self.assertEqual(len(notes), 1)
            (root / "Sources/Three/Foo.swift").unlink()
            changes, notes = access.proposals("Sources/Two/Client.swift:1:13: error: cannot find 'Foo' in scope\n", root)
            self.assertEqual(notes, [])
            self.assertEqual(changes[root / "Sources/One/Foo.swift"], "package struct Foo {}\n")

    def test_access_cli_dry_run_then_apply_in_git_fixture(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            git(root, "init", "-q")
            write(root, "Sources/One/Thing.swift", "internal struct Thing {}\n")
            write(root, "Sources/Two/Client.swift", "let value = Thing()\n")
            git(root, "add", ".")
            git(root, "-c", "user.email=test@example.invalid", "-c", "user.name=Test", "commit", "-qm", "base")
            log = root / "build.log"
            log.write_text("Sources/Two/Client.swift:1:13: error: 'Thing' is inaccessible due to 'internal' protection level\n")
            command = [sys.executable, str(SCRIPT_DIR / "modularization_access_lift.py"), str(log), "--root", str(root)]
            dry = subprocess.run(command, cwd=root, capture_output=True, text=True)
            self.assertEqual(dry.returncode, 0, dry.stderr)
            self.assertIn("+package struct Thing", dry.stdout)
            self.assertEqual((root / "Sources/One/Thing.swift").read_text(), "internal struct Thing {}\n")
            applied = subprocess.run(command + ["--apply"], cwd=root, capture_output=True, text=True)
            self.assertEqual(applied.returncode, 0, applied.stderr)
            self.assertEqual((root / "Sources/One/Thing.swift").read_text(), "package struct Thing {}\n")

    def test_retarget_cli_dry_run_then_apply_in_git_fixture(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            git(root, "init", "-q")
            write(root, "Sources/NewModule/Thing.swift", "struct Thing {}\n")
            write(root, "Tests/AppTests/ThingTests.swift", "@testable import RepoPromptApp\n")
            git(root, "add", ".")
            git(root, "-c", "user.email=test@example.invalid", "-c", "user.name=Test", "commit", "-qm", "base")
            path = root / "Tests/AppTests/ThingTests.swift"
            command = [sys.executable, str(SCRIPT_DIR / "modularization_retarget_test_imports.py"),
                       "--module", "NewModule", str(path)]
            dry = subprocess.run(command, cwd=root, capture_output=True, text=True)
            self.assertEqual(dry.returncode, 0, dry.stderr)
            self.assertIn("+@testable import NewModule", dry.stdout)
            self.assertEqual(path.read_text(), "@testable import RepoPromptApp\n")
            applied = subprocess.run(command + ["--apply"], cwd=root, capture_output=True, text=True)
            self.assertEqual(applied.returncode, 0, applied.stderr)
            self.assertEqual(path.read_text(), "@testable import NewModule\n")

    def test_test_import_retarget(self) -> None:
        before = "@testable import RepoPromptApp\nimport Foundation\n// @testable import RepoPromptApp\n"
        after = retarget.retarget(before, "NewModule")
        self.assertIn("@testable import NewModule\n", after)
        self.assertIn("// @testable import RepoPromptApp", after)


if __name__ == "__main__":
    unittest.main()
