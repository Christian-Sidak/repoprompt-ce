import Foundation

// MARK: - Route settlement vocabulary

/// How a nested discovery run's wait for MCP routing ended. It is claimed exactly once: the first
/// of the route authority, the provider stream, or outer cancellation to settle wins.
package enum ContextBuilderRouteSettlement: Sendable, Equatable {
    /// The provider's MCP connection was routed to this run; provider events flow to the host.
    case routed
    /// The provider stream finished and the route authority fenced a late route.
    case completedWithoutRoute
    /// The provider stream failed before routing committed.
    case failedWithoutRoute(String)
    /// The route authority lost ownership of this run's routing.
    case routingOwnershipLost
    /// The run was cancelled or stopped accepting events.
    case cancelled
}

/// Terminal result of the host's indefinite route wait.
package enum ContextBuilderRouteWaitResult: Sendable, Equatable {
    case routed
    case ownershipLost
    case cancelled
    case timedOutBeforeConnection
    case timedOutAfterConnection
}

/// The route authority's decision when the provider stream completes while routing is pending.
package enum ContextBuilderRouteCompletionAuthority: Sendable, Equatable {
    case committed
    case revocationFenced
}

/// Why a nested discovery run failed at the route/stream boundary.
package enum ContextBuilderRouteFailure: Sendable, Equatable {
    case completedWithoutRoute
    case routingOwnershipLost
    /// The provider stream failed; the message is the host's rendering of the provider error.
    case provider(String)
}

/// Outcome of the provider stream, and of the whole route/stream race.
package enum ContextBuilderRouteRunOutcome: Sendable, Equatable {
    case completed
    case cancelled
    case failed(ContextBuilderRouteFailure)
}

// MARK: - Precedence policy

/// Pure precedence tables shared by every host. They decide which settlement a signal claims and,
/// once one is claimed, which tasks are cancelled or joined and what the run returns.
package enum ContextBuilderRouteSettlementPolicy {
    /// The settlement the route authority's own wait claims.
    package static func settlement(forRouteWait result: ContextBuilderRouteWaitResult) -> ContextBuilderRouteSettlement {
        switch result {
        case .routed:
            .routed
        case .ownershipLost:
            .routingOwnershipLost
        case .cancelled:
            .cancelled
        case .timedOutBeforeConnection, .timedOutAfterConnection:
            // The indefinite wait never schedules elapsed-time deadlines, so a timeout can only
            // mean the waiter lost ownership of routing.
            .routingOwnershipLost
        }
    }

    /// What the stream does when the provider finished normally while routing is still pending.
    package enum CompletionStep: Sendable, Equatable {
        /// Claim this settlement and return this stream outcome.
        case settle(ContextBuilderRouteSettlement, streamOutcome: ContextBuilderRouteRunOutcome)
        /// No routing terminal signal is known yet: ask the route authority to decide.
        case resolveCompletionAuthority
    }

    /// Consults a routing terminal signal that may have arrived before the route waiter enrolled.
    package static func completionStep(
        currentRoutingOutcome: ContextBuilderRouteWaitResult?
    ) -> CompletionStep {
        switch currentRoutingOutcome {
        case .routed:
            .settle(.routed, streamOutcome: .completed)
        case .ownershipLost:
            .settle(.routingOwnershipLost, streamOutcome: .completed)
        case .cancelled:
            .settle(.cancelled, streamOutcome: .cancelled)
        case .timedOutBeforeConnection, .timedOutAfterConnection, nil:
            .resolveCompletionAuthority
        }
    }

    package static func settlement(
        forCompletionAuthority authority: ContextBuilderRouteCompletionAuthority
    ) -> ContextBuilderRouteSettlement {
        switch authority {
        case .committed:
            .routed
        case .revocationFenced:
            .completedWithoutRoute
        }
    }

    /// The join plan after a settlement is claimed. The race applies it in a fixed order: cancel,
    /// join the stream, join the route wait, replay unrouted events, then return the outcome.
    package struct Resolution: Sendable, Equatable {
        package enum Outcome: Sendable, Equatable {
            /// Return whatever the provider stream returned.
            case streamOutcome
            case failed(ContextBuilderRouteFailure)
            case cancelled
        }

        package let cancelsStream: Bool
        package let cancelsRouteWait: Bool
        package let joinsStream: Bool
        package let joinsRouteWait: Bool
        /// Unrouted buffered events are still shown to the user, without discovery activity.
        package let replaysUnroutedEvents: Bool
        package let outcome: Outcome
    }

    package static func resolution(for settlement: ContextBuilderRouteSettlement) -> Resolution {
        switch settlement {
        case .routed:
            Resolution(
                cancelsStream: false,
                cancelsRouteWait: false,
                joinsStream: true,
                joinsRouteWait: true,
                replaysUnroutedEvents: false,
                outcome: .streamOutcome
            )
        case .completedWithoutRoute:
            Resolution(
                cancelsStream: false,
                cancelsRouteWait: true,
                joinsStream: false,
                joinsRouteWait: true,
                replaysUnroutedEvents: true,
                outcome: .failed(.completedWithoutRoute)
            )
        case let .failedWithoutRoute(message):
            Resolution(
                cancelsStream: false,
                cancelsRouteWait: true,
                joinsStream: false,
                joinsRouteWait: true,
                replaysUnroutedEvents: true,
                outcome: .failed(.provider(message))
            )
        case .routingOwnershipLost:
            Resolution(
                cancelsStream: true,
                cancelsRouteWait: false,
                joinsStream: true,
                joinsRouteWait: true,
                replaysUnroutedEvents: false,
                outcome: .failed(.routingOwnershipLost)
            )
        case .cancelled:
            Resolution(
                cancelsStream: true,
                cancelsRouteWait: true,
                joinsStream: true,
                joinsRouteWait: true,
                replaysUnroutedEvents: false,
                outcome: .cancelled
            )
        }
    }
}

// MARK: - Settlement state

/// Exactly-once route settlement plus the bounded pre-route buffer, as one value.
///
/// While pending, provider events are buffered. Once routed, each event is delivered after an
/// atomic drain of everything buffered, so replay always precedes later events. Any other
/// settlement rejects events.
package struct ContextBuilderRouteSettlementMachine<Event> {
    package enum Disposition {
        case buffered
        case deliver(replaying: ContextBuilderPreRouteDrain<Event>)
        case rejected
    }

    package private(set) var settlement: ContextBuilderRouteSettlement?
    private var buffer: ContextBuilderPreRouteEventBuffer<Event>

    package init(limits: ContextBuilderPreRouteBufferLimits) {
        buffer = ContextBuilderPreRouteEventBuffer(limits: limits)
    }

    package var isPending: Bool {
        settlement == nil
    }

    package var isRouted: Bool {
        settlement == .routed
    }

    package var bufferedEventCount: Int {
        buffer.bufferedEventCount
    }

    /// Claims `candidate` if nothing has settled yet. Returns whether this call won.
    @discardableResult
    package mutating func settle(_ candidate: ContextBuilderRouteSettlement) -> Bool {
        guard settlement == nil else { return false }
        settlement = candidate
        return true
    }

    /// Decides one provider event. The descriptor is computed only when the event is buffered.
    package mutating func admit(
        _ event: Event,
        descriptor: @autoclosure () -> ContextBuilderPreRouteEventDescriptor
    ) -> Disposition {
        switch settlement {
        case nil:
            buffer.append(event, descriptor: descriptor())
            return .buffered
        case .routed:
            return .deliver(replaying: buffer.drain())
        case .completedWithoutRoute, .failedWithoutRoute, .routingOwnershipLost, .cancelled:
            return .rejected
        }
    }

    package mutating func drainBufferedEvents() -> ContextBuilderPreRouteDrain<Event> {
        buffer.drain()
    }
}

extension ContextBuilderRouteSettlementMachine: Sendable where Event: Sendable {}
extension ContextBuilderRouteSettlementMachine.Disposition: Sendable where Event: Sendable {}
