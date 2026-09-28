import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    /// M8S gate: app-versus-headless parity for the MCP read boundary (`read_file`,
    /// `get_code_structure`), with latency recorded but never threshold-asserted. See
    /// `MCPBackendParityHarness` for what the gate does not prove.
    @MainActor
    final class MCPBackendParityHarnessTests: XCTestCase {
        private typealias Harness = MCPBackendParityHarness
        private static let iterations = 5
        private static let globalPatterns = "**/node_modules/\n"

        func testReadBoundaryParityAndLatencyGate() async throws {
            let fixture = try makeFixture()
            let authority = GlobalIgnoreDefaultsAuthority()
            authority.publish(Self.globalPatterns)
            await IgnoreRulesManager.shared.setGlobalDefaultsAuthorityOverride(authority)
            addTeardownBlock { await IgnoreRulesManager.shared.setGlobalDefaultsAuthorityOverride(nil) }
            let harness = try await Harness.make(root: fixture.root, globalPatterns: Self.globalPatterns)
            addTeardownBlock { @MainActor in await harness.close() }
            let scenarios = Self.scenarios(root: fixture.root, external: fixture.external)

            let report = await harness.run(scenarios, iterations: Self.iterations)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let json = try encoder.encode(report)
            let attachment = XCTAttachment(data: json, uniformTypeIdentifier: "public.json")
            attachment.name = "mcp-backend-parity-report.json"
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
                        + " app_detail=\(scenario.appDetail ?? "-")"
                        + " headless_detail=\(scenario.headlessDetail ?? "-")"
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

        // MARK: - Gate logic (deterministic, no backends)

        func testEqualRelationFlagsDifferingOutcomes() {
            let report = evaluate(
                authority: .mustSucceed,
                relation: .equal,
                app: [.content("a")],
                headless: [.content("b")]
            )
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

        func testUnsettledAppIndexIsReportedNotFailed() {
            let report = evaluate(
                authority: .mustSucceed,
                relation: .equal,
                app: [.unsettled],
                headless: [.mapped(["a.swift"])]
            )
            XCTAssertEqual(report.violations, [])
            XCTAssertEqual(report.appOutcome, "unsettled")
        }

        func testUnsettledAppIndexCannotMaskDisclosure() {
            let report = evaluate(
                authority: .mustRefuse,
                relation: .equal,
                app: [.unsettled],
                headless: [.mapped(["secret.swift"])]
            )
            XCTAssertEqual(report.violations, ["headless must refuse but was mapped(secret.swift)"])
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

        func testLatencySummaryUsesLowerMedianAndMax() {
            let summary = Harness.LatencySummary(samples: [4, 1, 3, 2])
            XCTAssertEqual(summary.p50MS, 2)
            XCTAssertEqual(summary.maxMS, 4)
        }

        // MARK: - Scenario table

        /// The checked-in expectation table. Update a relation only with a documented reason.
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

        // MARK: - Helpers

        private struct Fixture {
            let root: URL
            let external: URL
        }

        /// ```
        /// root/.gitignore            *.log
        /// root/src/a.swift, root/src/debug.log
        /// root/linkfile.swift -> src/a.swift      root/linkdir -> src
        /// root/outside -> <external>              <external>/secret.swift
        /// ```
        private func makeFixture() throws -> Fixture {
            let created = FileManager.default.temporaryDirectory
                .appendingPathComponent("mcp-backend-parity-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
            let canonical = try XCTUnwrap(realpath(created.path, nil))
            defer { free(canonical) }
            let parent = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
            let root = parent.appendingPathComponent("root", isDirectory: true)
            let external = parent.appendingPathComponent("external", isDirectory: true)
            let files: [(URL, String)] = [
                (root.appendingPathComponent(".gitignore"), "*.log\n"),
                (root.appendingPathComponent("src/a.swift"), "struct A {\n    func run() {}\n}\nlet tail = 3\n"),
                (root.appendingPathComponent("src/debug.log"), "log line\n"),
                (external.appendingPathComponent("secret.swift"), "let secret = \"OUTSIDE_ROOT_SECRET\"\n")
            ]
            for (url, contents) in files {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contents.utf8).write(to: url)
            }
            for (link, destination) in [("linkfile.swift", "src/a.swift"), ("linkdir", "src"), ("outside", external.path)] {
                try FileManager.default.createSymbolicLink(
                    atPath: root.appendingPathComponent(link).path,
                    withDestinationPath: destination
                )
            }
            return Fixture(root: root, external: external)
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
