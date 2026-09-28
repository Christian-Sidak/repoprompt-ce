#!/usr/bin/env python3
"""Deterministic hosted CI runner for RepoPrompt CE XCTest suites."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable, Mapping, Optional, Sequence, TextIO

XCTEST_BUNDLE_GLOB = "*.xctest"
SANDBOX_MARKER_NAME = ".issue944-test-sandbox"
CommandExecutor = Callable[[Sequence[str], Optional[Path], Mapping[str, str]], int]


@dataclass(frozen=True)
class ShardSelection:
    suites: tuple[str, ...]
    method_loads: tuple[int, ...]


@dataclass(frozen=True)
class BundleSelection:
    package_bundle: Path | None
    target_bundles: Mapping[str, Path]
    xctest_binary: tuple[str, ...] | None


def parse_suite_methods(list_output: str) -> dict[str, tuple[str, ...]]:
    methods_by_suite: dict[str, set[str]] = {}
    for raw_line in list_output.splitlines():
        line = raw_line.strip()
        if "/" not in line:
            continue
        suite, method = line.split("/", 1)
        if not suite or not method:
            continue
        methods_by_suite.setdefault(suite, set()).add(line)
    return {
        suite: tuple(sorted(methods_by_suite[suite]))
        for suite in sorted(methods_by_suite)
    }


def list_suite_methods(
    swift_binary: str,
    cwd: Path | None,
) -> dict[str, tuple[str, ...]]:
    result = subprocess.run(
        [swift_binary, "test", "list"],
        check=True,
        capture_output=True,
        cwd=cwd,
        text=True,
    )
    return parse_suite_methods(result.stdout)


def validate_shard_args(shard_count: int, shard_index: int) -> None:
    if shard_count <= 0:
        raise ValueError("--shard-count must be greater than zero")
    if shard_index < 1 or shard_index > shard_count:
        raise ValueError("--shard-index must be between 1 and --shard-count")


def assign_suites_to_shards(
    method_counts: Mapping[str, int],
    shard_count: int,
) -> tuple[tuple[tuple[str, ...], ...], tuple[int, ...]]:
    if shard_count <= 0:
        raise ValueError("shard_count must be greater than zero")

    shards: list[list[str]] = [[] for _ in range(shard_count)]
    loads = [0 for _ in range(shard_count)]
    ordered_suites = sorted(
        method_counts.items(),
        key=lambda item: (-item[1], item[0]),
    )
    for suite, method_count in ordered_suites:
        if method_count <= 0:
            raise ValueError(f"discovered suite {suite} has no test methods")
        shard = min(range(shard_count), key=lambda index: (loads[index], index))
        shards[shard].append(suite)
        loads[shard] += method_count

    return (
        tuple(tuple(sorted(shard)) for shard in shards),
        tuple(loads),
    )


def select_shard(
    method_counts: Mapping[str, int],
    *,
    shard_count: int,
    shard_index: int,
) -> ShardSelection:
    validate_shard_args(shard_count, shard_index)
    shards, loads = assign_suites_to_shards(method_counts, shard_count)
    return ShardSelection(shards[shard_index - 1], loads)


def test_target_for_suite(suite: str) -> str:
    return suite.split(".", 1)[0]


def discover_test_bundles(
    swift_binary: str,
    cwd: Path | None,
) -> dict[str, Path]:
    try:
        result = subprocess.run(
            [swift_binary, "build", "--show-bin-path"],
            check=True,
            capture_output=True,
            cwd=cwd,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return {}

    bin_path = Path(result.stdout.strip())
    if not bin_path.is_dir():
        return {}
    return {
        path.name.removesuffix(".xctest"): path
        for path in sorted(bin_path.glob(XCTEST_BUNDLE_GLOB))
    }


def package_test_bundle(discovered: Mapping[str, Path]) -> Path | None:
    matches = [
        path
        for name, path in discovered.items()
        if name.endswith("PackageTests")
    ]
    return matches[0] if len(matches) == 1 else None


def target_bundles_for_suites(
    discovered: Mapping[str, Path],
    suites: Iterable[str],
) -> dict[str, Path]:
    targets = {test_target_for_suite(suite) for suite in suites}
    return {
        target: discovered[target]
        for target in sorted(targets)
        if target in discovered
    }


def xctest_binary_path() -> tuple[str, ...]:
    try:
        result = subprocess.run(
            ["xcrun", "--find", "xctest"],
            check=True,
            capture_output=True,
            text=True,
        )
        path = result.stdout.strip()
        if path:
            return (path,)
    except (OSError, subprocess.CalledProcessError):
        pass
    return ("xcrun", "xctest")


def resolve_bundle_selection(
    *,
    swift_binary: str,
    cwd: Path | None,
    suites: Sequence[str],
) -> BundleSelection:
    discovered = discover_test_bundles(swift_binary, cwd)
    if not discovered:
        return BundleSelection(None, {}, None)
    if len(discovered) == 1:
        return BundleSelection(next(iter(discovered.values())), {}, xctest_binary_path())

    package_bundle = package_test_bundle(discovered)
    if package_bundle is not None:
        return BundleSelection(package_bundle, {}, xctest_binary_path())

    target_bundles = target_bundles_for_suites(discovered, suites)
    missing_targets = sorted(
        {
            test_target_for_suite(suite)
            for suite in suites
            if test_target_for_suite(suite) not in target_bundles
        }
    )
    if missing_targets:
        raise ValueError(
            f"missing XCTest bundles for selected targets: {missing_targets}; "
            f"available bundles: {sorted(discovered)}"
        )
    return BundleSelection(None, target_bundles, xctest_binary_path())


def bundle_for_suite(
    suite: str,
    selection: BundleSelection,
) -> Path | None:
    if selection.package_bundle is not None:
        return selection.package_bundle
    return selection.target_bundles.get(test_target_for_suite(suite))


def command_for_suite(
    suite: str,
    *,
    swift_binary: str,
    bundle_selection: BundleSelection,
) -> tuple[str, ...]:
    bundle = bundle_for_suite(suite, bundle_selection)
    if bundle is not None:
        xctest_binary = bundle_selection.xctest_binary or ("xcrun", "xctest")
        return (*xctest_binary, "-XCTest", suite, str(bundle))
    return (swift_binary, "test", "--skip-build", "--filter", suite)


def isolated_suite_environment(
    sandbox_root: Path,
    suite: str,
    base_environment: Mapping[str, str] | None = None,
) -> dict[str, str]:
    digest = hashlib.sha256(suite.encode("utf-8")).hexdigest()[:16]
    suite_root = sandbox_root / digest
    home = suite_root / "home"
    temporary = suite_root / "tmp"
    config = suite_root / "config"
    cache = suite_root / "cache"
    data = suite_root / "data"
    for directory in (home, temporary, config, cache, data):
        directory.mkdir(parents=True, exist_ok=True)
    (suite_root / SANDBOX_MARKER_NAME).touch(exist_ok=True)

    environment = dict(base_environment or os.environ)
    environment.update(
        {
            "HOME": str(home),
            "CFFIXED_USER_HOME": str(home),
            "TMPDIR": str(temporary),
            "TMP": str(temporary),
            "TEMP": str(temporary),
            "XDG_CONFIG_HOME": str(config),
            "XDG_CACHE_HOME": str(cache),
            "XDG_DATA_HOME": str(data),
            "REPOPROMPT_TEST_SANDBOX_ROOT": str(suite_root),
            "NSUnbufferedIO": "YES",
        }
    )
    return environment


def execute_command(
    command: Sequence[str],
    cwd: Path | None,
    environment: Mapping[str, str],
) -> int:
    try:
        return subprocess.run(
            list(command),
            check=False,
            cwd=cwd,
            env=dict(environment),
        ).returncode
    except OSError as error:
        print(f"Unable to launch {command[0]}: {error}", file=sys.stderr)
        return 127


SWIFT_TESTING_IMPORT = re.compile(r"^\s*(?:@testable\s+)?import\s+Testing\b", re.MULTILINE)
XCTEST_HELPER_RELATIVE_PATH = Path("libexec/swift/pm/swiftpm-xctest-helper")
BundleTestLister = Callable[[Path, Mapping[str, str]], Optional[list[str]]]


def package_uses_swift_testing(root: Path) -> bool:
    """Direct XCTest execution would silently skip Swift Testing tests, so detect them."""
    tests_root = root / "Tests"
    if not tests_root.is_dir():
        return False
    for path in tests_root.rglob("*.swift"):
        try:
            if SWIFT_TESTING_IMPORT.search(path.read_text(encoding="utf-8", errors="ignore")):
                return True
        except OSError:
            return True
    return False


def xctest_helper_path(swift_binary: str) -> Path | None:
    try:
        result = subprocess.run(
            ["xcrun", "--find", swift_binary],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    swift_path = Path(result.stdout.strip())
    helper = swift_path.parent.parent / XCTEST_HELPER_RELATIVE_PATH
    return helper if helper.is_file() else None


def flatten_listed_tests(document: Mapping[str, object]) -> list[str]:
    """Flatten swiftpm-xctest-helper JSON into SwiftPM `Module.Class/method` specifiers."""
    specifiers: list[str] = []

    def is_leaf(node: object) -> bool:
        # Test methods carry no "tests" key; suites always do, even when empty ("tests": []).
        return isinstance(node, Mapping) and "tests" not in node

    def visit(node: Mapping[str, object]) -> None:
        children = node.get("tests")
        if not isinstance(children, list) or not children:
            return
        name = str(node.get("name", ""))
        if all(is_leaf(child) for child in children):
            specifiers.extend(f"{name}/{child.get('name')}" for child in children if child.get("name"))
            return
        for child in children:
            if isinstance(child, Mapping):
                visit(child)

    visit(document)
    return sorted(set(specifiers))


def helper_bundle_lister(helper: Path) -> BundleTestLister:
    def list_tests(bundle: Path, environment: Mapping[str, str]) -> Optional[list[str]]:
        with tempfile.TemporaryDirectory(prefix="rpce-test-list-") as directory:
            output = Path(directory) / "tests.json"
            try:
                subprocess.run(
                    [str(helper), str(bundle), str(output)],
                    check=True,
                    capture_output=True,
                    env=dict(environment),
                )
                return flatten_listed_tests(json.loads(output.read_text(encoding="utf-8")))
            except (OSError, subprocess.CalledProcessError, ValueError):
                return None

    return list_tests


def select_xctest_specifiers(specifiers: Sequence[str], test_filter: str | None) -> list[str] | None:
    """Apply SwiftPM `--filter` regex semantics; collapse fully selected suites.

    Returns None when the filter is not a valid Python regex so callers can fall back to SwiftPM.
    """
    if not test_filter:
        return ["All"] if specifiers else []
    try:
        pattern = re.compile(test_filter)
    except re.error:
        return None
    selected = [specifier for specifier in specifiers if pattern.search(specifier)]
    by_suite: dict[str, list[str]] = {}
    for specifier in specifiers:
        by_suite.setdefault(specifier.split("/", 1)[0], []).append(specifier)
    selected_set = set(selected)
    selectors: list[str] = []
    for suite in sorted(by_suite):
        methods = by_suite[suite]
        chosen = [method for method in methods if method in selected_set]
        if not chosen:
            continue
        if len(chosen) == len(methods):
            selectors.append(suite)
        else:
            selectors.extend(chosen)
    return selectors


def direct_xctest_command(
    *,
    swift_binary: str,
    cwd: Path | None,
    test_filter: str | None,
    environment: Mapping[str, str],
    lister: BundleTestLister | None = None,
    bundle_discovery: Optional[Callable[[str, Path | None], Mapping[str, Path]]] = None,
    xctest_binary: Optional[Callable[[], tuple[str, ...]]] = None,
) -> tuple[str, ...] | None:
    """Build the direct xctest invocation, or None when SwiftPM must run the tests.

    Running the built bundle directly avoids re-evaluating every package manifest under the
    sandboxed environment (the manifest cache is environment keyed) and the build re-plan that
    alternating `swift build` / `swift test` otherwise forces on the next job.
    """
    root = cwd or Path.cwd()
    if package_uses_swift_testing(root):
        return None
    discovered = (bundle_discovery or discover_test_bundles)(swift_binary, cwd)
    bundle = package_test_bundle(discovered) if discovered else None
    if bundle is None:
        return None
    if lister is None:
        helper = xctest_helper_path(swift_binary)
        if helper is None:
            return None
        lister = helper_bundle_lister(helper)
    specifiers = lister(bundle, environment)
    if specifiers is None:
        return None
    selectors = select_xctest_specifiers(specifiers, test_filter)
    if selectors is None:
        return None
    if not selectors:
        return ()
    binary = (xctest_binary or xctest_binary_path)()
    return (*binary, "-XCTest", ",".join(selectors), str(bundle))


def run_local_tests(
    *,
    swift_binary: str,
    cwd: Path | None,
    test_filter: str | None = None,
    test_product: str | None = None,
    executor: CommandExecutor = execute_command,
    direct_command: Callable[..., tuple[str, ...] | None] = direct_xctest_command,
) -> int:
    # Keep compilation and its caches outside the disposable runtime home.
    environment = dict(os.environ)
    status = executor((swift_binary, "build", "--build-tests"), cwd, environment)
    if status != 0:
        return status
    with tempfile.TemporaryDirectory(prefix="rpce-local-tests-") as directory:
        environment = isolated_suite_environment(Path(directory), "local", environment)
        command: tuple[str, ...] | None = None
        if test_product is None:
            command = direct_command(
                swift_binary=swift_binary, cwd=cwd, test_filter=test_filter, environment=environment,
            )
        if command == ():
            print("No matching test cases were run")
            return 0
        if command is None:
            command = (swift_binary, "test", "--skip-build")
            if test_product:
                command += ("--test-product", test_product)
            if test_filter:
                command += ("--filter", test_filter)
        return executor(command, cwd, environment)


MODULE_TEST_TARGET_PATTERN = re.compile(r"^[A-Za-z][A-Za-z0-9_]*Tests$")
MODULE_SCRATCH_PATH = Path(".build/swiftbuild")


def module_build_command(swift_binary: str, module: str) -> tuple[str, ...]:
    return (
        swift_binary, "build", "--build-system", "swiftbuild",
        "--scratch-path", str(MODULE_SCRATCH_PATH), "--product", module,
    )


def module_bundle_path(swift_binary: str, cwd: Path | None, module: str) -> Path | None:
    try:
        result = subprocess.run(
            [swift_binary, "build", "--build-system", "swiftbuild",
             "--scratch-path", str(MODULE_SCRATCH_PATH), "--show-bin-path"],
            check=True, capture_output=True, cwd=cwd, text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    bundle = Path(result.stdout.strip()) / f"{module}.xctest"
    if not bundle.is_absolute() and cwd is not None:
        bundle = cwd / bundle
    return bundle if bundle.is_dir() else None


def run_module_tests(
    *,
    swift_binary: str,
    cwd: Path | None,
    module: str,
    test_filter: str | None = None,
    executor: CommandExecutor = execute_command,
    bundle_locator: Callable[[str, Path | None, str], Path | None] = module_bundle_path,
    lister: BundleTestLister | None = None,
    xctest_binary: Optional[Callable[[], tuple[str, ...]]] = None,
) -> int:
    """Build only one test target's dependency closure and run its bundle directly.

    Native SwiftPM links every test target into one aggregate bundle, so a focused run always
    builds and links the whole package. The Swift Build engine emits one bundle per test target,
    which keeps a module's test loop independent of unrelated targets (plan P0.3/P1.3).
    """
    if not MODULE_TEST_TARGET_PATTERN.match(module):
        print(f"::error::--module must name a test target (got {module!r})")
        return 2
    environment = dict(os.environ)
    status = executor(module_build_command(swift_binary, module), cwd, environment)
    if status != 0:
        return status
    bundle = bundle_locator(swift_binary, cwd, module)
    if bundle is None:
        print(f"::error::built bundle for {module} was not found under {MODULE_SCRATCH_PATH}")
        return 2
    with tempfile.TemporaryDirectory(prefix="rpce-module-tests-") as directory:
        environment = isolated_suite_environment(Path(directory), module, environment)
        if lister is None:
            helper = xctest_helper_path(swift_binary)
            if helper is None:
                print("::error::swiftpm-xctest-helper is unavailable; cannot list module tests")
                return 2
            lister = helper_bundle_lister(helper)
        specifiers = lister(bundle, environment)
        if specifiers is None:
            print(f"::error::could not list tests in {bundle}")
            return 2
        selectors = select_xctest_specifiers(specifiers, test_filter)
        if selectors is None:
            print(f"::error::--filter is not a valid regular expression: {test_filter!r}")
            return 2
        if not selectors:
            print("No matching test cases were run")
            return 0
        binary = (xctest_binary or xctest_binary_path)()
        return executor((*binary, "-XCTest", ",".join(selectors), str(bundle)), cwd, environment)


def run_selected_suites(
    suites: Sequence[str],
    *,
    swift_binary: str,
    cwd: Path | None,
    bundle_selection: BundleSelection,
    sandbox_root: Path,
    executor: CommandExecutor = execute_command,
    output: TextIO = sys.stdout,
) -> int:
    for suite in suites:
        command = command_for_suite(
            suite,
            swift_binary=swift_binary,
            bundle_selection=bundle_selection,
        )
        environment = isolated_suite_environment(sandbox_root, suite)
        print(f"::group::{suite}", file=output, flush=True)
        print(f"sandbox={environment['REPOPROMPT_TEST_SANDBOX_ROOT']}", file=output)
        return_code = executor(command, cwd, environment)
        print("::endgroup::", file=output, flush=True)

        if return_code == 0:
            continue
        print(
            f"::error::{suite} failed with exit status {return_code}",
            file=output,
            flush=True,
        )
        return return_code or 1
    return 0


def print_selection_summary(
    *,
    selection: ShardSelection,
    suite_methods: Mapping[str, Sequence[str]],
    shard_count: int,
    shard_index: int,
    output: TextIO,
) -> None:
    method_count = sum(len(suite_methods[suite]) for suite in selection.suites)
    print(
        f"Selected test shard {shard_index}/{shard_count}: "
        f"{len(selection.suites)} suites, {method_count} methods; "
        f"all shard method loads={list(selection.method_loads)}",
        file=output,
    )


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run deterministic RepoPrompt CE XCTest suites."
    )
    parser.add_argument("--local", action="store_true", help="Build, then run sandboxed local tests with SwiftPM selection")
    parser.add_argument("--filter", dest="test_filter")
    parser.add_argument("--test-product")
    parser.add_argument("--module", help="Build and run only this test target (Swift Build engine)")
    parser.add_argument("--swift-binary", default="swift")
    parser.add_argument("--cwd", type=Path, default=None)
    parser.add_argument("--shard-count", type=int, default=1)
    parser.add_argument("--shard-index", type=int, default=1)
    args = parser.parse_args(argv)
    if args.local and (args.shard_count != 1 or args.shard_index != 1):
        parser.error("--local cannot be combined with sharding")
    if not args.local and (args.test_filter or args.test_product or args.module):
        parser.error("--filter, --test-product, and --module require --local")
    if args.module and args.test_product:
        parser.error("--module cannot be combined with --test-product")
    return args


def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    if args.local and args.module:
        return run_module_tests(
            swift_binary=args.swift_binary, cwd=args.cwd,
            module=args.module, test_filter=args.test_filter,
        )
    if args.local:
        return run_local_tests(
            swift_binary=args.swift_binary, cwd=args.cwd,
            test_filter=args.test_filter, test_product=args.test_product,
        )
    try:
        validate_shard_args(args.shard_count, args.shard_index)
        suite_methods = list_suite_methods(args.swift_binary, args.cwd)
    except ValueError as error:
        print(f"::error::{error}")
        return 2
    except subprocess.CalledProcessError as error:
        print(f"::error::swift test list failed with status {error.returncode}")
        if error.stdout:
            print(error.stdout, end="")
        if error.stderr:
            print(error.stderr, end="", file=sys.stderr)
        return error.returncode or 1

    selected_suites = tuple(sorted(suite_methods))
    method_counts = {
        suite: len(suite_methods[suite])
        for suite in selected_suites
    }
    try:
        selection = select_shard(
            method_counts,
            shard_count=args.shard_count,
            shard_index=args.shard_index,
        )
    except ValueError as error:
        print(f"::error::{error}")
        return 2

    print_selection_summary(
        selection=selection,
        suite_methods=suite_methods,
        shard_count=args.shard_count,
        shard_index=args.shard_index,
        output=sys.stdout,
    )
    if not selection.suites:
        return 0

    try:
        bundle_selection = resolve_bundle_selection(
            swift_binary=args.swift_binary,
            cwd=args.cwd,
            suites=selection.suites,
        )
    except ValueError as error:
        print(f"::error::{error}")
        return 2

    with tempfile.TemporaryDirectory(prefix="rpce-tests-") as directory:
        return run_selected_suites(
            selection.suites,
            swift_binary=args.swift_binary,
            cwd=args.cwd,
            bundle_selection=bundle_selection,
            sandbox_root=Path(directory),
        )


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
