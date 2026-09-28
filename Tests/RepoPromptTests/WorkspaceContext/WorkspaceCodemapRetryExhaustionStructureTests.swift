import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

#if DEBUG
    /// M8U: a root whose code-map graph can no longer be built without a reload must not be reported
    /// to MCP clients as a retryable pending index. The structure query's no-graph answer shares root
    /// status's unavailable reason: exhausted build retries, exhausted worker recovery, and terminal
    /// non-Git are unavailable and not retryable; a graph still being retried stays pending and
    /// retryable.
    @MainActor
    final class WorkspaceCodemapRetryExhaustionStructureTests: XCTestCase {
        func testExhaustedGraphBuildRetriesAreUnavailableAndNotRetryable() async throws {
            let harness = try await makeHarness(
                eligibility: .transientUnavailable(.permissionFailure),
                retryPolicy: Self.policy(maximumRetryCount: 0)
            )
            try await waitForRootStatus(harness) { $0.availability == .unavailable && $0.unavailableReason == .retryExhausted }

            let aggregate = try await query(harness)
            let root = try XCTUnwrap(aggregate.roots.first)
            XCTAssertEqual(root.status, .unavailable)
            XCTAssertFalse(root.updatesPending)
            XCTAssertEqual(root.seeds.map(\.state), [.notIndexed])
            let issue = try XCTUnwrap(root.issues.first)
            XCTAssertEqual(issue.code, "graph_retry_exhausted")
            XCTAssertFalse(issue.retryable)
            XCTAssertNil(issue.retryAfterMilliseconds)

            let reply = Self.reply(aggregate)
            XCTAssertEqual(reply.status, .unavailable)
            XCTAssertNil(reply.retry, "an exhausted root must not carry retry guidance")
            let text = try String(describing: ToolOutputFormatter.formatCodeStructure(value: Value(reply)))
            XCTAssertTrue(text.contains("unavailable"), text)
            XCTAssertTrue(text.contains("Reload the workspace root"), text)
            XCTAssertFalse(text.contains("Retry shortly"), text)
        }

        func testActiveTransientRetryStaysPendingAndRetryable() async throws {
            let harness = try await makeHarness(
                eligibility: .transientUnavailable(.permissionFailure),
                retryPolicy: Self.policy(maximumRetryCount: 3, sleepsForever: true)
            )
            let rootEpoch = try await waitForRootStatus(harness) { $0.availability == .indexing }.rootEpoch
            let phase = await harness.store.codemapGraphIndexBuildLaunchPhaseForTesting(rootEpoch: rootEpoch)
            XCTAssertEqual(phase, .transientRetry)

            let active = try await query(harness)
            let root = try XCTUnwrap(active.roots.first)
            XCTAssertEqual(root.status, .pending)
            XCTAssertTrue(root.updatesPending)
            XCTAssertEqual(root.issues.first?.code, "graph_indexing")
            XCTAssertEqual(root.issues.first?.retryable, true)
            XCTAssertEqual(root.issues.first?.retryAfterMilliseconds, 100)
            let reply = try await Self.reply(query(harness))
            XCTAssertEqual(reply.status, .pending)
            XCTAssertEqual(reply.retry?.retryable, true)
        }

        func testExhaustedWorkerRecoveryIsUnavailableAndRecoversWhenCleared() async throws {
            let harness = try await makeHarness(
                eligibility: .transientUnavailable(.permissionFailure),
                retryPolicy: Self.policy(maximumRetryCount: 3, sleepsForever: true)
            )
            _ = try await waitForRootStatus(harness) { $0.availability == .indexing }

            let exhausted = await harness.store.debugSetCodemapGraphIndexWorkerRecoveryStateForTesting(
                rootID: harness.rootID,
                state: .exhausted
            )
            XCTAssertTrue(exhausted)
            let exhaustedAnswer = try await query(harness)
            let unavailable = try XCTUnwrap(exhaustedAnswer.roots.first)
            XCTAssertEqual(unavailable.status, .unavailable)
            XCTAssertEqual(unavailable.issues.first?.code, "graph_worker_recovery_exhausted")
            XCTAssertEqual(unavailable.issues.first?.retryable, false)

            _ = await harness.store.debugSetCodemapGraphIndexWorkerRecoveryStateForTesting(
                rootID: harness.rootID,
                state: .available
            )
            let clearedAnswer = try await query(harness)
            let pending = try XCTUnwrap(clearedAnswer.roots.first)
            XCTAssertEqual(pending.status, .pending, "clearing exhaustion restores the retryable pending answer")
            XCTAssertEqual(pending.issues.first?.code, "graph_indexing")
        }

        func testNonGitEligibilityWithoutLocalProofIsUnavailable() async throws {
            let harness = try await makeHarness(
                eligibility: .terminalUnavailable(.nonGit),
                retryPolicy: Self.policy(maximumRetryCount: 3)
            )
            try await waitForRootStatus(harness) { $0.unavailableReason == .notGitRepository }

            let nonGitAnswer = try await query(harness)
            let root = try XCTUnwrap(nonGitAnswer.roots.first)
            XCTAssertEqual(root.status, .unavailable)
            XCTAssertEqual(root.issues.first?.code, "git_root_unavailable")
            XCTAssertEqual(root.issues.first?.retryable, false)
            let reply = try await Self.reply(query(harness))
            XCTAssertNil(reply.retry)
        }

        // MARK: - Helpers

        private struct Harness {
            let store: WorkspaceFileContextStore
            let rootID: UUID
            let seedFileID: UUID
        }

        private static let budget = WorkspaceCodemapGraphQueryBudget(
            maximumTokenCount: 10000,
            maximumNodeCount: 100,
            maximumEdgeCount: 100,
            maximumGraphByteCount: 1_000_000,
            graphEvidenceTokenCount: 10000,
            renderTokenCount: 0
        )

        private static func policy(
            maximumRetryCount: Int,
            sleepsForever: Bool = false
        ) -> WorkspaceFileContextStore.CodemapGraphIndexBuildRetryPolicy {
            WorkspaceFileContextStore.CodemapGraphIndexBuildRetryPolicy(
                maximumRetryCount: maximumRetryCount,
                initialBackoffNanoseconds: 0,
                maximumBackoffNanoseconds: 0,
                nowNanoseconds: { DispatchTime.now().uptimeNanoseconds },
                sleep: { _ in
                    // An active retry that never fires keeps the launch in `transientRetry`.
                    if sleepsForever { try await Task.sleep(for: .seconds(3600)) }
                }
            )
        }

        /// A loaded root whose Git classification requires preflight and whose eligibility probe
        /// answers `eligibility`, with an isolated code-map runtime (no process-wide artifact state).
        private func makeHarness(
            eligibility: WorkspaceCodemapGitEligibilityPreflightResult,
            retryPolicy: WorkspaceFileContextStore.CodemapGraphIndexBuildRetryPolicy
        ) async throws -> Harness {
            let rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("codemap-retry-exhaustion-\(UUID().uuidString)", isDirectory: true)
            let file = rootURL.appendingPathComponent("Sources/A.swift")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("struct A { func run() {} }\n".utf8).write(to: file)
            let runtime = try CodemapStoreFixture(name: "retry-exhaustion")
            let store = WorkspaceFileContextStore(
                codemapRuntimeProvider: { try runtime.runtime() },
                codemapLocalGitClassificationProbe: .init { _ in .requiresGitPreflight },
                codemapGitEligibilityProbe: .init { _ in eligibility },
                codemapGraphIndexBuildRetryPolicy: retryPolicy
            )
            let loaded = try await store.loadRoot(path: rootURL.path)
            addTeardownBlock {
                await store.unloadRoot(id: loaded.id)
                await runtime.shutdown()
                try? FileManager.default.removeItem(at: rootURL)
            }
            let files = await store.files(inRoot: loaded.id)
            let seed = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/A.swift" })
            return Harness(store: store, rootID: loaded.id, seedFileID: seed.id)
        }

        @discardableResult
        private func waitForRootStatus(
            _ harness: Harness,
            timeout: Duration = .seconds(10),
            _ predicate: (WorkspaceCodemapRootStatusSnapshot) -> Bool
        ) async throws -> WorkspaceCodemapRootStatusSnapshot {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            var last: WorkspaceCodemapRootStatusSnapshot?
            while clock.now < deadline {
                let status = await harness.store.currentCodemapRootStatusUpdate()
                last = status.roots.first { $0.rootEpoch.rootID == harness.rootID }
                if let last, predicate(last) { return last }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("root status did not reach the expected state; last: \(String(describing: last))")
            throw CancellationError()
        }

        private func query(_ harness: Harness) async throws -> WorkspaceCodemapStructureAggregateResult {
            try await harness.store.queryCodemapStructureGraphs(
                seedFileIDs: [harness.seedFileID],
                direction: nil,
                maximumDepth: 1,
                budget: Self.budget,
                rootScope: .visibleWorkspace
            )
        }

        private static func reply(_ aggregate: WorkspaceCodemapStructureAggregateResult) -> ToolResultDTOs.CodeStructureReplyDTO {
            MCPServerViewModel.codeStructureReplyDTO(
                aggregate: aggregate,
                presentation: nil,
                revalidation: [:],
                includesSignatures: false,
                budget: budget,
                size: .medium,
                worktreeScope: nil
            )
        }
    }
#endif
