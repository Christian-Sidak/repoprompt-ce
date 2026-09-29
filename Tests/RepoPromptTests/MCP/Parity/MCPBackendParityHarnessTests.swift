import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    /// M8S/M8T gate: app-versus-headless parity for the MCP read boundary (`read_file`,
    /// `get_code_structure`), with latency recorded but never threshold-asserted. The primary fixture
    /// is a committed Git repository, so the app's code-map graph is eligible and code-structure parity
    /// is judged on content; a non-Git root, mapped by the app through its non-Git Code Maps opt-in
    /// (#994), must hold the same parity. See `MCPBackendParityHarness` for what the gate does not prove.
    @MainActor
    final class MCPBackendParityHarnessTests: XCTestCase {
        private typealias Harness = MCPBackendParityHarness
        private static let iterations = 5
        private static let globalPatterns = "**/node_modules/\n"

        func testReadBoundaryParityAndLatencyGate() async throws {
            let fixture = try makeGitFixture()
            try await pinGlobalIgnoreDefaults()
            let harness = try await Harness.make(root: fixture.root, globalPatterns: Self.globalPatterns)
            addTeardownBlock { @MainActor in await harness.close() }
            let scenarios = Self.scenarios(root: fixture.root, external: fixture.external)

            let report = await harness.run(scenarios, iterations: Self.iterations)

            try assertGate(report, scenarios: scenarios, attachmentName: "mcp-backend-parity-report.json")
        }

        /// M12: `file_search` parity over the same Git fixture: content, regex, case folding, whole
        /// words, path globs, filters, ignore/link/outside-root exclusion, limits, `count_only`, `auto`
        /// mode, and invalid input.
        func testFileSearchParityAndLatencyGate() async throws {
            let fixture = try makeGitFixture()
            try await pinGlobalIgnoreDefaults()
            let harness = try await Harness.make(root: fixture.root, globalPatterns: Self.globalPatterns)
            addTeardownBlock { @MainActor in await harness.close() }
            let scenarios = Self.searchScenarios()

            let report = await harness.run(scenarios, iterations: Self.iterations)

            try assertGate(report, scenarios: scenarios, attachmentName: "mcp-backend-parity-file-search-report.json")
        }

        /// Before non-Git Code Maps (#994) this was the one documented code-structure divergence: the app
        /// answered terminal `git_root_unavailable` while headless maps files in any root. With the
        /// opt-in on, the app maps the root from filesystem source authority and must match headless.
        func testNonGitRootCodeStructureParityWithNonGitCodeMaps() async throws {
            let root = try makeNonGitFixture()
            try await pinGlobalIgnoreDefaults()
            let harness = try await Harness.make(
                root: root,
                globalPatterns: Self.globalPatterns,
                nonGitCodeMapsEnabled: true
            )
            addTeardownBlock { @MainActor in await harness.close() }
            let scenarios = [
                Harness.Scenario(
                    name: "code structure of a non-Git root",
                    tool: .codeStructure,
                    arguments: ["paths": .array([.string("src/a.swift")])],
                    authority: .mustSucceed,
                    relation: .equal
                ),
                // Reads do not depend on Git: parity must hold here too.
                Harness.Scenario(
                    name: "read in a non-Git root",
                    tool: .readFile,
                    arguments: ["path": "src/a.swift"],
                    authority: .mustSucceed,
                    relation: .equal
                )
            ]

            let report = await harness.run(scenarios, iterations: Self.iterations)

            try assertGate(report, scenarios: scenarios, attachmentName: "mcp-backend-parity-non-git-report.json")
        }

        /// M9: the real app `get_code_structure` path assembles and encodes its reply on the
        /// projection worker, never on the main thread, in that order.
        func testAppCodeStructureAssemblesAndEncodesOnProjectionWorker() async throws {
            let root = try makeNonGitFixture()
            try await pinGlobalIgnoreDefaults()
            let harness = try await Harness.make(root: root, globalPatterns: Self.globalPatterns)
            addTeardownBlock { @MainActor in await harness.close() }
            let recorder = ProjectionExecutionRecorder()
            MCPProviderProjectionWorker.executionObserverForTesting = recorder.observer
            defer { MCPProviderProjectionWorker.executionObserverForTesting = nil }

            let value = try await harness.callApp(
                .codeStructure,
                arguments: ["paths": .array([.string("src/a.swift")]), "signatures": .bool(false)]
            )

            XCTAssertNotNil(value.decode(ToolResultDTOs.CodeStructureReplyDTO.self))
            let events = recorder.events.filter { $0.toolName == MCPWindowToolName.getCodeStructure }
            XCTAssertEqual(events.map(\.phase), ["reply_assembly", "value_encoding"])
            XCTAssertFalse(events.contains(where: \.ranOnMainThread), "\(events)")
        }

        // MARK: - Gate logic (deterministic, no backends)

        func testEqualRelationFlagsDifferingOutcomes() {
            let report = evaluate(authority: .mustSucceed, relation: .equal, app: [.content("a")], headless: [.content("b")])
            XCTAssertEqual(report.violations.count, 1)
        }

        func testKnownDivergenceMustStillDiverge() {
            let report = evaluate(
                authority: .mustSucceed,
                relation: .knownDivergence("documented"),
                app: [.content("a")],
                headless: [.content("a")]
            )
            XCTAssertEqual(report.violations, ["documented divergence no longer diverges (content(1 chars)); update the table"])
        }

        func testAuthorityClassIsEnforcedForBothBackends() {
            let leaked = evaluate(authority: .mustRefuse, relation: .equal, app: [.refused], headless: [.content("x")])
            XCTAssertEqual(leaked.violations.first, "headless must refuse but was content(1 chars)")
            let failed = evaluate(authority: .mustSucceed, relation: .equal, app: [.refused], headless: [.refused])
            XCTAssertEqual(failed.violations.count, 2)
        }

        func testUnsettledAppIndexFailsAMustSucceedScenario() {
            let report = evaluate(
                authority: .mustSucceed,
                relation: .equal,
                app: [.unsettled],
                headless: [.mapped([Self.file("a.swift", "struct A")])]
            )
            XCTAssertTrue(report.violations.contains("app must succeed but was unsettled"), "\(report.violations)")
        }

        func testTerminalUnavailableFailsAMustSucceedScenario() {
            let report = evaluate(
                authority: .mustSucceed,
                relation: .equal,
                app: [.unavailable(["git_root_unavailable"])],
                headless: [.mapped([Self.file("a.swift", "struct A")])]
            )
            XCTAssertTrue(
                report.violations.contains("app must succeed but was unavailable(git_root_unavailable)"),
                "\(report.violations)"
            )
        }

        func testUnsettledOrUnavailableIsNeverARefusal() {
            for appOutcome in [Harness.Outcome.unsettled, .unavailable(["git_root_unavailable"]), .mapped([])] {
                let report = evaluate(authority: .mustRefuse, relation: .equal, app: [appOutcome], headless: [.refused])
                XCTAssertTrue(
                    report.violations.contains("app must refuse but was \(appOutcome)"),
                    "\(appOutcome): \(report.violations)"
                )
            }
        }

        func testUnsettledAppIndexCannotMaskDisclosure() {
            let report = evaluate(
                authority: .mustRefuse,
                relation: .equal,
                app: [.unsettled],
                headless: [.mapped([Self.file("secret.swift", "let secret")])]
            )
            XCTAssertTrue(report.violations.contains("headless must refuse but was mapped(secret.swift)"), "\(report.violations)")
        }

        func testCodeStructureEquivalenceComparesSignaturesNotPresence() {
            let signatures = "struct A {\n  func run()\n}\n"
            let appText = "File: src/a.swift\n" + signatures
            XCTAssertTrue(Harness.equivalent(
                app: .mapped([Self.file("a.swift", appText)]),
                headless: .mapped([Self.file("a.swift", signatures)])
            ))
            XCTAssertFalse(
                Harness.equivalent(
                    app: .mapped([Self.file("a.swift", "File: src/a.swift\nstruct A {\n}\n")]),
                    headless: .mapped([Self.file("a.swift", signatures)])
                ),
                "different API text for the same file name is a mismatch"
            )
            XCTAssertFalse(
                Harness.equivalent(app: .mapped([Self.file("a.swift", appText)]), headless: .mapped([Self.file("a.swift", "")])),
                "empty headless signatures can never be equivalent"
            )
            XCTAssertFalse(
                Harness.equivalent(
                    app: .mapped([Self.file("a.swift", appText)]),
                    headless: .mapped([Self.file("a.swift", signatures), Self.file("b.swift", "struct B")])
                ),
                "a different seed set is a mismatch"
            )
        }

        func testAppCodeStructureClassificationSeparatesRefusalsFromInfrastructure() {
            let seed = Self.file("a.swift", "File: a.swift\nstruct A")
            XCTAssertEqual(Harness.classifyAppCodeStructure(status: .ok, seeds: [seed], issueCodes: []), .mapped([seed]))
            XCTAssertEqual(
                Harness.classifyAppCodeStructure(status: .unavailable, seeds: [], issueCodes: ["path_not_found"]),
                .refused,
                "an unresolvable requested path is the app's code-structure refusal"
            )
            XCTAssertEqual(
                Harness.classifyAppCodeStructure(
                    status: .unavailable,
                    seeds: [],
                    issueCodes: ["path_not_found", "git_root_unavailable"]
                ),
                .unavailable(["git_root_unavailable", "path_not_found"]),
                "an infrastructure code alongside a path refusal is not a clean refusal"
            )
            XCTAssertEqual(
                Harness.classifyAppCodeStructure(status: .pending, seeds: [], issueCodes: ["graph_indexing"]),
                .unsettled
            )
            XCTAssertEqual(
                Harness.classifyAppCodeStructure(status: .unavailable, seeds: [], issueCodes: ["git_root_unavailable"]),
                .unavailable(["git_root_unavailable"])
            )
            XCTAssertEqual(Harness.classifyAppCodeStructure(status: .unavailable, seeds: [], issueCodes: []), .unavailable([]))
            XCTAssertEqual(Harness.classifyAppCodeStructure(status: .ok, seeds: [], issueCodes: []), .mapped([]))
        }

        func testNonQuiescentAppIndexIsAViolationEvenWhenOutcomesAgree() {
            let seed = Self.file("a.swift", "struct A")
            let report = Harness.evaluate(
                Harness.Scenario(name: "unit", tool: .codeStructure, arguments: [:], authority: .mustSucceed, relation: .equal),
                app: [Harness.Observation(outcome: .mapped([seed]), detail: nil)],
                headless: [Harness.Observation(outcome: .mapped([seed]), detail: nil)],
                appSamples: [1],
                headlessSamples: [1],
                appSettleMS: 45000,
                appQuiescent: false
            )
            XCTAssertEqual(report.violations, ["app code-map index did not reach quiescence within the settle bound"])
        }

        func testMustBeUnavailableRequiresTheExpectedCode() {
            func report(_ app: Harness.Outcome) -> Harness.ScenarioReport {
                Harness.evaluate(
                    Harness.Scenario(
                        name: "unit",
                        tool: .codeStructure,
                        arguments: [:],
                        authority: .mustSucceed,
                        relation: .knownDivergence("documented"),
                        appAuthority: .mustBeUnavailable,
                        unavailableCode: "git_root_unavailable"
                    ),
                    app: [Harness.Observation(outcome: app, detail: nil)],
                    headless: [Harness.Observation(outcome: .mapped([Self.file("a.swift", "struct A")]), detail: nil)],
                    appSamples: [1],
                    headlessSamples: [1]
                )
            }
            XCTAssertEqual(report(.unavailable(["git_root_unavailable"])).violations, [])
            XCTAssertEqual(report(.unavailable(["graph_indexing"])).violations.count, 1)
            XCTAssertEqual(report(.unsettled).violations.count, 1)
            XCTAssertEqual(report(.refused).violations.count, 1)
        }

        func testRefusalForTheWrongReasonIsFlagged() {
            let report = Harness.evaluate(
                Harness.Scenario(
                    name: "unit",
                    tool: .readFile,
                    arguments: [:],
                    authority: .mustRefuse,
                    relation: .equal,
                    headlessRefusal: "symbolic_link_path"
                ),
                app: [Harness.Observation(outcome: .refused, detail: nil)],
                headless: [Harness.Observation(outcome: .refused, detail: "pathOutsideWorkspace")],
                appSamples: [1],
                headlessSamples: [1]
            )
            XCTAssertEqual(report.violations.count, 1)
        }

        func testAppInternalErrorIsNotAnAuthorityRefusal() {
            let report = Harness.evaluate(
                Harness.Scenario(name: "unit", tool: .readFile, arguments: [:], authority: .mustRefuse, relation: .equal),
                app: [Harness.Observation(outcome: .refused, detail: "[-32603] Internal error: runtime deallocated")],
                headless: [Harness.Observation(outcome: .refused, detail: "symbolic_link_path")],
                appSamples: [1],
                headlessSamples: [1]
            )
            XCTAssertEqual(report.violations.count, 1)
        }

        func testAppWorkspaceNotReadyIsNotAnAuthorityRefusal() {
            let report = Harness.evaluate(
                Harness.Scenario(name: "unit", tool: .readFile, arguments: [:], authority: .mustRefuse, relation: .equal),
                app: [Harness.Observation(outcome: .refused, detail: "workspace_authority_unavailable")],
                headless: [Harness.Observation(outcome: .refused, detail: "symbolic_link_path")],
                appSamples: [1],
                headlessSamples: [1]
            )
            XCTAssertEqual(report.violations.count, 1)
        }

        func testOutcomeChangingAcrossIterationsIsFlagged() {
            let report = evaluate(
                authority: .mustSucceed,
                relation: .equal,
                app: [.content("a"), .content("b")],
                headless: [.content("a"), .content("a")]
            )
            XCTAssertTrue(report.violations.contains("app outcome changed across iterations"))
        }

        func testSampleStateDigestDistinguishesContentWithoutExposingIt() {
            func state(_ text: String) -> String {
                Harness.sampleState(
                    Harness.Observation(outcome: .mapped([Self.file("a.swift", text)]), detail: "status=ok"),
                    rootAvailability: "ready"
                )
            }
            let first = state("struct A {}\n")
            XCTAssertEqual(first, state("struct A {}\n"), "identical content yields an identical state")
            XCTAssertNotEqual(first, state("struct A { let x = 1 }\n"), "a content change is attributable")
            XCTAssertFalse(first.contains("struct A"), "the state never carries mapped text: \(first)")
            XCTAssertTrue(first.hasPrefix("mapped(a.swift)|status=ok|digest="), first)
            XCTAssertTrue(first.hasSuffix("|roots=ready"), first)
            let unsettled = Harness.sampleState(
                Harness.Observation(outcome: .unsettled, detail: "status=pending issues=graph_indexing"),
                rootAvailability: "indexing"
            )
            XCTAssertEqual(unsettled, "unsettled|status=pending issues=graph_indexing|digest=-|roots=indexing")
        }

        func testIterationInstabilityCarriesEachSampleState() {
            let states = ["mapped(a.swift)|status=partial|digest=aaa|roots=ready", "mapped(a.swift,b.swift)|status=ok|digest=bbb|roots=ready"]
            let report = Harness.evaluate(
                Harness.Scenario(name: "unit", tool: .codeStructure, arguments: [:], authority: .mustSucceed, relation: .equal),
                app: [
                    Harness.Observation(outcome: .mapped([Self.file("a.swift", "A")]), detail: "status=partial"),
                    Harness.Observation(outcome: .mapped([Self.file("a.swift", "A"), Self.file("b.swift", "B")]), detail: "status=ok")
                ],
                headless: [Harness.Observation(outcome: .mapped([Self.file("a.swift", "A")]), detail: nil)],
                appSamples: [1, 1],
                headlessSamples: [1],
                appSampleStates: states
            )
            XCTAssertTrue(report.violations.contains("app outcome changed across iterations"))
            XCTAssertEqual(report.appSampleStates, states)
        }

        func testStoreEventsAreLabelledPerRootWithRelativeTimes() {
            let first = WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID())
            let second = WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID())
            func event(
                _ rootEpoch: WorkspaceCodemapRootEpoch,
                _ kind: WorkspaceFileContextStore.CodemapGraphIndexBuildStoreEventKind,
                _ phase: WorkspaceCodemapGraphIndexLaunchPhase,
                atMS milliseconds: UInt64,
                reason: String? = nil
            ) -> WorkspaceFileContextStore.CodemapGraphIndexBuildStoreEvent {
                WorkspaceFileContextStore.CodemapGraphIndexBuildStoreEvent(
                    ordinal: milliseconds,
                    rootEpoch: rootEpoch,
                    kind: kind,
                    launchPhase: phase,
                    uptimeNanoseconds: 5_000_000_000 + milliseconds * 1_000_000,
                    transientReason: reason
                )
            }
            var cancelled = event(first, .cancelled, .cancelled, atMS: 55)
            cancelled.origin = "catalogAdvance.file_system_publication"
            let described = Harness.describeStoreEvents([
                event(first, .scheduled, .eligibilityQueued, atMS: 0),
                event(second, .eligibilityTerminal, .terminalUnavailable, atMS: 12),
                event(first, .retryScheduled, .transientRetry, atMS: 40, reason: "setup.registrationFailed"),
                cancelled
            ])
            XCTAssertEqual(
                described,
                "r0+0ms:scheduled:eligibilityQueued>r1+12ms:eligibilityTerminal:terminalUnavailable"
                    + ">r0+40ms:retryScheduled:transientRetry:setup.registrationFailed"
                    + ">r0+55ms:cancelled:cancelled:origin=catalogAdvance.file_system_publication"
            )
            XCTAssertFalse(described.contains(first.rootID.uuidString), "root identifiers never appear")
        }

        func testDemandEventsAreLabelledPerFileWithRelativeTimes() {
            let rootEpoch = WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID())
            let fileA = UUID()
            let fileB = UUID()
            func event(_ fileID: UUID, _ label: String, atMS milliseconds: UInt64) -> WorkspaceFileContextStore.CodemapDemandEvent {
                WorkspaceFileContextStore.CodemapDemandEvent(
                    ordinal: milliseconds,
                    rootEpoch: rootEpoch,
                    fileID: fileID,
                    label: label,
                    uptimeNanoseconds: 9_000_000_000 + milliseconds * 1_000_000
                )
            }
            let described = Harness.describeDemandEvents([
                event(fileA, "request.created.pending", atMS: 0),
                event(fileB, "request.joined.ready", atMS: 3),
                event(fileB, "release.cancelled.from.ready", atMS: 9)
            ])
            XCTAssertEqual(
                described,
                "f0+0ms:request.created.pending>f1+3ms:request.joined.ready>f1+9ms:release.cancelled.from.ready"
            )
            XCTAssertFalse(described.contains(fileA.uuidString), "file identifiers never appear")
        }

        func testSignatureIssueLabelNamesThePathWithoutRecordingIt() {
            typealias Issue = ToolResultDTOs.CodeStructureReplyDTO.IssueDTO
            let fallback = Issue(
                code: "signature_unavailable", phase: "render", path: nil, retryable: false,
                retryAfterMilliseconds: nil, attempted: nil, limit: nil,
                message: "One or more signatures could not be rendered; graph data remains usable."
            )
            XCTAssertEqual(Harness.signatureIssueLabel(fallback), "signature_unavailable@render:renderFallback")
            let artifact = Issue(
                code: "signature_unavailable", phase: "render_demand", path: "root/src/b.swift", retryable: true,
                retryAfterMilliseconds: 100, attempted: nil, limit: nil,
                message: "A signature artifact is unavailable; graph data remains usable."
            )
            let label = Harness.signatureIssueLabel(artifact)
            XCTAssertEqual(label, "signature_unavailable@render_demand:artifact:path:retryable")
            XCTAssertFalse(label.contains("b.swift"), "the issue path is never recorded")
        }

        func testSearchExpectationChecksOnlySucceedingBackends() {
            let hits = Harness.SearchHits(
                paths: ["src/a.swift"],
                content: [Harness.ContentHit(path: "src/debug.log", line: 1, text: "log")]
            )
            let violations = Harness.searchViolations(
                Harness.SearchExpectation(include: ["src/a.swift", "docs/guide.md"], exclude: ["src/debug.log"]),
                checks: [("app", .mustSucceed, .search(hits)), ("headless", .mustRefuse, .search(hits))]
            )
            XCTAssertEqual(violations, ["app search missed docs/guide.md", "app search leaked src/debug.log"])
            XCTAssertEqual(
                Harness.searchViolations(
                    Harness.SearchExpectation(count: 3),
                    checks: [("headless", .mustSucceed, .search(Harness.SearchHits(count: 1)))]
                ),
                ["headless count was 1, expected 3"]
            )
        }

        func testEmptyAgreeingSearchCannotSatisfyAnInclusion() {
            let report = Harness.evaluate(
                Harness.Scenario(
                    name: "unit",
                    tool: .fileSearch,
                    arguments: [:],
                    authority: .mustSucceed,
                    relation: .equal,
                    search: Harness.SearchExpectation(include: ["src/a.swift"])
                ),
                app: [Harness.Observation(outcome: .search(Harness.SearchHits()), detail: nil)],
                headless: [Harness.Observation(outcome: .search(Harness.SearchHits()), detail: nil)],
                appSamples: [1],
                headlessSamples: [1]
            )
            XCTAssertEqual(report.violations, ["app search missed src/a.swift", "headless search missed src/a.swift"])
        }

        func testAppSearchClassificationNormalizesDisplayPathsAndErrors() {
            let root = URL(fileURLWithPath: "/tmp/parity/root", isDirectory: true)
            typealias DTO = ToolResultDTOs.SearchResultDTO
            let reply = DTO(
                totalMatches: 2, totalFiles: 1, contentMatches: 1, pathMatches: 1, limitHit: false, perFileCounts: [],
                pathMatchLines: ["root/src/b.swift"],
                contentMatchGroups: [DTO.ContentMatchGroup(
                    path: "/tmp/parity/root/src/a.swift",
                    lines: [DTO.ContentMatchGroup.Line(lineNumber: 2, lineText: "x", contextBefore: nil, contextAfter: nil)]
                )]
            )
            let observation = Harness.classifyAppSearch(reply, countOnly: false, root: root)
            XCTAssertEqual(observation.outcome, .search(Harness.SearchHits(
                paths: ["src/b.swift"],
                content: [Harness.ContentHit(path: "src/a.swift", line: 2, text: "x")]
            )))
            XCTAssertEqual(observation.detail, "display=absolute,root_name limit_hit=false", "spellings are reported")
            XCTAssertEqual(Harness.classifyAppSearch(reply, countOnly: true, root: root).outcome, .search(Harness.SearchHits(count: 2)))
            let failure = DTO(
                totalMatches: 0, totalFiles: 0, contentMatches: 0, pathMatches: 0, limitHit: false, perFileCounts: [],
                pathMatchLines: [], contentMatchGroups: [], errorCode: "workspace_readiness_timeout"
            )
            let refused = Harness.classifyAppSearch(failure, countOnly: false, root: root)
            XCTAssertEqual(refused.outcome, .refused)
            XCTAssertEqual(refused.detail, "workspace_readiness_timeout")
        }

        func testHeadlessSearchClassificationSeparatesPathAndContentHits() {
            let value: Value = [
                "matches": [
                    ["path": "src/b.swift"],
                    ["path": "src/a.swift", "line": 3, "text": "hit"]
                ],
                "count": 2,
                "truncated": true
            ]
            let observation = Harness.classifyHeadlessSearch(value, countOnly: false)
            XCTAssertEqual(observation.outcome, .search(Harness.SearchHits(
                paths: ["src/b.swift"],
                content: [Harness.ContentHit(path: "src/a.swift", line: 3, text: "hit")]
            )))
            XCTAssertEqual(observation.detail, "truncated")
            XCTAssertEqual(
                Harness.classifyHeadlessSearch(["count": 7], countOnly: true).outcome,
                .search(Harness.SearchHits(count: 7))
            )
        }

        func testLatencySummaryUsesLowerMedianAndMax() {
            let summary = Harness.LatencySummary(samples: [4, 1, 3, 2])
            XCTAssertEqual(summary.p50MS, 2)
            XCTAssertEqual(summary.maxMS, 4)
        }

        // MARK: - Scenario table

        /// The checked-in expectation table for the Git fixture. Update a relation only with a
        /// documented reason.
        private static func scenarios(root: URL, external: URL) -> [Harness.Scenario] {
            func read(
                _ name: String,
                _ arguments: [String: Value],
                _ authority: Harness.Authority,
                headlessRefusal: String? = nil
            ) -> Harness.Scenario {
                Harness.Scenario(
                    name: name,
                    tool: .readFile,
                    arguments: arguments,
                    authority: authority,
                    relation: .equal,
                    headlessRefusal: headlessRefusal
                )
            }
            func structure(
                _ name: String,
                _ paths: [String],
                _ authority: Harness.Authority,
                headlessRefusal: String? = nil
            ) -> Harness.Scenario {
                Harness.Scenario(
                    name: name,
                    tool: .codeStructure,
                    arguments: ["paths": .array(paths.map(Value.string))],
                    authority: authority,
                    relation: .equal,
                    headlessRefusal: headlessRefusal
                )
            }
            let inRoot = root.appendingPathComponent("src/a.swift").path
            let outside = external.appendingPathComponent("secret.swift").path
            return [
                read("relative in-root file", ["path": "src/a.swift"], .mustSucceed),
                read("absolute in-root file", ["path": .string(inRoot)], .mustSucceed),
                read("line slice", ["path": "src/a.swift", "start_line": 2, "limit": 2], .mustSucceed),
                read("ignored file is readable", ["path": "src/debug.log"], .mustSucceed),
                read("final-component symlink", ["path": "linkfile.swift"], .mustRefuse, headlessRefusal: "symbolic_link_path"),
                read(
                    "symlinked directory component",
                    ["path": "linkdir/a.swift"],
                    .mustRefuse,
                    headlessRefusal: "symlink_component"
                ),
                read(
                    "escape through symlinked directory",
                    ["path": "outside/secret.swift"],
                    .mustRefuse,
                    headlessRefusal: "pathOutsideWorkspace"
                ),
                read("absolute outside-root path", ["path": .string(outside)], .mustRefuse, headlessRefusal: "pathOutsideWorkspace"),
                read("dot-dot escape", ["path": "../external/secret.swift"], .mustRefuse, headlessRefusal: "pathOutsideWorkspace"),
                read("missing file", ["path": "src/missing.swift"], .mustRefuse, headlessRefusal: "No such file"),
                read("directory path", ["path": "src"], .mustRefuse, headlessRefusal: "not_a_regular_file"),
                structure("code structure of an in-root file", ["src/a.swift"], .mustSucceed),
                structure("code structure of two seed files", ["src/a.swift", "src/b.swift"], .mustSucceed),
                structure(
                    "code structure of a file link",
                    ["linkfile.swift"],
                    .mustRefuse,
                    headlessRefusal: "read_refused:symbolic_link_path"
                ),
                structure(
                    "code structure through an escaping link",
                    ["outside/secret.swift"],
                    .mustRefuse,
                    headlessRefusal: "pathOutsideWorkspace"
                )
            ]
        }

        /// The checked-in `file_search` expectation table for the Git fixture. Every succeeding scenario
        /// names paths it must find and, where relevant, ignored/linked/outside paths it must not.
        private static func searchScenarios() -> [Harness.Scenario] {
            typealias Expectation = Harness.SearchExpectation
            // Files that contain `parityMarker` but must never be reported: Git-ignored, globally
            // ignored, reached through a directory link, or outside the root.
            let hidden = ["src/debug.log", "node_modules/pkg/index.js", "linkdir/search_target.swift", "outside/secret.swift"]
            func search(
                _ name: String,
                _ arguments: [String: Value],
                _ expectation: Expectation?,
                authority: Harness.Authority = .mustSucceed,
                relation: Harness.Relation = .equal,
                headlessRefusal: String? = nil,
                appAuthority: Harness.Authority? = nil
            ) -> Harness.Scenario {
                Harness.Scenario(
                    name: name,
                    tool: .fileSearch,
                    arguments: arguments,
                    authority: authority,
                    relation: relation,
                    headlessRefusal: headlessRefusal,
                    appAuthority: appAuthority,
                    search: expectation
                )
            }
            return [
                search(
                    "content literal excludes ignored, linked, and outside files",
                    ["pattern": "parityMarker", "mode": "content", "regex": false],
                    Expectation(include: ["src/search_target.swift", "docs/guide.md"], exclude: hidden)
                ),
                search(
                    "content regex",
                    ["pattern": "parity[A-Z][a-z]+", "mode": "content", "regex": true],
                    Expectation(include: ["src/search_target.swift", "docs/guide.md"], exclude: hidden)
                ),
                search(
                    "literal content is case-insensitive",
                    ["pattern": "PARITYMARKER", "mode": "content", "regex": false],
                    Expectation(include: ["src/search_target.swift"], exclude: hidden)
                ),
                search(
                    "regex content is case-insensitive",
                    ["pattern": "PARITY[a-z]+", "mode": "content", "regex": true],
                    Expectation(include: ["src/search_target.swift"], exclude: hidden)
                ),
                search(
                    "whole word",
                    ["pattern": "parity", "mode": "content", "regex": false, "whole_word": true],
                    Expectation(include: ["src/search_target.swift"], exclude: ["docs/guide.md"] + hidden)
                ),
                search(
                    "path glob excludes links and outside files",
                    ["pattern": "*.swift", "mode": "path", "regex": false],
                    Expectation(
                        include: ["src/a.swift", "src/search_target.swift"],
                        exclude: ["linkfile.swift", "linkdir/a.swift", "outside/secret.swift"]
                    )
                ),
                search(
                    "path literal",
                    ["pattern": "search_target", "mode": "path", "regex": false],
                    Expectation(include: ["src/search_target.swift"], exclude: ["linkdir/search_target.swift"])
                ),
                search(
                    "hidden dotfile path",
                    ["pattern": ".gitignore", "mode": "path", "regex": false],
                    Expectation(include: [".gitignore"])
                ),
                // Wildcards are path syntax only: a literal content pattern matches `?` as a character.
                search(
                    "literal content wildcard characters match literally",
                    ["pattern": "done?", "mode": "content", "regex": false],
                    Expectation(include: ["docs/guide.md"])
                ),
                search(
                    "extension filter",
                    ["pattern": "parityMarker", "mode": "content", "filter": ["extensions": [".md"]]],
                    Expectation(include: ["docs/guide.md"], exclude: ["src/search_target.swift"] + hidden)
                ),
                search(
                    "path filter",
                    ["pattern": "parityMarker", "mode": "content", "filter": ["paths": ["src"]]],
                    Expectation(include: ["src/search_target.swift"], exclude: ["docs/guide.md"] + hidden)
                ),
                search(
                    "path argument alias",
                    ["pattern": "parityMarker", "mode": "content", "path": "docs"],
                    Expectation(include: ["docs/guide.md"], exclude: ["src/search_target.swift"] + hidden)
                ),
                search(
                    "exclude filter",
                    ["pattern": "parityMarker", "mode": "content", "filter": ["exclude": ["docs"]]],
                    Expectation(include: ["src/search_target.swift"], exclude: ["docs/guide.md"] + hidden)
                ),
                search(
                    "content limit within one file",
                    ["pattern": "limitLine", "mode": "content", "max_results": 2],
                    Expectation(include: ["src/limit.swift"])
                ),
                // `limit` matches the path src/limit.swift and its content: `max_results` caps each stage.
                search(
                    "both-mode limit caps path and content separately",
                    ["pattern": "limit", "mode": "both", "max_results": 1],
                    Expectation(include: ["src/limit.swift"])
                ),
                search(
                    "count only",
                    ["pattern": "parityMarker", "mode": "content", "count_only": true],
                    Expectation(count: 3)
                ),
                search(
                    "count only beyond max_results",
                    ["pattern": "parityMarker", "mode": "content", "count_only": true, "max_results": 1],
                    Expectation(count: 3)
                ),
                search(
                    "auto mode glob",
                    ["pattern": "*.md"],
                    Expectation(include: ["docs/guide.md"])
                ),
                search(
                    "auto mode identifier searches paths too",
                    ["pattern": "search_target"],
                    Expectation(include: ["src/search_target.swift"])
                ),
                search(
                    "auto mode slash pattern searches paths",
                    ["pattern": "src/search"],
                    Expectation(include: ["src/search_target.swift"], exclude: ["linkdir/search_target.swift"])
                ),
                // Without `regex`, call parentheses stay literal: `go()` must not match the `ago` in guide.md.
                search(
                    "regex auto-detection keeps call parentheses literal",
                    ["pattern": "go()", "mode": "content"],
                    Expectation(include: ["src/b.swift"], exclude: ["docs/guide.md"])
                ),
                search(
                    "empty pattern",
                    ["pattern": ""],
                    nil,
                    authority: .mustRefuse,
                    headlessRefusal: "pattern cannot be empty"
                ),
                search(
                    "whitespace-only pattern",
                    ["pattern": "   ", "mode": "content"],
                    nil,
                    authority: .mustRefuse,
                    headlessRefusal: "pattern cannot be empty"
                ),
                // M13: `-` < `.` < `/`, so full-path order puts order/a-z.txt and order/a.txt before
                // order/a/b.txt; a depth-first walk would reach order/a/b.txt first.
                search(
                    "capped content keeps the first hits in full-path order",
                    ["pattern": "orderMarker", "mode": "content", "max_results": 2],
                    Expectation(include: ["order/a-z.txt", "order/a.txt"], exclude: ["order/a/b.txt"])
                ),
                search(
                    "capped paths keep the first hits in full-path order",
                    ["pattern": "order/a", "mode": "path", "max_results": 2],
                    Expectation(include: ["order/a-z.txt", "order/a.txt"], exclude: ["order/a/b.txt"])
                ),
                // M14: both backends clamp `max_results` into 1...FileSearchResultLimits.maximumMaxResults
                // instead of refusing, so zero and negatives keep exactly the first full-path-order hit.
                search(
                    "negative max_results clamps to one hit per stage",
                    ["pattern": "orderMarker", "mode": "content", "max_results": -5],
                    Expectation(include: ["order/a-z.txt"], exclude: ["order/a.txt", "order/a/b.txt"])
                ),
                search(
                    "zero max_results clamps to one hit per stage",
                    ["pattern": "order/a", "mode": "path", "max_results": 0],
                    Expectation(include: ["order/a-z.txt"], exclude: ["order/a.txt", "order/a/b.txt"])
                ),
                search(
                    "max_results above the maximum clamps and still answers",
                    ["pattern": "orderMarker", "mode": "content", "max_results": 1_000_000],
                    Expectation(include: ["order/a-z.txt", "order/a.txt", "order/a/b.txt"])
                ),
                // Only docs/blank_line.txt has an empty line; every other non-empty fixture file ends with a
                // newline, which must not start a phantom empty last line, and the empty file has no lines.
                search(
                    "empty-line regex matches only real empty lines",
                    ["pattern": "^$", "mode": "content", "regex": true],
                    Expectation(
                        include: ["docs/blank_line.txt"],
                        exclude: ["src/a.swift", "docs/guide.md", "docs/crlf.txt", "docs/empty.txt"]
                    )
                ),
                search(
                    "CRLF line numbers",
                    ["pattern": "crlfMarker", "mode": "content"],
                    Expectation(include: ["docs/crlf.txt"])
                ),
                search(
                    "explicit regex wildcard path pattern is a glob",
                    ["pattern": "*.swift", "mode": "path", "regex": true],
                    Expectation(
                        include: ["src/a.swift", "src/search_target.swift"],
                        exclude: ["linkfile.swift", "linkdir/a.swift", "outside/secret.swift"]
                    )
                ),
                search(
                    "uncompilable path regex falls back to literal matching",
                    ["pattern": "(unclosed", "mode": "path", "regex": true],
                    Expectation(include: ["docs/call(unclosed.txt"])
                ),
                search(
                    "path stage ignores whole_word",
                    ["pattern": "search", "mode": "path", "whole_word": true],
                    Expectation(include: ["src/search_target.swift"], exclude: ["linkdir/search_target.swift"])
                ),
                search(
                    "path glob retries with a trailing wildcard",
                    ["pattern": "src/*.sw", "mode": "path"],
                    Expectation(include: ["src/a.swift", "src/search_target.swift"], exclude: ["linkdir/a.swift"])
                ),
                // The app must really answer (its literal fallback finds the file), not merely not refuse.
                search(
                    "invalid regex",
                    ["pattern": "(unclosed", "mode": "content", "regex": true],
                    Expectation(include: ["docs/call(unclosed.txt"]),
                    authority: .mustRefuse,
                    relation: .knownDivergence(
                        "the app repairs an uncompilable content regex (literal fallback) and answers; headless "
                            + "rejects it with the compile error whenever content is searched (stricter, never broader)"
                    ),
                    headlessRefusal: "Code=2048",
                    appAuthority: .mustSucceed
                ),
                search(
                    "unknown mode",
                    ["pattern": "parityMarker", "mode": "fuzzy"],
                    Expectation(include: ["src/search_target.swift"], exclude: hidden),
                    authority: .mustRefuse,
                    relation: .knownDivergence(
                        "the app falls back to auto for a mode outside the schema enum; headless rejects it "
                            + "as invalid params (stricter, never broader)"
                    ),
                    headlessRefusal: "mode must be auto, path, content, or both",
                    appAuthority: .mustSucceed
                )
            ]
        }

        // MARK: - Helpers

        private struct GitFixture {
            let root: URL
            let external: URL
        }

        /// A committed Git repository (isolated `HOME`, local identity, no signing) under a
        /// kernel-canonical temporary parent, plus an external directory outside it:
        /// ```
        /// root/.gitignore            *.log
        /// root/src/a.swift, root/src/b.swift, root/src/debug.log (ignored, untracked)
        /// root/src/search_target.swift, root/src/limit.swift, root/docs/guide.md
        /// root/order/a.txt, root/order/a-z.txt, root/order/a/b.txt (each `orderMarker`)
        /// root/docs/blank_line.txt (one empty line), root/docs/crlf.txt (CRLF endings), root/docs/empty.txt,
        /// root/docs/call(unclosed.txt (contains `call(unclosed`)
        /// root/node_modules/pkg/index.js (globally ignored)
        /// root/linkfile.swift -> src/a.swift      root/linkdir -> src
        /// root/outside -> <external>              <external>/secret.swift
        /// ```
        /// `parityMarker` appears in search_target.swift (twice), guide.md, and — never to be reported —
        /// debug.log, node_modules, and the external secret. guide.md also contains `ago` (not `go()`).
        private func makeGitFixture() throws -> GitFixture {
            let git = try ReviewGitRepositoryFixture(name: "mcp-backend-parity", parentDirectory: canonicalTemporaryDirectory())
            addTeardownBlock { git.cleanup() }
            let root = git.sandbox.appendingPathComponent("root", isDirectory: true)
            let external = git.sandbox.appendingPathComponent("external", isDirectory: true)
            try git.initializeRepository(at: root)
            try git.write("let secret = \"OUTSIDE_ROOT_SECRET\"\n// parityMarker outside\n", to: "secret.swift", at: external)
            try git.write("*.log\n", to: ".gitignore", at: root)
            try git.write("struct A {\n    func run() {}\n}\nlet tail = 3\n", to: "src/a.swift", at: root)
            try git.write("struct B {\n    let a = A()\n    func go() { a.run() }\n}\n", to: "src/b.swift", at: root)
            try git.write("log line parityMarker\n", to: "src/debug.log", at: root)
            try git.write(
                "// parityMarker first\nlet parityMarker = 1\n// parity check\n",
                to: "src/search_target.swift",
                at: root
            )
            try git.write("let a = \"limitLine one\"\nlet b = \"limitLine two\"\nlet c = \"limitLine three\"\n", to: "src/limit.swift", at: root)
            try git.write("parityMarker in docs\nwritten long ago\nis it done? yes\n", to: "docs/guide.md", at: root)
            try git.write("// parityMarker in a dependency\n", to: "node_modules/pkg/index.js", at: root)
            for path in ["order/a.txt", "order/a-z.txt", "order/a/b.txt"] {
                try git.write("orderMarker\n", to: path, at: root)
            }
            try git.write("above\n\nbelow\n", to: "docs/blank_line.txt", at: root)
            try git.write("first\r\nsecond crlfMarker\r\n", to: "docs/crlf.txt", at: root)
            try git.write("", to: "docs/empty.txt", at: root)
            try git.write("value = call(unclosed\n", to: "docs/call(unclosed.txt", at: root)
            for (link, destination) in [("linkfile.swift", "src/a.swift"), ("linkdir", "src"), ("outside", external.path)] {
                try FileManager.default.createSymbolicLink(
                    atPath: root.appendingPathComponent(link).path,
                    withDestinationPath: destination
                )
            }
            try git.runGit(["add", "-A"], at: root)
            try git.commit("Parity fixture", at: root)
            return GitFixture(root: root, external: external)
        }

        private func makeNonGitFixture() throws -> URL {
            let parent = try canonicalTemporaryDirectory()
                .appendingPathComponent("mcp-backend-parity-non-git-\(UUID().uuidString)", isDirectory: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
            let root = parent.appendingPathComponent("root", isDirectory: true)
            let file = root.appendingPathComponent("src/a.swift")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("struct A {\n    func run() {}\n}\n".utf8).write(to: file)
            return root
        }

        /// The kernel-canonical temporary directory (`/private/var/...`).
        private func canonicalTemporaryDirectory() throws -> URL {
            let canonical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
            defer { free(canonical) }
            return URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        }

        /// Pins the app's global ignore defaults for this test and restores them afterwards.
        private func pinGlobalIgnoreDefaults() async throws {
            let authority = GlobalIgnoreDefaultsAuthority()
            authority.publish(Self.globalPatterns)
            await IgnoreRulesManager.shared.setGlobalDefaultsAuthorityOverride(authority)
            addTeardownBlock { await IgnoreRulesManager.shared.setGlobalDefaultsAuthorityOverride(nil) }
        }

        private func assertGate(_ report: Harness.Report, scenarios: [Harness.Scenario], attachmentName: String) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let attachment = try XCTAttachment(data: encoder.encode(report), uniformTypeIdentifier: "public.json")
            attachment.name = attachmentName
            attachment.lifetime = .keepAlways
            add(attachment)
            for scenario in report.scenarios {
                print(
                    "MCPParity \(scenario.tool.rawValue) \"\(scenario.name)\": app=\(scenario.appOutcome)"
                        + " headless=\(scenario.headlessOutcome)"
                        + " app_p50_ms=\(Self.format(scenario.appLatency.p50MS))"
                        + " headless_p50_ms=\(Self.format(scenario.headlessLatency.p50MS))"
                        + " app_max_ms=\(Self.format(scenario.appLatency.maxMS))"
                        + " headless_max_ms=\(Self.format(scenario.headlessLatency.maxMS))"
                        + (scenario.appSettleMS.map { " app_settle_ms=\(Self.format($0))" } ?? "")
                        + (scenario.appQuiescent.map { " app_quiescent=\($0)" } ?? "")
                        + " app_detail=\(scenario.appDetail ?? "-")"
                        + " headless_detail=\(scenario.headlessDetail ?? "-")"
                        + (scenario.appDiagnostics.map { " APP_CODEMAP=\($0)" } ?? "")
                        + (scenario.appSettleTrace.map { " SETTLE_TRACE=\($0.joined(separator: " > "))" } ?? "")
                        + (scenario.appSampleStates.map { " APP_SAMPLES=\($0.joined(separator: " > "))" } ?? "")
                        + (scenario.violations.isEmpty ? "" : " VIOLATIONS=\(scenario.violations)")
                )
            }
            XCTAssertEqual(report.scenarios.map(\.name), scenarios.map(\.name))
            for scenario in report.scenarios {
                XCTAssertEqual(scenario.violations, [], "\(scenario.tool.rawValue) \(scenario.name)")
                for latency in [scenario.appLatency, scenario.headlessLatency] {
                    XCTAssertEqual(latency.samplesMS.count, Self.iterations, scenario.name)
                    XCTAssertTrue(latency.samplesMS.allSatisfy { $0.isFinite && $0 >= 0 }, scenario.name)
                    XCTAssertLessThanOrEqual(latency.p50MS, latency.maxMS, scenario.name)
                }
            }
            XCTAssertEqual(report.notProven, Harness.notProven)
        }

        private static func file(_ name: String, _ text: String) -> Harness.MappedFile {
            Harness.MappedFile(name: name, text: text)
        }

        private func evaluate(
            authority: Harness.Authority,
            relation: Harness.Relation,
            app: [Harness.Outcome],
            headless: [Harness.Outcome]
        ) -> Harness.ScenarioReport {
            Harness.evaluate(
                Harness.Scenario(name: "unit", tool: .readFile, arguments: [:], authority: authority, relation: relation),
                app: app.map { Harness.Observation(outcome: $0, detail: nil) },
                headless: headless.map { Harness.Observation(outcome: $0, detail: nil) },
                appSamples: [1],
                headlessSamples: [1]
            )
        }

        private static func format(_ milliseconds: Double) -> String {
            String(format: "%.3f", milliseconds)
        }
    }
#endif
