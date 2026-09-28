import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    /// M8W: a graph-index job cancelled while it holds an admitted batch keeps its admission slot
    /// until its worker drains (the batch is non-preemptive). A replacement job queued for the same
    /// root meanwhile is ineligible (the draining batch counts against the per-root limit), so the
    /// drained worker's exit must re-run admission scheduling, or the replacement waits forever.
    final class WorkspaceCodemapGraphIndexAdmissionTests: XCTestCase {
        func testReplacementJobIsAdmittedAfterCancelledActiveJobDrains() async throws {
            let repository = try ReviewGitRepositoryFixture(name: #function)
            let rootURL = try repository.makeRepository(
                named: "root",
                files: [
                    "Sources/A.swift": "struct A { func run() {} }\n",
                    "Sources/B.swift": "struct B { let a = A() }\n"
                ]
            )
            let fixture = try CodemapStoreFixture(name: #function)
            let store = fixture.makeStore()
            // Holds whichever job first builds the catalog shard inside its admitted batch.
            let gate = CodemapGraphIndexGate()
            await gate.close()
            let catalogBuilds = CodemapLockedValues<WorkspaceCodemapRootEpoch>()
            await store.setCodemapGraphIndexCatalogBuildHandlerForTesting { rootEpoch in
                catalogBuilds.append(rootEpoch)
                await gate.pass()
            }
            addTeardownBlock {
                await gate.open()
                await store.setCodemapGraphIndexCatalogBuildHandlerForTesting(nil)
                await fixture.shutdown()
                repository.cleanup()
            }

            let loaded = try await store.loadRoot(path: rootURL.path)
            addTeardownBlock { await store.unloadRoot(id: loaded.id) }
            let engine = try fixture.runtime().bindingEngine()

            // Job A is admitted and blocked inside its batch (catalog shard build).
            let admitted = try await waitForRoot(engine: engine, rootID: loaded.id) { root in
                root.activeBatchCount == 1 && !catalogBuilds.values.isEmpty
            }
            let firstJobID = admitted.jobID
            let rootEpoch = admitted.rootEpoch

            // Cancel A while its batch is admitted, then schedule a replacement for the same root.
            await engine.cancelGraphIndex(rootEpoch: rootEpoch)
            _ = await engine.scheduleGraphIndex(rootEpoch: rootEpoch)
            let queued = try await waitForRoot(engine: engine, rootID: loaded.id) { root in
                root.jobID != firstJobID && root.isQueuedForAdmission && root.drainingBatchCount == 1
            }
            XCTAssertEqual(queued.phase, .waitingForAdmission, "the draining batch must block the replacement")

            // A drains: its batch ends and its worker exits after the job was replaced. That exit
            // must re-run admission so the now-eligible replacement is admitted and completes.
            await gate.open()
            let completed = try await waitForRoot(engine: engine, rootID: loaded.id, timeout: .seconds(20)) { root in
                root.jobID == queued.jobID && root.phase == .complete
            }
            XCTAssertEqual(completed.drainingBatchCount, 0)
            XCTAssertGreaterThan(completed.progress.counts.processedCandidateCount, 0)
        }

        // MARK: - Helpers

        private func waitForRoot(
            engine: WorkspaceCodemapBindingEngine,
            rootID: UUID,
            timeout: Duration = .seconds(10),
            _ predicate: (WorkspaceCodemapBindingEngineGraphIndexRootAccounting) -> Bool
        ) async throws -> WorkspaceCodemapBindingEngineGraphIndexRootAccounting {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            var last: WorkspaceCodemapBindingEngineGraphIndexRootAccounting?
            while clock.now < deadline {
                let accounting = await engine.accounting()
                last = accounting.graphIndexRoots.first { $0.rootEpoch.rootID == rootID }
                if let last, predicate(last) { return last }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail(
                "graph-index root did not reach the expected state; last: phase=\(String(describing: last?.phase))"
                    + " queued=\(String(describing: last?.isQueuedForAdmission))"
                    + " active=\(String(describing: last?.activeBatchCount))"
                    + " draining=\(String(describing: last?.drainingBatchCount))"
            )
            throw CancellationError()
        }
    }
#endif
