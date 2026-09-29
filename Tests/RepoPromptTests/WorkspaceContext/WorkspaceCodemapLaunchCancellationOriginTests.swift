import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    /// M8Z: every store path that detaches a root's code-map session or cancels its graph-index launch
    /// records a privacy-safe origin, so a relaunch seen in a parity run can be attributed to its
    /// initiator. The parity fixture reads a Git-ignored file right after activation; materializing it
    /// takes a root-wide `catalogAdvanced` authority fence, which detaches the root's in-flight graph
    /// launch and relaunches it. This pins that initiator and its label.
    @MainActor
    final class WorkspaceCodemapLaunchCancellationOriginTests: XCTestCase {
        func testMaterializingAnIgnoredFileDetachesTheRootGraphLaunchWithItsOrigin() async throws {
            let rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("codemap-cancellation-origin-\(UUID().uuidString)", isDirectory: true)
            try write("*.log\n", to: rootURL.appendingPathComponent(".gitignore"))
            try write("struct A { func run() {} }\n", to: rootURL.appendingPathComponent("Sources/A.swift"))
            try write("log line\n", to: rootURL.appendingPathComponent("Sources/debug.log"))
            let runtime = try CodemapStoreFixture(name: "cancellation-origin")
            // A transient eligibility answer with a retry that never fires keeps the launch alive in
            // `transientRetry`, so the fence finds a launch to detach regardless of timing. The root is
            // a plain folder, so the non-Git Code Maps opt-in (#994) must be on for it to launch at all.
            let store = WorkspaceFileContextStore(
                codemapRuntimeProvider: { try runtime.runtime() },
                codemapLocalGitClassificationProbe: .init { _ in .requiresGitPreflight },
                codemapGitEligibilityProbe: .init { _ in .transientUnavailable(.permissionFailure) },
                codemapGraphIndexBuildRetryPolicy: WorkspaceFileContextStore.CodemapGraphIndexBuildRetryPolicy(
                    maximumRetryCount: 3,
                    initialBackoffNanoseconds: 0,
                    maximumBackoffNanoseconds: 0,
                    nowNanoseconds: { DispatchTime.now().uptimeNanoseconds },
                    sleep: { _ in try await Task.sleep(for: .seconds(3600)) }
                ),
                nonGitCodeMapsEnabled: true
            )
            let loaded = try await store.loadRoot(path: rootURL.path)
            addTeardownBlock {
                await store.unloadRoot(id: loaded.id)
                await runtime.shutdown()
                try? FileManager.default.removeItem(at: rootURL)
            }
            let files = await store.files(inRoot: loaded.id)
            XCTAssertFalse(files.contains { $0.standardizedRelativePath == "Sources/debug.log" }, "the log is ignored")
            try await waitForEvent(store, rootID: loaded.id) { $0.kind == .retryScheduled }
            let before = await store.codemapGraphIndexBuildStoreEventsForTesting(rootID: loaded.id)
            let lastOrdinal = before.last?.ordinal ?? 0

            let materialization = try await store.materializeExplicitlyRequestedFile(
                rootURL.appendingPathComponent("Sources/debug.log").path,
                rootScope: .visibleWorkspace
            )
            guard case .materialized = materialization else {
                return XCTFail("the ignored file materializes as a managed-only record, got \(materialization)")
            }

            let after = await store.codemapGraphIndexBuildStoreEventsForTesting(rootID: loaded.id)
                .filter { $0.ordinal > lastOrdinal }
            let origin = "rootAuthorityFence.explicitMaterialization.catalogAdvanced"
            XCTAssertTrue(
                after.contains { $0.kind == .cancelled && $0.origin == origin },
                "the in-flight launch is cancelled by the materialization fence: \(Self.describe(after))"
            )
            XCTAssertTrue(
                after.contains { $0.kind == .sessionDetached && $0.origin == origin },
                "the root's code-map state is detached by the materialization fence: \(Self.describe(after))"
            )
            for label in after.compactMap(\.origin) {
                XCTAssertFalse(label.contains("/"), "origins carry case names only: \(label)")
                XCTAssertFalse(label.contains(rootURL.lastPathComponent), "origins never carry paths: \(label)")
            }
            try await waitForEvent(store, rootID: loaded.id, after: lastOrdinal) { $0.kind == .scheduled }
        }

        // MARK: - Helpers

        private func write(_ text: String, to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        private func waitForEvent(
            _ store: WorkspaceFileContextStore,
            rootID: UUID,
            after ordinal: UInt64 = 0,
            timeout: Duration = .seconds(10),
            _ predicate: (WorkspaceFileContextStore.CodemapGraphIndexBuildStoreEvent) -> Bool
        ) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            var last: [WorkspaceFileContextStore.CodemapGraphIndexBuildStoreEvent] = []
            while clock.now < deadline {
                last = await store.codemapGraphIndexBuildStoreEventsForTesting(rootID: rootID)
                if last.contains(where: { $0.ordinal > ordinal && predicate($0) }) { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("expected launch event did not occur; events: \(Self.describe(last))")
            throw CancellationError()
        }

        private static func describe(_ events: [WorkspaceFileContextStore.CodemapGraphIndexBuildStoreEvent]) -> String {
            events.map { "\($0.kind):\($0.launchPhase)" + ($0.origin.map { ":\($0)" } ?? "") }.joined(separator: ">")
        }
    }
#endif
