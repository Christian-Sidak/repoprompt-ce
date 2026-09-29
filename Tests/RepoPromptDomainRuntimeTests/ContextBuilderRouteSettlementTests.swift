import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

/// Deterministic contract for the shared Context Builder route/stream settlement core.
///
/// Every race scenario runs twice, once on the main actor (the app's isolation) and once on a
/// private actor (a headless host), and must produce the same settlement, outcome, and ordered
/// host trace on both.
final class ContextBuilderRouteSettlementTests: XCTestCase {
    // MARK: - Descriptor and buffer accounting

    func testDescriptorClassifiesProviderEventTypesAndCountsEveryCharacter() {
        let content = ContextBuilderPreRouteEventDescriptor(type: "content", text: "hé👍🏽", additionalPayloads: ["ab", nil])
        XCTAssertEqual(content.kind, .content(isEmpty: false))
        XCTAssertEqual(content.payloadCharacterCount, "content".count + 3 + 2)

        XCTAssertEqual(
            ContextBuilderPreRouteEventDescriptor(type: "content", text: nil, additionalPayloads: []).kind,
            .content(isEmpty: true)
        )
        XCTAssertEqual(
            ContextBuilderPreRouteEventDescriptor(type: "content", text: "", additionalPayloads: []).kind,
            .content(isEmpty: true)
        )
        for progress in ["lifecycle", "event", "status"] {
            XCTAssertEqual(
                ContextBuilderPreRouteEventDescriptor(type: progress, text: "x", additionalPayloads: []).kind,
                .progress
            )
        }
        for protected in ["tool_call", "tool_result", "error", "final_content", "message_stop", "transport_activity"] {
            XCTAssertEqual(
                ContextBuilderPreRouteEventDescriptor(type: protected, text: nil, additionalPayloads: []).kind,
                .protected
            )
        }
    }

    func testLimitsClampNegativeValuesToZero() {
        let limits = ContextBuilderPreRouteBufferLimits(maxBufferedTextCharacters: -5, maxBufferedEventCount: -1)
        XCTAssertEqual(limits.maxBufferedTextCharacters, 0)
        XCTAssertEqual(limits.maxBufferedEventCount, 0)

        var buffer = ContextBuilderPreRouteEventBuffer<String>(limits: limits)
        buffer.append("a", descriptor: Self.descriptor("tool_call", "a"))
        let drained = buffer.drain()
        XCTAssertEqual(drained.events, [])
        XCTAssertEqual(drained.droppedEventCount, 1)
        XCTAssertEqual(drained.droppedTextCharacterCount, "tool_call".count + 1)
    }

    func testProgressCoalescesPerTypeAndCountsTheReplacedEventAsDropped() {
        var buffer = ContextBuilderPreRouteEventBuffer<String>(limits: .init(maxBufferedTextCharacters: 1000, maxBufferedEventCount: 100))
        buffer.append("status-1", descriptor: Self.descriptor("status", "1"))
        buffer.append("lifecycle-1", descriptor: Self.descriptor("lifecycle", "1"))
        buffer.append("content-1", descriptor: Self.descriptor("content", "c"))
        buffer.append("status-2", descriptor: Self.descriptor("status", "22"))

        let drained = buffer.drain()
        XCTAssertEqual(drained.events, ["lifecycle-1", "content-1", "status-2"])
        XCTAssertEqual(drained.droppedEventCount, 1)
        XCTAssertEqual(drained.droppedTextCharacterCount, "status".count + 1)
        XCTAssertEqual(buffer.bufferedEventCount, 0)

        let empty = buffer.drain()
        XCTAssertEqual(empty.droppedEventCount, 0)
        XCTAssertNil(empty.droppedSummary)
    }

    func testPayloadBoundEvictsContentBeforeProgressBeforeOldestProtected() {
        var buffer = ContextBuilderPreRouteEventBuffer<String>(limits: .init(maxBufferedTextCharacters: 30, maxBufferedEventCount: 100))
        buffer.append("tool", descriptor: Self.descriptor("tool_call", "t"))
        buffer.append("status", descriptor: Self.descriptor("status", "s"))
        buffer.append("content", descriptor: Self.descriptor("content", "c"))
        XCTAssertEqual(buffer.bufferedTextCharacterCount, 10 + 7 + 8)

        // 25 + 6: the content event goes first even though it is the newest ordinary event.
        buffer.append("error", descriptor: Self.descriptor("error", "e"))
        XCTAssertEqual(buffer.bufferedDescriptors.map(\.type), ["tool_call", "status", "error"])

        // An oversized protected event evicts progress, then the oldest protected event.
        buffer.append("result", descriptor: Self.descriptor("tool_result", String(repeating: "r", count: 14)))
        let drained = buffer.drain()
        XCTAssertEqual(drained.events, ["result"])
        XCTAssertEqual(drained.droppedEventCount, 4)
        XCTAssertEqual(drained.droppedTextCharacterCount, 8 + 7 + 10 + 6)
        XCTAssertEqual(
            drained.droppedSummary,
            "Dropped 31 characters of early provider payload and 4 early provider events while waiting for MCP routing."
        )
    }

    func testCountBoundEvictsRedundantBeforeContentBeforeOldestProtected() {
        var buffer = ContextBuilderPreRouteEventBuffer<String>(limits: .init(maxBufferedTextCharacters: 1000, maxBufferedEventCount: 3))
        buffer.append("tool-1", descriptor: Self.descriptor("tool_call", "1"))
        buffer.append("content-a", descriptor: Self.descriptor("content", "a"))
        buffer.append("empty", descriptor: Self.descriptor("content", ""))
        buffer.append("tool-2", descriptor: Self.descriptor("tool_call", "2"))
        XCTAssertEqual(buffer.bufferedDescriptors.map(\.type), ["tool_call", "content", "tool_call"])

        buffer.append("tool-3", descriptor: Self.descriptor("tool_call", "3"))
        buffer.append("tool-4", descriptor: Self.descriptor("tool_call", "4"))

        let drained = buffer.drain()
        XCTAssertEqual(drained.events, ["tool-2", "tool-3", "tool-4"])
        XCTAssertEqual(drained.droppedEventCount, 3)
        XCTAssertEqual(drained.droppedTextCharacterCount, 7 + 8 + 10)
    }

    // MARK: - Machine and policy

    func testMachineSettlesExactlyOnceAndDecidesEventsBySettlement() {
        var machine = ContextBuilderRouteSettlementMachine<String>(limits: .init(maxBufferedTextCharacters: 100, maxBufferedEventCount: 10))
        guard case .buffered = machine.admit("before", descriptor: Self.descriptor("content", "before")) else {
            return XCTFail("Pending events must be buffered")
        }
        XCTAssertTrue(machine.settle(.routed))
        XCTAssertFalse(machine.settle(.cancelled))
        XCTAssertEqual(machine.settlement, .routed)

        var descriptorEvaluations = 0
        guard case let .deliver(replay) = machine.admit("after", descriptor: {
            descriptorEvaluations += 1
            return Self.descriptor("content", "after")
        }()) else {
            return XCTFail("Routed events must be delivered after the buffered replay")
        }
        XCTAssertEqual(replay.events, ["before"])
        XCTAssertEqual(descriptorEvaluations, 0)
        guard case let .deliver(secondReplay) = machine.admit("later", descriptor: Self.descriptor("content", "later")) else {
            return XCTFail("Routed events must keep flowing")
        }
        XCTAssertEqual(secondReplay.events, [])

        for settlement in [ContextBuilderRouteSettlement.completedWithoutRoute, .failedWithoutRoute("x"), .routingOwnershipLost, .cancelled] {
            var settled = ContextBuilderRouteSettlementMachine<String>(limits: .init(maxBufferedTextCharacters: 100, maxBufferedEventCount: 10))
            _ = settled.admit("kept", descriptor: Self.descriptor("content", "kept"))
            settled.settle(settlement)
            guard case .rejected = settled.admit("late", descriptor: Self.descriptor("content", "late")) else {
                return XCTFail("\(settlement) must reject later events")
            }
            XCTAssertEqual(settled.drainBufferedEvents().events, ["kept"])
        }
    }

    func testPrecedenceTables() {
        typealias Policy = ContextBuilderRouteSettlementPolicy
        XCTAssertEqual(Policy.settlement(forRouteWait: .routed), .routed)
        XCTAssertEqual(Policy.settlement(forRouteWait: .ownershipLost), .routingOwnershipLost)
        XCTAssertEqual(Policy.settlement(forRouteWait: .cancelled), .cancelled)
        XCTAssertEqual(Policy.settlement(forRouteWait: .timedOutBeforeConnection), .routingOwnershipLost)
        XCTAssertEqual(Policy.settlement(forRouteWait: .timedOutAfterConnection), .routingOwnershipLost)

        XCTAssertEqual(Policy.completionStep(currentRoutingOutcome: .routed), .settle(.routed, streamOutcome: .completed))
        XCTAssertEqual(
            Policy.completionStep(currentRoutingOutcome: .ownershipLost),
            .settle(.routingOwnershipLost, streamOutcome: .completed)
        )
        XCTAssertEqual(Policy.completionStep(currentRoutingOutcome: .cancelled), .settle(.cancelled, streamOutcome: .cancelled))
        XCTAssertEqual(Policy.completionStep(currentRoutingOutcome: .timedOutBeforeConnection), .resolveCompletionAuthority)
        XCTAssertEqual(Policy.completionStep(currentRoutingOutcome: .timedOutAfterConnection), .resolveCompletionAuthority)
        XCTAssertEqual(Policy.completionStep(currentRoutingOutcome: nil), .resolveCompletionAuthority)

        XCTAssertEqual(Policy.settlement(forCompletionAuthority: .committed), .routed)
        XCTAssertEqual(Policy.settlement(forCompletionAuthority: .revocationFenced), .completedWithoutRoute)

        typealias Plan = (cancelStream: Bool, cancelRoute: Bool, joinStream: Bool, joinRoute: Bool, replay: Bool)
        let expectations: [(ContextBuilderRouteSettlement, Plan, ContextBuilderRouteSettlementPolicy.Resolution.Outcome)] = [
            (.routed, (false, false, true, true, false), .streamOutcome),
            (.completedWithoutRoute, (false, true, false, true, true), .failed(.completedWithoutRoute)),
            (.failedWithoutRoute("boom"), (false, true, false, true, true), .failed(.provider("boom"))),
            (.routingOwnershipLost, (true, false, true, true, false), .failed(.routingOwnershipLost)),
            (.cancelled, (true, true, true, true, false), .cancelled)
        ]
        for (settlement, plan, outcome) in expectations {
            let resolution = Policy.resolution(for: settlement)
            XCTAssertEqual(resolution.cancelsStream, plan.cancelStream, "\(settlement)")
            XCTAssertEqual(resolution.cancelsRouteWait, plan.cancelRoute, "\(settlement)")
            XCTAssertEqual(resolution.joinsStream, plan.joinStream, "\(settlement)")
            XCTAssertEqual(resolution.joinsRouteWait, plan.joinRoute, "\(settlement)")
            XCTAssertEqual(resolution.replaysUnroutedEvents, plan.replay, "\(settlement)")
            XCTAssertEqual(resolution.outcome, outcome, "\(settlement)")
        }
    }

    // MARK: - Race scenarios (main actor and headless actor parity)

    func testRouteCommitReplaysBufferedEventsBeforeLaterEvents() async {
        await assertRaceParity(
            expected: .init(settlement: .routed, outcome: .completed),
            trace: [
                .disposed("content:a", accepted: true),
                .disposed("tool_call:t", accepted: true),
                .beganRoutedStream,
                .committedRoute(replayed: ["content:a", "tool_call:t"], droppedCharacters: 0, droppedEvents: 0),
                .published(["content:a", "tool_call:t"]),
                .delivered("content:c", replayed: [], droppedCharacters: 0, droppedEvents: 0),
                .published(["content:c"]),
                .disposed("content:c", accepted: true)
            ]
        ) { control in
            control.yield("content", "a")
            control.yield("tool_call", "t")
            await control.waitForTraceCount(2)
            await control.authority.resolveRoute(.routed)
            await control.waitForTraceCount(5)
            control.yield("content", "c")
            control.finish()
        }
    }

    func testCompletionFencedWithoutRouteReplaysUnroutedEvents() async {
        await assertRaceParity(
            expected: .init(settlement: .completedWithoutRoute, outcome: .failed(.completedWithoutRoute)),
            trace: [
                .disposed("content:a", accepted: true),
                .disposed("tool_call:t", accepted: true),
                .replayedUnrouted(["content:a", "tool_call:t"], droppedCharacters: 0, droppedEvents: 0)
            ]
        ) { control in
            control.yield("content", "a")
            control.yield("tool_call", "t")
            control.finish()
        }
    }

    func testCompletionCommittedByRouteAuthorityRoutesTheRun() async {
        await assertRaceParity(
            completionAuthority: .committed,
            expected: .init(settlement: .routed, outcome: .completed),
            trace: [
                .disposed("content:a", accepted: true),
                .beganRoutedStream,
                .committedRoute(replayed: ["content:a"], droppedCharacters: 0, droppedEvents: 0),
                .published(["content:a"])
            ]
        ) { control in
            control.yield("content", "a")
            control.finish()
        }
    }

    func testPreRouteProviderFailureReplaysUnroutedEventsAndReportsTheMessage() async {
        await assertRaceParity(
            expected: .init(settlement: .failedWithoutRoute("boom"), outcome: .failed(.provider("boom"))),
            trace: [
                .disposed("content:a", accepted: true),
                .replayedUnrouted(["content:a"], droppedCharacters: 0, droppedEvents: 0)
            ]
        ) { control in
            control.yield("content", "a")
            control.finish(throwing: ScriptedProviderFailure(message: "boom"))
        }
    }

    func testRouteOwnershipLossCancelsTheStreamWithoutReplay() async {
        await assertRaceParity(
            expected: .init(settlement: .routingOwnershipLost, outcome: .failed(.routingOwnershipLost)),
            trace: [.disposed("content:a", accepted: true)]
        ) { control in
            control.yield("content", "a")
            await control.waitForTraceCount(1)
            await control.authority.resolveRoute(.ownershipLost)
        }
    }

    func testOuterCancellationWhilePendingSettlesCancelled() async {
        await assertRaceParity(
            cancelRaceAfterSteering: true,
            expected: .init(settlement: .cancelled, outcome: .cancelled),
            trace: [.disposed("content:a", accepted: true)]
        ) { control in
            control.yield("content", "a")
            await control.waitForTraceCount(1)
        }
    }

    func testRejectedAdmissionSettlesCancelled() async {
        await assertRaceParity(
            acceptedEventLimit: 1,
            expected: .init(settlement: .cancelled, outcome: .cancelled),
            trace: [
                .disposed("content:a", accepted: true),
                .disposed("content:b", accepted: false)
            ]
        ) { control in
            control.yield("content", "a")
            control.yield("content", "b")
        }
    }

    func testPostRouteProviderFailureIsTheRunOutcome() async {
        await assertRaceParity(
            expected: .init(settlement: .routed, outcome: .failed(.provider("late"))),
            trace: [
                .beganRoutedStream,
                .committedRoute(replayed: [], droppedCharacters: 0, droppedEvents: 0),
                .published([]),
                .delivered("content:a", replayed: [], droppedCharacters: 0, droppedEvents: 0),
                .published(["content:a"]),
                .disposed("content:a", accepted: true)
            ]
        ) { control in
            await control.authority.resolveRoute(.routed)
            await control.waitForTraceCount(3)
            control.yield("content", "a")
            await control.waitForTraceCount(6)
            control.finish(throwing: ScriptedProviderFailure(message: "late"))
        }
    }

    func testRoutingSignalObservedAtCompletionDecidesTheRun() async {
        await assertRaceParity(
            currentRoutingOutcome: .cancelled,
            expected: .init(settlement: .cancelled, outcome: .cancelled),
            trace: [.disposed("content:a", accepted: true)]
        ) { control in
            control.yield("content", "a")
            control.finish()
        }
        await assertRaceParity(
            currentRoutingOutcome: .ownershipLost,
            expected: .init(settlement: .routingOwnershipLost, outcome: .failed(.routingOwnershipLost)),
            trace: [.disposed("content:a", accepted: true)]
        ) { control in
            control.yield("content", "a")
            control.finish()
        }
        await assertRaceParity(
            currentRoutingOutcome: .timedOutAfterConnection,
            expected: .init(settlement: .completedWithoutRoute, outcome: .failed(.completedWithoutRoute)),
            trace: [
                .disposed("content:a", accepted: true),
                .replayedUnrouted(["content:a"], droppedCharacters: 0, droppedEvents: 0)
            ]
        ) { control in
            control.yield("content", "a")
            control.finish()
        }
    }

    func testRoutingWatchdogReportsOnlyWhileNoConnectionWasObserved() async {
        await assertRaceParity(
            expected: .init(settlement: .routed, outcome: .completed),
            trace: [
                .watchdogProbed,
                .watchdogReported,
                .beganRoutedStream,
                .committedRoute(replayed: [], droppedCharacters: 0, droppedEvents: 0),
                .published([])
            ]
        ) { control in
            await control.authority.fireWatchdog()
            await control.waitForTraceCount(2)
            await control.authority.resolveRoute(.routed)
            await control.waitForTraceCount(5)
            control.finish()
        }
        await assertRaceParity(
            connectionObserved: true,
            expected: .init(settlement: .routed, outcome: .completed),
            trace: [
                .watchdogProbed,
                .beganRoutedStream,
                .committedRoute(replayed: [], droppedCharacters: 0, droppedEvents: 0),
                .published([])
            ]
        ) { control in
            await control.authority.fireWatchdog()
            await control.waitForTraceCount(1)
            await control.authority.resolveRoute(.routed)
            await control.waitForTraceCount(4)
            control.finish()
        }
    }

    func testDetachedHostSettlesCancelledWithoutConsumingEvents() async {
        await assertRaceParity(
            attached: false,
            expected: .init(settlement: .cancelled, outcome: .cancelled),
            trace: []
        ) { control in
            control.yield("content", "a")
        }
    }

    func testOverflowAccountingReachesTheRouteCommit() async {
        await assertRaceParity(
            limits: .init(maxBufferedTextCharacters: 1000, maxBufferedEventCount: 2),
            expected: .init(settlement: .routed, outcome: .completed),
            trace: [
                .disposed("content:1", accepted: true),
                .disposed("status:s", accepted: true),
                .disposed("content:2", accepted: true),
                .disposed("tool_call:3", accepted: true),
                .beganRoutedStream,
                .committedRoute(
                    replayed: ["content:2", "tool_call:3"],
                    droppedCharacters: "content1".count + "statuss".count,
                    droppedEvents: 2
                ),
                .published(["content:2", "tool_call:3"])
            ]
        ) { control in
            control.yield("content", "1")
            control.yield("status", "s")
            control.yield("content", "2")
            control.yield("tool_call", "3")
            await control.waitForTraceCount(4)
            await control.authority.resolveRoute(.routed)
            await control.waitForTraceCount(7)
            control.finish()
        }
    }

    // MARK: - Harness

    private static func descriptor(_ type: String, _ text: String?) -> ContextBuilderPreRouteEventDescriptor {
        ContextBuilderPreRouteEventDescriptor(type: type, text: text, additionalPayloads: [])
    }

    private func assertRaceParity(
        limits: ContextBuilderPreRouteBufferLimits = .init(maxBufferedTextCharacters: 1000, maxBufferedEventCount: 100),
        attached: Bool = true,
        acceptedEventLimit: Int? = nil,
        currentRoutingOutcome: ContextBuilderRouteWaitResult? = nil,
        completionAuthority: ContextBuilderRouteCompletionAuthority = .revocationFenced,
        connectionObserved: Bool = false,
        cancelRaceAfterSteering: Bool = false,
        expected: ContextBuilderRouteSettlementReport,
        trace expectedTrace: [ScriptedRaceTrace],
        file: StaticString = #filePath,
        line: UInt = #line,
        steer: @escaping @Sendable (ScriptedRaceControl) async -> Void
    ) async {
        for isolation in ScriptedRaceIsolation.allCases {
            let control = ScriptedRaceControl(
                configuration: .init(
                    attached: attached,
                    acceptedEventLimit: acceptedEventLimit,
                    currentRoutingOutcome: currentRoutingOutcome,
                    completionAuthority: completionAuthority,
                    connectionObserved: connectionObserved
                )
            )
            let race = Task {
                switch isolation {
                case .mainActor:
                    await ScriptedRaceRunner.runOnMainActor(control: control, limits: limits)
                case .headlessActor:
                    await ScriptedHeadlessRaceActor().run(control: control, limits: limits)
                }
            }
            await steer(control)
            if cancelRaceAfterSteering {
                race.cancel()
            }
            let result = await race.value
            XCTAssertEqual(result.report, expected, "\(isolation)", file: file, line: line)
            XCTAssertEqual(result.trace, expectedTrace, "\(isolation)", file: file, line: line)
            XCTAssertTrue(result.everyCallbackOnRaceActor, "\(isolation)", file: file, line: line)
        }
    }
}

struct ScriptedProviderFailure: Error, Sendable {
    let message: String
}

struct ScriptedProviderEvent: Sendable, Equatable {
    let type: String
    let text: String?

    var label: String {
        "\(type):\(text ?? "")"
    }
}

enum ScriptedRaceTrace: Sendable, Equatable {
    case disposed(String, accepted: Bool)
    case beganRoutedStream
    case committedRoute(replayed: [String], droppedCharacters: Int, droppedEvents: Int)
    case delivered(String, replayed: [String], droppedCharacters: Int, droppedEvents: Int)
    case replayedUnrouted([String], droppedCharacters: Int, droppedEvents: Int)
    case published([String])
    case watchdogProbed
    case watchdogReported
}

enum ScriptedRaceIsolation: CaseIterable {
    case mainActor
    case headlessActor
}

struct ScriptedRaceResult: Sendable {
    let report: ContextBuilderRouteSettlementReport
    let trace: [ScriptedRaceTrace]
    let everyCallbackOnRaceActor: Bool
}

/// Route authority for a scripted run. Like the MCP bootstrap lease it is an actor, and a
/// committed completion or an observed routing signal also wakes the indefinite route wait.
actor ScriptedRouteAuthority {
    struct Configuration {
        let attached: Bool
        let acceptedEventLimit: Int?
        let currentRoutingOutcome: ContextBuilderRouteWaitResult?
        let completionAuthority: ContextBuilderRouteCompletionAuthority
        let connectionObserved: Bool
    }

    let configuration: Configuration
    private var route: ContextBuilderRouteWaitResult?
    private var routeWaiters: [UUID: CheckedContinuation<ContextBuilderRouteWaitResult, Never>] = [:]
    private var watchdogFired = false
    private var watchdogWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    func resolveRoute(_ result: ContextBuilderRouteWaitResult) {
        guard route == nil else { return }
        route = result
        let waiters = routeWaiters
        routeWaiters.removeAll()
        waiters.values.forEach { $0.resume(returning: result) }
    }

    func waitForRoute() async -> ContextBuilderRouteWaitResult {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let route {
                    continuation.resume(returning: route)
                } else if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                } else {
                    routeWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelRouteWait(id) }
        }
    }

    func currentRoutingOutcome() -> ContextBuilderRouteWaitResult? {
        switch configuration.currentRoutingOutcome {
        case let .some(outcome) where outcome != .timedOutBeforeConnection && outcome != .timedOutAfterConnection:
            // A terminal routing signal is what the waiting route wait would also observe.
            resolveRoute(outcome)
        default:
            break
        }
        return configuration.currentRoutingOutcome
    }

    func resolveCompletionAuthority() -> ContextBuilderRouteCompletionAuthority {
        if configuration.completionAuthority == .committed {
            resolveRoute(.routed)
        }
        return configuration.completionAuthority
    }

    func fireWatchdog() {
        watchdogFired = true
        let waiters = watchdogWaiters
        watchdogWaiters.removeAll()
        waiters.values.forEach { $0.resume(returning: true) }
    }

    /// Returns `true` when the watchdog fires and `false` when the waiting task is cancelled.
    func waitForWatchdog() async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if watchdogFired {
                    continuation.resume(returning: true)
                } else if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    watchdogWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWatchdogWait(id) }
        }
    }

    private func cancelRouteWait(_ id: UUID) {
        routeWaiters.removeValue(forKey: id)?.resume(returning: .cancelled)
    }

    private func cancelWatchdogWait(_ id: UUID) {
        watchdogWaiters.removeValue(forKey: id)?.resume(returning: false)
    }
}

/// Ordered trace sink the steering script can wait on.
actor ScriptedRaceTraceStore {
    private var count = 0
    private var waiters: [(minimum: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func append() {
        count += 1
        let ready = waiters.filter { $0.minimum <= count }
        waiters.removeAll { $0.minimum <= count }
        ready.forEach { $0.continuation.resume() }
    }

    func waitForCount(_ minimum: Int) async {
        guard count < minimum else { return }
        await withCheckedContinuation { waiters.append((minimum, $0)) }
    }
}

/// Everything the steering script and the scripted host share. Sendable.
final class ScriptedRaceControl: Sendable {
    let authority: ScriptedRouteAuthority
    let events: AsyncThrowingStream<ScriptedProviderEvent, any Error>
    private let eventContinuation: AsyncThrowingStream<ScriptedProviderEvent, any Error>.Continuation
    let traceStore = ScriptedRaceTraceStore()

    init(configuration: ScriptedRouteAuthority.Configuration) {
        authority = ScriptedRouteAuthority(configuration: configuration)
        let (stream, continuation) = AsyncThrowingStream<ScriptedProviderEvent, any Error>.makeStream()
        events = stream
        eventContinuation = continuation
    }

    var configuration: ScriptedRouteAuthority.Configuration {
        authority.configuration
    }

    func yield(_ type: String, _ text: String?) {
        eventContinuation.yield(ScriptedProviderEvent(type: type, text: text))
    }

    func finish(throwing error: (any Error)? = nil) {
        eventContinuation.finish(throwing: error)
    }

    /// Waits until the host has recorded at least `count` trace entries.
    func waitForTraceCount(_ count: Int) async {
        await traceStore.waitForCount(count)
    }
}

/// A host with no isolation of its own: every callback runs on whichever actor runs the race.
final class ScriptedRaceHost: ContextBuilderRouteSettlementHost {
    typealias Event = ScriptedProviderEvent
    typealias Publication = [String]

    private let raceActor: any Actor
    private let control: ScriptedRaceControl
    private(set) var trace: [ScriptedRaceTrace] = []
    private(set) var everyCallbackOnRaceActor = true
    private var acceptedEventCount = 0
    /// Trace appends are forwarded in order through one stream, so waiters observe them in order.
    private let traceSignals: AsyncStream<Void>.Continuation

    init(raceActor: any Actor, control: ScriptedRaceControl) {
        self.raceActor = raceActor
        self.control = control
        let (signals, continuation) = AsyncStream<Void>.makeStream()
        traceSignals = continuation
        let store = control.traceStore
        Task {
            for await _ in signals {
                await store.append()
            }
        }
    }

    deinit {
        traceSignals.finish()
    }

    var isAttached: Bool {
        checkIsolation()
        return control.configuration.attached
    }

    nonisolated(nonsending) func waitForRoute() async -> ContextBuilderRouteWaitResult {
        checkIsolation()
        let result = await control.authority.waitForRoute()
        checkIsolation()
        return result
    }

    nonisolated(nonsending) func currentRoutingOutcome() async -> ContextBuilderRouteWaitResult? {
        let outcome = await control.authority.currentRoutingOutcome()
        checkIsolation()
        return outcome
    }

    nonisolated(nonsending) func resolveCompletionAuthority() async -> ContextBuilderRouteCompletionAuthority {
        let authority = await control.authority.resolveCompletionAuthority()
        checkIsolation()
        return authority
    }

    nonisolated(nonsending) func sleepUntilRoutingWatchdog() async throws {
        guard await control.authority.waitForWatchdog() else { throw CancellationError() }
        checkIsolation()
    }

    nonisolated(nonsending) func childConnectionWasObserved() async -> Bool {
        checkIsolation()
        record(.watchdogProbed)
        return control.configuration.connectionObserved
    }

    nonisolated(nonsending) func reportRoutingWatchdog() async {
        record(.watchdogReported)
    }

    func acceptsProviderEvents() -> Bool {
        checkIsolation()
        guard let limit = control.configuration.acceptedEventLimit else { return true }
        return acceptedEventCount < limit
    }

    func recordProviderEventProgress() -> Bool {
        checkIsolation()
        return true
    }

    func failureMessage(for error: any Error) -> String {
        (error as? ScriptedProviderFailure)?.message ?? String(describing: error)
    }

    func preRouteDescriptor(for event: ScriptedProviderEvent) -> ContextBuilderPreRouteEventDescriptor {
        ContextBuilderPreRouteEventDescriptor(type: event.type, text: event.text, additionalPayloads: [])
    }

    nonisolated(nonsending) func beginRoutedStream() async {
        record(.beganRoutedStream)
    }

    func commitRoute(replaying drain: ContextBuilderPreRouteDrain<ScriptedProviderEvent>) -> [String] {
        let labels = drain.events.map(\.label)
        record(.committedRoute(
            replayed: labels,
            droppedCharacters: drain.droppedTextCharacterCount,
            droppedEvents: drain.droppedEventCount
        ))
        return labels
    }

    func deliverRoutedEvent(
        _ event: ScriptedProviderEvent,
        replaying drain: ContextBuilderPreRouteDrain<ScriptedProviderEvent>
    ) -> [String] {
        let labels = drain.events.map(\.label)
        record(.delivered(
            event.label,
            replayed: labels,
            droppedCharacters: drain.droppedTextCharacterCount,
            droppedEvents: drain.droppedEventCount
        ))
        return labels + [event.label]
    }

    func replayUnroutedEvents(_ drain: ContextBuilderPreRouteDrain<ScriptedProviderEvent>) {
        record(.replayedUnrouted(
            drain.events.map(\.label),
            droppedCharacters: drain.droppedTextCharacterCount,
            droppedEvents: drain.droppedEventCount
        ))
    }

    nonisolated(nonsending) func publish(_ publication: [String]) async {
        record(.published(publication))
    }

    nonisolated(nonsending) func willProcessProviderEvent(_ event: ScriptedProviderEvent) async {
        checkIsolation()
    }

    func didDisposeProviderEvent(_ event: ScriptedProviderEvent, accepted: Bool) {
        if accepted {
            acceptedEventCount += 1
        }
        record(.disposed(event.label, accepted: accepted))
    }

    private func record(_ entry: ScriptedRaceTrace) {
        checkIsolation()
        trace.append(entry)
        traceSignals.yield()
    }

    private func checkIsolation() {
        // `preconditionIsolated` traps; recording keeps a regression a normal test failure.
        let onActor = raceActorIsCurrent()
        everyCallbackOnRaceActor = everyCallbackOnRaceActor && onActor
    }

    private func raceActorIsCurrent() -> Bool {
        if raceActor === MainActor.shared {
            return Thread.isMainThread
        }
        return (raceActor as? ScriptedHeadlessRaceActor)?.isCurrent() ?? false
    }
}

enum ScriptedRaceRunner {
    @MainActor
    static func runOnMainActor(
        control: ScriptedRaceControl,
        limits: ContextBuilderPreRouteBufferLimits
    ) async -> ScriptedRaceResult {
        let host = ScriptedRaceHost(raceActor: MainActor.shared, control: control)
        let report = await ContextBuilderRouteSettlementRace.run(
            control.events,
            host: host,
            limits: limits,
            isolation: MainActor.shared
        )
        return ScriptedRaceResult(
            report: report,
            trace: host.trace,
            everyCallbackOnRaceActor: host.everyCallbackOnRaceActor
        )
    }
}

/// A headless host's own actor, with a serial executor whose queue identifies the current actor.
actor ScriptedHeadlessRaceActor {
    private let queue: DispatchSerialQueue
    private static let queueKey = DispatchSpecificKey<ObjectIdentifier>()

    init() {
        let queue = DispatchSerialQueue(label: "ContextBuilderRouteSettlementTests.headless")
        self.queue = queue
        queue.setSpecific(key: Self.queueKey, value: ObjectIdentifier(queue))
    }

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    nonisolated func isCurrent() -> Bool {
        DispatchQueue.getSpecific(key: Self.queueKey) == ObjectIdentifier(queue)
    }

    func run(control: ScriptedRaceControl, limits: ContextBuilderPreRouteBufferLimits) async -> ScriptedRaceResult {
        let host = ScriptedRaceHost(raceActor: self, control: control)
        let report = await ContextBuilderRouteSettlementRace.run(
            control.events,
            host: host,
            limits: limits,
            isolation: self
        )
        return ScriptedRaceResult(
            report: report,
            trace: host.trace,
            everyCallbackOnRaceActor: host.everyCallbackOnRaceActor
        )
    }
}
