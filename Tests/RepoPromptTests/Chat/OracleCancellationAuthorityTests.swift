import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

@MainActor
final class OracleCancellationAuthorityTests: XCTestCase {
    func testForegroundExplicitCancelPreservesResolvedAuthorityForReloadAndContinuation() async throws {
        try await assertCancellationPreservesAuthority(.explicit)
    }

    func testPreTokenTransportCancelPreservesResolvedAuthorityForReloadAndContinuation() async throws {
        try await assertCancellationPreservesAuthority(.transport)
    }

    func testImagePreparationPublicationOwnership() async throws {
        let composition = WindowStateCompositionFactory.make(
            windowID: -9342, deferredInitialAgentSystemWorkspaceRefresh: true, sharedMCPService: MCPService()
        )
        await composition.workspaceManager.awaitInitialized()
        let oracle = composition.oracleViewModel
        defer {
            oracle.oracleImageThumbnailsForTesting = nil
            oracle.setOraclePostPackagingTransportOverrideForTesting(nil)
            composition.workspaceManager.prepareForWindowClose()
            oracle.sessions = []
        }
        composition.apiSettingsViewModel.openAIApiKey = "test-key"
        composition.apiSettingsViewModel.isOpenAIKeyValid = true
        await oracle.startNewChatSession()
        let sessionID = try XCTUnwrap(oracle.currentSessionID)
        let original = AITransientImage(bytes: Data([1, 2, 3]), mediaType: .png, title: "original")
        var gates: [CheckedContinuation<[AIChatImageAttachment], Error>] = []
        var sent: [AIMessage] = []
        oracle.oracleImageThumbnailsForTesting = { _ in
            try await withCheckedThrowingContinuation { gates.append($0) }
        }
        oracle.setOraclePostPackagingTransportOverrideForTesting { message, _ in
            sent.append(message)
            return (UUID(), AsyncThrowingStream { continuation in
                continuation.yield(ChatStreamOutput(text: "done", reasoning: nil, tokens: ChatTokenInfo(), terminalOutcome: .completed))
                continuation.finish()
            })
        }
        func begin(_ text: String, scope: ContextBuilderOracleLaneScope? = nil) -> Task<UUID?, Never> {
            Task { await oracle.sendMessage(
                text,
                sessionID: sessionID,
                overrideModel: .gpt54Mini,
                oracleTransientImages: [original],
                contextBuilderScope: scope
            ) }
        }
        func waitForGate(_ count: Int) async throws {
            try await AsyncTestWait.waitUntil("thumbnail preparation \(count)") { gates.count == count }
        }
        func waitForCompletion(_ id: UUID, in target: UUID) async throws {
            try await AsyncTestWait.waitUntil("prepared image send completion") {
                !oracle.isSessionStreaming(target) && oracle.messagesSnapshot(for: target).contains {
                    $0.id == id && $0.isFinalized && $0.content == "done"
                }
            }
        }

        let cancelled = begin("cancelled")
        try await waitForGate(1)
        cancelled.cancel()
        gates[0].resume(returning: [])
        let cancelledResult = await cancelled.value
        XCTAssertNil(cancelledResult)

        let group = ContextBuilderOracleGroupSupervision()
        let revoked = begin("revoked", scope: group.makeLane(sessionID: sessionID))
        try await waitForGate(2)
        group.cancel()
        gates[1].resume(returning: [])
        let revokedResult = await revoked.value
        XCTAssertNil(revokedResult)
        XCTAssertTrue(oracle.messagesSnapshot(for: sessionID).isEmpty)
        XCTAssertTrue(sent.isEmpty)

        let older = begin("older")
        try await waitForGate(3)
        let newer = begin("newer")
        try await waitForGate(4)
        gates[2].resume(returning: [])
        let olderResult = await older.value
        XCTAssertNil(olderResult)
        // An obsolete preparation must not clear the newer owner's token.
        gates[3].resume(returning: [])
        let newerResult = await newer.value
        XCTAssertNotNil(newerResult)
        if let newerResult { try await waitForCompletion(newerResult, in: sessionID) }

        let beforeText = begin("before text")
        try await waitForGate(5)
        let textResult = await oracle.sendMessage("text successor", sessionID: sessionID, overrideModel: .gpt54Mini)
        if let textResult { try await waitForCompletion(textResult, in: sessionID) }
        gates[4].resume(returning: [])
        let beforeTextResult = await beforeText.value
        XCTAssertNil(beforeTextResult)

        let explicitlyCancelled = begin("explicit cancel")
        try await waitForGate(6)
        await oracle.cancelAIResponse(in: sessionID)
        gates[5].resume(returning: [])
        let explicitResult = await explicitlyCancelled.value
        XCTAssertNil(explicitResult)

        let reset = begin("reset")
        try await waitForGate(7)
        await oracle.cancelAllActiveSessionStreams()
        gates[6].resume(returning: [])
        let resetResult = await reset.value
        XCTAssertNil(resetResult)

        let background = begin("background")
        try await waitForGate(8)
        await oracle.startNewChatSession()
        gates[7].resume(returning: [])
        let backgroundResult = await background.value
        XCTAssertNotNil(backgroundResult)
        if let backgroundResult { try await waitForCompletion(backgroundResult, in: sessionID) }

        let obsolete = begin("obsolete")
        try await waitForGate(9)
        let latest = begin("latest")
        try await waitForGate(10)
        gates[9].resume(returning: [])
        let latestResult = await latest.value
        XCTAssertNotNil(latestResult)
        if let latestResult { try await waitForCompletion(latestResult, in: sessionID) }
        gates[8].resume(returning: [])
        let obsoleteResult = await obsolete.value
        XCTAssertNil(obsoleteResult)

        XCTAssertEqual(
            oracle.messagesSnapshot(for: sessionID).filter(\.isUser).map(\.content),
            ["newer", "text successor", "background", "latest"]
        )
        XCTAssertTrue(oracle.messagesSnapshot(for: sessionID).filter(\.isUser).allSatisfy(\.imageAttachments.isEmpty))

        let deleted = begin("deleted")
        try await waitForGate(11)
        oracle.purgeSessionStorage(sessionID)
        gates[10].resume(returning: [])
        let deletedResult = await deleted.value
        XCTAssertNil(deletedResult)
        XCTAssertTrue(oracle.messagesSnapshot(for: sessionID).isEmpty)
        XCTAssertEqual(
            sent.map { $0.conversationMessages.last?.content ?? "" },
            ["newer", "text successor", "background", "latest"].map { "<user_instructions>\n\($0)\n</user_instructions>" }
        )
        XCTAssertEqual(sent.first?.transientImages.first?.bytes, original.bytes)
        XCTAssertEqual(sent.last?.transientImages.first?.bytes, original.bytes)

        // Exercise real preview failure through sendMessage, not just the ordering override.
        oracle.oracleImageThumbnailsForTesting = nil
        let visibleSessionID = try XCTUnwrap(oracle.currentSessionID)
        let placeholder = await oracle.sendMessage(
            "unavailable preview",
            sessionID: visibleSessionID,
            overrideModel: .gpt54Mini,
            oracleTransientImages: [original]
        )
        let placeholderID = try XCTUnwrap(placeholder)
        try await waitForCompletion(placeholderID, in: visibleSessionID)
        XCTAssertEqual(sent.count, 5)
        XCTAssertEqual(sent.last?.transientImages.first?.bytes, original.bytes)
        let previews = try XCTUnwrap(oracle.messagesSnapshot(for: visibleSessionID).first(where: \.isUser)?.imageAttachments)
        XCTAssertEqual(previews.count, 1)
        XCTAssertTrue(previews[0].thumbnailData.isEmpty)
    }

    private enum CancellationKind: Equatable {
        case explicit
        case transport
    }

    private func assertCancellationPreservesAuthority(_ cancellationKind: CancellationKind) async throws {
        let composition = WindowStateCompositionFactory.make(
            windowID: cancellationKind == .explicit ? -9340 : -9341,
            deferredInitialAgentSystemWorkspaceRefresh: true,
            sharedMCPService: MCPService()
        )
        await composition.workspaceManager.awaitInitialized()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OracleCancellationAuthority-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            composition.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting(nil)
            composition.workspaceManager.prepareForWindowClose()
            composition.oracleViewModel.sessions = []
            try? FileManager.default.removeItem(at: root)
        }

        var workspace = try XCTUnwrap(composition.workspaceManager.activeWorkspace)
        let tab = ComposeTabState(id: UUID())
        workspace.customStoragePath = root
        workspace.composeTabs = [tab]
        workspace.activeComposeTabID = tab.id
        if let index = composition.workspaceManager.workspaces.firstIndex(where: { $0.id == workspace.id }) {
            composition.workspaceManager.workspaces[index] = workspace
        }
        composition.workspaceManager.activeWorkspace = workspace
        composition.promptManager.loadComposeTabsFromWorkspace(workspace)
        composition.apiSettingsViewModel.openAIApiKey = "test-key"
        composition.apiSettingsViewModel.isOpenAIKeyValid = true
        composition.promptManager.preferredModel = AIModel.gpt54.rawValue
        composition.promptManager.selectedChatPresetID = ChatPreset.BuiltIn.chat.id

        let promptID = UUID()
        let promptMarker = "CANCELLED ORACLE CUSTOM REVIEW"
        composition.promptManager.storedPrompts.append(
            StoredPromptRecord(id: promptID, title: "[Cancelled Review]", content: promptMarker)
        )
        let chatPreset = ChatPreset(
            name: "Cancelled Review",
            mode: .review,
            fileTreeMode: .auto,
            codeMapUsage: .auto,
            gitInclusion: GitInclusion.none,
            storedPromptIds: [promptID],
            useStoredPromptsAsSystem: true
        )
        let modelPreset = try ModelPreset(
            name: "Cancelled Oracle",
            model: .gpt54Mini,
            chatPresetMappings: ChatPresetMappings(reviewPresetID: chatPreset.id)
        )
        let profile = AgentModelsSettingsProfile(planningModelRaw: AIModel.gpt54.rawValue)
        let startSnapshot = snapshot(
            profile: profile,
            modelPresets: [modelPreset],
            chatPreset: chatPreset,
            exposed: true
        )
        var capturedMessages: [AIMessage] = []
        var capturedModels: [AIModel] = []
        var heldContinuation: AsyncThrowingStream<ChatStreamOutput, Error>.Continuation?
        composition.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting { message, model in
            capturedMessages.append(message)
            capturedModels.append(model)
            let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                switch cancellationKind {
                case .explicit:
                    heldContinuation = continuation
                case .transport:
                    continuation.finish(throwing: CancellationError())
                }
            }
            return (UUID(), stream)
        }

        let request = Task { @MainActor in
            try await composition.oracleViewModel.tool_chatSendWithConfiguredRoster(
                args: [
                    "message": .string("Cancel before response"),
                    "mode": .string("review"),
                    "model": .string(modelPreset.name),
                    "new_chat": .bool(true)
                ],
                promptVM: composition.promptManager,
                tabContext: makeTabContext(workspaceID: workspace.id, tabID: tab.id),
                capturedProfile: profile,
                selectionSnapshotOverride: startSnapshot
            )
        }

        if cancellationKind == .explicit {
            try await AsyncTestWait.waitUntil("Oracle explicit-cancel stream start") {
                heldContinuation != nil && composition.oracleViewModel.sessions.contains {
                    $0.selectedChatPresetID == chatPreset.id
                }
            }
            let session = try XCTUnwrap(
                composition.oracleViewModel.sessions.first(where: { $0.selectedChatPresetID == chatPreset.id })
            )
            await composition.oracleViewModel.cancelAIResponse(in: session.id, skipPartialParseAndSave: false)
            heldContinuation?.finish(throwing: CancellationError())
        }

        do {
            _ = try await request.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch let error as ChatToolError {
            XCTAssertTrue(error.message.localizedCaseInsensitiveContains("cancel"), error.message)
        }

        await composition.oracleViewModel.drainTrackedAutosaves(for: workspace.id)
        let cancelledSession = try XCTUnwrap(
            composition.oracleViewModel.sessions.first(where: { $0.selectedChatPresetID == chatPreset.id })
        )
        let savedURL = try XCTUnwrap(cancelledSession.fileURL)
        let persisted = try await composition.oracleViewModel.chatData.loadChatSession(from: savedURL)
        XCTAssertFalse(persisted.messages.contains { !$0.isUser && $0.rawText.isEmpty })
        XCTAssertEqual(persisted.preferredAIModel, AIModel.gpt54Mini.rawValue)
        XCTAssertEqual(persisted.selectedChatPresetID, chatPreset.id)

        composition.oracleViewModel.setOraclePostPackagingTransportOverrideForTesting { message, model in
            capturedMessages.append(message)
            capturedModels.append(model)
            let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
                continuation.yield(
                    ChatStreamOutput(text: "continued", reasoning: nil, tokens: ChatTokenInfo(), terminalOutcome: .completed)
                )
                continuation.finish()
            }
            return (UUID(), stream)
        }
        let continuationSnapshot = snapshot(
            profile: AgentModelsSettingsProfile(planningModelRaw: AIModel.gpt54.rawValue),
            modelPresets: [],
            chatPreset: chatPreset,
            exposed: false
        )
        _ = try await composition.oracleViewModel.tool_chatSendWithConfiguredRoster(
            args: [
                "message": .string("Continue after cancellation"),
                "mode": .string("review"),
                "chat_id": .string(cancelledSession.shortID)
            ],
            promptVM: composition.promptManager,
            tabContext: makeTabContext(workspaceID: workspace.id, tabID: tab.id),
            capturedProfile: continuationSnapshot.agentModelsProfile,
            selectionSnapshotOverride: continuationSnapshot
        )

        XCTAssertEqual(capturedModels, [.gpt54Mini, .gpt54Mini])
        XCTAssertEqual(capturedMessages.count, 2)
        XCTAssertTrue(capturedMessages.allSatisfy { $0.systemPrompt.contains(promptMarker) })
    }

    private func snapshot(
        profile: AgentModelsSettingsProfile,
        modelPresets: [ModelPreset],
        chatPreset: ChatPreset,
        exposed: Bool
    ) -> OracleSelectionSnapshot {
        OracleSelectionSnapshot(
            origin: .mcp,
            agentModelsProfile: profile,
            modelPresets: modelPresets,
            modelPresetsExposed: exposed,
            modelPresetsTemporarilyDisabled: false,
            chatPresets: ChatPreset.BuiltIn.all() + [chatPreset],
            defaultChatPresets: [
                .chat: ChatPreset.BuiltIn.chat,
                .plan: ChatPreset.BuiltIn.plan,
                .review: ChatPreset.BuiltIn.review
            ]
        )
    }

    private func makeTabContext(workspaceID: UUID, tabID: UUID) -> OracleViewModel.OracleSendTabContext {
        OracleViewModel.OracleSendTabContext(
            tabID: tabID,
            workspaceID: workspaceID,
            activationPolicy: .foregroundWhenActive,
            packaging: OracleViewModel.OracleSendPackagingContext(
                sourceTabID: tabID,
                sourceWorkspaceID: workspaceID,
                sourceSelectionRevision: 0,
                sourceAgentSessionID: nil,
                sourceAgentRunID: nil,
                promptText: "",
                selection: StoredSelection(),
                lookupContext: nil,
                reviewGitContext: .automaticOnly(),
                provenance: .direct
            )
        )
    }
}
