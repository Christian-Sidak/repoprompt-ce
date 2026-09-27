# Headless MCP domain runtime M8 — reliability boundary for third-party consumers

Date: 2026-09-28

Base: `origin/main` at `dd1ca53e9c020f949615c5bf4616e70d286681e0`

M8 continues the M0–M7 program. It does not introduce a new runtime, catalog,
store, or server product. It finishes making the existing domain runtime and the
`repoprompt-mcp` transport shell the reliability boundary that a third-party MCP
host can depend on, and it records the evidence that gates any later change to
the default backend.

## Verified starting point

The following were verified against source at the base SHA before any change.

| Id | Finding | Evidence |
|---|---|---|
| C1 | App-backed proxy connects and handshakes before reading stdin and retries forever when the app socket is absent, refused, or `server_not_ready`. The host sees only its own startup timeout. | `BootstrapSocketProxy.start`, `MCPService.runTransport`, `CLIProxyRuntimePolicy.shouldRetry` |
| C2 | On a terminal proxy failure with unreplayable work, the helper exits (73) without answering outstanding host requests. No response synthesis exists. | `JSONRPCBridgeLedger.recordConnectionFailure` / `beginConnection`, `handleRuntimeError` |
| C3 | `MCPDomainHost` owns resource-admission controllers but `invoke` acquires no lease and applies no watchdog. Only the app adapter (`MCPConnectionManager`) composes lanes, leases, contracts, and `MCPToolExecutionWatchdog.execute`. Direct headless calls `domainHost.invoke` directly and renders every error as `String(describing:)`. | `MCPDomainHost.invoke`, `DirectHeadlessMCPService.installHandlers` |
| C4 | Headless `read_file`, `file_search`, `get_file_tree`, and `get_code_structure` run synchronously on the cooperative pool with no size or file-count bounds; `get_code_structure` with an empty selection enumerates every file. | `MCPDomainCanonicalWorkspaceService` |
| C9 | The deterministic bridge-ledger, host, watchdog, and direct-headless contract suites were removed in #908; the architecture doc still names them as validation owners. | `git show dbd9eeee` |

The domain runtime already provides the primitives M8 composes: per-connection
lane limiters (`MCPDomainConnectionCallLimiters`), resource admission
(`MCPDomainToolResourceAdmissionController`), deadlines
(`MCPDomainAdmissionDeadline`), execution contracts
(`MCPToolExecutionContractCatalog`), and the watchdog
(`MCPToolExecutionWatchdog`). M8 reuses them; it does not reimplement them.

## Consumer invariants

| # | Invariant |
|---|---|
| I1 | Every host request receives exactly one JSON-RPC response before the helper exits, unless the host's stdout is gone or a response for that id was already in delivery. |
| I2 | `initialize` receives a response or a typed error within a bounded startup budget whether or not the app is running. |
| I3 | Transport and execution failures carry a stable `code` and a `retryability` of `retryable`, `retry_after`, `indeterminate`, or `permanent`. |
| I4 | No mutation is replayed or re-executed by transport recovery. A request that may have reached the app and is not on the replay allowlist is reported `indeterminate`, never `retryable`. |
| I5 | Every direct-headless tool call is admitted through the same lanes, resource leases, and execution contracts as the app, and bounded calls settle within their declared deadline plus grace. |

## Milestones

Each milestone is committed only after its focused validation passes. A
milestone that cannot be validated is left uncommitted and reported as blocked.

### M8A — proxy startup budget and terminal settlement (I1, I2, I3, I4)

Scope: `Sources/RepoPromptMCP`, `Sources/RepoPromptShared/MCP`.

- Shared, additive failure contract: stable codes, retryability, and the JSON-RPC
  error frame used for synthesized settlement.
- Ledger API that claims every unanswered host-originated request exactly once at
  terminal time, excluding ids whose response is already in delivery.
- Terminal settlement: on any terminal proxy failure where the host's stdout is
  still usable, write one JSON-RPC error per unanswered host request, then exit
  with the unchanged exit code.
- Pre-session startup budget: until the first accepted bootstrap handshake, a
  bounded budget (default 20 s, `REPOPROMPT_MCP_STARTUP_TIMEOUT_SECONDS`, `0`
  restores the legacy unbounded wait) ends the retry loop, answers every pending
  host request with `app_unavailable`, and exits 73. A host that closes stdin
  during startup ends the helper cleanly. After the first accepted handshake the
  existing reconnect/replay policy is unchanged.
- Terminal records gain additive settlement counts.

Acceptance:

- Deterministic tests: ledger claim semantics (forwarded, write-uncertain,
  in-delivery exclusion, replayable classification, idempotence); settlement
  frame shape; a fake-app `runBridge` chaos case where the app closes with an
  unreplayable request and the host receives exactly one typed error; a
  replayable-only failure still reconnects without settlement; stdout-fault
  failures write nothing; startup budget with an absent socket answers
  `initialize` with `app_unavailable`.
- `repoprompt-mcp` builds; existing proxy/ledger/terminal-record tests pass.

### M8B — shared host invocation pipeline for direct headless (I3, I5)

Scope: `Sources/RepoPromptDomainRuntime`, `Sources/RepoPromptMCP`, the app's lane
mapping.

- Move the admission-class → connection-lane mapping into the domain runtime so
  the app and headless share one definition.
- Add a protocol-neutral invocation pipeline in the domain runtime that composes,
  in order: pre-admission policy, per-connection lane permit, resource lease,
  execution contract, watchdog for bounded contracts, and host invocation, and
  classifies failures into the shared failure contract with the same codes the
  app emits (`tool_execution_timeout`, `tool_execution_cleanup_unresponsive`,
  `tool_execution_connection_terminal`, …).
- Direct headless dispatches every call through that pipeline and renders typed
  errors.

Acceptance: deterministic domain-runtime tests prove the lane and lease bounds,
exactly-once lease release on success, error, and cancellation, watchdog
settlement with an injected clock, and typed classification; direct-headless
tests prove the pipeline is used end to end.

### M8C — bounded direct-headless read backends (I5, parity)

Scope: `MCPDomainCanonicalWorkspaceService`.

- Move blocking filesystem work off the cooperative pool (a dispatch queue) with
  cooperative cancellation propagated from the calling task.
- Bound reads to the app's default content-read limit (10,000,000 bytes), decode
  UTF-8 (BOM stripped) or BOM-marked UTF-16, and fail typed for oversized,
  undecodable, or non-regular files.
- Enumerate lazily, bounded at 200,000 files per call; `file_search` skips file
  content above the read limit and reports `skipped_large_files`, and reports
  `truncated` when the enumeration bound is reached. `get_file_tree` stops at
  20,000 lines with a truncation line.
- `get_code_structure` with no paths and an empty selection returns an empty result
  with a note instead of walking every root; explicit directories expand lazily up
  to 256 supported files and report `truncated`.

Acceptance: deterministic fixture tests (`MCPDomainCanonicalWorkspaceBoundsTests`)
for the read limit, BOM/binary decoding, oversized search content, and the
empty-selection and directory-expansion contracts.

Known parity gaps kept for the parity harness: headless enumeration honors hidden
and package-descendant skipping only, not `.gitignore` or the app's global ignore
defaults, and headless result shapes are JSON rather than the app's formatted text.

### M8D — restored deterministic contract coverage and documentation

Restore the deterministic parts of the removed validation owners that M8 relies
on, and correct `docs/architecture/headless-mcp-runtime.md` so validation owners
and host ownership claims match source.

### M8E — app tools/call hot path off the MainActor (first slice)

Every app-backed `tools/call` currently performs a `MainActor.run` hop to read the
window count and multi-window mode, including routing-bypass tools that only return
constants. A lock-protected nonisolated mirror published synchronously from
`WindowStatesManager.allWindows` replaces that hop. The mirror is updated inside the
same main-actor mutation that changes the window list, so it is never older than the
last completed window change. Only the process-wide manager publishes it. The live MCP-enabled
window authority checks later in routing (and connection binding) stay on the MainActor.

Evidence: conductor ticket `49833be6-c0b5-4d5f-96cd-57a48db9aaa2` —
`WindowRoutingCountMirrorTests` 2/2, `BindContextRoutingAuthorityTests` 4/4,
`PersistedMCPRoutingIdentityTests` 3/3; `conductor lint` passed. No live latency measurement
was taken; the benefit claimed is the removed queueing dependency, not a measured speedup.

### M8F — bounded answers for replayable requests while disconnected (I1)

After the first accepted session the proxy reconnects indefinitely, which is right for app
updates and restarts, but a replayable request in flight during a long absence was never
answered. Once the current disconnection exceeds
`REPOPROMPT_MCP_DISCONNECTED_REQUEST_TIMEOUT_SECONDS` (default 30, `0` = legacy), the proxy
claims forwarded replay-allowlisted requests other than `initialize`, answers each with a
retryable `transport_lost` error, and drops them from the replay cache. This runs only between
bridge runs, so the host's stdout has no other writer. The ledger claim is non-terminal, is
refused whenever reconnect is illegal (unreplayable work, pending transaction, response in
delivery), and records no tombstone, so the host may reuse the ids. `initialize` is excluded
because the initialize replay plan may still forward its response.

### M8G — local field-failure taxonomy

Proxy and app terminal records were written to the events directory but nothing read them, so
the split between app-unavailable, restart, host, and transport exits could not be measured.
`repoprompt-mcp diagnostics terminal-summary [--since-hours N]` prints a JSON summary with
record and undecodable counts, the time window, counts by layer, initiator and reason, records
with active or in-delivery requests, and host settlement totals. Reasons outside a short
`[a-z0-9_.-]` token set collapse to `other`; error descriptions, session fingerprints, process
identifiers, tool names, and paths are never emitted. The command is read-only and dispatches
before any app connection or service composition.

### M8H — retry guidance on the default app backend (I3)

App execution-contract failures rendered only `<code>: <message>` unless the client requested
raw JSON, so ordinary hosts of the default backend received no retry guidance. Those failures
now carry `retryability` (and the legacy `retryable` flag when it was missing). In default mode
one JSON line follows the first line with `retryability`, `retryable`, and, when known,
`retry_after_ms`, `mutation_state`, `operation_id`, and `settlement`; the code is not repeated.
Watchdog and protected-mutation failures derive retryability with
`MCPDomainToolFailureClassifier`, the same rules as direct headless; admission and routing codes
use a fixed table. A pre-existing legacy `retryable` flag stays authoritative, so guidance never
contradicts values existing clients already read. Codes without a classification keep the
legacy single-line text.

### M8I — typed selection prerequisites (#1071)

Seven selection-dependent app tools (`manage_selection`, `ask_oracle`, `oracle_send`,
`workspace_context` snapshot and export, `prompt` export, `get_code_structure` without paths, and
`get_file_tree` `selected`) threw `CancellationError` when the automatic-selection drain ended
`deferred` or `invalidated`, so hosts saw a generic cancellation. They now throw
`MCPSelectionPrerequisiteError`, rendered through the execution-contract path as
`tool_prerequisite_selection_deferred` or `tool_prerequisite_selection_invalidated`, retryable,
`mutation_state` `not_applied` (each drain runs before any mutation or export write). A drain that
ends `cancelled` still throws `CancellationError`.

### M8K — one authority for app global ignore defaults

Before headless ignore parity can follow a single source, the app itself had two: `app_settings`
wrote `fileSystem.globalIgnoreDefaults` in `globalSettings.json` (seeded with the canonical list),
while the crawl read the legacy `UserDefaults` value, so an `app_settings` change never reached
crawl or search. The crawl now reads the JSON value through `GlobalIgnoreDefaultsAuthority`,
published by `GlobalSettingsStore.shared` on load and on every write. A one-time migration carries
a customized legacy value into an uncustomized JSON value; an explicit JSON value always wins; the
legacy keys stay in place. Headless parity (shared matcher and a read-only view of this authority)
remains a separate, unstarted slice.

### M8L — shared gitignore compiler (no behavior change)

`GitignoreCompiler`, `PatternPool`, and the DEBUG-only `IgnoreDebugMetricsRecorder` it reports to
moved from the app into `RepoPromptDomainRuntime` (`package` access; the recorder keeps its
lock-guarded state and environment/defaults switches), and the gitignore C API (`repo_gitignore_match_anchored`,
`repo_gitignore_match_anywhere`, `repo_normalize_pattern`, `repo_parse_gitignore_line`,
`repo_gitignore_pattern`) is now declared once in the public `RepoPromptC/include/repo_gitignore.h`,
included by `wildmatch.h` (an existing module input, so warm clang module caches rebuild) and by
the C implementation and the app bridging header. The app keeps `IgnoreRules`,
`IgnoreRulePolicy`, and git-topology resolution. Headless enumeration does not apply any ignore
layer yet: explicit parity contract and the read-only authority view are the next slices.

### M8M — read-only headless view of the app ignore authority

- The `globalSettings.json` schema identity and load gate (`DomainGlobalSettingsSchema`: CE
  lineage, current version, rejected experimental v6, frozen unlineaged v1/v2 ceiling) and the
  canonical global ignore list (`DomainGlobalIgnoreDefaults`) moved into the domain runtime; the
  app's `GlobalSettingsDocument` constants and `GlobalSettingsFileStore.preservationBlockReason`
  delegate to them, so the app and headless trust exactly the same documents.
- `DomainGlobalIgnoreDefaultsView` reads `<storage>/Settings/globalSettings.json` (the app's file
  for the default profile; an isolated file for an explicit headless profile) and reports
  `settings`, `value_absent`, `file_missing`, or `blocked_<reason>` (`unreadable`,
  `incompatible_schema`, `unsupported_future_schema`, `invalid_value`). It never writes. A
  blocked document's value is never used; like the app's blocked load, the canonical list applies.
- Headless `app_settings` serves `file_system.global_ignore_defaults` from that view (re-read on
  every access), marks it `writable: false` with `authority: app` and `authority_status`, and
  rejects `set` with `appAuthorityReadOnly`. A value previously stored for this key in headless
  `direct-settings.json` is ignored but left in place. Other headless settings are unchanged.

Ignore-layer parity contract (what headless enumeration applies today versus the app):

| Layer | App crawl | Headless enumeration |
|---|---|---|
| `.git` exclusion | always | not applied (hidden-file skip only) |
| Root `.gitignore` | yes (mandatory floor in Git roots) | not applied |
| Nested `.gitignore` | yes when hierarchical ignores are on (default) | not applied |
| Global ignore defaults | `globalSettings.json` value (M8K) | value readable via M8M; not applied |
| `.repo_ignore` / `.cursorignore` | yes when enabled (default) | not applied |
| Symlinks | skipped by default | not governed by `skip_symlinks`; FileManager enumerator defaults (unverified) |

No row is claimed as parity until headless enumeration applies it with the shared compiler (M8L)
and a fixture test compares it with the app's result.

### Later milestones (not started in this pass)

- Remaining MainActor/GUI decoupling of the tier-0 read path (per-hop inventory first).
- Cross-backend app-versus-headless parity and latency harness.
- Live chaos matrix (app killed mid-request, restart during `initialize`), which
  requires explicit approval to stop or relaunch the visible app.

## Evidence (M8A–C)

- Focused suites: conductor ticket `e05b3335-9c78-4841-bb60-b3b62e42fa99` —
  `MCPDomainCanonicalWorkspaceBoundsTests` 5/5, `MCPDomainInvocationPipelineTests` 7/7,
  `MCPProxyHostSettlementTests` 13/13.
- Style: `conductor lint` ticket `ff57be55-0f61-49c8-91bd-fa13c8447d2b` passed (format-check
  and strict SwiftLint).
- `Scripts/headless_runtime_guardrails.sh` passed.
- Not validated: `make guardrails` could not run its SwiftPM manifest dump in the sandboxed
  environment (`sandbox_apply: Operation not permitted`); its source-layout report was
  derivative of that failure. No full root-suite run, live MCP smoke, or app relaunch was
  performed.

Findings made while validating:

- On Darwin a pipe whose writer closed reports readable-at-EOF rather than a guaranteed
  `POLLHUP`, so the startup closed-input probe counts pending bytes (`FIONREAD`) and treats
  readable-with-zero-pending as end of input; an ioctl failure falls back to the hang-up rule.
- The proxy logger was a top-level global in the executable's `main.swift`. Entry-file globals
  are initialized by top-level code, which never runs when the module is loaded in-process, so
  the startup retry path stalled on its first log call under XCTest. The logger now lives in an
  ordinary source file and initializes lazily in every host; production behavior is unchanged.

## Cutover gate

`app` remains the default backend and `auto` remains preview. M8 does not change
either. A default change requires the live chaos matrix, the parity and latency
harness, and packaged-release evidence listed above.
