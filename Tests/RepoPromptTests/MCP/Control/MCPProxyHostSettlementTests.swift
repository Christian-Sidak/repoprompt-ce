import Darwin
import Foundation
@testable import RepoPromptMCP
import RepoPromptShared
import XCTest

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}

/// Contract tests for M8A: every host request receives exactly one answer when the app can no
/// longer answer it, settlement never invites a duplicate mutation, and startup is bounded.
final class MCPProxyHostSettlementTests: XCTestCase {
    // MARK: - Ledger claim

    func testLedgerClaimsUnansweredHostRequestsOnceInSubmissionOrder() async throws {
        let ledger = JSONRPCBridgeLedger(connectionID: "settlement-claim")
        _ = try await ledger.beginConnection()

        try await forward(ledger, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"a"}}}"#)
        try await forward(ledger, #"{"jsonrpc":"2.0","id":"two","method":"tools/call","params":{"name":"apply_edits","arguments":{"path":"a"}}}"#)
        // Prepared but never committed: the socket write did not complete.
        _ = try await ledger.prepare(
            frame: line(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"context_builder","arguments":{}}}"#),
            direction: .clientToServer
        )
        // A response for id 4 is being written to the host; it must never be answered again.
        try await forward(ledger, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"git","arguments":{}}}"#)
        _ = try await ledger.prepare(
            frame: line(#"{"jsonrpc":"2.0","id":4,"result":{"content":[]}}"#),
            direction: .serverToClient
        )

        let claim = await ledger.claimUnansweredHostRequests(terminalReason: "app_socket_closed")

        XCTAssertEqual(claim.requests, [
            JSONRPCBridgeUnansweredHostRequest(
                id: .number(1),
                method: "tools/call",
                tool: "read_file",
                isReplayable: true,
                requestState: .forwarded
            ),
            JSONRPCBridgeUnansweredHostRequest(
                id: .string("two"),
                method: "tools/call",
                tool: "apply_edits",
                isReplayable: false,
                requestState: .forwarded
            ),
            JSONRPCBridgeUnansweredHostRequest(
                id: .number(3),
                method: "tools/call",
                tool: "context_builder",
                isReplayable: false,
                requestState: .deliveryUncertain
            )
        ])
        XCTAssertEqual(claim.responseInDeliveryCount, 1)

        let snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.terminalReason, "app_socket_closed")
        XCTAssertEqual(snapshot.pendingTransactionCount, 1, "only the in-delivery response transaction remains")

        let secondClaim = await ledger.claimUnansweredHostRequests(terminalReason: "later")
        XCTAssertEqual(secondClaim.requests, [], "a request is never claimed twice")
        let terminalReason = await ledger.snapshot().terminalReason
        XCTAssertEqual(terminalReason, "app_socket_closed", "the first terminal reason is preserved")
    }

    func testLedgerClaimIgnoresCancelledAndAppOriginatedRequests() async throws {
        let ledger = JSONRPCBridgeLedger(connectionID: "settlement-cancelled")
        _ = try await ledger.beginConnection()
        try await forward(ledger, #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"apply_edits","arguments":{}}}"#)
        try await forward(ledger, #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":9}}"#)
        let appRequest = try await ledger.prepare(
            frame: line(#"{"jsonrpc":"2.0","id":50,"method":"elicitation/create","params":{}}"#),
            direction: .serverToClient
        )
        try await ledger.commit(appRequest)

        let claim = await ledger.claimUnansweredHostRequests(terminalReason: "app_socket_closed")
        XCTAssertEqual(claim.requests, [])
        XCTAssertEqual(claim.responseInDeliveryCount, 0)
    }

    // MARK: - Classification and frames

    func testSettlementFramesNeverReportPossiblyAppliedWorkAsRetryable() throws {
        let claim = JSONRPCBridgeHostSettlementClaim(
            requests: [
                .init(id: .number(1), method: "tools/call", tool: "read_file", isReplayable: true, requestState: .forwarded),
                .init(id: .string("m"), method: "tools/call", tool: "apply_edits", isReplayable: false, requestState: .forwarded),
                .init(id: .number(3), method: "tools/call", tool: "file_actions", isReplayable: false, requestState: .deliveryUncertain),
                .init(id: .null, method: "tools/call", tool: "read_file", isReplayable: true, requestState: .forwarded)
            ],
            responseInDeliveryCount: 0
        )
        let frames = MCPProxyHostSettlement.frames(
            for: claim,
            decision: .init(code: .transportLost, reason: "app_socket_closed")
        )
        XCTAssertEqual(frames.count, 3, "a null id cannot be answered")

        let first = try errorObject(frames[0])
        XCTAssertEqual(first.id as? Int, 1)
        XCTAssertEqual(first.code, MCPTransportSettlementError.jsonRPCErrorCode)
        XCTAssertEqual(first.data["code"] as? String, "transport_lost")
        XCTAssertEqual(first.data["retryability"] as? String, "retryable")
        XCTAssertEqual(first.data["retryable"] as? Bool, true)
        XCTAssertEqual(first.data["request_state"] as? String, "forwarded")
        XCTAssertEqual(first.data["reason"] as? String, "app_socket_closed")
        XCTAssertEqual(first.data["tool"] as? String, "read_file")

        let mutation = try errorObject(frames[1])
        XCTAssertEqual(mutation.id as? String, "m")
        XCTAssertEqual(mutation.data["retryability"] as? String, "indeterminate")
        XCTAssertEqual(mutation.data["retryable"] as? Bool, false)
        XCTAssertTrue(mutation.message.contains("may have been applied"))

        let uncertain = try errorObject(frames[2])
        XCTAssertEqual(uncertain.data["retryability"] as? String, "indeterminate")
        XCTAssertEqual(uncertain.data["request_state"] as? String, "delivery_uncertain")

        for frame in frames {
            XCTAssertEqual(frame.last, UInt8(ascii: "\n"))
            XCTAssertEqual(frame.count(where: { $0 == UInt8(ascii: "\n") }), 1, "one newline-delimited frame")
        }
    }

    func testRejectedConnectionIsPermanentEvenForReplayableRequests() {
        let error = MCPTransportSettlementError.classify(
            code: .connectionRejected,
            reason: "approval_denied",
            requestState: .forwarded,
            isReplayable: true,
            method: "initialize",
            tool: nil
        )
        XCTAssertEqual(error.retryability, .permanent)
        XCTAssertFalse(error.retryability.legacyRetryableFlag)
    }

    func testDecisionSkipsSettlementWhenHostOutputOrHostIsGone() {
        let skipped: [Swift.Error] = [
            CLIRuntimeError.hostDisconnected(.stdoutBrokenPipe(bytesWritten: 3, totalBytes: 9)),
            CLIRuntimeError.hostDisconnected(.parentProcessChanged(initialPPID: 10, currentPPID: 1)),
            CLIRuntimeError.hostDisconnected(.stdinClosed),
            CLIRuntimeError.connectionFailed(underlying: SocketProxyError.stdoutBrokenPipe(bytesWritten: 1, totalBytes: 2)),
            CLIRuntimeError.connectionFailed(underlying: SocketProxyError.stdoutWriteTimeout(
                bytesWritten: 1,
                totalBytes: 2,
                stallTimeout: 30
            ))
        ]
        for error in skipped {
            XCTAssertNil(MCPProxyHostSettlement.decision(for: error), "\(error)")
        }

        XCTAssertEqual(
            MCPProxyHostSettlement.decision(for: CLIRuntimeError.connectionFailed(underlying: SocketProxyError.serverClosed)),
            .init(code: .transportLost, reason: "app_socket_closed")
        )
        XCTAssertEqual(
            MCPProxyHostSettlement.decision(for: CLIRuntimeError.connectionFailed(
                underlying: JSONRPCBridgeLedgerError.terminal("reconnection_attempted_with_unreplayable_work")
            )),
            .init(code: .transportLost, reason: "jsonrpc_bridge_terminal")
        )
        XCTAssertEqual(
            MCPProxyHostSettlement.decision(for: CLIRuntimeError.approvalDenied),
            .init(code: .connectionRejected, reason: "approval_denied")
        )
        XCTAssertEqual(
            MCPProxyHostSettlement.decision(for: CLIRuntimeError.terminatedByServer(
                CLIServerTerminationProvenance(reason: nil, message: nil)
            )),
            .init(code: .sessionTerminated, reason: "terminated_by_server")
        )
        XCTAssertEqual(
            MCPProxyHostSettlement.decision(for: CLIRuntimeError.hostDisconnected(.taskCancelled)),
            .init(code: .transportLost, reason: "host_task_cancelled")
        )
        XCTAssertEqual(
            MCPProxyHostSettlement.decision(for: CLIRuntimeError.connectionFailed(
                underlying: MCPProxyStartupBudgetExceeded(budgetSeconds: 20, lastFailureReason: "app_socket_connect_failed")
            )),
            .init(code: .appUnavailable, reason: "app_socket_connect_failed")
        )
    }

    func testStartupBudgetErrorIsTerminalAndStablyClassified() {
        let error = CLIRuntimeError.connectionFailed(
            underlying: MCPProxyStartupBudgetExceeded(budgetSeconds: 20, lastFailureReason: "handshake_rejected")
        )
        XCTAssertFalse(CLIProxyRuntimePolicy.shouldRetry(after: error))
        XCTAssertEqual(CLIProxyRuntimePolicy.failureReason(for: error), "startup_budget_exceeded")
        XCTAssertEqual(mcpCLIExitCode(for: error), .connectionFailed)
    }

    // MARK: - Startup

    func testStartupPolicyParsesEnvironment() {
        XCTAssertEqual(MCPProxyStartupPolicy.fromEnvironment([:]).budgetSeconds, 20)
        XCTAssertNil(MCPProxyStartupPolicy.fromEnvironment([MCPProxyStartupPolicy.environmentKey: "0"]).budgetSeconds)
        XCTAssertEqual(MCPProxyStartupPolicy.fromEnvironment([MCPProxyStartupPolicy.environmentKey: " 7.5 "]).budgetSeconds, 7.5)
        XCTAssertEqual(MCPProxyStartupPolicy.fromEnvironment([MCPProxyStartupPolicy.environmentKey: "-1"]).budgetSeconds, 20)
        XCTAssertEqual(MCPProxyStartupPolicy.fromEnvironment([MCPProxyStartupPolicy.environmentKey: "abc"]).budgetSeconds, 20)
        XCTAssertEqual(MCPProxyStartupPolicy.fromEnvironment([MCPProxyStartupPolicy.environmentKey: "99999"]).budgetSeconds, 3600)

        let policy = MCPProxyStartupPolicy(budgetSeconds: 10)
        XCTAssertFalse(policy.isExhausted(elapsedSeconds: 9.9))
        XCTAssertTrue(policy.isExhausted(elapsedSeconds: 10))
        XCTAssertEqual(policy.cappedRetryDelay(0.5, elapsedSeconds: 9.8), 0.2, accuracy: 0.0001)
        XCTAssertEqual(policy.cappedRetryDelay(0.5, elapsedSeconds: 12), 0)
        XCTAssertFalse(MCPProxyStartupPolicy(budgetSeconds: nil).isExhausted(elapsedSeconds: 1e9))
    }

    func testStartupFramesAnswerEveryCompletePendingRequest() throws {
        let input = line(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"clientInfo":{"name":"host"}}}"#)
            + line(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
            + line("not json")
            + line(#"[{"jsonrpc":"2.0","id":"t","method":"tools/call","params":{"name":"read_file"}}]"#)
            + Data(#"{"jsonrpc":"2.0","id":5,"method":"tools/list""#.utf8)

        let frames = MCPProxyHostSettlement.startupFrames(
            hostInput: input,
            decision: .init(code: .appUnavailable, reason: "app_socket_connect_failed")
        )
        XCTAssertEqual(frames.count, 2, "notifications, malformed lines, and a partial line are not answered")

        let initialize = try errorObject(frames[0])
        XCTAssertEqual(initialize.id as? Int, 0)
        XCTAssertEqual(initialize.data["code"] as? String, "app_unavailable")
        XCTAssertEqual(initialize.data["retryability"] as? String, "retryable")
        XCTAssertEqual(initialize.data["request_state"] as? String, "not_forwarded")
        XCTAssertEqual(initialize.data["method"] as? String, "initialize")

        let toolCall = try errorObject(frames[1])
        XCTAssertEqual(toolCall.id as? String, "t")
        XCTAssertEqual(toolCall.data["tool"] as? String, "read_file")
    }

    func testHostInputProbesDistinguishPendingDataFromClosedInput() throws {
        let pipe = try makePipe()
        defer {
            Darwin.close(pipe.read)
        }
        XCTAssertFalse(MCPProxyHostSettlement.hostClosedInputWithoutPendingData(fd: pipe.read))

        let payload = line(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        try writeAll(payload, to: pipe.write)
        Darwin.close(pipe.write)
        XCTAssertFalse(
            MCPProxyHostSettlement.hostClosedInputWithoutPendingData(fd: pipe.read),
            "unread host bytes keep startup alive"
        )

        XCTAssertEqual(MCPProxyHostSettlement.readAvailableHostInput(fd: pipe.read), payload)
        XCTAssertTrue(MCPProxyHostSettlement.hostClosedInputWithoutPendingData(fd: pipe.read))
    }

    /// With no app socket, the pre-session budget ends the retry loop and the pending
    /// `initialize` receives a typed `app_unavailable` answer instead of a silent host timeout.
    func testStartupBudgetAnswersInitializeWhenAppSocketIsAbsent() async throws {
        let hostInput = try makePipe()
        let hostOutput = try makePipe()
        defer {
            Darwin.close(hostInput.read)
            Darwin.close(hostInput.write)
            Darwin.close(hostOutput.read)
            Darwin.close(hostOutput.write)
        }
        try writeAll(
            line(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"host"}}}"#),
            to: hostInput.write
        )
        // Short /tmp path keeps the address inside sun_path so the failure is ENOENT.
        let missingSocket = URL(fileURLWithPath: "/tmp/rp-absent-\(UUID().uuidString.prefix(8)).sock")
        let service = MCPService(
            startupPolicy: MCPProxyStartupPolicy(budgetSeconds: 0.2),
            socketURL: missingSocket,
            hostInputFD: hostInput.read,
            hostOutputFD: hostOutput.write
        )

        // The budget is 0.2 s; the bound only turns a stall (for example, the retry path reading
        // an uninitialized entry-file global) into a visible failure.
        let transport = Task { try await service.runTransport() }
        guard let result = await awaitBounded(transport, seconds: 10) else {
            transport.cancel()
            return XCTFail("runTransport did not settle within 10 s of a 0.2 s startup budget")
        }
        let thrown: Swift.Error
        switch result {
        case .success:
            return XCTFail("Expected the startup budget to end the retry loop")
        case let .failure(error):
            thrown = error
        }
        let startup = try XCTUnwrap(MCPProxyHostSettlement.startupBudgetError(in: thrown))
        XCTAssertEqual(startup.lastFailureReason, "app_socket_connect_failed")

        let outcome = await MCPProxyHostSettlement.settle(
            error: thrown,
            ledger: service.ledgerForSettlement,
            stdinFD: hostInput.read,
            stdoutFD: hostOutput.write
        )
        XCTAssertEqual(outcome, .init(settledRequestCount: 1, unsettledRequestCount: 0))

        let frames = readLines(from: hostOutput.read)
        XCTAssertEqual(frames.count, 1)
        let answer = try errorObject(XCTUnwrap(frames.first))
        XCTAssertEqual(answer.id as? Int, 1)
        XCTAssertEqual(answer.data["code"] as? String, "app_unavailable")
        XCTAssertEqual(answer.data["retryability"] as? String, "retryable")
    }

    // MARK: - Bridge chaos

    /// A fake app accepts one mutation and one replayable read, then closes. The mutation makes the
    /// bridge terminal, so each host request receives exactly one typed answer and nothing is replayed.
    func testAppCloseWithUnreplayableWorkSettlesEachHostRequestExactlyOnce() async throws {
        var sockets: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        let proxySocket = sockets[0]
        let appSocket = sockets[1]
        _ = fcntl(proxySocket, F_SETFL, fcntl(proxySocket, F_GETFL) | O_NONBLOCK)
        let hostInput = try makePipe()
        let hostOutput = try makePipe()
        defer {
            Darwin.close(proxySocket)
            Darwin.close(hostInput.read)
            Darwin.close(hostInput.write)
            Darwin.close(hostOutput.read)
            Darwin.close(hostOutput.write)
        }

        let ledger = JSONRPCBridgeLedger(connectionID: "settlement-chaos")
        _ = try await ledger.beginConnection()
        let bridge = Task {
            try await BootstrapSocketProxy.runBridge(
                socketFD: proxySocket,
                stdinFD: hostInput.read,
                stdoutFD: hostOutput.write,
                identityCache: ClientIdentityCache(),
                bridgeLedger: ledger,
                faultRule: nil
            )
        }

        try writeAll(
            line(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"apply_edits","arguments":{"path":"a"}}}"#)
                + line(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"a"}}}"#),
            to: hostInput.write
        )
        let received = readLines(from: appSocket, count: 2, timeoutMilliseconds: 10000)
        XCTAssertEqual(received.count, 2, "the fake app received both host requests")
        Darwin.close(appSocket)

        let bridgeError: Swift.Error
        do {
            try await bridge.value
            return XCTFail("Expected app closure to end the bridge")
        } catch {
            bridgeError = error
        }
        let runtimeError = CLIRuntimeError.connectionFailed(underlying: bridgeError)
        let protocolActive = await ledger.recordConnectionFailure(CLIProxyRuntimePolicy.failureReason(for: runtimeError))
        XCTAssertTrue(protocolActive, "unreplayable work forbids reconnect")

        let outcome = await MCPProxyHostSettlement.settle(
            error: runtimeError,
            ledger: ledger,
            stdinFD: hostInput.read,
            stdoutFD: hostOutput.write
        )
        XCTAssertEqual(outcome, .init(settledRequestCount: 2, unsettledRequestCount: 0))

        let answers = try readLines(from: hostOutput.read).map(errorObject)
        XCTAssertEqual(answers.map { $0.id as? Int }, [7, 8])
        XCTAssertEqual(answers[0].data["retryability"] as? String, "indeterminate")
        XCTAssertEqual(answers[0].data["tool"] as? String, "apply_edits")
        XCTAssertEqual(answers[1].data["retryability"] as? String, "retryable")

        let repeated = await MCPProxyHostSettlement.settle(
            error: runtimeError,
            ledger: ledger,
            stdinFD: hostInput.read,
            stdoutFD: hostOutput.write
        )
        XCTAssertEqual(repeated.settledRequestCount, 0, "settlement is idempotent")
        XCTAssertEqual(readLines(from: hostOutput.read), [])
    }

    func testReplayableOnlyConnectionLossStillReconnectsWithoutSettlement() async throws {
        let ledger = JSONRPCBridgeLedger(connectionID: "settlement-replayable")
        _ = try await ledger.beginConnection()
        try await forward(ledger, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"a"}}}"#)

        let protocolActive = await ledger.recordConnectionFailure("app_socket_closed")
        XCTAssertFalse(protocolActive)
        let generation = try await ledger.beginConnection()
        XCTAssertEqual(generation, 2)
        let snapshot = await ledger.snapshot()
        XCTAssertEqual(snapshot.activeRequestCount, 1, "the replayable request stays owned by replay")
        XCTAssertNil(snapshot.terminalReason)
    }

    // MARK: - Terminal record

    func testTerminalRecordCarriesSettlementCountsAndDecodesLegacyRecords() async throws {
        let bridge = JSONRPCBridgeLedger(connectionID: "settlement-record")
        _ = try await bridge.beginConnection()
        let ledger = await bridge.snapshot()
        let record = CLIProxyRuntimePolicy.makeTerminalRecord(
            sessionToken: "token",
            localPID: 1,
            initialParentPID: 2,
            ledgerSnapshot: ledger,
            runtimeError: .connectionFailed(underlying: SocketProxyError.serverClosed),
            fallbackReason: "fallback",
            hostSettlement: .init(settledRequestCount: 3, unsettledRequestCount: 1)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(record)) as? [String: Any])
        XCTAssertEqual(object["host_settled_request_count"] as? Int, 3)
        XCTAssertEqual(object["host_unsettled_request_count"] as? Int, 1)

        var legacy = object
        legacy.removeValue(forKey: "host_settled_request_count")
        legacy.removeValue(forKey: "host_unsettled_request_count")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            MCPTerminalRecord.self,
            from: JSONSerialization.data(withJSONObject: legacy)
        )
        XCTAssertNil(decoded.hostSettledRequestCount)
        XCTAssertEqual(decoded.reason, record.reason)
    }

    // MARK: - Helpers

    private struct ErrorObject {
        let id: Any?
        let code: Int
        let message: String
        let data: [String: Any]
    }

    private func errorObject(_ frame: Data) throws -> ErrorObject {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: frame) as? [String: Any])
        XCTAssertEqual(object["jsonrpc"] as? String, "2.0")
        XCTAssertNil(object["result"])
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        return try ErrorObject(
            id: object["id"],
            code: XCTUnwrap(error["code"] as? Int),
            message: XCTUnwrap(error["message"] as? String),
            data: XCTUnwrap(error["data"] as? [String: Any])
        )
    }

    /// Waits for `task` without structured-concurrency joins, so an uncooperative task cannot
    /// extend the wait past `seconds`. Returns nil on timeout.
    private func awaitBounded<T: Sendable>(
        _ task: Task<T, Swift.Error>,
        seconds: Double
    ) async -> Result<T, Swift.Error>? {
        let claim = ResumeOnce()
        return await withCheckedContinuation { continuation in
            Task {
                let result = await task.result
                if claim.claim() {
                    continuation.resume(returning: result)
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if claim.claim() {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func forward(_ ledger: JSONRPCBridgeLedger, _ json: String) async throws {
        let prepared = try await ledger.prepare(frame: line(json), direction: .clientToServer)
        try await ledger.commit(prepared)
    }

    private func line(_ string: String) -> Data {
        Data((string + "\n").utf8)
    }

    private func makePipe() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return (fds[0], fds[1])
    }

    private func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                offset += written
            }
        }
    }

    /// Reads complete lines. Without `count`, returns what is already available; with `count`,
    /// waits (bounded) until that many lines arrive or the peer closes.
    private func readLines(
        from fd: Int32,
        count: Int? = nil,
        timeoutMilliseconds: Int32 = 0
    ) -> [Data] {
        var collected = Data()
        var lines: [Data] = []
        let deadline = ProcessInfo.processInfo.systemUptime + Double(timeoutMilliseconds) / 1000
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remaining = max(0, Int32((deadline - ProcessInfo.processInfo.systemUptime) * 1000))
            let ready = poll(&descriptor, 1, count == nil ? 0 : min(remaining, 250))
            if ready > 0, descriptor.revents & Int16(POLLIN) != 0 {
                let read = buffer.withUnsafeMutableBufferPointer { Darwin.read(fd, $0.baseAddress!, $0.count) }
                if read > 0 {
                    collected.append(contentsOf: buffer[0 ..< read])
                    while let newline = collected.firstIndex(of: UInt8(ascii: "\n")) {
                        lines.append(Data(collected[collected.startIndex ... newline]))
                        collected = Data(collected[collected.index(after: newline)...])
                    }
                    if let count, lines.count >= count {
                        return lines
                    }
                    continue
                }
                return lines
            }
            guard let count, lines.count < count, ProcessInfo.processInfo.systemUptime < deadline else {
                return lines
            }
        }
    }
}
