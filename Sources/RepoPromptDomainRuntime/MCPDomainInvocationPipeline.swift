import Foundation
import MCP
import RepoPromptShared

// MARK: - Shared admission mapping

extension MCPToolAdmissionClass {
    /// The per-connection lane that orders calls of this class. One definition serves the app
    /// adapter and direct headless so both compositions admit the same tool the same way.
    package var connectionLane: MCPDomainConnectionCallLane {
        switch self {
        case .exclusive:
            .ordinary
        case .control:
            .control
        case .smallRead:
            .smallRead
        case .fileRead:
            .fileRead
        case .gitRead:
            .gitRead
        case .fileSearch:
            .fileSearch
        }
    }
}

// MARK: - Typed failures

/// Consumer-facing tool failure with a stable code and retry guidance.
///
/// Codes intentionally match the app adapter's execution-contract codes so a host sees the same
/// vocabulary regardless of backend.
package struct MCPDomainToolFailure: Error, Equatable, Sendable {
    package let toolName: String
    package let code: String
    package let message: String
    package let retryability: MCPFailureRetryability
    package let retryAfterMilliseconds: Int?
    /// `DomainProtectedMutationState` raw value observed for this invocation, when any.
    package let mutationState: String?
    package let operationID: String?
    package let settlement: String?
    /// Tool-specific structured facts about what did happen (for example, the committed selection
    /// and pack reference of a Context Builder run whose Oracle step failed). Rendered under
    /// `details`; empty for every classifier-derived failure.
    package let details: [String: Value]

    package init(
        toolName: String,
        code: String,
        message: String,
        retryability: MCPFailureRetryability,
        retryAfterMilliseconds: Int? = nil,
        mutationState: String? = nil,
        operationID: String? = nil,
        settlement: String? = nil,
        details: [String: Value] = [:]
    ) {
        self.toolName = toolName
        self.code = code
        self.message = message
        self.retryability = retryability
        self.retryAfterMilliseconds = retryAfterMilliseconds
        self.mutationState = mutationState
        self.operationID = operationID
        self.settlement = settlement
        self.details = details
    }

    package var metadata: [String: Value] {
        var metadata: [String: Value] = [
            "code": .string(code),
            "error": .string(message),
            "tool": .string(toolName),
            "retryability": .string(retryability.rawValue),
            "retryable": .bool(retryability.legacyRetryableFlag)
        ]
        if let retryAfterMilliseconds { metadata["retry_after_ms"] = .int(retryAfterMilliseconds) }
        if let mutationState { metadata["mutation_state"] = .string(mutationState) }
        if let operationID { metadata["operation_id"] = .string(operationID) }
        if let settlement { metadata["settlement"] = .string(settlement) }
        if !details.isEmpty { metadata["details"] = .object(details) }
        return metadata
    }

    /// Human-readable first line followed by the machine-readable metadata object.
    package var renderedText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = (try? encoder.encode(Value.object(metadata)))
            .flatMap { String(data: $0, encoding: .utf8) }
        guard let json else { return "\(code): \(message)" }
        return "\(code): \(message)\n\(json)"
    }
}

/// Maps runtime, admission, watchdog, and provider errors onto `MCPDomainToolFailure`.
///
/// Retry guidance is derived from where the call stopped, never optimistically: once a
/// mutation-capable tool may have started work, an interruption is `indeterminate` unless the
/// protected-mutation journal reported `not_applied`.
package enum MCPDomainToolFailureClassifier {
    package static func classify(
        _ error: Error,
        toolName: String,
        admissionClass: MCPToolAdmissionClass?,
        contract: MCPToolExecutionContract?,
        mutation: DomainProtectedMutationSettlement?
    ) -> MCPDomainToolFailure {
        if let failure = error as? MCPDomainToolFailure {
            return failure
        }
        let mayMutate = admissionClass == nil || admissionClass == .exclusive
        let mutationState = mutation?.state.rawValue
        let operationID = mutation?.operationID

        func failure(
            _ code: String,
            _ message: String,
            _ retryability: MCPFailureRetryability,
            settlement: String? = nil,
            mutationStateOverride: String? = nil
        ) -> MCPDomainToolFailure {
            MCPDomainToolFailure(
                toolName: toolName,
                code: code,
                message: message,
                retryability: retryability,
                mutationState: mutationStateOverride ?? mutationState,
                operationID: operationID,
                settlement: settlement
            )
        }

        // Work started and was then interrupted by a deadline or cancellation.
        let interrupted: MCPFailureRetryability = switch mutation?.state {
        case .notApplied?:
            .retryable
        case .applied?, .unknown?, .indeterminateAfterCommit?:
            .indeterminate
        case nil:
            mayMutate ? .indeterminate : .retryable
        }
        // Work ran to a provider error.
        let failed: MCPFailureRetryability = switch mutation?.state {
        case .applied?, .unknown?, .indeterminateAfterCommit?:
            .indeterminate
        case .notApplied?, nil:
            .permanent
        }
        let deadlineDescription = contract?.deadline.map { Self.secondsDescription($0) } ?? "declared"

        switch error {
        case let denial as MCPDomainCallPolicyDenial:
            return failure("tool_policy_denied", Self.message(for: denial), .permanent)

        case let hostError as MCPDomainHostError:
            switch hostError {
            case .draining:
                return failure("tool_execution_runtime_draining", "The MCP runtime is shutting down.", .retryable)
            case .duplicateInvocationID:
                return failure("tool_execution_duplicate_invocation", "Duplicate invocation identity was rejected.", .permanent)
            case let .unknownTool(name):
                return failure("tool_unknown", "Unknown tool '\(name)'.", .permanent)
            case .scopeUnavailable:
                return failure("tool_scope_unavailable", "Tool '\(toolName)' is not registered for this connection's scope.", .permanent)
            case .staleRegistration:
                return failure("tool_registration_stale", "Tool '\(toolName)' was re-registered while the call was admitted.", .retryable)
            case .runtimeGenerationMismatch, .connectionRegistrationInvalid:
                return failure("tool_execution_connection_terminal", "The MCP connection is closing.", .retryable)
            }

        case is MCPDomainAdmissionDeadline.Expired,
             MCPToolExecutionWatchdogError.admissionEnvelopeExpired:
            return failure(
                "tool_execution_admission_timeout",
                "Tool '\(toolName)' could not be admitted within its \(deadlineDescription)-second execution contract.",
                .retryable,
                settlement: "admission_timeout",
                mutationStateOverride: DomainProtectedMutationState.notApplied.rawValue
            )

        case let MCPToolExecutionWatchdogError.executionTimedOut(settlement):
            return failure(
                "tool_execution_timeout",
                "Tool '\(toolName)' exceeded its \(deadlineDescription)-second execution contract and settled as \(settlement.rawValue) during cancellation grace.",
                interrupted,
                settlement: settlement.rawValue
            )

        case MCPToolExecutionWatchdogError.executionDetached:
            return failure(
                "tool_execution_timeout",
                "Tool '\(toolName)' exceeded its \(deadlineDescription)-second execution contract and did not settle during cancellation grace; it was detached and its resources stay reserved until it settles.",
                interrupted,
                settlement: "detached"
            )

        case MCPToolExecutionWatchdogError.cleanupUnresponsive:
            return failure(
                "tool_execution_cleanup_unresponsive",
                "Tool '\(toolName)' exceeded its \(deadlineDescription)-second execution contract and ignored cancellation; its resources stay reserved until it settles.",
                interrupted,
                settlement: "cleanup_unresponsive"
            )

        case is MCPDomainConnectionCallLimiters.AdmissionRejected,
             MCPDomainToolResourceAdmissionController.AdmissionError.closed:
            return failure("tool_execution_connection_terminal", "The MCP connection is closing.", .retryable)

        case let protected as DomainProtectedMutationError:
            return MCPDomainToolFailure(
                toolName: toolName,
                code: "protected_mutation_indeterminate_after_commit",
                message: protected.localizedDescription,
                retryability: .indeterminate,
                mutationState: protected.settlement.state.rawValue,
                operationID: protected.settlement.operationID,
                settlement: "error"
            )

        case let mcpError as MCPError:
            if case let .invalidParams(detail) = mcpError {
                return failure("invalid_params", detail ?? "Invalid parameters.", .permanent)
            }
            return failure("tool_error", Self.describe(mcpError), failed)

        default:
            if MCPToolExecutionCancelledError.matches(error) {
                return failure("tool_execution_cancelled", "Tool '\(toolName)' was cancelled.", interrupted)
            }
            return failure("tool_execution_failed", Self.describe(error), failed)
        }
    }

    private static func describe(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            return localized
        }
        return String(describing: error)
    }

    private static func message(for denial: MCPDomainCallPolicyDenial) -> String {
        switch denial {
        case let .missingAdditionalGrant(toolName):
            "Tool '\(toolName)' requires an additional grant for this client."
        case let .restricted(toolName):
            "Tool '\(toolName)' is restricted for this client."
        case let .roleUnavailable(toolName):
            "Tool '\(toolName)' is unavailable for this client's role."
        case let .unknownTool(toolName):
            "Unknown tool '\(toolName)'."
        case let .missingAdmissionClassification(toolName):
            "Tool '\(toolName)' has no admission classification."
        }
    }

    private static func secondsDescription(_ duration: Duration) -> String {
        let components = duration.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        if seconds.rounded() == seconds {
            return String(Int(seconds))
        }
        return String(format: "%.3g", seconds)
    }
}

// MARK: - Invocation pipeline

/// Protocol-neutral composition of the host's admission and execution bounds.
///
/// In order: pre-admission call policy, the per-connection lane permit, the cross-connection
/// resource lease, the declared execution contract, the watchdog for bounded contracts, and the
/// exact host invocation. Every failure is classified into `MCPDomainToolFailure`.
///
/// The resource lease is released only when the host invocation itself settles, so a provider
/// that outlives its watchdog (detached or cleanup-unresponsive) keeps its resource reserved and
/// cannot overlap a later call on the same state.
package struct MCPDomainInvocationPipeline: Sendable {
    package struct Invocation: Sendable {
        package let toolName: String
        package let arguments: [String: Value]
        package let scope: MCPDomainToolRegistrationScope
        package let policy: MCPDomainClientPolicySnapshot
        package let resource: MCPDomainToolResourceAdmissionController.Resource
        /// Builds the exact host invocation once admission has succeeded.
        package let makeHostInvocation: @Sendable (MCPDomainHostResolution) async throws -> MCPDomainHostInvocation

        package init(
            toolName: String,
            arguments: [String: Value],
            scope: MCPDomainToolRegistrationScope,
            policy: MCPDomainClientPolicySnapshot,
            resource: MCPDomainToolResourceAdmissionController.Resource,
            makeHostInvocation: @escaping @Sendable (MCPDomainHostResolution) async throws -> MCPDomainHostInvocation
        ) {
            self.toolName = toolName
            self.arguments = arguments
            self.scope = scope
            self.policy = policy
            self.resource = resource
            self.makeHostInvocation = makeHostInvocation
        }
    }

    private let host: MCPDomainHost
    private let limiters: MCPDomainConnectionCallLimiters
    private let watchdogEnvironment: @Sendable () -> MCPToolExecutionWatchdogEnvironment

    package init(
        host: MCPDomainHost,
        limiters: MCPDomainConnectionCallLimiters,
        watchdogEnvironment: @escaping @Sendable () -> MCPToolExecutionWatchdogEnvironment = { .continuous() }
    ) {
        self.host = host
        self.limiters = limiters
        self.watchdogEnvironment = watchdogEnvironment
    }

    /// Connection lanes sized from the shared admission limits.
    package static func makeConnectionLimiters() -> MCPDomainConnectionCallLimiters {
        MCPDomainConnectionCallLimiters(
            limit: MCPDomainToolAdmissionLimits.exclusiveConnection,
            controlLimit: MCPDomainToolAdmissionLimits.controlConnection,
            smallReadLimit: MCPDomainToolAdmissionLimits.smallReadConnection,
            fileReadLimit: MCPDomainToolAdmissionLimits.fileReadConnection,
            gitReadLimit: MCPDomainToolAdmissionLimits.gitReadConnection,
            fileSearchLimit: MCPDomainToolAdmissionLimits.fileSearchConnection
        )
    }

    package func execute(_ invocation: Invocation) async -> Result<Value, MCPDomainToolFailure> {
        let toolName = invocation.toolName
        let admissionClass: MCPToolAdmissionClass
        do {
            admissionClass = try await host.evaluatePreAdmissionCallPolicy(
                toolName: toolName,
                policy: invocation.policy
            ).admissionClass
        } catch {
            return .failure(Self.classify(error, invocation, admissionClass: nil, contract: nil, mutation: nil))
        }
        guard let contract = MCPToolExecutionContractCatalog.contract(
            for: toolName,
            arguments: invocation.arguments
        ) else {
            return .failure(MCPDomainToolFailure(
                toolName: toolName,
                code: "tool_execution_contract_missing",
                message: "No declared execution contract exists for MCP tool '\(toolName)'.",
                retryability: .permanent
            ))
        }

        let environment = watchdogEnvironment()
        // Bounded contracts also bound admission, so a runaway predecessor that still holds a
        // lane or resource cannot make a later call wait forever.
        let admissionDeadline = contract.deadline.map { deadline in
            MCPDomainAdmissionDeadline(
                instant: environment.now() + deadline,
                now: environment.now,
                sleep: environment.sleep
            )
        }
        let observation = MutationSettlementObservation()
        let host = host
        do {
            let resolution = try await host.resolve(toolName: toolName, scope: invocation.scope)
            let value = try await limiters.withPermit(
                lane: admissionClass.connectionLane,
                admissionDeadline: admissionDeadline
            ) {
                let lease = try await host.acquireResourceAdmission(
                    for: admissionClass,
                    resource: invocation.resource,
                    admissionDeadline: admissionDeadline
                )
                let hostInvocation: MCPDomainHostInvocation
                do {
                    hostInvocation = try await invocation.makeHostInvocation(resolution)
                } catch {
                    lease?.release()
                    throw error
                }
                let hostTask = Task {
                    defer { lease?.release() }
                    return try await MCPDomainProtectedMutationSettlementContext.$observer.withValue({ settlement in
                        observation.record(settlement)
                    }) {
                        try await host.invoke(hostInvocation)
                    }
                }
                let operation: @Sendable () async throws -> Value = {
                    try await withTaskCancellationHandler {
                        try await hostTask.value
                    } onCancel: {
                        hostTask.cancel()
                    }
                }
                guard case let .bounded(deadline, cancellationGrace, cleanupDisposition) = contract else {
                    return try await operation()
                }
                return try await MCPToolExecutionWatchdog.execute(
                    deadline: deadline,
                    cancellationGrace: cancellationGrace,
                    cleanupDisposition: cleanupDisposition,
                    environment: environment,
                    operation: operation
                )
            }
            return .success(value)
        } catch {
            return .failure(Self.classify(
                error,
                invocation,
                admissionClass: admissionClass,
                contract: contract,
                mutation: observation.snapshot()
            ))
        }
    }

    private static func classify(
        _ error: Error,
        _ invocation: Invocation,
        admissionClass: MCPToolAdmissionClass?,
        contract: MCPToolExecutionContract?,
        mutation: DomainProtectedMutationSettlement?
    ) -> MCPDomainToolFailure {
        MCPDomainToolFailureClassifier.classify(
            error,
            toolName: invocation.toolName,
            admissionClass: admissionClass,
            contract: contract,
            mutation: mutation
        )
    }
}

/// Keeps the most informative protected-mutation settlement reported during one invocation.
private final class MutationSettlementObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var settlement: DomainProtectedMutationSettlement?

    func record(_ settlement: DomainProtectedMutationSettlement) {
        lock.withLock {
            if self.settlement == nil || self.settlement?.state == .unknown {
                self.settlement = settlement
            }
        }
    }

    func snapshot() -> DomainProtectedMutationSettlement? {
        lock.withLock { settlement }
    }
}
