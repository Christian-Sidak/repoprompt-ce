import Foundation
import MCP
import RepoPromptDomainRuntime

protocol DirectHeadlessOracleStore: OracleGroupStore, OracleArtifactStore {
    func loadMostRecentConversation(owner: OracleConversationOwner) async throws -> OracleStoredConversation?
}

extension DomainOracleConversationStore: DirectHeadlessOracleStore {}

actor DirectHeadlessOracleAdapter {
    enum AdapterError: Error, LocalizedError, Equatable {
        case contextPackRequired
        case appOnlyOraclePreset
        case unsupportedProviderOverride
        case unknownChatID
        case rosterConflict
        case missingPreparedInvocation
        case childCarrierMismatch

        var errorDescription: String? {
            switch self {
            case .contextPackRequired:
                "context_pack_required: grouped Context Builder execution requires a frozen canonical context pack."
            case .appOnlyOraclePreset:
                "oracle_preset is available only through the app-backed Context Builder."
            case .unsupportedProviderOverride:
                "Direct Oracle provider overrides are unsupported; select a model or start a new chat."
            case .unknownChatID:
                "Unknown Oracle chat_id. Start a new chat with ask_oracle and new_chat=true."
            case .rosterConflict:
                "The configured Oracle roster differs from this durable conversation. Start a new chat with new_chat=true."
            case .missingPreparedInvocation:
                "Oracle launch preparation was not available for this invocation."
            case .childCarrierMismatch:
                "Prepared Oracle child-launch carriers do not match the frozen lane plan."
            }
        }
    }

    private enum Route {
        case direct(modelID: String, implicitConversationID: UUID?)
        case startGroup(group: OracleGroupDescriptor, roster: OracleRoster, members: [OracleGroupMember])
        case continueGroup(groupID: OracleGroupID, expectedRevision: UInt64, roster: OracleRoster)
    }

    enum PreparedRoute {
        case direct(modelID: String, implicitConversationID: UUID?)
        case group
        /// Opt-in raw-instruction Context Builder discovery (M17). The Oracle route consumes the
        /// discovered frozen pack afterwards, or nothing runs after discovery for `clarify`.
        case discovery(DiscoveryRoute)
    }

    struct DiscoveryRoute: Equatable {
        enum Oracle: Equatable {
            /// `clarify` or no response type: discovery only.
            case none
            case direct(modelID: String)
            /// The retained grouped plan consumes the pack through
            /// `buildContext(arguments:request:discoveredInput:)`.
            case group
        }

        let instructions: String
        let mode: OracleMode
        let responseType: String?
        /// Discovery turns run on the roster primary (or the `model` override).
        let discoveryModel: OracleModelReference
        let oracle: Oracle
    }

    private struct DiscoveryIntent {
        let instructions: String
        let mode: OracleMode
        let responseType: String?
        let discoveryModel: OracleModelReference
        let consumesOracle: Bool
    }

    private struct InvocationPlan {
        let invocationID: UUID
        let runID: UUID
        let claimID: UUID?
        /// Nil only for a discovery plan until its pack exists.
        var input: OracleInput?
        let route: Route
        let childLaunchPlan: DomainChildLaunchPlan
        var discovery: DiscoveryIntent?
    }

    private let owner: OracleConversationOwner
    private let rosterResolver: DirectHeadlessOracleRosterResolver
    private let store: any DirectHeadlessOracleStore
    private let provider: DirectHeadlessProviderCoordinator
    private let groupRuntime: OracleGroupRuntime
    /// Process-level opt-in for raw-instruction discovery (`DirectHeadlessContextDiscovery`).
    private let contextDiscoveryEnabled: Bool
    private var plansByInvocationID: [UUID: InvocationPlan] = [:]
    private var isShuttingDown = false

    init(
        profileIdentifier: String,
        rosterResolver: DirectHeadlessOracleRosterResolver,
        store: any DirectHeadlessOracleStore,
        claimManager: OracleGroupClaimManager,
        provider: DirectHeadlessProviderCoordinator,
        contextDiscoveryEnabled: Bool = false
    ) throws {
        owner = try OracleConversationOwner(kind: "direct-headless", identifier: profileIdentifier)
        self.rosterResolver = rosterResolver
        self.store = store
        self.provider = provider
        self.contextDiscoveryEnabled = contextDiscoveryEnabled
        groupRuntime = OracleGroupRuntime(store: store, claimManager: claimManager)
    }

    func resolveChildLaunchPlan(
        toolName: String,
        arguments: [String: Value],
        securityContext: DomainToolInvocationSecurityContext
    ) async throws -> DomainChildLaunchPlan {
        guard !isShuttingDown else { throw CancellationError() }
        let plan = try await makeInvocationPlan(
            toolName: toolName,
            arguments: arguments,
            invocationID: securityContext.invocationID,
            runID: securityContext.principal.runID ?? UUID()
        )
        guard !isShuttingDown else { throw CancellationError() }
        plansByInvocationID[plan.invocationID] = plan
        return plan.childLaunchPlan
    }

    func consumePreparedRoute(request: DomainPhysicalToolRequest) throws -> PreparedRoute {
        guard let invocationID = request.securityContext?.invocationID,
              let plan = plansByInvocationID[invocationID]
        else {
            throw AdapterError.missingPreparedInvocation
        }
        if let discovery = plan.discovery {
            let oracle: DiscoveryRoute.Oracle
            switch plan.route {
            case let .direct(modelID, _):
                plansByInvocationID.removeValue(forKey: invocationID)
                oracle = discovery.consumesOracle ? .direct(modelID: modelID) : .none
            case .startGroup:
                oracle = .group
            case .continueGroup:
                plansByInvocationID.removeValue(forKey: invocationID)
                throw AdapterError.missingPreparedInvocation
            }
            return .discovery(DiscoveryRoute(
                instructions: discovery.instructions,
                mode: discovery.mode,
                responseType: discovery.responseType,
                discoveryModel: discovery.discoveryModel,
                oracle: oracle
            ))
        }
        guard plan.claimID != nil else {
            plansByInvocationID.removeValue(forKey: invocationID)
            guard case let .direct(modelID, implicitConversationID) = plan.route else {
                throw AdapterError.missingPreparedInvocation
            }
            return .direct(modelID: modelID, implicitConversationID: implicitConversationID)
        }
        return .group
    }

    func discardPreparedInvocation(plan: DomainChildLaunchPlan) {
        let launchIDs = plan.lanes.map(\.launchID)
        guard let invocationID = plansByInvocationID.first(where: {
            $0.value.runID == plan.runID && $0.value.childLaunchPlan.lanes.map(\.launchID) == launchIDs
        })?.key else { return }
        plansByInvocationID.removeValue(forKey: invocationID)
    }

    func start(arguments: [String: Value], request: DomainPhysicalToolRequest) async throws -> Value {
        let plan = try await consumePlan(toolName: "ask_oracle", arguments: arguments, request: request)
        return try await execute(plan, request: request)
    }

    func `continue`(arguments: [String: Value], request: DomainPhysicalToolRequest) async throws -> Value {
        let plan = try await consumePlan(toolName: "oracle_send", arguments: arguments, request: request)
        return try await execute(plan, request: request)
    }

    func buildContext(arguments: [String: Value], request: DomainPhysicalToolRequest) async throws -> Value {
        let plan = try await consumePlan(toolName: "context_builder", arguments: arguments, request: request)
        guard plan.discovery == nil else { throw AdapterError.missingPreparedInvocation }
        return try await execute(plan, request: request)
    }

    /// Runs the retained grouped discovery plan with the discovered pack as its input, exactly as a
    /// `context_pack_ref` naming that pack would. Every lane launches in `launchPin`, the committed
    /// context its carriers were minted for (see `DirectHeadlessProviderCoordinator.runProviderOnce`).
    func buildContext(
        arguments: [String: Value],
        request: DomainPhysicalToolRequest,
        discoveredInput: OracleInput,
        launchPin: DomainChildLaunchContextPin
    ) async throws -> Value {
        var plan = try await consumePlan(toolName: "context_builder", arguments: arguments, request: request)
        guard let discovery = plan.discovery, discovery.consumesOracle, discovery.mode == discoveredInput.mode,
              case .startGroup = plan.route
        else {
            throw AdapterError.missingPreparedInvocation
        }
        plan.input = discoveredInput
        return try await execute(plan, request: request, launchPin: launchPin)
    }

    func log(chatID: String?, limit: Int) async throws -> Value {
        let limit = max(1, min(limit, 50))
        if let chatID {
            let lookup = try OracleMemberLookup(publicChatID: chatID)
            if let group = try await store.load(member: lookup, owner: owner) {
                guard let laneIndex = group.members.firstIndex(where: { $0.publicChatID == chatID }) else {
                    throw AdapterError.unknownChatID
                }
                return groupLog(group, laneIndex: laneIndex, limit: limit)
            }
            throw AdapterError.unknownChatID
        }

        let latestDirect = await provider.latestConversationReference()
        guard let latest = try await store.loadMostRecentConversation(owner: owner) else {
            return try await provider.conversationLog(id: nil, limit: limit)
        }
        if case let .group(group) = latest {
            guard Self.prefersGroup(group, overDirectUpdatedAt: latestDirect?.updatedAt) else {
                return try await provider.conversationLog(id: nil, limit: limit)
            }
            return groupLog(group, laneIndex: 0, limit: limit)
        }
        return try await provider.conversationLog(id: nil, limit: limit)
    }

    func isGroupChat(chatID: String) async throws -> Bool {
        try await store.load(member: OracleMemberLookup(publicChatID: chatID), owner: owner) != nil
    }

    func shutdown() {
        isShuttingDown = true
        plansByInvocationID.removeAll()
    }

    private func consumePlan(
        toolName: String,
        arguments: [String: Value],
        request: DomainPhysicalToolRequest
    ) async throws -> InvocationPlan {
        guard !isShuttingDown else { throw CancellationError() }
        if let invocationID = request.securityContext?.invocationID,
           let plan = plansByInvocationID.removeValue(forKey: invocationID)
        {
            return plan
        }
        guard request.securityContext == nil else { throw AdapterError.missingPreparedInvocation }
        let plan = try await makeInvocationPlan(
            toolName: toolName,
            arguments: arguments,
            invocationID: UUID(),
            runID: UUID()
        )
        guard !isShuttingDown else { throw CancellationError() }
        return plan
    }

    private func makeInvocationPlan(
        toolName: String,
        arguments: [String: Value],
        invocationID: UUID,
        runID: UUID
    ) async throws -> InvocationPlan {
        if toolName == "context_builder", arguments["oracle_preset"] != nil {
            throw AdapterError.appOnlyOraclePreset
        }
        if arguments["provider"] != nil { throw AdapterError.unsupportedProviderOverride }
        let route: OracleConversationRoute
        let input: OracleInput
        let resolvedStartRoster: OracleRoster?
        if toolName == "context_builder" {
            let mode = Self.contextBuilderMode(arguments["response_type"]?.stringValue)
            let roster = try await rosterResolver.resolveRoster(for: OracleRosterResolutionRequest(
                primaryModelOverride: arguments["model"]?.stringValue,
                newChat: true
            ))
            if contextDiscoveryEnabled, arguments["context_pack_ref"] == nil,
               let instructions = arguments["instructions"]?.stringValue?
               .trimmingCharacters(in: .whitespacesAndNewlines),
               !instructions.isEmpty
            {
                return try await discoveryPlan(
                    instructions: instructions,
                    responseType: arguments["response_type"]?.stringValue,
                    mode: mode,
                    roster: roster,
                    invocationID: invocationID,
                    runID: runID
                )
            }
            if roster.count == 1, arguments["context_pack_ref"]?.stringValue != nil {
                throw AdapterError.contextPackRequired
            }

            if let rawReference = arguments["context_pack_ref"]?.stringValue {
                guard arguments["instructions"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
                else {
                    throw MCPError.invalidParams(
                        "context_builder accepts either instructions or context_pack_ref, not both."
                    )
                }
                let reference = try OracleFrozenPackReference(rawValue: rawReference)
                let data = try await store.loadArtifact(id: reference.artifactID)
                let pack = try OracleFrozenContextPack.decodeCanonical(data)
                guard pack.mode == mode else {
                    throw MCPError.invalidParams(
                        "context_pack_ref response mode does not match response_type."
                    )
                }
                input = try OracleInput(
                    mode: mode,
                    userMessage: pack.content,
                    context: OracleContextEnvelope(
                        content: .durableArtifact(id: reference.artifactID),
                        sha256: reference.artifactID,
                        provenance: pack.provenance
                    )
                )
            } else {
                guard let instructions = arguments["instructions"]?.stringValue else {
                    throw MCPError.invalidParams("context_builder requires instructions or context_pack_ref")
                }
                guard roster.count == 1 else { throw AdapterError.contextPackRequired }
                input = try OracleInput(mode: mode, userMessage: instructions)
            }
            route = .start(primaryModelOverride: arguments["model"]?.stringValue)
            resolvedStartRoster = roster
        } else {
            guard let message = arguments["message"]?.stringValue else {
                throw MCPError.invalidParams("\(toolName) requires message")
            }
            input = try OracleInput(mode: Self.oracleMode(arguments["mode"]?.stringValue), userMessage: message)
            route = try OracleConversationRoute.resolve(
                chatID: arguments["chat_id"]?.stringValue,
                newChat: arguments["new_chat"]?.boolValue == true,
                modelOverride: arguments["model"]?.stringValue,
                whenMissingChatID: toolName == "oracle_send" ? .continueCurrent : .startNew
            )
            resolvedStartRoster = nil
        }

        switch route {
        case let .start(primaryModelOverride):
            let roster = if let resolvedStartRoster {
                resolvedStartRoster
            } else {
                try await rosterResolver.resolveRoster(for: OracleRosterResolutionRequest(
                    primaryModelOverride: primaryModelOverride,
                    newChat: true
                ))
            }
            try await provider.validateOracleRoster(roster)
            if roster.count == 1 {
                let childPlan = try Self.childPlan(runID: runID, roster: roster)
                return InvocationPlan(
                    invocationID: invocationID,
                    runID: runID,
                    claimID: nil,
                    input: input,
                    route: .direct(modelID: roster.primary.modelID, implicitConversationID: nil),
                    childLaunchPlan: childPlan
                )
            }
            let group = try OracleGroupDescriptor(size: roster.count)
            let members = try roster.orderedModels.enumerated().map { laneIndex, model in
                try OracleGroupMember(
                    laneID: OracleLaneID(index: laneIndex),
                    publicChatID: UUID().uuidString,
                    model: model
                )
            }
            let claimID = UUID()
            let childPlan = try Self.childPlan(
                runID: runID,
                group: group,
                claimID: claimID,
                roster: roster
            )
            return InvocationPlan(
                invocationID: invocationID,
                runID: runID,
                claimID: claimID,
                input: input,
                route: .startGroup(group: group, roster: roster, members: members),
                childLaunchPlan: childPlan
            )

        case let .continuation(chatID):
            let configured = try await rosterResolver.resolveRoster(for: OracleRosterResolutionRequest(newChat: false))
            if let group = try await store.load(member: OracleMemberLookup(publicChatID: chatID), owner: owner) {
                return try await groupContinuationPlan(
                    group: group,
                    configuredRoster: configured,
                    invocationID: invocationID,
                    runID: runID,
                    input: input
                )
            }
            let directRoster = try OracleRoster(primary: configured.primary)
            try await provider.validateOracleRoster(directRoster)
            let childPlan = try Self.childPlan(runID: runID, roster: directRoster)
            return InvocationPlan(
                invocationID: invocationID,
                runID: runID,
                claimID: nil,
                input: input,
                route: .direct(modelID: directRoster.primary.modelID, implicitConversationID: nil),
                childLaunchPlan: childPlan
            )

        case .implicitContinuation:
            let configured = try await rosterResolver.resolveRoster(for: OracleRosterResolutionRequest(newChat: false))
            let latestDirect = await provider.latestConversationReference()
            if case let .group(group)? = try await store.loadMostRecentConversation(owner: owner),
               Self.prefersGroup(group, overDirectUpdatedAt: latestDirect?.updatedAt)
            {
                return try await groupContinuationPlan(
                    group: group,
                    configuredRoster: configured,
                    invocationID: invocationID,
                    runID: runID,
                    input: input
                )
            }
            let directRoster = try OracleRoster(primary: configured.primary)
            try await provider.validateOracleRoster(directRoster)
            return try InvocationPlan(
                invocationID: invocationID,
                runID: runID,
                claimID: nil,
                input: input,
                route: .direct(
                    modelID: directRoster.primary.modelID,
                    implicitConversationID: latestDirect?.id
                ),
                childLaunchPlan: Self.childPlan(runID: runID, roster: directRoster)
            )
        }
    }

    /// Plans an opt-in discovery invocation. `plan`, `question`, and `review` keep the configured
    /// roster for the Oracle step (one member: direct conversation; several: a group); `clarify` or
    /// no response type plans only the roster primary, which runs discovery and nothing after it.
    ///
    /// The child plan is `.atHandoff`: no carrier exists while discovery runs, and the Oracle
    /// step's carriers are minted after the commit, bound to the committed context revision and
    /// with a full lifetime, however long discovery took. `clarify` never mints any.
    private func discoveryPlan(
        instructions: String,
        responseType: String?,
        mode: OracleMode,
        roster: OracleRoster,
        invocationID: UUID,
        runID: UUID
    ) async throws -> InvocationPlan {
        if let responseType, !["plan", "question", "review", "clarify"].contains(responseType) {
            throw MCPError.invalidParams("response_type must be plan, question, review, or clarify.")
        }
        let consumesOracle = responseType.map { ["plan", "question", "review"].contains($0) } ?? false
        let oracleRoster = try consumesOracle ? roster : OracleRoster(primary: roster.primary)
        try await provider.validateOracleRoster(oracleRoster)
        let discovery = DiscoveryIntent(
            instructions: instructions,
            mode: mode,
            responseType: responseType,
            discoveryModel: roster.primary,
            consumesOracle: consumesOracle
        )
        if oracleRoster.count == 1 {
            return try InvocationPlan(
                invocationID: invocationID,
                runID: runID,
                claimID: nil,
                input: nil,
                route: .direct(modelID: oracleRoster.primary.modelID, implicitConversationID: nil),
                childLaunchPlan: Self.childPlan(runID: runID, roster: oracleRoster, preparation: .atHandoff),
                discovery: discovery
            )
        }
        let group = try OracleGroupDescriptor(size: oracleRoster.count)
        let members = try oracleRoster.orderedModels.enumerated().map { laneIndex, model in
            try OracleGroupMember(
                laneID: OracleLaneID(index: laneIndex),
                publicChatID: UUID().uuidString,
                model: model
            )
        }
        let claimID = UUID()
        return try InvocationPlan(
            invocationID: invocationID,
            runID: runID,
            claimID: claimID,
            input: nil,
            route: .startGroup(group: group, roster: oracleRoster, members: members),
            childLaunchPlan: Self.childPlan(
                runID: runID,
                group: group,
                claimID: claimID,
                roster: oracleRoster,
                preparation: .atHandoff
            ),
            discovery: discovery
        )
    }

    private static func prefersGroup(
        _ group: OracleGroupDocument,
        overDirectUpdatedAt latestDirectAt: Date?
    ) -> Bool {
        latestDirectAt.map { $0 <= group.updatedAt } ?? true
    }

    private func groupContinuationPlan(
        group: OracleGroupDocument,
        configuredRoster: OracleRoster,
        invocationID: UUID,
        runID: UUID,
        input: OracleInput
    ) async throws -> InvocationPlan {
        guard configuredRoster == group.roster else { throw AdapterError.rosterConflict }
        try await provider.validateOracleRoster(group.roster)
        let claimID = UUID()
        let childPlan = try Self.childPlan(
            runID: runID,
            group: group.group,
            claimID: claimID,
            roster: group.roster
        )
        return InvocationPlan(
            invocationID: invocationID,
            runID: runID,
            claimID: claimID,
            input: input,
            route: .continueGroup(
                groupID: group.group.id,
                expectedRevision: group.revision,
                roster: group.roster
            ),
            childLaunchPlan: childPlan
        )
    }

    private func execute(
        _ plan: InvocationPlan,
        request: DomainPhysicalToolRequest,
        launchPin: DomainChildLaunchContextPin? = nil
    ) async throws -> Value {
        guard let input = plan.input else { throw AdapterError.missingPreparedInvocation }
        switch plan.route {
        case .direct:
            throw AdapterError.missingPreparedInvocation
        case let .startGroup(group, roster, members):
            guard !isShuttingDown else { throw CancellationError() }
            guard let claimID = plan.claimID else { throw AdapterError.childCarrierMismatch }
            let bundle = try groupCarrierBundle(for: plan, group: group)
            let completion = try await executeGrouped(
                OracleGroupRuntime.Request(
                    invocationID: plan.invocationID,
                    runID: plan.runID,
                    claimID: claimID,
                    input: input,
                    intent: .start(
                        .init(
                            group: group,
                            owner: owner,
                            name: String((plan.discovery?.instructions ?? input.userMessage).prefix(80)),
                            roster: roster,
                            members: members
                        )
                    )
                ),
                bundle: bundle,
                request: request,
                launchPin: launchPin
            )
            return Self.groupValue(completion.result)
        case let .continueGroup(groupID, expectedRevision, roster):
            guard !isShuttingDown else { throw CancellationError() }
            guard let claimID = plan.claimID else { throw AdapterError.childCarrierMismatch }
            let group = try OracleGroupDescriptor(id: groupID, size: roster.count)
            let bundle = try groupCarrierBundle(for: plan, group: group)
            let completion = try await executeGrouped(
                OracleGroupRuntime.Request(
                    invocationID: plan.invocationID,
                    runID: plan.runID,
                    claimID: claimID,
                    input: input,
                    intent: .continuation(
                        .init(
                            group: group,
                            owner: owner,
                            observedRevision: expectedRevision,
                            expectedRoster: roster
                        )
                    )
                ),
                bundle: bundle,
                request: request,
                launchPin: launchPin
            )
            return Self.groupValue(completion.result)
        }
    }

    private func executeGrouped(
        _ request: OracleGroupRuntime.Request,
        bundle: DomainChildLaunchCarrierBundle,
        request physicalRequest: DomainPhysicalToolRequest,
        launchPin: DomainChildLaunchContextPin?
    ) async throws -> OracleGroupRuntime.Completion {
        let provider = provider
        do {
            return try await groupRuntime.execute(
                request,
                callbacks: .init(
                    executeLane: { invocation in
                        guard let carrier = bundle.carrier(for: invocation.member.laneID) else {
                            throw AdapterError.childCarrierMismatch
                        }
                        let prompt = Self.prompt(
                            turns: invocation.priorTerminalTurns,
                            laneIndex: invocation.member.laneID.index,
                            next: invocation.context.input.userMessage
                        )
                        let response: String
                        do {
                            response = try await provider.runProviderOnce(
                                message: prompt,
                                providerID: invocation.member.model.providerID,
                                model: invocation.member.model.modelID,
                                request: physicalRequest,
                                purpose: .oracleGroup,
                                carrierEnvironment: carrier.environment,
                                launchPin: launchPin
                            )
                        } catch let refusal as DomainChildLaunchContextPin.Mismatch {
                            // The lane's launch was refused before its process started.
                            throw OracleLaneFailure(
                                code: DomainChildLaunchContextPin.Mismatch.code,
                                message: refusal.errorDescription ?? String(describing: refusal)
                            )
                        }
                        return OracleLaneExecutionResponse(response: response)
                    }
                )
            )
        } catch let error as OracleGroupRuntime.RuntimeError {
            throw mapRuntimeError(error)
        }
    }

    private func mapRuntimeError(_ error: OracleGroupRuntime.RuntimeError) -> Error {
        switch error {
        case .settlementFailed:
            error
        case .singleLaneBypassRequired, .continuationMissing, .continuationChanged, .rosterConflict,
             .invalidPreparedTurn:
            AdapterError.rosterConflict
        }
    }

    private func groupCarrierBundle(
        for plan: InvocationPlan,
        group: OracleGroupDescriptor
    ) throws -> DomainChildLaunchCarrierBundle {
        guard let bundle = DomainChildLaunchContext.bundle,
              bundle.plan.runID == plan.runID,
              bundle.plan.oracleGroupID == group.id,
              bundle.plan.oracleGroupClaimID == plan.claimID,
              bundle.carriers.count == group.size,
              bundle.plan.lanes.map(\.launchID) == plan.childLaunchPlan.lanes.map(\.launchID),
              bundle.plan.lanes.map(\.providerIdentifier) == plan.childLaunchPlan.lanes.map(\.providerIdentifier),
              bundle.plan.lanes.map(\.oracleLaneID) == plan.childLaunchPlan.lanes.map(\.oracleLaneID)
        else {
            throw AdapterError.childCarrierMismatch
        }
        return bundle
    }

    private func groupLog(_ group: OracleGroupDocument, laneIndex: Int, limit: Int) -> Value {
        let member = group.members[laneIndex]
        return .object([
            "chat_id": .string(member.publicChatID),
            "messages": .array(Array(Self.messages(turns: group.turns, laneIndex: laneIndex).suffix(limit))),
            "oracle_group_id": .string(group.group.id.rawValue.uuidString),
            "lane_index": .int(laneIndex),
            "oracle_count": .int(group.group.size),
            "root_chat_id": .string(group.members[0].publicChatID)
        ])
    }

    private static func childPlan(
        runID: UUID,
        group: OracleGroupDescriptor? = nil,
        claimID: UUID? = nil,
        roster: OracleRoster,
        preparation: DomainChildLaunchPreparation = .atAdmission
    ) throws -> DomainChildLaunchPlan {
        let lanes = try roster.orderedModels.enumerated().map { index, model in
            try DomainChildLaunchLanePlan(
                providerIdentifier: model.providerID ?? DirectHeadlessOracleRosterResolver.providerID,
                oracleLaneID: group == nil ? nil : OracleLaneID(index: index)
            )
        }
        return try DomainChildLaunchPlan(
            runID: runID,
            oracleGroupID: group?.id,
            oracleGroupClaimID: claimID,
            lanes: lanes,
            approvalMetadata: ["oracle_count": "\(roster.count)"],
            preparation: preparation
        )
    }

    private static func prompt(turns: [OracleTurnRecord], laneIndex: Int, next: String) -> String {
        var messages: [(String, String)] = []
        for turn in turns where turn.state == .terminal {
            messages.append(("user", turn.input.userMessage))
            guard turn.results.indices.contains(laneIndex) else { continue }
            let result = turn.results[laneIndex]
            if let response = result.response ?? result.error?.partialResponse {
                messages.append(("assistant", response))
            }
        }
        guard !messages.isEmpty else { return next }
        return messages.map { "\($0.0): \($0.1)" }.joined(separator: "\n\n") + "\n\nuser: " + next
    }

    private static func messages(turns: [OracleTurnRecord], laneIndex: Int) -> [Value] {
        var values: [Value] = []
        for turn in turns where turn.state == .terminal {
            values.append(.object(["role": .string("user"), "text": .string(turn.input.userMessage)]))
            guard turn.results.indices.contains(laneIndex) else { continue }
            let result = turn.results[laneIndex]
            if let response = result.response ?? result.error?.partialResponse {
                values.append(.object(["role": .string("assistant"), "text": .string(response)]))
            }
        }
        return values
    }

    private static func oracleMode(_ raw: String?) throws -> OracleMode {
        guard let raw else { return .chat }
        guard let mode = OracleMode(rawValue: raw) else {
            throw MCPError.invalidParams("Oracle mode must be chat, plan, or review.")
        }
        return mode
    }

    private static func contextBuilderMode(_ raw: String?) -> OracleMode {
        switch raw {
        case "plan": .plan
        case "review": .review
        default: .chat
        }
    }

    private static func groupValue(_ result: OracleGroupResult) -> Value {
        var object = OracleGroupMCPCodec.groupFields(result)
        object.merge([
            "chat_id": .string(result.primary.chatID),
            "response": result.primary.response.map(Value.string) ?? .null,
            "backend": .string("headless")
        ]) { _, new in new }
        return .object(object)
    }
}
