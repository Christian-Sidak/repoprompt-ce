import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

/// The user's management delegation as an authority-owned grant capability.
///
/// Management is the one capability that changes on a live grant, so these tests pin what that
/// change may and may not do: it starts off, it moves only the exact generation it names, it is
/// visible to the observer through the link-set revision and the change feed, and withdrawing it
/// takes effect at the very next fence of an operation already in flight.
final class DomainAgentSessionLinkManagementTests: XCTestCase {
    private enum FixtureError: Error {
        case reservationFailed
        case activationFailed
    }

    // MARK: - Fixtures

    private func makeAuthority() -> DomainAgentSessionLinkAuthority {
        DomainAgentSessionLinkAuthority(
            identity: DomainRuntimeIdentity(
                runtimeID: UUID(),
                lifecycleGeneration: 1,
                processID: 1,
                mode: .app,
                createdAt: Date(timeIntervalSince1970: 0)
            ),
            now: { Date(timeIntervalSince1970: 1000) }
        )
    }

    private func makeEndpoint(windowID: Int) -> DomainAgentSessionLinkEndpointIdentity {
        DomainAgentSessionLinkEndpointIdentity(
            windowID: windowID,
            workspaceID: UUID(),
            tabID: UUID(),
            sessionID: UUID(),
            persistentBindingGeneration: UUID(),
            bindingTransitionGeneration: 1
        )
    }

    private func activateLink(
        _ authority: DomainAgentSessionLinkAuthority,
        observer: DomainAgentSessionLinkEndpointIdentity,
        target: DomainAgentSessionLinkEndpointIdentity
    ) async throws -> DomainAgentSessionLinkGrant {
        guard case let .reserved(pending, _) = await authority.reserveLink(observer: observer, target: target)
        else { throw FixtureError.reservationFailed }
        let activation = await authority.activateLink(
            reservation: pending,
            initialSnapshot: DomainAgentSessionObservationSnapshot(
                sessionID: target.sessionID,
                displayName: "Target",
                providerDisplayName: "Codex CLI",
                status: .running,
                idleForSend: false,
                pendingInteractionKind: nil,
                latestVisibleAssistantPreview: nil,
                visibleRowCount: 1,
                lastActivityAt: Date(timeIntervalSince1970: 500)
            ),
            sourcePublicationSequence: 1
        )
        guard case let .activated(activated) = activation else { throw FixtureError.activationFailed }
        return activated.grant
    }

    private func reference(_ grant: DomainAgentSessionLinkGrant) -> DomainAgentSessionLinkReference {
        DomainAgentSessionLinkReference(linkID: grant.id, generation: grant.generation)
    }

    private static let managementOperations: [DomainAgentSessionTargetOperation] = [
        .monitorGetInteraction, .monitorRespond, .monitorSteer
    ]

    // MARK: - Default

    func testGrantsStartWatchOnlyAndManagementOperationsNeedTheManageCapability() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint(windowID: 1)
        let target = makeEndpoint(windowID: 2)
        let grant = try await activateLink(authority, observer: observer, target: target)

        XCTAssertEqual(grant.capabilities, DomainAgentSessionLinkCapability.version1)
        XCTAssertFalse(grant.capabilities.contains(.manage))
        for operation in Self.managementOperations {
            let lease = await authority.authorize(
                operation: operation,
                observerEndpoint: observer,
                targetSessionID: target.sessionID
            )
            XCTAssertEqual(lease.failureError, .capabilityDenied, operation.rawValue)
        }
        let watch = await authority.authorize(
            operation: .monitorPoll,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        )
        XCTAssertNotNil(try? watch.get(), "the watch grant itself is untouched")
        let inventory = await authority.links(forObserverEndpoint: observer)
        XCTAssertEqual(inventory.items.first?.capabilityNames, ["poll", "read", "send_when_idle", "wait"])
    }

    // MARK: - Grant and withdraw

    func testSetManagementChangesOnlyTheExactGrantAndIsVisibleToTheObserver() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint(windowID: 1)
        let target = makeEndpoint(windowID: 2)
        let otherTarget = makeEndpoint(windowID: 3)
        var events = await authority.changeEvents().makeAsyncIterator()
        let grant = try await activateLink(authority, observer: observer, target: target)
        _ = await events.next()
        let other = try await activateLink(authority, observer: observer, target: otherTarget)
        _ = await events.next()
        let revisionBefore = await authority.observerLinkSetRevision(observer.sessionID)
        let targetRevisionBefore = await authority.targetLinkSetRevision(target.sessionID)

        let granted = await authority.setManagement(
            true,
            reference: reference(grant),
            observer: observer,
            target: target
        )
        guard case let .changed(managedGrant, observerInventory) = granted else {
            return XCTFail("expected a capability change, got \(granted)")
        }
        XCTAssertEqual(managedGrant.id, grant.id)
        XCTAssertEqual(managedGrant.generation, grant.generation, "the link keeps its identity")
        XCTAssertEqual(managedGrant.capabilities, DomainAgentSessionLinkCapability.managed)
        let managedItem = observerInventory.items.first { $0.targetSessionID == target.sessionID }
        let otherItem = observerInventory.items.first { $0.targetSessionID == otherTarget.sessionID }
        XCTAssertEqual(managedItem?.capabilityNames, ["manage", "poll", "read", "send_when_idle", "wait"])
        XCTAssertEqual(otherItem?.capabilities, DomainAgentSessionLinkCapability.version1, "only the named grant")
        XCTAssertEqual(
            observerInventory.linkSetRevision,
            revisionBefore + 1,
            "the observer must be re-told its capabilities, so its link-set revision advances"
        )
        let targetRevisionAfter = await authority.targetLinkSetRevision(target.sessionID)
        XCTAssertEqual(targetRevisionAfter, targetRevisionBefore, "the inbound grant set did not change")

        let event = await events.next()
        XCTAssertEqual(event?.kind, .capabilitiesChanged)
        XCTAssertEqual(event?.linkID, grant.id)
        XCTAssertEqual(event?.observerSessionID, observer.sessionID)
        XCTAssertEqual(event?.targetSessionID, target.sessionID)
        XCTAssertEqual(event?.observerLinkSetRevision, revisionBefore + 1)

        let steer = await authority.authorize(
            operation: .monitorSteer,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        )
        XCTAssertEqual(try steer.get().capability, .manage)
        let otherSteer = await authority.authorize(
            operation: .monitorSteer,
            observerEndpoint: observer,
            targetSessionID: otherTarget.sessionID
        )
        XCTAssertEqual(otherSteer.failureError, .capabilityDenied)

        let repeated = await authority.setManagement(true, reference: reference(grant), observer: observer, target: target)
        guard case .unchanged = repeated else { return XCTFail("expected unchanged, got \(repeated)") }
        let revisionAfterRepeat = await authority.observerLinkSetRevision(observer.sessionID)
        XCTAssertEqual(revisionAfterRepeat, revisionBefore + 1, "a no-op re-owes nothing")

        // Exact addressing: the wrong endpoints or a foreign reference change nothing.
        let wrongTarget = await authority.setManagement(true, reference: reference(other), observer: observer, target: target)
        XCTAssertEqual(wrongTarget, .notFound)
        let wrongObserver = await authority.setManagement(
            false,
            reference: reference(grant),
            observer: makeEndpoint(windowID: 9),
            target: target
        )
        XCTAssertEqual(wrongObserver, .notFound)

        let withdrawn = await authority.setManagement(false, reference: reference(grant), observer: observer, target: target)
        guard case let .changed(watchGrant, _) = withdrawn else { return XCTFail("expected a change, got \(withdrawn)") }
        XCTAssertEqual(watchGrant.capabilities, DomainAgentSessionLinkCapability.version1)
    }

    func testWithdrawingManagementFailsOutstandingLeasesAndTheManagedCommitFence() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint(windowID: 1)
        let target = makeEndpoint(windowID: 2)
        let grant = try await activateLink(authority, observer: observer, target: target)
        _ = await authority.setManagement(true, reference: reference(grant), observer: observer, target: target)

        let respondLease = try await authority.authorize(
            operation: .monitorRespond,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()
        let steerLease = try await authority.authorize(
            operation: .monitorSteer,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()
        let pollLease = try await authority.authorize(
            operation: .monitorPoll,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()
        let respondValid = await authority.validate(lease: respondLease)
        XCTAssertNil(respondValid)

        // A steer reserves in the shared ledger under its management lease.
        guard case let .reserved(reservation) = await authority.beginSend(
            lease: steerLease,
            idempotencyKey: "steer-1",
            messageDigest: "digest"
        ) else { return XCTFail("a management lease may reserve in the ledger") }

        // The user withdraws management while both operations are in flight.
        _ = await authority.setManagement(false, reference: reference(grant), observer: observer, target: target)

        let respondAfter = await authority.validate(lease: respondLease)
        XCTAssertEqual(respondAfter, .capabilityDenied, "the final fence of an in-flight respond now fails")
        let pollAfter = await authority.validate(lease: pollLease)
        XCTAssertNil(pollAfter, "watching is unaffected")
        let commit = await authority.commitSendAuthorization(
            reservation: reservation,
            linkGeneration: reservation.linkGeneration,
            requiresManagement: true
        )
        XCTAssertEqual(commit, .managementRevoked, "a withdrawn delegation delivers nothing")
        let snapshot = await authority.snapshot()
        XCTAssertEqual(snapshot.inFlightSendCount, 0, "the refused reservation is released")

        // Re-granting lets the same key proceed: nothing was delivered under it.
        _ = await authority.setManagement(true, reference: reference(grant), observer: observer, target: target)
        let freshLease = try await authority.authorize(
            operation: .monitorSteer,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()
        let retried = await authority.beginSend(lease: freshLease, idempotencyKey: "steer-1", messageDigest: "digest")
        guard case .reserved = retried else { return XCTFail("expected a fresh reservation, got \(retried)") }

        // An ordinary send commit never consults management.
        let sendLease = try await authority.authorize(
            operation: .monitorSend,
            observerEndpoint: observer,
            targetSessionID: target.sessionID
        ).get()
        _ = await authority.setManagement(false, reference: reference(grant), observer: observer, target: target)
        guard case let .reserved(sendReservation) = await authority.beginSend(
            lease: sendLease,
            idempotencyKey: "send-1",
            messageDigest: "digest"
        ) else { return XCTFail("expected a send reservation") }
        let sendCommit = await authority.commitSendAuthorization(
            reservation: sendReservation,
            linkGeneration: sendReservation.linkGeneration
        )
        XCTAssertEqual(sendCommit, .committed)
    }

    func testRelinkNeverInheritsManagementAndShutdownRefusesChanges() async throws {
        let authority = makeAuthority()
        let observer = makeEndpoint(windowID: 1)
        let target = makeEndpoint(windowID: 2)
        let grant = try await activateLink(authority, observer: observer, target: target)
        _ = await authority.setManagement(true, reference: reference(grant), observer: observer, target: target)
        _ = await authority.revoke(linkID: grant.id, generation: grant.generation, reason: .userRequested)

        let relinked = try await activateLink(authority, observer: observer, target: target)
        XCTAssertNotEqual(reference(relinked), reference(grant))
        XCTAssertEqual(relinked.capabilities, DomainAgentSessionLinkCapability.version1, "a relink is watch-only")
        let stale = await authority.setManagement(true, reference: reference(grant), observer: observer, target: target)
        XCTAssertEqual(stale, .notFound, "a revoked generation can never be managed again")

        await authority.beginDrain()
        let draining = await authority.setManagement(true, reference: reference(relinked), observer: observer, target: target)
        XCTAssertEqual(draining, .shuttingDown)
    }
}

private extension Result where Failure == DomainAgentSessionLinkError {
    var failureError: DomainAgentSessionLinkError? {
        guard case let .failure(error) = self else { return nil }
        return error
    }
}
