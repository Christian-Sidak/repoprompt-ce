import Foundation

/// Local, counts-only aggregation of MCP terminal records for the field-failure taxonomy.
///
/// Output is limited to closed enums, stable reason tokens, counts, and the time window. Error
/// descriptions, session fingerprints, process identifiers, tool names, and paths never appear.
public struct MCPTerminalRecordSummary: Codable, Equatable, Sendable {
    public struct ReasonCount: Codable, Equatable, Sendable {
        public let layer: MCPTerminalLayer
        public let initiator: MCPTerminalInitiator
        public let reason: String
        public let count: Int
    }

    public let recordCount: Int
    public let undecodableRecordCount: Int
    public let windowStart: Date?
    public let windowEnd: Date?
    /// Sorted by descending count, then layer, initiator, and reason.
    public let reasons: [ReasonCount]
    /// Records written while at least one bridged request was still active.
    public let recordsWithActiveRequests: Int
    public let recordsWithResponseInDelivery: Int
    public let hostSettledRequestTotal: Int
    public let hostUnsettledRequestTotal: Int
    /// Records where at least one host request was left without an answer.
    public let recordsWithUnsettledRequests: Int

    private enum CodingKeys: String, CodingKey {
        case recordCount = "record_count"
        case undecodableRecordCount = "undecodable_record_count"
        case windowStart = "window_start"
        case windowEnd = "window_end"
        case reasons
        case recordsWithActiveRequests = "records_with_active_requests"
        case recordsWithResponseInDelivery = "records_with_response_in_delivery"
        case hostSettledRequestTotal = "host_settled_request_total"
        case hostUnsettledRequestTotal = "host_unsettled_request_total"
        case recordsWithUnsettledRequests = "records_with_unsettled_requests"
    }

    /// Replaces any reason that is not a short stable token, so free text can never leak even from
    /// records written by older builds.
    public static func stableReasonToken(_ reason: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_.-")
        guard !reason.isEmpty,
              reason.count <= 64,
              reason.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else {
            return "other"
        }
        return reason
    }

    public static func summarize(records: [MCPTerminalRecord], undecodableCount: Int = 0) -> MCPTerminalRecordSummary {
        struct Key: Hashable {
            let layer: MCPTerminalLayer
            let initiator: MCPTerminalInitiator
            let reason: String
        }
        var counts: [Key: Int] = [:]
        for record in records {
            let key = Key(
                layer: record.layer,
                initiator: record.initiator,
                reason: stableReasonToken(record.reason)
            )
            counts[key, default: 0] += 1
        }
        let reasons = counts.map { key, count in
            ReasonCount(layer: key.layer, initiator: key.initiator, reason: key.reason, count: count)
        }.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            if lhs.layer != rhs.layer { return lhs.layer.rawValue < rhs.layer.rawValue }
            if lhs.initiator != rhs.initiator { return lhs.initiator.rawValue < rhs.initiator.rawValue }
            return lhs.reason < rhs.reason
        }
        let timestamps = records.map(\.timestamp)
        return MCPTerminalRecordSummary(
            recordCount: records.count,
            undecodableRecordCount: undecodableCount,
            windowStart: timestamps.min(),
            windowEnd: timestamps.max(),
            reasons: reasons,
            recordsWithActiveRequests: records.count(where: { ($0.bridgeActiveRequestCount ?? 0) > 0 }),
            recordsWithResponseInDelivery: records.count(where: { ($0.bridgeResponseInDeliveryCount ?? 0) > 0 }),
            hostSettledRequestTotal: records.reduce(0) { $0 + max(0, $1.hostSettledRequestCount ?? 0) },
            hostUnsettledRequestTotal: records.reduce(0) { $0 + max(0, $1.hostUnsettledRequestCount ?? 0) },
            recordsWithUnsettledRequests: records.count(where: { ($0.hostUnsettledRequestCount ?? 0) > 0 })
        )
    }

    /// Reads `terminal-*.json` records in `directory`, optionally limited to those at or after
    /// `since`. Unreadable or undecodable files are counted, never surfaced.
    public static func summarize(
        directory: URL,
        since: Date? = nil,
        fileManager: FileManager = .default
    ) -> MCPTerminalRecordSummary {
        let files = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var records: [MCPTerminalRecord] = []
        var undecodable = 0
        for file in files where file.pathExtension == "json" && file.lastPathComponent.hasPrefix("terminal-") {
            guard let data = try? Data(contentsOf: file),
                  let record = try? decoder.decode(MCPTerminalRecord.self, from: data)
            else {
                undecodable += 1
                continue
            }
            if let since, record.timestamp < since { continue }
            records.append(record)
        }
        return summarize(records: records, undecodableCount: undecodable)
    }
}
