import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

#if DEBUG
    /// M8U/M8V: a root whose code-map graph can no longer be built without a reload must not be
    /// reported to MCP clients as a retryable pending index. The structure query's no-graph answer
    /// shares root status's unavailable reason: exhausted build retries, exhausted worker recovery,
    /// terminal non-Git, a bare repository, and an invalid Git layout are unavailable and not
    /// retryable (the Git-layout answers stay distinct from non-Git); a graph still being retried stays
    /// pending and retryable. A Git-layout terminal answer is sticky for the root epoch and cleared
    /// only by reloading the root.
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

        func testBareRepositoryIsTerminalAndDistinctFromNonGit() async throws {
            try await assertGitLayoutTerminal(
                eligibility: .terminalUnavailable(.bareRepository),
                reason: .bareRepository,
                code: "git_bare_repository",
                textFragments: ["bare Git repository", "Open a checkout"]
            )
        }

        func testInvalidGitLayoutIsTerminalAndDistinctFromNonGit() async throws {
            try await assertGitLayoutTerminal(
                eligibility: .terminalUnavailable(.invalidLayout),
                reason: .invalidGitLayout,
                code: "git_layout_invalid",
                textFragments: ["Git cannot resolve", "Repair the root", "then reload the workspace root"]
            )
        }

        func testGitLayoutTerminalAnswerIsStickyForTheEpochAndClearedByReload() async throws {
            let harness = try await makeHarness(
                eligibility: .terminalUnavailable(.bareRepository),
                retryPolicy: Self.policy(maximumRetryCount: 3, sleepsForever: true)
            )
            let rootEpoch = try await waitForRootStatus(harness) { $0.unavailableReason == .bareRepository }.rootEpoch

            // Even with eligibility now reporting only a transient condition, re-prioritizing in the
            // same root epoch starts a fresh launch that replays the sticky Git-terminal setup
            // disposition (it finishes `superseded` without recovering), so the answer must stay
            // terminal rather than flip to a retryable pending index.
            harness.answer.value = .transientUnavailable(.permissionFailure)
            _ = await harness.store.prioritizeCodemapGraphIndexNow(rootID: harness.rootID)
            try await waitForSupersededLaunchAfterPrioritize(harness)
            let phaseAfterPrioritize = await harness.store.codemapGraphIndexBuildLaunchPhaseForTesting(rootEpoch: rootEpoch)
            XCTAssertEqual(phaseAfterPrioritize, .superseded)
            let sameEpoch = try await query(harness)
            XCTAssertEqual(sameEpoch.roots.first?.status, .unavailable)
            XCTAssertEqual(sameEpoch.roots.first?.issues.first?.code, "git_bare_repository")
            try await waitForRootStatus(harness) { $0.unavailableReason == .bareRepository }

            // Reloading the root starts a new epoch that re-runs eligibility from scratch.
            let reloaded = try await reload(harness)
            try await waitForRootStatus(reloaded) { $0.availability == .indexing && $0.unavailableReason == nil }
            let fresh = try await query(reloaded)
            let root = try XCTUnwrap(fresh.roots.first)
            XCTAssertEqual(root.status, .pending)
            XCTAssertEqual(root.issues.first?.code, "graph_indexing")
            XCTAssertEqual(root.issues.first?.retryable, true)
        }

        func testEligibilityTransientReasonIsRecordedOnRetryAndExhaustion() async throws {
            let harness = try await makeHarness(
                eligibility: .transientUnavailable(.repositoryChanging),
                retryPolicy: Self.policy(maximumRetryCount: 1)
            )
            try await waitForRootStatus(harness) { $0.unavailableReason == .retryExhausted }

            let events = await harness.store.codemapGraphIndexBuildStoreEventsForTesting(rootID: harness.rootID)
            let label = "eligibility.repositoryChanging"
            // Another root-ready trigger may start a fresh launch, so counts can vary; every label must
            // name the eligibility cause, a retry must have been scheduled, and exhaustion is labelled.
            let transient = events.filter { $0.kind == .eligibilityTransient }.map(\.transientReason)
            let scheduled = events.filter { $0.kind == .retryScheduled }.map(\.transientReason)
            XCTAssertGreaterThanOrEqual(transient.count, 2)
            XCTAssertTrue(transient.allSatisfy { $0 == label }, "\(transient)")
            XCTAssertFalse(scheduled.isEmpty)
            XCTAssertTrue(scheduled.allSatisfy { $0 == label }, "\(scheduled)")
            XCTAssertEqual(events.filter { $0.kind == .retryExhausted }.map(\.transientReason), [label])
            assertPrivacySafe(events, harness)
        }

        func testRetryableSetupReasonIsRecordedOnExhaustion() async throws {
            let harness = try await makeHarness(
                eligibility: .eligible,
                retryPolicy: Self.policy(maximumRetryCount: 0),
                runtimeFails: true
            )
            try await waitForRootStatus(harness) { $0.unavailableReason == .retryExhausted }

            let events = await harness.store.codemapGraphIndexBuildStoreEventsForTesting(rootID: harness.rootID)
            XCTAssertTrue(events.contains { $0.kind == .eligibilityEligible })
            XCTAssertFalse(events.contains { $0.kind == .eligibilityTransient }, "the failure is in setup, not eligibility")
            XCTAssertEqual(events.filter { $0.kind == .retryExhausted }.map(\.transientReason), ["setup.runtimeFailure"])
            assertPrivacySafe(events, harness)
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
            let rootURL: URL
            let answer: EligibilityAnswer
        }

        private func assertGitLayoutTerminal(
            eligibility: WorkspaceCodemapGitEligibilityPreflightResult,
            reason: WorkspaceCodemapRootStatusUnavailableReason,
            code: String,
            textFragments: [String],
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws {
            let harness = try await makeHarness(eligibility: eligibility, retryPolicy: Self.policy(maximumRetryCount: 3))
            try await waitForRootStatus(harness) { $0.availability == .unavailable && $0.unavailableReason == reason }

            let aggregate = try await query(harness)
            let root = try XCTUnwrap(aggregate.roots.first, file: file, line: line)
            XCTAssertEqual(root.status, .unavailable, file: file, line: line)
            XCTAssertFalse(root.updatesPending, file: file, line: line)
            XCTAssertEqual(root.seeds.map(\.state), [.notIndexed], file: file, line: line)
            let issue = try XCTUnwrap(root.issues.first, file: file, line: line)
            XCTAssertEqual(issue.code, code, file: file, line: line)
            XCTAssertNotEqual(issue.code, "git_root_unavailable", "must not look like an ordinary non-Git root", file: file, line: line)
            XCTAssertFalse(issue.retryable, file: file, line: line)
            XCTAssertNil(issue.retryAfterMilliseconds, file: file, line: line)

            let reply = Self.reply(aggregate)
            XCTAssertEqual(reply.status, .unavailable, file: file, line: line)
            XCTAssertNil(reply.retry, file: file, line: line)
            let text = try String(describing: ToolOutputFormatter.formatCodeStructure(value: Value(reply)))
            for fragment in textFragments {
                XCTAssertTrue(text.contains(fragment), "\(fragment) missing from: \(text)", file: file, line: line)
            }
            XCTAssertFalse(text.contains("Retry shortly"), text, file: file, line: line)
        }

        /// Transient-reason labels carry case names only: no path components.
        private func assertPrivacySafe(
            _ events: [WorkspaceFileContextStore.CodemapGraphIndexBuildStoreEvent],
            _ harness: Harness,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            for reason in events.compactMap(\.transientReason) {
                XCTAssertFalse(reason.contains("/"), reason, file: file, line: line)
                XCTAssertFalse(reason.contains(harness.rootURL.lastPathComponent), reason, file: file, line: line)
            }
        }

        /// Unloads and reloads the harness root (a new root epoch) in the same store.
        private func reload(_ harness: Harness) async throws -> Harness {
            await harness.store.unloadRoot(id: harness.rootID)
            let store = harness.store
            let loaded = try await store.loadRoot(path: harness.rootURL.path)
            addTeardownBlock { await store.unloadRoot(id: loaded.id) }
            let files = await store.files(inRoot: loaded.id)
            let seed = try XCTUnwrap(files.first { $0.standardizedRelativePath == "Sources/A.swift" })
            return Harness(store: store, rootID: loaded.id, seedFileID: seed.id, rootURL: harness.rootURL, answer: harness.answer)
        }

        /// Waits until a launch started after the latest `prioritizeNow` event has finished `superseded`.
        private func waitForSupersededLaunchAfterPrioritize(_ harness: Harness, timeout: Duration = .seconds(10)) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            var last: [WorkspaceFileContextStore.CodemapGraphIndexBuildStoreEvent] = []
            while clock.now < deadline {
                last = await harness.store.codemapGraphIndexBuildStoreEventsForTesting(rootID: harness.rootID)
                if let prioritized = last.lastIndex(where: { $0.kind == .prioritizeNow }),
                   last[(prioritized + 1)...].contains(where: { $0.launchPhase == .superseded })
                {
                    return
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("no superseded launch after prioritizeNow; events: \(last.map { "\($0.kind):\($0.launchPhase)" })")
            throw CancellationError()
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
            retryPolicy: WorkspaceFileContextStore.CodemapGraphIndexBuildRetryPolicy,
            runtimeFails: Bool = false
        ) async throws -> Harness {
            let rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("codemap-retry-exhaustion-\(UUID().uuidString)", isDirectory: true)
            let file = rootURL.appendingPathComponent("Sources/A.swift")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("struct A { func run() {} }\n".utf8).write(to: file)
            let runtime = try CodemapStoreFixture(name: "retry-exhaustion")
            let answer = EligibilityAnswer(eligibility)
            let store = WorkspaceFileContextStore(
                codemapRuntimeProvider: {
                    if runtimeFails { throw CocoaError(.featureUnsupported) }
                    return try runtime.runtime()
                },
                codemapLocalGitClassificationProbe: .init { _ in .requiresGitPreflight },
                codemapGitEligibilityProbe: .init { _ in answer.value },
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
            return Harness(store: store, rootID: loaded.id, seedFileID: seed.id, rootURL: rootURL, answer: answer)
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
            MCPCodeStructureReplyProjection.assemble(.init(
                aggregate: aggregate,
                presentation: nil,
                revalidation: [:],
                includesSignatures: false,
                budget: budget,
                size: .medium,
                worktreeScope: nil
            ))
        }
    }

    /// The injected eligibility probe's answer, changeable mid-test (lock-protected).
    private final class EligibilityAnswer: @unchecked Sendable {
        private let lock = NSLock()
        private var current: WorkspaceCodemapGitEligibilityPreflightResult

        init(_ initial: WorkspaceCodemapGitEligibilityPreflightResult) {
            current = initial
        }

        var value: WorkspaceCodemapGitEligibilityPreflightResult {
            get { lock.withLock { current } }
            set { lock.withLock { current = newValue } }
        }
    }
#endif
