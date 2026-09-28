import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

/// An in-process app `MCPServerViewModel` bound to one workspace root, exposing the real window
/// tools (`windowMCPTools`) without a visible app, socket transport, or connection manager.
/// `file_search` is not wired (its search closure throws).
///
/// `make` binds a standalone server without activating the workspace (callers load roots into the
/// store themselves); file-tool reads that need the workspace root catalog (`read_file`,
/// `get_code_structure`) then fail closed with `workspace_authority_unavailable`, and domain read
/// routing cannot find an unregistered window. `makeRegisteredWindow` instead uses a real,
/// registered `WindowState` whose workspace is activated through `switchWorkspace`, so those tools
/// run their real authority and routing path.
@MainActor
enum InProcessMCPWindowServerFixture {
    struct Server {
        let server: MCPServerViewModel
        let connectionID: UUID
        let workspaceManager: WorkspaceManagerViewModel
    }

    struct RegisteredWindow {
        let window: WindowState
        let connectionID: UUID
    }

    static func make(
        store: WorkspaceFileContextStore,
        root: URL,
        windowID: Int = -859,
        workspaceName: String = "In-process MCP fixture"
    ) throws -> (server: MCPServerViewModel, connectionID: UUID) {
        let parts = makeParts(store: store, root: root, windowID: windowID, workspaceName: workspaceName)
        let bound = try bind(parts, windowID: windowID)
        return (bound.server, bound.connectionID)
    }

    /// A registered app window whose workspace is activated through `switchWorkspace`, bound to a
    /// test connection on the window's own `mcpServer`. Domain read routing resolves the window
    /// through `WindowStatesManager`, so file-tool reads run their real authority path. Call
    /// `close(_:)` when done.
    static func makeRegisteredWindow(
        root: URL,
        workspaceName: String = "In-process MCP fixture"
    ) async throws -> RegisteredWindow {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        do {
            let workspace = window.workspaceManager.createWorkspace(
                name: "\(workspaceName) \(UUID().uuidString.prefix(8))",
                repoPaths: [root.path],
                ephemeral: true
            )
            let result = await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "inProcessMCPWindowServerFixture"
            )
            guard let active = window.workspaceManager.activeWorkspace, active.id == workspace.id else {
                throw MCPError.internalError("in-process fixture workspace did not activate: \(result)")
            }
            window.promptManager.loadComposeTabsFromWorkspace(active, syncPromptText: true)
            let connectionID = UUID()
            try window.mcpServer.bindTabForConnection(
                connectionID: connectionID,
                clientName: nil,
                tabID: XCTUnwrap(active.activeComposeTabID),
                workspaceID: active.id,
                windowID: window.windowID
            )
            window.mcpServer.setRequestMetadataOverrideForTesting(
                MCPServerViewModel.RequestMetadata(
                    connectionID: connectionID,
                    clientName: nil,
                    windowID: window.windowID
                )
            )
            return RegisteredWindow(window: window, connectionID: connectionID)
        } catch {
            await close(RegisteredWindow(window: window, connectionID: UUID()))
            throw error
        }
    }

    static func close(_ registered: RegisteredWindow) async {
        registered.window.mcpServer.setRequestMetadataOverrideForTesting(nil)
        registered.window.beginClose()
        await registered.window.tearDown()
        WindowStatesManager.shared.unregisterWindowState(registered.window)
    }

    static func tool(named name: String, from server: MCPServerViewModel) async throws -> RepoPromptApp.Tool {
        let tools = await server.windowMCPTools
        return try XCTUnwrap(tools.first { $0.name == name }, "window tool \(name) is not exposed")
    }

    // MARK: - Parts

    private struct Parts {
        let prompt: PromptViewModel
        let oracle: OracleViewModel
        let workspaceManager: WorkspaceManagerViewModel
        let workspace: WorkspaceModel
    }

    private static func makeParts(
        store: WorkspaceFileContextStore,
        root: URL,
        windowID: Int,
        workspaceName: String
    ) -> Parts {
        let fileManager = WorkspaceFilesViewModel(workspaceFileContextStore: store)
        let keyManager = KeyManager(
            secureService: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let aiQueriesService = AIQueriesService(keyManager: keyManager)
        let apiSettings = APISettingsViewModel(
            aiQueriesService: aiQueriesService,
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        let settingsManager = WindowSettingsManager(windowID: windowID)
        let prompt = PromptViewModel(
            fileManager: fileManager,
            aiQueriesService: aiQueriesService,
            apiSettingsViewModel: apiSettings,
            windowID: windowID,
            settingsManager: settingsManager
        )
        let workspaceManager = WorkspaceManagerViewModel(
            fileManager: fileManager,
            promptViewModel: prompt,
            performInitialWorkspaceActivation: false
        )
        let workspace = WorkspaceModel(name: workspaceName, repoPaths: [root.path])
        workspaceManager.workspaces = [workspace]
        workspaceManager.activeWorkspace = workspace
        let oracle = OracleViewModel(
            aiQueriesService: aiQueriesService,
            promptViewModel: prompt,
            workspaceManager: workspaceManager,
            chatData: ChatDataService()
        )
        return Parts(prompt: prompt, oracle: oracle, workspaceManager: workspaceManager, workspace: workspace)
    }

    private static func bind(_ parts: Parts, windowID: Int) throws -> Server {
        let service = MCPService(
            hostBootstrapOperation: {},
            controllerStartOperation: {},
            controllerFullShutdownOperation: {}
        )
        let server = MCPServerViewModel(
            service: service,
            promptVM: parts.prompt,
            oracleVM: parts.oracle,
            workspaceManager: parts.workspaceManager,
            windowID: windowID,
            workspaceSearch: { _, _, _, _, _, _, _, _, _, _, _, _, _, _ in
                throw MCPError.internalError("search is not wired in the in-process window-server fixture")
            },
            ensureGitDataRootLoaded: { _, _ in
                throw MCPError.internalError("Git-data loading is not wired in the in-process window-server fixture")
            }
        )
        let workspace = parts.workspaceManager.activeWorkspace ?? parts.workspace
        let connectionID = UUID()
        try server.bindTabForConnection(
            connectionID: connectionID,
            clientName: nil,
            tabID: XCTUnwrap(workspace.activeComposeTabID),
            workspaceID: workspace.id,
            windowID: windowID
        )
        server.setRequestMetadataOverrideForTesting(
            MCPServerViewModel.RequestMetadata(
                connectionID: connectionID,
                clientName: nil,
                windowID: windowID
            )
        )
        return Server(server: server, connectionID: connectionID, workspaceManager: parts.workspaceManager)
    }
}
