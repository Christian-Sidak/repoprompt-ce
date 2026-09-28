import Foundation
@testable import RepoPromptApp
import XCTest

/// M8Y: a failed or cancelled root registration must not end the root epoch.
///
/// The store cancels a root's in-flight setup when it replaces that root's authority (for example
/// when activation adds a supplemental root and advances the catalog), then relaunches setup for the
/// same, still-loaded root epoch. The engine used to release the Git capability of the cancelled
/// attempt with a `releasedRootEpoch` tombstone, so every relaunch answered terminal
/// `releasedRootEpoch`, then `registrationFailed`, until the store gave up with
/// `graph_retry_exhausted`. Whether that happened depended on whether the store's cleanup reached the
/// engine before the cancelled attempt observed its cancellation; this test pins the losing order.
final class WorkspaceCodemapBindingEngineRegistrationTests: XCTestCase {
    func testCancelledRegistrationDoesNotEndTheRootEpoch() async throws {
        let repository = try ReviewGitRepositoryFixture(name: "binding-engine-registration")
        let rootURL = try repository.makeRepository(named: "root", files: ["src/a.swift": "struct A {}\n"])
        let gate = FirstResolutionGate()
        let fixture = try CodemapStoreFixture(
            name: "binding-engine-registration",
            capabilityHooks: WorkspaceCodemapGitCapabilityServiceHooks(beforeResolution: { await gate.pass() })
        )
        addTeardownBlock {
            await gate.open()
            await fixture.shutdown()
            repository.cleanup()
        }
        let engine = try fixture.runtime().bindingEngine()
        let registration = WorkspaceCodemapBindingRootRegistration(
            rootID: UUID(),
            rootLifetimeID: UUID(),
            loadedRootURL: rootURL,
            catalogGeneration: 1,
            ingressGeneration: 1
        )

        // The attempt is suspended in Git capability resolution when its task is cancelled, and no
        // replacement reached the engine first: the order that used to tombstone the epoch.
        let cancelled = Task { await engine.registerRoot(registration) }
        await gate.waitUntilEntered()
        cancelled.cancel()
        guard case .failed = await cancelled.value else {
            return XCTFail("a cancelled registration attempt fails")
        }
        await gate.open()

        let retried = await engine.registerRoot(registration)
        guard case .registered = retried else {
            return XCTFail("the same, still-loaded root epoch must register after a cancelled attempt, got \(retried)")
        }

        // Unloading still ends the epoch: a later registration of it stays terminally unavailable.
        await engine.unloadRoot(rootEpoch: registration.capabilityRequest.rootEpoch)
        let afterUnload = await engine.registerRoot(registration)
        guard case .unavailable(.terminalUnavailable(.releasedRootEpoch)) = afterUnload else {
            return XCTFail("an unloaded root epoch must stay released, got \(afterUnload)")
        }
    }
}

/// Holds the first Git capability resolution until `open()`; later resolutions pass through.
private actor FirstResolutionGate {
    private var entered = false
    private var isOpen = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        guard !entered else { return }
        entered = true
        for waiter in enteredWaiters {
            waiter.resume()
        }
        enteredWaiters.removeAll()
        guard !isOpen else { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in openWaiters {
            waiter.resume()
        }
        openWaiters.removeAll()
    }
}
