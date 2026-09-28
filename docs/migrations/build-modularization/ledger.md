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
| ADR-07 | Focused-test executor | Open — P0.3 bake-off |

## Phase 0 progress

- [x] P0.1 retroactive timing baseline (structured conductor timing still open)
- [x] P0.2 prototype graph tool (index-store replacement still open)
- [ ] P0.3 focused-test executor bake-off
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
