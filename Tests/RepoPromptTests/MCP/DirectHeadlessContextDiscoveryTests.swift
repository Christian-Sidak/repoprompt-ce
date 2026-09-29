import Foundation
import MCP
import RepoPromptDomainRuntime
@testable import RepoPromptMCP
import XCTest

/// End-to-end M17 coverage for direct-headless Context Builder discovery: raw instructions run
/// through a fake `codex` that plays the discovery model and the Oracle lanes, over a real bound
/// workspace, durable pack store, compare-and-set commit, and the existing Oracle routes.
final class DirectHeadlessContextDiscoveryTests: XCTestCase {
    func testRawInstructionsDiscoverCommitAndFeedOneFrozenPackToGroupedOracles() async throws {
        let fixture = try Fixture(name: "grouped", discovery: true)
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        XCTAssertNotNil(prepared.contextDiscovery)
        try await Self.setRoster(prepared, primary: "lane-0", additional: ["lane-1"])
        let backend = Self.backend(prepared)
        let before = try await prepared.context.snapshot(connectionID: prepared.connectionID)
        let feature = try XCTUnwrap(before.roots.first).path + "/Sources/Feature.swift"
        let featureBytes = try Data(contentsOf: URL(fileURLWithPath: feature))

        let result = try await invoke(
            prepared: prepared,
            backend: backend,
            arguments: [
                "instructions": .string("Where is the feature marker?"),
                "response_type": .string("plan")
            ]
        )

        // Discovery result.
        XCTAssertEqual(result["selection"] as? [String], [feature])
        XCTAssertEqual(result["selected_paths"] as? [String], ["Sources/Feature.swift"])
        XCTAssertEqual(result["prompt"] as? String, "Explain the feature marker.")
        XCTAssertEqual(result["selection_committed"] as? Bool, true)
        XCTAssertEqual(result["context_id"] as? String, before.identity.contextID.uuidString)
        let discovery = try XCTUnwrap(result["discovery"] as? [String: Any])
        XCTAssertEqual(discovery["turns"] as? Int, 2)
        XCTAssertEqual(discovery["tool_calls"] as? Int, 3)
        XCTAssertEqual(discovery["refused_tool_calls"] as? Int, 1)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: feature)), featureBytes, "apply_edits was refused")

        // The bound context now holds exactly the discovered selection.
        let after = try await prepared.context.snapshot(connectionID: prepared.connectionID)
        XCTAssertEqual(after.selection, [feature])
        XCTAssertEqual(after.prompt, before.prompt)
        XCTAssertGreaterThan(after.context.revisions.workingRevision, before.context.revisions.workingRevision)

        // One canonical durable pack, consumed by the grouped Oracle turn.
        let reference = try OracleFrozenPackReference(rawValue: XCTUnwrap(result["context_pack_ref"] as? String))
        let data = try await prepared.oracleStore.loadArtifact(id: reference.artifactID)
        let pack = try OracleFrozenContextPack.decodeCanonical(data)
        XCTAssertEqual(pack.mode, .plan)
        XCTAssertEqual(pack.provenance, [OracleEvidenceReference(path: "Sources/Feature.swift")])
        XCTAssertTrue(pack.content.contains("FEATURE_MARKER"))
        XCTAssertEqual(result["oracle_count"] as? Int, 2)
        let lanes = try XCTUnwrap(result["oracle_results"] as? [[String: Any]])
        XCTAssertEqual(lanes.compactMap { $0["response"] as? String }, ["oracle-0-lane-0-pack", "oracle-1-lane-1-pack"])
        let owner = try OracleConversationOwner(kind: "direct-headless", identifier: fixture.profileName)
        guard case let .group(group)? = try await prepared.oracleStore.loadMostRecentConversation(owner: owner) else {
            return XCTFail("Expected a durable Oracle group")
        }
        let turnInput = try XCTUnwrap(group.turns.last?.input)
        XCTAssertEqual(turnInput.context?.content, .durableArtifact(id: reference.artifactID))
        XCTAssertEqual(turnInput.userMessage, pack.content)
        XCTAssertEqual(group.name, "Where is the feature marker?")

        // Discovery turns: read-only sandbox, discovery model, and no child-launch carrier.
        let calls = try fixture.calls()
        let discoveryCalls = calls.filter { $0.kind == "discovery" }
        XCTAssertEqual(discoveryCalls.count, 2)
        XCTAssertTrue(discoveryCalls.allSatisfy { $0.sandbox == "read-only" && $0.launchID == nil && $0.model == "lane-0" })
        let oracleCalls = calls.filter { $0.kind == "oracle" }
        XCTAssertEqual(Set(oracleCalls.map(\.lane)), ["0", "1"])
        XCTAssertTrue(oracleCalls.allSatisfy { $0.launchID != nil })
        for call in oracleCalls {
            XCTAssertEqual(try fixture.input(of: call), pack.content.trimmingCharacters(in: .newlines))
        }
    }

    func testClarifyDiscoversWithoutOracleAndItsPackFeedsALaterGroupedRequest() async throws {
        let fixture = try Fixture(name: "clarify", discovery: true)
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        try await Self.setRoster(prepared, primary: "lane-0", additional: ["lane-1"])
        let backend = Self.backend(prepared)

        let clarified = try await invoke(
            prepared: prepared,
            backend: backend,
            arguments: [
                "instructions": .string("Find the feature"),
                "response_type": .string("clarify")
            ]
        )
        XCTAssertNil(clarified["chat_id"])
        XCTAssertNil(clarified["oracle_count"])
        XCTAssertEqual(clarified["response_type"] as? String, "clarify")
        XCTAssertEqual(clarified["file_count"] as? Int, 1)
        var calls = try fixture.calls()
        XCTAssertEqual(calls.map(\.kind), ["discovery", "discovery"], "clarify runs only the roster primary's discovery")
        let reference = try XCTUnwrap(clarified["context_pack_ref"] as? String)

        let grouped = try await invoke(
            prepared: prepared,
            backend: backend,
            arguments: ["context_pack_ref": .string(reference)]
        )
        XCTAssertEqual(grouped["oracle_count"] as? Int, 2)
        let lanes = try XCTUnwrap(grouped["oracle_results"] as? [[String: Any]])
        XCTAssertEqual(lanes.compactMap { $0["response"] as? String }, ["oracle-0-lane-0-pack", "oracle-1-lane-1-pack"])
        calls = try fixture.calls()
        XCTAssertEqual(calls.count(where: { $0.kind == "discovery" }), 2, "a pack reference never rediscovers")
    }

    func testSingleOracleQuestionSendsThePackToADirectConversation() async throws {
        let fixture = try Fixture(name: "single", discovery: true)
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        let backend = Self.backend(prepared)

        let result = try await invoke(
            prepared: prepared,
            backend: backend,
            arguments: [
                "instructions": .string("What does Feature hold?"),
                "response_type": .string("question")
            ]
        )

        XCTAssertNotNil(result["chat_id"] as? String)
        XCTAssertEqual(result["response"] as? String, "oracle-none-default-pack")
        XCTAssertEqual(result["selected_paths"] as? [String], ["Sources/Feature.swift"])
        let calls = try fixture.calls()
        XCTAssertEqual(calls.map(\.kind), ["discovery", "discovery", "oracle"])
        XCTAssertNil(calls[0].launchID)
        XCTAssertNotNil(calls[2].launchID, "the direct Oracle keeps its prepared carrier")
        XCTAssertEqual(calls[2].sandbox, "workspace-write", "the direct Oracle purpose is unchanged")
    }

    func testWithoutOptInRawInstructionContractsAreUnchanged() async throws {
        let fixture = try Fixture(name: "opt-out", discovery: false)
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        XCTAssertNil(prepared.contextDiscovery)
        let backend = Self.backend(prepared)
        let before = try await prepared.context.snapshot(connectionID: prepared.connectionID)

        let direct = try await invoke(
            prepared: prepared,
            backend: backend,
            arguments: ["instructions": .string("raw"), "response_type": .string("plan")]
        )
        XCTAssertEqual(direct["response"] as? String, "oracle-none-default-raw")
        XCTAssertNil(direct["context_pack_ref"])

        try await Self.setRoster(prepared, primary: "lane-0", additional: ["lane-1"])
        do {
            _ = try await invoke(prepared: prepared, backend: backend, arguments: ["instructions": .string("raw")])
            XCTFail("Expected context_pack_required")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("context_pack_required"), error.localizedDescription)
        }
        XCTAssertEqual(try fixture.calls().map(\.kind), ["oracle"])
        let after = try await prepared.context.snapshot(connectionID: prepared.connectionID)
        XCTAssertEqual(after.selection, before.selection)
        XCTAssertEqual(after.context.revisions.workingRevision, before.context.revisions.workingRevision)
    }

    func testDiscoveryProviderFailureWritesNoSelectionAndRunsNoOracle() async throws {
        let fixture = try Fixture(name: "provider-failure", discovery: true)
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        try await Self.setRoster(prepared, primary: "discovery-fail", additional: ["lane-1"])
        let backend = Self.backend(prepared)
        let before = try await prepared.context.snapshot(connectionID: prepared.connectionID)

        do {
            _ = try await invoke(
                prepared: prepared,
                backend: backend,
                arguments: ["instructions": .string("Find it"), "response_type": .string("review")]
            )
            XCTFail("Expected the discovery provider failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("discovery_provider_failed:"), error.localizedDescription)
        }

        let calls = try fixture.calls()
        XCTAssertEqual(calls.map(\.kind), ["discovery"])
        let after = try await prepared.context.snapshot(connectionID: prepared.connectionID)
        XCTAssertEqual(after.selection, before.selection)
        XCTAssertEqual(after.context.revisions.workingRevision, before.context.revisions.workingRevision)
        let owner = try OracleConversationOwner(kind: "direct-headless", identifier: fixture.profileName)
        let stored = try await prepared.oracleStore.loadMostRecentConversation(owner: owner)
        XCTAssertNil(stored, "no Oracle group is created when discovery fails")
    }

    func testContextEditedDuringDiscoveryFailsClosedThroughTheBackend() async throws {
        let fixture = try Fixture(name: "stale", discovery: true)
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        try await Self.setRoster(prepared, primary: "gated", additional: [])
        let backend = Self.backend(prepared)
        let before = try await prepared.context.snapshot(connectionID: prepared.connectionID)

        let task = Task {
            try await self.invoke(
                prepared: prepared,
                backend: backend,
                arguments: ["instructions": .string("Find it"), "response_type": .string("question")]
            )
        }
        try await fixture.waitForGate()
        _ = try await prepared.context.mutate(
            request: toolRequest(prepared),
            mutation: .setPrompt("edited while discovery was running")
        )
        fixture.openGate()
        do {
            _ = try await task.value
            XCTFail("Expected the stale context to fail closed")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("discovery_context_changed:"), error.localizedDescription)
        }

        let after = try await prepared.context.snapshot(connectionID: prepared.connectionID)
        XCTAssertEqual(after.selection, before.selection, "no selection was written")
        XCTAssertEqual(after.prompt, "edited while discovery was running")
        XCTAssertEqual(try fixture.calls().map(\.kind), ["discovery", "discovery"], "no Oracle ran")
    }

    func testCancellationDuringADiscoveryTurnDrainsTheProviderAndWritesNothing() async throws {
        let fixture = try Fixture(name: "cancel", discovery: true)
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        try await Self.setRoster(prepared, primary: "gated", additional: ["lane-1"])
        let backend = Self.backend(prepared)
        let before = try await prepared.context.snapshot(connectionID: prepared.connectionID)

        let task = Task {
            try await self.invoke(
                prepared: prepared,
                backend: backend,
                arguments: ["instructions": .string("Find it"), "response_type": .string("plan")]
            )
        }
        try await fixture.waitForGate()
        let blocked = try XCTUnwrap(fixture.calls().last)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }

        let blockedProcessID = try XCTUnwrap(Int32(blocked.processID))
        XCTAssertEqual(kill(blockedProcessID, 0), -1, "the discovery provider process was drained")
        XCTAssertEqual(errno, ESRCH)
        let after = try await prepared.context.snapshot(connectionID: prepared.connectionID)
        XCTAssertEqual(after.selection, before.selection)
        XCTAssertEqual(after.context.revisions.workingRevision, before.context.revisions.workingRevision)
        XCTAssertEqual(try fixture.calls().map(\.kind), ["discovery", "discovery"])
        let owner = try OracleConversationOwner(kind: "direct-headless", identifier: fixture.profileName)
        let stored = try await prepared.oracleStore.loadMostRecentConversation(owner: owner)
        XCTAssertNil(stored)
    }

    func testSelectionCommitIsCompareAndSetAgainstTheFrozenContext() async throws {
        let fixture = try Fixture(name: "cas", discovery: true)
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        // Every call is its own invocation, as in production (the store deduplicates by operation ID).
        let frozen = try await prepared.context.discoverySnapshot(for: toolRequest(prepared))
        let feature = try XCTUnwrap(frozen.roots.first).path + "/Sources/Feature.swift"

        // A concurrent prompt edit moves the context revision: the commit is refused, nothing written.
        _ = try await prepared.context.mutate(
            request: toolRequest(prepared),
            mutation: .setPrompt("edited during discovery")
        )
        do {
            _ = try await prepared.context.commitDiscoveredSelection(
                [feature],
                over: frozen,
                request: toolRequest(prepared)
            )
            XCTFail("Expected a stale-context refusal")
        } catch let error as ContextBuilderDiscoveryError {
            XCTAssertEqual(error.code, "discovery_context_changed")
        }
        var current = try await prepared.context.snapshot(connectionID: prepared.connectionID)
        XCTAssertEqual(current.selection, [])
        XCTAssertEqual(current.prompt, "edited during discovery")

        // Against a fresh freeze the commit applies once; the same selection again is a no-op.
        let refrozen = try await prepared.context.discoverySnapshot(for: toolRequest(prepared))
        let applied = try await prepared.context.commitDiscoveredSelection(
            [feature],
            over: refrozen,
            request: toolRequest(prepared)
        )
        XCTAssertTrue(applied.applied)
        XCTAssertGreaterThan(applied.contextRevision, refrozen.contextRevision)
        current = try await prepared.context.snapshot(connectionID: prepared.connectionID)
        XCTAssertEqual(current.selection, [feature])
        XCTAssertEqual(current.context.revisions.workingRevision, applied.contextRevision)

        let unchangedFreeze = try await prepared.context.discoverySnapshot(for: toolRequest(prepared))
        let unchanged = try await prepared.context.commitDiscoveredSelection(
            [feature],
            over: unchangedFreeze,
            request: toolRequest(prepared)
        )
        XCTAssertFalse(unchanged.applied)
        XCTAssertEqual(unchanged.contextRevision, unchangedFreeze.contextRevision)

        // The superseded freeze stays refused after the commit.
        do {
            _ = try await prepared.context.commitDiscoveredSelection([], over: refrozen, request: toolRequest(prepared))
            XCTFail("Expected a stale-context refusal")
        } catch let error as ContextBuilderDiscoveryError {
            XCTAssertEqual(error.code, "discovery_context_changed")
        }
    }

    // MARK: - M18 post-commit settlement and handoff carriers

    func testCancellationAtThePostCommitHandoffReportsTheCommitAndResumesFromThePack() async throws {
        let fixture = try Fixture(name: "handoff-cancel", discovery: true)
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        try await Self.setRoster(prepared, primary: "lane-0", additional: ["lane-1"])
        let backend = Self.backend(prepared)
        let before = try await prepared.context.snapshot(connectionID: prepared.connectionID)
        let feature = try XCTUnwrap(before.roots.first).path + "/Sources/Feature.swift"
        let security = try await securityContext(prepared)

        // Cancellation lands exactly between the commit and the Oracle step's carriers.
        let task = Task {
            try await self.invoke(
                prepared: prepared,
                backend: backend,
                arguments: ["instructions": .string("Where is the feature marker?"), "response_type": .string("plan")],
                security: security,
                atHandoff: {
                    withUnsafeCurrentTask { $0?.cancel() }
                    try Task.checkCancellation()
                }
            )
        }
        let failure: MCPDomainToolFailure
        do {
            _ = try await task.value
            return XCTFail("Expected the post-commit cancellation to be reported")
        } catch let error as MCPDomainToolFailure {
            failure = error
        }

        XCTAssertEqual(failure.code, "oracle_cancelled_after_discovery")
        XCTAssertEqual(failure.retryability, .indeterminate, "a committed selection is never blindly retryable")
        XCTAssertEqual(failure.mutationState, "applied")
        XCTAssertEqual(failure.operationID, security.invocationID.uuidString)
        XCTAssertEqual(failure.settlement, "discovery_committed")
        XCTAssertEqual(failure.details["status"], .string("oracle_cancelled"))
        XCTAssertEqual(failure.details["selection_committed"], .bool(true))
        XCTAssertEqual(failure.details["selection"], .array([.string(feature)]))
        XCTAssertEqual(failure.details["selected_paths"], .array([.string("Sources/Feature.swift")]))
        guard case let .string(reference)? = failure.details["context_pack_ref"],
              case let .object(resume)? = failure.details["resume"],
              case let .object(resumeArguments)? = resume["arguments"]
        else {
            return XCTFail("Expected the pack reference and a resume request: \(failure.details)")
        }
        XCTAssertEqual(resume["tool"], .string("context_builder"))
        XCTAssertEqual(resumeArguments, ["context_pack_ref": .string(reference), "response_type": .string("plan")])
        XCTAssertTrue(failure.message.contains(reference))
        XCTAssertTrue(failure.renderedText.hasPrefix("oracle_cancelled_after_discovery: "))
        XCTAssertTrue(failure.renderedText.contains(#""mutation_state":"applied""#))

        // What the failure says is what happened: the selection is committed, no Oracle ran.
        let after = try await prepared.context.snapshot(connectionID: prepared.connectionID)
        XCTAssertEqual(after.selection, [feature])
        XCTAssertGreaterThan(after.context.revisions.workingRevision, before.context.revisions.workingRevision)
        XCTAssertEqual(try fixture.calls().map(\.kind), ["discovery", "discovery"])
        let owner = try OracleConversationOwner(kind: "direct-headless", identifier: fixture.profileName)
        let stored = try await prepared.oracleStore.loadMostRecentConversation(owner: owner)
        XCTAssertNil(stored)

        // The resume request reuses the persisted pack without rediscovering.
        let resumed = try await invoke(prepared: prepared, backend: backend, arguments: resumeArguments)
        XCTAssertEqual(resumed["oracle_count"] as? Int, 2)
        let lanes = try XCTUnwrap(resumed["oracle_results"] as? [[String: Any]])
        XCTAssertEqual(lanes.compactMap { $0["response"] as? String }, ["oracle-0-lane-0-pack", "oracle-1-lane-1-pack"])
        XCTAssertEqual(try fixture.calls().count(where: { $0.kind == "discovery" }), 2)
        guard case let .group(group)? = try await prepared.oracleStore.loadMostRecentConversation(owner: owner) else {
            return XCTFail("Expected the resumed Oracle group")
        }
        let artifactID = try OracleFrozenPackReference(rawValue: reference).artifactID
        XCTAssertEqual(group.turns.last?.input.context?.content, .durableArtifact(id: artifactID))
    }

    func testOracleFailureAfterCommitIsTypedWithTheCommittedSelection() async throws {
        let fixture = try Fixture(name: "oracle-failure", discovery: true)
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        try await Self.setRoster(prepared, primary: "oracle-fail", additional: [])
        let backend = Self.backend(prepared)
        let before = try await prepared.context.snapshot(connectionID: prepared.connectionID)
        let feature = try XCTUnwrap(before.roots.first).path + "/Sources/Feature.swift"

        do {
            _ = try await invoke(
                prepared: prepared,
                backend: backend,
                arguments: ["instructions": .string("What does Feature hold?"), "response_type": .string("question")]
            )
            XCTFail("Expected the Oracle failure")
        } catch let failure as MCPDomainToolFailure {
            XCTAssertEqual(failure.code, "oracle_failed_after_discovery")
            XCTAssertEqual(failure.retryability, .indeterminate)
            XCTAssertEqual(failure.mutationState, "applied")
            XCTAssertEqual(failure.details["status"], .string("oracle_failed"))
            XCTAssertEqual(failure.details["selection_committed"], .bool(true))
            XCTAssertNil(failure.details["resume"], "a roster of one has no pack-reference route")
            XCTAssertTrue(failure.message.contains("Replaying the raw instructions"), failure.message)
        }
        let after = try await prepared.context.snapshot(connectionID: prepared.connectionID)
        XCTAssertEqual(after.selection, [feature])
        let calls = try fixture.calls()
        XCTAssertEqual(calls.map(\.kind), ["discovery", "discovery", "oracle"])
        XCTAssertNotNil(calls[2].launchID, "the direct Oracle ran with the carrier prepared at the handoff")
    }

    func testSlowDiscoveryPreparesRedeemableGroupedCarriersAtTheHandoff() async throws {
        let fixture = try Fixture(name: "handoff-carriers", discovery: true)
        defer { fixture.cleanup() }
        defer {
            fixture.openGate()
            fixture.openOracleGate()
        }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        try await Self.setRoster(prepared, primary: "gated", additional: ["lane-1"])
        let backend = Self.backend(prepared)

        // A carrier lifetime shorter than discovery.
        let lifetime = Duration.seconds(3)
        let (wrapped, preparations) = await realHandoffTool(
            prepared: prepared,
            backend: backend,
            carrierLifetime: lifetime
        )
        let security = try await verifiedSecurityContext(prepared)
        let task = Task {
            try await MCPDomainInvocationSecurityContext.$current.withValue(security) {
                try await wrapped(["instructions": .string("Where is the feature marker?"), "response_type": .string("plan")])
            }
        }

        try await fixture.waitForGate()
        let duringDiscovery = await preparations.bundles
        XCTAssertTrue(duringDiscovery.isEmpty, "no carrier exists while discovery runs")
        // Hold discovery past the carrier lifetime: a carrier minted at admission would be expired.
        try await Task.sleep(for: lifetime + .milliseconds(500))
        fixture.openGate()
        try await fixture.waitForOracleGate()

        let blocked = try XCTUnwrap(fixture.calls().first { $0.kind == "oracle" && $0.model == "gated" })
        let redemption = try await prepared.runtime.routingCoordinator.redeemLaunchToken(
            material: XCTUnwrap(blocked.launchToken),
            runtimeID: prepared.runtime.identity.runtimeID,
            runtimeGeneration: prepared.runtime.identity.lifecycleGeneration,
            connectionID: UUID(),
            processID: nil,
            clientPrincipal: XCTUnwrap(blocked.clientPrincipal),
            providerIdentifier: XCTUnwrap(blocked.providerIdentifier)
        )
        guard case .accepted = redemption else {
            return XCTFail("The lane's carrier must be redeemable after a slow discovery, got \(redemption)")
        }
        fixture.openOracleGate()

        let value = try await task.value
        guard case let .object(result) = value else { return XCTFail("Expected an object result") }
        XCTAssertEqual(result["selection_committed"], .bool(true))
        XCTAssertEqual(result["oracle_count"], .int(2))
        let bundles = await preparations.bundles
        XCTAssertEqual(bundles.count, 1, "one single-use preparation, at the handoff")
        let calls = try fixture.calls()
        XCTAssertTrue(calls.filter { $0.kind == "discovery" }.allSatisfy { $0.launchToken == nil })
        let oracleCalls = calls.filter { $0.kind == "oracle" }
        try XCTAssertEqual(
            Set(oracleCalls.compactMap(\.launchID)),
            Set(XCTUnwrap(bundles.first).carriers.map(\.launchID.uuidString))
        )
        // The invocation revoked its carriers when it ended: the unredeemed lane's token is dead.
        let unredeemed = try XCTUnwrap(oracleCalls.first { $0.model == "lane-1" })
        let late = try await prepared.runtime.routingCoordinator.redeemLaunchToken(
            material: XCTUnwrap(unredeemed.launchToken),
            runtimeID: prepared.runtime.identity.runtimeID,
            runtimeGeneration: prepared.runtime.identity.lifecycleGeneration,
            connectionID: UUID(),
            processID: nil,
            clientPrincipal: XCTUnwrap(unredeemed.clientPrincipal),
            providerIdentifier: XCTUnwrap(unredeemed.providerIdentifier)
        )
        if case .accepted = late {
            XCTFail("A carrier must not outlive its invocation")
        }
    }

    // MARK: - M19 handoff pinned to the committed context

    func testRebindBetweenCommitAndHandoffMintsNothingAndReportsTheCommittedContext() async throws {
        let fixture = try Fixture(name: "handoff-rebind", discovery: true)
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        try await Self.setRoster(prepared, primary: "lane-0", additional: ["lane-1"])
        let backend = Self.backend(prepared)
        let committed = try await prepared.context.snapshot(connectionID: prepared.connectionID)
        let other = try await Self.addContext(to: prepared)
        let feature = try XCTUnwrap(committed.roots.first).path + "/Sources/Feature.swift"
        let rebound = BarrierFlag()
        // The barrier lands after the commit, at the handoff, just before the coordinator resolves
        // the connection's context: a concurrent bind_context moves the connection to `other`.
        let (wrapped, preparations) = await realHandoffTool(prepared: prepared, backend: backend) {
            _ = try await prepared.runtime.standaloneScopeCoordinator.bind(scopeID: prepared.scopeID, context: other)
            await rebound.set()
        }
        let security = try await verifiedSecurityContext(prepared)

        let failure: MCPDomainToolFailure
        do {
            _ = try await MCPDomainInvocationSecurityContext.$current.withValue(security) {
                try await wrapped(["instructions": .string("Where is the feature marker?"), "response_type": .string("plan")])
            }
            return XCTFail("A handoff after a rebind must not launch the Oracle")
        } catch let error as MCPDomainToolFailure {
            failure = error
        }
        let barrierRan = await rebound.value
        XCTAssertTrue(barrierRan)

        // Truthful settlement: the commit to the original context stands, no Oracle started.
        XCTAssertEqual(failure.code, "oracle_failed_after_discovery")
        XCTAssertEqual(failure.mutationState, "applied")
        XCTAssertEqual(failure.retryability, .indeterminate)
        XCTAssertEqual(failure.settlement, "discovery_committed")
        XCTAssertEqual(failure.details["status"], .string("oracle_failed"))
        XCTAssertEqual(failure.details["context_id"], .string(committed.identity.contextID.uuidString))
        XCTAssertEqual(failure.details["selection_committed"], .bool(true))
        guard case let .object(handoff)? = failure.details["handoff"] else {
            return XCTFail("Expected the handoff refusal: \(failure.details)")
        }
        XCTAssertEqual(handoff["code"], .string("child_launch_context_changed"))
        XCTAssertEqual(handoff["committed_context_id"], .string(committed.identity.contextID.uuidString))
        XCTAssertNotNil(failure.details["resume"], "the grouped step still resumes from the pack")
        XCTAssertTrue(failure.message.contains("The Oracle step was not started: child_launch_context_changed"), failure.message)
        XCTAssertTrue(failure.message.contains("rebound to context \(other.contextID.uuidString)"), failure.message)
        XCTAssertTrue(failure.message.contains("resume while bound to it"), failure.message)

        // Nothing was minted for either context, and no Oracle ran.
        let bundles = await preparations.bundles
        XCTAssertTrue(bundles.isEmpty)
        let routing = await prepared.runtime.routingCoordinator.snapshot()
        XCTAssertTrue(routing.pendingRunContexts.isEmpty, "no launch token was issued")
        XCTAssertEqual(try fixture.calls().map(\.kind), ["discovery", "discovery"])
        // The selection landed in the context discovery froze, not the one bound now.
        let now = try await prepared.context.snapshot(connectionID: prepared.connectionID)
        XCTAssertEqual(now.identity, other)
        XCTAssertEqual(now.selection, [])
        _ = try await prepared.runtime.standaloneScopeCoordinator.bind(
            scopeID: prepared.scopeID,
            context: committed.identity
        )
        let original = try await prepared.context.snapshot(connectionID: prepared.connectionID)
        XCTAssertEqual(original.selection, [feature])
    }

    func testSameContextRevisionChangeBetweenCommitAndHandoffMintsNothing() async throws {
        let fixture = try Fixture(name: "handoff-revision", discovery: true)
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        try await Self.setRoster(prepared, primary: "lane-0", additional: [])
        let backend = Self.backend(prepared)
        let before = try await prepared.context.snapshot(connectionID: prepared.connectionID)
        let feature = try XCTUnwrap(before.roots.first).path + "/Sources/Feature.swift"
        let editRequest = try await toolRequest(prepared)
        // Same binding, but the committed context is edited between the commit and the handoff.
        let (wrapped, preparations) = await realHandoffTool(prepared: prepared, backend: backend) {
            _ = try await prepared.context.mutate(request: editRequest, mutation: .setPrompt("edited after the commit"))
        }
        let security = try await verifiedSecurityContext(prepared)

        let failure: MCPDomainToolFailure
        do {
            _ = try await MCPDomainInvocationSecurityContext.$current.withValue(security) {
                try await wrapped(["instructions": .string("What does Feature hold?"), "response_type": .string("question")])
            }
            return XCTFail("A handoff after a revision change must not launch the Oracle")
        } catch let error as MCPDomainToolFailure {
            failure = error
        }

        XCTAssertEqual(failure.code, "oracle_failed_after_discovery")
        XCTAssertEqual(failure.mutationState, "applied")
        XCTAssertEqual(failure.retryability, .indeterminate)
        XCTAssertEqual(failure.details["status"], .string("oracle_failed"))
        guard case let .object(handoff)? = failure.details["handoff"],
              case let .int(pinnedRevision)? = handoff["committed_context_revision"]
        else {
            return XCTFail("Expected the handoff refusal: \(failure.details)")
        }
        XCTAssertEqual(handoff["code"], .string("child_launch_context_changed"))
        XCTAssertTrue(failure.message.contains("the context revision moved from \(pinnedRevision) to "), failure.message)
        XCTAssertFalse(failure.message.contains("resume while bound"), "the binding did not change")
        XCTAssertNil(failure.details["resume"], "a roster of one has no pack-reference route")

        let bundles = await preparations.bundles
        XCTAssertTrue(bundles.isEmpty)
        let routing = await prepared.runtime.routingCoordinator.snapshot()
        XCTAssertTrue(routing.pendingRunContexts.isEmpty, "no launch token was issued")
        XCTAssertEqual(try fixture.calls().map(\.kind), ["discovery", "discovery"])
        let after = try await prepared.context.snapshot(connectionID: prepared.connectionID)
        XCTAssertEqual(after.selection, [feature])
        XCTAssertEqual(after.prompt, "edited after the commit")
        XCTAssertGreaterThan(after.context.revisions.workingRevision, UInt64(pinnedRevision))
    }

    func testDiscoveryPurposeAndOptInParsing() {
        XCTAssertEqual(
            DirectHeadlessProviderCoordinator.codexExecArguments(model: "m", purpose: .contextDiscovery),
            ["--model", "m", "exec", "--skip-git-repo-check", "--sandbox", "read-only", "--json", "-"]
        )
        for value in ["1", "true", " YES ", "on"] {
            XCTAssertTrue(DirectHeadlessContextDiscovery.isEnabled(environment: [DirectHeadlessContextDiscovery.environmentKey: value]))
        }
        for value in ["0", "false", "", "discover"] {
            XCTAssertFalse(DirectHeadlessContextDiscovery.isEnabled(environment: [DirectHeadlessContextDiscovery.environmentKey: value]))
        }
        XCTAssertFalse(DirectHeadlessContextDiscovery.isEnabled(environment: [:]))
    }

    // MARK: - Helpers

    private static func backend(_ prepared: DirectHeadlessMCPService.PreparedRuntime) -> DirectHeadlessConversationBackend {
        DirectHeadlessConversationBackend(
            providerCoordinator: prepared.providerCoordinator,
            oracleAdapter: prepared.oracleAdapter,
            contextDiscovery: prepared.contextDiscovery
        )
    }

    /// The real admission path: long-running provider, child-launch coordinator, and routing tokens.
    /// `atHandoff` runs inside the handoff's carrier preparation, after the commit and the policy
    /// revalidation, immediately before the coordinator resolves the context and mints.
    private func realHandoffTool(
        prepared: DirectHeadlessMCPService.PreparedRuntime,
        backend: DirectHeadlessConversationBackend,
        carrierLifetime: Duration = .seconds(60),
        atHandoff: (@Sendable () async throws -> Void)? = nil
    ) async -> (tool: MCPDomainToolBinding, preparations: BundleRecorder) {
        let coordinator = DirectHeadlessChildLaunchCoordinator(carrierLifetime: carrierLifetime)
        await coordinator.configure(
            runtime: prepared.runtime,
            endpointDescriptor: prepared.childEndpoint.socketURL.path,
            oracleAdapter: prepared.oracleAdapter
        )
        let preparations = BundleRecorder()
        let provider = MCPDomainLongRunningToolProvider(
            identity: prepared.runtime.identity,
            policyStore: prepared.runtime.mutationPolicyStore,
            interactionBroker: prepared.runtime.interactionBroker,
            activityCenter: prepared.runtime.activityCenter,
            resolveChildLaunchPlan: { toolName, arguments, security in
                try await coordinator.resolvePlan(toolName: toolName, arguments: arguments, securityContext: security)
            },
            prepareChildLaunches: { plan, toolName, arguments, security, pin in
                XCTAssertNotNil(pin, "discovery prepares only at its pinned handoff")
                try await atHandoff?()
                let bundle = try await coordinator.prepare(
                    plan: plan,
                    toolName: toolName,
                    arguments: arguments,
                    securityContext: security,
                    pinnedTo: pin
                )
                await preparations.record(bundle)
                return bundle
            },
            revokeChildLaunches: { plan, bundle in await coordinator.revoke(plan: plan, bundle: bundle) }
        )
        let binding = MCPDomainToolBinding(
            definition: .init(
                name: "context_builder",
                description: "discovery through the long-running provider",
                inputSchema: .object(["type": .string("object")])
            )
        ) { arguments in
            let request = try DomainPhysicalToolRequest(
                argumentsJSON: JSONEncoder().encode(arguments),
                securityContext: MCPDomainInvocationSecurityContext.current
            )
            let result = try await backend.buildContext(request)
            return try JSONDecoder().decode(Value.self, from: result.json)
        }
        return (provider.wrapping(binding), preparations)
    }

    /// Adds a second context to the bound workspace and returns its identity (the binding is kept).
    private static func addContext(
        to prepared: DirectHeadlessMCPService.PreparedRuntime
    ) async throws -> DomainContextIdentity {
        let current = try await prepared.context.snapshot(connectionID: prepared.connectionID)
        var document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: current.workspace.document.documentBytes) as? [String: Any]
        )
        var contexts = try XCTUnwrap(document["composeTabs"] as? [[String: Any]])
        let contextID = UUID()
        contexts.append(["id": contextID.uuidString, "name": "Other", "prompt": "", "selectedPaths": [String]()])
        document["composeTabs"] = contexts
        let replacement = try DomainWorkspaceDocument.decode(
            documentBytes: JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]),
            fileURL: current.workspace.document.fileURL
        )
        let outcome = await prepared.runtime.workspaceStore.execute(DomainWorkspaceCommandEnvelope(
            operationID: UUID(),
            expectedWorkspaceRevision: current.workspace.revisions.workingRevision,
            origin: .standalone,
            command: .replaceWorkingDocument(replacement)
        ))
        XCTAssertEqual(outcome.disposition, .applied)
        return DomainContextIdentity(workspaceID: current.identity.workspaceID, contextID: contextID)
    }

    private static func setRoster(
        _ prepared: DirectHeadlessMCPService.PreparedRuntime,
        primary: String,
        additional: [String]
    ) async throws {
        _ = try await prepared.settingsStore.set(key: OracleRosterContract.primarySettingKey, value: .string(primary))
        _ = try await prepared.settingsStore.set(
            key: OracleRosterContract.additionalSettingKey,
            value: .stringArray(additional)
        )
    }

    /// Mirrors the long-running provider's carrier contract with synthetic carriers: an ordinary
    /// plan gets its bundle at admission, a `.atHandoff` plan gets only a handoff. `atHandoff`
    /// runs inside the handoff's preparation, before the carriers exist.
    private func invoke(
        prepared: DirectHeadlessMCPService.PreparedRuntime,
        backend: DirectHeadlessConversationBackend,
        arguments: [String: Value],
        security suppliedSecurity: DomainToolInvocationSecurityContext? = nil,
        atHandoff: (@Sendable () async throws -> Void)? = nil
    ) async throws -> [String: Any] {
        let security: DomainToolInvocationSecurityContext = if let suppliedSecurity {
            suppliedSecurity
        } else {
            try await securityContext(prepared)
        }
        let plan = try await prepared.oracleAdapter.resolveChildLaunchPlan(
            toolName: "context_builder",
            arguments: arguments,
            securityContext: security
        )
        let request = try DomainPhysicalToolRequest(
            argumentsJSON: JSONEncoder().encode(arguments),
            securityContext: security
        )
        if plan.preparation == .atHandoff {
            let handoff = DomainChildLaunchHandoff(
                prepare: { _ in
                    try await atHandoff?()
                    return try Self.syntheticBundle(for: plan)
                },
                revokeLate: { _ in }
            )
            let result: DomainPhysicalToolResult
            do {
                result = try await DomainChildLaunchContext.$handoff.withValue(handoff) {
                    try await backend.buildContext(request)
                }
            } catch {
                // As the provider's revocation does when an invocation ends early.
                _ = await handoff.close()
                await prepared.oracleAdapter.discardPreparedInvocation(plan: plan)
                throw error
            }
            _ = await handoff.close()
            return try XCTUnwrap(JSONSerialization.jsonObject(with: result.json) as? [String: Any])
        }
        let bundle = try Self.syntheticBundle(for: plan)
        let result = try await DomainChildLaunchContext.$bundle.withValue(bundle) {
            try await DomainChildLaunchContext.$current.withValue(bundle.singleCarrier) {
                try await backend.buildContext(request)
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: result.json) as? [String: Any])
    }

    private static func syntheticBundle(for plan: DomainChildLaunchPlan) throws -> DomainChildLaunchCarrierBundle {
        let carriers = plan.lanes.map { lane in
            var environment: [String: String] = [
                DomainChildLaunchCarrier.runIDEnvironmentKey: plan.runID.uuidString,
                DomainChildLaunchCarrier.launchIDEnvironmentKey: lane.launchID.uuidString,
                DomainChildLaunchCarrier.providerIdentifierEnvironmentKey: lane.providerIdentifier
            ]
            if let groupID = plan.oracleGroupID {
                environment[DomainChildLaunchCarrier.oracleGroupIDEnvironmentKey] = groupID.rawValue.uuidString
            }
            if let laneID = lane.oracleLaneID {
                environment[DomainChildLaunchCarrier.oracleLaneIDEnvironmentKey] = "\(laneID.index)"
            }
            if let claimID = plan.oracleGroupClaimID {
                environment[DomainChildLaunchCarrier.oracleGroupClaimIDEnvironmentKey] = claimID.uuidString
            }
            return DomainChildLaunchCarrier(
                runID: plan.runID,
                launchID: lane.launchID,
                providerIdentifier: lane.providerIdentifier,
                oracleGroupID: plan.oracleGroupID,
                oracleLaneID: lane.oracleLaneID,
                oracleGroupClaimID: plan.oracleGroupClaimID,
                launchTokenID: UUID(),
                credentialEnvelope: nil,
                environment: environment
            )
        }
        return try DomainChildLaunchCarrierBundle(plan: plan, carriers: carriers)
    }

    private func toolRequest(
        _ prepared: DirectHeadlessMCPService.PreparedRuntime
    ) async throws -> DomainPhysicalToolRequest {
        try await DomainPhysicalToolRequest(
            argumentsJSON: JSONEncoder().encode([String: Value]()),
            securityContext: securityContext(prepared)
        )
    }

    /// A verified run-scoped caller granted `context_builder`, so the long-running provider's
    /// approval admits it.
    private func verifiedSecurityContext(
        _ prepared: DirectHeadlessMCPService.PreparedRuntime
    ) async throws -> DomainToolInvocationSecurityContext {
        let base = try await securityContext(prepared)
        return DomainToolInvocationSecurityContext(
            principal: DomainClientPrincipal(
                principalID: UUID(),
                stableKey: "m18-verified-client",
                displayName: "M18 verified client",
                kind: .runScoped,
                assurance: .verifiedProcess,
                processID: getpid(),
                runID: prepared.principal.runID,
                provider: "direct-stdio",
                verifiedIdentityFingerprint: "m18-fixture",
                claimedProcessID: nil
            ),
            connectionID: base.connectionID,
            connectionGeneration: base.connectionGeneration,
            invocationID: UUID(),
            runtimeID: base.runtimeID,
            runtimeGeneration: base.runtimeGeneration,
            workspaceID: base.workspaceID,
            workspaceRevision: base.workspaceRevision,
            authorizedCanonicalRoots: base.authorizedCanonicalRoots,
            hasAuthoritativeRoutingContext: true,
            ephemeralGrantedToolNames: ["context_builder"],
            ephemeralGrantedOperations: []
        )
    }

    private func securityContext(
        _ prepared: DirectHeadlessMCPService.PreparedRuntime
    ) async throws -> DomainToolInvocationSecurityContext {
        let snapshot = try await prepared.context.snapshot(connectionID: prepared.connectionID)
        return DomainToolInvocationSecurityContext(
            principal: prepared.principal,
            connectionID: prepared.connectionID,
            connectionGeneration: prepared.connectionGeneration,
            invocationID: UUID(),
            runtimeID: prepared.runtime.identity.runtimeID,
            runtimeGeneration: prepared.runtime.identity.lifecycleGeneration,
            workspaceID: snapshot.identity.workspaceID,
            workspaceRevision: snapshot.workspace.revisions.workingRevision,
            authorizedCanonicalRoots: Set(snapshot.roots.map(\.path)),
            hasAuthoritativeRoutingContext: true,
            ephemeralGrantedToolNames: [],
            ephemeralGrantedOperations: []
        )
    }
}

private actor BarrierFlag {
    private(set) var value = false

    func set() {
        value = true
    }
}

private actor BundleRecorder {
    private(set) var bundles: [DomainChildLaunchCarrierBundle] = []

    func record(_ bundle: DomainChildLaunchCarrierBundle) {
        bundles.append(bundle)
    }
}

private struct Fixture {
    struct Call {
        let kind: String
        let lane: String
        let model: String
        let sandbox: String
        let launchID: String?
        let processID: String
        let launchToken: String?
        let clientPrincipal: String?
        let providerIdentifier: String?
    }

    let root: URL
    let profile: URL
    let executable: URL
    let callLog: URL
    let inputs: URL
    let profileName: String
    let discovery: Bool

    init(name: String, discovery: Bool) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-headless-discovery-root-\(name)-\(UUID().uuidString)", isDirectory: true)
        profile = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-headless-discovery-profile-\(name)-\(UUID().uuidString)", isDirectory: true)
        executable = profile.appendingPathComponent("codex-stub")
        callLog = profile.appendingPathComponent("calls.log")
        inputs = profile.appendingPathComponent("inputs", isDirectory: true)
        profileName = "discovery-\(name)"
        self.discovery = discovery
        let manager = FileManager.default
        try manager.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try manager.createDirectory(at: inputs, withIntermediateDirectories: true)
        try Data("struct Feature {\n    let marker = \"FEATURE_MARKER\"\n}\n".utf8)
            .write(to: root.appendingPathComponent("Sources/Feature.swift"))
        try Data("struct Other {}\n".utf8).write(to: root.appendingPathComponent("Sources/Other.swift"))
        let script = #"""
        #!/bin/sh
        model=default
        sandbox=
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --model) shift; model="$1" ;;
            --sandbox) shift; sandbox="$1" ;;
          esac
          shift
        done
        lane="${REPOPROMPT_MCP_ORACLE_LANE_ID:-none}"
        input=$(/bin/cat)
        kind=oracle
        case "$input" in
          *"\#(ContextBuilderDiscoveryPrompt.protocolVersion)"*) kind=discovery ;;
        esac
        /usr/bin/printf '%s' "$input" > '\#(inputs.path)/'"$kind-$lane-$$.txt"
        /usr/bin/printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$kind" "$lane" "$model" "$sandbox" \
          "${REPOPROMPT_MCP_LAUNCH_ID:-}" "$$" "${REPOPROMPT_MCP_LAUNCH_TOKEN:-}" \
          "${REPOPROMPT_MCP_CLIENT_PRINCIPAL:-}" "${REPOPROMPT_MCP_PROVIDER_IDENTIFIER:-}" >> '\#(callLog.path)'
        if [ "$kind" = discovery ]; then
          if [ "$model" = gated ]; then
            case "$input" in
              *'tool="file_search"'*)
                : > '\#(profile.path)/waiting'
                i=0
                while [ ! -f '\#(profile.path)/go' ] && [ "$i" -lt 400 ]; do
                  /bin/sleep 0.05
                  i=$((i + 1))
                done
                ;;
            esac
          fi
          if [ "$model" = discovery-fail ]; then
            /usr/bin/printf '%s\n' 'fake discovery failure' >&2
            exit 7
          fi
          case "$input" in
            *'tool="file_search"'*)
              /usr/bin/printf '%s\n' '{"type":"message","text":"{\"final\":{\"prompt\":\"Explain the feature marker.\"}}"}'
              ;;
            *)
              /usr/bin/printf '%s\n' '{"type":"message","text":"{\"tool_calls\":[{\"tool\":\"file_search\",\"arguments\":{\"pattern\":\"FEATURE_MARKER\",\"mode\":\"content\"}},{\"tool\":\"apply_edits\",\"arguments\":{\"path\":\"Sources/Feature.swift\",\"rewrite\":\"owned\"}},{\"tool\":\"manage_selection\",\"arguments\":{\"op\":\"add\",\"paths\":[\"Sources/Feature.swift\"]}}]}"}'
              ;;
          esac
          exit 0
        fi
        if [ "$model" = gated ]; then
          : > '\#(profile.path)/oracle-waiting'
          i=0
          while [ ! -f '\#(profile.path)/oracle-go' ] && [ "$i" -lt 400 ]; do
            /bin/sleep 0.05
            i=$((i + 1))
          done
        fi
        if [ "$model" = oracle-fail ]; then
          /usr/bin/printf '%s\n' 'fake oracle failure' >&2
          exit 9
        fi
        case "$input" in
          *FEATURE_MARKER*) saw=pack ;;
          *) saw=raw ;;
        esac
        /usr/bin/printf '{"type":"message","text":"oracle-%s-%s-%s"}\n' "$lane" "$model" "$saw"
        """#
        try Data(script.utf8).write(to: executable)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func service() -> DirectHeadlessMCPService {
        var environment = [
            "REPOPROMPT_CODEX_COMMAND": executable.path,
            "REPOPROMPT_MCP_HEADLESS_PROFILE": profileName,
            "REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": profile.path,
            "REPOPROMPT_MCP_WORKING_DIRS": root.path,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""
        ]
        if discovery {
            environment[DirectHeadlessContextDiscovery.environmentKey] = "1"
        }
        return DirectHeadlessMCPService(environment: environment, currentDirectory: root)
    }

    func calls() throws -> [Call] {
        guard FileManager.default.fileExists(atPath: callLog.path) else { return [] }
        return try String(contentsOf: callLog, encoding: .utf8)
            .split(separator: "\n")
            .map { line in
                let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                func optional(_ index: Int) -> String? {
                    fields.indices.contains(index) && !fields[index].isEmpty ? fields[index] : nil
                }
                return Call(
                    kind: fields[0],
                    lane: fields[1],
                    model: fields[2],
                    sandbox: fields[3],
                    launchID: optional(4),
                    processID: fields[5],
                    launchToken: optional(6),
                    clientPrincipal: optional(7),
                    providerIdentifier: optional(8)
                )
            }
    }

    /// Waits until a `gated` discovery provider is blocked in its second turn.
    func waitForGate() async throws {
        let marker = profile.appendingPathComponent("waiting")
        let deadline = ContinuousClock.now + .seconds(15)
        while !FileManager.default.fileExists(atPath: marker.path) {
            guard ContinuousClock.now < deadline else {
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func openGate() {
        FileManager.default.createFile(atPath: profile.appendingPathComponent("go").path, contents: Data())
    }

    /// Waits until a `gated` Oracle lane is blocked.
    func waitForOracleGate() async throws {
        let marker = profile.appendingPathComponent("oracle-waiting")
        let deadline = ContinuousClock.now + .seconds(15)
        while !FileManager.default.fileExists(atPath: marker.path) {
            guard ContinuousClock.now < deadline else {
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func openOracleGate() {
        FileManager.default.createFile(atPath: profile.appendingPathComponent("oracle-go").path, contents: Data())
    }

    func input(of call: Call) throws -> String {
        try String(
            contentsOf: inputs.appendingPathComponent("\(call.kind)-\(call.lane)-\(call.processID).txt"),
            encoding: .utf8
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: profile)
    }
}
