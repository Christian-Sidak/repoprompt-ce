import CryptoKit
import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
@testable import RepoPromptMCP
import XCTest

#if DEBUG
    /// M8S/M8T/M12: in-process app-versus-headless parity and latency harness for the MCP read boundary
    /// (`read_file`, `get_code_structure`, `file_search`).
    ///
    /// Both backends run against the same fixture root, ignore defaults, and `skip_symlinks` policy:
    /// the app through the real window tools of a registered, activated `WindowState`
    /// (`InProcessMCPWindowServerFixture.makeRegisteredWindow`), headless through
    /// `MCPDomainCanonicalWorkspaceService` with the production `DirectHeadlessDomainContext.resolvePath`.
    ///
    /// Outcomes are normalized per tool. `read_file`: a thrown error and an error DTO are both
    /// `refused`; content is compared after one trailing newline is removed. `get_code_structure`:
    /// the seed files that received a code map, each with its text — the app's rendered
    /// `content` (a path/imports header followed by the Code Map API description) and headless
    /// `signatures` (the same API description from the shared `CodeMapSyntaxArtifactBuilder`); the two
    /// are equivalent only when every seed name matches and each app text ends with the non-empty
    /// headless text. App graph expansion (`related` files) is app-only and not compared. An app reply
    /// with `unavailable` status is a terminal `unavailable(codes)`; one still `pending` after the
    /// bounded settle wait is `unsettled`. Neither is ever a success or a refusal. `file_search`: the
    /// sorted root-relative path hits and content hits (path, 1-based line, line text), or the count for
    /// `count_only`; an app error field or a thrown error is `refused`. A `SearchExpectation` (paths that
    /// must and must not appear, or an exact count) makes each search scenario non-vacuous.
    ///
    /// Each scenario declares an authority class per backend (`mustSucceed` / `mustRefuse` /
    /// `mustBeUnavailable`) and a relation (`equal`, or a documented `knownDivergence` that must still
    /// diverge, so the table cannot silently go stale). Outcomes must be stable across iterations.
    /// Latency is sampled per backend with interleaved iterations after a warm-up and reported
    /// (p50 / max), never asserted against a threshold.
    @MainActor
    final class MCPBackendParityHarness {
        enum Authority: String, Encodable {
            case mustSucceed = "must_succeed"
            case mustRefuse = "must_refuse"
            /// The backend must answer with a terminal `unavailable` carrying `Scenario.unavailableCode`.
            case mustBeUnavailable = "must_be_unavailable"
        }

        enum Relation: Equatable {
            case equal
            case knownDivergence(String)
        }

        enum Tool: String, Encodable {
            case readFile = "read_file"
            case codeStructure = "get_code_structure"
            case fileSearch = "file_search"
        }

        /// `file_search` expectations checked against every backend whose authority is `mustSucceed`, so
        /// an empty or broken answer cannot satisfy a scenario just because both backends agree.
        struct SearchExpectation {
            /// Root-relative paths that must appear (as a path hit or a content hit).
            var include: [String] = []
            /// Root-relative paths that must never appear (ignored, linked, or outside-root files).
            var exclude: [String] = []
            /// For `count_only`: the exact count every succeeding backend must report.
            var count: Int?
        }

        struct Scenario {
            let name: String
            let tool: Tool
            let arguments: [String: Value]
            /// Applies to both backends unless `appAuthority` overrides it for the app.
            let authority: Authority
            let relation: Relation
            /// For `mustRefuse`: a substring the headless refusal detail must contain, so a refusal
            /// for the wrong reason (for example a broken harness path) cannot pass vacuously.
            var headlessRefusal: String?
            var appAuthority: Authority?
            /// For `mustBeUnavailable`: an issue code the unavailable answer must carry.
            var unavailableCode: String?
            /// `file_search` only.
            var search: SearchExpectation?

            var effectiveAppAuthority: Authority {
                appAuthority ?? authority
            }
        }

        struct MappedFile: Equatable {
            let name: String
            let text: String
        }

        struct ContentHit: Equatable, Comparable, CustomStringConvertible {
            let path: String
            let line: Int
            let text: String

            static func < (lhs: ContentHit, rhs: ContentHit) -> Bool {
                (lhs.path, lhs.line, lhs.text) < (rhs.path, rhs.line, rhs.text)
            }

            var description: String {
                "\(path):\(line)"
            }
        }

        /// Normalized `file_search` answer: root-relative path hits and content hits (1-based line and
        /// the matched line's text), each sorted; or, for `count_only`, the reported count alone.
        struct SearchHits: Equatable {
            var paths: [String] = []
            var content: [ContentHit] = []
            var count: Int?

            var touchedPaths: Set<String> {
                Set(paths).union(content.map(\.path))
            }
        }

        enum Outcome: Equatable, CustomStringConvertible {
            /// `read_file` content.
            case content(String)
            /// `get_code_structure`: seed files that received a code map, sorted by name.
            case mapped([MappedFile])
            case refused
            /// A terminal `unavailable` answer, with its issue codes.
            case unavailable([String])
            /// Still `pending` after the bounded settle wait.
            case unsettled
            /// `file_search`: an answered search (possibly empty; `SearchExpectation` makes it non-vacuous).
            case search(SearchHits)

            var isSuccess: Bool {
                switch self {
                case .content, .search: true
                case let .mapped(files): !files.isEmpty
                case .refused, .unavailable, .unsettled: false
                }
            }

            var description: String {
                switch self {
                case let .content(text): "content(\(text.count) chars)"
                case let .mapped(files): "mapped(\(files.map(\.name).joined(separator: ",")))"
                case .refused: "refused"
                case let .unavailable(codes): "unavailable(\(codes.joined(separator: ",")))"
                case .unsettled: "unsettled"
                case let .search(hits):
                    if let count = hits.count {
                        "count(\(count))"
                    } else {
                        "search(paths=[\(hits.paths.joined(separator: ","))]"
                            + " content=[\(hits.content.map(\.description).joined(separator: ","))])"
                    }
                }
            }
        }

        struct Observation {
            let outcome: Outcome
            /// Error code or message, for the report only (never compared).
            let detail: String?
        }

        struct LatencySummary: Encodable {
            let samplesMS: [Double]
            let p50MS: Double
            let maxMS: Double

            init(samples: [Double]) {
                samplesMS = samples
                let sorted = samples.sorted()
                p50MS = sorted.isEmpty ? 0 : sorted[(sorted.count - 1) / 2]
                maxMS = sorted.last ?? 0
            }
        }

        struct ScenarioReport: Encodable {
            let name: String
            let tool: Tool
            let authority: Authority
            let appAuthority: Authority
            let expectedRelation: String
            let appOutcome: String
            let headlessOutcome: String
            let appDetail: String?
            let headlessDetail: String?
            let appStable: Bool
            let headlessStable: Bool
            /// Untimed wait for the app code-structure index before sampling (nil for `read_file`).
            let appSettleMS: Double?
            /// Whether the app code-map index reached quiescence before sampling (nil for `read_file`).
            let appQuiescent: Bool?
            /// App code-map pipeline state (store launch events with their origins, artifact-demand
            /// events, engine graph-index accounting, root status): captured when settling fails, and
            /// after sampling (`post_samples`) for every must-succeed code-structure scenario.
            let appDiagnostics: String?
            /// Code structure only: each measured app sample's state (`sampleState`), in order.
            let appSampleStates: [String]?
            /// Code structure only: the app state transitions seen while settling (bounded, timestamped).
            let appSettleTrace: [String]?
            let appLatency: LatencySummary
            let headlessLatency: LatencySummary
            /// Human-readable expectation failures; empty when the scenario passes.
            let violations: [String]
        }

        struct StageSummary: Encodable {
            let stage: String
            let dimensions: String
            let samples: Int
            let p50MS: Double
            let p95MS: Double
            let maxMS: Double
        }

        struct Report: Encodable {
            let iterations: Int
            let scenarios: [ScenarioReport]
            /// App-side `EditFlowPerf` stage breakdown, or nil when another capture held the recorder.
            let appStages: [StageSummary]?
            let notProven: [String]
        }

        static let notProven = [
            "transport, JSON-RPC envelope (isError vs protocol error), lanes, leases, and watchdog",
            "the app socket/connection-manager path (both backends are driven at the tool layer)",
            "app code-structure graph expansion (related files; headless has no graph)",
            "file_search worktree display projection (the in-process fixture binds no session worktree)",
            "file_search display spelling: app paths are compared root-relative (a root-name or absolute prefix "
                + "would be removed and reported as display=...); multi-root aliases are not exercised",
            "file_search result order, context_lines, limit/size-cap flags, and app auto-selection side effects "
                + "(hits are compared as sorted sets; app latency includes auto-selection)",
            "file_search regex dialect beyond the table (app PCRE2 vs headless ICU NSRegularExpression)",
            "multi-root namespaces, cold start, and large-tree performance",
            "absolute latency comparability across machines or runs"
        ]

        /// App error codes that mean the workspace or its freshness was not ready: infrastructure, not an
        /// authority decision, so they can never satisfy a `mustRefuse` scenario.
        static let appInfrastructureRefusalCodes = [
            "workspace_authority_", "workspace_freshness_timeout", "worktree_scope_unavailable",
            "workspace_readiness_", "search_backpressure"
        ]

        /// Upper bound on the untimed wait for the app code-map index to reach quiescence.
        static let appIndexSettleTimeout: Duration = .seconds(45)
        /// How long readiness must hold continuously to count as quiescent. App readiness is not
        /// monotonic after activation (the graph can restart, e.g. after activation-time Git data
        /// maintenance), so a single settled answer is not enough.
        static let appIndexQuiescenceWindow: Duration = .milliseconds(1500)

        let root: URL
        /// Retained for the harness's lifetime (window tools hold their runtime weakly); release with
        /// `close()`.
        private let appWindow: InProcessMCPWindowServerFixture.RegisteredWindow
        /// The app store's isolated code-map runtime (temporary artifact root, production binding
        /// engine and Git capability service), so no process-wide artifact state is read or written.
        private let codemapRuntime: CodemapStoreFixture
        private let appTools: [Tool: RepoPromptApp.Tool]
        private let headless: MCPDomainCanonicalWorkspaceService

        private init(
            root: URL,
            appWindow: InProcessMCPWindowServerFixture.RegisteredWindow,
            codemapRuntime: CodemapStoreFixture,
            appTools: [Tool: RepoPromptApp.Tool],
            headless: MCPDomainCanonicalWorkspaceService
        ) {
            self.root = root
            self.appWindow = appWindow
            self.codemapRuntime = codemapRuntime
            self.appTools = appTools
            self.headless = headless
        }

        /// Calls one app window tool once, without settling or sampling.
        func callApp(_ tool: Tool, arguments: [String: Value]) async throws -> Value {
            guard let appTool = appTools[tool] else {
                throw MCPError.internalError("app tool \(tool.rawValue) is not exposed")
            }
            return try await appTool(arguments)
        }

        /// Closes and unregisters the app window, then shuts down its code-map runtime.
        func close() async {
            await InProcessMCPWindowServerFixture.close(appWindow)
            await codemapRuntime.shutdown()
        }

        /// Activates `root` as the app workspace (after the caller has pinned the app's global ignore
        /// defaults to `globalPatterns`; the app crawl uses its default `skip_symlinks`, which headless
        /// mirrors) and builds both backends over it.
        ///
        /// `nonGitCodeMapsEnabled` is the app's non-Git Code Maps opt-in (#994). It is pinned here rather
        /// than inherited from the store's build-configuration default, so a non-Git scenario states
        /// which app behavior it compares against.
        static func make(
            root: URL,
            globalPatterns: String,
            nonGitCodeMapsEnabled: Bool = true
        ) async throws -> MCPBackendParityHarness {
            let codemapRuntime = try CodemapStoreFixture(name: "mcp-backend-parity")
            // Production Git classification and eligibility probes (unlike `CodemapStoreFixture.makeStore`,
            // which forces eligibility), so the app's Git gating for code structure stays real.
            let store = WorkspaceFileContextStore(
                enableCatalogShardShadowValidation: false,
                codemapRuntimeProvider: { try codemapRuntime.runtime() },
                nonGitCodeMapsEnabled: nonGitCodeMapsEnabled
            )
            let window: InProcessMCPWindowServerFixture.RegisteredWindow
            do {
                window = try await InProcessMCPWindowServerFixture.makeRegisteredWindow(
                    root: root,
                    workspaceFileContextStore: store
                )
            } catch {
                await codemapRuntime.shutdown()
                throw error
            }
            var appTools: [Tool: RepoPromptApp.Tool] = [:]
            do {
                appTools[.readFile] = try await InProcessMCPWindowServerFixture.tool(
                    named: MCPWindowToolName.readFile,
                    from: window.window.mcpServer
                )
                appTools[.codeStructure] = try await InProcessMCPWindowServerFixture.tool(
                    named: MCPWindowToolName.getCodeStructure,
                    from: window.window.mcpServer
                )
                appTools[.fileSearch] = try await InProcessMCPWindowServerFixture.tool(
                    named: MCPWindowToolName.search,
                    from: window.window.mcpServer
                )
            } catch {
                await InProcessMCPWindowServerFixture.close(window)
                await codemapRuntime.shutdown()
                throw error
            }
            let snapshot = DomainCanonicalWorkspaceSnapshot(
                identity: DomainContextIdentity(workspaceID: UUID(), contextID: UUID()),
                roots: [root],
                prompt: "",
                selection: []
            )
            let configuration = DomainIgnoreConfiguration(globalPatterns: globalPatterns, skipSymlinks: true)
            let headless = MCPDomainCanonicalWorkspaceService(adapter: DomainCanonicalWorkspaceAdapter(
                toolSnapshot: { _ in snapshot },
                readSnapshot: { _ in snapshot },
                mutate: { _, _ in snapshot },
                resolvePath: { raw, roots, allowMissingLeaf in
                    try DirectHeadlessDomainContext.resolvePath(raw, roots: roots, allowMissingLeaf: allowMissingLeaf)
                },
                ignoreConfiguration: { configuration }
            ))
            return MCPBackendParityHarness(
                root: root,
                appWindow: window,
                codemapRuntime: codemapRuntime,
                appTools: appTools,
                headless: headless
            )
        }

        /// Runs every scenario: an untimed settle (code structure), one warm-up, then `iterations`
        /// interleaved app/headless samples.
        func run(_ scenarios: [Scenario], iterations: Int) async -> Report {
            EditFlowPerf.resetDebugCaptureForTesting()
            let captureStarted = switch EditFlowPerf.beginDebugCapture(label: "mcp-backend-parity", maxSamples: 4000) {
            case .started: true
            case .busy: false
            }
            var reports: [ScenarioReport] = []
            for scenario in scenarios {
                let settle = await settleAppIndex(for: scenario)
                var sampleStates: [String]?
                var diagnostics: String?
                if settle?.quiescent == false {
                    diagnostics = await appCodemapDiagnostics()
                } else if settle != nil, scenario.effectiveAppAuthority == .mustSucceed,
                          await !(observeApp(scenario).outcome.isSuccess)
                {
                    // A settled but failed must-succeed answer (for example a terminal
                    // `graph_retry_exhausted`) records which launch path failed.
                    diagnostics = await appCodemapDiagnostics()
                }
                _ = await observeApp(scenario)
                _ = await observeHeadless(scenario)
                var appObservations: [Observation] = []
                var headlessObservations: [Observation] = []
                var appSamples: [Double] = []
                var headlessSamples: [Double] = []
                for _ in 0 ..< iterations {
                    let (app, appMS) = await Self.timed { await self.observeApp(scenario) }
                    appObservations.append(app)
                    appSamples.append(appMS)
                    if scenario.tool == .codeStructure {
                        // Untimed: attributes any change across samples to a concrete app state.
                        let rootAvailability = await appRootAvailability()
                        sampleStates = (sampleStates ?? []) + [Self.sampleState(app, rootAvailability: rootAvailability)]
                    }
                    let (headless, headlessMS) = await Self.timed { await self.observeHeadless(scenario) }
                    headlessObservations.append(headless)
                    headlessSamples.append(headlessMS)
                }
                if scenario.tool == .codeStructure, diagnostics == nil,
                   scenario.effectiveAppAuthority == .mustSucceed
                {
                    // Always recorded for answers that must succeed (bounded event windows), so a
                    // relaunch or a signature missing from one sample can be attributed to the store
                    // path that caused it, including in runs that pass.
                    diagnostics = await "post_samples " + appCodemapDiagnostics()
                }
                reports.append(Self.evaluate(
                    scenario,
                    app: appObservations,
                    headless: headlessObservations,
                    appSamples: appSamples,
                    headlessSamples: headlessSamples,
                    appSettleMS: settle?.milliseconds,
                    appQuiescent: settle?.quiescent,
                    appDiagnostics: diagnostics,
                    appSampleStates: sampleStates,
                    appSettleTrace: settle?.trace
                ))
            }
            var stages: [StageSummary]?
            if captureStarted {
                stages = EditFlowPerf.debugCaptureSnapshot(finish: true).stages.map {
                    StageSummary(
                        stage: $0.stageName,
                        dimensions: $0.sanitizedDimensions,
                        samples: $0.sampleCount,
                        p50MS: $0.p50MS,
                        p95MS: $0.p95MS,
                        maxMS: $0.maxMS
                    )
                }
            }
            return Report(iterations: iterations, scenarios: reports, appStages: stages, notProven: Self.notProven)
        }

        /// Untimed, bounded wait for the app code-map index to become quiescent: the code-structure tool
        /// answers settled and every app root reports `ready` (or terminal `unavailable`) through the
        /// store's root status, continuously for `appIndexQuiescenceWindow`. Not reaching quiescence
        /// within `appIndexSettleTimeout` is a violation in `evaluate`, never an exemption.
        private func settleAppIndex(
            for scenario: Scenario
        ) async -> (milliseconds: Double, quiescent: Bool, trace: [String])? {
            guard scenario.tool == .codeStructure else { return nil }
            let clock = ContinuousClock()
            let start = clock.now
            var readySince: ContinuousClock.Instant?
            var trace: [String] = []
            var lastState: String?
            while clock.now - start < Self.appIndexSettleTimeout {
                let observation = await observeApp(scenario)
                let settled = observation.outcome != .unsettled
                let rootsReady = await appRootsAreQuiescent()
                let rootAvailability = await appRootAvailability()
                let state = Self.sampleState(observation, rootAvailability: rootAvailability)
                if state != lastState {
                    lastState = state
                    trace.append("\(Int(Self.milliseconds(clock.now - start)))ms:\(state)")
                    if trace.count > Self.settleTraceLimit { trace.removeFirst(trace.count - Self.settleTraceLimit) }
                }
                if settled, rootsReady {
                    let since = readySince ?? clock.now
                    readySince = since
                    if clock.now - since >= Self.appIndexQuiescenceWindow {
                        return (Self.milliseconds(clock.now - start), true, trace)
                    }
                } else {
                    readySince = nil
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return (Self.milliseconds(clock.now - start), false, trace)
        }

        static let settleTraceLimit = 12

        /// A compact, privacy-safe description of one app observation: the outcome summary (file names
        /// only), the reply detail (status and issue codes), a short SHA-256 digest of the mapped text
        /// (never the text), and the app roots' availabilities.
        static func sampleState(_ observation: Observation, rootAvailability: String) -> String {
            let digestInput: String? = switch observation.outcome {
            case let .mapped(files): files.map { "\($0.name)\u{0}\($0.text)" }.joined(separator: "\u{1}")
            case let .content(text): text
            case let .search(hits): "\(hits)"
            case .refused, .unavailable, .unsettled: nil
            }
            let digest = digestInput.map { input in
                SHA256.hash(data: Data(input.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
            } ?? "-"
            return "\(observation.outcome)|\(observation.detail ?? "-")|digest=\(digest)|roots=\(rootAvailability)"
        }

        private func appRootAvailability() async -> String {
            let status = await appWindow.window.workspaceFileContextStore.currentCodemapRootStatusUpdate()
            return status.roots.map(\.availability.rawValue).sorted().joined(separator: ",")
        }

        private func appRootsAreQuiescent() async -> Bool {
            let status = await appWindow.window.workspaceFileContextStore.currentCodemapRootStatusUpdate()
            return !status.roots.isEmpty && status.roots.allSatisfy { root in
                root.availability == .ready || root.availability == .unavailable
            }
        }

        /// App code-structure issue codes that mean the requested path itself was refused (not found in
        /// the workspace catalog, which excludes links and outside-root targets).
        static let appCodeStructurePathRefusalCodes: Set = ["path_not_found"]

        /// Normalizes an app code-structure reply. Seeds make it `mapped`. With no seeds, an answer
        /// whose issues are all path refusals is `refused`; otherwise `pending` is `unsettled`, any other
        /// status is `unavailable` with its codes (terminal, e.g. `git_root_unavailable`), and an empty
        /// `ok` answer is `mapped([])` — none of which is a success or a refusal.
        static func classifyAppCodeStructure(
            status: ToolResultDTOs.CodeStructureReplyDTO.Status,
            seeds: [MappedFile],
            issueCodes: [String]
        ) -> Outcome {
            if !seeds.isEmpty { return .mapped(seeds.sorted { $0.name < $1.name }) }
            if !issueCodes.isEmpty, issueCodes.allSatisfy(appCodeStructurePathRefusalCodes.contains) {
                return .refused
            }
            switch status {
            case .pending: return .unsettled
            case .unavailable: return .unavailable(issueCodes.sorted())
            case .ok, .partial: return .mapped([])
            }
        }

        /// A compact description of the app code-map pipeline for diagnosing an unsettled index.
        private func appCodemapDiagnostics() async -> String {
            let store = appWindow.window.workspaceFileContextStore
            var parts: [String] = []
            let events = await store.codemapGraphIndexBuildStoreEventsForTesting()
            parts.append("store_events=" + Self.describeStoreEvents(events))
            let demandEvents = await store.codemapDemandEventsForTesting()
            parts.append("demand_events=" + Self.describeDemandEvents(demandEvents))
            do {
                let accounting = try await codemapRuntime.runtime().bindingEngine().accounting()
                parts.append("engine_roots=" + accounting.graphIndexRoots.map { root in
                    "phase=\(root.phase) retry=\(root.retryAttempt) worker=\(root.workerPresent)"
                        + " completion=\(root.lastWorkerCompletionReason.map { "\($0)" } ?? "-")"
                        + " counts=\(root.progress.counts)"
                }.joined(separator: ";"))
            } catch {
                parts.append("engine=unavailable(\(error))")
            }
            let status = await store.currentCodemapRootStatusUpdate()
            parts.append("root_status=" + status.roots.map { root in
                "\(root.availability) unavailable=\(root.unavailableReason.map { "\($0)" } ?? "-")"
                    + " updates_pending=\(root.updatesPending)"
            }.joined(separator: ";"))
            return parts.joined(separator: " | ")
        }

        /// The last 40 store launch events, each labelled with its root (`r0`, `r1`, … in order of first
        /// appearance, never a path or identifier) and its offset in milliseconds from the first event.
        static func describeStoreEvents(
            _ events: [WorkspaceFileContextStore.CodemapGraphIndexBuildStoreEvent]
        ) -> String {
            var labels: [WorkspaceCodemapRootEpoch: String] = [:]
            for event in events where labels[event.rootEpoch] == nil {
                labels[event.rootEpoch] = "r\(labels.count)"
            }
            let origin = events.first?.uptimeNanoseconds ?? 0
            return events.suffix(40).map { event in
                let offset = event.uptimeNanoseconds >= origin ? (event.uptimeNanoseconds - origin) / 1_000_000 : 0
                return "\(labels[event.rootEpoch] ?? "r?")+\(offset)ms:\(event.kind):\(event.launchPhase)"
                    + (event.transientReason.map { ":\($0)" } ?? "")
                    + (event.origin.map { ":origin=\($0)" } ?? "")
            }.joined(separator: ">")
        }

        /// The last 60 artifact-demand events, each labelled with its file (`f0`, `f1`, … in order of
        /// first appearance, never a path or identifier) and its offset in milliseconds from the first
        /// event.
        static func describeDemandEvents(_ events: [WorkspaceFileContextStore.CodemapDemandEvent]) -> String {
            var labels: [UUID: String] = [:]
            for event in events where labels[event.fileID] == nil {
                labels[event.fileID] = "f\(labels.count)"
            }
            let origin = events.first?.uptimeNanoseconds ?? 0
            return events.suffix(60).map { event in
                let offset = event.uptimeNanoseconds >= origin ? (event.uptimeNanoseconds - origin) / 1_000_000 : 0
                return "\(labels[event.fileID] ?? "f?")+\(offset)ms:\(event.label)"
            }.joined(separator: ">")
        }

        // MARK: - Evaluation

        /// Whether two outcomes agree: exact equality, except code structure, where seed names must
        /// match and each app text must end with the corresponding non-empty headless text.
        static func equivalent(app: Outcome, headless: Outcome) -> Bool {
            guard case let .mapped(appFiles) = app, case let .mapped(headlessFiles) = headless else {
                return app == headless
            }
            return appFiles.map(\.name) == headlessFiles.map(\.name)
                && zip(appFiles, headlessFiles).allSatisfy { appFile, headlessFile in
                    !headlessFile.text.isEmpty && appFile.text.hasSuffix(headlessFile.text)
                }
        }

        static func evaluate(
            _ scenario: Scenario,
            app: [Observation],
            headless: [Observation],
            appSamples: [Double],
            headlessSamples: [Double],
            appSettleMS: Double? = nil,
            appQuiescent: Bool? = nil,
            appDiagnostics: String? = nil,
            appSampleStates: [String]? = nil,
            appSettleTrace: [String]? = nil
        ) -> ScenarioReport {
            var violations: [String] = []
            if appQuiescent == false {
                violations.append("app code-map index did not reach quiescence within the settle bound")
            }
            let appOutcome = app.first?.outcome ?? .refused
            let headlessOutcome = headless.first?.outcome ?? .refused
            let appStable = app.allSatisfy { $0.outcome == appOutcome }
            let headlessStable = headless.allSatisfy { $0.outcome == headlessOutcome }
            if !appStable { violations.append("app outcome changed across iterations") }
            if !headlessStable { violations.append("headless outcome changed across iterations") }

            let checks: [(String, Authority, Outcome)] = [
                ("app", scenario.effectiveAppAuthority, appOutcome),
                ("headless", scenario.authority, headlessOutcome)
            ]
            for (backend, authority, outcome) in checks {
                switch authority {
                case .mustSucceed:
                    if !outcome.isSuccess { violations.append("\(backend) must succeed but was \(outcome)") }
                case .mustRefuse:
                    // Only an explicit refusal counts; an unsettled, unavailable, or empty answer is not one.
                    if outcome != .refused { violations.append("\(backend) must refuse but was \(outcome)") }
                case .mustBeUnavailable:
                    let expected = scenario.unavailableCode ?? ""
                    if case let .unavailable(codes) = outcome, codes.contains(expected) {
                        break
                    }
                    violations.append("\(backend) must be unavailable with \(expected) but was \(outcome)")
                }
            }

            // An internal error is a harness or runtime failure, never an authority refusal; without this
            // a broken app runtime would satisfy every `mustRefuse` scenario vacuously.
            if appOutcome == .refused, let detail = app.first?.detail, detail.contains("-32603") {
                violations.append("app refused with an internal error, not an authority refusal: \(detail)")
            }
            if appOutcome == .refused, let detail = app.first?.detail,
               appInfrastructureRefusalCodes.contains(where: { detail.contains($0) })
            {
                violations.append("app refused because its workspace was not ready, not by authority: \(detail)")
            }
            if scenario.authority == .mustRefuse, let expected = scenario.headlessRefusal,
               !(headless.first?.detail ?? "").contains(expected)
            {
                violations.append("headless refused for the wrong reason: \(headless.first?.detail ?? "-"), expected \(expected)")
            }
            if let expectation = scenario.search {
                violations += searchViolations(expectation, checks: checks)
            }

            let agree = equivalent(app: appOutcome, headless: headlessOutcome)
            let expectedRelation: String
            switch scenario.relation {
            case .equal:
                expectedRelation = "equal"
                if !agree {
                    violations.append("expected equal outcomes, app \(appOutcome) vs headless \(headlessOutcome)")
                }
            case let .knownDivergence(reason):
                expectedRelation = "known_divergence: \(reason)"
                if agree {
                    violations.append("documented divergence no longer diverges (\(appOutcome)); update the table")
                }
            }

            return ScenarioReport(
                name: scenario.name,
                tool: scenario.tool,
                authority: scenario.authority,
                appAuthority: scenario.effectiveAppAuthority,
                expectedRelation: expectedRelation,
                appOutcome: appOutcome.description,
                headlessOutcome: headlessOutcome.description,
                appDetail: app.first?.detail,
                headlessDetail: headless.first?.detail,
                appStable: appStable,
                headlessStable: headlessStable,
                appSettleMS: appSettleMS,
                appQuiescent: appQuiescent,
                appDiagnostics: appDiagnostics,
                appSampleStates: appSampleStates,
                appSettleTrace: appSettleTrace,
                appLatency: LatencySummary(samples: appSamples),
                headlessLatency: LatencySummary(samples: headlessSamples),
                violations: violations
            )
        }

        /// `SearchExpectation` violations for each backend that must succeed with a search answer.
        static func searchViolations(
            _ expectation: SearchExpectation,
            checks: [(String, Authority, Outcome)]
        ) -> [String] {
            var violations: [String] = []
            for (backend, authority, outcome) in checks where authority == .mustSucceed {
                guard case let .search(hits) = outcome else { continue }
                if let count = expectation.count, hits.count != count {
                    violations.append("\(backend) count was \(hits.count.map(String.init) ?? "absent"), expected \(count)")
                }
                let touched = hits.touchedPaths
                for path in expectation.include where !touched.contains(path) {
                    violations.append("\(backend) search missed \(path)")
                }
                for path in expectation.exclude where touched.contains(path) {
                    violations.append("\(backend) search leaked \(path)")
                }
            }
            return violations
        }

        // MARK: - Backends

        private func observeApp(_ scenario: Scenario) async -> Observation {
            guard let tool = appTools[scenario.tool] else { return Observation(outcome: .refused, detail: "tool missing") }
            let value: Value
            do {
                value = try await tool(scenario.arguments)
            } catch {
                return Observation(outcome: .refused, detail: String(describing: error))
            }
            switch scenario.tool {
            case .readFile:
                guard let reply = value.decode(ToolResultDTOs.ReadFileReply.self) else {
                    return Observation(outcome: .refused, detail: "undecodable read_file reply")
                }
                if let code = reply.errorCode ?? reply.errorMessage {
                    return Observation(outcome: .refused, detail: code)
                }
                return Observation(outcome: .content(Self.normalized(reply.content)), detail: reply.message)
            case .codeStructure:
                guard let reply = value.decode(ToolResultDTOs.CodeStructureReplyDTO.self) else {
                    return Observation(outcome: .refused, detail: "undecodable get_code_structure reply")
                }
                let issues = reply.issues + reply.roots.flatMap(\.issues)
                let issueCodes = issues.map(\.code)
                let signatureIssues = issues.filter { $0.code.hasPrefix("signature_") }.map(Self.signatureIssueLabel)
                let detail = "status=\(reply.status.rawValue)"
                    + (issueCodes.isEmpty ? "" : " issues=\(issueCodes.joined(separator: ","))")
                    + (signatureIssues.isEmpty ? "" : " signature_issues=\(signatureIssues.joined(separator: ","))")
                let seeds = reply.files
                    .filter { $0.role == "seed" && !$0.content.isEmpty }
                    .map { MappedFile(name: URL(fileURLWithPath: $0.path).lastPathComponent, text: $0.content) }
                return Observation(
                    outcome: Self.classifyAppCodeStructure(status: reply.status, seeds: seeds, issueCodes: issueCodes),
                    detail: detail
                )
            case .fileSearch:
                guard let reply = value.decode(ToolResultDTOs.SearchResultDTO.self) else {
                    return Observation(outcome: .refused, detail: "undecodable file_search reply")
                }
                return Self.classifyAppSearch(reply, countOnly: scenario.arguments["count_only"]?.boolValue == true, root: root)
            }
        }

        /// Normalizes an app `file_search` reply. An error field (`error_code` or `error`) is a refusal
        /// whose detail is the code or message. Otherwise path lines and content groups become
        /// root-relative hits; `count_only` reports `total_matches`. The detail records the app's display
        /// spelling (`display=relative|root_name|absolute`) and `limit_hit`, never compared.
        static func classifyAppSearch(_ reply: ToolResultDTOs.SearchResultDTO, countOnly: Bool, root: URL) -> Observation {
            if let code = reply.errorCode ?? reply.errorMessage {
                return Observation(outcome: .refused, detail: code)
            }
            var spellings = Set<String>()
            func relative(_ display: String) -> String {
                let (path, spelling) = appRootRelativePath(display, root: root)
                spellings.insert(spelling)
                return path
            }
            var hits = SearchHits()
            if countOnly {
                hits.count = reply.totalMatches
            } else {
                hits.paths = reply.pathMatchLines.map(relative).sorted()
                hits.content = reply.contentMatchGroups.flatMap { group in
                    group.lines.map { ContentHit(path: relative(group.path), line: $0.lineNumber, text: $0.lineText) }
                }.sorted()
            }
            let display = spellings.isEmpty ? "-" : spellings.sorted().joined(separator: ",")
            return Observation(
                outcome: .search(hits),
                detail: "display=\(display) limit_hit=\(reply.limitHit)" + (reply.warning == nil ? "" : " warning")
            )
        }

        /// An app display path as a root-relative path, with the spelling it used: `absolute` (under the
        /// root's absolute path), `root_name` (prefixed with the root folder name), or `relative`.
        static func appRootRelativePath(_ display: String, root: URL) -> (path: String, spelling: String) {
            let absolutePrefix = root.standardizedFileURL.path + "/"
            if display.hasPrefix(absolutePrefix) {
                return (String(display.dropFirst(absolutePrefix.count)), "absolute")
            }
            let namePrefix = root.lastPathComponent + "/"
            if display.hasPrefix(namePrefix) {
                return (String(display.dropFirst(namePrefix.count)), "root_name")
            }
            return (display, "relative")
        }

        /// Normalizes a headless `file_search` reply: a `matches` entry with a `line` is a content hit,
        /// one without is a path hit; `count_only` reports `count`. Bounds flags go to the detail.
        static func classifyHeadlessSearch(_ value: Value, countOnly: Bool) -> Observation {
            let object = value.objectValue ?? [:]
            var hits = SearchHits()
            if countOnly {
                hits.count = object["count"]?.intValue
            } else {
                for match in object["matches"]?.arrayValue?.compactMap(\.objectValue) ?? [] {
                    guard let path = match["path"]?.stringValue else { continue }
                    if let line = match["line"]?.intValue {
                        hits.content.append(ContentHit(path: path, line: line, text: match["text"]?.stringValue ?? ""))
                    } else {
                        hits.paths.append(path)
                    }
                }
                hits.paths.sort()
                hits.content.sort()
            }
            var bounds: [String] = []
            if object["truncated"]?.boolValue == true { bounds.append("truncated") }
            if let skipped = object["skipped_large_files"]?.intValue { bounds.append("skipped_large_files=\(skipped)") }
            return Observation(outcome: .search(hits), detail: bounds.isEmpty ? nil : bounds.joined(separator: " "))
        }

        private func observeHeadless(_ scenario: Scenario) async -> Observation {
            let request: DomainPhysicalReadRequest
            do {
                request = try DomainPhysicalReadRequest(
                    request: DomainPhysicalToolRequest(
                        argumentsJSON: JSONEncoder().encode(scenario.arguments),
                        securityContext: nil
                    ),
                    context: DomainReadInvocationContext(handle: nil, connectionID: nil),
                    sideEffects: MCPDomainReadSideEffectEmitter(submit: { _, _, _, _, _ in })
                )
            } catch {
                return Observation(outcome: .refused, detail: "request encoding failed")
            }
            let value: Value
            do {
                let result = switch scenario.tool {
                case .readFile: try await headless.readFile(request)
                case .codeStructure: try await headless.inspectCodeStructure(request)
                case .fileSearch: try await headless.searchFiles(request)
                }
                value = try JSONDecoder().decode(Value.self, from: result.json)
            } catch let error as MCPDomainCanonicalReadError {
                return Observation(outcome: .refused, detail: error.code)
            } catch {
                return Observation(outcome: .refused, detail: String(describing: error))
            }
            switch scenario.tool {
            case .fileSearch:
                return Self.classifyHeadlessSearch(value, countOnly: scenario.arguments["count_only"]?.boolValue == true)
            case .readFile:
                return Observation(outcome: .content(Self.normalized(value.stringValue ?? "")), detail: nil)
            case .codeStructure:
                let files = value.objectValue?["files"]?.arrayValue?.compactMap(\.objectValue) ?? []
                let mapped = files.compactMap { file -> MappedFile? in
                    guard file["diagnostic"] == nil,
                          let path = file["path"]?.stringValue,
                          let signatures = file["signatures"]?.stringValue,
                          !signatures.isEmpty
                    else { return nil }
                    return MappedFile(name: URL(fileURLWithPath: path).lastPathComponent, text: signatures)
                }
                let diagnostics = files.compactMap { file -> String? in
                    guard let code = file["diagnostic"]?.stringValue else { return nil }
                    return [code, file["reason"]?.stringValue].compactMap(\.self).joined(separator: ":")
                }
                // Headless answers a refused explicit file with a per-file diagnostic, not a throw.
                let outcome: Outcome = mapped.isEmpty && !diagnostics.isEmpty
                    ? .refused
                    : .mapped(mapped.sorted { $0.name < $1.name })
                return Observation(outcome: outcome, detail: diagnostics.joined(separator: ",").nilIfEmpty)
            }
        }

        /// Which app path produced a `signature_*` issue: `code@phase:variant`, plus `:path` when the
        /// issue names a file and `:retryable`. The variant comes from the issue's fixed message (the
        /// same code is emitted by several paths); the message and path themselves are never recorded.
        static func signatureIssueLabel(_ issue: ToolResultDTOs.CodeStructureReplyDTO.IssueDTO) -> String {
            let variant = switch issue.message {
            case "Signature coordination is temporarily unavailable.": "coordination"
            case "Signature rendering was cancelled.": "cancelled"
            case "A current signature candidate is unavailable.": "candidate"
            case "Signature generation is still pending.": "pending"
            case "A signature artifact is unavailable; graph data remains usable.": "artifact"
            case "Signature selection is unavailable.": "selection"
            case "One or more signatures could not be rendered; graph data remains usable.": "renderFallback"
            default: "other"
            }
            return "\(issue.code)@\(issue.phase):\(variant)"
                + (issue.path == nil ? "" : ":path")
                + (issue.retryable ? ":retryable" : "")
        }

        private static func normalized(_ content: String) -> String {
            content.hasSuffix("\n") ? String(content.dropLast()) : content
        }

        private static func timed<T>(_ body: () async -> T) async -> (T, Double) {
            let clock = ContinuousClock()
            let start = clock.now
            let value = await body()
            return (value, milliseconds(clock.now - start))
        }

        private static func milliseconds(_ duration: Duration) -> Double {
            let components = duration.components
            return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
        }
    }

    private extension String {
        var nilIfEmpty: String? {
            isEmpty ? nil : self
        }
    }
#endif
