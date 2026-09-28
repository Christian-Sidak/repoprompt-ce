# Build Modularization Ledger

Living record for [`../build-modularization-2026-09-28.md`](../build-modularization-2026-09-28.md). Each slice adds its manifest, evidence, timings, and ratchet deltas. Entries are marked superseded rather than erased.

## Tooling

| Tool | Purpose | Plan item |
| --- | --- | --- |
| `Scripts/modularization_metrics.py report [--details]` | Architecture metrics: app size and share, god files, singletons, triage dependency graph (wrong-way edges, largest cycle), test coupling | P0.2 (regex prototype; index-store replacement pending) |
| `Scripts/modularization_metrics.py check` / `update` | Ratchet gate (run by `make guardrails`) and baseline refresh | P0.7 |
| `Scripts/conductor_job_timings.py` | Retroactive queue-wait and net job-duration percentiles from conductor logs | P0.1 (structured in-conductor timing pending) |

Self-tests: `make conductor-selftest` (includes `test_modularization_metrics.py` and `test_conductor_job_timings.py`).

## Ratchet policy

- **Gated** (CI fails on any increase): `app_files_over_5000_lines`, `app_static_shared_declarations`, `app_largest_cycle_components`, `tests_sleep_calls`. Ordinary feature work never needs to worsen these.
- **Tracked** (reported, not gated): `app_target_swift_lines`, `app_files_over_2000_lines`, `app_shared_accessor_uses`, `app_userdefaults_standard_uses`, `app_wrong_way_file_edges`, `tests_testable_import_app_files`. Each is promoted to gated when its wave provides an alternative home (a module or an injection seam), or, for wrong-way edges, when the index-store graph replaces the regex graph.
- Lower a baseline with `update` in the slice that improves it. Raising one requires `update --allow-regression` plus a justification entry here.

## Baseline — 2026-09-28 (`589cecc5`)

Metrics: [`ratchets.json`](ratchets.json). App target: 1,160 files, 648,091 lines, 88.3% of first-party Swift; 17 files over 5k lines; 102 singleton declarations and 1,220 `.shared` uses; 1,102 wrong-way edges; largest cycle 67 of 75 components.

Conductor timings (last 3,000 jobs, net of queue):

| Category | n | p50 | p90 |
| --- | --- | --- | --- |
| Heavy-slot wait | 1,383 | < 1 s | 8.8 min |
| Focused test, nothing compiled | 131 | 2.2 min | 10.1 min |
| Focused test, tests recompiled | 44 | 3.0 min | 9.0 min |
| Focused test, app recompiled | 46 | 4.7 min | 11.1 min |
| Package, app recompiled | 19 | 13.2 min | 60.1 min |

**Correction:** the first draft of the plan reported a heavy-slot wait of p50 12.3 min, because an ad-hoc parser read `739ms` as minutes. The tested parser shows that 75% of jobs are admitted immediately, 295 waited at least a minute, and 22 waited over an hour. The plan text has been corrected.

## Decisions

| ID | Decision | Status |
| --- | --- | --- |
| ADR-01 | Root-package targets first; separate packages only past the §3.4 gate | Accepted (plan) |
| ADR-07 | Focused-test executor | Accepted (2026-09-28): Swift Build per-target bundles (`conductor test --module`) for test targets whose closure excludes `RepoPromptApp`, including Swift Testing; native aggregate stays the default `FILTER` path, the path for app-dependent targets, and the CI path. Passed the gate on both P0.3 slices (77% and 95% lower median edit→test, no discovery loss) |

## Phase 0 progress

- [x] P0.1 retroactive timing baseline (structured conductor timing still open)
- [x] P0.2 prototype graph tool (index-store replacement still open)
- [x] P0.3 focused-test executor bake-off — gate holds on both slices (`RepoPromptMCPCoreTests` 77%, `RepoPromptDomainRuntimeTests` 95%); ADR-07 accepted. Not measured, not blockers: candidates (c) and (d), CI parity of module runs (CI stays on the aggregate)
- [x] P0.4 fixed per-job overhead root cause and fix (see below)
- [ ] P0.5 link and type-check levers
- [ ] P0.6 compatibility inventory golden tests
- [x] P0.7 ratchets file and guardrail gate

## P0.4 — fixed per-job overhead (2026-09-28)

The "no-op relink" hypothesis was wrong. A no-change focused `dev-test` spent about 75 s (41 s "build" plus a slow `swift test`) because of two causes:

1. **Per-job environment defeats SwiftPM's caches.** SwiftPM keys its manifest cache on the full process environment, since manifests can read it (this `Package.swift` does). Conductor exported a unique `REPOPROMPT_CONDUCTOR_JOB_TICKET` to every job, so each build re-evaluated every package manifest and re-planned: 28–31 s no-op versus 0.7 s with a stable environment (reproduced directly).
2. **Test execution through SwiftPM.** `swift test --skip-build` ran in the sandboxed environment, which again missed the manifest cache (26–36 s for a 7 ms test with any single sandbox variable changed). Alternating `swift build` and `swift test` also forced the next build to re-plan (about 10–15 s).

Fixes:

- `Scripts/conductor.py`: the job ticket is exported only to conductor's own `__operation_runner`, which pops it on entry (`capture_job_ticket`); readers use `current_job_ticket()`. SwiftPM-facing commands now see a stable, allowlisted environment.
- `Scripts/ci_app_test_runner.py` local path: build with SwiftPM, list tests with the toolchain's `swiftpm-xctest-helper`, apply `--filter` with SwiftPM's regex-search semantics (whole suites collapsed), then run the bundle directly with `xctest` inside the same sandbox.
  - It falls back to `swift test --skip-build` when `--test-product` is given, when any test imports Swift Testing, when the bundle or helper is unavailable, or when the filter is not a valid Python regex.
  - Parity: the helper and `swift test list` report the same 3,599 tests, with no differences.

Measured through conductor (focused filter `RepoPromptRegexCoreTests`, 7 tests):

| Scenario | Before | After |
| --- | --- | --- |
| Nothing changed | 74.7 s | **2.2 s** (build 0.6 s) |
| One app file touched, body only (1 file compiled) | — | 41 s |
| One unused top-level `func` added to the app (interface change) | — | 246 s (6 app files and **all 370 test files** recompiled; build 168 s) |

The interface-change row is the monolith cost that per-module test targets must remove: any interface change to `RepoPromptApp` recompiles the entire `@testable` test target.

Follow-up: in the interface-change job about 78 s of execution happened outside SwiftPM (conductor build-cache handling). It is about 1.5 s on no-op jobs. Investigate under P0.1.

## P0.3 focused-test executor — leaf slice (2026-09-28)

Candidates:
- **(a) native aggregate**: `conductor test --filter RepoPromptMCPCoreTests`. It builds the package test graph and runs the one `RepoPromptCEPackageTests.xctest`.
- **(b) Swift Build per target**: `conductor test --module RepoPromptMCPCoreTests` (commit `02d97447`). It runs `swift build --build-system swiftbuild --scratch-path .build/swiftbuild --product RepoPromptMCPCoreTests`, lists the bundle with `swiftpm-xctest-helper`, and runs it directly with `xctest` in the sandbox.

Method:
- The probe edits were made in `Sources/RepoPromptMCPCore/MCPReplayState.swift`:
  - **body:** `replayFrames()` rewritten to an equivalent `let` plus `return`;
  - **interface:** an unused top-level `func` appended;
  - **revert:** the file restored, which is a second interface change.
- Each scenario ran once per path, from the same warm state. All probes are reverted.
- Times come from conductor job JSON:
  - `exec` is `executionSeconds`. It starts after global heavy admission, so queue and heavy-slot waits (up to 35 min here, because other checkouts held the slot) are excluded.
  - `pre-test` is process start to the first `Test Suite … started` line.
  - `build` is the build tool's own `Build complete!` time.

| Scenario | Path | Ticket | exec | pre-test | build | What was rebuilt |
| --- | --- | --- | --- | --- | --- | --- |
| Cold (new scratch path) | b | `60a66da1` | 651.5 s | 569.4 s | 321.5 s | Dependency resolve/fetch (~227 s) plus the full closure: 57 targets, no `RepoPromptApp` |
| No-op | b | `18a5de6d` | 81.8 s | 40.1 s | 19.1 s | Nothing compiled; Swift Build re-plans (1,888 planning steps) |
| No-op (warm) | a | `107a8bca` | 76.2 s | 22.1 s | 3.3 s | Nothing |
| Body edit | b | `f10b33bf` | **41.3 s** | **22.0 s** | 12.0 s | `RepoPromptMCPCore` plus the module bundle link |
| Body edit | a | `2a706f79` | 114.5 s | 84.4 s | 66.9 s | 1 file, then relinks `repoprompt-mcp` and the aggregate bundle (app included) |
| Interface edit | b | `edd41ba4` | **61.3 s** | **34.0 s** | 24.2 s | `RepoPromptMCPCore`, `RepoPromptMCPCoreTests` |
| Interface edit | a | `5e3f5b83` | 210.5 s | 193.3 s | 116.1 s | MCPCore, the MCP executable, and **360 `RepoPromptTests` files** (two app tests `@testable import RepoPromptMCPCore`), then the aggregate link |
| Revert (interface) | b | `9d0e7019` | **48.1 s** | **26.7 s** | 18.0 s | As for the interface edit |
| Revert (interface) | a | `48397249` | 389.8 s | 356.9 s | 166.9 s | As for the interface edit |

Medians over the three edit scenarios:

| Metric | (a) aggregate | (b) module | Reduction |
| --- | --- | --- | --- |
| exec (edit → tests finished, excluding queue) | 210.5 s | 48.1 s | 77% |
| pre-test (edit → first test starts) | 193.3 s | 26.7 s | 86% |
| build tool only | 116.1 s | 18.0 s | 84% |

Findings:

- **App exclusion.** No (b) log contains `Compiling RepoPromptApp` or `Compiling RepoPromptTests`. The Swift Build target list never includes `RepoPromptApp`; the cold closure is 57 targets, mostly tree-sitter, NIO, and collections through DomainRuntime and CodeMapCore.
- **Discovery parity.**
  - `swiftpm-xctest-helper` lists 66 tests in 9 suites from `RepoPromptMCPCoreTests.xctest`.
  - That equals the 66 `func test…` declarations in `Tests/RepoPromptMCPCoreTests` and the 66 that path (a) executes for the same filter.
  - The target has no Swift Testing tests.
  - Every run in both paths passed 66/66.
- **No swiftbuild blockers** on this package with Swift 6.3.3 / Xcode 26.5 SDK. The only diagnostics were the existing `-Wshorten-64-to-32` warnings in the tree-sitter Python scanner.
- **Where the win comes from.**
  - Interface changes no longer recompile the app test target.
  - Body edits no longer relink the aggregate bundle.
  - Module runs also skip conductor's seeded `.build` cache handling. On path (a), 17–190 s per edit job ran outside SwiftPM (pre-test minus build), which is the same unexplained overhead as the P0.4 follow-up.
- **Costs of (b):**
  - A no-op costs about 18 s more before tests start, because Swift Build re-plans every invocation (19 s versus 3 s).
  - The first run in a worktree resolves and fetches dependencies again (~227 s) and builds the closure from scratch.
  - `.build/swiftbuild` is 5.4 GB for this one closure, against 4.2 GB for the whole native `.build/arm64-apple-macosx`. Disk and a cold start are the price of a second scratch path until §5.5 shares caches.
- **Noise.** Test execution for the same 66 tests ranged from 17 s to 82 s. That target's `DirectHeadlessOracleGroupTests` is timing-sensitive, and other checkouts were building concurrently. `pre-test` is the cleaner comparison; each row is one sample.

**ADR-07 recommendation (leaf slice; superseded by the decision in the next section):** adopt (b) as the focused-test executor for test targets whose closure excludes `RepoPromptApp`, behind `dev-test MODULE=` (P1.3).
- It clears the §3.4/P0.3 gate: the median edit→owning-test time, excluding queue, is 77% lower (the gate is ≥ 30%), with no discovery loss.
- Keep the native aggregate as the default `FILTER` path and in CI until:
  1. the workspace/agent-adjacent slice repeats this result;
  2. module runs support Swift Testing (the helper path lists XCTest only);
  3. peak RSS and CI parity are measured.
- Candidates (c) xcodebuild per-module schemes and (d) local package were not measured. (b) already removes the app from the loop without new packaging, so (d) needs a separate justification under §3.4.

## P0.3 focused-test executor — agent-adjacent slice, Swift Testing, and decision (2026-09-28)

### Swift Testing in `--module` runs

The invocation was derived from SwiftPM 6.3.3 on a throwaway package with XCTest and Swift Testing tests. `swiftpm-testing-helper --help` prints nothing, and `swift test --build-system swiftbuild -v` does not print the test commands, so the argument vectors and environment were captured with `ps` while `swift test` ran:

- **XCTest:** `xctest [-XCTest <selectors>] <T>.xctest` with `SWIFT_TESTING_ENABLED=0`. Without that variable `xctest` also hosts the Swift Testing tests. Our first real-repo run hit exactly this and ran them twice.
- **Swift Testing:** `swiftpm-testing-helper --test-bundle-path <T>.xctest/Contents/MacOS/<T> --build-system swiftbuild [--filter F] <same path> --testing-library swift-testing`.
  - `DYLD_FRAMEWORK_PATH` and `DYLD_LIBRARY_PATH` must point at the platform's Developer frameworks. Without them the helper cannot `dlopen` the bundle (`@rpath/XCTest.framework` not found).
- **Order and exit status:** both libraries always run, XCTest first. The run fails if either fails. Swift Testing's exit 69 (no tests matched) counts as success, as in `swift test`.

`Scripts/ci_app_test_runner.py` now does the same in `--module` runs whenever a file under `Tests/<Target>` imports Testing (commit `145862db`).
- **Detection:** `sources_import_swift_testing`, which the aggregate path's `package_uses_swift_testing` now also uses (over `Tests/`).
- **Filter equivalence:**
  - Swift Testing receives `--filter` verbatim, as SwiftPM forwards it, so its selection is identical by construction.
  - XCTest selection matches the helper's listing with Python `re`, whereas SwiftPM uses ICU. The runner therefore accepts only a portable subset: literals, escaped punctuation, `.`, `*`, `+`, `?`, `|`, anchors, plain groups, and simple classes.
  - Anything else fails closed: `--module` exits 2 before building, and the aggregate direct path falls back to `swift test`.
- **Other fail-closed cases (exit 2):** `Tests/<Target>` is missing; or the target imports Testing but the helper or the platform path is unavailable.
- **Unit tests:** 7 new cases in `Scripts/test_ci_app_test_runner.py` cover:
  - argument vectors and environments;
  - exit-code mapping;
  - both libraries running after an XCTest failure;
  - a Swift Testing–only selection;
  - the fail-closed paths and portable filters;
  - the shared detection.
- **End to end on this repo,** with a temporary two-test `@Suite` in `Tests/RepoPromptDomainRuntimeTests` (removed afterwards):
  - unfiltered: 258 XCTest plus 2 Swift Testing tests, each run once (`28a964b4`);
  - `--filter 'P03SwiftTestingProbe|DomainAgentRunExecutionContractsTests'`: 5 plus 2 (`75ece559`).

No first-party test target imports Testing today.

### Second slice: `RepoPromptDomainRuntimeTests`

This is the workspace/agent domain: agent-session links, worktree bindings, Oracle groups, and workspace activation.
- In `Package.swift` the test target depends only on `RepoPromptDomainRuntime` and the `MCP` product.
- `RepoPromptDomainRuntime` depends on `RepoPromptShared`, `RepoPromptWorkspaceCore`, `RepoPromptC`, `RepoPromptCodeMapCore`, `Logging`, and `MCP`.
- No path reaches `RepoPromptApp`.

Method: the same as the leaf slice, with these specifics.
- **Probe file:** `Sources/RepoPromptDomainRuntime/ArrayExtensions.swift`.
  - **body:** `chunked(into:)` computes its reserve capacity through a `let`;
  - **interface:** an unused top-level `func` appended;
  - **revert:** `git checkout`, a second interface change.
- **Order:** in each scenario (b) ran first, then (a), from the same source state. One sample per path per scenario.
- **Metrics:** `exec`, `pre-test`, and `build` are defined as before. Heavy-slot waits (up to 6 min 15 s here) are excluded.
- **What was rebuilt:**
  - for (a), from the native `Compiling`/`Linking` lines;
  - for (b), from index-store units and object/product mtimes in `.build/swiftbuild`, because Swift Build prints no per-file lines.

| Scenario | Path | Ticket | exec | pre-test | build | What was rebuilt |
| --- | --- | --- | --- | --- | --- | --- |
| Warm-up | b | `5b0dc819` | 89.0 s | 71.9 s | 52.2 s | The test target (the Swift Testing probe had just been removed) |
| Warm-up | a | `ae2e90f5` | 46.3 s | 35.3 s | 22.7 s | Nothing |
| No-op | b | `14dd4be9` | 22.1 s | 13.6 s | 6.3 s | Nothing; Swift Build re-plans |
| No-op | a | `e389e5ca` | 7.7 s | 3.7 s | 1.1 s | Nothing |
| Body edit | b | `64abd3ff` | **15.5 s** | **13.1 s** | 7.7 s | `ArrayExtensions.o`, the prelinked `RepoPromptDomainRuntime.o`, the module bundle |
| Body edit | a | `59e607e0` | 72.6 s | 64.0 s | 53.0 s | All 86 `RepoPromptDomainRuntime` files; relinks `repoprompt-mcp`, the `RepoPrompt` app executable, and the aggregate bundle |
| Interface edit | b | `c49b5a2a` | **86.1 s** | **80.8 s** | 68.6 s | 81 of 86 DomainRuntime files, all 20 test files, the bundle |
| Interface edit | a | `273905ca` | 866.6 s | 859.3 s | 530.0 s | DomainRuntime 81, MCPCore 32, MCP 1, MCPCoreTests 9, DomainRuntimeTests 2, **`RepoPromptApp` 1,142 and `RepoPromptTests` 360 files**; the same three links |
| Revert (interface) | b | `b8df4df5` | **33.5 s** | **30.5 s** | 25.4 s | As for the interface edit |
| Revert (interface) | a | `b31cf893` | 665.1 s | 662.6 s | 558.6 s | As for the interface edit |

Medians over the three edit scenarios:

| Metric | (a) aggregate | (b) module | Reduction |
| --- | --- | --- | --- |
| exec (edit → tests finished, excluding queue) | 665.1 s | 33.5 s | 95% |
| pre-test (edit → first test starts) | 662.6 s | 30.5 s | 95% |
| build tool only | 530.0 s | 25.4 s | 95% |

Findings:

- **App exclusion.** No (b) log mentions `RepoPromptApp`, and `.build/swiftbuild` contains no `RepoPromptApp` artifacts. On (a), any `RepoPromptDomainRuntime` interface change recompiles the whole app (1,142 files), because the app imports the module, plus 360 app test files.
- **Discovery parity.**
  - `swiftpm-xctest-helper` lists 258 tests in 20 suites from `RepoPromptDomainRuntimeTests.xctest`.
  - That equals the 258 `func test…()` declarations in `Tests/RepoPromptDomainRuntimeTests`.
  - Every run in both paths executed 258 with 0 failures.
- **Noise.** The (b) interface (86 s) and revert (34 s) runs rebuilt the same files; each row is one sample.
- **Unattributed gap on (a).** It spent 11–329 s between `Build complete!` and the first test. This is not conductor's cache publication, which runs after the tests. The gap is unattributed, like the leaf-slice and P0.4 follow-ups.
- **Costs of (b).**
  - A no-op starts tests about 10 s later (Swift Build re-plans: 6.3 s versus 1.1 s).
  - `.build/swiftbuild` is 5.5 GB now that it covers both slices (5.4 GB after the leaf slice), next to 4.2 GB for `.build/arm64-apple-macosx`.
- **Cold start.** Not re-measured, because the scratch path was already warm from the leaf slice, which shares the DomainRuntime closure. This target's first build there (`0c42dc38`, with the Swift Testing probe) took 159 s exec and a 65.6 s build.

### Peak RSS

Method:
- **Sampler:** a local script (`.build/p03-rss/rss_sampler.py`, not committed) polled `ps -axww -o pid=,ppid=,rss=,args=` every 0.5 s while the job ran. It is read-only and sends no signals.
- **Root process:** the job's `ci_app_test_runner.py`, matched on this worktree's absolute script path plus `--local --module …` or `--local --filter …`, so jobs from other checkouts cannot match.
- **Aggregation:** each sample sums RSS over the root's descendant tree.
- **Build service:** the sampler also looked for a `SWBBuildService` outside the tree. None appeared: SwiftPM 6.3.3 runs Swift Build in-process in `swift-build`.
- **Caveats:**
  - the tree sum counts shared pages once per process, so it is an upper bound;
  - 0.5 s sampling can miss short compiler peaks, so single-process figures are lower bounds.
- **Runs sampled:** the interface-edit rows, the heaviest edit scenario.

| Run | Ticket | Samples | Peak tree RSS | Processes at peak | Largest single processes |
| --- | --- | --- | --- | --- | --- |
| (b) module, interface edit | `c49b5a2a` | 77 | 1,553 MiB | 10 | `swift-build` 313, `ld` 263, `swift-frontend` 237 MiB |
| (a) aggregate, interface edit | `273905ca` | 860 | 3,856 MiB | 15 | `dsymutil` 2,070, `ld` 1,988, `swift-frontend` 1,153, `swift-driver` 596 MiB |

(a) peaked 55 s into the app recompile, with parallel `swift-frontend` jobs. Its largest single processes are the app and aggregate link and dSYM steps, which (b) never runs.

### ADR-07 decision

Gate: at least 30% lower median edit→owning-test time excluding queue, and no discovery loss.

| Slice | Median exec, (a) → (b) | Reduction | Discovery (helper = declared = executed) |
| --- | --- | --- | --- |
| Leaf: `RepoPromptMCPCoreTests` | 210.5 s → 48.1 s | 77% | 66 = 66 = 66 |
| Agent-adjacent: `RepoPromptDomainRuntimeTests` | 665.1 s → 33.5 s | 95% | 258 = 258 = 258 |

**Accepted.**
- **Adopted executor:** Swift Build per-target bundles (`conductor test --module`), for test targets whose closure excludes `RepoPromptApp`. P1.3 surfaces it as `dev-test MODULE=`.
- **Unchanged paths:** the native aggregate stays the default `FILTER` path, the path for targets that depend on the app, and the CI path.
- **Preconditions met:**
  - Swift Testing is supported (above).
  - Release builds and packaging are untouched (still native SwiftPM), so the §3.4 clean-build clause is unaffected.
- **Not adopted:** candidates (c) xcodebuild per-module schemes and (d) a local package were not measured. (b) already takes the app out of the loop without new packaging or generated schemes, and (d) would still need its own §3.4 justification.
- **Costs accepted:**
  - a no-op about 10 s slower;
  - a second scratch path (5.5 GB) with a one-time cold resolve and build per worktree, until §5.5 shares caches.
- **Follow-ups, not blockers:**
  - CI parity for module runs (CI stays on the aggregate);
  - the unattributed post-build gap on (a) (P0.1);
  - cross-worktree cache sharing (§5.5).
