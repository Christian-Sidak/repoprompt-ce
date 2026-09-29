import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

/// #1071: an unmet selection prerequisite renders through the execution-contract path under its
/// #1081 wire code, as a retryable failure that applied nothing. Its description already leads with
/// the code, so default-mode text still carries the code exactly once. Drain classification and
/// genuine cancellation are covered by `MCPSelectionPrerequisiteErrorTests`.
final class MCPSelectionPrerequisiteErrorRenderingTests: XCTestCase {
    private let failures: [MCPSelectionPrerequisiteError] = [.deferred, .invalidated]

    func testDescriptionLeadsWithTheWireCode() {
        XCTAssertEqual(MCPSelectionPrerequisiteError.deferred.code, "selection_prerequisite_deferred")
        XCTAssertEqual(MCPSelectionPrerequisiteError.invalidated.code, "selection_prerequisite_invalidated")
        for failure in failures {
            XCTAssertTrue(failure.description.hasPrefix("\(failure.code): "), failure.description)
            XCTAssertEqual(failure.localizedDescription, failure.description)
        }
    }

    func testRawJSONRendersRetryableWithoutApplyingState() throws {
        for failure in failures {
            let text = try textContent(render(failure, rawJSON: true))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            XCTAssertEqual(object["is_error"] as? Bool, true, text)
            XCTAssertEqual(object["code"] as? String, failure.code, text)
            XCTAssertEqual(object["error"] as? String, failure.description, text)
            XCTAssertEqual(object["retryability"] as? String, "retryable", text)
            XCTAssertEqual(object["retryable"] as? Bool, true, text)
            XCTAssertEqual(object["mutation_state"] as? String, "not_applied", text)
        }
    }

    func testDefaultModeCarriesTheCodeOnceWithRetryGuidance() throws {
        for failure in failures {
            let text = try textContent(render(failure, rawJSON: false))
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            XCTAssertEqual(lines.count, 2, text)
            XCTAssertEqual(lines.first.map(String.init), failure.description)
            XCTAssertEqual(text.components(separatedBy: failure.code).count - 1, 1, "The code must appear exactly once: \(text)")
            let guidance = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
            XCTAssertEqual(guidance["retryability"] as? String, "retryable", text)
            XCTAssertEqual(guidance["retryable"] as? Bool, true, text)
            XCTAssertEqual(guidance["mutation_state"] as? String, "not_applied", text)
        }
    }

    func testMessagesWithoutTheirCodeKeepTheCodePrefix() {
        let text = ServerNetworkManager.defaultModeExecutionContractErrorText(
            code: "selection_prerequisite_deferred",
            message: "selection_prerequisite_deferred_elsewhere: unrelated text",
            metadata: [:]
        )
        XCTAssertEqual(text, "selection_prerequisite_deferred: selection_prerequisite_deferred_elsewhere: unrelated text")
    }

    /// Mirrors the metadata the app host attaches in its execution-contract failure branch.
    private func render(_ failure: MCPSelectionPrerequisiteError, rawJSON: Bool) -> CallTool.Result {
        ServerNetworkManager.executionContractToolErrorResult(
            rawJSON: rawJSON,
            code: failure.code,
            message: failure.localizedDescription,
            metadata: [
                "retryable": .bool(true),
                "mutation_state": .string("not_applied")
            ]
        )
    }

    private func textContent(_ result: CallTool.Result) throws -> String {
        XCTAssertEqual(result.isError, true)
        guard case let .text(text, _, _) = try XCTUnwrap(result.content.first) else {
            XCTFail("Expected text content")
            return ""
        }
        return text
    }
}
