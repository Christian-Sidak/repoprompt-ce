@testable import RepoPromptApp
import XCTest

/// M8E: the MCP tools/call routing snapshot reads a nonisolated window-count mirror instead of
/// hopping to the MainActor.
final class WindowRoutingCountMirrorTests: XCTestCase {
    func testSnapshotReflectsLastPublishedCountAndMultiWindowMode() {
        let mirror = WindowRoutingCountMirror()
        XCTAssertEqual(mirror.snapshot().count, 0)
        XCTAssertFalse(mirror.snapshot().isMultiWindowActive)

        mirror.publish(count: 1)
        XCTAssertEqual(mirror.snapshot().count, 1)
        XCTAssertFalse(mirror.snapshot().isMultiWindowActive)

        mirror.publish(count: 2)
        XCTAssertEqual(mirror.snapshot().count, 2)
        XCTAssertTrue(mirror.snapshot().isMultiWindowActive)

        mirror.publish(count: 1)
        XCTAssertFalse(mirror.snapshot().isMultiWindowActive)
    }

    func testSnapshotIsReadableConcurrentlyWithoutTheMainActor() async {
        let mirror = WindowRoutingCountMirror()
        mirror.publish(count: 3)
        let counts = await withTaskGroup(of: Int.self) { group in
            for _ in 0 ..< 16 {
                group.addTask { mirror.snapshot().count }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(counts, Array(repeating: 3, count: 16))
    }
}
