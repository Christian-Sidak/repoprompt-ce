import Foundation
@testable import RepoPromptApp
import XCTest

final class OverseerACPApprovalPolicyTests: XCTestCase {
    func testSelectsOnlyOneTimeAllowWhenBroaderOptionsComeFirst() {
        let options = [
            (optionID: "allow_always", kind: "allow_always"),
            (optionID: "allow-edits-session", kind: "allow_once"),
            (optionID: "allow-once", kind: "allow_once")
        ]
        XCTAssertEqual(
            ACPPermissionOptionPolicy.overseerOneTimeAllowOptionID(options: options, providerID: .grokBuild),
            "allow-once"
        )
    }

    func testMislabelledOrAbsentOneTimeAllowLeavesPromptManual() {
        XCTAssertNil(ACPPermissionOptionPolicy.overseerOneTimeAllowOptionID(
            options: [
                (optionID: "enable-always-approve", kind: "allow_once"),
                (optionID: "allow-edits-session", kind: "allow_once")
            ],
            providerID: .grokBuild
        ))
        XCTAssertNil(ACPPermissionOptionPolicy.overseerOneTimeAllowOptionID(
            options: [(optionID: "always", kind: "allow_always")],
            providerID: .cursor
        ))
        XCTAssertNil(ACPPermissionOptionPolicy.overseerOneTimeAllowOptionID(
            options: [(optionID: "reject-once", kind: "reject_once")],
            providerID: .openCode
        ))
    }

    func testProviderSpecificOptionCanUseAllowOnceKindWithoutBroadeningID() {
        XCTAssertEqual(ACPPermissionOptionPolicy.overseerOneTimeAllowOptionID(
            options: [(optionID: "approve", kind: "allow_once")],
            providerID: .openCode
        ), "approve")
    }
}
