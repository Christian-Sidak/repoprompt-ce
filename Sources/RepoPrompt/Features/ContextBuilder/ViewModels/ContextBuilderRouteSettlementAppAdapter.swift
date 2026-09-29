import Foundation
import RepoPromptDomainRuntime

/// The MCP route authority a nested discovery run waits on while its provider stream runs.
/// Production adapts the run's bootstrap lease; focused parity tests script it.
protocol ContextBuilderRunRouteAuthority: Sendable {
    func waitForRoute(
        progressReporter: @escaping MCPBootstrapRoutingProgressReporter
    ) async -> MCPRoutingWaitOutcome
    func currentRoutingTerminalOutcome() async -> MCPRoutingWaitOutcome?
    func resolveRouteAuthorityAtProviderCompletion() async -> MCPRunRouteAuthorityDecision
    func childConnectionWasObserved() async -> Bool
}

struct ContextBuilderLeaseRouteAuthority: ContextBuilderRunRouteAuthority {
    let lease: MCPBootstrapLease
    let runID: UUID

    func waitForRoute(
        progressReporter: @escaping MCPBootstrapRoutingProgressReporter
    ) async -> MCPRoutingWaitOutcome {
        await lease.releaseWhenRoutedIndefinitely(progressReporter: progressReporter)
    }

    func currentRoutingTerminalOutcome() async -> MCPRoutingWaitOutcome? {
        await lease.currentRoutingTerminalOutcome()
    }

    func resolveRouteAuthorityAtProviderCompletion() async -> MCPRunRouteAuthorityDecision {
        await lease.resolveRouteAuthorityAtProviderCompletion()
    }

    func childConnectionWasObserved() async -> Bool {
        await MCPRoutingWaiter.connectionWasObserved(runID: runID)
    }
}

extension ContextBuilderDefaults {
    static let mcpPreRouteBufferLimits = ContextBuilderPreRouteBufferLimits(
        maxBufferedTextCharacters: mcpPreRouteBufferedTextCharacterLimit,
        maxBufferedEventCount: mcpPreRouteBufferedEventLimit
    )
}

extension AIStreamResult {
    /// Pre-route accounting for this event: its type plus every retained provider-supplied string.
    var contextBuilderPreRouteDescriptor: ContextBuilderPreRouteEventDescriptor {
        ContextBuilderPreRouteEventDescriptor(
            type: type,
            text: text,
            additionalPayloads: [
                reasoning,
                toolName,
                toolArgs,
                toolOutput,
                toolResultJSON,
                toolArgsJSON,
                providerSessionID,
                stopReason,
                contentMessageID
            ]
        )
    }
}

extension ContextBuilderRouteWaitResult {
    init(_ outcome: MCPRoutingWaitOutcome) {
        self = switch outcome {
        case .routed:
            .routed
        case .failed:
            .ownershipLost
        case .cancelled:
            .cancelled
        case .timedOutBeforeConnection:
            .timedOutBeforeConnection
        case .timedOutAfterConnection:
            .timedOutAfterConnection
        }
    }
}

extension ContextBuilderRouteCompletionAuthority {
    init(_ decision: MCPRunRouteAuthorityDecision) {
        self = switch decision {
        case .committed:
            .committed
        case .revocationFenced:
            .revocationFenced
        }
    }
}
