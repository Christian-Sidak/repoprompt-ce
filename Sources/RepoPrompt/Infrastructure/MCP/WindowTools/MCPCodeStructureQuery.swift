import Foundation
import MCP

// Explicit checked conformances are intentional actor-boundary contracts.
// swiftformat:disable redundantSendable

/// Value options for one `get_code_structure` call, parsed from tool arguments with no window, tab,
/// or workspace authority. Seeds are resolved separately, under frozen authority, by the app adapter.
struct MCPCodeStructureQueryRequest: Sendable, Equatable {
    static let argumentKeys: Set<String> = ["paths", "expand", "depth", "signatures", "size"]
    /// Upper bound on unique seed files. Seed resolution stops as soon as it is exceeded.
    static let maximumSeedCount = 8192
    static let maximumRequestedPathCount = 256

    let direction: WorkspaceCodemapStructureTraversalDirection?
    let maximumDepth: Int
    let includesSignatures: Bool
    let size: WorkspaceCodemapGraphOutputSize
    let budget: WorkspaceCodemapGraphQueryBudget

    /// Parses every option except `paths`, in the tool's historical validation order: unknown keys,
    /// `expand`, `depth`, `signatures`, then `size`. The messages are part of the tool contract.
    /// `depth` is validated even without `expand`, and only applies with it.
    static func parse(_ args: [String: Value]) throws -> Self {
        guard Set(args.keys).isSubset(of: argumentKeys) else {
            throw MCPError.invalidParams("unknown get_code_structure parameter")
        }

        let direction: WorkspaceCodemapStructureTraversalDirection?
        if let value = args["expand"] {
            guard let raw = value.stringValue else {
                throw MCPError.invalidParams("expand must be 'uses', 'used_by', or 'both'")
            }
            direction = switch raw {
            case "uses": .referencedDefinitions
            case "used_by": .referrers
            case "both": .both
            default: throw MCPError.invalidParams("expand must be 'uses', 'used_by', or 'both'")
            }
        } else {
            direction = nil
        }

        let suppliedDepth: Int
        if let value = args["depth"] {
            guard let depth = value.intValue else {
                throw MCPError.invalidParams("depth must be an integer")
            }
            suppliedDepth = depth
        } else {
            suppliedDepth = 1
        }
        guard (1 ... 4).contains(suppliedDepth) else {
            throw MCPError.invalidParams("depth must be between 1 and 4")
        }

        let includesSignatures: Bool
        if let value = args["signatures"] {
            guard let signatures = value.boolValue else {
                throw MCPError.invalidParams("signatures must be a boolean")
            }
            includesSignatures = signatures
        } else {
            includesSignatures = true
        }

        let size: WorkspaceCodemapGraphOutputSize
        if let value = args["size"] {
            guard let rawSize = value.stringValue,
                  let parsedSize = WorkspaceCodemapGraphOutputSize(rawValue: rawSize)
            else {
                throw MCPError.invalidParams("size must be 'small', 'medium', or 'large'")
            }
            size = parsedSize
        } else {
            size = .medium
        }

        return Self(
            direction: direction,
            maximumDepth: direction == nil ? 0 : suppliedDepth,
            includesSignatures: includesSignatures,
            size: size,
            budget: WorkspaceCodemapGraphPolicy.initial.queryBudget(
                size: size,
                includesSignatures: includesSignatures
            )
        )
    }

    /// Validates a supplied `paths` argument. The app adapter calls this after its ingress wait,
    /// where the check has always run, so an invalid list keeps its cancellation ordering.
    static func requestedPaths(from value: Value) throws -> [String] {
        guard let rawPaths = value.arrayValue,
              !rawPaths.isEmpty,
              rawPaths.count <= maximumRequestedPathCount,
              rawPaths.allSatisfy({ $0.stringValue != nil })
        else {
            throw MCPError.invalidParams("paths must contain one to 256 strings")
        }
        return rawPaths.compactMap(\.stringValue)
    }
}

/// Everything one query needs, captured by the app adapter. No window, tab, selection, or UI model
/// crosses: seeds arrive resolved and the global Code Maps switch arrives as a captured value.
struct MCPCodeStructureQueryInput: Sendable {
    let request: MCPCodeStructureQueryRequest
    /// Seed records resolved under the caller's frozen authority, possibly duplicated or outside
    /// the lookup scope; the orchestrator admits each in-scope file once.
    let seeds: [WorkspaceFileRecord]
    /// The translated `paths` argument; empty for selection seeds.
    let requestedPaths: [String]
    let includePathNotFoundIssue: Bool
    let lookupContext: WorkspaceLookupContext
    let codeMapsGloballyDisabled: Bool
}

/// The store capabilities one code-structure query uses. Production is
/// `WorkspaceStoreCodeStructureQueryBackend`; tests substitute a scripted backend.
protocol MCPCodeStructureQueryBackend: Sendable {
    func rootScopeAvailability(_ rootScope: WorkspaceLookupRootScope) async -> WorkspaceLookupRootScopeAvailability
    func rootRefs(scope rootScope: WorkspaceLookupRootScope) async -> [WorkspaceRootRef]
    func logicalRootDisplayNamesByRootID(for lookupContext: WorkspaceLookupContext) async -> [UUID: String]
    func queryStructureGraphs(
        _ query: WorkspaceCodemapGraphStructureQuery,
        rootScope: WorkspaceLookupRootScope,
        logicalRootDisplayNamesByRootID: [UUID: String]
    ) async throws -> WorkspaceCodemapStructureAggregateResult
    func revalidateStructureGraphs(
        _ aggregate: WorkspaceCodemapStructureAggregateResult
    ) async -> [WorkspaceCodemapRootEpoch: WorkspaceCodemapStructureGraphRevalidationResult]
    func structureSignaturePresentation(
        fileIDs: [UUID],
        maximumCandidateDemandCount: Int,
        rootScope: WorkspaceLookupRootScope,
        logicalRootDisplayNamesByRootID: [UUID: String]
    ) async throws -> WorkspaceCodemapOperationPresentation
}

/// The production backend: the workspace store actor and the signature presentation coordinator
/// over it, with the production demand policy.
struct WorkspaceStoreCodeStructureQueryBackend: MCPCodeStructureQueryBackend {
    let store: WorkspaceFileContextStore

    func rootScopeAvailability(_ rootScope: WorkspaceLookupRootScope) async -> WorkspaceLookupRootScopeAvailability {
        await store.rootScopeAvailability(rootScope)
    }

    func rootRefs(scope rootScope: WorkspaceLookupRootScope) async -> [WorkspaceRootRef] {
        await store.rootRefs(scope: rootScope)
    }

    func logicalRootDisplayNamesByRootID(for lookupContext: WorkspaceLookupContext) async -> [UUID: String] {
        await lookupContext.logicalRootDisplayNamesByRootID(store: store)
    }

    func queryStructureGraphs(
        _ query: WorkspaceCodemapGraphStructureQuery,
        rootScope: WorkspaceLookupRootScope,
        logicalRootDisplayNamesByRootID: [UUID: String]
    ) async throws -> WorkspaceCodemapStructureAggregateResult {
        try await store.queryCodemapStructureGraphs(
            seedFileIDs: query.seedFileIDs,
            direction: query.direction,
            maximumDepth: query.maximumDepth,
            budget: query.budget,
            rootScope: rootScope,
            logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID
        )
    }

    func revalidateStructureGraphs(
        _ aggregate: WorkspaceCodemapStructureAggregateResult
    ) async -> [WorkspaceCodemapRootEpoch: WorkspaceCodemapStructureGraphRevalidationResult] {
        await store.revalidateCodemapStructureGraphs(aggregate)
    }

    func structureSignaturePresentation(
        fileIDs: [UUID],
        maximumCandidateDemandCount: Int,
        rootScope: WorkspaceLookupRootScope,
        logicalRootDisplayNamesByRootID: [UUID: String]
    ) async throws -> WorkspaceCodemapOperationPresentation {
        try await WorkspaceCodemapPresentationCoordinator(
            store: store,
            policy: WorkspaceCodemapPresentationRequestPolicy(
                maximumReadinessRounds: 4096,
                initialBackoffMilliseconds: 25,
                maximumBackoffMilliseconds: 250,
                maximumTotalWait: .milliseconds(workspaceCodemapProductionDemandWaitMilliseconds),
                maximumCandidateDemandCount: maximumCandidateDemandCount
            ),
            structurePhaseDidChange: { phase in
                await MCPToolExecutionHandlerPhaseContext.report(phase.mcpToolExecutionHandlerPhase)
            }
        ).structureSignaturePresentation(
            fileIDs: fileIDs,
            rootScope: rootScope,
            logicalRootDisplayNamesByRootID: logicalRootDisplayNamesByRootID
        )
    }
}

/// App-independent `get_code_structure` query orchestration: scope availability, seed admission and
/// ordering, graph query, initial and final revalidation, signature demand, and reply assembly.
///
/// It holds no window, tab, selection, or UI model, and nothing in it is MainActor-isolated. The app
/// adapter keeps window and tab routing, frozen workspace authority capture and validation, path and
/// selection seed resolution, and the fence that revalidates authority after `run` returns and again
/// after the reply is encoded: workspace authority can change at any suspension in here, and only
/// that fence decides whether the reply is released.
///
/// `run` is a nonisolated `async` function, so a MainActor caller suspends while the whole query,
/// including the pure seed ordering and reply assembly, runs off the main actor.
struct MCPCodeStructureQueryOrchestrator: Sendable {
    typealias DTO = ToolResultDTOs.CodeStructureReplyDTO

    /// Boundaries at which `phaseWillBegin` runs, in this order. These are orchestration hooks, not
    /// the tool-execution handler phases reported for watchdog diagnostics.
    enum Phase: String, Sendable, Equatable {
        case seedOrdering = "seed_ordering"
        case graphQuery = "graph_query"
        case signatureDemand = "signature_demand"
        case replyAssembly = "reply_assembly"
    }

    /// The seed-order keys, projected once per admitted seed, and the order the graph query used.
    struct SeedOrder: Sendable, Equatable {
        let keys: [MCPCodeStructureReplyProjection.SeedOrderKey]
        let orderedFileIDs: [UUID]
    }

    struct Outcome: Sendable {
        let reply: DTO
        /// Nil when the query answered before seed ordering (Code Maps disabled, an unavailable
        /// session-bound scope, or no requested seed in scope).
        let seedOrder: SeedOrder?
        let signatureDemandInvoked: Bool
    }

    let backend: any MCPCodeStructureQueryBackend
    /// Runs synchronously on the orchestrating executor as each phase begins. Production passes a
    /// no-op; tests use it to observe isolation and to inject cancellation or an authority change
    /// at a deterministic boundary.
    let phaseWillBegin: @Sendable (Phase) -> Void

    init(
        backend: any MCPCodeStructureQueryBackend,
        phaseWillBegin: @escaping @Sendable (Phase) -> Void = { _ in }
    ) {
        self.backend = backend
        self.phaseWillBegin = phaseWillBegin
    }

    func run(_ input: MCPCodeStructureQueryInput) async throws -> Outcome {
        try Task.checkCancellation()
        let request = input.request
        let lookupContext = input.lookupContext
        let rootScope = lookupContext.rootScope
        let worktreeScope = ToolResultDTOs.WorktreeScopeDTO.sessionBound(from: lookupContext.bindingProjection)
        if input.codeMapsGloballyDisabled {
            return Self.answered(Self.unavailableIssue(
                code: "codemaps_disabled",
                phase: "graph_snapshot",
                message: "Codemap generation is disabled."
            ), request: request, worktreeScope: worktreeScope)
        }

        switch await backend.rootScopeAvailability(rootScope) {
        case .available:
            break
        case .sessionWorktreeUnavailable:
            return Self.answered(Self.unavailableIssue(
                code: "git_root_unavailable",
                phase: "seed_resolution",
                message: "The session-bound worktree root is unavailable."
            ), request: request, worktreeScope: worktreeScope)
        }

        let roots = await backend.rootRefs(scope: rootScope)
        let seeds = Self.admittedSeeds(input.seeds, allowedRootIDs: Set(roots.map(\.id)))
        if seeds.isEmpty, input.includePathNotFoundIssue {
            return Self.answered(Self.unavailableIssue(
                code: "path_not_found",
                phase: "seed_resolution",
                path: input.requestedPaths.first,
                message: "No requested path resolved to a file."
            ), request: request, worktreeScope: worktreeScope)
        }

        let logicalRootNames = await backend.logicalRootDisplayNamesByRootID(for: lookupContext)
        phaseWillBegin(.seedOrdering)
        // Each admitted seed's logical path is projected exactly once; the sort compares keys.
        let seedOrderKeys = seeds.map { file in
            MCPCodeStructureReplyProjection.seedOrderKey(
                for: file,
                roots: roots,
                lookupContext: lookupContext,
                logicalRootDisplayNamesByRootID: logicalRootNames
            )
        }
        let orderedSeedFileIDs = MCPCodeStructureReplyProjection.orderedSeedFileIDs(seedOrderKeys)
        try Task.checkCancellation()

        await MCPToolExecutionHandlerPhaseContext.report(.getCodeStructureGraphSnapshot)
        phaseWillBegin(.graphQuery)
        let aggregate = try await backend.queryStructureGraphs(
            WorkspaceCodemapGraphStructureQuery(
                seedFileIDs: orderedSeedFileIDs,
                direction: request.direction,
                maximumDepth: request.maximumDepth,
                budget: request.budget
            ),
            rootScope: rootScope,
            logicalRootDisplayNamesByRootID: logicalRootNames
        )
        try Task.checkCancellation()
        await MCPToolExecutionHandlerPhaseContext.report(.getCodeStructureGraphTraversal)
        await MCPToolExecutionHandlerPhaseContext.report(.getCodeStructureGraphRevalidation)
        let initialRevalidation = await backend.revalidateStructureGraphs(aggregate)
        let renderableFileIDs = Self.renderableFileIDs(aggregate, initialRevalidation: initialRevalidation)

        let presentation: WorkspaceCodemapOperationPresentation?
        if request.includesSignatures, !renderableFileIDs.isEmpty {
            phaseWillBegin(.signatureDemand)
            presentation = try await backend.structureSignaturePresentation(
                fileIDs: renderableFileIDs,
                maximumCandidateDemandCount: request.budget.maximumNodeCount,
                rootScope: rootScope,
                logicalRootDisplayNamesByRootID: logicalRootNames
            )
        } else {
            presentation = nil
        }
        try Task.checkCancellation()

        let finalRevalidation = await backend.revalidateStructureGraphs(aggregate)
        let revalidation = Self.mergedRevalidation(initial: initialRevalidation, final: finalRevalidation)
        try Task.checkCancellation()
        await MCPToolExecutionHandlerPhaseContext.report(.getCodeStructureAssembly)
        phaseWillBegin(.replyAssembly)
        let reply = MCPCodeStructureReplyProjection.assemble(.init(
            aggregate: aggregate,
            presentation: presentation,
            revalidation: revalidation,
            includesSignatures: request.includesSignatures,
            budget: request.budget,
            size: request.size,
            worktreeScope: worktreeScope
        ))
        try Task.checkCancellation()
        return Outcome(
            reply: reply,
            seedOrder: SeedOrder(keys: seedOrderKeys, orderedFileIDs: orderedSeedFileIDs),
            signatureDemandInvoked: presentation != nil
        )
    }

    /// In-scope seeds, each standardized full path admitted once (first occurrence wins).
    static func admittedSeeds(
        _ files: [WorkspaceFileRecord],
        allowedRootIDs: Set<UUID>
    ) -> [WorkspaceFileRecord] {
        var admittedPaths = Set<String>()
        var admitted: [WorkspaceFileRecord] = []
        for file in files where allowedRootIDs.contains(file.rootID) {
            if admittedPaths.insert(file.standardizedFullPath).inserted {
                admitted.append(file)
            }
        }
        return admitted
    }

    /// Graph nodes eligible for signature demand: every node of a root whose graph was not already
    /// invalid at the initial revalidation.
    static func renderableFileIDs(
        _ aggregate: WorkspaceCodemapStructureAggregateResult,
        initialRevalidation: [WorkspaceCodemapRootEpoch: WorkspaceCodemapStructureGraphRevalidationResult]
    ) -> [UUID] {
        aggregate.roots.flatMap { root -> [UUID] in
            if case .invalid? = initialRevalidation[root.rootEpoch] { return [] }
            return root.nodes.map(\.fileID)
        }
    }

    /// Final revalidation results override initial ones, except that a root found invalid initially
    /// stays invalid: a graph that went stale before signature demand never becomes current again.
    static func mergedRevalidation(
        initial: [WorkspaceCodemapRootEpoch: WorkspaceCodemapStructureGraphRevalidationResult],
        final: [WorkspaceCodemapRootEpoch: WorkspaceCodemapStructureGraphRevalidationResult]
    ) -> [WorkspaceCodemapRootEpoch: WorkspaceCodemapStructureGraphRevalidationResult] {
        var merged = initial
        for (rootEpoch, result) in final {
            if case .invalid? = merged[rootEpoch] { continue }
            merged[rootEpoch] = result
        }
        return merged
    }

    private static func unavailableIssue(
        code: String,
        phase: String,
        path: String? = nil,
        message: String
    ) -> DTO.IssueDTO {
        DTO.IssueDTO(
            code: code,
            phase: phase,
            path: path,
            retryable: false,
            retryAfterMilliseconds: nil,
            attempted: nil,
            limit: nil,
            message: message
        )
    }

    private static func answered(
        _ issue: DTO.IssueDTO,
        request: MCPCodeStructureQueryRequest,
        worktreeScope: ToolResultDTOs.WorktreeScopeDTO?
    ) -> Outcome {
        Outcome(
            reply: MCPCodeStructureReplyProjection.unavailableReply(
                issue: issue,
                size: request.size,
                worktreeScope: worktreeScope
            ),
            seedOrder: nil,
            signatureDemandInvoked: false
        )
    }
}

extension WorkspaceCodemapStructureExecutionPhase {
    var mcpToolExecutionHandlerPhase: MCPToolExecutionHandlerPhase {
        switch self {
        case .seedResolution: .getCodeStructureSeedResolution
        case .graphSnapshot: .getCodeStructureGraphSnapshot
        case .graphTraversal: .getCodeStructureGraphTraversal
        case .graphRevalidation: .getCodeStructureGraphRevalidation
        case .renderDemand: .getCodeStructureRenderDemand
        case .freeze: .getCodeStructureFreeze
        case .render: .getCodeStructureRender
        case .assembly: .getCodeStructureAssembly
        }
    }
}
