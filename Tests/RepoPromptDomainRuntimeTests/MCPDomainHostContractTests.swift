import Foundation
import MCP
@testable import RepoPromptDomainRuntime
import XCTest

/// Deterministic contracts for `MCPDomainHost` fencing, cancellation, and drain. Restores the
/// coverage removed in #908 that the M8 invocation pipeline depends on; no timing assertions.
final class MCPDomainHostContractTests: XCTestCase {
    func testInvokesExactRegisteredBindingAndLeavesNoActiveState() async throws {
        let fixture = try await makeFixture(binding { arguments in arguments["path"] ?? .string("none") })
        let value = try await fixture.invoke(arguments: ["path": .string("README.md")])
        XCTAssertEqual(value.stringValue, "README.md")
        let snapshot = await fixture.runtime.domainHost.snapshot()
        XCTAssertEqual(snapshot.lifecycle, .accepting)
        XCTAssertEqual(snapshot.activeInvocationCount, 0)
        XCTAssertEqual(snapshot.connectionsWithActiveInvocationsCount, 0)
    }

    func testStaleResolutionIsRejectedAfterReregistration() async throws {
        let fixture = try await makeFixture(binding { _ in .string("original") })
        let stale = try await fixture.resolve()
        _ = try await fixture.runtime.toolRegistry.registerWithResult(
            registrationID: fixture.registrationID,
            scope: fixture.scope,
            bindings: [binding(description: "replacement") { _ in .string("replacement") }]
        )
        do {
            _ = try await fixture.invoke(resolution: stale)
            XCTFail("A stale resolution invoked the replacement binding")
        } catch let error as MCPDomainHostError {
            XCTAssertEqual(error, .staleRegistration(toolName: MCPWindowToolName.readFile))
        }
    }

    func testRuntimeGenerationMismatchIsRejectedBeforeProviderEntry() async throws {
        let entered = Flag()
        let fixture = try await makeFixture(binding { _ in
            await entered.set()
            return .string("entered")
        })
        do {
            _ = try await fixture.invoke(runtimeGeneration: fixture.runtime.identity.lifecycleGeneration + 1)
            XCTFail("A foreign runtime generation was admitted")
        } catch let error as MCPDomainHostError {
            XCTAssertEqual(error, .runtimeGenerationMismatch)
        }
        let didEnter = await entered.value
        XCTAssertFalse(didEnter)
    }

    func testConnectionCancellationSettlesInFlightWorkAndFencesThatGeneration() async throws {
        let started = Gate()
        let fixture = try await makeFixture(binding { _ in
            await started.open()
            try await waitForCancellation()
            return .string("unreachable")
        })
        let host = fixture.runtime.domainHost
        let inFlight = Task { try await fixture.invoke() }
        await started.wait()

        await host.cancelInvocations(
            connectionID: fixture.connection.connectionID,
            connectionGeneration: fixture.connection.generation
        )
        do {
            _ = try await inFlight.value
            XCTFail("Cancelled work returned a value")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }

        do {
            _ = try await fixture.invoke()
            XCTFail("The terminal generation admitted new work")
        } catch let error as MCPDomainHostError {
            XCTAssertEqual(error, .connectionRegistrationInvalid)
        }
        let fenced = await host.snapshot()
        XCTAssertEqual(fenced.activeInvocationCount, 0)
        XCTAssertEqual(fenced.terminalConnectionFenceCount, 1)

        await host.releaseConnection(
            connectionID: fixture.connection.connectionID,
            connectionGeneration: fixture.connection.generation
        )
        let released = await host.snapshot()
        XCTAssertEqual(released.terminalConnectionFenceCount, 0, "release prunes a settled fence")
    }

    func testDrainRejectsNewWorkAndAccountsForUncooperativeProviders() async throws {
        let started = Gate()
        let release = Gate()
        let fixture = try await makeFixture(binding { _ in
            await started.open()
            await release.wait() // ignores cancellation
            return .string("late")
        })
        let host = fixture.runtime.domainHost
        let inFlight = Task { try await fixture.invoke() }
        await started.wait()

        let result = await host.drain(timeout: .milliseconds(20))
        XCTAssertTrue(result.deadlineExpired)
        XCTAssertFalse(result.callerCancelled)
        XCTAssertEqual(result.detachedInvocationCount, 1)
        let draining = await host.snapshot()
        XCTAssertEqual(draining.lifecycle, .draining)

        do {
            _ = try await fixture.invoke()
            XCTFail("A draining host admitted new work")
        } catch let error as MCPDomainHostError {
            XCTAssertEqual(error, .draining)
        }

        await release.open()
        _ = try? await inFlight.value
        let drained = await host.snapshot()
        XCTAssertEqual(drained.lifecycle, .drained, "the detached provider settling completes the drain")
        XCTAssertEqual(drained.activeInvocationCount, 0)
    }

    func testDrainClosesResourceAdmission() async throws {
        let fixture = try await makeFixture(binding { _ in .string("ok") })
        let host = fixture.runtime.domainHost
        _ = await host.drain(timeout: .milliseconds(1))
        do {
            _ = try await host.acquireResourceAdmission(for: .exclusive, resource: .appWide)
            XCTFail("A drained host granted a resource lease")
        } catch let error as MCPDomainHostError {
            XCTAssertEqual(error, .draining)
        }
    }

    // MARK: - Fixture

    private struct Fixture {
        let runtime: MCPDomainRuntime
        let registrationID: MCPDomainToolRegistrationID
        let scope: MCPDomainToolRegistrationScope
        let connection: DomainConnectionRegistration

        func resolve() async throws -> MCPDomainHostResolution {
            try await runtime.domainHost.resolve(toolName: MCPWindowToolName.readFile, scope: scope)
        }

        func invoke(
            resolution: MCPDomainHostResolution? = nil,
            arguments: [String: Value] = [:],
            runtimeGeneration: UInt64? = nil
        ) async throws -> Value {
            let resolved: MCPDomainHostResolution = if let resolution {
                resolution
            } else {
                try await resolve()
            }
            let invocationID = UUID()
            return try await runtime.domainHost.invoke(MCPDomainHostInvocation(
                invocationID: invocationID,
                connectionID: connection.connectionID,
                resolution: resolved,
                arguments: arguments,
                securityContext: DomainToolInvocationSecurityContext(
                    principal: DomainClientPrincipal(
                        principalID: connection.connectionID,
                        stableKey: "host-contract",
                        displayName: "Host Contract",
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
                    runtimeID: runtime.identity.runtimeID,
                    runtimeGeneration: runtimeGeneration ?? runtime.identity.lifecycleGeneration,
                    hasAuthoritativeRoutingContext: false,
                    ephemeralGrantedToolNames: []
                )
            ))
        }
    }

    private func makeFixture(_ binding: MCPDomainToolBinding) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-domain-host-contract-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let runtime = MCPDomainRuntime(configuration: .init(
            mode: .standalone,
            profileIdentifier: "host-contract",
            storageDirectory: directory,
            eventDirectory: directory,
            temporaryDirectory: directory,
            externalReloadInterval: nil,
            hostDrainTimeout: .milliseconds(25)
        ))
        try await runtime.start()
        let registrationID = MCPDomainToolRegistrationID()
        let scope = MCPDomainToolRegistrationScope.standalone(id: DomainStandaloneScopeID())
        _ = try await runtime.toolRegistry.register(registrationID: registrationID, scope: scope, bindings: [binding])
        let connectionID = UUID()
        _ = await runtime.routingCoordinator.registerConnection(connectionID: connectionID, operationID: UUID())
        let connection = try await runtime.routingCoordinator.currentRegistration(connectionID: connectionID)
        return Fixture(runtime: runtime, registrationID: registrationID, scope: scope, connection: connection)
    }

    private func binding(
        description: String = "host contract fixture",
        operation: @Sendable @escaping ([String: Value]) async throws -> Value
    ) -> MCPDomainToolBinding {
        MCPDomainToolBinding(
            definition: MCPDomainToolDefinition(
                name: MCPWindowToolName.readFile,
                description: description,
                inputSchema: .object(["type": .string("object"), "properties": .object([:])])
            ),
            operation: operation
        )
    }
}

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

private actor Flag {
    private(set) var value = false

    func set() {
        value = true
    }
}
