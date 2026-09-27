import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

/// #1071: unmet selection-drain prerequisites are typed, retryable failures; only a genuine
/// cancellation remains `CancellationError`.
final class MCPSelectionPrerequisiteErrorTests: XCTestCase {
    func testDrainOutcomesMapToSuccessTypedFailureOrCancellation() throws {
        XCTAssertNoThrow(try MCPSelectionPrerequisiteError.require(.completed, .canonicalSelection))

        XCTAssertThrowsError(try MCPSelectionPrerequisiteError.require(.cancelled, .canonicalSelection)) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertThrowsError(try MCPSelectionPrerequisiteError.require(.deferred, .mirroredSelectionAndMetrics)) { error in
            XCTAssertEqual(error as? MCPSelectionPrerequisiteError, .deferred(.mirroredSelectionAndMetrics))
            XCTAssertFalse(error is CancellationError)
        }
        XCTAssertThrowsError(try MCPSelectionPrerequisiteError.require(.invalidated, .canonicalSelection)) { error in
            XCTAssertEqual(error as? MCPSelectionPrerequisiteError, .invalidated(.canonicalSelection))
        }
    }

    func testPrerequisiteFailuresRenderAsRetryableWithoutApplyingState() throws {
        for failure in [
            MCPSelectionPrerequisiteError.deferred(.canonicalSelection),
            .invalidated(.mirroredSelectionAndMetrics)
        ] {
            let result = ServerNetworkManager.executionContractToolErrorResult(
                rawJSON: true,
                code: failure.code,
                message: failure.localizedDescription,
                metadata: [
                    "retryable": .bool(true),
                    "mutation_state": .string("not_applied"),
                    "prerequisite": .string(failure.requirement.rawValue)
                ]
            )
            guard case let .text(text, _, _) = try XCTUnwrap(result.content.first) else {
                return XCTFail("Expected text content")
            }
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            XCTAssertEqual(object["code"] as? String, failure.code)
            XCTAssertEqual(object["retryability"] as? String, "retryable")
            XCTAssertEqual(object["mutation_state"] as? String, "not_applied")
            XCTAssertTrue(failure.localizedDescription.contains("Nothing was changed"))
        }
    }
}
