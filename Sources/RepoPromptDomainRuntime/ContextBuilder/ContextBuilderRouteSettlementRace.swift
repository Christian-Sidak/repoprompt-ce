import Foundation

// MARK: - Host port

/// Everything a nested discovery run's route/stream race needs from its host.
///
/// The host keeps ownership of the route authority (the MCP bootstrap lease in the app), the
/// run's workspace and session admission, presentation, and the mapping of its provider event
/// type. The race owns the tasks, the exactly-once settlement, the bounded pre-route buffer, and
/// every precedence decision.
///
/// Every requirement is called on the actor the race runs on. The race never calls into the host
/// between draining the buffer and the synchronous delivery that consumes the drain, so buffered
/// events always precede later ones. `Publication` carries what a synchronous delivery produced
/// to the asynchronous `publish(_:)` that follows it.
package protocol ContextBuilderRouteSettlementHost<Event>: AnyObject {
    associatedtype Event
    associatedtype Publication

    /// `false` once the run's owner is gone. The route wait and the stream then settle `.cancelled`.
    var isAttached: Bool { get }

    // Route authority.

    /// Waits indefinitely until routing commits, ownership is lost, or the task is cancelled.
    nonisolated(nonsending) func waitForRoute() async -> ContextBuilderRouteWaitResult
    /// A routing terminal signal that may have arrived before the route wait enrolled.
    nonisolated(nonsending) func currentRoutingOutcome() async -> ContextBuilderRouteWaitResult?
    /// Resolves a provider-completion race through the route authority.
    nonisolated(nonsending) func resolveCompletionAuthority() async -> ContextBuilderRouteCompletionAuthority

    // Routing watchdog.

    /// Sleeps until the watchdog should check on routing. Throws when the task is cancelled.
    nonisolated(nonsending) func sleepUntilRoutingWatchdog() async throws
    nonisolated(nonsending) func childConnectionWasObserved() async -> Bool
    /// Tells the user the run is still waiting for the provider's MCP connection.
    nonisolated(nonsending) func reportRoutingWatchdog() async

    // Admission.

    /// Whether the run still owns its session and may accept provider events.
    func acceptsProviderEvents() -> Bool
    /// Records liveness for one provider event. `false` means the run lost its attempt ownership.
    func recordProviderEventProgress() -> Bool
    /// Renders a provider stream failure for the run's terminal message.
    func failureMessage(for error: any Error) -> String

    // Provider mapping.

    func preRouteDescriptor(for event: Event) -> ContextBuilderPreRouteEventDescriptor

    // Delivery.

    /// Called once when routing commits, before the buffered events are drained.
    nonisolated(nonsending) func beginRoutedStream() async
    /// Replays the drained events with discovery activity and announces the committed route.
    func commitRoute(replaying drain: ContextBuilderPreRouteDrain<Event>) -> Publication
    /// Replays the drained events with discovery activity, then delivers `event`.
    func deliverRoutedEvent(_ event: Event, replaying drain: ContextBuilderPreRouteDrain<Event>) -> Publication
    /// Replays events that never routed, without discovery activity, so the user still sees them.
    func replayUnroutedEvents(_ drain: ContextBuilderPreRouteDrain<Event>)
    nonisolated(nonsending) func publish(_ publication: Publication) async

    // Observation.

    nonisolated(nonsending) func willProcessProviderEvent(_ event: Event) async
    func didDisposeProviderEvent(_ event: Event, accepted: Bool)
}

/// Settlement and outcome of one route/stream race.
package struct ContextBuilderRouteSettlementReport: Sendable, Equatable {
    package let settlement: ContextBuilderRouteSettlement
    package let outcome: ContextBuilderRouteRunOutcome

    package init(settlement: ContextBuilderRouteSettlement, outcome: ContextBuilderRouteRunOutcome) {
        self.settlement = settlement
        self.outcome = outcome
    }
}

// MARK: - Race

/// Races a nested discovery run's provider stream against its MCP route authority.
///
/// Three tasks start together: the route wait, the provider stream consumer, and a routing
/// watchdog. Whichever of the route wait, the stream, or outer cancellation settles first decides
/// the run; `ContextBuilderRouteSettlementPolicy.resolution(for:)` then decides which tasks are
/// cancelled or joined and what the race returns.
///
/// Every task runs on `isolation`, the caller's actor. The app passes the main actor and headless
/// hosts pass their own actor, so settlement, buffering, and delivery never interleave within a
/// step. The actor is required, never inferred: a nonisolated caller would let the tasks race.
package enum ContextBuilderRouteSettlementRace {
    package static func run<Host: ContextBuilderRouteSettlementHost>(
        _ stream: AsyncThrowingStream<Host.Event, any Error>,
        host: Host,
        limits: ContextBuilderPreRouteBufferLimits,
        isolation: isolated any Actor
    ) async -> ContextBuilderRouteSettlementReport {
        let state = ContextBuilderRouteSettlementRunState<Host.Event>(limits: limits)
        // Outer cancellation runs its handler synchronously on an arbitrary thread. The relay
        // hands `.cancelled` to the actor, where it races the other settlers in order.
        let (cancellationSignals, cancellationRelay) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )

        let routeTask = Task {
            await awaitRouteAuthority(host: host, state: state, isolation: isolation)
        }
        let streamTask = Task {
            await consumeProviderStream(stream, host: host, state: state, isolation: isolation)
        }
        let watchdogTask = Task {
            await runRoutingWatchdog(host: host, state: state, isolation: isolation)
        }
        Task {
            await settleOnOuterCancellation(cancellationSignals, state: state, isolation: isolation)
        }

        return await withTaskCancellationHandler {
            let settlement = await state.waitForSettlement(isolation: isolation)
            watchdogTask.cancel()

            let resolution = ContextBuilderRouteSettlementPolicy.resolution(for: settlement)
            if resolution.cancelsStream {
                streamTask.cancel()
            }
            if resolution.cancelsRouteWait {
                routeTask.cancel()
            }
            var streamOutcome: ContextBuilderRouteRunOutcome?
            if resolution.joinsStream {
                streamOutcome = await streamTask.value
            }
            if resolution.joinsRouteWait {
                await routeTask.value
            }
            if resolution.replaysUnroutedEvents {
                host.replayUnroutedEvents(state.machine.drainBufferedEvents())
            }
            cancellationRelay.finish()

            let outcome: ContextBuilderRouteRunOutcome = switch resolution.outcome {
            case .streamOutcome:
                // `.routed` always joins the stream.
                streamOutcome ?? .cancelled
            case let .failed(failure):
                .failed(failure)
            case .cancelled:
                .cancelled
            }
            return ContextBuilderRouteSettlementReport(settlement: settlement, outcome: outcome)
        } onCancel: {
            watchdogTask.cancel()
            streamTask.cancel()
            routeTask.cancel()
            cancellationRelay.yield()
        }
    }

    private static func awaitRouteAuthority<Host: ContextBuilderRouteSettlementHost>(
        host: Host,
        state: ContextBuilderRouteSettlementRunState<Host.Event>,
        isolation: isolated any Actor
    ) async {
        guard host.isAttached else {
            state.settle(.cancelled)
            return
        }
        let result = await host.waitForRoute()
        await settle(
            ContextBuilderRouteSettlementPolicy.settlement(forRouteWait: result),
            host: host,
            state: state,
            isolation: isolation
        )
    }

    private static func consumeProviderStream<Host: ContextBuilderRouteSettlementHost>(
        _ stream: AsyncThrowingStream<Host.Event, any Error>,
        host: Host,
        state: ContextBuilderRouteSettlementRunState<Host.Event>,
        isolation: isolated any Actor
    ) async -> ContextBuilderRouteRunOutcome {
        guard host.isAttached else {
            state.settle(.cancelled)
            return .cancelled
        }

        do {
            for try await event in stream {
                await host.willProcessProviderEvent(event)
                guard !Task.isCancelled, host.acceptsProviderEvents(), host.recordProviderEventProgress() else {
                    host.didDisposeProviderEvent(event, accepted: false)
                    state.settle(.cancelled)
                    return .cancelled
                }

                // Retry and child-process lifecycle notifications are ordinary stream events.
                // Only termination of this outer stream is authoritative before routing commits.
                switch state.machine.admit(event, descriptor: host.preRouteDescriptor(for: event)) {
                case .buffered:
                    break
                case let .deliver(replay):
                    let publication = host.deliverRoutedEvent(event, replaying: replay)
                    await host.publish(publication)
                case .rejected:
                    host.didDisposeProviderEvent(event, accepted: false)
                    return .cancelled
                }
                host.didDisposeProviderEvent(event, accepted: true)
            }
        } catch is CancellationError {
            state.settle(.cancelled)
            return .cancelled
        } catch {
            guard host.acceptsProviderEvents() else {
                state.settle(.cancelled)
                return .cancelled
            }
            let message = host.failureMessage(for: error)
            state.settle(.failedWithoutRoute(message))
            return .failed(.provider(message))
        }

        guard state.machine.isPending else { return .completed }
        let currentRoutingOutcome = await host.currentRoutingOutcome()
        switch ContextBuilderRouteSettlementPolicy.completionStep(currentRoutingOutcome: currentRoutingOutcome) {
        case let .settle(settlement, streamOutcome):
            await settle(settlement, host: host, state: state, isolation: isolation)
            return streamOutcome
        case .resolveCompletionAuthority:
            break
        }

        guard state.machine.isPending else { return .completed }
        let authority = await host.resolveCompletionAuthority()
        await settle(
            ContextBuilderRouteSettlementPolicy.settlement(forCompletionAuthority: authority),
            host: host,
            state: state,
            isolation: isolation
        )
        return .completed
    }

    private static func runRoutingWatchdog<Host: ContextBuilderRouteSettlementHost>(
        host: Host,
        state: ContextBuilderRouteSettlementRunState<Host.Event>,
        isolation: isolated any Actor
    ) async {
        do {
            try await host.sleepUntilRoutingWatchdog()
        } catch {
            return
        }
        guard host.isAttached, state.machine.isPending, host.acceptsProviderEvents() else { return }
        let connectionWasObserved = await host.childConnectionWasObserved()
        guard !connectionWasObserved, state.machine.isPending, host.acceptsProviderEvents() else { return }
        await host.reportRoutingWatchdog()
    }

    private static func settleOnOuterCancellation<Event>(
        _ signals: AsyncStream<Void>,
        state: ContextBuilderRouteSettlementRunState<Event>,
        isolation: isolated any Actor
    ) async {
        for await _ in signals {
            state.settle(.cancelled)
            return
        }
    }

    /// Claims `candidate`. When it wins `.routed`, commits the route: begin the routed stream,
    /// then drain and replay the buffer with no suspension between the drain and the replay.
    private static func settle<Host: ContextBuilderRouteSettlementHost>(
        _ candidate: ContextBuilderRouteSettlement,
        host: Host,
        state: ContextBuilderRouteSettlementRunState<Host.Event>,
        isolation: isolated any Actor
    ) async {
        guard state.settle(candidate), candidate == .routed else { return }
        await host.beginRoutedStream()
        let publication = host.commitRoute(replaying: state.machine.drainBufferedEvents())
        await host.publish(publication)
    }
}

/// Per-run settlement state plus its single waiter. Only touched on the race's actor.
private final class ContextBuilderRouteSettlementRunState<Event> {
    var machine: ContextBuilderRouteSettlementMachine<Event>
    private var waiter: CheckedContinuation<ContextBuilderRouteSettlement, Never>?

    init(limits: ContextBuilderPreRouteBufferLimits) {
        machine = ContextBuilderRouteSettlementMachine(limits: limits)
    }

    @discardableResult
    func settle(_ candidate: ContextBuilderRouteSettlement) -> Bool {
        guard machine.settle(candidate) else { return false }
        waiter?.resume(returning: candidate)
        waiter = nil
        return true
    }

    func waitForSettlement(isolation: isolated any Actor) async -> ContextBuilderRouteSettlement {
        if let settlement = machine.settlement {
            return settlement
        }
        precondition(waiter == nil, "A route settlement supports exactly one waiter.")
        return await withCheckedContinuation { continuation in
            if let settlement = machine.settlement {
                continuation.resume(returning: settlement)
            } else {
                waiter = continuation
            }
        }
    }
}
