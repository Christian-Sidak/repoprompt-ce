import Foundation
import MCP

package enum DomainChildLaunchContext {
    /// Exact N=1 compatibility carrier. Group execution uses `bundle` and leaves this nil.
    @TaskLocal package static var current: DomainChildLaunchCarrier?
    @TaskLocal package static var bundle: DomainChildLaunchCarrierBundle?
    /// Installed instead of `bundle`/`current` for a `.atHandoff` plan: the tool prepares its
    /// carriers here, once, when it is ready to launch children.
    @TaskLocal package static var handoff: DomainChildLaunchHandoff?
}

/// The exact context authority a handoff's carriers must be minted against: the context a tool
/// committed to, at the workspace and context revisions its commit produced.
///
/// Preparation resolves the connection's current read context and refuses, before minting anything,
/// when it is not this pin (the connection was rebound, or either revision moved). Launch tokens are
/// then issued for the pinned context and revision, so issuance re-checks the revision too. The
/// child process launched with those carriers runs in the pinned context as well (its working
/// directory is the pinned context's root), revalidated against the connection at the launch. A
/// host that pins the child's roots for its lifetime (a launch-scoped root authority) refuses the
/// launch with the `roots*` reasons when those roots are no longer the committed ones.
package struct DomainChildLaunchContextPin: Equatable, Sendable {
    package let context: DomainContextIdentity
    package let workspaceRevision: UInt64
    package let contextRevision: UInt64

    package init(context: DomainContextIdentity, workspaceRevision: UInt64, contextRevision: UInt64) {
        self.context = context
        self.workspaceRevision = workspaceRevision
        self.contextRevision = contextRevision
    }

    package enum Mismatch: Error, Equatable, LocalizedError {
        /// The connection is now bound to a different context.
        case rebound(current: DomainContextIdentity)
        case workspaceRevisionChanged(expected: UInt64, actual: UInt64)
        case contextRevisionChanged(expected: UInt64, actual: UInt64)
        /// The connection no longer resolves to a context, or the pinned context is gone.
        case contextUnavailable
        /// The roots the launch would run in (worktree overlays applied) are not the roots the
        /// commit was made over: a roots or overlay change reached the launch first.
        case rootsChanged
        /// The committed roots, or their worktree mapping, no longer resolve.
        case rootsUnavailable(String)
        /// A change of the pinned workspace's roots was already in flight when the launch began.
        case rootsChanging

        package static let code = "child_launch_context_changed"

        /// Stable machine-readable reason.
        package var reason: String {
            switch self {
            case .rebound: "rebound"
            case .workspaceRevisionChanged: "workspace_revision_changed"
            case .contextRevisionChanged: "context_revision_changed"
            case .contextUnavailable: "context_unavailable"
            case .rootsChanged: "roots_changed"
            case .rootsUnavailable: "roots_unavailable"
            case .rootsChanging: "roots_changing"
            }
        }

        package var errorDescription: String? {
            let detail = switch self {
            case let .rebound(current):
                "the connection was rebound to context \(current.contextID.uuidString)"
            case let .workspaceRevisionChanged(expected, actual):
                "the workspace revision moved from \(expected) to \(actual)"
            case let .contextRevisionChanged(expected, actual):
                "the context revision moved from \(expected) to \(actual)"
            case .contextUnavailable:
                "the connection no longer resolves to the committed context"
            case .rootsChanged:
                "the roots the launch would run in are not the roots the selection was committed over"
            case let .rootsUnavailable(detail):
                "the committed roots no longer resolve (\(detail))"
            case .rootsChanging:
                "a change of the committed workspace's roots was in flight"
            }
            return "\(Self.code): \(detail) after the committed context was pinned; "
                + "no child was launched under it."
        }

        /// Classifies an error raised while minting or launching under a pin, before any child
        /// process started: a refusal by the pin itself, or a launch-token issuance that rejected
        /// the pinned context (its revision moved after the pin was validated, or it is gone).
        /// Returns nil for every other error.
        package init?(pinnedLaunchError error: Error) {
            if let mismatch = error as? Self {
                self = mismatch
                return
            }
            switch error as? DomainRunLaunchTokenError {
            case let .staleContextRevision(expected, actual)?:
                self = .contextRevisionChanged(expected: expected, actual: actual)
            case .contextUnavailable?:
                self = .contextUnavailable
            default:
                return nil
            }
        }
    }

    /// Throws unless `handle` is exactly this pin's context at this pin's revisions.
    package func validate(_ handle: DomainReadContextHandle) throws {
        guard handle.context == context else { throw Mismatch.rebound(current: handle.context) }
        guard handle.contextRevision == contextRevision else {
            throw Mismatch.contextRevisionChanged(expected: contextRevision, actual: handle.contextRevision)
        }
        // The workspace revision covers the roots the carriers' context resolves to.
        guard handle.workspaceRevision == workspaceRevision else {
            throw Mismatch.workspaceRevisionChanged(expected: workspaceRevision, actual: handle.workspaceRevision)
        }
    }
}

/// Single-use, invocation-scoped preparation of a `.atHandoff` plan's carriers.
///
/// Before `prepare(pinnedTo:)` the invocation holds no carrier, so nothing it runs can redeem the
/// private endpoint. `prepare(pinnedTo:)` revalidates the admission authorizations, then mints the
/// plan's carriers against the pinned context (failing closed when the connection's context no
/// longer matches it), with a full launch-token lifetime. The provider revokes whatever was minted
/// when the invocation ends (`close()`).
package actor DomainChildLaunchHandoff {
    package enum HandoffError: Error, Equatable, LocalizedError {
        case alreadyPrepared
        case closed

        package var errorDescription: String? {
            switch self {
            case .alreadyPrepared:
                "child_launch_handoff_consumed: the invocation's child-launch carriers were already prepared once."
            case .closed:
                "child_launch_handoff_closed: the invocation ended before its child-launch carriers were prepared."
            }
        }
    }

    package typealias Prepare = @Sendable (DomainChildLaunchContextPin) async throws -> DomainChildLaunchCarrierBundle
    package typealias Revoke = @Sendable (DomainChildLaunchCarrierBundle) async -> Void

    private enum State {
        case ready
        case preparing
        case prepared(DomainChildLaunchCarrierBundle)
        /// A preparation was attempted and failed; the handoff is not reusable.
        case spent
        case closed
    }

    private let prepareBundle: Prepare
    private let revokeLate: Revoke
    private var state = State.ready

    /// `revokeLate` revokes a bundle whose preparation finished after `close()`.
    package init(prepare: @escaping Prepare, revokeLate: @escaping Revoke) {
        prepareBundle = prepare
        self.revokeLate = revokeLate
    }

    package func prepare(pinnedTo pin: DomainChildLaunchContextPin) async throws -> DomainChildLaunchCarrierBundle {
        switch state {
        case .ready:
            break
        case .closed:
            throw HandoffError.closed
        case .preparing, .prepared, .spent:
            throw HandoffError.alreadyPrepared
        }
        state = .preparing
        let bundle: DomainChildLaunchCarrierBundle
        do {
            bundle = try await prepareBundle(pin)
        } catch {
            if case .preparing = state { state = .spent }
            throw error
        }
        guard case .preparing = state else {
            await revokeLate(bundle)
            throw HandoffError.closed
        }
        state = .prepared(bundle)
        return bundle
    }

    /// Ends the handoff and returns the prepared bundle, if any, for the caller to revoke.
    package func close() -> DomainChildLaunchCarrierBundle? {
        defer { state = .closed }
        if case let .prepared(bundle) = state { return bundle }
        return nil
    }
}

package enum DomainInteractionPresentationContext {
    @TaskLocal package static var requestID: UUID?
}

package struct DomainLongRunningInteractionAdapter: Sendable {
    package let isAvailable: @Sendable (DomainInteractionRequest) async -> Bool
    package let resolveDefaultTimeoutSeconds: @Sendable (DomainInteractionRequest) async throws -> TimeInterval
    package let cancel: @Sendable (UUID) async -> Void

    package init(
        isAvailable: @escaping @Sendable (DomainInteractionRequest) async -> Bool,
        resolveDefaultTimeoutSeconds: @escaping @Sendable (DomainInteractionRequest) async throws -> TimeInterval,
        cancel: @escaping @Sendable (UUID) async -> Void
    ) {
        self.isAvailable = isAvailable
        self.resolveDefaultTimeoutSeconds = resolveDefaultTimeoutSeconds
        self.cancel = cancel
    }
}

package struct MCPDomainLongRunningToolProvider: Sendable {
    package typealias PrepareChildLaunch = @Sendable (
        _ toolName: String,
        _ arguments: [String: Value],
        _ securityContext: DomainToolInvocationSecurityContext
    ) async throws -> DomainChildLaunchCarrier?

    package typealias ResolveChildLaunchPlan = @Sendable (
        _ toolName: String,
        _ arguments: [String: Value],
        _ securityContext: DomainToolInvocationSecurityContext
    ) async throws -> DomainChildLaunchPlan?

    package typealias PrepareChildLaunches = @Sendable (
        _ plan: DomainChildLaunchPlan,
        _ toolName: String,
        _ arguments: [String: Value],
        _ securityContext: DomainToolInvocationSecurityContext,
        /// Nil at admission; at a `.atHandoff` handoff, the committed context to mint against.
        _ pin: DomainChildLaunchContextPin?
    ) async throws -> DomainChildLaunchCarrierBundle

    package typealias RevokeChildLaunches = @Sendable (
        _ plan: DomainChildLaunchPlan,
        _ bundle: DomainChildLaunchCarrierBundle?
    ) async -> Void

    package static let toolNames: Set<String> = [
        "oracle_utils",
        "ask_oracle",
        "oracle_send",
        "context_builder",
        "ask_user",
        "agent_explore",
        "agent_run",
        "agent_manage",
        "share_thoughts",
        "set_status",
        "wait_for_next_user_instruction"
    ]

    private let identity: DomainRuntimeIdentity
    private let policyStore: DomainMutationPolicyStore
    private let interactionBroker: DomainInteractionBroker
    private let activityCenter: DomainActivityCenter
    private let prepareChildLaunch: PrepareChildLaunch
    private let resolveChildLaunchPlan: ResolveChildLaunchPlan?
    private let prepareChildLaunches: PrepareChildLaunches?
    private let revokeChildLaunches: RevokeChildLaunches?

    package init(
        identity: DomainRuntimeIdentity,
        policyStore: DomainMutationPolicyStore,
        interactionBroker: DomainInteractionBroker,
        activityCenter: DomainActivityCenter,
        prepareChildLaunch: @escaping PrepareChildLaunch = { _, _, _ in nil }
    ) {
        self.identity = identity
        self.policyStore = policyStore
        self.interactionBroker = interactionBroker
        self.activityCenter = activityCenter
        self.prepareChildLaunch = prepareChildLaunch
        resolveChildLaunchPlan = nil
        prepareChildLaunches = nil
        revokeChildLaunches = nil
    }

    package init(
        identity: DomainRuntimeIdentity,
        policyStore: DomainMutationPolicyStore,
        interactionBroker: DomainInteractionBroker,
        activityCenter: DomainActivityCenter,
        resolveChildLaunchPlan: @escaping ResolveChildLaunchPlan,
        prepareChildLaunches: @escaping PrepareChildLaunches,
        revokeChildLaunches: @escaping RevokeChildLaunches
    ) {
        self.identity = identity
        self.policyStore = policyStore
        self.interactionBroker = interactionBroker
        self.activityCenter = activityCenter
        prepareChildLaunch = { _, _, _ in nil }
        self.resolveChildLaunchPlan = resolveChildLaunchPlan
        self.prepareChildLaunches = prepareChildLaunches
        self.revokeChildLaunches = revokeChildLaunches
    }

    package func wrapping(
        _ binding: MCPDomainToolBinding,
        interactionAdapter: DomainLongRunningInteractionAdapter? = nil
    ) -> MCPDomainToolBinding {
        guard Self.toolNames.contains(binding.definition.name) else { return binding }
        let definition = binding.definition
        return MCPDomainToolBinding(definition: definition) { arguments in
            try await execute(
                binding: binding,
                arguments: arguments,
                interactionAdapter: interactionAdapter
            )
        }
    }

    private func execute(
        binding: MCPDomainToolBinding,
        arguments: [String: Value],
        interactionAdapter: DomainLongRunningInteractionAdapter?
    ) async throws -> Value {
        try Task.checkCancellation()
        let toolName = binding.definition.name
        let securityContext = MCPDomainInvocationSecurityContext.current
        let activity = await activityCenter.begin(
            kind: activityKind(toolName),
            toolName: toolName,
            invocationID: securityContext?.invocationID,
            sessionID: sessionID(arguments)
        )
        guard let activity else { throw CancellationError() }

        do {
            let value: Value
            if toolName == "ask_user" {
                value = try await executeInteraction(
                    binding: binding,
                    arguments: arguments,
                    securityContext: securityContext,
                    activity: activity,
                    interactionAdapter: interactionAdapter
                )
            } else {
                let requiresLaunch = requiresChildLaunch(toolName: toolName, arguments: arguments)
                let launchPlan: DomainChildLaunchPlan?
                if requiresLaunch, let resolveChildLaunchPlan {
                    guard let securityContext else {
                        throw MCPError.invalidParams(
                            "approval_required_noninteractive: missing verified invocation identity"
                        )
                    }
                    guard let resolved = try await resolveChildLaunchPlan(
                        toolName,
                        arguments,
                        securityContext
                    ) else {
                        throw MCPError.internalError(
                            "child_launch_plan_missing: launch-requiring planned execution must resolve an exact plan"
                        )
                    }
                    launchPlan = resolved
                } else {
                    launchPlan = nil
                }
                let authorizations: [DomainMutationAuthorizationSnapshot]
                do {
                    authorizations = try await authorizeIfNeeded(
                        toolName: toolName,
                        arguments: arguments,
                        context: securityContext
                    )
                } catch {
                    if let launchPlan { await revokeChildLaunches?(launchPlan, nil) }
                    throw error
                }
                do {
                    try Task.checkCancellation()
                } catch {
                    if let launchPlan { await revokeChildLaunches?(launchPlan, nil) }
                    throw error
                }
                let carrier: DomainChildLaunchCarrier?
                var bundle: DomainChildLaunchCarrierBundle?
                var handoff: DomainChildLaunchHandoff?
                if requiresLaunch {
                    guard let securityContext else {
                        throw MCPError.invalidParams(
                            "approval_required_noninteractive: missing verified invocation identity"
                        )
                    }
                    if let launchPlan, let prepareChildLaunches, launchPlan.preparation == .atHandoff {
                        // Nothing is minted now; the tool prepares its carriers at its handoff,
                        // after revalidating the same authorizations.
                        let policyStore = policyStore
                        let revokeChildLaunches = revokeChildLaunches
                        handoff = DomainChildLaunchHandoff(
                            prepare: { pin in
                                // Cancellation is checked first: a revalidation interrupted by it
                                // must read as cancellation, not as a changed policy.
                                try Task.checkCancellation()
                                do {
                                    for authorization in authorizations {
                                        try await policyStore.revalidate(authorization)
                                    }
                                } catch {
                                    if Task.isCancelled { throw CancellationError() }
                                    throw error
                                }
                                try Task.checkCancellation()
                                return try await prepareChildLaunches(
                                    launchPlan,
                                    toolName,
                                    arguments,
                                    securityContext,
                                    pin
                                )
                            },
                            revokeLate: { bundle in await revokeChildLaunches?(launchPlan, bundle) }
                        )
                        carrier = nil
                    } else if let launchPlan, let prepareChildLaunches {
                        do {
                            bundle = try await prepareChildLaunches(
                                launchPlan,
                                toolName,
                                arguments,
                                securityContext,
                                nil
                            )
                        } catch {
                            await revokeChildLaunches?(launchPlan, nil)
                            throw error
                        }
                        carrier = bundle?.singleCarrier
                    } else {
                        carrier = try await prepareChildLaunch(toolName, arguments, securityContext)
                    }
                } else {
                    carrier = nil
                }
                do {
                    for authorization in authorizations {
                        try await policyStore.revalidate(authorization)
                    }
                    try Task.checkCancellation()
                    value = try await DomainChildLaunchContext.$handoff.withValue(handoff) {
                        try await DomainChildLaunchContext.$bundle.withValue(bundle) {
                            try await DomainChildLaunchContext.$current.withValue(carrier) {
                                try await binding(arguments)
                            }
                        }
                    }
                } catch {
                    if let handoff { bundle = await handoff.close() }
                    if let launchPlan { await revokeChildLaunches?(launchPlan, bundle) }
                    throw error
                }
                if let handoff { bundle = await handoff.close() }
                if let launchPlan { await revokeChildLaunches?(launchPlan, bundle) }
            }
            _ = await activityCenter.finish(
                activity,
                state: .completed,
                commitID: UUID()
            )
            return value
        } catch is CancellationError {
            _ = await activityCenter.finish(
                activity,
                state: .cancelled,
                commitID: UUID(),
                statusText: "Cancelled"
            )
            throw CancellationError()
        } catch {
            _ = await activityCenter.finish(
                activity,
                state: .failed,
                commitID: UUID(),
                statusText: Self.safeErrorText(error)
            )
            throw error
        }
    }

    private func executeInteraction(
        binding: MCPDomainToolBinding,
        arguments: [String: Value],
        securityContext: DomainToolInvocationSecurityContext?,
        activity: DomainActivityToken,
        interactionAdapter: DomainLongRunningInteractionAdapter?
    ) async throws -> Value {
        _ = await activityCenter.update(
            activity,
            state: .waitingForInteraction,
            statusText: "Waiting for user response"
        )
        let requestSeed = DomainInteractionRequest(
            toolName: binding.definition.name,
            clientID: securityContext?.connectionID,
            invocationID: securityContext?.invocationID,
            runID: securityContext?.principal.runID,
            payload: arguments,
            deadline: .distantFuture
        )
        let timeout = try await interactionTimeout(
            arguments,
            request: requestSeed,
            adapter: interactionAdapter
        )
        let request = DomainInteractionRequest(
            id: requestSeed.id,
            toolName: requestSeed.toolName,
            clientID: requestSeed.clientID,
            invocationID: requestSeed.invocationID,
            runID: requestSeed.runID,
            payload: requestSeed.payload,
            deadline: Date().addingTimeInterval(timeout + 1)
        )
        let appUI = interactionAdapter.map { adapter in
            DomainInteractionProvider(
                kind: .appUI,
                isAvailable: adapter.isAvailable,
                present: { request in
                    try await DomainInteractionPresentationContext.$requestID.withValue(request.id) {
                        try await binding(arguments)
                    }
                },
                cancel: adapter.cancel
            )
        }
        let result = await interactionBroker.request(request, appUI: appUI)
        switch result {
        case let .response(value, _):
            return value
        case .timedOut:
            return .object([
                "answers": .object([:]),
                "timed_out": .bool(true),
                "skipped": .bool(false),
                "elapsed_seconds": .int(max(0, Int(timeout.rounded(.down))))
            ])
        case .cancelled:
            throw CancellationError()
        case .unavailable:
            throw MCPError.invalidParams(
                "interaction_unavailable: this client did not negotiate elicitation and no app UI presenter is available"
            )
        case let .failed(message):
            throw MCPError.internalError("ask_user interaction failed: \(message)")
        }
    }

    private func authorizeIfNeeded(
        toolName: String,
        arguments: [String: Value],
        context: DomainToolInvocationSecurityContext?
    ) async throws -> [DomainMutationAuthorizationSnapshot] {
        let classes = approvalClasses(toolName: toolName, arguments: arguments)
        guard !classes.isEmpty else { return [] }
        var snapshots: [DomainMutationAuthorizationSnapshot] = []
        for approvalClass in classes {
            snapshots.append(try await policyStore.authorize(
                context: context,
                toolName: toolName,
                action: approvalClass,
                workspaceID: context?.workspaceID,
                canonicalRoots: []
            ))
        }
        return snapshots
    }

    private func approvalClasses(
        toolName: String,
        arguments: [String: Value]
    ) -> [String] {
        switch toolName {
        case "ask_oracle", "oracle_send", "context_builder":
            return ["ai_cost", "external_process"]
        case "agent_explore":
            return normalizedOperation(arguments, fallback: "") == "start"
                ? ["ai_cost", "external_process"]
                : []
        case "agent_run":
            let operation = normalizedOperation(arguments, fallback: "wait")
            return ["start", "steer", "respond"].contains(operation)
                ? ["ai_cost", "external_process"]
                : []
        case "agent_manage":
            let operation = canonicalOperation(arguments, fallback: "list_sessions")
            if ["resume_session", "handoff"].contains(operation) {
                return ["ai_cost", "external_process"]
            }
            return operation == "create_session" ? ["external_process"] : []
        default:
            return []
        }
    }

    private func requiresChildLaunch(
        toolName: String,
        arguments: [String: Value]
    ) -> Bool {
        switch toolName {
        case "context_builder", "ask_oracle", "oracle_send":
            return true
        case "agent_explore":
            return normalizedOperation(arguments, fallback: "") == "start"
        case "agent_run":
            let operation = normalizedOperation(arguments, fallback: "wait")
            return ["start", "steer", "respond"].contains(operation)
        default:
            return false
        }
    }

    private func normalizedOperation(
        _ arguments: [String: Value],
        fallback: String
    ) -> String {
        guard let operation = arguments["op"]?.stringValue else { return fallback }
        return operation
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func canonicalOperation(
        _ arguments: [String: Value],
        fallback: String
    ) -> String {
        let operation = normalizedOperation(arguments, fallback: fallback)
        return operation == "extract_handoff" ? "handoff" : operation
    }

    private func activityKind(_ toolName: String) -> DomainActivityKind {
        switch toolName {
        case "ask_oracle", "oracle_send", "oracle_utils":
            .oracle
        case "context_builder":
            .contextBuilder
        case "agent_explore":
            .agentExplore
        case "agent_run":
            .agentRun
        case "agent_manage":
            .agentManage
        case "ask_user":
            .interaction
        default:
            .sessionControl
        }
    }

    private func sessionID(_ arguments: [String: Value]) -> UUID? {
        guard let raw = arguments["session_id"]?.stringValue else { return nil }
        return UUID(uuidString: raw)
    }

    private func interactionTimeout(
        _ arguments: [String: Value],
        request: DomainInteractionRequest,
        adapter: DomainLongRunningInteractionAdapter?
    ) async throws -> TimeInterval {
        if let suppliedValue = arguments["timeout_seconds"] {
            guard let supplied = suppliedValue.intValue, supplied > 0 else {
                throw MCPError.invalidParams("timeout_seconds must be a positive integer.")
            }
            return TimeInterval(supplied)
        }
        if let adapter {
            let resolved: TimeInterval
            do {
                resolved = try await adapter.resolveDefaultTimeoutSeconds(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return 300
            }
            guard resolved.isFinite, resolved > 0 else {
                throw MCPError.internalError("ask_user workspace timeout is invalid")
            }
            return resolved
        }
        return 300
    }

    private static func safeErrorText(_ error: Error) -> String {
        if error is CancellationError { return "Cancelled" }
        let text = String(describing: error)
        return String(text.prefix(512))
    }
}
