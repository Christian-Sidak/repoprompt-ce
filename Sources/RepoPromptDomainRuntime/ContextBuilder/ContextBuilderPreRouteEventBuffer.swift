import Foundation

// MARK: - Pre-route provider event accounting

/// Provider-neutral accounting facts for one provider event observed before MCP routing commits.
///
/// Hosts map their own provider event type onto this value; the pre-route buffer never inspects
/// the event itself. `payloadCharacterCount` counts every retained provider-supplied string,
/// including the event type discriminator, in `Character`s.
package struct ContextBuilderPreRouteEventDescriptor: Sendable, Equatable {
    package enum Kind: Sendable, Equatable {
        /// Ordinary assistant content. Empty content carries no payload beyond its type.
        case content(isEmpty: Bool)
        /// Lifecycle, event, or status progress. Only the newest event of each type is kept.
        case progress
        /// Tool, error, result, terminal, and every other event. Evicted only as a last resort.
        case protected
    }

    package static let contentType = "content"
    package static let coalescibleProgressTypes: Set<String> = ["lifecycle", "event", "status"]

    package let type: String
    package let kind: Kind
    package let payloadCharacterCount: Int

    /// - Parameters:
    ///   - type: The provider event type discriminator.
    ///   - text: The event's assistant text, which decides whether content is empty.
    ///   - additionalPayloads: Every other retained provider-supplied string on the event.
    package init(type: String, text: String?, additionalPayloads: [String?]) {
        self.type = type
        if type == Self.contentType {
            kind = .content(isEmpty: text?.isEmpty ?? true)
        } else if Self.coalescibleProgressTypes.contains(type) {
            kind = .progress
        } else {
            kind = .protected
        }
        payloadCharacterCount = additionalPayloads.reduce(type.count + (text?.count ?? 0)) {
            $0 + ($1?.count ?? 0)
        }
    }

    var isContent: Bool {
        if case .content = kind { return true }
        return false
    }

    /// Progress, or content with no text: dropping it loses no assistant output.
    var isRedundantNonterminal: Bool {
        kind == .progress || kind == .content(isEmpty: true)
    }
}

/// Hard bounds on what a run retains while it waits for MCP routing. Negative limits clamp to zero.
package struct ContextBuilderPreRouteBufferLimits: Sendable, Equatable {
    package let maxBufferedTextCharacters: Int
    package let maxBufferedEventCount: Int

    package init(maxBufferedTextCharacters: Int, maxBufferedEventCount: Int) {
        self.maxBufferedTextCharacters = max(0, maxBufferedTextCharacters)
        self.maxBufferedEventCount = max(0, maxBufferedEventCount)
    }
}

/// Everything a pre-route buffer held, in arrival order, and what it had to drop.
package struct ContextBuilderPreRouteDrain<Event> {
    package let events: [Event]
    /// Payload characters of every evicted or coalesced event since the previous drain.
    package let droppedTextCharacterCount: Int
    /// Number of evicted or coalesced events since the previous drain, protected ones included.
    package let droppedEventCount: Int

    package init(events: [Event], droppedTextCharacterCount: Int, droppedEventCount: Int) {
        self.events = events
        self.droppedTextCharacterCount = droppedTextCharacterCount
        self.droppedEventCount = droppedEventCount
    }

    package var hasDroppedEvents: Bool {
        droppedTextCharacterCount > 0 || droppedEventCount > 0
    }

    /// The run-log line every host records for dropped pre-route events, or `nil` when none were dropped.
    package var droppedSummary: String? {
        guard hasDroppedEvents else { return nil }
        let details = [
            droppedTextCharacterCount > 0
                ? "\(droppedTextCharacterCount) characters of early provider payload"
                : nil,
            droppedEventCount > 0
                ? "\(droppedEventCount) early provider events"
                : nil
        ].compactMap(\.self).joined(separator: " and ")
        return "Dropped \(details) while waiting for MCP routing."
    }
}

extension ContextBuilderPreRouteDrain: Sendable where Event: Sendable {}

/// Bounded, order-preserving buffer for provider events that arrive before MCP routing commits.
///
/// Accounting is exact: every event removed by coalescing or eviction adds its payload characters
/// and one event to the dropped totals reported by the next `drain()`.
///
/// - Coalescing: a progress event replaces the newest buffered progress event of the same type.
/// - Payload bound: evict ordinary content first so compact diagnostics survive, then redundant
///   progress, then the oldest protected event so oversized payloads cannot win.
/// - Count bound: evict redundant progress or empty content first, then ordinary content, then
///   the oldest protected event so tool, error, result, or terminal-only streams stay bounded.
package struct ContextBuilderPreRouteEventBuffer<Event> {
    package let limits: ContextBuilderPreRouteBufferLimits
    private var entries: [(event: Event, descriptor: ContextBuilderPreRouteEventDescriptor)] = []
    package private(set) var bufferedTextCharacterCount = 0
    private var droppedTextCharacterCount = 0
    private var droppedEventCount = 0

    package init(limits: ContextBuilderPreRouteBufferLimits) {
        self.limits = limits
    }

    package var bufferedEventCount: Int {
        entries.count
    }

    package var bufferedDescriptors: [ContextBuilderPreRouteEventDescriptor] {
        entries.map(\.descriptor)
    }

    package mutating func append(_ event: Event, descriptor: ContextBuilderPreRouteEventDescriptor) {
        if descriptor.kind == .progress,
           let existingIndex = entries.lastIndex(where: {
               $0.descriptor.type == descriptor.type && $0.descriptor.kind == .progress
           })
        {
            removeEntry(at: existingIndex)
        }

        entries.append((event, descriptor))
        bufferedTextCharacterCount += descriptor.payloadCharacterCount
        trimToLimits()
    }

    package mutating func drain() -> ContextBuilderPreRouteDrain<Event> {
        let drained = ContextBuilderPreRouteDrain(
            events: entries.map(\.event),
            droppedTextCharacterCount: droppedTextCharacterCount,
            droppedEventCount: droppedEventCount
        )
        entries.removeAll(keepingCapacity: false)
        bufferedTextCharacterCount = 0
        droppedTextCharacterCount = 0
        droppedEventCount = 0
        return drained
    }

    private mutating func trimToLimits() {
        while bufferedTextCharacterCount > limits.maxBufferedTextCharacters,
              let index = nextPayloadEvictionIndex()
        {
            removeEntry(at: index)
        }
        while entries.count > limits.maxBufferedEventCount,
              let index = nextCountEvictionIndex()
        {
            removeEntry(at: index)
        }
    }

    private func nextPayloadEvictionIndex() -> Int? {
        entries.firstIndex(where: { $0.descriptor.isContent })
            ?? entries.firstIndex(where: { $0.descriptor.isRedundantNonterminal })
            ?? entries.indices.first
    }

    private func nextCountEvictionIndex() -> Int? {
        entries.firstIndex(where: { $0.descriptor.isRedundantNonterminal })
            ?? entries.firstIndex(where: { $0.descriptor.isContent })
            ?? entries.indices.first
    }

    private mutating func removeEntry(at index: Int) {
        let removed = entries.remove(at: index)
        bufferedTextCharacterCount -= removed.descriptor.payloadCharacterCount
        droppedTextCharacterCount += removed.descriptor.payloadCharacterCount
        droppedEventCount += 1
    }
}

extension ContextBuilderPreRouteEventBuffer: Sendable where Event: Sendable {}
