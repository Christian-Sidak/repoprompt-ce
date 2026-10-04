import Foundation
@testable import RepoPromptApp
import XCTest

final class HistoryAnalyticsTests: XCTestCase {
    func testDurationUsesProviderCoverageButExcludesLongPauseInsideOneTurn() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let resumed = start.addingTimeInterval(86400)
        let turn = AgentTranscriptTurn(
            responseSpans: [
                AgentTranscriptProviderResponseSpan(
                    lifecycle: .completed,
                    startedAt: start,
                    lastActivityAt: start.addingTimeInterval(120),
                    completedAt: start.addingTimeInterval(120)
                ),
                AgentTranscriptProviderResponseSpan(
                    lifecycle: .completed,
                    startedAt: resumed,
                    lastActivityAt: resumed.addingTimeInterval(60),
                    completedAt: resumed.addingTimeInterval(60)
                )
            ],
            terminalState: .completed,
            startedAt: start,
            lastActivityAt: resumed.addingTimeInterval(60),
            completedAt: resumed.addingTimeInterval(60)
        )

        let primitives = AgentSessionMetadataRecord.computeDurationPrimitives(from: [turn])

        XCTAssertEqual(primitives.coveredSeconds, 180)
        XCTAssertEqual(primitives.gapSeconds, [86280])
        XCTAssertEqual(
            AgentSessionMetadataRecord.activeDurationSeconds(
                intervals: AgentSessionMetadataRecord.activityIntervals(from: turn),
                thresholdMinutes: 10
            ),
            180
        )
    }

    func testTranscriptTurnCountIsIndependentFromProjectedItemCount() {
        let record = makeRecord(id: UUID(), freshness: 1, itemCount: 275)
        let enriched = record.enrichingTranscriptDerivedFields(from: [
            AgentTranscriptTurn(startedAt: Date(timeIntervalSinceReferenceDate: 1)),
            AgentTranscriptTurn(startedAt: Date(timeIntervalSinceReferenceDate: 2))
        ])

        XCTAssertEqual(enriched.transcriptTurnCount, 2)
        XCTAssertEqual(enriched.itemCount, 275)
    }

    func testCrossWorkspaceFilteringDeduplicatesSessionIDUsingFreshestProjection() {
        let sessionID = UUID()
        let stale = makeRecord(id: sessionID, freshness: 1, itemCount: 10)
        let fresh = makeRecord(id: sessionID, freshness: 2, itemCount: 20)
        let scanner = HistorySessionScanner(applicationSupportRoot: URL(fileURLWithPath: "/tmp/history-tests"))

        let matches = scanner.sessionsMatchingFilters(
            [
                HistoryWorkspaceScanResult(
                    workspaceDir: URL(fileURLWithPath: "/tmp/workspace-a"),
                    workspaceName: "A",
                    workspaceID: UUID(),
                    records: [stale],
                    indexReadFailed: false,
                    indexSchemaVersion: nil
                ),
                HistoryWorkspaceScanResult(
                    workspaceDir: URL(fileURLWithPath: "/tmp/workspace-b"),
                    workspaceName: "B",
                    workspaceID: UUID(),
                    records: [fresh],
                    indexReadFailed: false,
                    indexSchemaVersion: nil
                )
            ],
            workspace: nil,
            agentKind: nil,
            model: nil,
            filePath: nil,
            from: nil,
            to: nil
        )

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.workspaceName, "B")
        XCTAssertEqual(matches.first?.record.itemCount, 20)
    }

    func testTokenUsageAttributionIsBackwardCompatibleAndRoundTripsIDs() throws {
        let legacy = AgentTokenUsagePersist(promptTokens: 11, completionTokens: 7)
        let legacyDecoded = try JSONDecoder().decode(
            AgentTokenUsagePersist.self,
            from: JSONEncoder().encode(legacy)
        )
        XCTAssertNil(legacyDecoded.runID)
        XCTAssertNil(legacyDecoded.turnID)

        let runID = UUID()
        let turnID = UUID()
        let attributed = AgentTokenUsagePersist(
            runID: runID,
            turnID: turnID,
            promptTokens: 13,
            completionTokens: 5,
            estimatedToolInputTokens: 3,
            estimatedToolOutputTokens: 2
        )
        let decoded = try JSONDecoder().decode(
            AgentTokenUsagePersist.self,
            from: JSONEncoder().encode(attributed)
        )

        XCTAssertEqual(decoded.runID, runID)
        XCTAssertEqual(decoded.turnID, turnID)
        XCTAssertEqual(decoded.estimatedToolInputTokens, 3)
        XCTAssertEqual(decoded.estimatedToolOutputTokens, 2)
    }

    // MARK: - Stale index decode-count isolation (issue 1091)

    /// Verifies that stale-schema indexes do not consume the `maxIndexDecodes` budget.
    /// Before the fix, 2000+ stale indexes (v2/v5/v6) would exhaust the 2000-decode limit
    /// before any current-schema index was processed, returning 0 sessions.
    func testStaleSchemaIndexesDoNotCountAgainstDecodeLimit() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-history-stale-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        // Build one current-schema workspace and many stale-schema workspaces.
        let currentSchemaVersion = AgentSessionMetadataIndex.currentSchemaVersion
        let staleSchemaVersion = currentSchemaVersion - 1

        func makeWorkspace(_ name: String, schemaVersion: Int) throws -> URL {
            let workspaceDir = tmp.appendingPathComponent(name, isDirectory: true)
            let agentSessionsDir = workspaceDir.appendingPathComponent("AgentSessions", isDirectory: true)
            try FileManager.default.createDirectory(at: agentSessionsDir, withIntermediateDirectories: true)
            let indexJSON = """
            {"schemaVersion":\(schemaVersion),"generatedAt":"2026-01-01T00:00:00Z","entries":[],"quarantinedFiles":[]}
            """
            try indexJSON.data(using: .utf8)!.write(
                to: agentSessionsDir.appendingPathComponent("AgentSessionIndex.json")
            )
            return workspaceDir
        }

        // Create 5 stale workspaces followed by 1 current-schema workspace.
        var workspaceDirs: [URL] = []
        for i in 0 ..< 5 {
            workspaceDirs.append(try makeWorkspace("stale-\(i)", schemaVersion: staleSchemaVersion))
        }
        let currentDir = try makeWorkspace("current-0", schemaVersion: currentSchemaVersion)
        workspaceDirs.append(currentDir)

        // Budget: only 1 full decode allowed. Without the fix, the 5 stale reads would have
        // pre-consumed decode slots and the current-schema index would be rejected.
        let tightBudget = HistoryInventoryBudget(
            maxWorkspaces: 100,
            maxIndexDecodes: 1,
            maxIndexBytes: 64 * 1024 * 1024
        )
        let scanner = HistorySessionScanner(
            applicationSupportRoot: tmp,
            inventoryBudget: tightBudget,
            workspaceDirectoryProvider: { _ in workspaceDirs }
        )
        let result = try await scanner.scanWorkspaces(matching: nil)

        // The current-schema workspace must be present and its index must have been decoded.
        XCTAssertFalse(result.isTruncated, "scan should not be truncated; stale reads must not exhaust the decode budget")
        let decodeCount = await scanner.indexDecodeCountForTesting
        XCTAssertEqual(decodeCount, 1, "exactly one full decode for the current-schema index")
        let currentResult = result.workspaces.first { $0.workspaceDir == currentDir }
        XCTAssertNotNil(currentResult, "current-schema workspace must appear in results")
        XCTAssertNil(currentResult?.indexSchemaVersion, "current-schema entry should have nil indexSchemaVersion")

        // Stale workspaces should appear with their schema version recorded but no records.
        let staleResults = result.workspaces.filter { $0.indexSchemaVersion == staleSchemaVersion }
        XCTAssertEqual(staleResults.count, 5, "all stale workspaces should be present")
    }

    private func makeRecord(id: UUID, freshness: TimeInterval, itemCount: Int) -> AgentSessionMetadataRecord {
        let date = Date(timeIntervalSinceReferenceDate: freshness)
        return AgentSessionMetadataRecord(
            id: id,
            filename: "AgentSession-\(id.uuidString).json",
            workspaceID: nil,
            composeTabID: nil,
            name: "Session",
            savedAt: date,
            lastUserMessageAt: nil,
            itemCount: itemCount,
            transcriptProjectionCounts: nil,
            hasUnknownConversationContent: false,
            agentKindRaw: nil,
            agentModelRaw: nil,
            agentReasoningEffortRaw: nil,
            lastRunStateRaw: nil,
            autoEditEnabled: true,
            parentSessionID: nil,
            isMCPOriginated: true,
            serializationVersion: nil,
            observedFileSize: nil,
            observedFileModificationDate: date,
            lastIndexedAt: date
        )
    }
}
