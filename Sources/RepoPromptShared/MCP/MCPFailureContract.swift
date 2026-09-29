import Foundation

/// Consumer-facing retry guidance shared by every MCP composition.
///
/// The value describes the *request*, not the session: it tells a host whether issuing the
/// same request again is safe once a server is available.
public enum MCPFailureRetryability: String, Codable, Equatable, Sendable, CaseIterable {
    /// No side effect can have committed; the same request may be issued again.
    case retryable
    /// Retrying is safe after the accompanying `retry_after_ms` delay.
    case retryAfter = "retry_after"
    /// The request may have reached its handler and may have committed. Inspect state
    /// before issuing another mutation; never replay blindly.
    case indeterminate
    /// Retrying the same request is expected to fail the same way.
    case permanent

    /// Compatibility projection for existing `retryable: Bool` metadata consumers.
    public var legacyRetryableFlag: Bool {
        switch self {
        case .retryable, .retryAfter:
            true
        case .indeterminate, .permanent:
            false
        }
    }
}

/// Stable transport-level failure codes synthesized by `repoprompt-mcp` when the app
/// cannot answer a host request.
public enum MCPTransportFailureCode: String, Codable, Equatable, Sendable, CaseIterable {
    /// The app never accepted a bootstrap session within the startup budget.
    case appUnavailable = "app_unavailable"
    /// The app connection ended while the request was outstanding.
    case transportLost = "transport_lost"
    /// The app explicitly terminated this helper session.
    case sessionTerminated = "session_terminated"
    /// The app or user refused the connection.
    case connectionRejected = "connection_rejected"
}

/// Where a synthesized request stood when the transport ended.
public enum MCPTransportRequestState: String, Codable, Equatable, Sendable {
    /// The request never left the helper.
    case notForwarded = "not_forwarded"
    /// The request was fully written to the app socket and no response was delivered.
    case forwarded
    /// The request write to the app socket did not complete; delivery is unknown.
    case deliveryUncertain = "delivery_uncertain"
}

/// A JSON-RPC error answer synthesized for one host request that the app can no longer answer.
public struct MCPTransportSettlementError: Equatable, Sendable {
    /// JSON-RPC implementation-defined server error. MCP SDKs use this value for a closed
    /// connection, so hosts already treat it as a transport-class failure.
    public static let jsonRPCErrorCode = -32000

    public let code: MCPTransportFailureCode
    public let retryability: MCPFailureRetryability
    public let requestState: MCPTransportRequestState
    /// Stable, privacy-safe cause token (for example `app_socket_closed`).
    public let reason: String
    public let method: String?
    public let tool: String?
    public let retryAfterMilliseconds: Int?

    public init(
        code: MCPTransportFailureCode,
        retryability: MCPFailureRetryability,
        requestState: MCPTransportRequestState,
        reason: String,
        method: String?,
        tool: String?,
        retryAfterMilliseconds: Int? = nil
    ) {
        self.code = code
        self.retryability = retryability
        self.requestState = requestState
        self.reason = reason
        self.method = method
        self.tool = tool
        self.retryAfterMilliseconds = retryAfterMilliseconds
    }

    /// Classifies a request the app can no longer answer. Only requests on the transport
    /// replay allowlist are ever reported retryable; everything else that may have reached
    /// the app is indeterminate, so settlement can never invite a duplicate mutation.
    public static func classify(
        code: MCPTransportFailureCode,
        reason: String,
        requestState: MCPTransportRequestState,
        isReplayable: Bool,
        method: String?,
        tool: String?
    ) -> MCPTransportSettlementError {
        let retryability: MCPFailureRetryability = if code == .connectionRejected {
            .permanent
        } else if requestState == .notForwarded || isReplayable {
            .retryable
        } else {
            .indeterminate
        }
        return MCPTransportSettlementError(
            code: code,
            retryability: retryability,
            requestState: requestState,
            reason: reason,
            method: method,
            tool: tool
        )
    }

    public var message: String {
        let subject = tool.map { "RepoPrompt tool '\($0)'" } ?? "RepoPrompt request"
        let cause = switch code {
        case .appUnavailable:
            "RepoPrompt CE is not running or did not accept the MCP connection in time. Launch RepoPrompt CE (with MCP enabled) and reconnect this server."
        case .transportLost:
            "The connection to RepoPrompt CE ended before \(subject) completed."
        case .sessionTerminated:
            "RepoPrompt CE terminated this MCP session before \(subject) completed."
        case .connectionRejected:
            "RepoPrompt CE rejected this MCP connection."
        }
        let guidance = switch retryability {
        case .retryable, .retryAfter:
            " The request had no side effects and can be retried once the server is available."
        case .indeterminate:
            " The request may have been applied; inspect the current state before retrying."
        case .permanent:
            ""
        }
        return cause + guidance
    }

    public var dataObject: [String: Any] {
        var data: [String: Any] = [
            "code": code.rawValue,
            "retryability": retryability.rawValue,
            "retryable": retryability.legacyRetryableFlag,
            "request_state": requestState.rawValue,
            "reason": reason,
            "server": "repoprompt-ce"
        ]
        if let method { data["method"] = method }
        if let tool { data["tool"] = tool }
        if let retryAfterMilliseconds { data["retry_after_ms"] = retryAfterMilliseconds }
        return data
    }

    /// Newline-terminated JSON-RPC error response for `id`, or nil for a null id, which
    /// JSON-RPC does not allow a server to answer.
    public func jsonRPCFrame(id: JSONRPCBridgeID) -> Data? {
        let idValue: Any
        switch id {
        case let .number(value):
            idValue = value
        case let .string(value):
            idValue = value
        case .null:
            return nil
        }
        let object: [String: Any] = [
            "jsonrpc": "2.0",
            "id": idValue,
            "error": [
                "code": Self.jsonRPCErrorCode,
                "message": message,
                "data": dataObject
            ] as [String: Any]
        ]
        guard var data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else {
            return nil
        }
        data.append(UInt8(ascii: "\n"))
        return data
    }
}
