import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
@testable import RepoPromptMCP
import XCTest

#if DEBUG
    /// M8S: in-process app-versus-headless parity and latency harness for the MCP read boundary.
    ///
    /// Both backends run against the same fixture root, ignore defaults, and `skip_symlinks` policy:
    /// the app through its real window tools on an in-process `MCPServerViewModel`
    /// (`InProcessMCPWindowServerFixture`), headless through `MCPDomainCanonicalWorkspaceService` with
    /// the production `DirectHeadlessDomainContext.resolvePath`. Each scenario's outcomes are normalized
    /// (a thrown error and an error DTO are both `refused`; content is compared after one trailing
    /// newline is removed) and checked against a checked-in expectation: an authority class
    /// (`mustSucceed` / `mustRefuse`, for both backends) and a relation (`equal`, or a documented
    /// `knownDivergence` that must still diverge, so the table cannot silently go stale). Outcomes must
    /// be stable across iterations. Latency is sampled per backend with interleaved iterations after a
    /// warm-up and reported (p50 / max), never asserted against a threshold.
    ///
    /// Not proven: transport, JSON-RPC envelope (`isError` vs protocol error), lanes, leases, and the
    /// watchdog (both sides are driven at the tool layer); the app's socket/connection-manager path;
    /// `file_search` (not wired in the fixture); multi-root namespaces; cold-start or large-tree
    /// performance; and absolute latency comparability across machines.
    @MainActor
    final class MCPBackendParityHarness {
        enum Authority: String, Encodable {
            case mustSucceed = "must_succeed"
            case mustRefuse = "must_refuse"
        }

        enum Relation: Equatable {
            case equal
            case knownDivergence(String)
        }

        enum Tool: String, Encodable {
            case readFile = "read_file"
            case codeStructure = "get_code_structure"
        }

        struct Scenario {
            let name: String
            let tool: Tool
            let arguments: [String: Value]
            let authority: Authority
            let relation: Relation
            /// For `mustRefuse`: a substring the headless refusal detail must contain, so a refusal
            /// for the wrong reason (for example a broken harness path) cannot pass vacuously.
            var headlessRefusal: String?
        }

        enum Outcome: Equatable, CustomStringConvertible {
            /// `read_file` content.
            case content(String)
            /// `get_code_structure`: names of files that received a code map.
            case mapped([String])
            case refused
            /// The app's code-structure index had not settled (`pending` / `unavailable`).
            case unsettled

            var isSuccess: Bool {
                switch self {
                case .content: true
                case let .mapped(names): !names.isEmpty
                case .refused, .unsettled: false
                }
            }

            var description: String {
                switch self {
                case let .content(text): "content(\(text.count) chars)"
                case let .mapped(names): "mapped(\(names.joined(separator: ",")))"
                case .refused: "refused"
                case .unsettled: "unsettled"
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
            let expectedRelation: String
            let appOutcome: String
            let headlessOutcome: String
            let appDetail: String?
            let headlessDetail: String?
            let appStable: Bool
            let headlessStable: Bool
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
            "file_search (not wired in the in-process fixture)",
            "multi-root namespaces, cold start, and large-tree performance",
            "absolute latency comparability across machines or runs"
        ]

        let root: URL
        /// Retained for the harness's lifetime (window tools hold their runtime weakly); release with
        /// `close()`.
        private let appWindow: InProcessMCPWindowServerFixture.RegisteredWindow
        private let appTools: [Tool: RepoPromptApp.Tool]
        private let headless: MCPDomainCanonicalWorkspaceService

        private init(
            root: URL,
            appWindow: InProcessMCPWindowServerFixture.RegisteredWindow,
            appTools: [Tool: RepoPromptApp.Tool],
            headless: MCPDomainCanonicalWorkspaceService
        ) {
            self.root = root
            self.appWindow = appWindow
            self.appTools = appTools
            self.headless = headless
        }

        /// Closes and unregisters the app window.
        func close() async {
            await InProcessMCPWindowServerFixture.close(appWindow)
        }

        /// Activates `root` as the app workspace (after the caller has pinned the app's global ignore
        /// defaults to `globalPatterns`; the app crawl uses its default `skip_symlinks`, which headless
        /// mirrors) and builds both backends over it.
        static func make(root: URL, globalPatterns: String) async throws -> MCPBackendParityHarness {
            let window = try await InProcessMCPWindowServerFixture.makeRegisteredWindow(root: root)
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
            } catch {
                await InProcessMCPWindowServerFixture.close(window)
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
            return MCPBackendParityHarness(root: root, appWindow: window, appTools: appTools, headless: headless)
        }

        /// Runs every scenario: one warm-up, then `iterations` interleaved app/headless samples.
        func run(_ scenarios: [Scenario], iterations: Int) async -> Report {
            EditFlowPerf.resetDebugCaptureForTesting()
            let captureStarted = switch EditFlowPerf.beginDebugCapture(label: "mcp-backend-parity", maxSamples: 4000) {
            case .started: true
            case .busy: false
            }
            var reports: [ScenarioReport] = []
            for scenario in scenarios {
                await settleAppIndex(for: scenario)
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
                    let (headless, headlessMS) = await Self.timed { await self.observeHeadless(scenario) }
                    headlessObservations.append(headless)
                    headlessSamples.append(headlessMS)
                }
                reports.append(Self.evaluate(
                    scenario,
                    app: appObservations,
                    headless: headlessObservations,
                    appSamples: appSamples,
                    headlessSamples: headlessSamples
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

        /// Bounded wait (outside the timed samples) for the app's code-structure index to leave
        /// `pending` / `unavailable` after activation. A still-unsettled index is reported, not failed.
        private func settleAppIndex(for scenario: Scenario) async {
            guard scenario.tool == .codeStructure else { return }
            for _ in 0 ..< Self.appIndexSettleAttempts {
                guard await observeApp(scenario).outcome == .unsettled else { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        private static let appIndexSettleAttempts = 100

        /// App error codes that mean the workspace or its freshness was not ready: infrastructure, not an
        /// authority decision, so they can never satisfy a `mustRefuse` scenario.
        static let appInfrastructureRefusalCodes = [
            "workspace_authority_", "workspace_freshness_timeout", "worktree_scope_unavailable"
        ]

        // MARK: - Evaluation

        static func evaluate(
            _ scenario: Scenario,
            app: [Observation],
            headless: [Observation],
            appSamples: [Double],
            headlessSamples: [Double]
        ) -> ScenarioReport {
            var violations: [String] = []
            let appOutcome = app.first?.outcome ?? .refused
            let headlessOutcome = headless.first?.outcome ?? .refused
            let appStable = app.allSatisfy { $0.outcome == appOutcome }
            let headlessStable = headless.allSatisfy { $0.outcome == headlessOutcome }
            if !appStable { violations.append("app outcome changed across iterations") }
            if !headlessStable { violations.append("headless outcome changed across iterations") }

            for (backend, outcome) in [("app", appOutcome), ("headless", headlessOutcome)] {
                switch scenario.authority {
                case .mustSucceed:
                    // An unsettled app code-structure index cannot be judged; it is reported, not failed.
                    if !outcome.isSuccess, outcome != .unsettled {
                        violations.append("\(backend) must succeed but was \(outcome)")
                    }
                case .mustRefuse:
                    if outcome.isSuccess { violations.append("\(backend) must refuse but was \(outcome)") }
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

            let comparable = appOutcome != .unsettled && headlessOutcome != .unsettled
            let expectedRelation: String
            switch scenario.relation {
            case .equal:
                expectedRelation = "equal"
                if comparable, appOutcome != headlessOutcome {
                    violations.append("expected equal outcomes, app \(appOutcome) vs headless \(headlessOutcome)")
                }
            case let .knownDivergence(reason):
                expectedRelation = "known_divergence: \(reason)"
                if comparable, appOutcome == headlessOutcome {
                    violations.append("documented divergence no longer diverges (\(appOutcome)); update the table")
                }
            }

            return ScenarioReport(
                name: scenario.name,
                tool: scenario.tool,
                authority: scenario.authority,
                expectedRelation: expectedRelation,
                appOutcome: appOutcome.description,
                headlessOutcome: headlessOutcome.description,
                appDetail: app.first?.detail,
                headlessDetail: headless.first?.detail,
                appStable: appStable,
                headlessStable: headlessStable,
                appLatency: LatencySummary(samples: appSamples),
                headlessLatency: LatencySummary(samples: headlessSamples),
                violations: violations
            )
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
                if reply.status == .pending || reply.status == .unavailable {
                    return Observation(outcome: .unsettled, detail: reply.status.rawValue)
                }
                let names = reply.files.filter { !$0.content.isEmpty }.map { URL(fileURLWithPath: $0.path).lastPathComponent }
                return Observation(
                    outcome: names.isEmpty ? .refused : .mapped(names.sorted()),
                    detail: reply.issues.map(\.code).joined(separator: ",").nilIfEmpty
                )
            }
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
                }
                value = try JSONDecoder().decode(Value.self, from: result.json)
            } catch let error as MCPDomainCanonicalReadError {
                return Observation(outcome: .refused, detail: error.code)
            } catch {
                return Observation(outcome: .refused, detail: String(describing: error))
            }
            switch scenario.tool {
            case .readFile:
                return Observation(outcome: .content(Self.normalized(value.stringValue ?? "")), detail: nil)
            case .codeStructure:
                let files = value.objectValue?["files"]?.arrayValue?.compactMap(\.objectValue) ?? []
                let mapped = files.filter { file in
                    file["diagnostic"] == nil && file["signatures"]?.stringValue?.isEmpty == false
                }
                let names = mapped.compactMap { $0["path"]?.stringValue }.map { URL(fileURLWithPath: $0).lastPathComponent }
                let diagnostics = files.compactMap { file -> String? in
                    guard let code = file["diagnostic"]?.stringValue else { return nil }
                    return [code, file["reason"]?.stringValue].compactMap(\.self).joined(separator: ":")
                }
                return Observation(
                    outcome: names.isEmpty ? .refused : .mapped(names.sorted()),
                    detail: diagnostics.joined(separator: ",").nilIfEmpty
                )
            }
        }

        private static func normalized(_ content: String) -> String {
            content.hasSuffix("\n") ? String(content.dropLast()) : content
        }

        private static func timed<T>(_ body: () async -> T) async -> (T, Double) {
            let clock = ContinuousClock()
            let start = clock.now
            let value = await body()
            let elapsed = clock.now - start
            let components = elapsed.components
            return (value, Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15)
        }
    }

    private extension String {
        var nilIfEmpty: String? {
            isEmpty ? nil : self
        }
    }
#endif
