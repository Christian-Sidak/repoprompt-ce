import Foundation
import MCP
import RepoPromptDomainRuntime

/// Direct-headless adapter for `ContextBuilderDiscoveryEngine` (M17).
///
/// Opt-in per process: `REPOPROMPT_MCP_HEADLESS_CONTEXT_DISCOVERY=1` makes a raw-instruction
/// `context_builder` call run bounded discovery over the connection-bound context. Without it the
/// established contracts are unchanged: one roster member sends the raw instructions straight to a
/// direct conversation, and a grouped roster requires `context_pack_ref`.
///
/// The adapter supplies the engine's host ports only: the frozen snapshot capture, the provider
/// (one read-only `codex exec` per turn with no child-launch carrier, so the provider has no path to
/// RepoPrompt tools other than the frozen protocol tools, run in the frozen snapshot's active root),
/// the compare-and-set selection commit, and the durable pack store.
struct DirectHeadlessContextDiscovery {
    static let environmentKey = "REPOPROMPT_MCP_HEADLESS_CONTEXT_DISCOVERY"

    let context: DirectHeadlessDomainContext
    let providerCoordinator: DirectHeadlessProviderCoordinator
    let packStore: any OracleArtifactStore
    let settingsStore: DomainDirectSettingsStore?
    let engine: ContextBuilderDiscoveryEngine

    init(
        context: DirectHeadlessDomainContext,
        providerCoordinator: DirectHeadlessProviderCoordinator,
        packStore: any OracleArtifactStore,
        settingsStore: DomainDirectSettingsStore?,
        engine: ContextBuilderDiscoveryEngine = ContextBuilderDiscoveryEngine()
    ) {
        self.context = context
        self.providerCoordinator = providerCoordinator
        self.packStore = packStore
        self.settingsStore = settingsStore
        self.engine = engine
    }

    static func isEnabled(environment: [String: String]) -> Bool {
        guard let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return ["1", "true", "yes", "on"].contains(raw)
    }

    func run(
        instructions: String,
        mode: OracleMode,
        model: OracleModelReference,
        request: DomainPhysicalToolRequest
    ) async throws -> ContextBuilderDiscoveryOutcome {
        let (frozen, frozenRoot) = try await context.discoveryFreeze(for: request)
        let ignoreConfiguration: DomainCanonicalWorkspaceAdapter.IgnoreConfigurationProvider? = settingsStore.map { store in
            { @Sendable in await DirectHeadlessWorkspaceBackend.ignoreConfiguration(from: store) }
        }
        let workspace = ContextBuilderFrozenWorkspace(
            snapshot: frozen,
            resolvePath: { rawPath, roots, allowMissingLeaf in
                try DirectHeadlessDomainContext.resolvePath(rawPath, roots: roots, allowMissingLeaf: allowMissingLeaf)
            },
            ignoreConfiguration: ignoreConfiguration
        )
        return try await engine.run(
            ContextBuilderDiscoveryRequest(instructions: instructions, mode: mode),
            workspace: workspace,
            provider: Provider(
                coordinator: providerCoordinator,
                providerID: model.providerID,
                modelID: model.modelID,
                request: request,
                workingDirectory: frozenRoot
            ),
            committer: Committer(context: context, request: request),
            packStore: packStore
        )
    }

    /// Structured discovery fields shared by every `context_builder` discovery reply.
    static func resultFields(
        _ outcome: ContextBuilderDiscoveryOutcome,
        responseType: String?
    ) -> [String: Value] {
        var fields: [String: Value] = [
            "backend": .string("headless"),
            "context_id": .string(outcome.context.contextID.uuidString),
            "status": .string("completed"),
            "prompt": .string(outcome.prompt),
            "selection": .array(outcome.selection.map(Value.string)),
            "selected_paths": .array(outcome.displayPaths.map(Value.string)),
            "file_count": .int(outcome.selection.count),
            "context_pack_ref": .string(outcome.packReference.rawValue),
            "context_pack_bytes": .int(outcome.packBytes),
            "selection_committed": .bool(outcome.receipt.applied),
            "discovery": .object([
                "turns": .int(outcome.turns),
                "tool_calls": .int(outcome.toolCalls),
                "refused_tool_calls": .int(outcome.refusedToolCalls),
                "protocol": .string(ContextBuilderDiscoveryPrompt.protocolVersion)
            ])
        ]
        if let responseType {
            fields["response_type"] = .string(responseType)
        }
        return fields
    }

    private struct Provider: ContextBuilderDiscoveryProvider {
        let coordinator: DirectHeadlessProviderCoordinator
        let providerID: String?
        let modelID: String
        let request: DomainPhysicalToolRequest
        /// The frozen snapshot's active root: every turn runs in the roots its protocol tools read.
        let workingDirectory: URL?

        func complete(prompt: String, turn _: Int) async throws -> String {
            try await coordinator.runProviderOnce(
                message: prompt,
                providerID: providerID,
                model: modelID,
                request: request,
                purpose: .contextDiscovery,
                // No carrier: discovery turns never inherit the Oracle lane carrier.
                launch: .discoveryTurn(workingDirectory: workingDirectory)
            )
        }
    }

    private struct Committer: ContextBuilderDiscoveryCommitter {
        let context: DirectHeadlessDomainContext
        let request: DomainPhysicalToolRequest

        func commitSelection(
            _ absolutePaths: [String],
            over snapshot: ContextBuilderDiscoverySnapshot
        ) async throws -> ContextBuilderDiscoveryCommitReceipt {
            try await context.commitDiscoveredSelection(absolutePaths, over: snapshot, request: request)
        }
    }
}
