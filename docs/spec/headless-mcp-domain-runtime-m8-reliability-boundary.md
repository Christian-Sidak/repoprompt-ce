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
`MCPSelectionPrerequisiteError` through `MCPServerViewModel.requireReadFileAutoSelectionPrerequisite`
(#1081), rendered through the execution-contract path under the #1081 codes
`selection_prerequisite_deferred` or `selection_prerequisite_invalidated`, retryable, `mutation_state`
`not_applied` (each drain runs before any mutation or export write). The #1081 description already
leads with the code, so default-mode text carries it once and raw JSON keeps it in both `code` and
`error`. A task cancellation observed after the drain, or a drain that ends `cancelled`, still throws
`CancellationError`.

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
  blocked document's value is never used and the canonical list applies. Since M14 the app's
  blocked load instead keeps its legacy `UserDefaults` value, which this file-only view cannot
  read, so the two can differ while the settings file is blocked (documented divergence).
- Headless `app_settings` serves `file_system.global_ignore_defaults` from that view (re-read on
  every access), marks it `writable: false` with `authority: app` and `authority_status`, and
  rejects `set` with `appAuthorityReadOnly`. A value previously stored for this key in headless
  `direct-settings.json` is ignored but left in place. Other headless settings are unchanged.

Ignore-layer parity contract: see the M8N table below, which supersedes the pre-M8N state
(headless applied no ignore layer).

### M8N — shared ignore-layer engine and headless ignore enumeration

- `IgnoreRules`, `IgnoreRulesSnapshot`, `IgnoreRuleAuthority`, and `IgnoreRulePolicy` moved into
  the domain runtime with no behavior change. The Git-root payload is the domain
  `IgnoreRepositoryRootPrefix`, which now owns prefix validation; the app's
  `GitRepositoryRelativeRootPrefix` stores it and maps validation failures onto its existing
  `GitWorktreeInitializationError` cases.
- `IgnoreLayerAssembly` owns root assembly (`compileRootAuthority`, `makeRootRules`) and per-directory
  assembly (`appendingDirectoryLayers`). The app's `IgnoreRulesManager` forwards to it and the
  app's nested-directory path loads files with its unchanged I/O and error policy, then assembles
  through it.
- Headless enumeration (`file_search`, `get_file_tree`, `get_code_structure` directory expansion)
  applies these layers when the adapter supplies a `DomainIgnoreConfiguration`: global patterns
  from the M8M app-authority view and the headless `respect_repo_ignore`, `respect_cursorignore`,
  and `enable_hierarchical_ignores` switches (defaults match the app). Ignored directories are
  skipped unless a negation requires traversal, as in the app. With a configuration, the blanket
  hidden-file skip is dropped (the app has none); callers without one keep the legacy behavior.

| Layer | App crawl | Headless enumeration | Evidence |
|---|---|---|---|
| `.git` / `.svn` / `.DS_Store` built-ins | always | same `IgnoreRules` base layers | `HeadlessIgnoreEnumerationTests` |
| Root `.gitignore` | yes | yes | `HeadlessIgnoreParityTests` (non-Git) |
| Git-root mandatory floor | yes | yes, same `resolvingLoadedRoot` policy (M8O) | `HeadlessIgnoreEnumerationTests` |
| Root nested inside a repository (ancestor `.gitignore` walk) | yes | yes, same `gitRootChain` (M8O) | `HeadlessIgnoreParityTests`, `HeadlessIgnoreEnumerationTests` |
| Nested `.gitignore` / `.repo_ignore` / `.cursorignore` | yes when hierarchical (default) | yes, same `appendingDirectoryLayers` | `HeadlessIgnoreEnumerationTests` |
| Global ignore defaults | `globalSettings.json` value | same value via M8M view | `HeadlessIgnoreParityTests` |
| `.repo_ignore` / `.cursorignore` at root | yes when enabled | yes when enabled | `HeadlessIgnoreParityTests` |
| Hidden files | listed unless ignored | listed unless ignored | `HeadlessIgnoreEnumerationTests` |
| Symlinks | skipped by default; when off, only root-contained targets are eligible | same eligibility via `skip_symlinks`; never crosses the root (M8P) | `HeadlessSymlinkParityTests`, `HeadlessSymlinkPolicyTests` |
| `read_file` of an ignored or symlinked path | ignored readable; link/component/outside refused | same gates on the logical path; no-follow canonical read (M8Q) | `HeadlessReadAuthorityParityTests`, `HeadlessReadAuthorityTests` |

Evidence: conductor ticket `ffa8bb9e-ef7b-4089-802a-f7003663a738` passed 62/62, including
`HeadlessIgnoreEnumerationTests` 5/5 and `HeadlessIgnoreParityTests` 1/1 plus the existing ignore,
search, settings-authority, and direct-headless suites; all products built (`38a30899`); lint passed
before the final path-attribution fix (that fix was formatter-clean). Validation found and fixed a
real headless bug: enumerated items reported under `/private/var/...` for a `/var/...` root were
attributed to the root's rules only; enumeration now matches every equivalent root spelling and
applies no ignore decision to an item it cannot attribute.

Remaining ignore-parity gaps after M8N: roots nested inside a repository (closed by M8O below),
symlink policy (`skip_symlinks`), and `read_file` on an ignored path (app behavior unverified).

### M8O — nested Git root ignore parity

- `IgnoreRulePolicy.resolvingLoadedRoot` (the app crawl's policy resolver: ancestor `.git` walk,
  structural layout validation, gitfile/linked-worktree support, fail-closed on ambiguous topology),
  `MandatoryGitIgnoreFile` (the no-symlink, bounded, UTF-8, unchanged-during-read `.gitignore`
  reader), and `IgnoreLayerAssembly.gitRootChain` (repository root down to the loaded root: each
  level's `.gitignore` as the mandatory floor, global defaults once at the repository root, each
  level's `.repo_ignore` / `.cursorignore` when enabled) moved into the domain runtime with
  `GitRepositoryLayout`. The app's `IgnoreRulesManager` forwards to them with no behavior change.
- The headless evaluator resolves its policy and root chain through the same code, so a root nested
  inside a repository applies its ancestors' `.gitignore` files (including repository-anchored
  patterns, through the policy's repository-relative prefix) and the mandatory floor.
- Failure policy now matches the app: ambiguous Git topology, a present but unreadable root-level
  ignore file, or an unreadable nested `.gitignore` under a Git root fails the enumeration closed
  with the typed `MCPDomainCanonicalReadError.ignoreRulesUnavailable(root:)` rather than enumerate
  with the wrong rules. Nested `.repo_ignore` / `.cursorignore` stay best effort, as in the app.

Evidence: `HeadlessIgnoreParityTests` (non-Git root and a root nested in a repository, compared
against `IgnoreRulesManager` with the resolved policy) and `HeadlessIgnoreEnumerationTests`
(nested root with ancestor, anchored, hierarchical, and subdirectory-base cases; gitfile linked
worktree root; ambiguous topology, symlinked nested `.gitignore`, and unreadable root layer fail
closed). Conductor evidence: focused suites (headless ignore, policy resolution, ignore manager,
gitignore compiler, direct-headless) passed 54/54 (`3e1e3c95-4dd6-48ce-a05d-3f6c4555ed7f`); all
products built (`bb9a724b-924b-4d94-a8dc-c3dd599da1ca`); lint passed
(`96c9cdb1-3544-4253-be9f-febc96a0a0e3`) after whitespace/import-order-only formatting of four test
files. A first run failed to compile because the relocated `GitRepositoryLayout` lost its
synthesized cross-module initializer; it now declares an explicit `package` initializer.

Remaining ignore-parity gaps after M8O: symlink policy (`skip_symlinks`, closed by M8P below) and
`read_file` on an ignored path (app behavior unverified).

### M8P — headless symlink policy parity (root-contained)

The app has two layers. Its raw crawl (`FileSystemService.gatherPathsUsingEnumerator`) drops every
link when `skip_symlinks` is on (the default) and, when it is off, follows directory links —
including ones that leave the root — with a `DirChain` (device, inode) cycle guard, and lists file
and broken links as files. Its authoritative discovery and read gates are narrower, independent of
`skip_symlinks`: `catalogRegularFileEligibility` / `catalogFolderIsDiscoverable` and content-read
validation (`validateContentFileForReading`, `PhysicalCatalogPathProbe`) refuse a final-component
symlink (`.symbolicLink`), a missing target (`.missingOrDirectory`), and any path whose canonical
target is outside the root's canonical root (`.outsideCanonicalRoot`); with `skip_symlinks` on they
also refuse any path with a symlinked component (`.symlinkComponent`).

Headless enumeration (`file_search`, `get_file_tree`, `get_code_structure` directory expansion)
follows the authoritative gates, not the raw crawl. This is a deliberate, security-required
divergence from the raw crawl: a workspace root is a disclosure boundary, and nothing outside it may
be listed or read under an in-root logical path.

- `HeadlessDirectoryWalk` (configured enumeration only; callers without a configuration keep the
  legacy `FileManager` enumeration unchanged): with `skip_symlinks` on, every link is dropped. With
  it off, the only link admitted is one whose kernel-canonical target (`realpath`) is a directory
  inside the owning root's kernel-canonical root; it is listed and followed with the app's ancestor
  cycle guard (a cycle is listed, not descended). File links, broken links, and links whose target
  leaves the root — directly, via `../`, or nested beneath a followed in-root link — are neither
  listed nor followed. If the canonical root cannot be read, every link is dropped. A directory whose
  identity cannot be read is listed but not descended. Entries keep logical paths, so ignore rules
  see the link's own relative path (an ignored link name is not followed). Children are visited in
  name order; package directories stay listed-but-not-descended as before.
- Only regular, non-link files inside the canonical root reach content search and code-map reads.
- `DomainIgnoreConfiguration.skipSymlinks` (default true) carries the policy; the direct-headless
  adapter reads `file_system.skip_symlinks`. The headless settings catalog default for that key was
  `false` and is now `true`, matching `GlobalSettingsManager.skipSymlinks()`.
- Explicit path authority is unchanged: `DirectHeadlessDomainContext.resolvePath` resolves symlinks
  and requires the result inside a workspace root. For adapters that pass logical base paths, a base
  below the root that passes through a symlinked directory enumerates nothing under `skip_symlinks`.
- Consequence of following the gates rather than the raw crawl: with links followed, the app's
  raw crawl can still surface a file link, a broken link, or an escaping directory's names in its own
  tree; headless lists none of them.

Evidence: `HeadlessSymlinkParityTests` (headless listing equals the app's raw crawl filtered by
`catalogRegularFileEligibility` for both policy values, and pins that the raw crawl enumerates
`linkfile.swift` and `outside/ext.swift` while eligibility rejects them as `.symbolicLink` and
`.outsideCanonicalRoot`) and `HeadlessSymlinkPolicyTests` (default skips every link; follow admits
only in-root directory links with the cycle guard and logical ignore paths; outside-root file,
directory, `../`, and nested escape links never disclose names or content through path search,
content search, tree, or code-structure expansion; file links are not read; base through a skipped
link; settings default). Conductor evidence: focused suites (headless symlink and ignore, policy
resolution, ignore manager, direct-headless, canonical workspace) passed 65/65
(`d455a8ca`); all products built (`7d5f3a15`); lint passed with no formatting issues and strict
SwiftLint clean (`51022a7a`). A first focused run (`d768f545`) failed to compile on an async call
inside an `XCTUnwrap` autoclosure in the new test; the call is now hoisted.

Remaining ignore-parity gap after M8P: `read_file` on an ignored or symlinked path (closed by M8Q
below).

### M8Q — explicit `read_file` authority parity

App contract (explicit read, not discovery): `WorkspaceReadableFileService.resolveReadFileRequest`
resolves through `WorkspaceFileContextStore.resolveExactExistingWorkspaceFile`, whose explicit
materialization (`exactFileCandidates`, `materializeSingleExactFile`) admits a path whose
`catalogRegularFileEligibility` is `.eligible` **or `.ineligible(.ignored)`** — ignore rules filter
discovery; they do not authorize or refuse an explicit read. Every other reason blocks it:
`.symbolicLink` (final component is a link, whatever `skip_symlinks` says), `.symlinkComponent`
(a symlinked directory component while `skip_symlinks` is on), `.outsideCanonicalRoot`,
`.outsideRoot`, `.nonRegularFile`, `.missingOrDirectory`. The content read re-validates the same
gates (`FileSystemService.validateContentFileForReading`). App-only always-readable external
paths are out of scope and remain unsupported headless.

Before M8Q, headless `read_file` read whatever the adapter resolved: ignored files were readable
(correct), but because `DirectHeadlessDomainContext.resolvePath` resolves symlinks, a final-component
link to an in-root file and a path through a symlinked directory under `skip_symlinks` were readable
(the app refuses both), and the content was re-opened by path after the containment check, so a
component swapped for a symlink in between could escape the root.

- `HeadlessReadAuthority` applies the app's gates to the *logical* path the caller named (below the
  root spelling it matches), independent of adapter-side resolution: final-component link →
  `symbolicLinkPath`; symlinked component under `skip_symlinks` → `symlinkComponent`; `realpath`
  target outside the root's `realpath` → `outsideCanonicalRoot`; a path (absolute or `..`-escaping)
  under no root → `outsideRoot`; non-regular → `notARegularFile`. Ignored files are read. The policy
  comes from `DomainIgnoreConfiguration.skipSymlinks` (default on when no configuration is supplied).
- The content is read through a component-by-component `openat(O_NOFOLLOW)` walk of the canonical
  target from the canonical root, then `fstat`-checked as a regular file within the read limit. A
  directory component or the final file replaced by a symlink after authorization yields `ELOOP` /
  `ENOTDIR` and fails closed as `pathChangedDuringRead`; no symlink is traversed at read time. The
  root directory itself is trusted workspace authority (not re-validated per component).
- The adapter's `resolvePath` still runs first, so its own errors (outside the workspace, ambiguous
  relative path) are unchanged.

Evidence: `HeadlessReadAuthorityParityTests` (for every fixture path and both policy values, headless
reads exactly when the app's `catalogRegularFileEligibility` is `.eligible` or `.ignored`, and each
refusal maps to the app reason: ignored in-root file and ignored file through an in-root directory
link are read; file links in and out of the root, symlinked components under skip, and `outside/` /
`../` escapes are refused) and `HeadlessReadAuthorityTests` (ignored readable; final links refused
under either policy; component policy; outside-root link, `../` link, `..` traversal, and absolute
outside paths refused with a deliberately non-resolving adapter; directories refused; directory
component and final file swapped for outside-root links after authorization fail closed as
`pathChangedDuringRead`). Conductor evidence: focused suites (headless read authority, symlink,
ignore, canonical workspace, direct-headless, protected-mutation security) passed 87/87
(`91d9f728`); all products built (`190b59f4`); lint passed with 0/1602 files needing formatting and
strict SwiftLint clean (`205454bc`). A first focused run (`b1b7b79e`) failed to compile because the
app-side parity test called the domain-internal `mcpValue()`; it now decodes `result.json`, as the
other app-side parity tests do, with no production API widened.

Remaining residual (not claimed): a swap of the workspace root directory itself, and the app-only
always-readable external read paths.

### M8R — bounded, fault-isolated headless `get_code_structure`

Before M8R, headless `get_code_structure` read each source with `Data(contentsOf:)` — the whole file,
before the syntax engine's oversize check — with no aggregate bound (256 files per call), through the
resolving adapter path and a following read (so an explicit final-component link was code-mapped
although `read_file` refuses it, and a post-resolution symlink swap could escape the root), and one
unreadable or vanished file, or a code-map builder error, failed the entire call.

- Every source is read only through `HeadlessReadAuthority` (the M8Q `read_file` gates on the
  caller's logical path for an explicit file, or on the enumerated logical path for a directory
  member, plus the no-follow canonical read). `get_code_structure` never reads a byte that `read_file`
  would refuse. Explicitly named ignored files are code-mapped, as they are readable.
- Per-file cap: `maximumCodeStructureFileBytes` = `CodeMapSyntaxEngine.parseUTF8Limit` + 3 (a BOM).
  The engine refuses larger UTF-8 sources as oversize anyway, so a larger file is reported
  `source_oversize` from its `fstat` size without being read.
- Per-call budget: `maximumCodeStructureSourceBytes` (64,000,000). Each file's size is charged before
  any byte is read; once the budget refuses a file, it and every later file are reported
  `budget_exhausted` unread and the result is marked `truncated`. (A file growing during its read can
  overshoot the budget by at most the per-file cap.)
- Fault isolation (`codeStructureResults`): a read refusal (`read_refused` with the stable
  `MCPDomainCanonicalReadError.code` as `reason`), a vanished file (`missing`), any other I/O failure
  (`unreadable`), and a code-map builder error (`codemap_failed`) become that file's diagnostic; the
  existing `undecodable_source`, `unsupported_language`, `no_symbols`, `source_oversize`,
  `parse_failed`, and `decode_failed` diagnostics are unchanged. Only cancellation ends the call.
  Adapter path-resolution errors for an explicit path still fail the call, as the app's
  `exactPathResolutionIssue` does.
- `MCPDomainCanonicalReadError` gains stable `code` strings and `readBudgetExhausted`;
  `HeadlessReadAuthority.readContained` gains a size-admission hook evaluated after `fstat`, before
  any read.

Evidence: `HeadlessCodeStructureResilienceTests` (an unreadable file and an oversize file in the same
directory batch as a good file are reported per file while the good file is mapped; explicit
final-component link and symlinked component refused with their reasons while an explicit ignored
file is mapped, all with a non-resolving adapter; budget exhaustion reports the remainder unread;
a vanished file is `missing`; cancellation still ends the call), plus the existing code-structure,
symlink-policy, and bounds suites. Conductor evidence: focused suites passed 87/87 (`f5fd34f7`);
all products built (`fd8988e4`); lint passed with 0/1602 files needing formatting and strict
SwiftLint clean (`bbced235`). A first focused run (`f66780f0`) failed one assertion because the
budget fixture (`struct S {}`) legitimately maps to `no_symbols`; fixtures now carry symbols and the
assertions require a fully mapped file (language and non-empty signatures, no diagnostic).

### M8S — in-process app-versus-headless parity and latency harness (read boundary)

A deterministic, in-process gate for the cutover evidence named below, scoped to the MCP read
boundary (`read_file`, `get_code_structure`).

- App backend: the real window tools of a registered `WindowState` whose ephemeral workspace is
  activated through `switchWorkspace` (`InProcessMCPWindowServerFixture.makeRegisteredWindow`), so
  file-tool reads run the app's real workspace-authority and domain read routing path
  (`WindowStatesManager` window lookup, root catalog readiness). The fixture's standalone `make`,
  extracted from `MCPReadMutationPathContractTests` (which now uses it), is unchanged. Headless
  backend: `MCPDomainCanonicalWorkspaceService` with the production
  `DirectHeadlessDomainContext.resolvePath`. Both share one fixture root and one set of global
  ignore defaults (pinned through `IgnoreRulesManager`'s authority override); headless uses the
  app's default `skip_symlinks`.
- Normalization: a thrown error and an error DTO are both `refused` (the tool layer; the MCP
  `isError` result vs JSON-RPC error envelope is decided at the transport and is not compared);
  `read_file` content is compared after removing one trailing newline; `get_code_structure` is
  compared as the set of file names that received a code map; an app code-structure reply with
  `pending` / `unavailable` status is `unsettled` (a bounded, untimed settle wait precedes sampling).
- Expectation table (`MCPBackendParityHarnessTests.scenarios`): every scenario declares an authority
  class for both backends (`must_succeed` / `must_refuse`) and a relation (`equal`, or a documented
  `known_divergence` that must still diverge, so the table cannot silently go stale). Outcomes must be
  stable across iterations. Vacuous refusals are rejected: a `must_refuse` scenario names the
  headless refusal reason it expects; an app refusal carrying an internal error (`-32603`) or a
  workspace-not-ready code (`workspace_authority_*`, `workspace_freshness_timeout`,
  `worktree_scope_unavailable`) is a violation, never an authority refusal. An unsettled app index is
  reported, not failed, but cannot mask a headless disclosure. The evaluator is covered by
  backend-free unit tests.
- Scenarios: relative and absolute in-root reads, a line slice, an ignored file (readable), a
  final-component symlink, a symlinked directory component, an escape through a symlinked
  directory, an absolute outside path, a `..` escape, a missing file, a directory, and code structure
  for an in-root file, a file link, and an escaping link.
- Latency: one warm-up, then interleaved app/headless iterations per scenario (5), timed with
  `ContinuousClock`; the report carries samples, p50, and max per backend plus the app's
  `EditFlowPerf` DEBUG stage breakdown (omitted when another capture holds the recorder). The gate
  asserts only sample count and sanity (finite, non-negative, p50 <= max) — never a threshold or a
  backend ratio. The JSON report is attached to the test run and summarized in `MCPParity` log lines.
- Production fix found by the harness: `DirectHeadlessDomainContext.resolvePath` compared the
  `resolvingSymlinksInPath()` result (which strips a leading `/private`) against `root.path`, so a
  workspace root spelled `/private/var/...` rejected every in-root path as outside the workspace. It
  now also accepts the root's resolved spelling.

Findings (focused run `43111c88`): all four `must_succeed` reads return identical content from both
backends; every `must_refuse` read is refused by both — the app with `-32602` invalid-params
refusals, headless with the expected typed reason. Tool-layer read p50 was about 3.9–5.6 ms (app)
versus about 0.4 ms (headless) on one machine; this is recorded, not a claim about end-to-end or
cross-machine latency. Code-structure parity is not yet compared: the in-process app reports
`unavailable` for `get_code_structure` even after the settle wait (its code-map graph service does
not become available in this fixture), so those scenarios are `unsettled` on the app side and only
the headless authority is asserted. (Superseded by M8T below: the fixture is now a Git repository and
code-structure parity is compared on content.)

Not proven by M8S: transport, the JSON-RPC envelope, lanes, leases, and the watchdog (both backends
are driven at the tool layer); the app socket / connection-manager path; app-side code-structure
parity (above); `file_search` (not wired in the fixture); multi-root namespaces; cold-start or
large-tree performance; and absolute latency comparability across machines or runs. The live chaos
matrix and packaged-release evidence remain separate cutover-gate items.

Evidence: `MCPBackendParityHarnessTests` 11/11 and the focused suites
(`MCPReadMutationPathContractTests`, `HeadlessReadAuthority*`, `HeadlessCodeStructureResilienceTests`,
`DirectHeadless*`) passed 121/121 (conductor `43111c88`). Earlier focused runs (`e449bb10`, `aa789798`,
`3f77020f`, `460d7739`) failed while the gate surfaced, in turn, the headless `/private` resolver bug,
an unretained app runtime, an unactivated workspace, and an unregistered app window; each would
otherwise have let `must_refuse` scenarios pass vacuously, which the reason and infrastructure
checks now reject. All-products build and lint: pending (coordinator).

### M8T — real `get_code_structure` parity gate (Git-eligible, quiescent, content-compared)

M8S left code-structure parity uncompared: its fixture had no Git repository, and the app's code-map
graph requires Git repository authority. Verified in source: a non-Git root classifies as
`WorkspaceCodemapGitEligibilityPreflightResult.terminalUnavailable(.nonGit)`
(`WorkspaceCodemapGitCapabilityService.eligibilityPreflight`), the store installs a terminal setup
disposition instead of scheduling the graph, and the structure query answers
`status: unavailable` with the non-retryable issue `git_root_unavailable`. That is intended app
behavior, not a defect.

- The primary fixture is a committed Git repository (`ReviewGitRepositoryFixture`: isolated `HOME`,
  local identity, no signing, an explicit `main` branch) under a kernel-canonical temporary parent;
  the symlink scenarios are committed links.
- The app window's store uses an isolated code-map runtime (`CodemapStoreFixture`: temporary
  artifact root, production binding engine and Git capability service) instead of
  `CodeMapArtifactRuntime.processWide()`, so no process-wide artifact state is read or written, with
  the production local-classification and Git-eligibility probes (not the forced-eligible probe of
  `CodemapStoreFixture.makeStore`), so Git gating stays real. The harness shuts the runtime down on
  close. `InProcessMCPWindowServerFixture.makeRegisteredWindow` gained an optional injected store.
- Content comparison: app `FileDTO.content` is `CodeMapAPIContentFormatter.pathAndImportsBlock` plus
  `artifact.apiDescription`; headless `signatures` is the same `apiDescription` from the shared
  `CodeMapSyntaxArtifactBuilder`. Seeds are equivalent only when their names match and each app text
  ends, byte for byte, with the corresponding non-empty headless text. App graph expansion
  (`related` files) is app-only and not compared. Scenarios: one seed, two seeds (with a cross-file
  reference), a file link, and an escaping link.
- No escape hatch. An app reply still `pending` after the settle bound is `unsettled`, a terminal
  `unavailable` is `unavailable(codes)`, and an `ok` reply without mapped seeds is `mapped([])`:
  none is a success or a refusal. The app's typed code-structure refusal (no seeds, every issue
  `path_not_found`) is `refused`; an infrastructure code alongside it is not a clean refusal.
  Per-backend authority lets a scenario require `must_be_unavailable` with a specific code.
- Quiescent readiness: app code-map readiness is not monotonic after workspace activation — a focused
  run showed a graph that answered settled and then returned to `pending` (`seed_pending`,
  `graph_indexing`) mid-sampling, around activation-time Git data maintenance. The settle wait
  (untimed, 45 s bound) therefore requires the tool to answer settled and every app root to report
  `ready` (or terminal `unavailable`) through `currentCodemapRootStatusUpdate()`, continuously for
  1.5 s. Not reaching quiescence is a violation; the report then carries `APP_CODEMAP` diagnostics
  (store launch events, engine graph-index accounting, root status).
- Documented divergence (`MCPBackendParityHarnessTests.testNonGitRootCodeStructureIsADocumentedDivergence`):
  in a non-Git root the app must answer `unavailable` with `git_root_unavailable` while headless maps
  the file; reads in that root must still be equal. If the two ever agree, the gate fails and the
  table must be updated.
- Regression coverage (backend-free): unsettled and terminal-unavailable answers fail
  `must_succeed`; unsettled, unavailable, and empty answers are never refusals; an unsettled app
  cannot mask a headless disclosure; content equivalence rejects different API text, empty headless
  signatures, and different seed sets; `must_be_unavailable` requires its code; app code-structure
  classification separates path refusals from infrastructure codes; a non-quiescent index is a
  violation even when outcomes agree.

Findings. Code-structure parity holds on content: with the index quiescent, both seed scenarios
map on both backends with the app text ending exactly in the headless API description, and both link
scenarios are refused by both. App code-structure latency at the tool layer was about 0.7–1.9 s p50
(graph query and presentation) versus about 4–12 ms headless on one machine — recorded, not asserted.
Not a production fix (hypothesis not confirmed): after three transient retries a graph-build launch
records `retryExhausted` and stops rescheduling; `makeCodemapRootStatusSnapshot` classifies that as
`unavailable`, but the code-structure query's fallback would still answer `pending` with a retryable
`graph_indexing`. The failing focused runs showed active indexing (`seed_pending`,
`graph_indexing`), not exhaustion, so this inconsistency was not exercised and is left for a
follow-up with a deterministic reproduction. (Reproduced and fixed in M8U below.)

Not proven by M8T: app graph expansion parity (headless has no graph), code-structure behavior for
worktrees, submodules, or nested repositories, and anything listed as not proven for M8S.

Evidence: focused `MCPBackendParityHarness|MCPReadMutationPathContract` passed 74/74 on two
consecutive runs of unchanged source (conductor `8b334035` and `3c45e359`). Earlier runs
(`1e1fa3fb`, `f5a9ef89`, `7f840feb`, `56bab008`) surfaced, in turn, the process-wide code-map
runtime dependency, the app's `path_not_found` refusal form, and non-monotonic readiness; `7f840feb`
was green before the quiescence requirement and is not counted.

### M8U — code-map retry exhaustion no longer reported as a retryable pending index

The M8T follow-up, now confirmed with a deterministic reproduction and fixed. A code-map graph-build
launch whose eligibility check is transiently unavailable retries up to
`CodemapGraphIndexBuildRetryPolicy.maximumRetryCount` times and then records `retryExhausted`
(`scheduleCodemapGraphIndexBuildRetry`); `scheduleCodemapGraphIndexBuildAfterRootReady` returns early
for that phase, so file deltas do not reschedule it — only a root reload or
`prioritizeCodemapGraphIndexNow` does. Root status already classified the root as `unavailable`
(`retryExhausted`), but the structure query's no-graph fallback checked only the proof-backed non-Git
cache and answered `status: pending` with a retryable `graph_indexing` (`retry_after_ms: 100`); the
reply DTO then carried top-level retry guidance and the text formatter said "Retry shortly". An MCP
client would retry forever against a root that will not rebuild on its own. The same fallback also
answered a worker-recovery-exhausted root, and a non-Git root whose eligibility came from the Git
probe without a local proof, as retryable pending.

- `codemapRootUnavailableReason(rootEpoch:)` is now the single source for root status and the query:
  worker-recovery exhaustion, `retryExhausted`, and `terminalNonGit` launches.
- The query's no-graph answer (`codemapNoGraphStructureAnswer`) is terminal — `status: unavailable`,
  `updates_pending: false`, seeds `not_indexed`, issue `retryable: false` with no `retry_after_ms` —
  for `git_root_unavailable` (proof-backed cache or `terminalNonGit` launch), `graph_retry_exhausted`,
  and `graph_worker_recovery_exhausted`. A graph that is still being built or actively retried keeps
  the pending, retryable `graph_indexing` answer.
- The text formatter explains the two exhaustion codes and directs a reload ("retrying the same
  request will not help") instead of a generic retry.
- Headless contract: unchanged. Headless has no code-map graph; its `get_code_structure` never
  returns pending or retry guidance (M8R), so there is no headless counterpart to correct.

Regression coverage (`WorkspaceCodemapRetryExhaustionStructureTests`, isolated code-map runtime,
injected probes): `maximumRetryCount: 0` with a `requiresGitPreflight` local probe and a
`transientUnavailable(.permissionFailure)` eligibility probe reaches `retryExhausted` deterministically,
and the query, the reply DTO (no `retry`), and the formatted text all report a terminal, non-retryable
answer; an active transient retry (a retry sleep that never fires) stays pending and retryable;
worker-recovery exhaustion toggled through the DEBUG seam is unavailable and returns to pending when
cleared; non-Git eligibility without a local proof is `git_root_unavailable` and not retryable.

Not changed (recorded): other terminal eligibility reasons (bare repository, invalid layout) finish
the launch as `superseded`, which root status itself reports as `notInitialized`; making those
terminal needs a decision about their recovery semantics and is left for a follow-up. (Bare
repository and invalid layout: decided and fixed in M8V below.)

Evidence: focused `WorkspaceCodemapRetryExhaustionStructure|MCPBackendParityHarness|MCPCodeStructure|
CodeStructureToolCard|ToolOutputFormatter` passed 55/55 (conductor `955b7dc5`), including
`WorkspaceCodemapRetryExhaustionStructureTests` 4/4 and the M8T parity gate 18/18. A first run
(`586d633b`) failed to compile only in the new test (a nonisolated call to the main-actor
`codeStructureReplyDTO`); the test class is now `@MainActor`. All-products build and lint pending on
this checkpoint.

### M8V — bare repositories and invalid Git layouts reported as terminal, distinct from non-Git

The M8U recorded gap, verified in source and fixed. `WorkspaceCodemapGitCapabilityService
.eligibilityPreflight` classifies a root whose Git kind is bare (`git rev-parse --is-bare-repository`,
after `--show-toplevel` finds no work tree) as `terminalUnavailable(.bareRepository)`, and one Git
reports as a work tree without a resolvable top level as `terminalUnavailable(.invalidLayout)`. For
every terminal reason except `nonGit`, the store installs the session setup disposition
`.unavailable(.gitTerminal(reason))` but finishes the launch as `superseded`. Root status mapped
`superseded` to `notInitialized` (no unavailable reason), and the M8U structure fallback answered
`pending` with a retryable `graph_indexing` — so an MCP client was told to retry a root that cannot
index.

Recovery contract, from source: the Git-terminal disposition is sticky for the root epoch —
`ensureCodemapSetupTask` replays an existing session's disposition, and `codemapUnavailableIsStable`
treats every Git-terminal reason except `releasedRootEpoch` as stable — so neither file deltas nor
`prioritizeCodemapGraphIndexNow` can recover it, even if eligibility later changes. Reloading the root
(a new root epoch) re-runs eligibility from scratch and is the only recovery.

- `WorkspaceCodemapRootStatusUnavailableReason` gains `bareRepository` and `invalidGitLayout`,
  derived in the single `codemapRootUnavailableReason` from the session's sticky Git-terminal
  disposition (after worker-recovery exhaustion and the `terminalNonGit` / `retryExhausted` launch
  phases). Root status therefore reports `unavailable` with the specific reason.
- The structure query's no-graph answer is terminal and non-retryable with distinct codes:
  `git_bare_repository` ("no work tree to index; open a checkout") and `git_layout_invalid` ("repair
  it, then reload the root"). Neither is `git_root_unavailable`, so a bare repository never looks like
  an ordinary non-Git directory. The formatter gives each its own cause and action.
- Unchanged: Git classification itself, launch scheduling and phases, the proof-backed and
  launch-phase non-Git answer, active transient retries (still pending and retryable), and the other
  terminal reasons (`unsupportedObjectFormat`, `unsupportedGit`, `invalidLoadedRootContainment`,
  `namespaceUnavailable`, `rootEpochBindingMismatch`, `releasedRootEpoch`), which keep their current
  reporting pending a per-reason recovery decision.
- Headless: unaffected (no code-map graph; never pending or retry guidance).

Regression coverage (`WorkspaceCodemapRetryExhaustionStructureTests`, isolated runtime, injected
probes): a bare-repository and an invalid-layout eligibility each produce root status
`unavailable` with their reason, a terminal non-retryable query answer with their distinct code
(asserted not to be `git_root_unavailable`), a DTO without retry guidance, and formatter text with
their cause and action; with the bare disposition installed, switching eligibility to an active
transient condition and re-prioritizing in the same epoch keeps the terminal answer, while reloading
the root clears it to the ordinary pending, retryable `graph_indexing`.

Evidence (scoped): focused `WorkspaceCodemapRetryExhaustionStructure|MCPCodeStructure|
CodeStructureToolCard|ToolOutputFormatter|AgentWorkspaceRootsSidebar` passed 40/40 on unchanged source
(conductor `7e51699f`), including `WorkspaceCodemapRetryExhaustionStructureTests` 7/7. A first run
(`190e7d65`) failed in two new tests (a formatter fragment containing an apostrophe, which
`String(describing:)` escapes; and a sticky-epoch test that wrongly expected the eligibility probe to
re-run in the same epoch — the source replays the sticky disposition without re-probing, which the
test now asserts). All-products build and lint pending on this checkpoint.

M8T parity gate: NOT passing on this checkpoint — intermittently red, and not claimed. It is outside
M8V's change (which only affects how an existing Git-terminal disposition is reported; launch
scheduling, retries, and engine admission are untouched) and passed on the M8T and M8U runs, but
failed on both M8V focused runs through two distinct app code-map engine paths, recorded with the
harness's `APP_CODEMAP` diagnostics (now also captured when a settled must-succeed code-structure
answer fails):

- `190e7d65`: the Git fixture's graph build exhausted its three transient retries (about 1.75 s of
  backoff) right after activation and answered `graph_retry_exhausted` (honestly, since M8U).
- `0be123ad`: the store launch completed (`eligibilityEligible` → `setupJoining` → `engineScheduling`
  → `handedOff`), an earlier launch for the same root was `cancelled` after hand-off and relaunched,
  and the replacement engine graph-index job stayed in `waitingForAdmission` for the whole 45 s bound
  (worker present, zero candidates processed); the app kept answering `pending` / `graph_indexing`.

Both are production reliability defects in the app's code-map engine — a freshly opened repository
can fail to index until reloaded — and are the scope of the next milestone (M8W), not fixed here. The
admission stall's root cause is unconfirmed (hypothesis: an admission slot not released by, or a
missed admission reschedule after, the cancelled job); confirming it needs the engine's active-batch
set, admission queue, and per-root active-batch counts at the stall.

### M8W — code-map graph-index admission wake-up after a cancelled active job drains

The admission-stall half of the intermittent M8T gate failure recorded in M8V, root-caused and
fixed. In `WorkspaceCodemapBindingEngine` an admitted graph-index batch is non-preemptive, so
`cancelGraphIndexJob` removes a cancelled job that holds an admitted batch from `graphIndexJobs` but
deliberately keeps its ID in `activeGraphIndexJobIDs` and the draining maps until its worker reaches
a currentness boundary, and skips `scheduleGraphIndexAdmissions()` for an active job. A replacement
job for the same root queued meanwhile is ineligible: `activeGraphIndexBatchCount(rootEpoch:)` still
counts the draining batch against `maximumActiveGraphIndexBatchCountPerRoot` (default 1). When the
drained batch ends, `releaseGraphIndexAdmission` returns early (the root's job is now the
replacement), and `finishGraphIndexWorker`'s missing-job branch released the slot and draining state
but returned without `scheduleQueuedRequests()` / `scheduleGraphIndexAdmissions()`, unlike normal
completion. The now-eligible replacement then waited in `waitingForAdmission` indefinitely unless an
unrelated event re-ran admission — matching the `0be123ad` diagnostics (a launch `cancelled` after
hand-off, then a replacement stuck in `waitingForAdmission` with zero candidates processed).

- Fix: the missing-job branch of `finishGraphIndexWorker` now calls `scheduleQueuedRequests()` and
  `scheduleGraphIndexAdmissions()` after releasing the drained job's capacity. No other admission,
  cancellation, or preemption behavior changes.
- Regression (`WorkspaceCodemapGraphIndexAdmissionTests`, committed Git fixture, isolated runtime): a
  catalog-build handler gated closed holds job A inside its admitted batch; `cancelGraphIndex` then
  `scheduleGraphIndex` queues replacement B in `waitingForAdmission` behind one draining batch;
  opening the gate must let B be admitted and complete. Run before the fix (`cb8878f1`), it failed for
  exactly the intended reason — after A drained, B stayed `waitingForAdmission` with
  `queued=true active=0 draining=0`, eligible but never admitted.

Retry exhaustion (the other M8V gate path) is not changed here. Source assessment: transient results
that consume the store launch's 3-retry budget (250 / 500 / 1000 ms) include not only Git faults
(`gitProcessUnavailable`, `repositoryChanging`, `permissionFailure`) but supersession — an eligibility
`CancellationError` maps to `runtimeUnavailable`, and setup `.cancelled` / `.staleCurrentness`
dispositions are retryable — so activation-time authority churn may exhaust it. Store events record
the event kind but not the transient reason, so which path the fixture hits is unconfirmed. M8X
instruments the reason first and decides the fix from evidence; the budget is unchanged.

Evidence: focused `WorkspaceCodemapGraphIndexAdmission|WorkspaceCodemapGraphIncrementalIndex|
CodemapAutomaticSelectionGraphNative|WorkspaceCodemapRetryExhaustionStructure|
CodemapGraphStatusDebugDiagnostics|MCPBackendParityHarness` passed 41/41 after the fix (conductor
`054b218d`). The M8T parity gate was 18/18 in that run, with every code-structure scenario quiescent;
because the retry-exhaustion path is unfixed, that is an observation, not a claim the gate is
stable. All-products build and lint pending on this checkpoint.

### M8X — transient-reason diagnostics for code-map graph-build retries (instrumentation; cause unresolved)

Instrumentation for the retry-exhaustion half of the intermittent M8T gate failure, before any policy
change. Verified retry sources: only two launch sites consume the store's 3-retry budget
(`CodemapGraphIndexBuildRetryPolicy.production`: 250 / 500 / 1000 ms) — a transient eligibility result
(`WorkspaceCodemapGitTransientUnavailableReason`) and a retryable setup disposition
(`codemapSetupDispositionIsRetryable`). Engine scheduling never retries, and a launch that finishes
`.cancelled` (for example when a detached session advances root authority mid-flight) exits without
consuming a retry; a setup `.staleCurrentness` consumes one only when the launch is still current.

- DEBUG store events (`CodemapGraphIndexBuildStoreEvent`, bounded at 2048) gain an optional
  `transientReason`: `eligibility.<reason>` on `eligibilityTransient`, and the triggering reason on
  `retryScheduled` and `retryExhausted` (so an exhaustion names the cause of its final attempt), or
  `setup.<case>` for a retryable setup disposition (`codemapSetupTransientReasonLabel`). Labels are
  case names only — no paths or payload values. Release builds are unchanged (the recorder is
  DEBUG-only).
- The parity harness's `APP_CODEMAP` diagnostics print each event's reason.
- Tests (`WorkspaceCodemapRetryExhaustionStructureTests`): a `repositoryChanging` eligibility transient
  with one retry labels every transient, scheduled-retry, and exhaustion event
  `eligibility.repositoryChanging`; an eligible root whose runtime provider throws exhausts with
  `setup.runtimeFailure` and no eligibility transient; labels never contain a path component.

Unresolved (not claimed): no `graph_retry_exhausted` occurred in the M8X focused run, so the cause of
the earlier exhaustion (`190e7d65`) is still unproven and the retry policy is unchanged. The M8T
parity gate is NOT passing on this checkpoint: in `22c7e783` every other scenario held exact parity,
but "code structure of two seed files" reached quiescence and its app outcome still changed across
the measured iterations — further evidence of non-monotonic app readiness after activation, not a
retry event. Per-iteration app outcomes are not yet reported, so what changed is unknown. The next
gate step is to report per-iteration outcomes and keep capturing `APP_CODEMAP` reasons until an
exhaustion or readiness regression is caught with its cause.

Evidence (scoped): in focused run `22c7e783` on frozen source,
`WorkspaceCodemapRetryExhaustionStructureTests` 9/9, `WorkspaceCodemapGraphIndexAdmissionTests`, and
`CodemapGraphStatusDebugDiagnosticsTests` passed; the parity gate failed only on the iteration-stability
check above (30 tests, 1 failure). All-products build and lint pending on this checkpoint.

### M12 — `file_search` app-versus-headless parity gate

The M8S harness now drives `file_search` on both backends over the Git fixture: the app through the
registered window's real tool (its `WindowState` composition wires the production
`StoreBackedWorkspaceSearch`; only the standalone `InProcessMCPWindowServerFixture.make` stubs search),
headless through `MCPDomainCanonicalWorkspaceService.searchFiles`. Outcomes normalize to sorted
root-relative path hits and content hits (path, 1-based line, line text), or the count for
`count_only`; an app error field or any thrown error is a refusal. Each scenario carries a
`SearchExpectation` (paths that must appear, ignored/linked/outside paths that must not, or an exact
count), so an empty answer both backends agree on cannot pass. Latency is reported per scenario
(p50/max, interleaved, after a warm-up), never asserted. In a single root the app's display paths were
observed root-relative, so no path rewriting was applied; the spelling is reported per scenario.

First run (all scenarios `equal`, before any fix): 16 of 22 held exact parity — literal, regex, and
literal-case content; whole word; path glob and literal; a dotfile path; extension, path, `path`-alias,
and exclude filters; a content limit within one file; `count_only`; an `auto` glob; the empty pattern;
and exclusion of Git-ignored, globally ignored, directory-link, file-link, and outside-root files.
Demonstrated drift, all headless-side:

| Scenario | App (default backend) | Headless before | Resolution |
| --- | --- | --- | --- |
| `auto` mode, identifier pattern | paths and content (`inferredAutoMode` → `both`) | content only (`*` → path, else content) | fixed: shared heuristic |
| regex content `PARITY[a-z]+` | case-insensitive (every MCP search) | case-sensitive | fixed: `.caseInsensitive` |
| `count_only` with `max_results: 1` | 3 (content counted unbounded) | 1 | fixed |
| whitespace-only pattern | rejected (`pattern cannot be empty`) | searched `"   "` | fixed: pattern trimmed |
| literal content `done?` (`mode: "content"`) | substring match | whole-line glob, no match | fixed: glob for paths only |
| uncompilable regex `(unclosed` | repaired (literal fallback, `warning`) | rejected with the compile error | documented divergence |
| `mode: "fuzzy"` (outside the schema enum) | falls back to `auto` | rejected as invalid params | documented divergence |

Fixes, in the narrowest owners:

- `FileSearchPatternHeuristics` (new, `RepoPromptDomainRuntime/Search`) holds the app's pure
  `inferredAutoMode`, `containsRegexSyntax`, and `usesPCREOnlyFeatures`, moved verbatim (checked
  line-for-line against the previous app source). `FileSearchActor` and `RegexToolkit` delegate, so
  app behavior is unchanged; headless uses the same functions for `auto` mode and for regex
  auto-detection when `regex` is omitted (replacing its narrower `looksLikeRegex`, under which `go()`
  would have compiled as a regex and matched `ago`; the table pins it literal).
- That switch routed more literal patterns into headless `matches`, which applied glob semantics to
  content lines whenever a literal contained `*`, `?`, or `[` (already true for `*` before M12). The
  added `done?` scenario demonstrated the miss against the app before the fix; wildcards are now glob
  syntax for path matching only, as the tool description states.
- Headless `searchFiles` trims the pattern, compiles regexes case-insensitively, caps path hits and
  content hits separately at `max_results` (as the app does for `mode: "both"`), and counts every
  content match for `count_only`. The `count` of a non-`count_only` reply stays the number of
  returned matches.

Intentional incompatibilities (the table requires them to keep diverging): headless rejects an
uncompilable regex and an out-of-enum `mode`, where the app repairs or falls back. Headless is
stricter, never broader. Not proven (listed in the report): worktree display projection (the
fixture binds no session worktree), multi-root display aliases, result order, `context_lines`,
limit/size-cap flags, the app's auto-selection side effect (included in app latency), and regex
dialect beyond the table (app PCRE2, headless ICU). The shared schema still describes `max_results`
as "Maximum total results"; both backends now cap per stage, and the schema text is unchanged.

Evidence (scoped): conductor focused run `e2255887` passed 86/86 on the final source —
`MCPBackendParityHarnessTests` (the read and code-structure gates unchanged, plus the `file_search`
gate: 25 scenarios, 23 at exact parity and 2 documented divergences, no violations),
`MCPDomainCanonicalSearchSemanticsTests`, `MCPDomainCanonicalWorkspaceBoundsTests`, the headless ignore
and symlink suites, and the app search suites that exercise the moved heuristics
(`StoreBackedWorkspaceSearchTests`, `WorkspaceSearchServiceTests`, `PCRE2SearchFastPlansTests`,
`MCPFileSearchDisplayPathTests`). The literal-wildcard drift was demonstrated by run `4c063db3` before
its fix. `conductor lint` (format-check and strict SwiftLint) and
`Scripts/headless_runtime_guardrails.sh` passed. Not run: the full suite, an all-products build
(the focused run compiles both the app and `RepoPromptMCP` sources through the test bundle), live
MCP smoke, the live chaos matrix, and packaged-release checks; backend defaults are unchanged.
In that run, per-scenario p50 latency for the 21 scenarios both backends answered was 5.7–14.5 ms
for the app (auto-selection included) and 2.4–6.0 ms for headless; it is reported, not asserted, and not comparable across machines.

### M13 — `file_search` parity closure

M13 closes five hypotheses from the M12 review with added parity scenarios (the fixture gains
`order/{a.txt,a-z.txt,a/b.txt}`, `docs/blank_line.txt`, `docs/crlf.txt`, `docs/empty.txt`, and
`docs/call(unclosed.txt`) and owner tests. The source of each app behavior is cited below; the
"headless before" column is read from the pre-M13 source.

| Hypothesis | App (source) | Headless before | Resolution |
| --- | --- | --- | --- |
| Capped selection follows walk order | each stage sorts every admitted file by full path (path stage UTF-8 bytes, `FileSearchActor.pathSearchInputPrecedes`; content stage `String` order) before capping | depth-first walk over `names.sorted()`, early stop at the cap: `order/a/b.txt` is reached before `order/a-z.txt` (`-` < `.` < `/`) | fixed: one bounded walk collects admitted files; each stage sorts and caps like the app |
| Explicit `regex: true` with `*.swift` | a wildcard-only pattern without strong regex syntax stays a glob; an uncompilable path regex falls back to glob/literal matching | validated `*.swift` as an ICU regex (a leading quantifier does not compile) and rejected the call; also rejected `(unclosed` in path-only mode | fixed: `FileSearchPatternHeuristics.pathStageUsesRegex` (moved from the app, which now delegates) and path-stage fallback |
| `^$` after a trailing newline | lines end at LF, CR, or CRLF; a trailing terminator starts no line; an empty buffer has no lines (`forEachPCRE2CRLFLine`, `SearchLineIndex`) | `components(separatedBy: .newlines)`: a phantom empty last line in every newline-terminated file, CRLF counted as two lines, and U+0085/U+2028/U+2029 as terminators | fixed: `FileSearchLines` (headless owner of the app's line model) |
| Invalid-regex gate was vacuous | repairs `(unclosed` and answers | rejected | the scenario now requires the app to find `docs/call(unclosed.txt`, not merely answer; headless still rejects when content is searched (documented divergence) |
| `max_results` schema said "Maximum total results" | caps path and content stages separately; `count_only` counts content unbounded | same (since M12) | fixed: `FileSearchResultLimits` owns the default (50) and the per-stage description; canonicalization restates the vendored text, and the app provider, headless `searchFiles`, and the generated review snapshot use it |

Path-stage details moved with the app's logic, also pinned by owner tests: the path stage ignores
`whole_word`, retries a glob with its friendly candidates (`src/*.sw` → `src/*.sw*`, any-depth
`**/`), and treats only `*` and `?` as wildcards (`[` is literal). Filters keep their M12 semantics.
The headless walk no longer stops early at the cap, since correct selection needs every admitted
file; it stays bounded by `maximumEnumeratedFiles`, and content reading still stops at the cap.
Headless output lists path hits before content hits (the app's stage order).

`WorkspaceCodemapRetryExhaustionStructureTests.testActiveTransientRetryStaysPendingAndRetryable`
read the launch phase once after root availability became `indexing`. Availability `indexing`
also covers the launch phases before the first transient answer schedules its retry
(`eligibilityQueued`, `setupJoining`, `engineScheduling`, `handedOff`), so the one-shot read could
race. The test now waits, bounded, for `transientRetry`; production code-map code is unchanged.

Still not proven: multi-root ordering and alias candidates, worktree display projection,
`context_lines`, unanchored regex matches that span lines or are empty (the app's full-buffer scan
skips empty matches; headless matches line by line), per-line length limits, and regex dialect
beyond the table (app PCRE2, headless ICU).

Evidence (source-only milestone; nothing compiled or run): `conductor lint` ticket `d4f89eb2`
passed (format-check 0/1613 files, strict SwiftLint) and `conductor guardrails` ticket `e72b2ea9`
passed, both on this source. The focused coordinated test tickets `05f27d06` and `5d221b1f`
(filter: the headless ignore and symlink suites, `MCPDomainCanonicalSearchSemanticsTests`,
`MCPBackendParityHarnessTests`, `DirectHeadlessCompositionTests`,
`WorkspaceCodemapRetryExhaustionStructureTests`, the app search suites,
`MCPDomainCanonicalWorkspaceBoundsTests`, `MCPDomainStandaloneCompositionTests`, and
`AgentSessionLinkToolCatalogPolicyTests`) both failed before any source compilation. Under Xcode 27.0
(27A266a, Swift 6.4), SwiftPM reports `Missing path .../Sparkle.xcframework/macos-arm64_x86_64/dSYMs`
declared by the vendored XCFramework's `DebugSymbolsPath`. That is an environment blocker outside M13.
M13 claims no compile result, no test result, and no parity runtime result: the drift and fixes above are
established from source, and the new parity scenarios, owner tests, codemap test synchronization, and
hand-patched schema review snapshot are unverified until a build succeeds. Not run: the full suite,
live MCP smoke, and packaged-release checks; backend defaults are unchanged.

### M14 — global-ignore authority safety and `max_results` range parity

- **Migration marker after a durable write.** `GlobalSettingsStore` recorded the one-time legacy
  global-ignore migration marker before the startup save ran, so a failed write followed by a
  relaunch lost a customized legacy value (the JSON on disk was still canonical and the migration
  never retried). The marker is now recorded only after a save carrying the migrated value succeeds
  (the startup save, a retry, or any later save); a failed write keeps the live value and retries on
  the next launch.
- **Blocked load keeps user exclusions.** A blocked or incompatible settings file installs provisional
  defaults, which published the canonical list to the crawl and suppressed the legacy effective
  exclusions that `IgnoreRulesManager`'s pre-load fallback would have applied. The provisional
  document now keeps the legacy effective value until a compatible document is loaded or recovered,
  and explicit recovery persists it. A loaded document whose save later failed is unchanged. Headless
  `DomainGlobalIgnoreDefaultsView` reads only the JSON file and still reports the canonical list in
  that blocked state (documented divergence).
- **`max_results` range.** Headless clamped `max_results` to `1...1000`; the app provider passed 0,
  negatives, and values above 1000 through unchanged. `FileSearchResultLimits.effectiveMaxResults`
  now owns the range (absent → 50; zero and negatives → 1; above 1000 → 1000; never refused), both
  backends call it, and the canonical schema text states the range.

Evidence: focused coordinated test ticket `e5d95110` passed (98 tests: `GlobalIgnoreDefaultsAuthorityTests`,
every `GlobalSettings*` suite, `MCPDomainCanonicalSearchSemanticsTests`, `MCPBackendParityHarnessTests`
with three new negative/zero/above-maximum parity scenarios, `DirectHeadlessCompositionTests`,
`DomainGlobalIgnoreDefaultsViewTests`, `HeadlessIgnoreParityTests`); `conductor lint` ticket `53e6ee9c`
and `conductor guardrails` ticket `65d98249` passed. The build used the locally restored, untracked
official Sparkle 2.9.2 dSYMs; no Vendor file is part of this change.

### M15 — app-independent `get_code_structure` query core

Before M15 the app ran the whole `get_code_structure` query on the main actor in
`MCPServerViewModel.buildCodeStructureDTO`: the Code Maps and scope checks, seed admission,
logical-path projection, graph query, initial and final revalidation, signature demand through
`WorkspaceCodemapPresentationCoordinator`, and assembly. Only seed ordering and assembly hopped to
`MCPProviderProjectionWorker` (M9/M10). `MCPFileToolProvider` parsed the arguments inline, next to
authority, ingress, and seed resolution.

- **Value request.** `MCPCodeStructureQueryRequest` (Sendable) parses every option except `paths`
  in the historical order (unknown keys, `expand`, `depth`, `signatures`, `size`) with the same
  messages. `requestedPaths(from:)` validates `paths` where it always ran, after the ingress wait,
  so an invalid list keeps its cancellation ordering. It replaces `MCPServerViewModel.CodeStructureRequest`
  and `codeStructureSeedLimit(for:)` (`maximumSeedCount` stays 8192).
- **Core.** `MCPCodeStructureQueryOrchestrator.run(_:)` takes a Sendable `MCPCodeStructureQueryInput`
  (request, resolved seeds, translated requested paths, lookup context, and the global Code Maps
  switch as a captured value) and an `MCPCodeStructureQueryBackend` port: scope availability, root
  refs, logical root names, graph query, revalidation, and signature demand.
  `WorkspaceStoreCodeStructureQueryBackend` is the production port over the store actor and the
  presentation coordinator, with the demand policy unchanged. The body is the former MainActor body
  with its order intact: every cancellation check, every `MCPToolExecutionHandlerPhase` report, the
  early answers (`codemaps_disabled`, `git_root_unavailable`, `path_not_found`), and the rule that a
  root invalid at the initial revalidation is excluded from demand and stays invalid after the
  final revalidation. `run` is a nonisolated `async` function, so all of it runs off the main actor,
  including the pure seed ordering and assembly, which no longer hop to the projection worker. It
  returns the reply, the seed order, and whether demand ran; the adapter records the last two only
  as DEBUG diagnostics. The pure seed-key projection moved to `MCPCodeStructureReplyProjection`.
- **What stays in the app.** Window and tab routing and `FrozenFileToolAuthority` capture
  (`readAuthority`), the ingress wait, explicit-path resolution issues, seed resolution for paths and
  for the selection (including the read auto-selection prerequisite), capturing the store and
  `codeMapsGloballyDisabled` on the main actor (`MCPServerViewModel.buildCodeStructureDTO`, now a
  thin adapter), and the fence. The fence validates authority after the core returns, encodes the
  reply on the projection worker, and validates again. The main actor is free for the whole query,
  so authority can change at any suspension inside the core; as before, only the fence decides
  whether the reply is released.
- **Guardrail.** `headless_runtime_guardrails.sh` requires the core and rejects `@MainActor`,
  `MainActor.`, any `ViewModel` or `WindowState` reference, and AppKit, SwiftUI, or Combine imports
  in it.
- **Not changed.** Reply DTOs, error messages, retry guidance, stale-root presentation, seed order
  (UTF-8 logical path, then UUID string), and Context Builder. The only diagnostics change is that
  the DEBUG `provider_projection_*` MainActor handoff events for `seed_ordering` and
  `reply_assembly` are gone, because there is no handoff; `value_encoding` remains.

Evidence: `MCPCodeStructureQueryOrchestratorTests` uses a scripted backend. It covers parsing order
and messages, reply parity with direct assembly, and the exact backend call sequence from a
MainActor caller with every phase off the main thread. It also covers a root invalidated during
demand reported unavailable, no demand when every root is already invalid, early answers without a
graph query, and cancellation during the graph query and during demand. Cancellation stops before
revalidation and assembly whether or not the backend observes it. `MCPCodeStructureProviderWorkerTests`
drives a real window. It covers phases off the main actor, cancellation at seed ordering and at the
graph query, and fail-closed replies when authority is superseded at seed ordering, graph query,
signature demand, assembly, and encoding. Over a settled non-Git index with graph expansion and
signatures, the headless core, given only the store actor and a value request, returns a reply equal
to the full app provider reply. `MCPCodeStructureReplyAssemblyTests` and `MCPBackendParityHarnessTests`
were updated for the retired hops.

Conductor evidence: the focused suites (`MCPCodeStructure*`, `MCPBackendParityHarness`,
`WorkspaceCodemapRetryExhaustionStructure`, `BindContextFileAuthority`, `MCPSelectionPrerequisiteError`,
`CodeStructureToolCard`, `MCPReadFileProviderAuthority`) passed 113/113 (`eb6c386d`), and a repeat of
the two M15 suites passed 20/20 (`35b622f5`). `conductor lint` (`28a28fca`), `conductor guardrails`
(`a5ebcc86`), and `swift-build --product RepoPrompt` (`b5a2206a`) passed. Two earlier focused runs
failed in the parity test only. `08b379f3` failed on an assertion that expected the root-relative
display path; graph paths carry the root label. `c9948022` sampled the core while a graph update was
still in flight (`updates_pending`, so `partial`) between two equal `ok` app replies, because the
test helper skipped the app adapter's ingress wait. The helper now mirrors that wait, and the test
compares only an app/core/app agreement, retrying a disagreeing sample within a bound. Builds used
the locally restored, untracked official Sparkle 2.9.2 dSYMs for Xcode 27; no Vendor file is part of
this change. Not run: the full root test suite, live MCP smoke, and a release-configuration build.

### M16 — shared Context Builder route/stream settlement core

Before M16, a nested discovery run's race between its provider stream and MCP routing lived on the
main actor in the app. `ContextBuilderRouteSettlementCoordinator` owned exactly-once settlement and
the bounded pre-route event buffer. `ContextBuilderAgentViewModel.consumeContextBuilderProviderStreamWhileAwaitingRoute`
and its helpers started route-wait, stream, and watchdog tasks, applied every precedence rule
inline, and buffered the app-only `AIStreamResult`. None of it was reachable from a headless host.

- **Core (`RepoPromptDomainRuntime/ContextBuilder`, `package` access, no MainActor).**
  `ContextBuilderPreRouteEventBuffer` holds provider-neutral events described by
  `ContextBuilderPreRouteEventDescriptor` (type, content/progress/protected kind, and payload
  character count). Coalescing, both eviction orders, and the dropped totals are unchanged.
  `droppedSummary` is the single source of the "Dropped … while waiting for MCP routing." log line.
  `ContextBuilderRouteSettlementMachine` is the exactly-once settlement plus the buffer as one value.
  It buffers events while pending and delivers each routed event only after an atomic drain, so the
  replay always comes first. It rejects events after any other settlement.
  `ContextBuilderRouteSettlementPolicy` holds the precedence tables:
  - the route-wait outcome → settlement mapping (a timeout means ownership was lost);
  - the provider-completion step (a routing signal observed first, otherwise the completion
    authority);
  - the per-settlement join plan: which tasks are cancelled and joined, whether unrouted events are
    replayed, and the outcome.
- **Race.** `ContextBuilderRouteSettlementRace.run(_:host:limits:isolation:)` owns the route-wait,
  stream, and watchdog tasks and the outer-cancellation relay, and applies the join plan in a fixed
  order: cancel, join the stream, join the route wait, replay, return. The caller's actor is a
  required `isolated any Actor` parameter. Every task captures it, so the whole race runs on that
  actor and settlement, buffering, and delivery never interleave within a step. A nonisolated
  caller cannot run it. Outer cancellation cancels the tasks and hands `.cancelled` to the actor
  through a relay task, as the former `Task { @MainActor in settle(.cancelled) }` did.
  `ContextBuilderRouteSettlementHost` is the port. It supplies:
  - the route authority (wait, current routing signal, completion authority);
  - the watchdog sleep, connection probe, and report;
  - admission (accepts events, run progress) and the provider-error rendering;
  - the event descriptor;
  - synchronous delivery (route commit, routed event, unrouted replay), each paired with an
    asynchronous `publish`;
  - observation hooks.
- **App adapter.** `ContextBuilderAgentViewModel.ProviderRouteSettlementHost` is a main-actor
  host with an isolated conformance. It keeps the bootstrap lease (behind
  `ContextBuilderRunRouteAuthority`, adapted by `ContextBuilderLeaseRouteAuthority`), session and
  run-registry admission, the run log, bindings, preview, discovery activity, and the DEBUG test
  hooks. The `AIStreamResult` descriptor mapping and the outcome mapping to
  `ContextBuilderRunTerminalOutcome` also stay in the app; the mapping keeps the
  `mcp_completed_without_route` and `mcp_routing_failed` text. The view model calls the race with
  `isolation: MainActor.shared`. `ContextBuilderRouteSettlementCoordinator` is deleted. The host's
  async witnesses are explicitly `@MainActor`. Under an isolated conformance, an async member of a
  `@MainActor` class that witnesses a `nonisolated(nonsending)` requirement otherwise takes the
  requirement's isolation. It still runs on the main actor, because the race calls it there, but
  it cannot touch main-actor state synchronously.
- **Guardrail.** `headless_runtime_guardrails.sh` requires the race core. It rejects
  `AIStreamResult`, `ViewModel`, `WindowState`, and `MCPBootstrapLease` in the core directory and
  any return of the coordinator. It also requires the view model to settle through the core. The
  existing domain-runtime MainActor and UI import checks cover the new files.
- **Not changed.** Buffer limits (64,000 characters and 256 events), event accounting, the
  protected-event retention order, and the settlement precedence. The route-commit sequence is
  unchanged: begin provider-stream progress, then drain, replay, and log in one step, then report
  activity. The per-event checks and DEBUG hook order, the watchdog, and the error text are
  unchanged too.
- **Not claimed.** Direct headless still has no nested discovery. Its `context_builder` goes to
  `DirectHeadlessOracleAdapter` (a frozen pack or instructions straight to the Oracle), so there is
  no headless route authority or provider host in production. M16 makes the settlement boundary
  consumable by such a host. Headless discovery parity is not claimed.

Evidence: `ContextBuilderRouteSettlementTests` (domain runtime) covers descriptor classification and
grapheme counting, zero limits, coalescing, both eviction orders with exact dropped totals and
summary text, machine dispositions (including a lazy descriptor once routed), and every precedence
table. Twelve race tests (fifteen scripted scenarios) run on the main actor and on a private actor
with its own serial executor. Each asserts the same report and ordered host trace on both, and that
every host callback ran on the race's actor. The scenarios are: route commit with buffered replay before later events;
completion fenced without a route; completion committed by the authority; provider failure before
the route; ownership loss; outer cancellation; rejected admission; provider failure after the
route; routing signals observed at completion; the watchdog with and without an observed
connection; a detached host; and overflow accounting reaching the commit.
`ContextBuilderRouteSettlementAppParityTests` checks the `AIStreamResult` mapping against a
verbatim copy of the retired coordinator over a seeded corpus (7 limit configurations × 3 seeds ×
300 operations; drained order, dropped totals, and buffered size compared after every step). It
checks the outcome and route mappings, then runs the production view-model race (a registered run
record, a scripted route authority) and a headless actor host over the same core and route
authority for six scripted runs, comparing output, drop summaries, and outcomes.

Conductor evidence: the first focused run (`02027dd8`) failed to compile the app host. Its async
witnesses had taken the requirement's `nonisolated(nonsending)` isolation (see the app adapter
bullet) and were marked `@MainActor`. The focused rerun `0ba18582` then passed 83/83:

- `RepoPromptTests` 64/64. The two new app suites ran, plus the existing Context Builder suites that
  drive real provider streams and routing: `ContextBuilderMultiRootDiscoveryTests` (27, real MCP
  routing), `ContextBuilderGracefulShutdownTests`, `ContextBuilderGroupedSupervisionTests`,
  `ContextBuilderSelectionPrerequisiteTests`, `ContextBuilderWatchdogStabilityTests`, and
  `ContextBuilderRunStateContractTests`.
- `RepoPromptDomainRuntimeTests` 19/19.

A repeat of the two new suites passed 24/24 (`75d654d8`). `conductor lint` (`d593bd06`),
`conductor guardrails` (`5df0f07d`: source layout, allowlist, licenses, and headless runtime), and
`swift-build --product all` (`3846c965`) passed. The builds used the locally restored, untracked
official Sparkle 2.9.2 dSYMs for Xcode 27; no Vendor file is part of this change. Not run: the full
root test suite, live MCP smoke, and a release-configuration build.

### M17 — opt-in direct-headless Context Builder discovery

Before M17, direct headless could not turn raw instructions into a selection. `context_builder` with
`instructions` sent them unchanged to one Oracle conversation (roster of one) or failed with
`context_pack_required` (grouped roster), so a third-party host could not get a discovered selection
or a frozen pack without the app.

- **Opt-in, unchanged default.** `REPOPROMPT_MCP_HEADLESS_CONTEXT_DISCOVERY=1` (also `true`, `yes`,
  `on`) enables discovery for a raw-instruction `context_builder` call on a direct-headless process.
  Without it, both established contracts are byte-for-byte unchanged, including the error text. The
  opt-in is process-level on purpose. The canonical tool schema is shared with the app, so a per-call
  argument would have changed the app-bound catalog, its fingerprints, and the generated review
  snapshot. `context_pack_ref` calls ignore the opt-in.
- **Core (`RepoPromptDomainRuntime/ContextBuilder`, `package`, no MainActor or UI).**
  `ContextBuilderDiscoverySnapshot` freezes the bound context once: identity, workspace and context
  revisions, physical roots, prompt, and selection. `ContextBuilderFrozenWorkspace` serves
  `get_file_tree`, `file_search`, `read_file`, and `get_code_structure` from that snapshot. It uses
  `MCPDomainCanonicalWorkspaceService` with the same bounds, ignore layers, and symlink policy as the
  headless tools, and an adapter whose mutation hook always refuses. Selected paths are admitted
  through `HeadlessReadAuthority`. Relative paths resolve under exactly one root, and anything
  outside the roots is refused. A final symbolic link, or a symlinked directory component under
  `skip_symlinks`, is refused, as is a canonical escape, a directory, a FIFO, and a file above the
  read limit. `ContextBuilderDiscoveryEngine` runs the loop:
  1. Exploration, under a wall-clock deadline: at most 12 provider replies, each one JSON object with
     up to 8 tool calls or a `final` answer. Replies inside prose or code fences are accepted, and two
     malformed replies are answered with a protocol error before the run fails. `manage_selection`
     edits a staged in-memory selection only. Any other tool name, including `apply_edits` and
     `file_actions`, is refused without being executed. Tool results are capped at 16,000
     characters, and the oldest results are elided to keep each prompt within 240,000 characters.
  2. Validation: the frozen roots are rechecked (a root that moved or disappeared is
     `discovery_context_changed`), and every selected path is admitted again. At most 48 files.
  3. Pack: files are read through the contained `O_NOFOLLOW` walk into one canonical
     `OracleFrozenContextPack`. It holds a task section with the mode directive, the original
     instructions when they differ from the clarified prompt, a file map, and the file contents,
     with root-relative display paths as provenance. The pack is capped at 1,500,000 bytes and
     stored content-addressed.
  4. Commit through the host's `ContextBuilderDiscoveryCommitter` port.

  The deadline covers exploration only, so it can never interrupt a commit. Every failure is typed
  (`discovery_*`, description led by the code, with a retryability flag) and writes no selection.
- **Compare-and-set commit.** `DirectHeadlessDomainContext.commitDiscoveredSelection` writes only if
  the connection still resolves to the frozen context with the same physical roots and the same
  workspace and context revisions. The store command carries both expected revisions and
  `conflictRecoveryPolicy: .failClosed`, so a concurrent durable writer is never overwritten by
  replay. An identical selection is a no-op receipt (`selection_committed: false`), because a
  context-scoped replacement that changes no context is a store conflict. Nothing after the store
  command can throw.
- **Provider.** Each turn is one `codex exec` with the new `.contextDiscovery` purpose (read-only
  sandbox) and an explicitly empty child-launch carrier. The discovery process therefore cannot
  redeem the private tool endpoint, and its only RepoPrompt tools are the frozen protocol tools.
  Discovery runs on the roster primary, or on the `model` override.
- **Oracle consumption.** `DirectHeadlessOracleAdapter` plans discovery as a new `.discovery`
  prepared route. With `plan`, `question`, or `review`, a multi-member roster keeps its grouped plan
  (claim and lane carriers) and consumes the discovered pack through
  `buildContext(arguments:request:discoveredInput:)`. The `OracleInput` is identical to what a
  `context_pack_ref` naming that pack resolves to. A roster of one sends the pack content to a direct
  conversation. `clarify` or no response type plans the primary only and stops after discovery. The
  reply carries `selection`, `selected_paths`, `prompt`, `file_count`, `context_pack_ref`,
  `selection_committed`, and `discovery` counts, plus the Oracle fields. A failure after the commit is
  `oracle_failed_after_discovery` and names the committed file count and the pack reference.
- **Side fix: non-blocking leaf open.** `HeadlessReadAuthority` now opens every leaf with
  `O_NONBLOCK`, refuses anything that is not a regular file, then restores blocking mode before
  reading. Before this, headless `read_file` or `get_code_structure` on a FIFO waited for a writer
  forever. That contradicted M8C's typed refusal of non-regular files, and it would have pinned the
  discovery deadline, because blocking work is awaited rather than abandoned. Regular-file reads are
  unchanged.
- **Guardrail.** `headless_runtime_guardrails.sh` requires the discovery core. It rejects write
  entry points in the core (`applyFileEdits`, `manageFiles`, physical mutation capabilities,
  `workspaceStore`) and requires the headless adapter to use the core with the read-only discovery
  purpose.

Evidence: `ContextBuilderDiscoveryTests` (domain runtime, 17) drives the engine with scripted
providers over a real temporary workspace and records the commit and pack ports. It covers:

- the happy path, with the exact canonical pack, its storage, the commit over the frozen snapshot,
  and the prompt and transcript contents;
- a final selection that replaces and de-duplicates the staged one;
- refused `apply_edits` and `file_actions`, with the file unchanged;
- staged symlink, outside, directory, and symlinked-component paths rejected without changing the
  staged selection;
- final inadmissible paths failing closed with no commit and no pack (symlink, symlinked
  component, outside, directory, FIFO, and missing);
- a file swapped for a symlink after staging;
- a moved root;
- the turn limit and the last-turn warning;
- malformed-reply repair and the protocol violation past the limit;
- provider failure, cancellation during a turn, and the exploration deadline;
- the selection, pack, and empty-selection budgets;
- a committer conflict;
- prompt elision under a small budget;
- a FIFO `read_file` returning a typed error;
- the reply parser.

`DirectHeadlessContextDiscoveryTests` (9) runs raw instructions through the real backend,
workspace, pack store, CAS, and Oracle routes, with a fake `codex` that plays the discovery model and
the Oracle lanes. It covers:

- discovery, commit, and one frozen pack consumed by a two-lane group. Discovery turns are
  read-only with no carrier. The group turn's input references the pack, each lane's stdin equals
  the pack, and `apply_edits` was refused;
- `clarify` with no Oracle, then its reference consumed by a later grouped `context_pack_ref`;
- a single-member `question` answered through a direct conversation;
- unchanged opt-out contracts;
- a discovery provider failure, with no selection written and no group created;
- a context edited while discovery was blocked in a turn, failing closed through the backend;
- cancellation mid-turn draining the provider process and writing nothing;
- the CAS commit in isolation (stale, applied, identical no-op, superseded);
- the purpose and opt-in parsing.

Conductor evidence. The first focused run (`a46c394a`) failed two expectations:

- The engine did not unwrap an `NSError` description; `describe` now reads
  `NSLocalizedDescriptionKey`.
- The CAS test reused one invocation ID for a prompt edit and the commit. The store correctly
  refused that as `operation_id_reused_with_different_command`, and the test now uses one invocation
  per call.

The rerun (`760c9e6f`) passed 25/25. On the settled tree, the final focused run (`1a2fdb81`) passed
331/331. That is `RepoPromptTests` 148 and `RepoPromptDomainRuntimeTests` 183, covering the new
suites plus these existing ones:

- the direct-headless Oracle group, composition, and read-authority suites;
- ignore, symlink, and code-structure resilience;
- the canonical workspace bounds and search semantics;
- protected-mutation security;
- the Oracle group contracts, runtime, and claims;
- standalone composition and the read tool provider;
- route settlement and the frozen pack;
- the `get_code_structure` provider and orchestrator;
- the backend parity harness.

A repeat of the two new suites (`8293e108`) passed 26/26. `conductor lint` (`2deacd6a`),
`conductor guardrails` (`da47f16b`), and `swift-build --product all` (`f590158a`) passed. Builds used
the locally restored, untracked official Sparkle 2.9.2 dSYMs for Xcode 27; no Vendor file is part of
this change. Not run: the full root suite, a live MCP smoke with a real `codex` provider, and a
release-configuration build.

- **Not claimed.** This is not app Context Builder parity. There is no tab, agent session, run
  record, transcript, preview, or token accounting. The app's nested discovery agent and its M16
  route settlement are not used, and `context_builder.agent`/`context_builder.model` are not
  consulted.

Remaining gaps:

- The protocol is a JSON text loop over one-shot `codex exec` turns, not native tool calling through
  the private endpoint. Every turn resends the bounded transcript, and `codexExec` is the only
  headless provider.
- The clarified prompt is returned and packed but not written to the context. The selection is
  whole files only (no slices or codemap-only entries), budgeted in bytes rather than tokens, and the
  pack carries no codemaps or file tree.
- Grouped lane carriers are prepared at admission and keep the 60-second launch-token lifetime.
  After a longer discovery, lane children cannot redeem the private tool endpoint. The pack itself
  is self-contained.
- A run rejected at or after the content-addressed store can leave one unreferenced pack artifact.
  There is no artifact collection.
- The discovery `codex` process can still read files through its own sandboxed shell. The
  authority bounds what is selected, packed, and committed, not what the model reads.
- `export_response` is still ignored by direct headless.
- A per-call opt-in needs a shared-schema change that the app must also accept or reject.

### Integration onto main (#1081 typed prerequisites, #994 non-Git Code Maps)

The M8A–M13 branch was merged onto `origin/main` `a5586936`, which had independently landed #1081
(typed selection prerequisites, also fixing #1071), #994 (Code Maps in non-Git folders), and the
#1089/#1092 cancelled-save convergence. What changed in the M8 contracts:

- **Selection prerequisites (M8I and #1081).** The merged contract keeps #1081's payload-free
  `MCPSelectionPrerequisiteError`, its description text, and
  `MCPServerViewModel.requireReadFileAutoSelectionPrerequisite` (drain, then a post-drain task
  cancellation check, then classification) at all seven sites. M8I's execution-contract rendering
  stays, under #1081's codes `selection_prerequisite_deferred` / `selection_prerequisite_invalidated`:
  retryable, `mutation_state` `not_applied`. M8I's `tool_prerequisite_selection_*` codes never shipped
  and are retired, and the `prerequisite` requirement field went with the payload. The description
  already leads with the code, so the default-mode renderer does not prefix it again (the code
  appears once); raw JSON carries it in `code` and in `error`.
- **Terminal code-map roots (M8U/M8V and #994).** #994 finishes every terminal eligibility result as
  `terminalUnavailable` with a sticky `rootTerminal` setup disposition, which removes M8V's
  "superseded, so `notInitialized`" defect by construction, and it renames `notGitRepository` to
  `sourceRootUnavailable`. `codemapRootUnavailableReason` stays the single source for root status and
  the structure query. It checks catalog-recovery exhaustion, then worker-recovery exhaustion, then a
  `terminalUnavailable` launch: `bareRepository` or `invalidGitLayout` from the disposition, otherwise
  `sourceRootUnavailable`. After that come `retryExhausted` and a bare/invalid disposition without a
  launch. The no-graph answer maps these to `git_root_unavailable` (with #994's "no usable source
  authority" message), `git_bare_repository`, `git_layout_invalid`, `graph_retry_exhausted`, and
  `graph_worker_recovery_exhausted`; otherwise it follows #994's rule that a terminal setup disposition
  (which a demand can install with no launch) is unavailable. Under #994 a Git preflight answering
  `nonGit` without a fresh local proof is transient, so it exhausts as non-retryable
  `graph_retry_exhausted` rather than M8U's `git_root_unavailable`. `prioritizeCodemapGraphIndexNow`
  keeps a `terminalUnavailable` launch (`promoted`) instead of relaunching it.
- **M8T parity.** With the non-Git Code Maps opt-in on, the app maps a plain root from filesystem
  source authority, so the former documented divergence is now an `.equal` scenario
  (`testNonGitRootCodeStructureParityWithNonGitCodeMaps`); the harness pins the opt-in explicitly.
- **M8Z attribution.** #994's new detach paths carry origins `nonGitCodeMapsSettingChanged` and
  `engineRootAuthorityInvalidated`; #994's recovery-ownership guard on watcher deltas keeps the
  `watcherDelta` fence site label.
- **Not changed (carried from #994):** with the opt-in off (the release default) a plain root never
  launches. Until a signature demand installs its `rootTerminal(.nonGit)` disposition, a
  `get_code_structure` call without signatures answers the retryable pending `graph_indexing`, and root
  status stays `notInitialized` ("Preparing…"). Making that state terminal would change the Code Map
  sidebar, which is a product decision outside this integration.
- **First compile and run of M12/M13.** The integration build is the first time the M12/M13 source
  compiled and ran. It used locally placed, untracked official Sparkle 2.9.2 dSYMs for the Xcode 27
  `DebugSymbolsPath` check, and they are not committed. One M13 expectation was wrong:
  `testPathGlobHeuristicsTable` expected two candidates for `*.swift`. `pathGlobCandidates` is the
  app's pre-M12 `SearchMatch` helper moved verbatim, and because `*.swift` does not end in a wildcard
  it also yields `*.swift*` and `**/*.swift*`. The test now expects all four candidates; the shared
  heuristic is unchanged.

### Later milestones (not started in this pass)

- Remaining MainActor/GUI decoupling of the tier-0 read path (per-hop inventory first).
- Cross-backend app-versus-headless parity and latency harness beyond the read boundary (M8S covers
  `read_file` and `get_code_structure`, M12 `file_search`, at the tool layer).
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
