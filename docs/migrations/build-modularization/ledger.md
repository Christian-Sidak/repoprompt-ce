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
| ADR-07 | Focused-test executor | Proposed: Swift Build per-target bundles (`conductor test --module`) for test targets that do not depend on `RepoPromptApp`; native aggregate stays the default and CI path. Passes the §3.4 gate on the leaf slice; the agent-adjacent slice is pending (see P0.3) |

## Phase 0 progress

- [x] P0.1 retroactive timing baseline (structured conductor timing still open)
- [x] P0.2 prototype graph tool (index-store replacement still open)
- [ ] P0.3 focused-test executor bake-off — leaf slice (`RepoPromptMCPCoreTests`, candidates a vs b) done and passes the gate; still open: the workspace/agent-adjacent slice, candidates (c) xcodebuild and (d) local package, peak RSS, CI parity
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

**ADR-07 recommendation (leaf slice):** adopt (b) as the focused-test executor for test targets whose closure excludes `RepoPromptApp`, behind `dev-test MODULE=` (P1.3).
- It clears the §3.4/P0.3 gate: the median edit→owning-test time, excluding queue, is 77% lower (the gate is ≥ 30%), with no discovery loss.
- Keep the native aggregate as the default `FILTER` path and in CI until:
  1. the workspace/agent-adjacent slice repeats this result;
  2. module runs support Swift Testing (the helper path lists XCTest only);
  3. peak RSS and CI parity are measured.
- Candidates (c) xcodebuild per-module schemes and (d) local package were not measured. (b) already removes the app from the loop without new packaging, so (d) needs a separate justification under §3.4.
