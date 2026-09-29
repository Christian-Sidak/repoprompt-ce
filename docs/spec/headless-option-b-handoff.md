# Option B headless reliability handoff (frozen after M22)

Branch: `wt/mcp-headless-reliability-core-20260929-r3`. This is a prototype for review, not a production cutover. The app backend remains the default; direct-headless Context Builder discovery is opt-in. Do not assume the branch is current with `origin/main`: the later, uncommitted #1113 integration was aborted at the freeze request. No branch push or main merge is part of this handoff.

## Completed milestones

| Milestone | Outcome |
| --- | --- |
| M8A–D | Proxy startup/terminal settlement, shared direct-headless admission, bounded read backends, deterministic contract coverage. |
| M8E–J | App `tools/call` routing count off the main actor; bounded disconnected replay; local failure taxonomy; typed retry/prerequisite guidance; restored MCP host tests. |
| M8K–Q | One app global-ignore authority, shared ignore compiler/layer engine, headless ignore enumeration, nested-Git and root-contained symlink parity, explicit `read_file` authority gates. |
| M8R–T | Bounded/fault-isolated headless code-structure reads and app-versus-headless read/code-structure parity and latency harnesses. |
| M8U–Z | Terminal code-map retry/invalid-Git disposition, cancelled graph-index admission wake-up, transient-reason diagnostics, cancelled registration recovery, and launch/missing-signature attribution tests. |
| M9–M11 | Move app code-structure reply assembly/encoding off the main actor; close encode and post-await file-tool authority races. |
| M12–M13 | `file_search` app-versus-headless parity harness and closure of ordering, path-regex, line-model, schema, and test-race gaps. |
| M14 | Safer global-ignore migration/load behavior and common `max_results` range semantics. |
| M15 | App-independent `get_code_structure` query core. |
| M16 | Shared Context Builder route/stream settlement core. |
| M17 | Opt-in direct-headless Context Builder discovery: bounded tool loop, selection/frozen-pack handoff, Oracle group route, and CAS commit. |
| M18–M20 | Truthful discovery settlement; carriers minted at handoff; multi-root spellings; handoff pinned to committed context and root headings; provider launch pinned to that context with typed pre-launch settlement. |
| M21 | Launch-scoped root authority for discovered Oracle lanes; follow-ups cover in-flight child calls and spawn-report ordering. |
| M22 | Extend the launch-scoped root lease to carrier-bearing direct-headless agent, Oracle, and grouped lanes; add mutation-conflict and cancellation coverage. |

The detailed design, per-milestone evidence, and limitations are in `docs/spec/headless-mcp-domain-runtime-m8-reliability-boundary.md` and `docs/architecture/headless-mcp-runtime.md`.

## Half-done, bugs, and risks

- **M22 review P2: worktree opt-out is ineffective.** `inherit_worktree=false` can still take the leased parent's worktree overlay in `DirectHeadlessDomainContext.prepareSessionRootOverlay`; a child may launch and write in that worktree. Fix the process-level overlay base and add a deterministic cwd/tool/write-target test.
- **M22 review P2: early cancel can be lost.** `DirectHeadlessProviderCoordinator` publishes the session before storing the launch task. A cancel during `noteSnapshot` may be acknowledged yet allow provider launch. Add pending-start cancellation state and a barrier test.
- Provider-backed headless Context Builder was not proved end to end. A disposable-profile direct-headless initialize/tools-list probe listed 21 tools, but the provider-backed `context_builder` probe returned `mcp_or_provider_error`; the cause was not diagnosed. No live CE app smoke, release build, or third-party harness acceptance test was completed.
- Root leasing blocks in-process root mutations during a lane, but does not prevent external filesystem writers. A hung provider/child invocation can retain the lease until cancellation, exit, or shutdown. On-disk root rename/symlink swaps and resumed frozen-pack/current-binding checks need separate security review. `file_search` still has documented PCRE2/ICU and scenario gaps in the M12/M13 spec.
- #1113's subsequent `RepoPromptMCPCore` extraction is **not integrated** on this branch. Reconcile it only in a separately authorized follow-up, not by treating this frozen branch as merge-ready.

## Validation and app-visible changes

- M22 focused tests: 91/91; root suite: 3,955 total, 2 opt-in skips, 0 failures (`35fe4987` conductor ticket prefix). M22 lint passed (`3c5a621c`). The M21 suite had 3,942 total, 2 skips, 0 failures. These are local test results, not live MCP or release evidence.
- Added/extended deterministic MCP domain host, direct-headless composition and provider/group, read/codemap/search parity, root-authority/lease/cancellation, settings and code-map regression tests. See the milestone spec for test names and tickets. Some coverage is in-process and does not prove real socket/provider behavior.
- Non-headless behavior changed in the default app backend too: app MCP routing and code-structure work moved off the main actor; file-tool authority is rechecked after awaits; typed prerequisite/retry errors and disconnected replay changed MCP responses; global-ignore migration/load handling and `file_search` range/schema changed; code-map terminal/retry/admission handling changed; shared search heuristics and Context Builder settlement replaced app-local implementations. Review these paths separately before any cutover.

Freeze disposition: leave this branch/worktree intact, no push, no further milestone, and no new main integration until the user chooses whether to port or rebuild.
