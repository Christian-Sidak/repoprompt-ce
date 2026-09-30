import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSecureStorage
import XCTest

@MainActor
final class AgentSessionLinkStopTransactionTests: XCTestCase {
    private struct Fixture {
        let viewModel: AgentModeViewModel
        let tabID: UUID
        let session: AgentModeViewModel.TabSession
        let candidate: AgentSessionLinkEndpointCandidate
    }

    private var retainedFixtures: [(AgentModeViewModel, WorkspaceManagerViewModel)] = []

    override func tearDown() {
        retainedFixtures.removeAll()
        super.tearDown()
    }

    private func makeFixture() throws -> Fixture {
        let tabID = UUID()
        let files = WorkspaceFilesViewModel()
        let keys = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        let api = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keys),
            keyManager: keys, loadStoredDataOnInit: false
        )
        let prompt = PromptViewModel(
            fileManager: files, apiSettingsViewModel: api, windowID: -1,
            settingsManager: WindowSettingsManager(windowID: -1)
        )
        let manager = WorkspaceManagerViewModel(
            fileManager: files, promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        let workspace = WorkspaceModel(
            name: "Stop target", repoPaths: [], ephemeralFlag: true,
            composeTabs: [ComposeTabState(id: tabID)], activeComposeTabID: tabID
        )
        manager.workspaces = [workspace]
        manager.activeWorkspace = workspace
        let viewModel = AgentModeViewModel(
            testWindowID: 1,
            testWorkspacePath: FileManager.default.currentDirectoryPath,
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: LifecycleRecorder())
            },
            connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
            mcpServerEnabler: { true }
        )
        retainedFixtures.append((viewModel, manager))
        viewModel.workspaceManager = manager
        viewModel.test_setCurrentTabIDOverride(tabID)
        viewModel.test_setAgentSessionSaver { _, _, _ in
            URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString).json")
        }
        let session = viewModel.session(for: tabID)
        session.selectedAgent = .claudeCode
        session.hasLoadedPersistedState = true
        let sessionID = try XCTUnwrap(viewModel.test_ensureSessionBoundToTab(session))
        let candidate = try XCTUnwrap(viewModel.agentSessionLinkCandidate(
            tabID: tabID, sessionID: sessionID, tabName: "Stop target", isWindowClosing: false
        ))
        return Fixture(viewModel: viewModel, tabID: tabID, session: session, candidate: candidate)
    }

    private func stop(
        _ fixture: Fixture,
        teardownDeadlineSeconds: TimeInterval = 1,
        auditDeadlineSeconds: TimeInterval = 1,
        deadlineSleep: (@MainActor (TimeInterval) async -> Void)? = nil,
        beforeCleanupTask: @escaping @MainActor () -> Void = {}
    ) async -> AgentSessionLinkStopTransactionOutcome {
        let observer = DomainAgentSessionLinkEndpointIdentity(
            windowID: 2, workspaceID: UUID(), tabID: UUID(), sessionID: UUID(),
            persistentBindingGeneration: UUID(), bindingTransitionGeneration: 1
        )
        return await fixture.viewModel.agentSessionLinkPerformStop(
            to: fixture.candidate,
            request: AgentSessionLinkStopRequest(
                requestID: UUID(), linkID: UUID(), linkGeneration: 1,
                observerEndpoint: observer, observerDisplayName: "Overseer"
            ),
            liveness: { AgentSessionLinkSendLiveness(
                observerEndpointIsLive: true, targetEndpointIsLive: true,
                targetWindowIsClosing: false
            ) },
            queueHasCommittedDrain: { false },
            withdrawInbound: { true },
            commitAuthorization: { .committed },
            teardownDeadlineSeconds: teardownDeadlineSeconds,
            auditDeadlineSeconds: auditDeadlineSeconds,
            deadlineSleep: deadlineSleep ?? { seconds in
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            },
            beforeCleanupTask: beforeCleanupTask
        )
    }

    func testIdleTargetRetainsNoopWithoutRowOrMutation() async throws {
        let fixture = try makeFixture()
        let before = fixture.session.items.count
        let outcome = await stop(fixture)
        guard case let .settled(receipt) = outcome else { return XCTFail("expected receipt") }
        XCTAssertEqual(receipt.result, .notRunning)
        XCTAssertEqual(receipt.stopRequested, false)
        XCTAssertNil(receipt.targetItemID)
        XCTAssertEqual(fixture.session.items.count, before)
        XCTAssertEqual(fixture.session.runState, .idle)
    }

    func testHeldWakeCannotDispatchAfterIdleStop() async throws {
        let fixture = try makeFixture()
        let heldFence = AgentRunStartStopFence(session: fixture.session)
        let wakeID = UUID()
        fixture.session.oversight.pendingAutoWake = AgentSessionLinkAutoWakeAttempt(
            wakeID: wakeID, observerEndpoint: fixture.candidate.domainEndpoint,
            queueEpoch: nil, queueRevision: 0, wakeFingerprint: nil,
            admissionBasis: .periodic, attemptedFingerprint: nil,
            physicalOutcome: .notAttempted, phase: .preparingDispatch,
            task: nil, stopFence: heldFence
        )
        let outcome = await stop(fixture)
        guard case let .settled(receipt) = outcome else { return XCTFail("expected receipt") }
        XCTAssertEqual(receipt.result, .notRunning)
        XCTAssertFalse(heldFence.permitsStart(of: fixture.session))
        XCTAssertEqual(fixture.session.oversight.pendingAutoWake?.phase, .cancelledBeforeDispatch)
        XCTAssertFalse(fixture.viewModel.agentSessionLinkAcquirePhysicalDispatch(
            for: fixture.session, dispatchID: .autoWake(wakeID: wakeID)
        ), "the held wake must never reach a provider call")
    }

    func testIdleStopInvalidatesUnmodeledDeferredStartFence() async throws {
        let fixture = try makeFixture()
        let deferredFence = AgentRunStartStopFence(session: fixture.session)
        guard case let .settled(receipt) = await stop(fixture) else { return XCTFail("expected receipt") }
        XCTAssertEqual(receipt.result, .notRunning)
        XCTAssertFalse(deferredFence.permitsStart(of: fixture.session))
    }

    func testManagedStopGateSuppressesPublishedSendReadiness() throws {
        let fixture = try makeFixture()
        func snapshot() -> DomainAgentSessionObservationSnapshot {
            AgentModeViewModel.observationSnapshot(
                for: fixture.session, candidate: fixture.candidate, subagentCounts: (running: 0, finished: 0)
            )
        }
        XCTAssertTrue(snapshot().idleForSend)
        XCTAssertTrue(snapshot().board.sendBlockers.isEmpty)
        let binding = try XCTUnwrap(fixture.session.persistentSessionBindingIdentity)
        let stopID = UUID()
        XCTAssertTrue(fixture.session.stopState.claimManagedStop(id: stopID, binding: binding))
        XCTAssertFalse(snapshot().idleForSend, "poll/wait must not report sendable while Stop owns the target")
        XCTAssertEqual(snapshot().board.sendBlockers, ["stop_in_progress"])
        XCTAssertTrue(fixture.session.stopState.releaseManagedStop(id: stopID, binding: binding))
        XCTAssertTrue(snapshot().idleForSend)
        XCTAssertTrue(snapshot().board.sendBlockers.isEmpty)
    }

    func testPendingStartWithdrawsWithoutSyntheticTerminalRun() async throws {
        let fixture = try makeFixture()
        fixture.session.runState = .completed
        fixture.session.mcpFollowUpRunPending = true
        fixture.session.pendingInstructions = ["the user's queued instruction"]
        fixture.session.pendingClaudeSteeringInstructions = [
            .init(
                id: UUID(), targetRunID: nil, targetRunAttemptID: nil,
                providerText: "local queued steer", attachments: [], taggedFileAttachments: [],
                draftText: "local queued steer", optimisticUserItemID: nil, createdAt: Date()
            )
        ]
        let beforeRevision = fixture.session.lastTerminalCommitRevision
        let outcome = await stop(fixture)
        guard case let .settled(receipt) = outcome else { return XCTFail("expected receipt") }
        XCTAssertEqual(receipt.result, .stopped)
        XCTAssertFalse(fixture.session.mcpFollowUpRunPending)
        XCTAssertTrue(fixture.session.pendingInstructions.isEmpty)
        XCTAssertTrue(fixture.session.pendingClaudeSteeringInstructions.isEmpty)
        XCTAssertEqual(fixture.session.runState, .completed)
        XCTAssertEqual(fixture.session.lastTerminalCommitRevision, beforeRevision)
        XCTAssertEqual(fixture.session.items.count(where: { $0.text == AgentChatItem.overseerRunStoppedText }), 1)
    }

    func testManagedPendingContentIsDroppedNotRestoredAsUserDraft() async throws {
        let fixture = try makeFixture()
        fixture.viewModel.storeDraftText(for: fixture.tabID, "the user's own draft")
        fixture.session.mcpFollowUpRunPending = true
        fixture.session.pendingInstructions = [.providerOnly(AgentSessionLinkMessageEnvelope.render(
            sourceSessionID: UUID(), sourceName: "Overseer", linkID: UUID(),
            linkGeneration: 1, message: "overseer-only", framing: .management
        ))]
        fixture.session.pendingClaudeSteeringInstructions = [
            .init(
                id: UUID(), targetRunID: nil, targetRunAttemptID: nil,
                providerText: "overseer-only", attachments: [], taggedFileAttachments: [],
                draftText: "", optimisticUserItemID: nil, createdAt: Date()
            )
        ]
        let outcome = await stop(fixture)
        guard case let .settled(receipt) = outcome else { return XCTFail("expected receipt") }
        XCTAssertEqual(receipt.result, .stopped)
        XCTAssertEqual(fixture.viewModel.retrieveDraftText(for: fixture.tabID), "the user's own draft")
        XCTAssertFalse(fixture.viewModel.retrieveDraftText(for: fixture.tabID).contains("overseer-only"))
        XCTAssertTrue(fixture.session.pendingClaudeSteeringInstructions.isEmpty)
    }

    func testActiveRunUsesCancellationSpineAndAttributedFactRow() async throws {
        let fixture = try makeFixture()
        fixture.session.runState = .running
        fixture.session.installRunID(UUID())
        _ = fixture.session.beginRunAttempt(source: "overseer-stop-test")
        let outcome = await stop(fixture)
        guard case let .settled(receipt) = outcome else { return XCTFail("expected receipt") }
        XCTAssertEqual(receipt.result, .stopped)
        XCTAssertEqual(fixture.session.runState, .cancelled)
        XCTAssertTrue(receipt.teardownCompleted == true)
        XCTAssertEqual(fixture.session.items.count(where: { $0.text == AgentChatItem.overseerRunStoppedText }), 1)
    }

    func testTimedOutOldBindingGateDoesNotWedgeStopAfterInPlaceRebind() async throws {
        let fixture = try makeFixture()
        let oldBinding = try XCTUnwrap(fixture.session.persistentSessionBindingIdentity)
        let oldStopID = UUID()
        XCTAssertTrue(fixture.session.stopState.claimManagedStop(id: oldStopID, binding: oldBinding))
        fixture.session.stopState.markCleanupStarted(id: oldStopID, binding: oldBinding)
        fixture.session.stopState.test_ageManagedStopClaim(by: 31)
        fixture.session.installPersistentSessionBinding(
            AgentPersistentSessionBindingIdentity(tabID: fixture.tabID, sessionID: fixture.candidate.sessionID)
        )
        let reboundCandidate = try XCTUnwrap(fixture.viewModel.agentSessionLinkCandidate(
            tabID: fixture.tabID, sessionID: fixture.candidate.sessionID,
            tabName: "Stop target", isWindowClosing: false
        ))
        let rebound = Fixture(
            viewModel: fixture.viewModel, tabID: fixture.tabID,
            session: fixture.session, candidate: reboundCandidate
        )
        fixture.session.runState = .running
        fixture.session.installRunID(UUID())
        _ = fixture.session.beginRunAttempt(source: "rebound-managed-stop")
        let outcome = await stop(rebound)
        guard case let .settled(receipt) = outcome else { return XCTFail("expected receipt") }
        XCTAssertEqual(receipt.result, .stopped)
        XCTAssertFalse(fixture.session.stopState.releaseManagedStop(id: oldStopID, binding: oldBinding))
    }

    func testSuccessfulStopRetainsResultWhenAuditSaveFails() async throws {
        let fixture = try makeFixture()
        fixture.session.runState = .running
        fixture.session.installRunID(UUID())
        _ = fixture.session.beginRunAttempt(source: "stop-save-failure")
        fixture.viewModel.test_setAgentSessionSaver { _, _, _ in
            throw NSError(domain: "StopAuditFailure", code: 1)
        }
        let outcome = await stop(fixture)
        guard case let .settled(receipt) = outcome else { return XCTFail("expected receipt") }
        XCTAssertEqual(receipt.result, .stopped)
        XCTAssertEqual(receipt.auditStatus, .failed)
        let rendered = try AgentSessionLinkMCPToolService.stopOutcomeValue(
            .receipt(receipt), targetSessionID: fixture.candidate.sessionID
        )
        XCTAssertNotNil(rendered.objectValue?["warning"]?.stringValue)
        XCTAssertEqual(fixture.session.runState, .cancelled)
        XCTAssertEqual(fixture.session.items.count(where: { $0.text == AgentChatItem.overseerRunStoppedText }), 1)
    }

    func testTeardownReleasedBeforeDeadlineReturnsStoppedWithCompletedCleanup() async throws {
        let fixture = try makeFixture()
        fixture.session.runState = .running
        fixture.session.installRunID(UUID())
        let ownership = fixture.session.beginRunAttempt(source: "stop-teardown-before-deadline")
        let entered = AgentSessionLinkStopSignal<Void>()
        let release = AgentSessionLinkStopSignal<Void>()
        let deadline = AgentSessionLinkStopSignal<Void>()
        fixture.session.installRunAttemptTerminalResources(ownership: ownership) { _ in
            {
                entered.finish(())
                await release.value()
            }
        }
        addTeardownBlock {
            release.finish(())
            deadline.finish(())
        }

        let stopping = Task {
            await self.stop(fixture, teardownDeadlineSeconds: 30, deadlineSleep: { seconds in
                if seconds == 30 {
                    await deadline.value()
                } else {
                    try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                }
            })
        }
        await entered.value()
        release.finish(())
        guard case let .settled(receipt) = await stopping.value else { return XCTFail("expected receipt") }
        XCTAssertEqual(receipt.result, .stopped)
        XCTAssertEqual(receipt.teardownCompleted, true)
        XCTAssertEqual(receipt.auditStatus, .persisted)
        XCTAssertEqual(fixture.session.runState, .cancelled)
        deadline.finish(())
    }

    func testTeardownDeadlineRetainsStopFailedTimeoutAndKeepsExecutingCleanupClaimed() async throws {
        let fixture = try makeFixture()
        fixture.session.runState = .running
        fixture.session.installRunID(UUID())
        let ownership = fixture.session.beginRunAttempt(source: "stop-teardown-after-deadline")
        let entered = AgentSessionLinkStopSignal<Void>()
        let release = AgentSessionLinkStopSignal<Void>()
        let deadline = AgentSessionLinkStopSignal<Void>()
        fixture.session.installRunAttemptTerminalResources(ownership: ownership) { _ in
            {
                entered.finish(())
                await release.value()
            }
        }
        addTeardownBlock {
            release.finish(())
            deadline.finish(())
        }

        let stopping = Task {
            await self.stop(fixture, teardownDeadlineSeconds: 30, deadlineSleep: { seconds in
                if seconds == 30 {
                    await deadline.value()
                } else {
                    try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                }
            })
        }
        await entered.value()
        deadline.finish(())
        guard case let .settled(receipt) = await stopping.value else { return XCTFail("expected receipt") }
        XCTAssertEqual(receipt.result, .stopFailed)
        XCTAssertEqual(receipt.failureReason, .teardownTimeout)
        XCTAssertEqual(receipt.teardownCompleted, false)
        XCTAssertEqual(receipt.auditStatus, .unknown)
        let rendered = try AgentSessionLinkMCPToolService.stopOutcomeValue(
            .receipt(receipt), targetSessionID: fixture.candidate.sessionID
        )
        XCTAssertNotNil(rendered.objectValue?["warning"]?.stringValue)
        XCTAssertEqual(rendered.objectValue?["reason"]?.stringValue, "teardown_timeout")
        XCTAssertEqual(fixture.session.runState, .cancelled)
        let binding = try XCTUnwrap(fixture.session.persistentSessionBindingIdentity)
        XCTAssertTrue(fixture.session.stopState.isStopping(binding: binding))
        XCTAssertFalse(
            fixture.session.stopState.forceRetireUnclaimedStop(binding: binding),
            "deadline must not mark already-started teardown unclaimed"
        )
        release.finish(())
        try await AsyncTestWait.waitUntil("late teardown releases the stop gate") {
            !fixture.session.stopState.isStopping(binding: binding)
        }
    }

    func testSecondUserStopRetiresStartedTimedOutTeardownGate() async throws {
        let fixture = try makeFixture()
        fixture.session.runState = .running
        fixture.session.installRunID(UUID())
        let ownership = fixture.session.beginRunAttempt(source: "started-wedged-stop")
        let entered = AgentSessionLinkStopSignal<Void>()
        let release = AgentSessionLinkStopSignal<Void>()
        let deadline = AgentSessionLinkStopSignal<Void>()
        fixture.session.installRunAttemptTerminalResources(ownership: ownership) { _ in
            {
                entered.finish(())
                await release.value()
            }
        }
        addTeardownBlock {
            release.finish(())
            deadline.finish(())
        }
        let stopping = Task {
            await self.stop(fixture, teardownDeadlineSeconds: 30, deadlineSleep: { seconds in
                if seconds == 30 { await deadline.value() }
            })
        }
        await entered.value()
        deadline.finish(())
        guard case let .settled(receipt) = await stopping.value else { return XCTFail("expected receipt") }
        XCTAssertEqual(receipt.failureReason, .teardownTimeout)
        let binding = try XCTUnwrap(fixture.session.persistentSessionBindingIdentity)
        XCTAssertTrue(fixture.session.stopState.isStopping(binding: binding))
        fixture.session.stopState.test_ageManagedStopClaim(by: 31)
        await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID)
        XCTAssertFalse(fixture.session.stopState.isStopping(binding: binding))
        release.finish(())
        XCTAssertFalse(fixture.session.stopState.isStopping(binding: binding), "late cleanup cannot reclaim the gate")
    }

    func testAuditRebindDuringSaveCannotClaimOriginalRowPersisted() async throws {
        let fixture = try makeFixture()
        fixture.session.runState = .running
        fixture.session.installRunID(UUID())
        _ = fixture.session.beginRunAttempt(source: "stop-audit-rebind")
        let manager = try XCTUnwrap(fixture.viewModel.workspaceManager)
        fixture.viewModel.test_setAgentSessionSaver { agentSession, _, _ in
            if agentSession.toLiveItems().contains(where: { $0.text == AgentChatItem.overseerRunStoppedText }) {
                _ = manager.compareAndSetActiveAgentSessionID(
                    expected: fixture.candidate.sessionID, replacement: UUID(),
                    forTabID: fixture.tabID, inWorkspaceID: fixture.candidate.workspaceID
                )
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("\(UUID().uuidString).json")
        }
        let outcome = await stop(fixture)
        guard case let .settled(receipt) = outcome else { return XCTFail("expected receipt") }
        XCTAssertEqual(receipt.result, .stopped)
        XCTAssertEqual(receipt.auditStatus, .failed)
    }

    func testAuditDeadlineRetainsUnknownWithoutRepeatingCancellation() async throws {
        let fixture = try makeFixture()
        fixture.session.runState = .running
        fixture.session.installRunID(UUID())
        _ = fixture.session.beginRunAttempt(source: "stop-save-timeout")
        let saveEntered = AgentSessionLinkStopSignal<Void>()
        let saveRelease = AgentSessionLinkStopSignal<Void>()
        let deadline = AgentSessionLinkStopSignal<Void>()
        fixture.viewModel.test_setAgentSessionSaver { _, _, _ in
            saveEntered.finish(())
            await saveRelease.value()
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("\(UUID().uuidString).json")
        }
        addTeardownBlock {
            saveRelease.finish(())
            deadline.finish(())
        }
        let stopping = Task {
            await self.stop(fixture, auditDeadlineSeconds: 5, deadlineSleep: { seconds in
                if seconds == 5 {
                    await deadline.value()
                } else {
                    try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                }
            })
        }
        await saveEntered.value()
        deadline.finish(())
        guard case let .settled(receipt) = await stopping.value else { return XCTFail("expected receipt") }
        XCTAssertEqual(receipt.result, .stopped)
        XCTAssertEqual(receipt.auditStatus, .unknown)
        let rendered = try AgentSessionLinkMCPToolService.stopOutcomeValue(
            .receipt(receipt), targetSessionID: fixture.candidate.sessionID
        )
        XCTAssertNotNil(rendered.objectValue?["warning"]?.stringValue)
        XCTAssertEqual(fixture.session.runState, .cancelled)
        XCTAssertEqual(fixture.session.items.count(where: { $0.text == AgentChatItem.overseerRunStoppedText }), 1)
        saveRelease.finish(())
    }

    func testSecondUserStopForceRetiresUnclaimedTerminalGate() async throws {
        let fixture = try makeFixture()
        fixture.session.runState = .running
        fixture.session.installRunID(UUID())
        _ = fixture.session.beginRunAttempt(source: "wedged-stop-gate")
        guard case .settled = await stop(fixture) else { return XCTFail("expected Stop receipt") }
        let binding = try XCTUnwrap(fixture.session.persistentSessionBindingIdentity)
        let wedgedID = UUID()
        XCTAssertTrue(fixture.session.stopState.claimManagedStop(id: wedgedID, binding: binding))
        fixture.session.stopState.markCleanupUnclaimedIfNeverStarted(id: wedgedID, binding: binding)
        XCTAssertTrue(fixture.session.stopState.isStopping(binding: binding))
        let foreignBinding = AgentPersistentSessionBindingIdentity(
            tabID: fixture.tabID, sessionID: UUID()
        )
        XCTAssertFalse(fixture.session.stopState.forceRetireUnclaimedStop(binding: foreignBinding))
        XCTAssertTrue(fixture.session.stopState.isStopping(binding: binding))
        await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID)
        XCTAssertFalse(fixture.session.stopState.isStopping(binding: binding))
    }

    func testCleanupDeadlineNeverUnclaimsAnExecutingTeardown() throws {
        let fixture = try makeFixture()
        let binding = try XCTUnwrap(fixture.session.persistentSessionBindingIdentity)
        let stopID = UUID()
        XCTAssertTrue(fixture.session.stopState.claimManagedStop(id: stopID, binding: binding))
        fixture.session.stopState.markCleanupStarted(id: stopID, binding: binding)
        fixture.session.stopState.markCleanupUnclaimedIfNeverStarted(id: stopID, binding: binding)
        XCTAssertTrue(fixture.session.stopState.isStopping(binding: binding))
        XCTAssertFalse(fixture.session.stopState.forceRetireUnclaimedStop(binding: binding))
        XCTAssertTrue(fixture.session.stopState.releaseManagedStop(id: stopID, binding: binding))
    }

    func testLocalStopWithdrawsQueuesAfterRealCompletedTerminalRevision() async throws {
        let fixture = try makeFixture()
        fixture.session.runState = .running
        fixture.session.installRunID(UUID())
        _ = fixture.session.beginRunAttempt(source: "completed-before-local-stop")
        await fixture.viewModel.test_publishNaturalCompletion(fixture.session)
        let revision = try XCTUnwrap(fixture.session.lastTerminalCommitRevision)
        XCTAssertEqual(revision.terminalState, .completed)
        fixture.session.pendingInstructions = ["queued local follow-up"]
        fixture.session.pendingClaudeSteeringInstructions = [
            .init(
                id: UUID(), targetRunID: nil, targetRunAttemptID: nil,
                providerText: "queued Claude steer", attachments: [], taggedFileAttachments: [],
                draftText: "queued Claude steer", optimisticUserItemID: nil, createdAt: Date()
            )
        ]
        fixture.session.pendingNonCodexUserInputTokenQueue = [111]
        await fixture.viewModel.cancelAgentRun(tabID: fixture.tabID)
        XCTAssertTrue(fixture.session.pendingInstructions.isEmpty)
        XCTAssertTrue(fixture.session.pendingClaudeSteeringInstructions.isEmpty)
        XCTAssertTrue(fixture.session.pendingACPSteeringInstructions.isEmpty)
        XCTAssertTrue(fixture.session.pendingNonCodexUserInputTokenQueue.isEmpty)
        XCTAssertEqual(fixture.session.lastTerminalCommitRevision, revision)
    }

    func testNaturalCompletionAfterCancellationAdmissionSettlesNotRunning() async throws {
        let fixture = try makeFixture()
        fixture.session.runState = .running
        fixture.session.installRunID(UUID())
        _ = fixture.session.beginRunAttempt(source: "natural-completion-after-admission")
        fixture.viewModel.test_setBeforeCancellationCommit { session in
            await fixture.viewModel.test_publishNaturalCompletion(session)
        }
        defer { fixture.viewModel.test_setBeforeCancellationCommit(nil) }
        guard case let .settled(receipt) = await stop(fixture) else { return XCTFail("expected receipt") }
        XCTAssertEqual(receipt.result, .notRunning)
        XCTAssertEqual(receipt.stopRequested, true)
        XCTAssertEqual(fixture.session.lastTerminalCommitRevision?.terminalState, .completed)
        XCTAssertFalse(fixture.session.items.contains(where: { $0.text == AgentChatItem.overseerRunStoppedText }))
    }

    func testClaimLostBeforeCancellationReportsTargetChanged() async throws {
        let fixture = try makeFixture()
        fixture.session.runState = .running
        fixture.session.installRunID(UUID())
        _ = fixture.session.beginRunAttempt(source: "target-changed-before-task-entry")
        let outcome = await stop(fixture, beforeCleanupTask: {
            fixture.session.installRunID(UUID())
        })
        guard case let .settled(receipt) = outcome else { return XCTFail("expected receipt") }
        XCTAssertEqual(receipt.result, .stopFailed)
        XCTAssertEqual(receipt.failureReason, .targetChanged)
        XCTAssertEqual(receipt.stopRequested, false)
    }

    func testTerminalReplacementBeforeCleanupCannotMasqueradeAsNaturalCompletion() async throws {
        let fixture = try makeFixture()
        fixture.session.runState = .running
        fixture.session.installRunID(UUID())
        _ = fixture.session.beginRunAttempt(source: "captured-before-terminal-rebind")
        let outcome = await stop(fixture, beforeCleanupTask: {
            fixture.session.installPersistentSessionBinding(
                AgentPersistentSessionBindingIdentity(tabID: fixture.tabID, sessionID: UUID())
            )
            fixture.session.installRunID(UUID())
            _ = fixture.session.beginRunAttempt(source: "terminal-replacement")
            fixture.session.runState = .completed
        })
        guard case let .settled(receipt) = outcome else { return XCTFail("expected retained receipt") }
        XCTAssertEqual(receipt.result, .stopFailed)
        XCTAssertEqual(receipt.failureReason, .targetChanged)
        XCTAssertEqual(receipt.stopRequested, false)
        XCTAssertNil(receipt.resultingRunState)
        XCTAssertNil(receipt.targetItemID)
        XCTAssertEqual(fixture.session.runState, .completed)
        XCTAssertFalse(fixture.session.items.contains(where: { $0.text == AgentChatItem.overseerRunStoppedText }))
        let rendered = try AgentSessionLinkMCPToolService.stopOutcomeValue(
            .receipt(receipt), targetSessionID: fixture.candidate.sessionID
        )
        fixture.session.runState = .failed
        let replay = try AgentSessionLinkMCPToolService.stopOutcomeValue(
            .receipt(receipt), targetSessionID: fixture.candidate.sessionID
        )
        XCTAssertEqual(replay, rendered, "retained receipt must not resample replacement state")
    }

    func testNaturalCompletionBeforeTaskEntryIsNoopWithoutAttribution() async throws {
        let fixture = try makeFixture()
        fixture.session.runState = .running
        fixture.session.installRunID(UUID())
        _ = fixture.session.beginRunAttempt(source: "natural-completion-race")
        fixture.session.mcpFollowUpRunPending = true
        fixture.session.pendingInstructions = ["held local follow-up"]
        let heldFence = AgentRunStartStopFence(session: fixture.session)
        let outcome = await stop(fixture, beforeCleanupTask: {
            fixture.session.runState = .completed
        })
        guard case let .settled(receipt) = outcome else { return XCTFail("expected receipt") }
        XCTAssertEqual(receipt.result, .notRunning)
        XCTAssertEqual(receipt.stopRequested, false)
        XCTAssertNil(receipt.targetItemID)
        XCTAssertFalse(heldFence.permitsStart(of: fixture.session))
        XCTAssertFalse(fixture.session.mcpFollowUpRunPending)
        XCTAssertTrue(fixture.session.pendingInstructions.isEmpty)
        XCTAssertTrue(fixture.session.items.allSatisfy { $0.text != AgentChatItem.overseerRunStoppedText })
    }

    func testClaudeAttachmentRestartRejectsInPlaceRebindDuringSuspension() async throws {
        let fixture = try makeFixture()
        fixture.session.runState = .waitingForUser
        fixture.session.installRunID(UUID())
        _ = fixture.session.beginRunAttempt(source: "claude-attachment-restart")
        let reachedRestart = AgentSessionLinkStopSignal<Void>()
        let releaseRestart = AgentSessionLinkStopSignal<Void>()
        let finishedRestart = AgentSessionLinkStopSignal<Void>()
        addTeardownBlock { releaseRestart.finish(()) }
        fixture.viewModel.test_afterClaudeAttachmentSelfCancel = {
            reachedRestart.finish(())
            await releaseRestart.value()
        }
        fixture.viewModel.test_claudeAttachmentRestartFinished = { finishedRestart.finish(()) }
        defer {
            fixture.viewModel.test_afterClaudeAttachmentSelfCancel = nil
            fixture.viewModel.test_claudeAttachmentRestartFinished = nil
        }
        let attachment = AgentImageAttachment(source: .url("https://example.test/old-image.png"))
        guard case .submitted = fixture.viewModel.test_submitWaitingClaudeAttachment(
            session: fixture.session, text: "old binding text", attachment: attachment
        ) else { return XCTFail("expected scheduled attachment restart") }
        await reachedRestart.value()
        let replacementBinding = AgentPersistentSessionBindingIdentity(
            tabID: fixture.tabID, sessionID: fixture.candidate.sessionID
        )
        fixture.session.installPersistentSessionBinding(replacementBinding)
        fixture.viewModel.storeDraftText(for: fixture.tabID, "replacement draft")
        releaseRestart.finish(())
        await finishedRestart.value()
        XCTAssertEqual(fixture.viewModel.retrieveDraftText(for: fixture.tabID), "replacement draft")
        XCTAssertNotEqual(fixture.session.runState, .running)
    }

    func testHydrationDeferredSubmissionNeverRestoresIntoReplacementSession() async throws {
        let fixture = try makeFixture()
        let originalBinding = fixture.session.persistentSessionBindingIdentity
        let heldFence = AgentRunStartStopFence(session: fixture.session)
        let replacement = AgentTabSession(tabID: fixture.tabID)
        replacement.hasLoadedPersistedState = true
        replacement.testInstallPersistentSessionBinding(sessionID: UUID())
        fixture.viewModel.test_replaceSessionForDeferredHydration(tabID: fixture.tabID, with: replacement)
        fixture.viewModel.storeDraftText(for: fixture.tabID, "replacement draft")

        await fixture.viewModel.submitUserTurnAfterHydration(
            tabID: fixture.tabID, originalSession: fixture.session,
            originalBinding: originalBinding, trimmedText: "old session draft",
            attachmentsToSend: [], taggedFilesToSend: [], activeWorkflow: nil,
            stopFence: heldFence
        )
        XCTAssertEqual(fixture.viewModel.retrieveDraftText(for: fixture.tabID), "replacement draft")
        XCTAssertTrue(replacement.pendingImageAttachments.isEmpty)
        XCTAssertTrue(replacement.pendingTaggedFileAttachments.isEmpty)
    }

    func testPermanentStopFenceLossDoesNotRenderAsRetryableBusy() throws {
        for failure in [AgentSessionLinkSendFailure.endpointInvalidated, .linkRevoked, .managementRevoked, .shuttingDown] {
            XCTAssertThrowsError(try AgentSessionLinkMCPToolService.stopOutcomeValue(
                .blocked(failure), targetSessionID: UUID()
            ))
        }
        let busy = try AgentSessionLinkMCPToolService.stopOutcomeValue(
            .blocked(.targetBusy), targetSessionID: UUID()
        )
        XCTAssertEqual(busy.objectValue?["result"]?.stringValue, "target_busy")
    }

    func testIndeterminateStopRendersNonRetryableFailure() throws {
        let rendered = try AgentSessionLinkMCPToolService.stopOutcomeValue(
            .indeterminate, targetSessionID: UUID()
        )
        XCTAssertEqual(rendered.objectValue?["result"]?.stringValue, "stop_failed")
        XCTAssertEqual(rendered.objectValue?["reason"]?.stringValue, "cancellation_unconfirmed")
        XCTAssertEqual(rendered.objectValue?["retryable"], .bool(false))
    }

    func testPureAdmissionSelectsActiveWaitingAndPendingStart() {
        for waiting in [AgentSessionRunState.running, .waitingForUser, .waitingForQuestion, .waitingForApproval] {
            var snapshot = AgentSessionLinkDeliveryReadiness.Snapshot.ready
            snapshot.runStateIsActive = waiting.isActive
            snapshot.hasWaitingPrompt = waiting == .waitingForUser
            XCTAssertEqual(AgentSessionLinkStopAdmission.classify(snapshot), .activeRun)
        }
        var pending = AgentSessionLinkDeliveryReadiness.Snapshot.ready
        pending.mcpFollowUpRunPending = true
        XCTAssertEqual(AgentSessionLinkStopAdmission.classify(pending), .pendingStart)
        pending.mcpFollowUpRunPending = false
        pending.pendingInstructionCount = 1
        XCTAssertEqual(AgentSessionLinkStopAdmission.classify(pending), .pendingStart)
        XCTAssertEqual(AgentSessionLinkStopAdmission.classify(.ready), .notRunning)
    }

    func testBusyAndLifecycleRefusalsTakePrecedence() {
        var snapshot = AgentSessionLinkDeliveryReadiness.Snapshot.ready
        snapshot.runStateIsActive = true
        snapshot.terminalCommitInProgress = true
        XCTAssertEqual(AgentSessionLinkStopAdmission.classify(snapshot), .blocked(.targetBusy))
        snapshot.terminalCommitInProgress = false
        snapshot.stopInProgress = true
        XCTAssertEqual(AgentSessionLinkStopAdmission.classify(snapshot), .blocked(.targetBusy))
        snapshot.stopInProgress = false
        snapshot.hasLoadedPersistedState = false
        XCTAssertEqual(AgentSessionLinkStopAdmission.classify(snapshot), .blocked(.targetLoading))
        snapshot.endpointMatchesGrant = false
        XCTAssertEqual(AgentSessionLinkStopAdmission.classify(snapshot), .blocked(.endpointInvalidated))
    }

    func testInteractionIsNotABlockerAndUnsentDraftIsNotInSnapshot() {
        var snapshot = AgentSessionLinkDeliveryReadiness.Snapshot.ready
        snapshot.runStateIsActive = true
        snapshot.hasPendingApproval = true
        snapshot.hasPendingAskUser = true
        XCTAssertEqual(AgentSessionLinkStopAdmission.classify(snapshot), .activeRun)
    }
}
