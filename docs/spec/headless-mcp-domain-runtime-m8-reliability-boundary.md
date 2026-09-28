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

### Later milestones (not started in this pass)

- Remaining MainActor/GUI decoupling of the tier-0 read path (per-hop inventory first).
- Cross-backend app-versus-headless parity and latency harness beyond the read boundary (M8S covers
  `read_file` and `get_code_structure` at the tool layer).
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
