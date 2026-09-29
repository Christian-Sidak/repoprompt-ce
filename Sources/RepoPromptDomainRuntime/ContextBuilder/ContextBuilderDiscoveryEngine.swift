import Foundation
import MCP

/// Bounded Context Builder discovery over a frozen workspace.
///
/// Order of a run, each step failing closed:
/// 1. Exploration, under `maximumDuration`: at most `maximumTurns` provider replies. Each reply is
///    one JSON object with read-only tool calls or a final answer. Read tools run against the frozen
///    snapshot; `manage_selection` edits an in-memory staged selection; any other tool name is
///    refused without being executed.
/// 2. Validation: the frozen roots are rechecked and every selected path is admitted again.
/// 3. Pack: the selected files are read through the contained read walk and rendered into one
///    canonical `OracleFrozenContextPack` within `maximumPackBytes`, then stored content-addressed.
/// 4. Commit: the host committer writes the selection only if the bound context is still exactly
///    the frozen one.
///
/// No step before the commit writes to the context. A failure after the pack is stored and before
/// or during the commit leaves at most one unreferenced content-addressed pack artifact.
package struct ContextBuilderDiscoveryEngine: Sendable {
    package typealias Sleep = @Sendable (Duration) async throws -> Void

    package let limits: ContextBuilderDiscoveryLimits
    private let sleep: Sleep

    package init(
        limits: ContextBuilderDiscoveryLimits = .default,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.limits = limits
        self.sleep = sleep
    }

    package func run(
        _ request: ContextBuilderDiscoveryRequest,
        workspace: ContextBuilderFrozenWorkspace,
        provider: any ContextBuilderDiscoveryProvider,
        committer: any ContextBuilderDiscoveryCommitter,
        packStore: any OracleArtifactStore
    ) async throws -> ContextBuilderDiscoveryOutcome {
        let instructions = request.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instructions.isEmpty else { throw ContextBuilderDiscoveryError.emptyInstructions }
        try Task.checkCancellation()
        let skipSymlinks = await workspace.skipsSymlinks()
        let decision = try await exploreWithinDeadline(
            instructions: instructions,
            workspace: workspace,
            provider: provider,
            skipSymlinks: skipSymlinks
        )
        return try await finalize(
            decision,
            mode: request.mode,
            instructions: instructions,
            workspace: workspace,
            skipSymlinks: skipSymlinks,
            committer: committer,
            packStore: packStore
        )
    }

    // MARK: - Exploration

    struct Decision: Sendable {
        let selection: [ContextBuilderDiscoveryAuthorizedPath]
        let prompt: String
        let turns: Int
        let toolCalls: Int
        let refusedToolCalls: Int
    }

    struct TurnRecord: Sendable {
        let number: Int
        let reply: String
        var results: [ToolResultRecord]
    }

    struct ToolResultRecord: Sendable {
        enum Status: String, Sendable {
            case ok
            case error
            case refused
            case protocolError = "protocol_error"
        }

        let tool: String
        let status: Status
        let body: String
    }

    private func exploreWithinDeadline(
        instructions: String,
        workspace: ContextBuilderFrozenWorkspace,
        provider: any ContextBuilderDiscoveryProvider,
        skipSymlinks: Bool
    ) async throws -> Decision {
        let limits = limits
        let sleep = sleep
        return try await withThrowingTaskGroup(of: Decision?.self) { group in
            group.addTask {
                try await Self.explore(
                    instructions: instructions,
                    workspace: workspace,
                    provider: provider,
                    skipSymlinks: skipSymlinks,
                    limits: limits
                )
            }
            group.addTask {
                try await sleep(limits.maximumDuration)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            guard let decision = first else {
                throw ContextBuilderDiscoveryError.timedOut(limits.maximumDuration)
            }
            return decision
        }
    }

    private static func explore(
        instructions: String,
        workspace: ContextBuilderFrozenWorkspace,
        provider: any ContextBuilderDiscoveryProvider,
        skipSymlinks: Bool,
        limits: ContextBuilderDiscoveryLimits
    ) async throws -> Decision {
        var transcript: [TurnRecord] = []
        var staged: [ContextBuilderDiscoveryAuthorizedPath] = []
        var malformedReplies = 0
        var toolCalls = 0
        var refusedToolCalls = 0

        for turn in 1 ... limits.maximumTurns {
            try Task.checkCancellation()
            let prompt = try ContextBuilderDiscoveryPrompt.render(
                instructions: instructions,
                workspace: workspace,
                staged: staged,
                transcript: transcript,
                turn: turn,
                limits: limits
            )
            let reply: String
            do {
                reply = try await provider.complete(prompt: prompt, turn: turn)
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                throw ContextBuilderDiscoveryError.providerFailed(Self.describe(error))
            }
            try Task.checkCancellation()
            let recordedReply = Self.truncate(reply, limit: limits.maximumReplyTranscriptCharacters)

            switch ContextBuilderDiscoveryReply.parse(reply, maximumToolCalls: limits.maximumToolCallsPerTurn) {
            case let .failure(failure):
                malformedReplies += 1
                guard malformedReplies <= limits.maximumMalformedReplies else {
                    throw ContextBuilderDiscoveryError.protocolViolation(failure.reason)
                }
                transcript.append(TurnRecord(
                    number: turn,
                    reply: recordedReply,
                    results: [ToolResultRecord(
                        tool: "protocol",
                        status: .protocolError,
                        body: "\(failure.reason). Reply with exactly one JSON object as the protocol describes."
                    )]
                ))

            case let .success(.toolCalls(calls)):
                var record = TurnRecord(number: turn, reply: recordedReply, results: [])
                for call in calls {
                    try Task.checkCancellation()
                    toolCalls += 1
                    let result = try await execute(
                        call,
                        staged: &staged,
                        workspace: workspace,
                        skipSymlinks: skipSymlinks,
                        limits: limits
                    )
                    if result.status == .refused { refusedToolCalls += 1 }
                    record.results.append(result)
                }
                transcript.append(record)

            case let .success(.final(selectedPaths, clarifiedPrompt)):
                let selection: [ContextBuilderDiscoveryAuthorizedPath]
                if let selectedPaths {
                    var admitted: [ContextBuilderDiscoveryAuthorizedPath] = []
                    for rawPath in selectedPaths {
                        let path = try workspace.authorize(rawPath, skipSymlinks: skipSymlinks)
                        if !admitted.contains(where: { $0.absolutePath == path.absolutePath }) {
                            admitted.append(path)
                        }
                    }
                    selection = admitted
                } else {
                    selection = staged
                }
                guard !selection.isEmpty else { throw ContextBuilderDiscoveryError.emptySelection }
                guard selection.count <= limits.maximumSelectedFiles else {
                    throw ContextBuilderDiscoveryError.selectionLimitExceeded(
                        count: selection.count,
                        limit: limits.maximumSelectedFiles
                    )
                }
                let prompt = clarifiedPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return Decision(
                    selection: selection,
                    prompt: prompt.isEmpty ? instructions : prompt,
                    turns: turn,
                    toolCalls: toolCalls,
                    refusedToolCalls: refusedToolCalls
                )
            }
        }
        throw ContextBuilderDiscoveryError.turnLimitExceeded(limits.maximumTurns)
    }

    private static func execute(
        _ call: ContextBuilderDiscoveryToolCall,
        staged: inout [ContextBuilderDiscoveryAuthorizedPath],
        workspace: ContextBuilderFrozenWorkspace,
        skipSymlinks: Bool,
        limits: ContextBuilderDiscoveryLimits
    ) async throws -> ToolResultRecord {
        if ContextBuilderFrozenWorkspace.readToolNames.contains(call.tool) {
            do {
                let text = try await workspace.executeRead(
                    tool: call.tool,
                    arguments: call.arguments,
                    stagedSelection: staged.map(\.absolutePath)
                )
                return ToolResultRecord(
                    tool: call.tool,
                    status: .ok,
                    body: truncate(text, limit: limits.maximumToolResultCharacters)
                )
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                return ToolResultRecord(tool: call.tool, status: .error, body: describe(error))
            }
        }
        guard call.tool == "manage_selection" else {
            return ToolResultRecord(
                tool: call.tool,
                status: .refused,
                body: "tool_not_allowed: \(call.tool) is not available during headless discovery. "
                    + "Only get_file_tree, file_search, read_file, get_code_structure, and manage_selection exist; "
                    + "nothing was executed."
            )
        }
        return manageSelection(call.arguments, staged: &staged, workspace: workspace, skipSymlinks: skipSymlinks, limits: limits)
    }

    private static func manageSelection(
        _ arguments: [String: Value],
        staged: inout [ContextBuilderDiscoveryAuthorizedPath],
        workspace: ContextBuilderFrozenWorkspace,
        skipSymlinks: Bool,
        limits: ContextBuilderDiscoveryLimits
    ) -> ToolResultRecord {
        func failure(_ message: String) -> ToolResultRecord {
            ToolResultRecord(
                tool: "manage_selection",
                status: .error,
                body: message + " The staged selection is unchanged."
            )
        }
        let operation = (arguments["op"]?.stringValue ?? "get").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var paths: [String] = []
        if let raw = arguments["paths"], raw != .null {
            guard case let .array(items) = raw else { return failure("paths must be an array of strings.") }
            for item in items {
                guard case let .string(path) = item else { return failure("paths must be an array of strings.") }
                paths.append(path)
            }
        }
        switch operation {
        case "get":
            break
        case "clear":
            staged = []
        case "add", "set":
            var next = operation == "set" ? [] : staged
            for rawPath in paths {
                let admitted: ContextBuilderDiscoveryAuthorizedPath
                do {
                    admitted = try workspace.authorize(rawPath, skipSymlinks: skipSymlinks)
                } catch {
                    return failure("Rejected: \(describe(error))")
                }
                if !next.contains(where: { $0.absolutePath == admitted.absolutePath }) {
                    next.append(admitted)
                }
            }
            guard next.count <= limits.maximumSelectedFiles else {
                return failure("This would stage \(next.count) files, above the \(limits.maximumSelectedFiles)-file limit.")
            }
            staged = next
        case "remove":
            let removed = Set(paths.flatMap { rawPath -> [String] in
                var keys = [rawPath.trimmingCharacters(in: .whitespacesAndNewlines)]
                if let admitted = try? workspace.authorize(rawPath, skipSymlinks: skipSymlinks) {
                    keys.append(admitted.absolutePath)
                }
                return keys
            })
            staged.removeAll { removed.contains($0.absolutePath) || removed.contains($0.displayPath) }
        default:
            return failure("Unknown manage_selection op '\(operation)'; use get, add, remove, set, or clear.")
        }
        return ToolResultRecord(
            tool: "manage_selection",
            status: .ok,
            body: ContextBuilderDiscoveryPrompt.stagedSummary(staged)
        )
    }

    // MARK: - Finalization

    private func finalize(
        _ decision: Decision,
        mode: OracleMode,
        instructions: String,
        workspace: ContextBuilderFrozenWorkspace,
        skipSymlinks: Bool,
        committer: any ContextBuilderDiscoveryCommitter,
        packStore: any OracleArtifactStore
    ) async throws -> ContextBuilderDiscoveryOutcome {
        try Task.checkCancellation()
        try workspace.revalidateRoots()
        // The filesystem may have changed since a path was staged; admit every path again.
        var files: [ContextBuilderDiscoveryAuthorizedPath] = []
        for path in decision.selection {
            files.append(try workspace.authorize(path.absolutePath, skipSymlinks: skipSymlinks))
        }
        let declaredBytes = files.reduce(0) { $0 + $1.byteCount }
        guard declaredBytes <= limits.maximumPackBytes else {
            throw ContextBuilderDiscoveryError.packBudgetExceeded(bytes: declaredBytes, limit: limits.maximumPackBytes)
        }
        var contents: [(path: String, text: String)] = []
        var consumed = 0
        for file in files {
            try Task.checkCancellation()
            let text = try workspace.readForPack(
                file,
                skipSymlinks: skipSymlinks,
                limit: max(0, limits.maximumPackBytes - consumed)
            )
            consumed += file.byteCount
            contents.append((file.displayPath, text))
        }
        let pack = try OracleFrozenContextPack(
            mode: mode,
            content: ContextBuilderDiscoveryPrompt.packContent(
                mode: mode,
                prompt: decision.prompt,
                instructions: instructions,
                files: contents
            ),
            provenance: files.map { OracleEvidenceReference(path: $0.displayPath) }
        )
        let data = try pack.canonicalData()
        guard data.count <= limits.maximumPackBytes else {
            throw ContextBuilderDiscoveryError.packBudgetExceeded(bytes: data.count, limit: limits.maximumPackBytes)
        }
        try Task.checkCancellation()
        try workspace.revalidateRoots()
        let reference = try await OracleFrozenPackReference(artifactID: packStore.storeArtifact(data))
        try Task.checkCancellation()
        let receipt = try await committer.commitSelection(files.map(\.absolutePath), over: workspace.snapshot)
        return ContextBuilderDiscoveryOutcome(
            context: workspace.snapshot.identity,
            selection: files.map(\.absolutePath),
            displayPaths: files.map(\.displayPath),
            prompt: decision.prompt,
            pack: pack,
            packReference: reference,
            packBytes: data.count,
            turns: decision.turns,
            toolCalls: decision.toolCalls,
            refusedToolCalls: decision.refusedToolCalls,
            receipt: receipt
        )
    }

    static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n… [truncated: \(text.count - limit) more characters]"
    }

    static func describe(_ error: Error) -> String {
        let text = if let description = (error as? LocalizedError)?.errorDescription {
            description
        } else if let description = (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String {
            description
        } else {
            String(describing: error)
        }
        return truncate(text, limit: 1024)
    }
}

/// Prompt and pack rendering for discovery. Both are deterministic functions of their inputs.
package enum ContextBuilderDiscoveryPrompt {
    package static let protocolVersion = "repoprompt-headless-context-discovery/v1"

    static func render(
        instructions: String,
        workspace: ContextBuilderFrozenWorkspace,
        staged: [ContextBuilderDiscoveryAuthorizedPath],
        transcript: [ContextBuilderDiscoveryEngine.TurnRecord],
        turn: Int,
        limits: ContextBuilderDiscoveryLimits
    ) throws -> String {
        let header = preamble(workspace: workspace, limits: limits)
            + "\n\n<user_instructions>\n\(instructions)\n</user_instructions>"
        var footer = "\n\n<staged_selection>\n\(stagedSummary(staged))\n</staged_selection>\n\n"
        footer += "Reply \(turn) of \(limits.maximumTurns)."
        if turn == limits.maximumTurns {
            footer += " This is your last reply: send the final object now."
        }
        footer += " Reply with exactly one JSON object and nothing else."

        // Elide the oldest tool-result bodies first until the prompt fits.
        let positions = transcript.indices.flatMap { turnIndex in
            transcript[turnIndex].results.indices.map { (turnIndex, $0) }
        }
        let fixedCharacters = header.count + footer.count
        var elided = 0
        while true {
            let elidedPositions = Set(positions.prefix(elided).map { "\($0.0):\($0.1)" })
            let body = renderTranscript(transcript, elided: elidedPositions)
            let characters = fixedCharacters + body.count
            if characters <= limits.maximumPromptCharacters { return header + body + footer }
            guard elided < positions.count else {
                throw ContextBuilderDiscoveryError.promptBudgetExceeded(
                    characters: characters,
                    limit: limits.maximumPromptCharacters
                )
            }
            elided += 1
        }
    }

    static func stagedSummary(_ staged: [ContextBuilderDiscoveryAuthorizedPath]) -> String {
        guard !staged.isEmpty else { return "No files are staged." }
        return "\(staged.count) staged file(s):\n" + staged.map { "- \($0.displayPath) (\($0.byteCount) bytes)" }
            .joined(separator: "\n")
    }

    static func packContent(
        mode: OracleMode,
        prompt: String,
        instructions: String,
        files: [(path: String, text: String)]
    ) -> String {
        let directive = switch mode {
        case .plan:
            "Produce an implementation plan for the task. Ground each step in the files below and cite `path:start-end` ranges."
        case .review:
            "Review the code relevant to the task. Report concrete correctness, regression, and test gaps with `path:start-end` references to the files below."
        case .chat:
            "Answer the task using the files below. Cite `path:start-end` ranges for important claims."
        }
        var sections = ["<task>\n\(prompt)\n\n\(directive)\n</task>"]
        if prompt != instructions {
            sections.append("<user_instructions>\n\(instructions)\n</user_instructions>")
        }
        sections.append("<file_map>\n" + files.map { "- \($0.path)" }.joined(separator: "\n") + "\n</file_map>")
        let bodies = files.map { "<file path=\"\(escapeAttribute($0.path))\">\n\($0.text)\n</file>" }
        sections.append("<file_contents>\n" + bodies.joined(separator: "\n") + "\n</file_contents>")
        return sections.joined(separator: "\n\n")
    }

    private static func preamble(workspace: ContextBuilderFrozenWorkspace, limits: ContextBuilderDiscoveryLimits) -> String {
        let roots = zip(workspace.rootDisplayNames, workspace.snapshot.roots).map { name, root in
            name == root.path ? "- \(root.path)" : "- \(name): \(root.path)"
        }.joined(separator: "\n")
        return """
        <discovery_protocol version="\(protocolVersion)">
        You are the discovery agent for RepoPrompt's headless Context Builder. Find the workspace files a follow-up model needs for the user's task, then finish with a clarified task prompt and the selected files. Do not solve the task yourself.

        You have no direct tool access in this session: do not run shell commands and do not edit files. Every reply must be exactly one JSON object and nothing else, in one of two forms.

        1. Request tools (at most \(limits.maximumToolCallsPerTurn) calls per reply). Results arrive in the next message:
        {"tool_calls":[{"tool":"file_search","arguments":{"pattern":"SessionStore","mode":"content"}}]}

        2. Finish:
        {"final":{"prompt":"<clarified task for the follow-up model>","selected_paths":["Sources/App/SessionStore.swift"]}}
        When "selected_paths" is omitted, the staged selection is used.

        Tools (all read-only except the staged selection):
        - get_file_tree {"path"?: string, "max_depth"?: integer}: directory tree of the roots or of one directory. Prefer a small max_depth.
        - file_search {"pattern": string, "mode"?: "auto"|"path"|"content"|"both", "regex"?: boolean, "max_results"?: integer, "filter"?: {"extensions"?: [string], "paths"?: [string], "exclude"?: [string]}}: search file paths and contents.
        - read_file {"path": string, "start_line"?: integer, "limit"?: integer}: read a file; use line ranges for large files.
        - get_code_structure {"paths"?: [string]}: signatures for files or directories; omitted paths mean the staged selection.
        - manage_selection {"op": "get"|"add"|"remove"|"set"|"clear", "paths"?: [string]}: edit the staged selection. Nothing is written to the workspace until you finish.

        Rules:
        - Paths are relative to a workspace root or absolute under one. Only regular files inside the roots can be selected; symbolic links, directories, and paths outside the roots are rejected, and a final selection that contains one fails the whole run.
        - Select at most \(limits.maximumSelectedFiles) files. Prefer the smallest set that fully covers the task.
        - You have at most \(limits.maximumTurns) replies. Any other tool name is refused.
        </discovery_protocol>

        <workspace_roots>
        \(roots)
        </workspace_roots>
        """
    }

    private static func renderTranscript(
        _ transcript: [ContextBuilderDiscoveryEngine.TurnRecord],
        elided: Set<String>
    ) -> String {
        guard !transcript.isEmpty else { return "" }
        var lines = ["", "", "<discovery_transcript>"]
        for (turnIndex, turn) in transcript.enumerated() {
            lines.append("<turn number=\"\(turn.number)\">")
            lines.append("<reply>\n\(turn.reply)\n</reply>")
            for (resultIndex, result) in turn.results.enumerated() {
                let body = elided.contains("\(turnIndex):\(resultIndex)")
                    ? "[elided to stay within the prompt budget; call the tool again if you still need it]"
                    : result.body
                lines.append(
                    "<tool_result index=\"\(resultIndex + 1)\" tool=\"\(escapeAttribute(result.tool))\" status=\"\(result.status.rawValue)\">\n\(body)\n</tool_result>"
                )
            }
            lines.append("</turn>")
        }
        lines.append("</discovery_transcript>")
        return lines.joined(separator: "\n")
    }

    private static func escapeAttribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }
}
