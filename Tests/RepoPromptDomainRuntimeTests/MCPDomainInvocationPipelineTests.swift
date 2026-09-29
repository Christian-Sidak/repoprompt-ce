import Foundation
import MCP
@testable import RepoPromptDomainRuntime
import XCTest

/// Contract tests for M8B: the direct-headless composition admits, bounds, and classifies tool
/// calls through the same lanes, leases, contracts, and watchdog as the app adapter.
final class MCPDomainInvocationPipelineTests: XCTestCase {
    func testAdmissionClassLaneMappingIsShared() {
        XCTAssertEqual(MCPToolAdmissionClass.exclusive.connectionLane, .ordinary)
        XCTAssertEqual(MCPToolAdmissionClass.control.connectionLane, .control)
        XCTAssertEqual(MCPToolAdmissionClass.smallRead.connectionLane, .smallRead)
        XCTAssertEqual(MCPToolAdmissionClass.fileRead.connectionLane, .fileRead)
        XCTAssertEqual(MCPToolAdmissionClass.gitRead.connectionLane, .gitRead)
        XCTAssertEqual(MCPToolAdmissionClass.fileSearch.connectionLane, .fileSearch)
    }

    func testConnectionLaneBoundsConcurrentReadsAndReleasesEveryLease() async throws {
        let gate = Gate()
        let tracker = ConcurrencyTracker()
        let fixture = try await makeFixture(binding(MCPWindowToolName.getFileTree) { _ in
            await tracker.enter()
            await gate.wait()
            await tracker.leave()
            return .string("tree")
        })
        let limiters = MCPDomainInvocationPipeline.makeConnectionLimiters()
        let pipeline = fixture.pipeline(limiters: limiters)
        let invocation = fixture.invocation(MCPWindowToolName.getFileTree)

        let calls = (0 ..< 4).map { _ in
            Task { await pipeline.execute(invocation) }
        }
        let limit = MCPDomainToolAdmissionLimits.smallReadConnection
        await tracker.waitUntilActive(limit)
        try await eventually {
            await limiters.diagnosticsSnapshot(for: .smallRead).waiterCount == 4 - limit
        }
        let peakWhileBlocked = await tracker.peak
        XCTAssertEqual(peakWhileBlocked, limit)

        await gate.open()
        for call in calls {
            let result = await call.value
            XCTAssertEqual(try result.get().stringValue, "tree")
        }
        let peak = await tracker.peak
        XCTAssertEqual(peak, limit)
        let snapshot = await fixture.runtime.domainHost.snapshot()
        XCTAssertEqual(snapshot.activeResourceAdmissionLeaseCount, 0)
        XCTAssertEqual(snapshot.resourceAdmissionWaiterCount, 0)
        XCTAssertEqual(snapshot.activeInvocationCount, 0)
    }

    func testExclusiveCallsOnDifferentConnectionsShareTheScopeResourceLease() async throws {
        let gate = Gate()
        let tracker = ConcurrencyTracker()
        let fixture = try await makeFixture(binding(MCPWindowToolName.manageSelection) { _ in
            await tracker.enter()
            await gate.wait()
            await tracker.leave()
            return .string("selected")
        })
        let secondConnection = try await fixture.registerConnection()
        let first = fixture.pipeline(limiters: MCPDomainInvocationPipeline.makeConnectionLimiters())
        let second = fixture.pipeline(limiters: MCPDomainInvocationPipeline.makeConnectionLimiters())

        let firstCall = Task {
            await first.execute(fixture.invocation(MCPWindowToolName.manageSelection))
        }
        await tracker.waitUntilActive(1)
        let secondCall = Task {
            await second.execute(fixture.invocation(
                MCPWindowToolName.manageSelection,
                connection: secondConnection
            ))
        }
        let host = fixture.runtime.domainHost
        try await eventually {
            await host.snapshot().resourceAdmissionWaiterCount == 1
        }
        let peakWhileBlocked = await tracker.peak
        XCTAssertEqual(peakWhileBlocked, 1, "one exclusive call per scope across connections")

        await gate.open()
        let firstResult = await firstCall.value
        let secondResult = await secondCall.value
        XCTAssertEqual(try firstResult.get().stringValue, "selected")
        XCTAssertEqual(try secondResult.get().stringValue, "selected")
        let snapshot = await host.snapshot()
        XCTAssertEqual(snapshot.activeResourceAdmissionLeaseCount, 0)
    }

    func testWatchdogTimeoutOfCancellableReadIsTypedAndRetryable() async throws {
        let clock = ManualClock()
        let started = Gate()
        let fixture = try await makeFixture(binding(MCPWindowToolName.readFile) { _ in
            await started.open()
            try await waitForCancellation()
            return .string("unreachable")
        })
        let pipeline = fixture.pipeline(
            limiters: MCPDomainInvocationPipeline.makeConnectionLimiters(),
            environment: clock.environment
        )

        let call = Task { await pipeline.execute(fixture.invocation(MCPWindowToolName.readFile)) }
        await started.wait()
        await clock.waitForSleeper(target: Self.boundedDeadline)
        clock.advance(by: Self.boundedDeadline)

        let outcome = await call.value
        let failure = try XCTUnwrap(failure(of: outcome))
        XCTAssertEqual(failure.code, "tool_execution_timeout")
        XCTAssertEqual(failure.retryability, .retryable, "an interrupted read has no side effect")
        XCTAssertEqual(failure.settlement, MCPToolExecutionSettlement.cancellation.rawValue)
        XCTAssertEqual(failure.metadata["retryable"], .bool(true))
        let snapshot = await fixture.runtime.domainHost.snapshot()
        XCTAssertEqual(snapshot.activeResourceAdmissionLeaseCount, 0)
        XCTAssertEqual(snapshot.activeInvocationCount, 0)
    }

    func testCleanupUnresponsiveMutationIsIndeterminateAndKeepsItsResourceUntilSettled() async throws {
        let clock = ManualClock()
        let started = Gate()
        let release = Gate()
        let fixture = try await makeFixture(binding(MCPWindowToolName.manageSelection) { _ in
            await started.open()
            await release.wait() // ignores cancellation
            return .string("late")
        })
        let pipeline = fixture.pipeline(
            limiters: MCPDomainInvocationPipeline.makeConnectionLimiters(),
            environment: clock.environment
        )

        let call = Task { await pipeline.execute(fixture.invocation(MCPWindowToolName.manageSelection)) }
        await started.wait()
        await clock.waitForSleeper(target: Self.boundedDeadline)
        clock.advance(by: Self.boundedDeadline)
        await clock.waitForSleeper(
            target: Self.boundedDeadline + Self.boundedGrace
        )
        clock.advance(by: Self.boundedGrace)

        let outcome = await call.value
        let failure = try XCTUnwrap(failure(of: outcome))
        XCTAssertEqual(failure.code, "tool_execution_cleanup_unresponsive")
        XCTAssertEqual(failure.retryability, .indeterminate, "a mutation that ignored cancellation may still apply")
        XCTAssertEqual(failure.metadata["retryable"], .bool(false))

        let host = fixture.runtime.domainHost
        let reserved = await host.snapshot()
        XCTAssertEqual(reserved.activeResourceAdmissionLeaseCount, 1, "the runaway provider keeps its resource")
        XCTAssertEqual(reserved.activeInvocationCount, 1)

        await release.open()
        try await eventually {
            let snapshot = await host.snapshot()
            return snapshot.activeResourceAdmissionLeaseCount == 0 && snapshot.activeInvocationCount == 0
        }
    }

    func testPolicyDenialIsTypedAndNeverEntersTheProvider() async throws {
        let tracker = ConcurrencyTracker()
        let fixture = try await makeFixture(binding(MCPWindowToolName.readFile) { _ in
            await tracker.enter()
            return .string("read")
        })
        let pipeline = fixture.pipeline(limiters: MCPDomainInvocationPipeline.makeConnectionLimiters())
        let denied = await pipeline.execute(fixture.invocation(
            MCPWindowToolName.readFile,
            policy: Fixture.policy(restricted: [MCPWindowToolName.readFile])
        ))
        let failure = try XCTUnwrap(failure(of: denied))
        XCTAssertEqual(failure.code, "tool_policy_denied")
        XCTAssertEqual(failure.retryability, .permanent)
        let entered = await tracker.peak
        XCTAssertEqual(entered, 0)
    }

    func testProviderErrorsAreClassifiedFromMutationSettlement() {
        struct ProviderFailure: Error {}
        let notApplied = DomainProtectedMutationSettlement(state: .notApplied, operationID: "op-1")
        let unknown = DomainProtectedMutationSettlement(state: .unknown, operationID: "op-2")

        let rejected = MCPDomainToolFailureClassifier.classify(
            ProviderFailure(),
            toolName: MCPWindowToolName.applyEdits,
            admissionClass: .exclusive,
            contract: nil,
            mutation: notApplied
        )
        XCTAssertEqual(rejected.code, "tool_execution_failed")
        XCTAssertEqual(rejected.retryability, .permanent)
        XCTAssertEqual(rejected.mutationState, "not_applied")
        XCTAssertEqual(rejected.operationID, "op-1")

        let uncertain = MCPDomainToolFailureClassifier.classify(
            ProviderFailure(),
            toolName: MCPWindowToolName.applyEdits,
            admissionClass: .exclusive,
            contract: nil,
            mutation: unknown
        )
        XCTAssertEqual(uncertain.retryability, .indeterminate)

        let committed = MCPDomainToolFailureClassifier.classify(
            DomainProtectedMutationError.partialSuccessAfterCommit(operationID: "op-3"),
            toolName: MCPWindowToolName.fileActions,
            admissionClass: .exclusive,
            contract: nil,
            mutation: nil
        )
        XCTAssertEqual(committed.code, "protected_mutation_indeterminate_after_commit")
        XCTAssertEqual(committed.retryability, .indeterminate)
        XCTAssertEqual(committed.mutationState, "indeterminate_after_commit")
        XCTAssertEqual(committed.operationID, "op-3")

        let cancelledMutation = MCPDomainToolFailureClassifier.classify(
            CancellationError(),
            toolName: MCPWindowToolName.manageSelection,
            admissionClass: .exclusive,
            contract: nil,
            mutation: nil
        )
        XCTAssertEqual(cancelledMutation.code, "tool_execution_cancelled")
        XCTAssertEqual(cancelledMutation.retryability, .indeterminate)

        let invalid = MCPDomainToolFailureClassifier.classify(
            MCPError.invalidParams("missing path"),
            toolName: MCPWindowToolName.readFile,
            admissionClass: .fileRead,
            contract: nil,
            mutation: nil
        )
        XCTAssertEqual(invalid.code, "invalid_params")
        XCTAssertEqual(invalid.retryability, .permanent)
        XCTAssertTrue(invalid.renderedText.hasPrefix("invalid_params: missing path\n"))

        let draining = MCPDomainToolFailureClassifier.classify(
            MCPDomainHostError.draining,
            toolName: MCPWindowToolName.readFile,
            admissionClass: .fileRead,
            contract: nil,
            mutation: nil
        )
        XCTAssertEqual(draining.retryability, .retryable)
    }

    // MARK: - Fixture

    /// read_file and manage_selection share the default bounded contract; take its timings from
    /// the domain catalog rather than restating them.
    private static var boundedDeadline: Duration {
        MCPToolExecutionContractCatalog.contract(for: MCPWindowToolName.readFile)?.deadline ?? .zero
    }

    private static var boundedGrace: Duration {
        MCPToolExecutionContractCatalog.contract(for: MCPWindowToolName.readFile)?.cancellationGrace ?? .zero
    }

    private struct Fixture {
        let runtime: MCPDomainRuntime
        let scopeID: DomainStandaloneScopeID
        let connection: DomainConnectionRegistration

        static func policy(restricted: Set<String> = []) -> MCPDomainClientPolicySnapshot {
            MCPDomainClientPolicySnapshot(
                restrictedToolNames: restricted,
                additionalToolNames: [],
                role: .direct,
                allowsAgentExternalControlTools: false
            )
        }

        func registerConnection() async throws -> DomainConnectionRegistration {
            let connectionID = UUID()
            _ = await runtime.routingCoordinator.registerConnection(
                connectionID: connectionID,
                operationID: UUID()
            )
            return try await runtime.routingCoordinator.currentRegistration(connectionID: connectionID)
        }

        func pipeline(
            limiters: MCPDomainConnectionCallLimiters,
            environment: MCPToolExecutionWatchdogEnvironment? = nil
        ) -> MCPDomainInvocationPipeline {
            MCPDomainInvocationPipeline(
                host: runtime.domainHost,
                limiters: limiters,
                watchdogEnvironment: { environment ?? .continuous() }
            )
        }

        func invocation(
            _ toolName: String,
            connection: DomainConnectionRegistration? = nil,
            policy: MCPDomainClientPolicySnapshot = Fixture.policy()
        ) -> MCPDomainInvocationPipeline.Invocation {
            let connection = connection ?? self.connection
            let identity = runtime.identity
            return MCPDomainInvocationPipeline.Invocation(
                toolName: toolName,
                arguments: [:],
                scope: .standalone(id: scopeID),
                policy: policy,
                resource: .standaloneScope(scopeID.rawValue),
                makeHostInvocation: { resolution in
                    let invocationID = UUID()
                    return MCPDomainHostInvocation(
                        invocationID: invocationID,
                        connectionID: connection.connectionID,
                        resolution: resolution,
                        arguments: [:],
                        securityContext: DomainToolInvocationSecurityContext(
                            principal: DomainClientPrincipal(
                                principalID: connection.connectionID,
                                stableKey: "pipeline-test",
                                displayName: "Pipeline Test",
                                kind: .directStdio,
                                assurance: .verifiedProcess,
                                processID: 42,
                                runID: nil,
                                provider: nil,
                                verifiedIdentityFingerprint: "fixture"
                            ),
                            connectionID: connection.connectionID,
                            connectionGeneration: connection.generation,
                            invocationID: invocationID,
                            runtimeID: identity.runtimeID,
                            runtimeGeneration: identity.lifecycleGeneration,
                            hasAuthoritativeRoutingContext: false,
                            ephemeralGrantedToolNames: []
                        )
                    )
                }
            )
        }
    }

    private func makeFixture(_ binding: MCPDomainToolBinding) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-domain-pipeline-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let runtime = MCPDomainRuntime(configuration: .init(
            mode: .standalone,
            profileIdentifier: "pipeline-test",
            storageDirectory: directory,
            eventDirectory: directory,
            temporaryDirectory: directory,
            externalReloadInterval: nil,
            hostDrainTimeout: .milliseconds(25)
        ))
        try await runtime.start()
        let scopeID = DomainStandaloneScopeID()
        _ = try await runtime.toolRegistry.register(
            registrationID: MCPDomainToolRegistrationID(),
            scope: .standalone(id: scopeID),
            bindings: [binding]
        )
        let connectionID = UUID()
        _ = await runtime.routingCoordinator.registerConnection(connectionID: connectionID, operationID: UUID())
        let connection = try await runtime.routingCoordinator.currentRegistration(connectionID: connectionID)
        return Fixture(runtime: runtime, scopeID: scopeID, connection: connection)
    }

    private func binding(
        _ toolName: String,
        operation: @Sendable @escaping ([String: Value]) async throws -> Value
    ) -> MCPDomainToolBinding {
        MCPDomainToolBinding(
            definition: MCPDomainToolDefinition(
                name: toolName,
                description: "pipeline fixture",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])
            ),
            operation: operation
        )
    }

    private func failure(of result: Result<Value, MCPDomainToolFailure>) -> MCPDomainToolFailure? {
        if case let .failure(failure) = result { return failure }
        XCTFail("Expected a typed failure, got \(result)")
        return nil
    }

    /// Bounded cooperative wait for actor-owned state that exposes no completion signal.
    private func eventually(
        iterations: Int = 100_000,
        _ condition: @Sendable () async -> Bool
    ) async throws {
        for _ in 0 ..< iterations {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Condition was not reached")
        throw CancellationError()
    }
}

// MARK: - Helpers

private func waitForCancellation() async throws {
    let gate = Gate()
    try await withTaskCancellationHandler {
        await gate.wait()
        throw CancellationError()
    } onCancel: {
        Task { await gate.open() }
    }
}

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let waiters = waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor ConcurrencyTracker {
    private var active = 0
    private(set) var peak = 0
    private var activeWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func enter() {
        active += 1
        peak = max(peak, active)
        let ready = activeWaiters.filter { active >= $0.0 }
        activeWaiters.removeAll { active >= $0.0 }
        ready.forEach { $0.1.resume() }
    }

    func leave() {
        active -= 1
    }

    func waitUntilActive(_ count: Int) async {
        guard active < count else { return }
        await withCheckedContinuation { activeWaiters.append((count, $0)) }
    }
}

/// Virtual clock for the watchdog environment. `sleep` suspends until `advance` passes its target.
private final class ManualClock: @unchecked Sendable {
    private struct Sleeper {
        let target: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var current: Duration = .zero
    private var sleepers: [UUID: Sleeper] = [:]
    private var targetWaiters: [(Duration, CheckedContinuation<Void, Never>)] = []

    var environment: MCPToolExecutionWatchdogEnvironment {
        MCPToolExecutionWatchdogEnvironment(
            now: { [self] in now() },
            sleep: { [self] duration in try await sleep(duration) }
        )
    }

    func now() -> Duration {
        lock.withLock { current }
    }

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                enum Registration { case registered, due, cancelled }
                var ready: [CheckedContinuation<Void, Never>] = []
                let registration: Registration = lock.withLock {
                    if Task.isCancelled { return .cancelled }
                    let target = current + duration
                    if target <= current { return .due }
                    sleepers[id] = Sleeper(target: target, continuation: continuation)
                    ready = targetWaiters.filter { $0.0 == target }.map(\.1)
                    targetWaiters.removeAll { $0.0 == target }
                    return .registered
                }
                ready.forEach { $0.resume() }
                switch registration {
                case .registered:
                    break
                case .due:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let sleeper = lock.withLock { sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Suspends until a live sleeper with exactly `target` is registered.
    func waitForSleeper(target: Duration) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyRegistered = lock.withLock {
                if sleepers.values.contains(where: { $0.target == target }) { return true }
                targetWaiters.append((target, continuation))
                return false
            }
            if alreadyRegistered { continuation.resume() }
        }
    }

    func advance(by duration: Duration) {
        let due: [Sleeper] = lock.withLock {
            current += duration
            let due = sleepers.filter { $0.value.target <= current }
            for id in due.keys {
                sleepers.removeValue(forKey: id)
            }
            return Array(due.values)
        }
        due.forEach { $0.continuation.resume() }
    }
}
