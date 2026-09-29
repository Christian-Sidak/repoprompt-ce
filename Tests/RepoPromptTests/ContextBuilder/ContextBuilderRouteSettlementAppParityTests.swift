import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// App parity for the shared Context Builder route/stream settlement core.
///
/// - The `AIStreamResult` mapping feeds the shared buffer exactly what the pre-M16
///   `ContextBuilderRouteSettlementCoordinator` counted, checked against a verbatim copy of it.
/// - The production view-model race and a headless actor host that drives the same core with the
///   same route authority produce the same visible output, drop accounting, and terminal outcome.
@MainActor
final class ContextBuilderRouteSettlementAppParityTests: XCTestCase {
    // MARK: - Provider mapping

    func testProviderMappingCountsEveryRetainedStringAndKeepsLegacyClassification() {
        let event = AIStreamResult(
            type: "tool_call",
            text: "tx",
            reasoning: "r",
            promptTokens: 5,
            completionTokens: 6,
            cost: 0.5,
            toolName: "tn",
            toolArgs: "ta",
            toolOutput: "to",
            toolInvocationID: UUID(),
            toolResultJSON: "trj",
            toolArgsJSON: "taj",
            toolIsError: true,
            providerSessionID: "psid",
            stopReason: "stop",
            modelContextWindow: 3,
            contextUsedTokens: 2,
            contentMessageID: "mid"
        )
        let descriptor = event.contextBuilderPreRouteDescriptor
        XCTAssertEqual(descriptor.kind, .protected)
        XCTAssertEqual(
            descriptor.payloadCharacterCount,
            ["tool_call", "tx", "r", "tn", "ta", "to", "trj", "taj", "psid", "stop", "mid"].reduce(0) { $0 + $1.count }
        )
        XCTAssertEqual(
            AIStreamResult(type: AIStreamResult.lifecycleType, text: "x").contextBuilderPreRouteDescriptor.kind,
            .progress
        )
        XCTAssertEqual(AIStreamResult(type: "content", text: "").contextBuilderPreRouteDescriptor.kind, .content(isEmpty: true))
        for type in [AIStreamResult.transportActivityType, AIStreamResult.incompleteType, "final_content", "message_stop", "error"] {
            XCTAssertEqual(AIStreamResult(type: type, text: nil).contextBuilderPreRouteDescriptor.kind, .protected, type)
        }
    }

    func testSharedBufferMatchesTheLegacyCoordinatorOverASeededCorpus() {
        let limitConfigurations = [(0, 0), (1, 1), (20, 3), (64, 5), (200, 10), (1000, 2), (64000, 256)]
        var eventNumber = 0
        for (maxText, maxCount) in limitConfigurations {
            for seed in UInt64(1) ... 3 {
                var generator = SplitMix64(seed: seed &* 7919 &+ UInt64(maxText * 31 + maxCount))
                var legacy = LegacyPreRouteBuffer(maxBufferedTextCharacters: maxText, maxBufferedEventCount: maxCount)
                var shared = ContextBuilderPreRouteEventBuffer<AIStreamResult>(
                    limits: .init(maxBufferedTextCharacters: maxText, maxBufferedEventCount: maxCount)
                )
                let context = "limits \(maxText)/\(maxCount) seed \(seed)"
                for _ in 0 ..< 300 {
                    if Int.random(in: 0 ..< 10, using: &generator) == 0 {
                        assertEqualDrains(legacy.drain(), shared.drain(), context)
                        continue
                    }
                    eventNumber += 1
                    let event = Self.randomEvent(number: eventNumber, using: &generator)
                    legacy.append(event)
                    shared.append(event, descriptor: event.contextBuilderPreRouteDescriptor)
                    XCTAssertEqual(legacy.bufferedTextCharacterCount, shared.bufferedTextCharacterCount, context)
                    XCTAssertEqual(legacy.bufferedEvents.count, shared.bufferedEventCount, context)
                }
                assertEqualDrains(legacy.drain(), shared.drain(), context)
            }
        }
    }

    // MARK: - Outcome mapping

    func testTerminalOutcomeMappingKeepsRoutingErrorText() {
        let agent = AgentProviderKind.claudeCode
        let client = agent.mcpClientNameHint ?? agent.displayName
        XCTAssertEqual(ContextBuilderRunTerminalOutcome(.completed, agentKind: agent), .completed)
        XCTAssertEqual(ContextBuilderRunTerminalOutcome(.cancelled, agentKind: agent), .cancelled)
        XCTAssertEqual(ContextBuilderRunTerminalOutcome(.failed(.provider("boom")), agentKind: agent), .failed("boom"))
        XCTAssertEqual(
            ContextBuilderRunTerminalOutcome(.failed(.completedWithoutRoute), agentKind: agent),
            .failed(
                "mcp_completed_without_route: \(agent.displayName) finished before opening the expected MCP client " +
                    "'\(client)'. No Context Builder selection was committed."
            )
        )
        XCTAssertEqual(
            ContextBuilderRunTerminalOutcome(.failed(.routingOwnershipLost), agentKind: agent),
            .failed(
                "mcp_routing_failed: \(agent.displayName) lost ownership of the expected MCP client '\(client)' " +
                    "before routing committed. The run was terminated and MCP bootstrap state was released."
            )
        )
    }

    func testRouteAuthorityMappingMatchesTheLeaseVocabulary() {
        XCTAssertEqual(ContextBuilderRouteWaitResult(MCPRoutingWaitOutcome.routed), .routed)
        XCTAssertEqual(ContextBuilderRouteWaitResult(MCPRoutingWaitOutcome.failed(.signalled)), .ownershipLost)
        XCTAssertEqual(ContextBuilderRouteWaitResult(MCPRoutingWaitOutcome.failed(.cleanedUp)), .ownershipLost)
        XCTAssertEqual(ContextBuilderRouteWaitResult(MCPRoutingWaitOutcome.cancelled), .cancelled)
        XCTAssertEqual(
            ContextBuilderRouteWaitResult(MCPRoutingWaitOutcome.timedOutBeforeConnection),
            .timedOutBeforeConnection
        )
        XCTAssertEqual(ContextBuilderRouteWaitResult(MCPRoutingWaitOutcome.timedOutAfterConnection), .timedOutAfterConnection)
        XCTAssertEqual(ContextBuilderRouteCompletionAuthority(MCPRunRouteAuthorityDecision.committed), .committed)
        XCTAssertEqual(
            ContextBuilderRouteCompletionAuthority(MCPRunRouteAuthorityDecision.revocationFenced),
            .revocationFenced
        )
    }

    // MARK: - Production race versus headless host

    func testProductionRaceMatchesHeadlessHostForScriptedRuns() async throws {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }

        let composition = WindowStateCompositionFactory.make(
            windowID: -8871,
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService()
        )
        await composition.workspaceManager.awaitInitialized()
        let viewModel = composition.contextBuilderAgentViewModel
        defer { viewModel.installRunTestHooks(nil) }

        let overflowCount = ContextBuilderDefaults.mcpPreRouteBufferedEventLimit + 44
        let scenarios: [ParityScenario] = [
            ParityScenario(
                name: "routed after buffered events",
                preRouteEvents: [.content("a"), .event("tool_call", "read_file"), .content("b")],
                route: .routed,
                postRouteEvents: [.content("c"), .event("final_content", "abc!")],
                termination: .finish
            ),
            ParityScenario(
                name: "completed without route",
                preRouteEvents: [.content("a"), .event("status", "s"), .content("b")],
                route: nil,
                termination: .finish
            ),
            ParityScenario(
                name: "completion committed by route authority",
                preRouteEvents: [.content("a")],
                route: nil,
                termination: .finish,
                completionAuthority: .committed
            ),
            ParityScenario(
                name: "provider failure before route",
                preRouteEvents: [.content("a")],
                route: nil,
                termination: .fail("boom")
            ),
            ParityScenario(
                name: "routing ownership lost",
                preRouteEvents: [.content("a")],
                route: .failed(.signalled),
                termination: .none
            ),
            ParityScenario(
                name: "pre-route overflow",
                preRouteEvents: (0 ..< overflowCount).map { .content("x\($0) ") },
                route: .routed,
                termination: .finish
            )
        ]

        for scenario in scenarios {
            let app = try await runProductionRace(scenario, viewModel: viewModel)
            let headless = await runHeadlessRace(scenario)
            let headlessOutcome = ContextBuilderRunTerminalOutcome(headless.report.outcome, agentKind: .claudeCode)

            XCTAssertEqual(app.output, headless.output, scenario.name)
            for summary in headless.droppedSummaries {
                XCTAssertTrue(app.log.contains(summary), "\(scenario.name): missing \(summary) in \(app.log)")
            }
            switch (app.outcome, headlessOutcome) {
            case let (.failed(appMessage), .failed(headlessMessage)) where scenario.termination.isFailure:
                // The app appends CLI guidance to provider failures; the provider message leads.
                XCTAssertTrue(appMessage.hasPrefix(headlessMessage), "\(scenario.name): \(appMessage)")
            default:
                XCTAssertEqual(app.outcome, headlessOutcome, scenario.name)
            }
            XCTAssertEqual(headless.report.outcome, scenario.expectedOutcome, scenario.name)
        }

        // Spot-check the scenarios' visible effects directly.
        let routed = try await runProductionRace(scenarios[0], viewModel: viewModel)
        XCTAssertEqual(routed.output, "abc!")
        XCTAssertTrue(
            routed.log.contains("\(AgentProviderKind.claudeCode.displayName) connected, analyzing workspace..."),
            "\(routed.log)"
        )
        let overflow = try await runProductionRace(scenarios[5], viewModel: viewModel)
        XCTAssertEqual(
            overflow.output,
            (44 ..< overflowCount).map { "x\($0) " }.joined()
        )
        let droppedCharacters = (0 ..< 44).reduce(0) { $0 + "content".count + "x\($1) ".count }
        XCTAssertTrue(
            overflow.log.contains(
                "Dropped \(droppedCharacters) characters of early provider payload and 44 early provider events " +
                    "while waiting for MCP routing."
            ),
            "\(overflow.log)"
        )
    }

    // MARK: - Harness

    private func runProductionRace(
        _ scenario: ParityScenario,
        viewModel: ContextBuilderAgentViewModel
    ) async throws -> AppRaceResult {
        let tabID = UUID()
        viewModel.replaceSessionForTesting(tabID: tabID)
        let session = try XCTUnwrap(viewModel.sessions[tabID])
        let ownership = session.beginRunAttempt(source: "route-settlement-parity")
        let routeCommitted = ParitySignal()
        let record = ContextBuilderRunRecord(
            runID: UUID(),
            tabID: tabID,
            session: session,
            ownership: ownership,
            origin: .ui,
            agentKind: .claudeCode,
            modelRaw: AgentModel.defaultModel.rawValue,
            progressReporter: { phase in
                if phase == .waitingForProviderStreamEvent {
                    await routeCommitted.fire()
                }
            }
        )
        XCTAssertTrue(viewModel.registerRunForTesting(record))
        session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .running)

        let dispositions = ParityCounter()
        let runID = record.runID
        viewModel.installRunTestHooks(.init(
            beforeProcessingProviderEvent: nil,
            providerEventDisposition: { _, eventRunID, _ in
                guard eventRunID == runID else { return }
                Task { await dispositions.increment() }
            },
            teardownCompleted: nil
        ))

        let authority = ScriptedParityRouteAuthority(completionAuthority: scenario.completionAuthority)
        let (stream, continuation) = AsyncThrowingStream<AIStreamResult, Error>.makeStream()
        let run = Task {
            await viewModel.consumeProviderStreamAwaitingRouteForTesting(
                stream,
                record: record,
                routeAuthority: authority
            )
        }
        await steer(
            scenario,
            continuation: continuation,
            authority: authority,
            dispositions: dispositions,
            routeCommitted: routeCommitted
        )
        let outcome = await run.value
        record.previewPublicationTask?.cancel()
        viewModel.installRunTestHooks(nil)
        return AppRaceResult(
            outcome: outcome,
            output: record.output.fullOutput(),
            log: session.agentLog.map(\.message)
        )
    }

    private func runHeadlessRace(_ scenario: ParityScenario) async -> HeadlessRaceResult {
        let authority = ScriptedParityRouteAuthority(completionAuthority: scenario.completionAuthority)
        let dispositions = ParityCounter()
        let routeCommitted = ParitySignal()
        let (stream, continuation) = AsyncThrowingStream<AIStreamResult, Error>.makeStream()
        let race = HeadlessParityRaceActor()
        let run = Task {
            await race.run(
                stream,
                authority: authority,
                dispositions: dispositions,
                routeCommitted: routeCommitted
            )
        }
        await steer(
            scenario,
            continuation: continuation,
            authority: authority,
            dispositions: dispositions,
            routeCommitted: routeCommitted
        )
        return await run.value
    }

    /// Yields the pre-route events, waits until every one was disposed, resolves the route, waits
    /// for the route commit when routed, yields the post-route events, then terminates the stream.
    private func steer(
        _ scenario: ParityScenario,
        continuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation,
        authority: ScriptedParityRouteAuthority,
        dispositions: ParityCounter,
        routeCommitted: ParitySignal
    ) async {
        for event in scenario.preRouteEvents {
            continuation.yield(event.streamResult)
        }
        await dispositions.wait(atLeast: scenario.preRouteEvents.count)
        if let route = scenario.route {
            await authority.resolveRoute(route)
            if route == .routed {
                await routeCommitted.wait()
            }
        }
        for event in scenario.postRouteEvents {
            continuation.yield(event.streamResult)
        }
        await dispositions.wait(atLeast: scenario.preRouteEvents.count + scenario.postRouteEvents.count)
        switch scenario.termination {
        case .finish:
            continuation.finish()
        case let .fail(message):
            continuation.finish(throwing: ParityProviderFailure(message: message))
        case .none:
            break
        }
    }

    private func assertEqualDrains(
        _ legacy: (events: [AIStreamResult], droppedText: Int, droppedEvents: Int),
        _ shared: ContextBuilderPreRouteDrain<AIStreamResult>,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            legacy.events.map(\.contentMessageID),
            shared.events.map(\.contentMessageID),
            context,
            file: file,
            line: line
        )
        XCTAssertEqual(legacy.droppedText, shared.droppedTextCharacterCount, context, file: file, line: line)
        XCTAssertEqual(legacy.droppedEvents, shared.droppedEventCount, context, file: file, line: line)
    }

    private static func randomEvent(number: Int, using generator: inout SplitMix64) -> AIStreamResult {
        let types = [
            "content", "content", "content", AIStreamResult.lifecycleType, "event", "status",
            "tool_call", "tool_result", "error", "final_content", "message_stop", AIStreamResult.transportActivityType
        ]
        let alphabet = ["a", "é", "👍🏽", " ", "z", "\n"]
        func text(maxLength: Int) -> String? {
            guard Int.random(in: 0 ..< 5, using: &generator) != 0 else { return nil }
            let length = Int.random(in: 0 ... maxLength, using: &generator)
            return (0 ..< length).map { _ in alphabet[Int.random(in: 0 ..< alphabet.count, using: &generator)] }.joined()
        }
        func optionalText() -> String? {
            Int.random(in: 0 ..< 4, using: &generator) == 0 ? text(maxLength: 12) : nil
        }
        return AIStreamResult(
            type: types[Int.random(in: 0 ..< types.count, using: &generator)],
            text: text(maxLength: 40),
            reasoning: optionalText(),
            toolName: optionalText(),
            toolArgs: optionalText(),
            toolOutput: optionalText(),
            toolResultJSON: optionalText(),
            toolArgsJSON: optionalText(),
            providerSessionID: optionalText(),
            stopReason: optionalText(),
            contentMessageID: "id-\(number)"
        )
    }
}

// MARK: - Scenario model

private struct ParityScenario {
    struct Event {
        let type: String
        let text: String?

        static func content(_ text: String) -> Event {
            Event(type: "content", text: text)
        }

        static func event(_ type: String, _ text: String?) -> Event {
            Event(type: type, text: text)
        }

        var streamResult: AIStreamResult {
            AIStreamResult(type: type, text: text)
        }
    }

    enum Termination {
        case finish
        case fail(String)
        case none

        var isFailure: Bool {
            if case .fail = self { return true }
            return false
        }
    }

    let name: String
    let preRouteEvents: [Event]
    let route: MCPRoutingWaitOutcome?
    var postRouteEvents: [Event] = []
    let termination: Termination
    var completionAuthority: MCPRunRouteAuthorityDecision = .revocationFenced

    var expectedOutcome: ContextBuilderRouteRunOutcome {
        switch (route, termination, completionAuthority) {
        case (.routed?, _, _), (nil, .finish, .committed):
            .completed
        case (nil, .finish, .revocationFenced):
            .failed(.completedWithoutRoute)
        case let (nil, .fail(message), _):
            .failed(.provider(ParityProviderFailure(message: message).localizedDescription))
        case (.failed?, _, _), (.timedOutBeforeConnection?, _, _), (.timedOutAfterConnection?, _, _):
            .failed(.routingOwnershipLost)
        case (.cancelled?, _, _), (nil, .none, _):
            .cancelled
        }
    }
}

private struct ParityProviderFailure: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

private struct AppRaceResult {
    let outcome: ContextBuilderRunTerminalOutcome
    let output: String?
    let log: [String]
}

private struct HeadlessRaceResult {
    let report: ContextBuilderRouteSettlementReport
    let output: String?
    let droppedSummaries: [String]
}

// MARK: - Shared scripted route authority and signals

/// A scripted stand-in for the MCP bootstrap lease. Like the lease, a committed completion
/// re-signals the route so the indefinite route wait wakes.
private actor ScriptedParityRouteAuthority: ContextBuilderRunRouteAuthority {
    private let completionAuthority: MCPRunRouteAuthorityDecision
    private var route: MCPRoutingWaitOutcome?
    private var waiters: [UUID: CheckedContinuation<MCPRoutingWaitOutcome, Never>] = [:]

    init(completionAuthority: MCPRunRouteAuthorityDecision) {
        self.completionAuthority = completionAuthority
    }

    func resolveRoute(_ outcome: MCPRoutingWaitOutcome) {
        guard route == nil else { return }
        route = outcome
        let pending = waiters
        waiters.removeAll()
        pending.values.forEach { $0.resume(returning: outcome) }
    }

    func waitForRoute(
        progressReporter: @escaping MCPBootstrapRoutingProgressReporter
    ) async -> MCPRoutingWaitOutcome {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let route {
                    continuation.resume(returning: route)
                } else if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWait(id) }
        }
    }

    func currentRoutingTerminalOutcome() async -> MCPRoutingWaitOutcome? {
        nil
    }

    func resolveRouteAuthorityAtProviderCompletion() async -> MCPRunRouteAuthorityDecision {
        if completionAuthority == .committed {
            resolveRoute(.routed)
        }
        return completionAuthority
    }

    func childConnectionWasObserved() async -> Bool {
        true
    }

    private func cancelWait(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: .cancelled)
    }
}

private actor ParityCounter {
    private var count = 0
    private var waiters: [(minimum: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func increment() {
        count += 1
        let ready = waiters.filter { $0.minimum <= count }
        waiters.removeAll { $0.minimum <= count }
        ready.forEach { $0.continuation.resume() }
    }

    func wait(atLeast minimum: Int) async {
        guard count < minimum else { return }
        await withCheckedContinuation { waiters.append((minimum, $0)) }
    }
}

private actor ParitySignal {
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire() {
        guard !fired else { return }
        fired = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func wait() async {
        guard !fired else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

// MARK: - Headless host

/// A headless host: it drives the shared core on its own actor with the app's provider mapping,
/// output accumulator, and route authority vocabulary, but no view model, session, or UI.
private actor HeadlessParityRaceActor {
    func run(
        _ stream: AsyncThrowingStream<AIStreamResult, Error>,
        authority: ScriptedParityRouteAuthority,
        dispositions: ParityCounter,
        routeCommitted: ParitySignal
    ) async -> HeadlessRaceResult {
        let host = HeadlessParityHost(authority: authority, dispositions: dispositions, routeCommitted: routeCommitted)
        let report = await ContextBuilderRouteSettlementRace.run(
            stream,
            host: host,
            limits: ContextBuilderDefaults.mcpPreRouteBufferLimits,
            isolation: self
        )
        return HeadlessRaceResult(
            report: report,
            output: host.output.fullOutput(),
            droppedSummaries: host.droppedSummaries
        )
    }
}

private final class HeadlessParityHost: ContextBuilderRouteSettlementHost {
    typealias Event = AIStreamResult
    typealias Publication = Void

    private let authority: ScriptedParityRouteAuthority
    private let dispositions: ParityCounter
    private let routeCommitted: ParitySignal
    var output = ContextBuilderAssistantOutputAccumulator()
    private(set) var droppedSummaries: [String] = []

    init(authority: ScriptedParityRouteAuthority, dispositions: ParityCounter, routeCommitted: ParitySignal) {
        self.authority = authority
        self.dispositions = dispositions
        self.routeCommitted = routeCommitted
    }

    var isAttached: Bool {
        true
    }

    nonisolated(nonsending) func waitForRoute() async -> ContextBuilderRouteWaitResult {
        await ContextBuilderRouteWaitResult(authority.waitForRoute(progressReporter: { _ in }))
    }

    nonisolated(nonsending) func currentRoutingOutcome() async -> ContextBuilderRouteWaitResult? {
        guard let outcome = await authority.currentRoutingTerminalOutcome() else { return nil }
        return ContextBuilderRouteWaitResult(outcome)
    }

    nonisolated(nonsending) func resolveCompletionAuthority() async -> ContextBuilderRouteCompletionAuthority {
        await ContextBuilderRouteCompletionAuthority(authority.resolveRouteAuthorityAtProviderCompletion())
    }

    nonisolated(nonsending) func sleepUntilRoutingWatchdog() async throws {
        try await Task.sleep(for: .seconds(3600))
    }

    nonisolated(nonsending) func childConnectionWasObserved() async -> Bool {
        await authority.childConnectionWasObserved()
    }

    nonisolated(nonsending) func reportRoutingWatchdog() async {}

    func acceptsProviderEvents() -> Bool {
        true
    }

    func recordProviderEventProgress() -> Bool {
        true
    }

    func failureMessage(for error: any Error) -> String {
        error.localizedDescription
    }

    func preRouteDescriptor(for event: AIStreamResult) -> ContextBuilderPreRouteEventDescriptor {
        event.contextBuilderPreRouteDescriptor
    }

    nonisolated(nonsending) func beginRoutedStream() async {}

    func commitRoute(replaying drain: ContextBuilderPreRouteDrain<AIStreamResult>) {
        apply(drain)
        let routeCommitted = routeCommitted
        Task { await routeCommitted.fire() }
    }

    func deliverRoutedEvent(_ event: AIStreamResult, replaying drain: ContextBuilderPreRouteDrain<AIStreamResult>) {
        apply(drain)
        apply(event)
    }

    func replayUnroutedEvents(_ drain: ContextBuilderPreRouteDrain<AIStreamResult>) {
        apply(drain)
    }

    nonisolated(nonsending) func publish(_: Void) async {}

    nonisolated(nonsending) func willProcessProviderEvent(_: AIStreamResult) async {}

    func didDisposeProviderEvent(_: AIStreamResult, accepted _: Bool) {
        let dispositions = dispositions
        Task { await dispositions.increment() }
    }

    private func apply(_ drain: ContextBuilderPreRouteDrain<AIStreamResult>) {
        drain.events.forEach(apply)
        if let summary = drain.droppedSummary {
            droppedSummaries.append(summary)
        }
    }

    private func apply(_ event: AIStreamResult) {
        switch event.type {
        case "content":
            output.append(event.text ?? "", messageID: event.contentMessageID)
        case "final_content":
            if let text = event.text {
                output.replace(with: text)
            }
        default:
            break
        }
    }
}

// MARK: - Legacy oracle

/// Verbatim copy of the pre-M16 `ContextBuilderRouteSettlementCoordinator` buffering, kept as the
/// parity oracle for exact event accounting and protected-event retention.
private struct LegacyPreRouteBuffer {
    private let maxBufferedTextCharacters: Int
    private let maxBufferedEventCount: Int
    private(set) var bufferedEvents: [AIStreamResult] = []
    private(set) var bufferedTextCharacterCount = 0
    private var droppedTextCharacterCount = 0
    private var droppedNonterminalEventCount = 0

    init(maxBufferedTextCharacters: Int, maxBufferedEventCount: Int) {
        self.maxBufferedTextCharacters = max(0, maxBufferedTextCharacters)
        self.maxBufferedEventCount = max(0, maxBufferedEventCount)
    }

    mutating func append(_ event: AIStreamResult) {
        if isCoalescibleProgressEvent(event),
           let existingIndex = bufferedEvents.lastIndex(where: {
               $0.type == event.type && isCoalescibleProgressEvent($0)
           })
        {
            removeBufferedEvent(at: existingIndex)
        }

        bufferedEvents.append(event)
        bufferedTextCharacterCount += stringPayloadCharacterCount(event)
        trimBufferedEventsIfNeeded()
    }

    mutating func drain() -> (events: [AIStreamResult], droppedText: Int, droppedEvents: Int) {
        let result = (bufferedEvents, droppedTextCharacterCount, droppedNonterminalEventCount)
        bufferedEvents.removeAll(keepingCapacity: false)
        bufferedTextCharacterCount = 0
        droppedTextCharacterCount = 0
        droppedNonterminalEventCount = 0
        return result
    }

    private mutating func trimBufferedEventsIfNeeded() {
        while bufferedTextCharacterCount > maxBufferedTextCharacters,
              let index = nextPayloadEvictionIndex()
        {
            removeBufferedEvent(at: index)
        }
        while bufferedEvents.count > maxBufferedEventCount,
              let index = nextCountEvictionIndex()
        {
            removeBufferedEvent(at: index)
        }
    }

    private func nextPayloadEvictionIndex() -> Int? {
        bufferedEvents.firstIndex(where: { $0.type == "content" })
            ?? bufferedEvents.firstIndex(where: isRedundantNonterminalEvent)
            ?? bufferedEvents.indices.first
    }

    private func nextCountEvictionIndex() -> Int? {
        bufferedEvents.firstIndex(where: isRedundantNonterminalEvent)
            ?? bufferedEvents.firstIndex(where: { $0.type == "content" })
            ?? bufferedEvents.indices.first
    }

    private mutating func removeBufferedEvent(at index: Int) {
        let removed = bufferedEvents.remove(at: index)
        let removedCount = stringPayloadCharacterCount(removed)
        bufferedTextCharacterCount -= removedCount
        droppedTextCharacterCount += removedCount
        droppedNonterminalEventCount += 1
    }

    private func stringPayloadCharacterCount(_ event: AIStreamResult) -> Int {
        [
            event.type,
            event.text,
            event.reasoning,
            event.toolName,
            event.toolArgs,
            event.toolOutput,
            event.toolResultJSON,
            event.toolArgsJSON,
            event.providerSessionID,
            event.stopReason,
            event.contentMessageID
        ].compactMap(\.self).reduce(0) { $0 + $1.count }
    }

    private func isCoalescibleProgressEvent(_ event: AIStreamResult) -> Bool {
        switch event.type {
        case AIStreamResult.lifecycleType, "event", "status":
            true
        default:
            false
        }
    }

    private func isRedundantNonterminalEvent(_ event: AIStreamResult) -> Bool {
        isCoalescibleProgressEvent(event)
            || event.type == "content" && (event.text?.isEmpty ?? true)
    }
}

private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
