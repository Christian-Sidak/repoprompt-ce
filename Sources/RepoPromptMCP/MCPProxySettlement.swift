import Darwin
import Foundation
import RepoPromptShared

// MARK: - Startup budget

/// Bounds how long the app-backed proxy waits for the first accepted bootstrap session.
///
/// Before the first accepted handshake the host's `initialize` sits unread in stdin, so an
/// unbounded retry loop surfaces only as the host's own generic startup timeout. After the first
/// accepted handshake the existing reconnect/replay policy applies unchanged, which preserves
/// transparent resume across app updates and restarts.
struct MCPProxyStartupPolicy: Equatable {
    static let environmentKey = "REPOPROMPT_MCP_STARTUP_TIMEOUT_SECONDS"
    static let defaultBudgetSeconds: TimeInterval = 20
    static let maximumBudgetSeconds: TimeInterval = 3600

    /// `nil` restores the legacy unbounded startup wait.
    let budgetSeconds: TimeInterval?

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MCPProxyStartupPolicy {
        guard let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return MCPProxyStartupPolicy(budgetSeconds: defaultBudgetSeconds)
        }
        guard let seconds = TimeInterval(raw), seconds.isFinite, seconds >= 0 else {
            return MCPProxyStartupPolicy(budgetSeconds: defaultBudgetSeconds)
        }
        if seconds == 0 {
            return MCPProxyStartupPolicy(budgetSeconds: nil)
        }
        return MCPProxyStartupPolicy(budgetSeconds: min(seconds, maximumBudgetSeconds))
    }

    func isExhausted(elapsedSeconds: TimeInterval) -> Bool {
        guard let budgetSeconds else { return false }
        return elapsedSeconds >= budgetSeconds
    }

    /// Caps a retry delay so the budget check runs promptly at expiry.
    func cappedRetryDelay(_ delay: TimeInterval, elapsedSeconds: TimeInterval) -> TimeInterval {
        guard let budgetSeconds else { return delay }
        return max(0, min(delay, budgetSeconds - elapsedSeconds))
    }
}

/// Terminal error raised when no bootstrap session was accepted within the startup budget.
struct MCPProxyStartupBudgetExceeded: Swift.Error, Equatable, LocalizedError {
    static let terminalReason = "startup_budget_exceeded"

    let budgetSeconds: TimeInterval
    /// Stable failure token of the last connection attempt (for example `app_socket_connect_failed`).
    let lastFailureReason: String

    var errorDescription: String? {
        "RepoPrompt CE did not accept the MCP connection within \(Int(budgetSeconds.rounded()))s (last failure: \(lastFailureReason)). Launch RepoPrompt CE with MCP enabled, then reconnect this server. Set \(MCPProxyStartupPolicy.environmentKey) to change the wait (0 waits indefinitely)."
    }
}

// MARK: - Host settlement

/// Synthesizes one JSON-RPC error for every host request the app can no longer answer.
///
/// Settlement never implies success and never replays work: requests that may have reached the
/// app and are not on the transport replay allowlist are reported `indeterminate`.
enum MCPProxyHostSettlement {
    struct Decision: Equatable {
        let code: MCPTransportFailureCode
        let reason: String
    }

    struct Outcome: Equatable {
        let settledRequestCount: Int
        let unsettledRequestCount: Int

        static let none = Outcome(settledRequestCount: 0, unsettledRequestCount: 0)
    }

    static let settlementWriteStallTimeout: TimeInterval = 2
    static let maximumStartupHostInputBytes = 1 << 20

    /// Returns nil when the host's stdout can no longer carry a well-framed response, or when
    /// the host itself is gone.
    static func decision(for error: Swift.Error) -> Decision? {
        if let startup = error as? MCPProxyStartupBudgetExceeded {
            return Decision(code: .appUnavailable, reason: startup.lastFailureReason)
        }
        guard let runtimeError = CLIProxyRuntimePolicy.normalizedTerminalRuntimeError(for: error) else {
            return Decision(code: .transportLost, reason: "proxy_unexpected_error")
        }
        switch runtimeError {
        case .approvalDenied:
            return Decision(code: .connectionRejected, reason: "approval_denied")
        case let .terminatedByServer(provenance):
            return Decision(code: .sessionTerminated, reason: provenance.stableReason)
        case let .hostDisconnected(provenance):
            switch provenance.reason {
            case .stdoutBrokenPipe, .parentProcessChanged, .stdinClosed:
                // stdout is gone, the host is gone, or the bridge drained cleanly.
                return nil
            case .stdinPollFailed, .stdinReadFailed, .taskCancelled:
                return Decision(code: .transportLost, reason: provenance.reason.rawValue)
            }
        case let .connectionFailed(underlying):
            if let startup = underlying as? MCPProxyStartupBudgetExceeded {
                return Decision(code: .appUnavailable, reason: startup.lastFailureReason)
            }
            if let socketError = underlying as? SocketProxyError {
                switch socketError {
                case .stdoutBrokenPipe, .stdoutWriteTimeout, .hostDisconnected:
                    return nil
                case .approvalDenied:
                    return Decision(code: .connectionRejected, reason: "approval_denied")
                default:
                    break
                }
            }
            return Decision(
                code: .transportLost,
                reason: CLIProxyRuntimePolicy.failureReason(for: runtimeError)
            )
        }
    }

    /// Frames for requests the bridge ledger forwarded (or attempted to forward) to the app.
    static func frames(
        for claim: JSONRPCBridgeHostSettlementClaim,
        decision: Decision
    ) -> [Data] {
        claim.requests.compactMap { request in
            MCPTransportSettlementError.classify(
                code: decision.code,
                reason: decision.reason,
                requestState: request.requestState,
                isReplayable: request.isReplayable,
                method: request.method,
                tool: request.tool
            ).jsonRPCFrame(id: request.id)
        }
    }

    /// Frames for host requests that were never read from stdin because no session was ever
    /// accepted. Nothing reached the app, so every answer is retryable.
    static func startupFrames(hostInput: Data, decision: Decision) -> [Data] {
        pendingHostRequests(in: hostInput).compactMap { request in
            MCPTransportSettlementError.classify(
                code: decision.code,
                reason: decision.reason,
                requestState: .notForwarded,
                isReplayable: true,
                method: request.method,
                tool: request.tool
            ).jsonRPCFrame(id: request.id)
        }
    }

    struct PendingHostRequest: Equatable {
        let id: JSONRPCBridgeID
        let method: String
        let tool: String?
    }

    /// Complete newline-delimited JSON-RPC requests in `data`, in order. Notifications,
    /// responses, malformed lines, and a trailing partial line are ignored.
    static func pendingHostRequests(in data: Data) -> [PendingHostRequest] {
        var requests: [PendingHostRequest] = []
        var remainder = data[...]
        while let newline = remainder.firstIndex(of: UInt8(ascii: "\n")) {
            let line = remainder[remainder.startIndex ..< newline]
            remainder = remainder[remainder.index(after: newline)...]
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) else { continue }
            let messages: [[String: Any]] = if let batch = object as? [[String: Any]] {
                batch
            } else if let single = object as? [String: Any] {
                [single]
            } else {
                []
            }
            for message in messages {
                guard let method = message["method"] as? String,
                      let id = JSONRPCBridgeID.parseJSONValue(message["id"]),
                      id != .null
                else { continue }
                let tool = method == "tools/call"
                    ? (message["params"] as? [String: Any])?["name"] as? String
                    : nil
                requests.append(PendingHostRequest(id: id, method: method, tool: tool))
            }
        }
        return requests
    }

    /// Reads whatever the host has already written to `fd` without blocking.
    static func readAvailableHostInput(
        fd: Int32 = STDIN_FILENO,
        maximumBytes: Int = maximumStartupHostInputBytes
    ) -> Data {
        let originalFlags = fcntl(fd, F_GETFL)
        if originalFlags >= 0 {
            _ = fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK)
        }
        defer {
            if originalFlags >= 0 {
                _ = fcntl(fd, F_SETFL, originalFlags)
            }
        }
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while collected.count < maximumBytes {
            let count = buffer.withUnsafeMutableBufferPointer { pointer in
                Darwin.read(fd, pointer.baseAddress!, min(pointer.count, maximumBytes - collected.count))
            }
            if count > 0 {
                collected.append(contentsOf: buffer[0 ..< count])
                continue
            }
            if count < 0, errno == EINTR {
                continue
            }
            break
        }
        return collected
    }

    /// Darwin `FIONREAD`, which Swift does not import because it is the function-like macro
    /// `_IOR('f', 127, int)`: IOC_OUT (0x40000000) | (sizeof(int) & IOCPARM_MASK) << 16 | 'f' << 8 | 127.
    private static let fionreadRequest: UInt = 0x4000_0000
        | (UInt(MemoryLayout<Int32>.size) & 0x1FFF) << 16
        | UInt(UInt8(ascii: "f")) << 8
        | 127

    /// True when the host closed stdin and left no unread bytes, which MCP stdio defines as a
    /// shutdown request.
    static func hostClosedInputWithoutPendingData(fd: Int32 = STDIN_FILENO) -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let result = poll(&descriptor, 1, 0)
        guard result > 0 else { return false }
        let events = Int32(descriptor.revents)
        if events & POLLNVAL != 0 {
            return true
        }
        // Darwin reports a pipe whose writer closed as readable-at-EOF (POLLIN) and does not
        // guarantee POLLHUP, so ask how many bytes are actually pending.
        if events & (POLLIN | POLLHUP) != 0 {
            var pendingBytes: Int32 = 0
            let status = withUnsafeMutablePointer(to: &pendingBytes) { pointer in
                ioctl(fd, fionreadRequest, pointer)
            }
            if status == 0 {
                // Readable or hung up with nothing pending is end of input.
                return pendingBytes == 0
            }
        }
        return events & POLLHUP != 0 && events & POLLIN == 0
    }

    /// Writes frames without honoring task cancellation, bounded per frame by a short stall
    /// timeout. Stops at the first failure so a partial frame is never followed by another.
    static func write(
        _ frames: [Data],
        to fd: Int32 = STDOUT_FILENO,
        stallTimeout: TimeInterval = settlementWriteStallTimeout
    ) async -> Int {
        guard !frames.isEmpty else { return 0 }
        return await Task.detached(priority: .userInitiated) {
            let originalFlags = fcntl(fd, F_GETFL)
            defer {
                if originalFlags >= 0 {
                    _ = fcntl(fd, F_SETFL, originalFlags)
                }
            }
            var written = 0
            for frame in frames {
                do {
                    try NonBlockingFDWriter.writeAll(frame, to: fd, stallTimeout: stallTimeout)
                    written += 1
                } catch {
                    debugLog("MCPProxyHostSettlement: settlement write stopped: \(error)")
                    break
                }
            }
            return written
        }.value
    }

    /// Claims and answers every unanswered host request for a terminal proxy error.
    static func settle(
        error: Swift.Error,
        ledger: JSONRPCBridgeLedger,
        stdinFD: Int32 = STDIN_FILENO,
        stdoutFD: Int32 = STDOUT_FILENO
    ) async -> Outcome {
        guard let decision = decision(for: error) else {
            return .none
        }
        let isStartupFailure = startupBudgetError(in: error) != nil
        let claim = await ledger.claimUnansweredHostRequests(
            terminalReason: isStartupFailure ? MCPProxyStartupBudgetExceeded.terminalReason : decision.reason
        )
        var frames = Self.frames(for: claim, decision: decision)
        if isStartupFailure {
            // No session was ever accepted, so host requests are still unread in stdin.
            frames += startupFrames(hostInput: readAvailableHostInput(fd: stdinFD), decision: decision)
        }
        let written = await write(frames, to: stdoutFD)
        return Outcome(
            settledRequestCount: written,
            unsettledRequestCount: claim.responseInDeliveryCount + (frames.count - written)
        )
    }

    static func startupBudgetError(in error: Swift.Error) -> MCPProxyStartupBudgetExceeded? {
        if let startup = error as? MCPProxyStartupBudgetExceeded {
            return startup
        }
        guard case let .connectionFailed(underlying)? = error as? CLIRuntimeError else { return nil }
        return underlying as? MCPProxyStartupBudgetExceeded
    }
}
