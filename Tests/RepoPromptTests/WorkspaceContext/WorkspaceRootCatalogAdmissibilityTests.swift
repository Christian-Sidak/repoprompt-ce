@testable import RepoPromptApp
import XCTest

final class WorkspaceRootCatalogAdmissibilityTests: XCTestCase {
    func testCatalogAdmissionPrecedesSearchAdmissionOnlyAfterCatalogCompletion() {
        let workspaceID = UUID()
        let diagnostics = WorkspaceCatalogDiagnostics(
            generation: 1,
            rootScope: .visibleWorkspace,
            rootCount: 1,
            folderCount: 0,
            fileCount: 0
        )
        let cases: [(WorkspaceSearchReadinessState, Bool, Bool)] = [
            (.idle, false, false),
            (.activating(workspaceID: workspaceID, generation: 1), false, false),
            (.loadingCatalog(
                workspaceID: workspaceID,
                generation: 1,
                loadedRootCount: 0,
                expectedRootCount: 1,
                failures: []
            ), false, false),
            (.buildingIndexes(
                workspaceID: workspaceID,
                generation: 1,
                catalogGeneration: 1,
                failures: []
            ), true, false),
            (.ready(
                workspaceID: workspaceID,
                generation: 1,
                catalogGeneration: 1,
                indexedGeneration: 1,
                diagnostics: diagnostics
            ), true, true),
            (.degraded(
                workspaceID: workspaceID,
                generation: 1,
                catalogGeneration: 1,
                indexedGeneration: nil,
                failures: [],
                diagnostics: diagnostics
            ), true, true),
            (.degraded(
                workspaceID: workspaceID,
                generation: 1,
                catalogGeneration: nil,
                indexedGeneration: nil,
                failures: [],
                diagnostics: nil
            ), false, true)
        ]

        for (state, expectedCatalog, expectedSearch) in cases {
            XCTAssertEqual(state.isRootCatalogAdmissible, expectedCatalog, "state: \(state)")
            XCTAssertEqual(state.isSearchAdmissible, expectedSearch, "state: \(state)")
        }
    }
}

final class WorkspaceContextRootSnapshotTests: XCTestCase {
    func testSnapshotIsSendableRootScopedAndFencedByRootChanges() async throws {
        let firstURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let secondURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: firstURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }

        let store = WorkspaceFileContextStore()
        let first = try await store.loadRoot(path: firstURL.path)
        let firstSnapshot = await store.rootContextSnapshot(scope: .visibleWorkspace)
        let captured = try XCTUnwrap(firstSnapshot)
        assertSendable(captured)
        XCTAssertEqual(captured.rootRefs.map(\.id), [first.id])
        let capturedIsCurrent = await store.isRootContextSnapshotCurrent(captured)
        XCTAssertTrue(capturedIsCurrent)

        let second = try await store.loadRoot(path: secondURL.path)
        let secondSnapshot = await store.rootContextSnapshot(scope: .visibleWorkspace)
        let updated = try XCTUnwrap(secondSnapshot)
        XCTAssertEqual(Set(updated.rootRefs.map(\.id)), Set([first.id, second.id]))
        XCTAssertEqual(captured.rootRefs.map(\.id), [first.id])
        let oldIsCurrent = await store.isRootContextSnapshotCurrent(captured)
        let updatedIsCurrent = await store.isRootContextSnapshotCurrent(updated)
        XCTAssertFalse(oldIsCurrent)
        XCTAssertTrue(updatedIsCurrent)

        await store.unloadRoot(id: second.id)
        let unloadedIsCurrent = await store.isRootContextSnapshotCurrent(updated)
        XCTAssertFalse(unloadedIsCurrent)
    }

    private func assertSendable(_: some Sendable) {}
}
