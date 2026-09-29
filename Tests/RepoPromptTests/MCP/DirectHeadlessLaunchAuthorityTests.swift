import Darwin
import Foundation
import MCP
import RepoPromptDomainRuntime
@testable import RepoPromptMCP
import XCTest

/// M22: every carrier-bearing direct-headless provider launch (an ordinary agent, a direct Oracle
/// turn, each grouped Oracle lane) runs under one launch-scoped root authority. Its working
/// directory, its child token, and its child's tool roots all derive from that authority; a
/// conflicting change before the launch refuses it, typed, and root mutations are excluded from the
/// launch until its process exited and its in-flight child calls settled.
///
/// Every case runs the real long-running provider, child-launch coordinator, routing tokens, and
/// child admission path, with a fake `codex` that logs its working directory and carrier.
final class DirectHeadlessLaunchAuthorityTests: XCTestCase {
    // MARK: - Ordinary agents

    func testADetachedAgentRunsUnderItsLaunchAuthorityUntilItsProcessExits() async throws {
        let fixture = try LaunchFixture(name: "agent-detached")
        defer { fixture.cleanup() }
        defer { fixture.openGate() }
        let extraRoot = try Self.temporaryDirectory("agent-extra")
        defer { try? FileManager.default.removeItem(at: extraRoot) }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        // A second tab, so closing the agent's context would otherwise be allowed.
        _ = try await Self.addContext(to: prepared)
        let bound = try await prepared.context.snapshot(connectionID: prepared.connectionID)

        let started = try await startAgent(["model": .string("gated"), "detach": .bool(true)], prepared: prepared)
        XCTAssertEqual(started["status"], .string("running"), "a detached start returns while its agent runs")
        let sessionID = try Self.sessionID(started)
        try await fixture.waitForGate()
        let agent = try XCTUnwrap(fixture.calls().first)
        XCTAssertEqual(agent.workingDirectory, fixture.physicalRootPath)
        XCTAssertEqual(agent.runID, sessionID.uuidString)
        XCTAssertEqual(agent.sandbox, "workspace-write")
        XCTAssertEqual(prepared.context.launchRootAuthorityCounts().activeLeases, 1)

        // The start returned, but the token belongs to the running process: its child is admitted
        // and anchored to the launch's context and roots.
        let admitted = try await admitChild(of: agent, service: service, prepared: prepared)
        let child = try XCTUnwrap(admitted, "the running agent's child redeems its token after the start returned")
        let childView = try await prepared.context.snapshot(connectionID: child.connectionID, sessionID: sessionID)
        XCTAssertEqual(childView.identity, bound.identity)
        XCTAssertEqual(childView.roots.map(\.path), bound.roots.map(\.path))

        // Changes that would move the running agent's roots lose to it, typed, and write nothing.
        let addFolder: [String: Value] = ["action": .string("add_folder"), "folder_path": .string(extraRoot.path)]
        let closeBound: [String: Value] = [
            "action": .string("close_tab"),
            "tab": .string(bound.identity.contextID.uuidString),
            "allow_active": .bool(true)
        ]
        for arguments in [addFolder, closeBound] {
            let failure = try await expectFailure { try await self.manageWorkspaces(arguments, prepared: prepared) }
            XCTAssertEqual(failure.code, "root_authority_leased")
            XCTAssertEqual(failure.retryability, .retryable)
            XCTAssertEqual(failure.mutationState, DomainProtectedMutationState.notApplied.rawValue)
            XCTAssertEqual(failure.details["launch_kind"], .string("agent"))
            XCTAssertEqual(failure.details["launch_id"], agent.launchID.map(Value.string))
            XCTAssertEqual(failure.details["run_id"], .string(sessionID.uuidString))
        }
        let during = try await prepared.context.snapshot(connectionID: prepared.connectionID)
        XCTAssertEqual(during.roots.map(\.path), bound.roots.map(\.path), "the refused root was never added")
        XCTAssertEqual(during.workspace.revisions.workingRevision, bound.workspace.revisions.workingRevision)

        // The process exits: the session completes, the authority and its token are released, the
        // child fails closed, and the same change applies.
        fixture.openGate()
        let finished = try await waitForTerminal(sessionID, prepared: prepared)
        XCTAssertEqual(finished.status, .completed)
        XCTAssertEqual(finished.latestAssistantPreview, "reply-none-gated")
        do {
            _ = try await prepared.context.snapshot(connectionID: child.connectionID, sessionID: sessionID)
            XCTFail("A released launch authority must not resolve")
        } catch DirectHeadlessDomainContext.Error.launchRootAuthorityReleased {}
        await assertLaunchRootAuthorityIdle(prepared)
        let added = try await manageWorkspaces(addFolder, prepared: prepared)
        XCTAssertEqual(added["action"], .string("add_folder"))
        await prepared.context.detachLaunchConnection(child.connectionID)
        XCTAssertEqual(prepared.context.launchRootAuthorityCounts().leasedConnections, 0)
    }

    func testARootsChangeInFlightAtAnAgentLaunchRefusesTheStartTypedWithNothingRegistered() async throws {
        let fixture = try LaunchFixture(name: "agent-roots-changing")
        defer { fixture.cleanup() }
        let extraRoot = try Self.temporaryDirectory("agent-changing-root")
        defer { try? FileManager.default.removeItem(at: extraRoot) }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        let bound = try await prepared.context.snapshot(connectionID: prepared.connectionID)
        let atLaunch = LaunchGate()
        let proceed = LaunchGate()
        await prepared.providerCoordinator.installLaunchProbe { _ in
            await atLaunch.open()
            await proceed.wait()
        }
        let start = Task {
            try await self.startAgent(["model": .string("gated"), "detach": .bool(true)], prepared: prepared)
        }

        // At the launch boundary a roots change is admitted and parks inside the store's commit,
        // holding its claim, when the launch tries to take the roots.
        await atLaunch.wait()
        let commitParked = LaunchGate()
        let releaseCommit = LaunchGate()
        await prepared.runtime.workspaceStore.testSetAfterWorkspaceMutationGateAcquired { _ in
            await commitParked.open()
            await releaseCommit.wait()
        }
        let addFolder: [String: Value] = ["action": .string("add_folder"), "folder_path": .string(extraRoot.path)]
        let change = Task { try await self.manageWorkspaces(addFolder, prepared: prepared) }
        await commitParked.wait()
        await proceed.open()

        let failure = try await expectFailure { try await start.value }
        XCTAssertEqual(failure.toolName, "agent_run")
        XCTAssertEqual(failure.code, "child_launch_context_changed")
        XCTAssertEqual(failure.retryability, .retryable)
        XCTAssertEqual(failure.mutationState, DomainProtectedMutationState.notApplied.rawValue)
        XCTAssertEqual(failure.details["reason"], .string("roots_changing"))
        XCTAssertEqual(failure.details["process_started"], .bool(false))
        XCTAssertEqual(failure.details["context_id"], .string(bound.identity.contextID.uuidString))
        XCTAssertTrue(failure.message.contains("roots was in flight"), failure.message)
        XCTAssertTrue(try fixture.calls().isEmpty, "no provider process ran")
        let sessions = await prepared.providerCoordinator.listAgents()
        XCTAssertTrue(sessions.isEmpty, "a refused start registers no session")
        await assertLaunchRootAuthorityIdle(prepared, claimsExpected: 1)

        // The change that won applies.
        await prepared.runtime.workspaceStore.testSetAfterWorkspaceMutationGateAcquired(nil)
        await releaseCommit.open()
        let added = try await change.value
        XCTAssertEqual(added["action"], .string("add_folder"))
        await assertLaunchRootAuthorityIdle(prepared)
    }

    func testCancellingARunningAgentReleasesItsAuthorityAndRevokesItsToken() async throws {
        let fixture = try LaunchFixture(name: "agent-cancel")
        defer { fixture.cleanup() }
        defer { fixture.openGate() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        let started = try await startAgent(["model": .string("gated"), "detach": .bool(true)], prepared: prepared)
        let sessionID = try Self.sessionID(started)
        try await fixture.waitForGate()
        let agent = try XCTUnwrap(fixture.calls().first)

        await prepared.providerCoordinator.cancelAgent(sessionID: sessionID)
        let terminal = try await waitForTerminal(sessionID, prepared: prepared)
        XCTAssertEqual(terminal.status, .cancelled)
        await assertLaunchRootAuthorityIdle(prepared)
        let late = try await redeem(agent, prepared: prepared)
        XCTAssertEqual(late, .revoked, "the cancelled process's unredeemed token is dead")
        let admitted = try await admitChild(of: agent, service: service, prepared: prepared)
        XCTAssertNil(admitted)
    }

    func testAnAgentChildWriteInFlightAcrossTheAgentsExitKeepsTheRootsExcludedUntilItSettles() async throws {
        let fixture = try LaunchFixture(name: "agent-inflight-write")
        defer { fixture.cleanup() }
        defer { fixture.openGate() }
        let extraRoot = try Self.temporaryDirectory("agent-inflight-root")
        defer { try? FileManager.default.removeItem(at: extraRoot) }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        let bound = try await prepared.context.snapshot(connectionID: prepared.connectionID)
        let feature = try XCTUnwrap(bound.roots.first).appendingPathComponent("Sources/Feature.swift")
        let started = try await startAgent(["model": .string("gated"), "detach": .bool(true)], prepared: prepared)
        let sessionID = try Self.sessionID(started)
        try await fixture.waitForGate()
        let agent = try XCTUnwrap(fixture.calls().first)
        let admitted = try await admitChild(of: agent, service: service, prepared: prepared)
        let connection = try XCTUnwrap(admitted)

        // The agent's child apply_edits enters through the real host hooks, captures the leased
        // roots, and parks at its commit.
        let arguments: [String: Value] = [
            "path": .string("Sources/Feature.swift"),
            "search": .string("FEATURE_MARKER"),
            "replace": .string("AGENT_WRITE")
        ]
        let invocation = try await childInvocation("apply_edits", arguments, connection: connection, prepared: prepared)
        try invocation.onProviderEntry()
        let parked = LaunchGate()
        let resume = LaunchGate()
        let controller = Self.parkingCommitController(parked: parked, resume: resume)
        let request = try DomainPhysicalToolRequest(
            argumentsJSON: JSONEncoder().encode(arguments),
            securityContext: invocation.securityContext
        )
        let backend = DirectHeadlessFilesystemBackend(context: prepared.context)
        let write = Task {
            try await MCPDomainMutationCommitContext.$controller.withValue(controller) {
                try await backend.applyFileEdits(request)
            }
        }
        await parked.wait()

        // The agent exits: its authority is releasing while the write is in flight, so a roots
        // change is still refused and no new child call enters.
        fixture.openGate()
        _ = try await waitForTerminal(sessionID, prepared: prepared)
        var counts = prepared.context.launchRootAuthorityCounts()
        XCTAssertEqual(counts.activeLeases, 0)
        XCTAssertEqual(counts.releasingLeases, 1)
        XCTAssertEqual(counts.inFlightInvocations, 1)
        let addFolder: [String: Value] = ["action": .string("add_folder"), "folder_path": .string(extraRoot.path)]
        let refused = try await expectFailure { try await self.manageWorkspaces(addFolder, prepared: prepared) }
        XCTAssertEqual(refused.code, "root_authority_leased")
        XCTAssertEqual(refused.mutationState, DomainProtectedMutationState.notApplied.rawValue)
        let late = try await childInvocation("read_file", ["path": .string("Sources/Feature.swift")], connection: connection, prepared: prepared)
        XCTAssertThrowsError(try late.onProviderEntry(), "a released authority admits no new child call")

        // The write lands in the agent's root, never in the refused one; only once it settled can
        // the roots change.
        await resume.open()
        _ = try await write.value
        let written = try String(contentsOf: feature, encoding: .utf8)
        XCTAssertTrue(written.contains("AGENT_WRITE"), written)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: extraRoot.path), [], "the refused root is untouched")
        invocation.onProviderReturn()
        counts = prepared.context.launchRootAuthorityCounts()
        XCTAssertEqual(counts.leases, 0)
        XCTAssertEqual(counts.inFlightInvocations, 0)
        let added = try await manageWorkspaces(addFolder, prepared: prepared)
        XCTAssertEqual(added["action"], .string("add_folder"))
    }

    func testASubAgentStartedThroughItsParentsChildInheritsTheWorktreeUnderItsOwnAuthority() async throws {
        let fixture = try LaunchFixture(name: "agent-inherit")
        defer { fixture.cleanup() }
        defer { fixture.openGate() }
        let worktree = try Self.makeLinkedWorktree(of: fixture.root)
        defer { try? FileManager.default.removeItem(at: worktree) }
        let worktreePath = try XCTUnwrap(Self.realPath(worktree))
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }

        let parentStart = try await startAgent(
            ["model": .string("gated"), "detach": .bool(true), "worktree": .string(worktree.path)],
            prepared: prepared
        )
        let parentSession = try Self.sessionID(parentStart)
        try await fixture.waitForGate()
        let parent = try XCTUnwrap(fixture.calls().first)
        XCTAssertEqual(parent.workingDirectory, worktreePath, "the agent runs in its worktree")
        let admitted = try await admitChild(of: parent, service: service, prepared: prepared)
        let parentChild = try XCTUnwrap(admitted)
        let parentView = try await prepared.context.snapshot(connectionID: parentChild.connectionID, sessionID: parentSession)
        XCTAssertEqual(parentView.roots.compactMap { Self.realPath($0) }, [worktreePath], "its child reads the worktree")

        // The parent's child starts a sub-agent: it inherits the worktree and launches under its
        // own authority, while the parent keeps its own.
        let subStart = try await startAgent(
            ["model": .string("sub"), "detach": .bool(true)],
            prepared: prepared,
            via: parentChild
        )
        let subSession = try Self.sessionID(subStart)
        guard case let .object(session)? = subStart["session"] else { return XCTFail("\(subStart)") }
        XCTAssertEqual(session["parent_session_id"], .string(parentSession.uuidString))
        let subTerminal = try await waitForTerminal(subSession, prepared: prepared)
        XCTAssertEqual(subTerminal.status, .completed)
        XCTAssertEqual(subTerminal.worktreeBindings.map(\.source), ["direct-headless-inherited-overlay"])
        let sub = try XCTUnwrap(fixture.calls().first { $0.model == "sub" })
        XCTAssertEqual(sub.workingDirectory, worktreePath)
        XCTAssertEqual(sub.runID, subSession.uuidString)
        let counts = prepared.context.launchRootAuthorityCounts()
        XCTAssertEqual(counts.activeLeases, 1, "the sub-agent's authority ended with it; the parent's is held")

        fixture.openGate()
        _ = try await waitForTerminal(parentSession, prepared: prepared)
        await assertLaunchRootAuthorityIdle(prepared)
        await prepared.context.detachLaunchConnection(parentChild.connectionID)
    }

    func testShutdownReleasesARunningAgentsLaunchAuthority() async throws {
        let fixture = try LaunchFixture(name: "agent-shutdown")
        defer { fixture.cleanup() }
        defer { fixture.openGate() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        _ = try await startAgent(["model": .string("gated"), "detach": .bool(true)], prepared: prepared)
        try await fixture.waitForGate()
        XCTAssertEqual(prepared.context.launchRootAuthorityCounts().activeLeases, 1)

        await service.teardown(prepared)
        let counts = prepared.context.launchRootAuthorityCounts()
        XCTAssertEqual(counts.leases, 0)
        XCTAssertEqual(counts.claims, 0)
        XCTAssertEqual(counts.leasedConnections, 0)
    }

    // MARK: - Direct Oracle turns

    func testARunningDirectOracleAnchorsItsChildAndRefusesRootAndOverlayChangesUntilItExits() async throws {
        let fixture = try LaunchFixture(name: "oracle-running")
        defer { fixture.cleanup() }
        defer { fixture.openGate() }
        let extraRoot = try Self.temporaryDirectory("oracle-extra")
        defer { try? FileManager.default.removeItem(at: extraRoot) }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        try await Self.setRoster(prepared, primary: "gated", additional: [])
        let bound = try await prepared.context.snapshot(connectionID: prepared.connectionID)
        let runID = try XCTUnwrap(prepared.principal.runID)
        let task = Task { try await self.askOracle(["message": .string("What does Feature hold?")], prepared: prepared) }
        try await fixture.waitForGate()
        let oracle = try XCTUnwrap(fixture.calls().first)
        XCTAssertEqual(oracle.workingDirectory, fixture.physicalRootPath)
        XCTAssertEqual(oracle.sandbox, "workspace-write")

        let admitted = try await admitChild(of: oracle, service: service, prepared: prepared)
        let child = try XCTUnwrap(admitted)
        let childView = try await prepared.context.snapshot(connectionID: child.connectionID, sessionID: runID)
        XCTAssertEqual(childView.identity, bound.identity)
        XCTAssertEqual(childView.roots.map(\.path), bound.roots.map(\.path))

        // After the spawn, neither the roots nor the launch session's overlay can move under it.
        let addFolder: [String: Value] = ["action": .string("add_folder"), "folder_path": .string(extraRoot.path)]
        let refused = try await expectFailure { try await self.manageWorkspaces(addFolder, prepared: prepared) }
        XCTAssertEqual(refused.code, "root_authority_leased")
        XCTAssertEqual(refused.details["launch_kind"], .string("oracle"))
        let overlay = try await expectFailure {
            try await prepared.context.prepareSessionRootOverlay(
                sessionID: runID,
                sourceSessionID: nil,
                arguments: [:],
                connectionID: prepared.connectionID
            )
        }
        XCTAssertEqual(overlay.code, "root_authority_leased")

        fixture.openGate()
        let result = try await task.value
        XCTAssertEqual(result["response"], .string("reply-none-gated"))
        do {
            _ = try await prepared.context.snapshot(connectionID: child.connectionID, sessionID: runID)
            XCTFail("A released launch authority must not resolve")
        } catch DirectHeadlessDomainContext.Error.launchRootAuthorityReleased {}
        await assertLaunchRootAuthorityIdle(prepared)
        let added = try await manageWorkspaces(addFolder, prepared: prepared)
        XCTAssertEqual(added["action"], .string("add_folder"))
        await prepared.context.detachLaunchConnection(child.connectionID)
    }

    func testADirectOracleRefusesToLaunchAfterARebindAndReportsItTyped() async throws {
        let fixture = try LaunchFixture(name: "oracle-rebind")
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        try await Self.setRoster(prepared, primary: "lane-0", additional: [])
        let bound = try await prepared.context.snapshot(connectionID: prepared.connectionID)
        let other = try await Self.addContext(to: prepared)
        // The carrier was minted for the bound context; the connection is rebound before the launch.
        await prepared.providerCoordinator.installLaunchProbe { _ in
            _ = try await prepared.runtime.standaloneScopeCoordinator.bind(scopeID: prepared.scopeID, context: other)
        }

        let failure = try await expectFailure {
            try await self.askOracle(["message": .string("What does Feature hold?")], prepared: prepared)
        }
        XCTAssertEqual(failure.toolName, "ask_oracle")
        XCTAssertEqual(failure.code, "child_launch_context_changed")
        XCTAssertEqual(failure.retryability, .retryable)
        XCTAssertEqual(failure.mutationState, DomainProtectedMutationState.notApplied.rawValue)
        XCTAssertEqual(failure.details["reason"], .string("rebound"))
        XCTAssertEqual(failure.details["context_id"], .string(bound.identity.contextID.uuidString))
        XCTAssertTrue(failure.message.contains("rebound to context \(other.contextID.uuidString)"), failure.message)
        XCTAssertTrue(try fixture.calls().isEmpty, "no provider process ran")
        await assertLaunchRootAuthorityIdle(prepared)
    }

    func testAnOverlayChangeBeforeTheLaunchIsTheLaunchsOneAuthority() async throws {
        let fixture = try LaunchFixture(name: "oracle-overlay-before")
        defer { fixture.cleanup() }
        defer { fixture.openGate() }
        let worktree = try Self.makeLinkedWorktree(of: fixture.root)
        defer { try? FileManager.default.removeItem(at: worktree) }
        let worktreePath = try XCTUnwrap(Self.realPath(worktree))
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        try await Self.setRoster(prepared, primary: "gated", additional: [])
        let runID = try XCTUnwrap(prepared.principal.runID)
        // The launch session moves onto the worktree after the carrier was minted, before the launch.
        await prepared.providerCoordinator.installLaunchProbe { _ in
            _ = try await prepared.context.prepareSessionRootOverlay(
                sessionID: runID,
                sourceSessionID: nil,
                arguments: ["worktree": .string(worktree.path)],
                connectionID: prepared.connectionID
            )
        }
        let task = Task { try await self.askOracle(["message": .string("What does Feature hold?")], prepared: prepared) }
        try await fixture.waitForGate()

        // The process and its child agree on the roots the launch took: never one of each.
        let oracle = try XCTUnwrap(fixture.calls().first)
        XCTAssertEqual(oracle.workingDirectory, worktreePath)
        let admitted = try await admitChild(of: oracle, service: service, prepared: prepared)
        let child = try XCTUnwrap(admitted)
        let childView = try await prepared.context.snapshot(connectionID: child.connectionID, sessionID: runID)
        XCTAssertEqual(childView.roots.compactMap { Self.realPath($0) }, [worktreePath])
        XCTAssertEqual(childView.activeRoot.flatMap { Self.realPath($0) }, worktreePath)

        fixture.openGate()
        _ = try await task.value
        await assertLaunchRootAuthorityIdle(prepared)
        await prepared.context.detachLaunchConnection(child.connectionID)
    }

    func testADirectOracleThatFailsToSpawnReleasesItsAuthorityAndToken() async throws {
        let fixture = try LaunchFixture(name: "oracle-spawn-failure")
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        try await Self.setRoster(prepared, primary: "lane-0", additional: [])
        let executable = fixture.executable
        // The provider was resolved; the executable stops being executable before the spawn.
        await prepared.providerCoordinator.installLaunchProbe { _ in
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: executable.path)
        }
        do {
            _ = try await askOracle(["message": .string("What does Feature hold?")], prepared: prepared)
            XCTFail("A launch whose process cannot spawn must fail")
        } catch let failure as MCPDomainToolFailure {
            XCTAssertNotEqual(failure.code, "child_launch_context_changed", "a spawn failure is not a launch refusal")
        } catch {}
        XCTAssertTrue(try fixture.calls().isEmpty)
        await assertLaunchRootAuthorityIdle(prepared)
    }

    func testAnExpiredDirectOracleTokenAdmitsNoChildWhileItsAuthorityIsHeldUntilExit() async throws {
        let fixture = try LaunchFixture(name: "oracle-expiry")
        defer { fixture.cleanup() }
        defer { fixture.openGate() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        try await Self.setRoster(prepared, primary: "gated", additional: [])
        let lifetime = Duration.milliseconds(300)
        let task = Task {
            try await self.askOracle(
                ["message": .string("What does Feature hold?")],
                prepared: prepared,
                carrierLifetime: lifetime
            )
        }
        try await fixture.waitForGate()
        let oracle = try XCTUnwrap(fixture.calls().first)
        try await Task.sleep(for: lifetime + .milliseconds(300))
        let admitted = try await admitChild(of: oracle, service: service, prepared: prepared)
        XCTAssertNil(admitted, "an expired token admits no child")
        let counts = prepared.context.launchRootAuthorityCounts()
        XCTAssertEqual(counts.activeLeases, 1, "the process still runs under its authority")
        XCTAssertEqual(counts.leasedConnections, 0)

        fixture.openGate()
        _ = try await task.value
        await assertLaunchRootAuthorityIdle(prepared)
    }

    // MARK: - Grouped Oracle lanes (unpinned)

    func testGroupedLanesLaunchUnderTheirOwnAuthoritiesAndALaterLaneIsRefusedAfterARebind() async throws {
        let fixture = try LaunchFixture(name: "group-rebind")
        defer { fixture.cleanup() }
        defer { fixture.openGate() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        try await Self.setRoster(prepared, primary: "gated", additional: ["lane-1", "lane-2"])
        let bound = try await prepared.context.snapshot(connectionID: prepared.connectionID)
        let other = try await Self.addContext(to: prepared)
        let runID = try XCTUnwrap(prepared.principal.runID)
        let laneTwoMayLaunch = LaunchGate()
        await prepared.providerCoordinator.installLaunchProbe { carrier in
            if carrier.oracleLaneID?.index == 2 { await laneTwoMayLaunch.wait() }
        }
        let task = Task { try await self.askOracle(["message": .string("Where is the marker?")], prepared: prepared) }

        // Lane 0 runs (held), lane 1 runs to its exit, lane 2 has not launched.
        try await fixture.waitForGate()
        try await Self.waitUntil {
            guard (try? fixture.calls().contains { $0.model == "lane-1" }) == true else { return false }
            return prepared.context.launchRootAuthorityCounts().leases == 1
        }
        let calls = try fixture.calls()
        let laneZero = try XCTUnwrap(calls.first { $0.model == "gated" })
        let laneOne = try XCTUnwrap(calls.first { $0.model == "lane-1" })
        XCTAssertEqual(laneZero.sandbox, "read-only")
        // Lane 1's authority was released at its exit, which revoked its never-redeemed token.
        let lateLaneOne = try await redeem(laneOne, prepared: prepared)
        XCTAssertEqual(lateLaneOne, .revoked)

        // Lane 0's child keeps its launch's context and roots across a rebind of the parent.
        let admitted = try await admitChild(of: laneZero, service: service, prepared: prepared)
        let child = try XCTUnwrap(admitted)
        _ = try await prepared.runtime.standaloneScopeCoordinator.bind(scopeID: prepared.scopeID, context: other)
        let childView = try await prepared.context.snapshot(connectionID: child.connectionID, sessionID: runID)
        XCTAssertEqual(childView.identity, bound.identity)
        XCTAssertEqual(childView.roots.map(\.path), bound.roots.map(\.path))

        // Lane 2 launches after the rebind and is refused as a typed lane failure.
        await laneTwoMayLaunch.open()
        fixture.openGate()
        let result = try await task.value
        guard case let .array(lanes)? = result["oracle_results"] else {
            return XCTFail("Expected the grouped result: \(result)")
        }
        XCTAssertEqual(result["status"], .string("partial_failure"))
        let byLane = Dictionary(uniqueKeysWithValues: lanes.compactMap { lane -> (Int, [String: Value])? in
            guard case let .object(fields) = lane, case let .int(index)? = fields["lane_index"] else { return nil }
            return (index, fields)
        })
        XCTAssertEqual(byLane[0]?["status"], .string("completed"))
        XCTAssertEqual(byLane[1]?["status"], .string("completed"))
        XCTAssertEqual(byLane[2]?["status"], .string("failed"))
        guard case let .object(laneTwoError)? = byLane[2]?["error"], case let .string(message)? = laneTwoError["message"] else {
            return XCTFail("Expected lane 2's typed refusal: \(String(describing: byLane[2]))")
        }
        XCTAssertEqual(laneTwoError["code"], .string("child_launch_context_changed"))
        XCTAssertTrue(message.contains("rebound to context \(other.contextID.uuidString)"), message)
        XCTAssertTrue(message.contains("after the launch's carrier was minted"), message)
        let providerCalls = try fixture.calls()
        XCTAssertEqual(Set(providerCalls.map(\.model)), ["gated", "lane-1"], "lane 2's process never started")
        XCTAssertTrue(providerCalls.allSatisfy { $0.workingDirectory == fixture.physicalRootPath })
        await assertLaunchRootAuthorityIdle(prepared)
        await prepared.context.detachLaunchConnection(child.connectionID)
    }

    // MARK: - Invariants

    func testAChildWhoseTokenIsNotLaunchScopedIsNeverAdmitted() async throws {
        let fixture = try LaunchFixture(name: "unscoped-token")
        defer { fixture.cleanup() }
        let service = fixture.service()
        let prepared = try await service.prepareRuntime()
        addTeardownBlock { await service.teardown(prepared) }
        let bound = try await prepared.context.snapshot(connectionID: prepared.connectionID)
        let runID = UUID()
        let request = DomainRunLaunchReservationRequest(
            runID: runID,
            context: bound.identity,
            expectedContextRevision: bound.context.revisions.workingRevision,
            windowID: nil,
            clientPrincipal: "unscoped-client",
            providerIdentifier: "codexExec",
            runPurpose: "agent_run"
        )
        let token = try await prepared.runtime.routingCoordinator.issueLaunchToken(request)
        let connectionID = UUID()
        let admitted = await service.admitPrivateChild(
            connectionID: connectionID,
            peerPID: nil,
            handshake: DirectHeadlessChildEndpoint.Handshake(
                launchToken: token.material,
                clientPrincipal: "unscoped-client",
                providerIdentifier: "codexExec",
                runID: runID,
                launchID: request.launchID,
                oracleGroupID: nil,
                oracleLaneID: nil,
                oracleGroupClaimID: nil
            ),
            prepared: prepared
        )
        XCTAssertNil(admitted, "a child that would resolve the live roots is refused")
        let routing = await prepared.runtime.routingCoordinator.snapshot()
        XCTAssertFalse(routing.connections.contains { $0.registration.connectionID == connectionID })
        XCTAssertEqual(prepared.context.launchRootAuthorityCounts().leasedConnections, 0)
    }

    // MARK: - Helpers

    /// `agent_run start` through the real long-running provider and child-launch coordinator, as the
    /// verified top-level client, or as `connection` (a launched child) when given.
    private func startAgent(
        _ arguments: [String: Value],
        prepared: DirectHeadlessMCPService.PreparedRuntime,
        via connection: DirectHeadlessMCPService.ConnectionContext? = nil
    ) async throws -> [String: Value] {
        var start = arguments
        start["op"] = .string("start")
        if start["message"] == nil { start["message"] = .string("Do the task.") }
        let backend = DirectHeadlessAgentBackend(coordinator: prepared.providerCoordinator)
        let tool = await realTool("agent_run", prepared: prepared) { try await backend.run($0) }
        let security = if let connection {
            try await childSecurityContext(connection, prepared: prepared, grants: ["agent_run"])
        } else {
            try await verifiedSecurityContext(prepared, grants: ["agent_run"])
        }
        return try await Self.fields(MCPDomainInvocationSecurityContext.$current.withValue(security) {
            try await tool(start)
        })
    }

    /// `ask_oracle` through the real long-running provider and child-launch coordinator.
    private func askOracle(
        _ arguments: [String: Value],
        prepared: DirectHeadlessMCPService.PreparedRuntime,
        carrierLifetime: Duration = .seconds(60)
    ) async throws -> [String: Value] {
        let backend = DirectHeadlessConversationBackend(
            providerCoordinator: prepared.providerCoordinator,
            oracleAdapter: prepared.oracleAdapter
        )
        let tool = await realTool("ask_oracle", prepared: prepared, carrierLifetime: carrierLifetime) {
            try await backend.startOracleConversation($0)
        }
        let security = try await verifiedSecurityContext(prepared, grants: ["ask_oracle"])
        return try await Self.fields(MCPDomainInvocationSecurityContext.$current.withValue(security) {
            try await tool(arguments)
        })
    }

    /// The real admission path for `name`: long-running provider, child-launch coordinator (with
    /// the runtime's launch-root registry), and routing tokens.
    private func realTool(
        _ name: String,
        prepared: DirectHeadlessMCPService.PreparedRuntime,
        carrierLifetime: Duration = .seconds(60),
        _ body: @escaping @Sendable (DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult
    ) async -> MCPDomainToolBinding {
        let coordinator = DirectHeadlessChildLaunchCoordinator(carrierLifetime: carrierLifetime)
        await coordinator.configure(
            runtime: prepared.runtime,
            endpointDescriptor: prepared.childEndpoint.socketURL.path,
            oracleAdapter: prepared.oracleAdapter,
            launchRoots: prepared.context.launchRoots
        )
        let provider = MCPDomainLongRunningToolProvider(
            identity: prepared.runtime.identity,
            policyStore: prepared.runtime.mutationPolicyStore,
            interactionBroker: prepared.runtime.interactionBroker,
            activityCenter: prepared.runtime.activityCenter,
            resolveChildLaunchPlan: { toolName, arguments, security in
                try await coordinator.resolvePlan(toolName: toolName, arguments: arguments, securityContext: security)
            },
            prepareChildLaunches: { plan, toolName, arguments, security, pin in
                try await coordinator.prepare(
                    plan: plan,
                    toolName: toolName,
                    arguments: arguments,
                    securityContext: security,
                    pinnedTo: pin
                )
            },
            revokeChildLaunches: { plan, bundle in await coordinator.revoke(plan: plan, bundle: bundle) }
        )
        let binding = MCPDomainToolBinding(
            definition: .init(name: name, description: name, inputSchema: .object(["type": .string("object")]))
        ) { arguments in
            let request = try DomainPhysicalToolRequest(
                argumentsJSON: JSONEncoder().encode(arguments),
                securityContext: MCPDomainInvocationSecurityContext.current
            )
            let result = try await body(request)
            return try JSONDecoder().decode(Value.self, from: result.json)
        }
        return provider.wrapping(binding)
    }

    private static func fields(_ value: Value) throws -> [String: Value] {
        guard case let .object(fields) = value else {
            throw MCPError.internalError("expected an object result, got \(value)")
        }
        return fields
    }

    private static func sessionID(_ fields: [String: Value]) throws -> UUID {
        try XCTUnwrap(fields["session_id"]?.stringValue.flatMap(UUID.init(uuidString:)), "\(fields)")
    }

    private func waitForTerminal(
        _ sessionID: UUID,
        prepared: DirectHeadlessMCPService.PreparedRuntime,
        timeout: Duration = .seconds(30)
    ) async throws -> DomainAgentRunSnapshot {
        let deadline = ContinuousClock.now + timeout
        while true {
            let snapshot = await prepared.providerCoordinator.pollAgent(sessionID: sessionID, timeout: 0)
            if snapshot.status.isTerminal { return snapshot }
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for session \(sessionID) to settle")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func expectFailure(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> some Any
    ) async throws -> MCPDomainToolFailure {
        do {
            _ = try await body()
        } catch let failure as MCPDomainToolFailure {
            return failure
        }
        XCTFail("Expected a typed tool failure", file: file, line: line)
        throw CancellationError()
    }

    /// Admits a private child exactly as the endpoint does, from the carrier a launched process
    /// logged; nil when the child was refused.
    private func admitChild(
        of call: LaunchFixture.Call,
        service: DirectHeadlessMCPService,
        prepared: DirectHeadlessMCPService.PreparedRuntime
    ) async throws -> DirectHeadlessMCPService.ConnectionContext? {
        let handshake = try DirectHeadlessChildBridge.handshake(environment: call.carrierEnvironment)
        return await service.admitPrivateChild(
            connectionID: UUID(),
            peerPID: nil,
            handshake: handshake,
            prepared: prepared
        )?.connection
    }

    private func redeem(
        _ call: LaunchFixture.Call,
        prepared: DirectHeadlessMCPService.PreparedRuntime
    ) async throws -> DomainRunLaunchRedemptionResult {
        try await prepared.runtime.routingCoordinator.redeemLaunchToken(
            material: XCTUnwrap(call.launchToken),
            runtimeID: prepared.runtime.identity.runtimeID,
            runtimeGeneration: prepared.runtime.identity.lifecycleGeneration,
            connectionID: UUID(),
            processID: nil,
            clientPrincipal: XCTUnwrap(call.clientPrincipal),
            providerIdentifier: XCTUnwrap(call.providerIdentifier)
        )
    }

    /// The exact host invocation the endpoint would run for `toolName` on a child connection.
    private func childInvocation(
        _ toolName: String,
        _ arguments: [String: Value],
        connection: DirectHeadlessMCPService.ConnectionContext,
        prepared: DirectHeadlessMCPService.PreparedRuntime
    ) async throws -> MCPDomainHostInvocation {
        let resolution = try await prepared.runtime.domainHost.resolve(
            toolName: toolName,
            scope: .standalone(id: prepared.scopeID)
        )
        return await DirectHeadlessMCPService.hostInvocation(
            prepared: prepared,
            connection: connection,
            resolution: resolution,
            arguments: arguments
        )
    }

    /// A commit controller that fences and opens the physical targets like the protected path,
    /// then parks the commit until `resume` opens.
    private static func parkingCommitController(
        parked: LaunchGate,
        resume: LaunchGate
    ) -> DomainMutationCommitController {
        let fence = LaunchFenceBox()
        return DomainMutationCommitController(
            admitPhysicalTargets: { paths, mappings in
                try await fence.set(DomainMutationPathFence.admit(
                    requestedPaths: paths,
                    authorizedRoots: Set(mappings.map(\.physicalRoot))
                ))
            },
            physicalMutationCapability: {
                guard let snapshot = await fence.snapshot else { return nil }
                return try DomainMutationPhysicalCapability.open(snapshot: snapshot)
            },
            willCommit: {
                await parked.open()
                await resume.wait()
            }
        )
    }

    /// `manage_workspaces` through the real backend, as the bound top-level client.
    private func manageWorkspaces(
        _ arguments: [String: Value],
        prepared: DirectHeadlessMCPService.PreparedRuntime
    ) async throws -> [String: Value] {
        let request = try await DomainPhysicalToolRequest(
            argumentsJSON: JSONEncoder().encode(arguments),
            securityContext: securityContext(prepared)
        )
        let backend = DirectHeadlessGlobalBackend(
            runtime: prepared.runtime,
            scopeID: prepared.scopeID,
            context: prepared.context,
            settingsStore: prepared.settingsStore
        )
        let result = try await backend.manageWorkspaceLifecycle(request)
        return try Self.fields(JSONDecoder().decode(Value.self, from: result.json))
    }

    /// No launch holds or validates a root authority, and no launch token is outstanding.
    private func assertLaunchRootAuthorityIdle(
        _ prepared: DirectHeadlessMCPService.PreparedRuntime,
        claimsExpected: Int = 0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let counts = prepared.context.launchRootAuthorityCounts()
        XCTAssertEqual(counts.leases, 0, "a launch root authority is still held", file: file, line: line)
        XCTAssertEqual(counts.claims, claimsExpected, "root-mutation claims", file: file, line: line)
        XCTAssertEqual(counts.inFlightInvocations, 0, "child invocations in flight", file: file, line: line)
        let routing = await prepared.runtime.routingCoordinator.snapshot()
        XCTAssertTrue(routing.pendingRunContexts.isEmpty, "a launch token is still outstanding", file: file, line: line)
    }

    /// A verified run-scoped top-level caller granted `grants`, so the long-running provider's
    /// approval admits it.
    private func verifiedSecurityContext(
        _ prepared: DirectHeadlessMCPService.PreparedRuntime,
        grants: Set<String>
    ) async throws -> DomainToolInvocationSecurityContext {
        let base = try await securityContext(prepared)
        return DomainToolInvocationSecurityContext(
            principal: DomainClientPrincipal(
                principalID: UUID(),
                stableKey: "m22-verified-client",
                displayName: "M22 verified client",
                kind: .runScoped,
                assurance: .verifiedProcess,
                processID: getpid(),
                runID: prepared.principal.runID,
                provider: "direct-stdio",
                verifiedIdentityFingerprint: "m22-fixture",
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
            ephemeralGrantedToolNames: grants,
            ephemeralGrantedOperations: []
        )
    }

    /// The security context of a call made by the launched child `connection`, granted `grants`.
    private func childSecurityContext(
        _ connection: DirectHeadlessMCPService.ConnectionContext,
        prepared: DirectHeadlessMCPService.PreparedRuntime,
        grants: Set<String>
    ) async throws -> DomainToolInvocationSecurityContext {
        let view = try await prepared.context.snapshot(
            connectionID: connection.connectionID,
            sessionID: connection.principal.runID
        )
        return DomainToolInvocationSecurityContext(
            principal: connection.principal,
            connectionID: connection.connectionID,
            connectionGeneration: connection.connectionGeneration,
            invocationID: UUID(),
            runtimeID: prepared.runtime.identity.runtimeID,
            runtimeGeneration: prepared.runtime.identity.lifecycleGeneration,
            workspaceID: view.identity.workspaceID,
            workspaceRevision: view.workspace.revisions.workingRevision,
            authorizedCanonicalRoots: Set(view.roots.map(\.path)),
            hasAuthoritativeRoutingContext: true,
            ephemeralGrantedToolNames: grants,
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

    private static func waitUntil(
        timeout: Duration = .seconds(15),
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while await !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for the condition")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-headless-launch-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The kernel spelling of `url` (what a process's `pwd -P` reports).
    private static func realPath(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Makes `root` a Git repository with one commit and returns a linked worktree of it.
    private static func makeLinkedWorktree(of root: URL) throws -> URL {
        let git = "/usr/bin/git"
        guard FileManager.default.isExecutableFile(atPath: git) else { throw XCTSkip("git is unavailable") }
        let home = try temporaryDirectory("git-home")
        defer { try? FileManager.default.removeItem(at: home) }
        func run(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: git)
            process.arguments = [
                "-C", root.path,
                "-c", "user.name=RepoPrompt Tests",
                "-c", "user.email=tests@example.invalid",
                "-c", "commit.gpgsign=false"
            ] + arguments
            process.environment = ["PATH": "/usr/bin:/bin", "HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw MCPError.internalError("git \(arguments.joined(separator: " ")): \(String(decoding: data, as: UTF8.self))")
            }
        }
        let worktree = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-headless-launch-worktree-\(UUID().uuidString)", isDirectory: true)
        try run(["init", "-q"])
        try run(["add", "-A"])
        try run(["commit", "-q", "-m", "fixture"])
        try run(["worktree", "add", "-q", "--detach", worktree.path, "HEAD"])
        return worktree.resolvingSymlinksInPath()
    }
}

private actor LaunchFenceBox {
    private(set) var snapshot: DomainMutationPathFenceSnapshot?

    func set(_ snapshot: DomainMutationPathFenceSnapshot) {
        self.snapshot = snapshot
    }
}

/// Opens once; every waiter (earlier or later) passes after that.
private actor LaunchGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// A fake `codex` that logs each provider process's model, sandbox, working directory, and private
/// launch carrier. Model `gated` blocks until `openGate()`; every other model answers at once.
private struct LaunchFixture {
    struct Call {
        let model: String
        let lane: String
        let sandbox: String
        let launchID: String?
        let processID: String
        let launchToken: String?
        let clientPrincipal: String?
        let providerIdentifier: String?
        /// The provider process's physical working directory.
        let workingDirectory: String?
        let runID: String?
        let oracleGroupID: String?
        let oracleGroupClaimID: String?

        /// The private launch carrier this process was started with, as the child bridge reads it.
        var carrierEnvironment: [String: String] {
            var environment: [String: String] = [:]
            environment[DomainChildLaunchCarrier.launchTokenEnvironmentKey] = launchToken
            environment[DomainChildLaunchCarrier.clientPrincipalEnvironmentKey] = clientPrincipal
            environment[DomainChildLaunchCarrier.providerIdentifierEnvironmentKey] = providerIdentifier
            environment[DomainChildLaunchCarrier.runIDEnvironmentKey] = runID
            environment[DomainChildLaunchCarrier.launchIDEnvironmentKey] = launchID
            environment[DomainChildLaunchCarrier.oracleGroupIDEnvironmentKey] = oracleGroupID
            environment[DomainChildLaunchCarrier.oracleGroupClaimIDEnvironmentKey] = oracleGroupClaimID
            if lane != "none" {
                environment[DomainChildLaunchCarrier.oracleLaneIDEnvironmentKey] = lane
            }
            return environment
        }
    }

    let root: URL
    let profile: URL
    let executable: URL
    let callLog: URL
    let profileName: String

    init(name: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-headless-launch-root-\(name)-\(UUID().uuidString)", isDirectory: true)
        profile = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-headless-launch-profile-\(name)-\(UUID().uuidString)", isDirectory: true)
        executable = profile.appendingPathComponent("codex-stub")
        callLog = profile.appendingPathComponent("calls.log")
        profileName = "launch-\(name)"
        let manager = FileManager.default
        try manager.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try manager.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data("struct Feature {\n    let marker = \"FEATURE_MARKER\"\n}\n".utf8)
            .write(to: root.appendingPathComponent("Sources/Feature.swift"))
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
        /bin/cat > /dev/null
        /usr/bin/printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$model" "$lane" "$sandbox" \
          "${REPOPROMPT_MCP_LAUNCH_ID:-}" "$$" "${REPOPROMPT_MCP_LAUNCH_TOKEN:-}" \
          "${REPOPROMPT_MCP_CLIENT_PRINCIPAL:-}" "${REPOPROMPT_MCP_PROVIDER_IDENTIFIER:-}" \
          "$(/bin/pwd -P)" "${REPOPROMPT_MCP_RUN_ID:-}" "${REPOPROMPT_MCP_ORACLE_GROUP_ID:-}" \
          "${REPOPROMPT_MCP_ORACLE_GROUP_CLAIM_ID:-}" >> '\#(callLog.path)'
        if [ "$model" = gated ]; then
          : > '\#(profile.path)/waiting'
          i=0
          while [ ! -f '\#(profile.path)/go' ] && [ "$i" -lt 600 ]; do
            /bin/sleep 0.05
            i=$((i + 1))
          done
        fi
        /usr/bin/printf '{"type":"message","text":"reply-%s-%s"}\n' "$lane" "$model"
        """#
        try Data(script.utf8).write(to: executable)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func service() -> DirectHeadlessMCPService {
        DirectHeadlessMCPService(
            environment: [
                "REPOPROMPT_CODEX_COMMAND": executable.path,
                "REPOPROMPT_MCP_HEADLESS_PROFILE": profileName,
                "REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": profile.path,
                "REPOPROMPT_MCP_WORKING_DIRS": root.path,
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""
            ],
            currentDirectory: root
        )
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
                    model: fields[0],
                    lane: fields[1],
                    sandbox: fields[2],
                    launchID: optional(3),
                    processID: fields[4],
                    launchToken: optional(5),
                    clientPrincipal: optional(6),
                    providerIdentifier: optional(7),
                    workingDirectory: optional(8),
                    runID: optional(9),
                    oracleGroupID: optional(10),
                    oracleGroupClaimID: optional(11)
                )
            }
    }

    /// Waits until a `gated` provider process is blocked.
    func waitForGate() async throws {
        let marker = profile.appendingPathComponent("waiting")
        let deadline = ContinuousClock.now + .seconds(15)
        while !FileManager.default.fileExists(atPath: marker.path) {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func openGate() {
        FileManager.default.createFile(atPath: profile.appendingPathComponent("go").path, contents: Data())
    }

    /// The kernel spelling of `root`, as the provider process's `pwd -P` reports it.
    var physicalRootPath: String? {
        guard let resolved = realpath(root.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: profile)
    }
}
