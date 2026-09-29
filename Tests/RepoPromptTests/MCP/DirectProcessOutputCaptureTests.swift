import Foundation
@testable import RepoPromptMCP
import XCTest

final class DirectProcessOutputCaptureTests: XCTestCase {
    func testPipeReadStartsOnlyAfterAcquiringCaptureLock() {
        let mutex = NSLock()
        let attemptedLock = DispatchSemaphore(value: 0)
        let capture = DirectProcessOutputCapture(lock: ObservedLock(mutex: mutex) {
            attemptedLock.signal()
        })
        let state = ReadState()
        let completed = DispatchGroup()

        mutex.lock()
        completed.enter()
        DispatchQueue.global().async {
            capture.consume {
                state.recordRead()
                return Data("A".utf8)
            }
            completed.leave()
        }
        XCTAssertEqual(attemptedLock.wait(timeout: .now() + 5), .success)
        // Acquisition was attempted while we still own the mutex. The pipe must be untouched.
        XCTAssertEqual(state.readCount, 0)
        mutex.unlock()
        XCTAssertEqual(completed.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(capture.finish { Data() }.data, Data("A".utf8))
    }

    func testTerminalDrainWaitsForConsumedChunkToBeAccumulated() {
        let attemptedLock = DispatchSemaphore(value: 0)
        let capture = DirectProcessOutputCapture(lock: ObservedLock(mutex: NSLock()) {
            attemptedLock.signal()
        })
        let readStarted = DispatchSemaphore(value: 0)
        let releaseRead = DispatchSemaphore(value: 0)
        let completed = DispatchGroup()
        let state = ReadState()

        completed.enter()
        DispatchQueue.global().async {
            capture.consume {
                readStarted.signal()
                releaseRead.wait()
                return Data("A".utf8)
            }
            completed.leave()
        }
        XCTAssertEqual(attemptedLock.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(readStarted.wait(timeout: .now() + 5), .success)
        completed.enter()
        DispatchQueue.global().async {
            state.store(capture.finish { Data("B".utf8) })
            completed.leave()
        }
        // The finalizer has attempted the same mutex while the consumed chunk is held.
        XCTAssertEqual(attemptedLock.wait(timeout: .now() + 5), .success)
        releaseRead.signal()
        XCTAssertEqual(completed.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(state.snapshot?.data, Data("AB".utf8))
        XCTAssertEqual(state.snapshot?.truncated, false)
    }

    func testFinalizationSkipsLateReadersAndPreservesBoundedPrefix() {
        let capture = DirectProcessOutputCapture(limit: 4)
        capture.consume { Data("abc".utf8) }
        let snapshot = capture.finish { Data("def".utf8) }
        XCTAssertEqual(snapshot.data, Data("abcd".utf8))
        XCTAssertTrue(snapshot.truncated)
        capture.consume {
            XCTFail("A late callback must not consume the pipe after finalization")
            return Data("late".utf8)
        }
        XCTAssertEqual(capture.finish {
            XCTFail("Finalization must not drain the pipe twice")
            return Data()
        }, snapshot)

        let exact = DirectProcessOutputCapture(limit: 4)
        exact.consume { Data("abcd".utf8) }
        XCTAssertEqual(exact.finish { Data() }, .init(data: Data("abcd".utf8), truncated: false))
    }
}

private final class ObservedLock: NSLocking, @unchecked Sendable {
    private let mutex: NSLock
    private let onAttempt: @Sendable () -> Void

    init(mutex: NSLock, onAttempt: @escaping @Sendable () -> Void) {
        self.mutex = mutex
        self.onAttempt = onAttempt
    }

    func lock() {
        onAttempt()
        mutex.lock()
    }

    func unlock() {
        mutex.unlock()
    }
}

private final class ReadState: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var storedSnapshot: DirectProcessOutputCapture.Snapshot?

    var readCount: Int {
        lock.withLock { count }
    }

    var snapshot: DirectProcessOutputCapture.Snapshot? {
        lock.withLock { storedSnapshot }
    }

    func recordRead() {
        lock.withLock { count += 1 }
    }

    func store(_ snapshot: DirectProcessOutputCapture.Snapshot) {
        lock.withLock { storedSnapshot = snapshot }
    }
}

/// M21 follow-up: a spawned process is reported started exactly once, before its run settles,
/// whichever of the spawning thread and the termination handler reports it first.
final class DirectProcessSpawnReportTests: XCTestCase {
    func testAProcessThatExitsBeforeItsSpawnIsReportedIsReportedByItsTermination() async throws {
        let starts = SpawnReports()
        let reported = DispatchSemaphore(value: 0)
        let reportedBeforeSpawningThread = SpawnReports()
        // The spawning thread is held after the spawn until the start was reported elsewhere: only
        // the termination of the (immediately exiting) process can report it.
        _ = try await DirectProcess.run(
            "/usr/bin/true",
            arguments: [],
            didStart: {
                starts.record()
                reported.signal()
            },
            testHooks: DirectProcessTestHooks(afterSpawn: {
                if reported.wait(timeout: .now() + 10) == .success {
                    reportedBeforeSpawningThread.record()
                }
            })
        )
        XCTAssertEqual(reportedBeforeSpawningThread.count, 1, "the termination reported the spawn before the run settled")
        XCTAssertEqual(starts.count, 1, "the spawn is reported exactly once")
    }

    func testTerminationCannotSettleWhileTheClaimedSpawnReportHasNotCompleted() async throws {
        let events = OrderedEvents()
        let progressed = DispatchSemaphore(value: 0)
        // Contention on the start lock means the termination handler is waiting for the report.
        let startLock = ContentionSignallingLock { progressed.signal() }
        // The spawning thread claims the report long before the process exits (0.3 s), then pauses
        // precisely between the claim and the callback until the termination either waits for it
        // (contends for the start lock) or settles past it.
        _ = try await DirectProcess.run(
            "/bin/sleep",
            arguments: ["0.3"],
            didStart: { events.append("started") },
            testHooks: DirectProcessTestHooks(
                afterStartClaimed: {
                    _ = progressed.wait(timeout: .now() + 10)
                },
                beforeTerminationSettles: {
                    events.append("settling")
                    progressed.signal()
                },
                startLock: startLock
            )
        )
        XCTAssertEqual(events.values, ["started", "settling"], "the run settled before its spawn report completed")
    }

    func testAProcessReportsItsSpawnOnceWhenTheSpawningThreadReportsFirst() async throws {
        let starts = SpawnReports()
        _ = try await DirectProcess.run("/bin/sleep", arguments: ["0.2"], didStart: { starts.record() })
        XCTAssertEqual(starts.count, 1)
    }

    func testAProcessThatFailsToSpawnIsNeverReportedStarted() async {
        let starts = SpawnReports()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-direct-process-missing-\(UUID().uuidString)").path
        do {
            _ = try await DirectProcess.run(missing, arguments: [], didStart: { starts.record() })
            XCTFail("A missing executable must fail to spawn")
        } catch {}
        XCTAssertEqual(starts.count, 0)
    }
}

private final class OrderedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func append(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }
}

/// A lock that reports every acquisition attempt that has to wait for another holder.
private final class ContentionSignallingLock: NSLocking, @unchecked Sendable {
    private let mutex = NSLock()
    private let onContention: @Sendable () -> Void

    init(onContention: @escaping @Sendable () -> Void) {
        self.onContention = onContention
    }

    func lock() {
        if !mutex.try() {
            onContention()
            mutex.lock()
        }
    }

    func unlock() {
        mutex.unlock()
    }
}

private final class SpawnReports: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func record() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}
