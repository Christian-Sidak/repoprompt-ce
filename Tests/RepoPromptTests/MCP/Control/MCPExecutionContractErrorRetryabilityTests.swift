import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptShared
import XCTest

/// M8H: app execution-contract errors carry the shared retry guidance in default (non-raw) mode
/// without repeating the code, and raw JSON gains the same `retryability` field.
final class MCPExecutionContractErrorRetryabilityTests: XCTestCase {
    func testDefaultModeAppendsGuidanceLineWithoutRepeatingTheCode() throws {
        let text = try defaultText(ServerNetworkManager.executionContractToolErrorResult(
            rawJSON: false,
            code: "tool_execution_connection_terminal",
            message: "The MCP connection is closing."
        ))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], "tool_execution_connection_terminal: The MCP connection is closing.")
        XCTAssertEqual(text.components(separatedBy: "tool_execution_connection_terminal").count - 1, 1)
        let guidance = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        XCTAssertEqual(guidance["retryability"] as? String, "retryable")
        XCTAssertEqual(guidance["retryable"] as? Bool, true)
        XCTAssertNil(guidance["code"])
    }

    func testUnclassifiedCodeKeepsLegacySingleLineText() throws {
        let text = try defaultText(ServerNetworkManager.executionContractToolErrorResult(
            rawJSON: false,
            code: "some_future_code",
            message: "Something happened."
        ))
        XCTAssertEqual(text, "some_future_code: Something happened.")
    }

    func testRawJSONGainsRetryabilityAndKeepsLegacyFlag() throws {
        let text = try defaultText(ServerNetworkManager.executionContractToolErrorResult(
            rawJSON: true,
            code: "tool_execution_structure_settlement_busy",
            message: "busy",
            metadata: ["retryable": .bool(true), "retry_after_ms": .int(750)]
        ))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(object["code"] as? String, "tool_execution_structure_settlement_busy")
        XCTAssertEqual(object["retryability"] as? String, "retry_after")
        XCTAssertEqual(object["retryable"] as? Bool, true)
        XCTAssertEqual(object["retry_after_ms"] as? Int, 750)
    }

    func testWatchdogFailuresUseSharedClassifierRules() {
        let contract = MCPToolExecutionContractCatalog.contract(for: MCPWindowToolName.readFile)

        let readTimeout = ServerNetworkManager.typedRetryabilityMetadata(
            ["settlement": .string("cancellation")],
            code: "tool_execution_timeout",
            error: MCPToolExecutionWatchdogError.executionTimedOut(settlement: .cancellation),
            toolName: MCPWindowToolName.readFile,
            contract: contract
        )
        XCTAssertEqual(readTimeout["retryability"], .string("retryable"))
        XCTAssertEqual(readTimeout["retryable"], .bool(true))

        let mutationTimeout = ServerNetworkManager.typedRetryabilityMetadata(
            [:],
            code: "tool_execution_timeout",
            error: MCPToolExecutionWatchdogError.executionTimedOut(settlement: .cancellation),
            toolName: MCPWindowToolName.manageSelection,
            contract: contract
        )
        XCTAssertEqual(mutationTimeout["retryability"], .string("indeterminate"))
        XCTAssertEqual(mutationTimeout["retryable"], .bool(false))

        let exportNotApplied = ServerNetworkManager.typedRetryabilityMetadata(
            ["retryable": .bool(true), "mutation_state": .string("not_applied")],
            code: "tool_execution_timeout",
            error: MCPToolExecutionWatchdogError.executionTimedOut(settlement: .cancellation),
            toolName: MCPWindowToolName.prompt,
            contract: contract,
            mutation: DomainProtectedMutationSettlement(state: .notApplied, operationID: "op")
        )
        XCTAssertEqual(exportNotApplied["retryability"], .string("retryable"))
        XCTAssertEqual(exportNotApplied["retryable"], .bool(true))
    }

    func testLegacyFlagStaysAuthoritativeWhenDerivationDisagrees() {
        // The app force-disconnects a read provider that ignored cancellation and reports
        // retryable=false; guidance must not contradict that flag.
        let cleanup = ServerNetworkManager.typedRetryabilityMetadata(
            ["retryable": .bool(false), "settlement": .string("force_disconnect")],
            code: "tool_execution_cleanup_unresponsive",
            error: MCPToolExecutionWatchdogError.cleanupUnresponsive,
            toolName: MCPWindowToolName.readFile,
            contract: MCPToolExecutionContractCatalog.contract(for: MCPWindowToolName.readFile)
        )
        XCTAssertEqual(cleanup["retryability"], .string("permanent"))
        XCTAssertEqual(cleanup["retryable"], .bool(false))
    }

    private func defaultText(_ result: CallTool.Result) throws -> String {
        guard case let .text(text, _, _) = try XCTUnwrap(result.content.first) else {
            XCTFail("Expected text content")
            return ""
        }
        XCTAssertEqual(result.isError, true)
        return text
    }
}
