import Foundation
@testable import RepoPromptMCP
import RepoPromptShared
import XCTest

/// M8G: counts-only local summary of terminal records for the field-failure taxonomy.
final class MCPTerminalRecordSummaryTests: XCTestCase {
    func testSummaryGroupsReasonsCountsSettlementAndNeverEmitsFreeText() throws {
        let directory = try makeDirectory()
        let now = Date()
        try write(record(reason: "app_socket_closed", active: 2, settled: 2, unsettled: 0, at: now), to: directory)
        try write(record(reason: "app_socket_closed", active: 1, settled: 0, unsettled: 1, at: now), to: directory)
        try write(record(reason: "startup_budget_exceeded", initiator: .transport, at: now), to: directory)
        try write(record(reason: "Connection refused: /Users/someone/secret path", at: now), to: directory)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("terminal-broken.json"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("cli-event.json"))

        let summary = MCPTerminalRecordSummary.summarize(directory: directory)

        XCTAssertEqual(summary.recordCount, 4)
        XCTAssertEqual(summary.undecodableRecordCount, 1, "only terminal-*.json files are considered")
        XCTAssertEqual(summary.reasons.first?.reason, "app_socket_closed")
        XCTAssertEqual(summary.reasons.first?.count, 2)
        XCTAssertEqual(Set(summary.reasons.map(\.reason)), ["app_socket_closed", "startup_budget_exceeded", "other"])
        XCTAssertEqual(summary.recordsWithActiveRequests, 2)
        XCTAssertEqual(summary.hostSettledRequestTotal, 2)
        XCTAssertEqual(summary.hostUnsettledRequestTotal, 1)
        XCTAssertEqual(summary.recordsWithUnsettledRequests, 1)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try XCTUnwrap(String(data: encoder.encode(summary), encoding: .utf8))
        XCTAssertFalse(json.contains("someone"))
        XCTAssertFalse(json.contains("secret"))
        XCTAssertFalse(json.contains("sha256:"), "session fingerprints never appear")
    }

    func testSinceFilterAndCommandOutput() throws {
        let directory = try makeDirectory()
        let now = Date()
        try write(record(reason: "old_reason", at: now.addingTimeInterval(-3 * 3600)), to: directory)
        try write(record(reason: "recent_reason", at: now.addingTimeInterval(-600)), to: directory)

        var printed: [String] = []
        let status = MCPDiagnosticsCommand.run(
            arguments: ["terminal-summary", "--since-hours", "1"],
            eventsDirectory: directory,
            now: now,
            output: { printed.append($0) },
            errorOutput: { XCTFail("unexpected error output: \($0)") }
        )
        XCTAssertEqual(status, 0)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(XCTUnwrap(printed.first).utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["record_count"] as? Int, 1)
        let reasons = try XCTUnwrap(object["reasons"] as? [[String: Any]])
        XCTAssertEqual(reasons.first?["reason"] as? String, "recent_reason")
    }

    func testCommandRejectsUnknownArgumentsWithUsageStatus() {
        var errors: [String] = []
        for arguments in [[], ["other"], ["terminal-summary", "--since-hours"], ["terminal-summary", "--since-hours", "-1"]] {
            let status = MCPDiagnosticsCommand.run(
                arguments: arguments,
                eventsDirectory: FileManager.default.temporaryDirectory,
                output: { _ in XCTFail("no output expected") },
                errorOutput: { errors.append($0) }
            )
            XCTAssertEqual(status, MCPDiagnosticsCommand.usageExitCode, "\(arguments)")
        }
        XCTAssertEqual(errors.count, 4)
    }

    func testParseCLIModeRoutesDiagnosticsBeforeProxyParsing() {
        guard case let .diagnostics(arguments) = parseCLIMode(arguments: ["repoprompt-mcp", "diagnostics", "terminal-summary"]) else {
            return XCTFail("Expected diagnostics mode")
        }
        XCTAssertEqual(arguments, ["terminal-summary"])
    }

    // MARK: - Helpers

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-terminal-summary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func record(
        reason: String,
        initiator: MCPTerminalInitiator = .peer,
        active: Int = 0,
        settled: Int? = nil,
        unsettled: Int? = nil,
        at timestamp: Date
    ) -> MCPTerminalRecord {
        MCPTerminalRecord(
            timestamp: timestamp,
            layer: .proxy,
            initiator: initiator,
            reason: reason,
            sessionToken: UUID().uuidString,
            localPID: 1,
            peerPID: 2,
            appConnectionID: nil,
            connectionGeneration: 1,
            errno: nil,
            errorDescription: "free text that must not be summarized",
            bridgeActiveRequestCount: active,
            hostSettledRequestCount: settled,
            hostUnsettledRequestCount: unsettled
        )
    }

    private func write(_ record: MCPTerminalRecord, to directory: URL) throws {
        try MCPTerminalRecordStore.write(record, to: directory)
    }
}
