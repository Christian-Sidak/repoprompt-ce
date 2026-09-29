#!/usr/bin/env python3
"""Fail-closed audit of mechanical Swift module moves between two Git revisions."""

from __future__ import annotations

import argparse
from collections import Counter
import difflib
import hashlib
import json
import re
import subprocess
from pathlib import Path

ALLOWED_NON_SWIFT = {
    "Package.swift",
    "Scripts/modularization/modules.json",
    "docs/architecture/modules.md",
    "Scripts/source_layout_guardrails.sh",
    "docs/migrations/build-modularization/ratchets.json",
    "docs/migrations/build-modularization/ledger.md",
    "Scripts/conductor.py",  # conductor module index
    "Scripts/generate_xcode_workspace.py",
}
IMPORT = re.compile(r"^\s*(?:(?:@testable|@preconcurrency|public|internal|package)\s+)*import\s+([A-Za-z_]\w*)(?:\.[A-Za-z_]\w*)?\s*$")
DECLARATION = re.compile(r"\b(?:struct|class|enum|protocol|actor|extension|func|var|let|typealias|init|subscript|associatedtype|operator|precedencegroup)\b")
ACCESS = re.compile(r"(?<![\w.])(?:open|public|package|internal)(?:[ \t])(?!\()")
PREFIX_TOKEN = re.compile(r"(?:@\w+(?:\([^)]*\))?|final|static|class|override|nonisolated|required|convenience|mutating|nonmutating|lazy|weak|unowned|open|public|package|internal|private|fileprivate)\s*")


def git(*args: str, cwd: Path | None = None) -> bytes:
    return subprocess.check_output(["git", *args], cwd=cwd, stderr=subprocess.PIPE)


def module_allowlist(base: str, head: str, cwd: Path) -> set[str]:
    modules: set[str] = set()
    for ref in (base, head):
        for root in ("Sources", "Tests"):
            paths = git("ls-tree", "-r", "--name-only", ref, "--", root, cwd=cwd).decode().splitlines()
            modules.update(path.split("/")[1] for path in paths if len(path.split("/")) > 2)
        try:
            package = git("show", f"{ref}:Package.swift", cwd=cwd).decode()
        except subprocess.CalledProcessError:
            continue
        modules.update(re.findall(r"\.(?:target|testTarget|executableTarget)\s*\(\s*name:\s*\"([A-Za-z_]\w*)\"", package))
    return modules


def normalize_access(line: str) -> str:
    """Remove only an access token in the head of a declaration, never body text."""
    declaration = DECLARATION.search(line)
    if not declaration:
        return line
    prefix = line[:declaration.start()]
    indentation = len(prefix) - len(prefix.lstrip(" \t"))
    rest = prefix[indentation:]
    offset = 0
    while offset < len(rest):
        match = PREFIX_TOKEN.match(rest, offset)
        if not match or match.end() == offset:
            return line
        offset = match.end()
    return ACCESS.sub("", prefix) + line[declaration.start():]


def normalized(data: bytes) -> str:
    lines = []
    for line in data.decode("utf-8").splitlines(keepends=True):
        if re.match(r"^\s*(?:@\w+\s+)*import\b", line):
            continue
        lines.append(normalize_access(line))
    return hashlib.sha256("".join(lines).encode()).hexdigest()


def import_delta_ok(left: bytes, right: bytes, modules: set[str]) -> bool:
    def imports(data: bytes) -> Counter[str]:
        return Counter(line for line in data.decode("utf-8").splitlines()
                       if re.match(r"^\s*(?:@\w+\s+)*import\b", line))

    before, after = imports(left), imports(right)
    for line in list((before - after)) + list((after - before)):
        match = IMPORT.fullmatch(line)
        if not match or match.group(1) not in modules:
            return False
    return True


def content(ref: str, path: str, cwd: Path) -> bytes:
    return git("show", f"{ref}:{path}", cwd=cwd)


def line_class_ok(base: str, head: str, path: str, modules: set[str], cwd: Path) -> bool:
    diff = git("diff", "--no-ext-diff", "-U0", f"{base}...{head}", "--", path, cwd=cwd).decode()
    hunks: list[tuple[list[str], list[str]]] = []
    old: list[str] = []
    new: list[str] = []
    for line in diff.splitlines(keepends=True):
        if line.startswith("@@"):
            if old or new:
                hunks.append((old, new))
            old, new = [], []
        elif line.startswith("-") and not line.startswith("---"):
            old.append(line[1:])
        elif line.startswith("+") and not line.startswith("+++"):
            new.append(line[1:])
    if old or new:
        hunks.append((old, new))

    def filtered(lines: list[str]) -> list[str] | None:
        result = []
        for line in lines:
            if re.match(r"^\s*(?:@\w+\s+)*import\b", line):
                match = IMPORT.fullmatch(line.rstrip("\r\n"))
                if not match or match.group(1) not in modules:
                    return None
            else:
                result.append(normalize_access(line))
        return result

    return all(filtered(before) is not None and filtered(before) == filtered(after) for before, after in hunks)


def audit(base: str, head: str, cwd: Path, before: int | None = None, after: int | None = None) -> dict:
    modules = module_allowlist(base, head, cwd)
    raw = git("diff", "--name-status", "-M100%", f"{base}...{head}", cwd=cwd).decode()
    changes = [line.split("\t") for line in raw.splitlines()]
    violations: list[str] = []
    moves: list[dict] = []
    manifest = [{"status": row[0], "paths": row[1:]} for row in changes]
    deleted: list[str] = []
    added: list[str] = []
    for row in changes:
        status, *paths = row
        if status.startswith("R"):
            source, target = paths
            if source.endswith(".swift") != target.endswith(".swift"):
                violations.append(f"{source} -> {target}: cross-type move")
                continue
            entry = {"from": source, "to": target, "similarity": int(status[1:])}
            if source.endswith(".swift"):
                left = content(base, source, cwd)
                right = content(head, target, cwd)
                entry["base_sha256"] = normalized(left)
                entry["head_sha256"] = normalized(right)
                if not import_delta_ok(left, right, modules):
                    violations.append(f"{source} -> {target}: non-first-party import edit")
                if entry["base_sha256"] != entry["head_sha256"]:
                    violations.append(f"{source} -> {target}: normalized hashes differ")
            elif source not in ALLOWED_NON_SWIFT or target not in ALLOWED_NON_SWIFT:
                violations.append(f"{source} -> {target}: non-Swift path not allowed")
            moves.append(entry)
        elif status == "D" and paths[0].endswith(".swift"):
            deleted.append(paths[0])
        elif status == "A" and paths[0].endswith(".swift"):
            added.append(paths[0])
        elif status == "M" and paths[0].endswith(".swift"):
            if not line_class_ok(base, head, paths[0], modules, cwd):
                violations.append(f"{paths[0]}: non-access/import edit")
        elif not all(path in ALLOWED_NON_SWIFT for path in paths):
            violations.append(f"{' -> '.join(paths)}: non-Swift path not allowed")
    available = set(added)
    for source in deleted:
        left = content(base, source, cwd)
        left_hash = normalized(left)
        candidates = []
        for target in sorted(available):
            right = content(head, target, cwd)
            if normalized(right) == left_hash:
                candidates.append(target)
        if not candidates:
            violations.append(f"{source}: deleted Swift file has no normalized-equal addition")
            continue
        target = candidates[0]
        available.remove(target)
        right = content(head, target, cwd)
        head_hash = normalized(right)
        if not import_delta_ok(left, right, modules):
            violations.append(f"{source} -> {target}: non-first-party import edit")
        moves.append({"from": source, "to": target, "similarity": round(100 * difflib.SequenceMatcher(None, left, right).ratio()),
                      "base_sha256": left_hash, "head_sha256": head_hash})
    for target in sorted(available):
        violations.append(f"{target}: added Swift file has no normalized-equal deletion")
    if before is not None and before < 0 or after is not None and after < 0:
        violations.append("test discovery counts must be nonnegative")
    if (before is None) != (after is None):
        violations.append("both --tests-before and --tests-after are required")
    elif before is not None and before != after:
        violations.append(f"test discovery changed: {before} -> {after}")
    return {"base": base, "head": head, "manifest": manifest, "moves": moves,
            "tests_before": before, "tests_after": after, "violations": violations}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--json", type=Path)
    parser.add_argument("--tests-before", type=int)
    parser.add_argument("--tests-after", type=int)
    args = parser.parse_args()
    try:
        report = audit(args.base, args.head, Path.cwd(), args.tests_before, args.tests_after)
    except (subprocess.CalledProcessError, UnicodeDecodeError) as exc:
        parser.error(str(exc))
    print(f"Move audit: {args.base}...{args.head}")
    for move in report["moves"]:
        print(f"  {move['similarity']}% {move['from']} -> {move['to']}")
        if "base_sha256" in move:
            print(f"    normalized SHA-256: {move['base_sha256']} / {move['head_sha256']}")
    for violation in report["violations"]:
        print(f"  VIOLATION: {violation}")
    print(f"Result: {'FAIL' if report['violations'] else 'PASS'} ({len(report['moves'])} moves, {len(report['violations'])} violations)")
    if args.json:
        args.json.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 1 if report["violations"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
