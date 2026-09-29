import Foundation
import MCP

// Contracts for bounded, host-neutral Context Builder discovery (M17).
//
// A discovery run freezes the bound context once, lets a provider explore it through a fixed
// read-only tool set plus a staged (in-memory) selection, and ends with a validated selection, a
// canonical frozen context pack, and one compare-and-set selection commit against the frozen
// revisions. Nothing is written to the context before that commit, and nothing at all when any
// step fails.

/// The bound context as captured once when a discovery invocation starts.
package struct ContextBuilderDiscoverySnapshot: Equatable, Sendable {
    package let identity: DomainContextIdentity
    /// Revisions the selection commit is conditioned on.
    package let workspaceRevision: UInt64
    package let contextRevision: UInt64
    /// Physical roots every discovery read is served from (worktree overlays already applied).
    package let roots: [URL]
    package let prompt: String
    /// The context's selection at freeze time. Discovery does not start from it; a successful run
    /// replaces it.
    package let selection: [String]

    package init(
        identity: DomainContextIdentity,
        workspaceRevision: UInt64,
        contextRevision: UInt64,
        roots: [URL],
        prompt: String,
        selection: [String]
    ) {
        self.identity = identity
        self.workspaceRevision = workspaceRevision
        self.contextRevision = contextRevision
        self.roots = roots
        self.prompt = prompt
        self.selection = selection
    }
}

/// Every bound a discovery run enforces. Exceeding one fails the run closed.
package struct ContextBuilderDiscoveryLimits: Equatable, Sendable {
    /// Provider replies per run, including malformed ones.
    package var maximumTurns: Int
    package var maximumToolCallsPerTurn: Int
    /// Malformed replies tolerated (each one is answered with a protocol error) before the run fails.
    package var maximumMalformedReplies: Int
    package var maximumSelectedFiles: Int
    /// Characters of one tool result kept in the transcript.
    package var maximumToolResultCharacters: Int
    /// Characters of one provider reply kept in the transcript.
    package var maximumReplyTranscriptCharacters: Int
    /// Characters of one rendered provider prompt; older tool results are elided to stay within it.
    package var maximumPromptCharacters: Int
    /// UTF-8 bytes of the canonical frozen pack.
    package var maximumPackBytes: Int
    /// Wall-clock bound on the exploration phase (provider turns and tool calls). Validation, pack
    /// rendering, and the commit are bounded by the file limits instead, so a timeout can never
    /// interrupt a commit.
    package var maximumDuration: Duration

    package static let `default` = ContextBuilderDiscoveryLimits(
        maximumTurns: 12,
        maximumToolCallsPerTurn: 8,
        maximumMalformedReplies: 2,
        maximumSelectedFiles: 48,
        maximumToolResultCharacters: 16000,
        maximumReplyTranscriptCharacters: 4000,
        maximumPromptCharacters: 240_000,
        maximumPackBytes: 1_500_000,
        maximumDuration: .seconds(900)
    )

    package init(
        maximumTurns: Int,
        maximumToolCallsPerTurn: Int,
        maximumMalformedReplies: Int,
        maximumSelectedFiles: Int,
        maximumToolResultCharacters: Int,
        maximumReplyTranscriptCharacters: Int,
        maximumPromptCharacters: Int,
        maximumPackBytes: Int,
        maximumDuration: Duration
    ) {
        self.maximumTurns = max(1, maximumTurns)
        self.maximumToolCallsPerTurn = max(1, maximumToolCallsPerTurn)
        self.maximumMalformedReplies = max(0, maximumMalformedReplies)
        self.maximumSelectedFiles = max(1, maximumSelectedFiles)
        self.maximumToolResultCharacters = max(256, maximumToolResultCharacters)
        self.maximumReplyTranscriptCharacters = max(256, maximumReplyTranscriptCharacters)
        self.maximumPromptCharacters = max(1024, maximumPromptCharacters)
        self.maximumPackBytes = max(1, maximumPackBytes)
        self.maximumDuration = maximumDuration
    }
}

/// Typed discovery failures. Each description leads with its stable code, like the other
/// Context Builder refusals (`context_pack_required: …`).
package enum ContextBuilderDiscoveryError: Error, Equatable, LocalizedError {
    case emptyInstructions
    case providerFailed(String)
    case protocolViolation(String)
    case turnLimitExceeded(Int)
    case timedOut(Duration)
    case promptBudgetExceeded(characters: Int, limit: Int)
    case emptySelection
    case selectionLimitExceeded(count: Int, limit: Int)
    case invalidSelectedPath(path: String, reason: String)
    case packBudgetExceeded(bytes: Int, limit: Int)
    /// The bound context, its roots, or its revisions changed after the snapshot was frozen.
    case contextChanged(String)
    /// The frozen discovery workspace refused a write (it is read-only by construction).
    case readOnlyWorkspace

    package var code: String {
        switch self {
        case .emptyInstructions: "discovery_instructions_required"
        case .providerFailed: "discovery_provider_failed"
        case .protocolViolation: "discovery_protocol_violation"
        case .turnLimitExceeded: "discovery_turn_limit"
        case .timedOut: "discovery_timed_out"
        case .promptBudgetExceeded: "discovery_prompt_budget_exceeded"
        case .emptySelection: "discovery_empty_selection"
        case .selectionLimitExceeded: "discovery_selection_limit"
        case .invalidSelectedPath: "discovery_selection_invalid"
        case .packBudgetExceeded: "discovery_pack_budget_exceeded"
        case .contextChanged: "discovery_context_changed"
        case .readOnlyWorkspace: "discovery_workspace_read_only"
        }
    }

    /// Whether the same request may succeed when retried unchanged.
    package var isRetryable: Bool {
        switch self {
        case .providerFailed, .timedOut, .contextChanged, .protocolViolation, .turnLimitExceeded:
            true
        case .emptyInstructions, .promptBudgetExceeded, .emptySelection, .selectionLimitExceeded,
             .invalidSelectedPath, .packBudgetExceeded, .readOnlyWorkspace:
            false
        }
    }

    package var errorDescription: String? {
        let detail = switch self {
        case .emptyInstructions:
            "Context Builder discovery requires non-empty instructions."
        case let .providerFailed(message):
            "The discovery provider failed: \(message)"
        case let .protocolViolation(reason):
            "The discovery provider did not follow the reply protocol: \(reason)"
        case let .turnLimitExceeded(limit):
            "Discovery did not finish within \(limit) provider replies."
        case let .timedOut(duration):
            "Discovery did not finish within \(duration)."
        case let .promptBudgetExceeded(characters, limit):
            "The discovery prompt needs \(characters) characters, above the \(limit)-character budget."
        case .emptySelection:
            "Discovery finished without selecting any file."
        case let .selectionLimitExceeded(count, limit):
            "Discovery selected \(count) files, above the \(limit)-file limit."
        case let .invalidSelectedPath(path, reason):
            "Discovery selected '\(path)', which is not an admissible workspace file (\(reason))."
        case let .packBudgetExceeded(bytes, limit):
            "The frozen context pack needs \(bytes) bytes, above the \(limit)-byte budget."
        case let .contextChanged(reason):
            "The bound context changed during discovery (\(reason)); no selection was written."
        case .readOnlyWorkspace:
            "The frozen discovery workspace is read-only."
        }
        return "\(code): \(detail)"
    }
}

/// One provider completion per discovery turn. The prompt carries the whole protocol and
/// transcript, so a stateless one-shot provider is sufficient.
package protocol ContextBuilderDiscoveryProvider: Sendable {
    func complete(prompt: String, turn: Int) async throws -> String
}

package struct ContextBuilderDiscoveryCommitReceipt: Equatable, Sendable {
    /// False when the context already held exactly the discovered selection.
    package let applied: Bool
    package let workspaceRevision: UInt64
    package let contextRevision: UInt64

    package init(applied: Bool, workspaceRevision: UInt64, contextRevision: UInt64) {
        self.applied = applied
        self.workspaceRevision = workspaceRevision
        self.contextRevision = contextRevision
    }
}

/// Host-owned compare-and-set commit of the discovered selection. An implementation must write
/// only when the bound context is still exactly `snapshot` (identity, roots, workspace and context
/// revisions) and throw `ContextBuilderDiscoveryError.contextChanged` otherwise.
package protocol ContextBuilderDiscoveryCommitter: Sendable {
    func commitSelection(
        _ absolutePaths: [String],
        over snapshot: ContextBuilderDiscoverySnapshot
    ) async throws -> ContextBuilderDiscoveryCommitReceipt
}

package struct ContextBuilderDiscoveryRequest: Equatable, Sendable {
    package let instructions: String
    package let mode: OracleMode

    package init(instructions: String, mode: OracleMode) {
        self.instructions = instructions
        self.mode = mode
    }
}

/// A committed discovery result.
package struct ContextBuilderDiscoveryOutcome: Sendable {
    /// The frozen context the selection was committed to.
    package let context: DomainContextIdentity
    /// The frozen physical roots the pack was built from and the commit was made over (the commit
    /// refuses when the context's roots are no longer these).
    package let roots: [URL]
    /// Committed selection: absolute paths under the frozen physical roots, in selection order.
    package let selection: [String]
    /// Root-relative display paths (root-labeled when there are several roots), in the same order.
    package let displayPaths: [String]
    /// Clarified task prompt (the instructions when the provider supplied none).
    package let prompt: String
    package let pack: OracleFrozenContextPack
    package let packReference: OracleFrozenPackReference
    package let packBytes: Int
    package let turns: Int
    package let toolCalls: Int
    package let refusedToolCalls: Int
    package let receipt: ContextBuilderDiscoveryCommitReceipt

    /// The Oracle input for this pack, identical to what a `context_pack_ref` resolves to.
    package func oracleInput() throws -> OracleInput {
        try OracleInput(
            mode: pack.mode,
            userMessage: pack.content,
            context: OracleContextEnvelope(
                content: .durableArtifact(id: packReference.artifactID),
                sha256: packReference.artifactID,
                provenance: pack.provenance
            )
        )
    }
}

package struct ContextBuilderDiscoveryToolCall: Equatable, Sendable {
    package let tool: String
    package let arguments: [String: Value]

    package init(tool: String, arguments: [String: Value]) {
        self.tool = tool
        self.arguments = arguments
    }
}

/// The provider's reply: exactly one JSON object, either tool calls or a final answer.
package enum ContextBuilderDiscoveryReply: Equatable, Sendable {
    case toolCalls([ContextBuilderDiscoveryToolCall])
    case final(selectedPaths: [String]?, prompt: String?)

    package struct ParseFailure: Error, Equatable {
        package let reason: String
    }

    /// Parses the first JSON object in `text` that carries `tool_calls` or `final`. Code fences and
    /// surrounding prose are tolerated; anything else is a `ParseFailure`.
    package static func parse(_ text: String, maximumToolCalls: Int) -> Result<Self, ParseFailure> {
        guard let object = firstProtocolObject(in: text) else {
            return .failure(ParseFailure(reason: "no JSON object with \"tool_calls\" or \"final\" was found"))
        }
        let hasCalls = object["tool_calls"] != nil
        let hasFinal = object["final"] != nil
        guard hasCalls != hasFinal else {
            return .failure(ParseFailure(reason: "a reply must contain exactly one of \"tool_calls\" or \"final\""))
        }
        if hasFinal {
            guard case let .object(final)? = object["final"] else {
                return .failure(ParseFailure(reason: "\"final\" must be an object"))
            }
            var selectedPaths: [String]?
            if let raw = final["selected_paths"], raw != .null {
                guard case let .array(items) = raw else {
                    return .failure(ParseFailure(reason: "\"final.selected_paths\" must be an array of strings"))
                }
                var paths: [String] = []
                for item in items {
                    guard case let .string(path) = item else {
                        return .failure(ParseFailure(reason: "\"final.selected_paths\" must be an array of strings"))
                    }
                    paths.append(path)
                }
                selectedPaths = paths
            }
            var prompt: String?
            if let raw = final["prompt"], raw != .null {
                guard case let .string(value) = raw else {
                    return .failure(ParseFailure(reason: "\"final.prompt\" must be a string"))
                }
                prompt = value
            }
            return .success(.final(selectedPaths: selectedPaths, prompt: prompt))
        }
        guard case let .array(items)? = object["tool_calls"], !items.isEmpty else {
            return .failure(ParseFailure(reason: "\"tool_calls\" must be a non-empty array"))
        }
        guard items.count <= maximumToolCalls else {
            return .failure(ParseFailure(
                reason: "\(items.count) tool calls exceed the \(maximumToolCalls)-call limit per reply"
            ))
        }
        var calls: [ContextBuilderDiscoveryToolCall] = []
        for item in items {
            guard case let .object(call) = item,
                  case let .string(tool)? = call["tool"],
                  !tool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return .failure(ParseFailure(reason: "each tool call needs a string \"tool\""))
            }
            var arguments: [String: Value] = [:]
            if let raw = call["arguments"], raw != .null {
                guard case let .object(object) = raw else {
                    return .failure(ParseFailure(reason: "tool call \"arguments\" must be an object"))
                }
                arguments = object
            }
            calls.append(ContextBuilderDiscoveryToolCall(
                tool: tool.trimmingCharacters(in: .whitespacesAndNewlines),
                arguments: arguments
            ))
        }
        return .success(.toolCalls(calls))
    }

    /// Scans balanced top-level `{…}` spans (string- and escape-aware) in order and returns the
    /// first that decodes to an object with a protocol key.
    private static func firstProtocolObject(in text: String) -> [String: Value]? {
        let bytes = Array(text.utf8)
        var start: Int?
        var depth = 0
        var inString = false
        var escaped = false
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
            } else if byte == UInt8(ascii: "\"") {
                if depth > 0 { inString = true }
            } else if byte == UInt8(ascii: "{") {
                if depth == 0 { start = index }
                depth += 1
            } else if byte == UInt8(ascii: "}"), depth > 0 {
                depth -= 1
                if depth == 0, let spanStart = start {
                    let data = Data(bytes[spanStart ... index])
                    if case let .object(object)? = try? JSONDecoder().decode(Value.self, from: data),
                       object["tool_calls"] != nil || object["final"] != nil
                    {
                        return object
                    }
                    start = nil
                }
            }
            index += 1
        }
        return nil
    }
}
