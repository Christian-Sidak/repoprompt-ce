import CryptoKit
import Foundation
import MCP
import RepoPromptC
import RepoPromptCodeMapCore

package extension DomainPhysicalToolRequest {
    func mcpArguments() throws -> [String: Value] {
        try JSONDecoder().decode([String: Value].self, from: argumentsJSON)
    }
}

package extension DomainPhysicalToolResult {
    static func mcp(_ value: Value) throws -> DomainPhysicalToolResult {
        try DomainPhysicalToolResult(json: JSONEncoder().encode(value))
    }

    static func object(_ value: [String: Value]) throws -> DomainPhysicalToolResult {
        try mcp(.object(value))
    }
}

package struct DomainCanonicalWorkspaceSnapshot {
    package let identity: DomainContextIdentity
    package let roots: [URL]
    package let prompt: String
    package let selection: [String]

    package init(
        identity: DomainContextIdentity,
        roots: [URL],
        prompt: String,
        selection: [String]
    ) {
        self.identity = identity
        self.roots = roots
        self.prompt = prompt
        self.selection = selection
    }
}

package enum DomainCanonicalWorkspaceMutation {
    case setPrompt(String)
    case setSelection([String])
}

package struct DomainCanonicalWorkspaceAdapter {
    package typealias ToolSnapshot = @Sendable (DomainPhysicalToolRequest) async throws -> DomainCanonicalWorkspaceSnapshot
    package typealias ReadSnapshot = @Sendable (DomainPhysicalReadRequest) async throws -> DomainCanonicalWorkspaceSnapshot
    package typealias Mutate = @Sendable (
        DomainPhysicalToolRequest,
        DomainCanonicalWorkspaceMutation
    ) async throws -> DomainCanonicalWorkspaceSnapshot
    package typealias ResolvePath = @Sendable (
        _ rawPath: String,
        _ roots: [URL],
        _ allowMissingLeaf: Bool
    ) throws -> URL

    package typealias IgnoreConfigurationProvider = @Sendable () async -> DomainIgnoreConfiguration?

    package let toolSnapshot: ToolSnapshot
    package let readSnapshot: ReadSnapshot
    package let mutate: Mutate
    package let resolvePath: ResolvePath
    /// When present, enumeration applies the app's ignore layers; when nil, enumeration keeps the
    /// legacy hidden-file-only filtering.
    package let ignoreConfiguration: IgnoreConfigurationProvider?

    package init(
        toolSnapshot: @escaping ToolSnapshot,
        readSnapshot: @escaping ReadSnapshot,
        mutate: @escaping Mutate,
        resolvePath: @escaping ResolvePath,
        ignoreConfiguration: IgnoreConfigurationProvider? = nil
    ) {
        self.toolSnapshot = toolSnapshot
        self.readSnapshot = readSnapshot
        self.mutate = mutate
        self.resolvePath = resolvePath
        self.ignoreConfiguration = ignoreConfiguration
    }
}

/// Ignore inputs for headless enumeration: the app's effective global defaults and the
/// respect/hierarchical switches, matching the app crawl's defaults when settings are unset.
package struct DomainIgnoreConfiguration: Equatable {
    package let globalPatterns: String
    package let respectRepoIgnore: Bool
    package let respectCursorignore: Bool
    package let hierarchicalIgnores: Bool

    package init(
        globalPatterns: String,
        respectRepoIgnore: Bool = true,
        respectCursorignore: Bool = true,
        hierarchicalIgnores: Bool = true
    ) {
        self.globalPatterns = globalPatterns
        self.respectRepoIgnore = respectRepoIgnore
        self.respectCursorignore = respectCursorignore
        self.hierarchicalIgnores = hierarchicalIgnores
    }
}

/// Bounds for direct-headless physical reads. File-size limits match the app's default content
/// read limit; enumeration limits keep one call from walking an unbounded tree.
package enum MCPDomainCanonicalReadBounds {
    package static let maximumReadFileBytes = 10_000_000
    package static let maximumSearchFileBytes = 10_000_000
    package static let maximumEnumeratedFiles = 200_000
    package static let maximumTreeLines = 20000
    package static let maximumCodeStructureFiles = 256
}

package enum MCPDomainCanonicalReadError: Error, Equatable, LocalizedError {
    case fileTooLarge(byteCount: Int, limit: Int)
    case undecodableText
    case notARegularFile

    package var errorDescription: String? {
        switch self {
        case let .fileTooLarge(byteCount, limit):
            "File is \(byteCount) bytes, which exceeds the \(limit)-byte read limit."
        case .undecodableText:
            "File is not UTF-8 or UTF-16 text."
        case .notARegularFile:
            "Path is not a regular file."
        }
    }
}

/// Cooperative cancellation for blocking filesystem work that runs off the Swift concurrency pool.
private final class BlockingCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.withLock { cancelled = true }
    }

    func check() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
}

/// Canonical transport-neutral implementation of the standalone workspace capability family.
/// The executable supplies only authoritative snapshot/mutation/path adapters; argument parsing,
/// selection semantics, file reads, search, tree rendering, codemaps, prompt/context projection,
/// mutation admission, and response shapes are owned here.
package struct MCPDomainCanonicalWorkspaceService {
    private let adapter: DomainCanonicalWorkspaceAdapter

    package init(adapter: DomainCanonicalWorkspaceAdapter) {
        self.adapter = adapter
    }

    package func mutateSelection(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.mcpArguments()
        let snapshot = try await adapter.toolSnapshot(request)
        let op = args["op"]?.stringValue ?? "get"
        var paths = snapshot.selection
        let requested = args["paths"]?.arrayValue?.compactMap(\.stringValue) ?? []
        switch op {
        case "get", "preview":
            break
        case "clear":
            paths = []
        case "set":
            paths = requested
        case "add":
            for path in requested where !paths.contains(path) {
                paths.append(path)
            }
        case "remove":
            let removed = Set(requested)
            paths.removeAll { removed.contains($0) }
        case "promote", "demote":
            break
        default:
            throw MCPError.invalidParams("unknown manage_selection op: \(op)")
        }
        if paths != snapshot.selection {
            _ = try await adapter.mutate(request, .setSelection(paths))
        }
        return try .object([
            "selection": .array(paths.map(Value.string)),
            "count": .int(paths.count),
            "operation": .string(op)
        ])
    }

    package func inspectCodeStructure(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.request.mcpArguments()
        let snapshot = try await adapter.readSnapshot(request)
        let requested = args["paths"]?.arrayValue?.compactMap(\.stringValue) ?? snapshot.selection
        // Like the app, omitted paths mean the current selection. An empty selection never
        // expands to a whole-root walk.
        guard !requested.isEmpty else {
            return try .object([
                "files": .array([]),
                "updates_pending": .bool(false),
                "backend": .string("headless"),
                "note": .string("No paths were given and the selection is empty.")
            ])
        }
        let limit = MCPDomainCanonicalReadBounds.maximumCodeStructureFiles
        let resolved = try requested.prefix(limit).map { raw in
            try adapter.resolvePath(raw, snapshot.roots, false)
        }
        let ignoreContext = await makeIgnoreContext(roots: snapshot.roots)
        let (files, truncated) = try await Self.runCancellableBlocking { cancellation in
            var candidates: [URL] = []
            var truncated = false
            for url in resolved {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    let scan = try Self.forEachFile(
                        under: [url],
                        ignore: ignoreContext,
                        cancellation: cancellation
                    ) { file, _ in
                        guard CodeMapSyntaxEngine.supportsCodeMap(fileExtension: file.pathExtension) else { return true }
                        candidates.append(file)
                        return candidates.count < limit
                    }
                    truncated = truncated || scan.stoppedEarly
                } else if CodeMapSyntaxEngine.supportsCodeMap(fileExtension: url.pathExtension) {
                    candidates.append(url)
                }
                if candidates.count >= limit {
                    truncated = truncated || url != resolved.last
                    break
                }
            }
            let files = try candidates.prefix(limit).map { file -> Value in
                try cancellation.check()
                return try Self.codeMapResult(file)
            }
            return (files, truncated || requested.count > limit)
        }
        var result: [String: Value] = [
            "files": .array(files),
            "updates_pending": .bool(false),
            "backend": .string("headless")
        ]
        if truncated { result["truncated"] = .bool(true) }
        return try .object(result)
    }

    package func renderFileTree(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.request.mcpArguments()
        let snapshot = try await adapter.readSnapshot(request)
        if args["type"]?.stringValue == "roots" {
            return try .mcp(.string(snapshot.roots.map(\.path).joined(separator: "\n")))
        }
        let maxDepth = max(0, min(args["max_depth"]?.intValue ?? 6, 32))
        let roots: [URL] = if let path = args["path"]?.stringValue {
            try [adapter.resolvePath(path, snapshot.roots, false)]
        } else {
            snapshot.roots
        }
        let ignoreContext = await makeIgnoreContext(roots: snapshot.roots)
        let lines = try await Self.runCancellableBlocking { cancellation in
            var lines: [String] = []
            for root in roots {
                let remaining = MCPDomainCanonicalReadBounds.maximumTreeLines - lines.count
                guard remaining > 0 else { break }
                try lines.append(contentsOf: Self.treeLines(
                    root: root,
                    maxDepth: maxDepth,
                    maximumLines: remaining,
                    ignore: ignoreContext,
                    cancellation: cancellation
                ))
            }
            if lines.count >= MCPDomainCanonicalReadBounds.maximumTreeLines {
                lines.append("… truncated after \(MCPDomainCanonicalReadBounds.maximumTreeLines) lines; narrow with path or max_depth")
            }
            return lines
        }
        return try .mcp(.string(lines.joined(separator: "\n")))
    }

    package func readFile(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.request.mcpArguments()
        let snapshot = try await adapter.readSnapshot(request)
        guard let rawPath = args["path"]?.stringValue else {
            throw MCPError.invalidParams("missing path")
        }
        let url = try adapter.resolvePath(rawPath, snapshot.roots, false)
        let text = try await Self.runCancellableBlocking { _ in
            try Self.readText(at: url, limit: MCPDomainCanonicalReadBounds.maximumReadFileBytes)
        }
        let lines = text.components(separatedBy: .newlines)
        let start = args["start_line"]?.intValue
        let limit = args["limit"]?.intValue
        let selected: ArraySlice<String>
        if let start, start < 0 {
            selected = lines.suffix(min(lines.count, abs(start)))
        } else if let start {
            let index = max(0, start - 1)
            guard index < lines.count else { return try .mcp(.string("")) }
            selected = lines[index ..< min(lines.count, index + max(0, limit ?? lines.count))]
        } else {
            selected = lines[...]
        }
        return try .mcp(.string(selected.joined(separator: "\n")))
    }

    package func searchFiles(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.request.mcpArguments()
        let snapshot = try await adapter.readSnapshot(request)
        guard let pattern = args["pattern"]?.stringValue, !pattern.isEmpty else {
            throw MCPError.invalidParams("pattern cannot be empty")
        }
        let maxResults = max(1, min(args["max_results"]?.intValue ?? 50, 1000))
        let regexEnabled = args["regex"]?.boolValue ?? Self.looksLikeRegex(pattern)
        let wholeWord = args["whole_word"]?.boolValue ?? false
        let regexPattern = wholeWord ? "\\b(?:\(pattern))\\b" : pattern
        // Validate once here; the blocking scan compiles its own instance.
        if regexEnabled { _ = try NSRegularExpression(pattern: regexPattern) }
        let mode = (args["mode"]?.stringValue ?? "auto").lowercased()
        guard ["auto", "path", "content", "both"].contains(mode) else {
            throw MCPError.invalidParams("mode must be auto, path, content, or both")
        }
        let filter = Self.searchFilter(args)
        let searchesPaths = mode == "path" || mode == "both" || (mode == "auto" && pattern.contains("*"))
        let searchesContent = mode == "content" || mode == "both" || (mode == "auto" && !searchesPaths)
        let relativeRoots = Self.relativeRoots(snapshot.roots)
        let roots = snapshot.roots
        let ignoreContext = await makeIgnoreContext(roots: roots)
        let (results, enumerationTruncated, skippedLargeFiles) = try await Self.runCancellableBlocking { cancellation in
            let regex = regexEnabled ? try NSRegularExpression(pattern: regexPattern) : nil
            var results: [Value] = []
            var skippedLargeFiles = 0
            let scan = try Self.forEachFile(under: roots, ignore: ignoreContext, cancellation: cancellation) { file, byteCount in
                let relative = Self.relativePath(file, roots: relativeRoots)
                guard Self.includes(relativePath: relative, file: file, filter: filter) else {
                    return true
                }
                if searchesPaths,
                   Self.matches(pattern, value: relative, regex: regex, wholeWord: wholeWord)
                {
                    results.append(.object(["path": .string(relative)]))
                    if results.count >= maxResults { return false }
                }
                guard searchesContent else { return true }
                if let byteCount, byteCount > MCPDomainCanonicalReadBounds.maximumSearchFileBytes {
                    skippedLargeFiles += 1
                    return true
                }
                guard let text = try? Self.readText(
                    at: file,
                    limit: MCPDomainCanonicalReadBounds.maximumSearchFileBytes
                ) else { return true }
                for (index, line) in text.components(separatedBy: .newlines).enumerated() {
                    guard Self.matches(pattern, value: line, regex: regex, wholeWord: wholeWord) else { continue }
                    results.append(.object([
                        "path": .string(relative),
                        "line": .int(index + 1),
                        "text": .string(line)
                    ]))
                    if results.count >= maxResults { return false }
                }
                return true
            }
            return (results, scan.enumerationLimitReached, skippedLargeFiles)
        }
        var bounds: [String: Value] = [:]
        if enumerationTruncated { bounds["truncated"] = .bool(true) }
        if skippedLargeFiles > 0 { bounds["skipped_large_files"] = .int(skippedLargeFiles) }
        if args["count_only"]?.boolValue == true {
            return try .object(["count": .int(results.count)].merging(bounds) { current, _ in current })
        }
        return try .object(
            ["matches": .array(results), "count": .int(results.count)].merging(bounds) { current, _ in current }
        )
    }

    private struct SearchFilter {
        let extensions: Set<String>
        let paths: [String]
        let excludes: [String]
    }

    private static func searchFilter(_ args: [String: Value]) -> SearchFilter {
        let object = args["filter"]?.objectValue ?? [:]
        let extensions = Set(strings(object["extensions"]).map {
            let normalized = $0.lowercased()
            return normalized.hasPrefix(".") ? normalized : "." + normalized
        })
        var paths = strings(object["paths"])
        if let path = args["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty
        {
            paths.append(path)
        }
        return SearchFilter(
            extensions: extensions,
            paths: paths,
            excludes: strings(object["exclude"])
        )
    }

    private static func strings(_ value: Value?) -> [String] {
        guard let value else { return [] }
        switch value {
        case let .array(values):
            return values.compactMap(\.stringValue).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
        case let .string(value):
            return value.split(separator: ",").map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
        default:
            return []
        }
    }

    private static func includes(relativePath: String, file: URL, filter: SearchFilter) -> Bool {
        if !filter.extensions.isEmpty {
            let fileExtension = file.pathExtension.isEmpty ? "" : "." + file.pathExtension.lowercased()
            guard filter.extensions.contains(fileExtension) else { return false }
        }
        if !filter.paths.isEmpty,
           !filter.paths.contains(where: { matchesPathFilter($0, relativePath: relativePath) })
        {
            return false
        }
        return !filter.excludes.contains(where: { matchesExclude($0, relativePath: relativePath) })
    }

    private static func matchesPathFilter(_ rawPattern: String, relativePath: String) -> Bool {
        let pattern = rawPattern
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !pattern.isEmpty else { return true }
        if containsWildcard(pattern) {
            return globMatches(pattern, relativePath)
        }
        let candidate = pattern.lowercased()
        let relative = relativePath.lowercased()
        return relative == candidate || relative.hasPrefix(candidate + "/")
    }

    private static func matchesExclude(_ pattern: String, relativePath: String) -> Bool {
        if containsWildcard(pattern) {
            return globMatches(pattern, relativePath)
        }
        return relativePath.localizedCaseInsensitiveContains(pattern)
    }

    private static func containsWildcard(_ pattern: String) -> Bool {
        pattern.contains("*") || pattern.contains("?") || pattern.contains("[")
    }

    private static func globMatches(_ pattern: String, _ path: String) -> Bool {
        let wildstar: UInt32 = 0x40
        let casefold: UInt32 = 0x10
        let flags = (pattern.contains("**") ? wildstar : 0) | casefold
        return pattern.withCString { patternCString in
            path.withCString { pathCString in
                repo_wildmatch(patternCString, pathCString, flags) == 0
            }
        }
    }

    package func renderWorkspaceContext(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.request.mcpArguments()
        let snapshot = try await adapter.readSnapshot(request)
        let op = args["op"]?.stringValue ?? "snapshot"
        switch op {
        case "snapshot":
            return try .object([
                "prompt": .string(snapshot.prompt),
                "selection": .array(snapshot.selection.map(Value.string)),
                "roots": .array(snapshot.roots.map { .string($0.path) }),
                "workspace_id": .string(snapshot.identity.workspaceID.uuidString),
                "context_id": .string(snapshot.identity.contextID.uuidString)
            ])
        case "export":
            guard let path = args["path"]?.stringValue else {
                throw MCPError.invalidParams("export requires path")
            }
            let destination = try adapter.resolvePath(path, snapshot.roots, true)
            let content = "Prompt:\n\(snapshot.prompt)\n\nSelection:\n\(snapshot.selection.joined(separator: "\n"))\n"
            let capability = try await admitExport(destination, roots: snapshot.roots)
            guard let data = content.data(using: .utf8) else {
                throw MCPError.invalidParams("export content is not UTF-8")
            }
            try capability.writeFile(
                at: destination.path,
                data: data,
                overwrite: false,
                expectedContentDigest: nil,
                requireExisting: false
            )
            return try .object(["path": .string(destination.path), "exported": .bool(true)])
        case "list_presets":
            return try .object(["presets": .array([])])
        case "select_preset":
            throw MCPError.invalidRequest("copy presets are unavailable without an extracted preset backend")
        default:
            throw MCPError.invalidParams("unknown workspace_context op: \(op)")
        }
    }

    package func accessPrompt(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.request.mcpArguments()
        let snapshot = try await adapter.readSnapshot(request)
        let op = args["op"]?.stringValue ?? "get"
        switch op {
        case "get":
            return try .object(["prompt": .string(snapshot.prompt)])
        case "set", "append", "clear":
            let prompt: String = switch op {
            case "set": args["text"]?.stringValue ?? ""
            case "append": snapshot.prompt + (args["text"]?.stringValue ?? "")
            default: ""
            }
            let physical = DomainPhysicalToolRequest(
                argumentsJSON: request.request.argumentsJSON,
                securityContext: request.request.securityContext
            )
            let updated = try await adapter.mutate(physical, .setPrompt(prompt))
            return try .object(["prompt": .string(updated.prompt), "operation": .string(op)])
        case "export":
            guard let path = args["path"]?.stringValue else {
                throw MCPError.invalidParams("export requires path")
            }
            let destination = try adapter.resolvePath(path, snapshot.roots, true)
            let capability = try await admitExport(destination, roots: snapshot.roots)
            guard let data = snapshot.prompt.data(using: .utf8) else {
                throw MCPError.invalidParams("export content is not UTF-8")
            }
            try capability.writeFile(
                at: destination.path,
                data: data,
                overwrite: false,
                expectedContentDigest: nil,
                requireExisting: false
            )
            return try .object(["path": .string(destination.path), "exported": .bool(true)])
        case "list_presets":
            return try .object(["presets": .array([])])
        case "select_preset":
            throw MCPError.invalidRequest("select_preset is unavailable without an extracted preset backend")
        default:
            throw MCPError.invalidParams("unknown prompt op: \(op)")
        }
    }

    private func admitExport(_ destination: URL, roots: [URL]) async throws -> DomainMutationPhysicalCapability {
        let mappings = roots.map {
            DomainMutationPhysicalRootMapping(canonicalRoot: $0.path, physicalRoot: $0.path)
        }
        try await MCPDomainMutationCommitContext.admitPhysicalTargets(
            [destination.path],
            rootMappings: mappings
        )
        guard let capability = try await MCPDomainMutationCommitContext.physicalMutationCapability() else {
            throw DomainMutationPhysicalCapabilityError.scopeUnavailable
        }
        try capability.validateWriteTarget(
            at: destination.path,
            overwrite: false,
            expectedContentDigest: nil,
            requireExisting: false
        )
        try await MCPDomainMutationCommitContext.willCommit()
        return capability
    }

    private static func codeMapResult(_ url: URL) throws -> Value {
        let data = try Data(contentsOf: url)
        guard let content = String(data: data, encoding: .utf8) else {
            return .object(["path": .string(url.path), "diagnostic": .string("undecodable_source")])
        }
        guard let language = CodeMapSyntaxEngine.shared.language(forFileExtension: url.pathExtension) else {
            return .object(["path": .string(url.path), "diagnostic": .string("unsupported_language")])
        }
        let snapshot = CodeMapCoreSourceSnapshot(
            rawByteCount: data.count,
            rawSHA256: CodeMapRawSourceDigest(bytes: Data(SHA256.hash(data: data))),
            decoderPolicy: .workspaceAutomaticV1,
            decodeResult: .decoded(
                CodeMapDecodedSource(text: content, detectedEncodingRawValue: String.Encoding.utf8.rawValue)
            )
        )
        let outcome = try CodeMapSyntaxArtifactBuilder.build(source: snapshot, language: language)
        switch outcome {
        case let .ready(artifact):
            return .object([
                "path": .string(url.path),
                "language": .string(language.rawValue),
                "signatures": .string(artifact.apiDescription)
            ])
        case .readyNoSymbols:
            return .object([
                "path": .string(url.path),
                "language": .string(language.rawValue),
                "signatures": .string(""),
                "diagnostic": .string("no_symbols")
            ])
        case .oversize:
            return .object(["path": .string(url.path), "diagnostic": .string("source_oversize")])
        case .parseFailed:
            return .object(["path": .string(url.path), "diagnostic": .string("parse_failed")])
        case .decodeFailed:
            return .object(["path": .string(url.path), "diagnostic": .string("decode_failed")])
        }
    }

    private static func runBlocking<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let value = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try operation() })
            }
        }
        try Task.checkCancellation()
        return value
    }

    private static func runCancellableBlocking<T: Sendable>(
        _ operation: @escaping @Sendable (BlockingCancellation) throws -> T
    ) async throws -> T {
        let cancellation = BlockingCancellation()
        return try await withTaskCancellationHandler {
            try await runBlocking { try operation(cancellation) }
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Reads a bounded text file as UTF-8, or UTF-16 when a byte-order mark says so.
    private static func readText(at url: URL, limit: Int) throws -> String {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw MCPDomainCanonicalReadError.notARegularFile }
        if let size = values.fileSize, size > limit {
            throw MCPDomainCanonicalReadError.fileTooLarge(byteCount: size, limit: limit)
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= limit else {
            throw MCPDomainCanonicalReadError.fileTooLarge(byteCount: data.count, limit: limit)
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            guard let text = String(data: data, encoding: .utf16) else {
                throw MCPDomainCanonicalReadError.undecodableText
            }
            return text
        }
        let body = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        guard let text = String(data: Data(body), encoding: .utf8) else {
            throw MCPDomainCanonicalReadError.undecodableText
        }
        return text
    }

    private func makeIgnoreContext(roots: [URL]) async -> HeadlessIgnoreContext? {
        guard let configuration = await adapter.ignoreConfiguration?() else { return nil }
        return HeadlessIgnoreContext(roots: roots, configuration: configuration)
    }

    private struct FileScan {
        /// The visitor asked to stop.
        var stoppedEarly = false
        /// The global enumeration bound was reached before the tree was exhausted.
        var enumerationLimitReached = false
    }

    /// Lazily visits regular files under `roots`, bounded by `maximumEnumeratedFiles`.
    /// The visitor returns false to stop.
    private static func forEachFile(
        under roots: [URL],
        ignore: HeadlessIgnoreContext? = nil,
        cancellation: BlockingCancellation,
        _ visit: (URL, Int?) throws -> Bool
    ) throws -> FileScan {
        var scan = FileScan()
        var visited = 0
        for root in roots {
            let located = ignore?.locate(root)
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey],
                options: located == nil ? [.skipsHiddenFiles, .skipsPackageDescendants] : [.skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                try cancellation.check()
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
                if let located, let relative = located.relativePath(of: url) {
                    let isDirectory = values?.isDirectory == true
                    guard located.evaluator.admits(relative, isDirectory: isDirectory) else {
                        if isDirectory, !located.evaluator.requiresTraversal(relative) {
                            enumerator.skipDescendants()
                        }
                        continue
                    }
                }
                guard values?.isRegularFile == true else { continue }
                guard visited < MCPDomainCanonicalReadBounds.maximumEnumeratedFiles else {
                    scan.enumerationLimitReached = true
                    return scan
                }
                visited += 1
                guard try visit(url, values?.fileSize) else {
                    scan.stoppedEarly = true
                    return scan
                }
            }
        }
        return scan
    }

    private static func treeLines(
        root: URL,
        maxDepth: Int,
        maximumLines: Int,
        ignore: HeadlessIgnoreContext? = nil,
        cancellation: BlockingCancellation
    ) throws -> [String] {
        var lines = [root.lastPathComponent + "/"]
        let located = ignore?.locate(root)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: located == nil ? [.skipsHiddenFiles, .skipsPackageDescendants] : [.skipsPackageDescendants]
        ) else { return lines }
        for case let url as URL in enumerator {
            try cancellation.check()
            guard lines.count < maximumLines else { break }
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let depth = relative.split(separator: "/").count
            if depth > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if let located, let ignoredRelative = located.relativePath(of: url) {
                guard located.evaluator.admits(ignoredRelative, isDirectory: isDirectory) else {
                    if isDirectory, !located.evaluator.requiresTraversal(ignoredRelative) {
                        enumerator.skipDescendants()
                    }
                    continue
                }
            }
            lines.append(String(repeating: "  ", count: depth) + url.lastPathComponent + (isDirectory ? "/" : ""))
        }
        return lines
    }

    private struct RelativeRoot {
        let rawPath: String
        let canonicalPath: String
    }

    private static func relativeRoots(_ roots: [URL]) -> [RelativeRoot] {
        roots.map {
            RelativeRoot(
                rawPath: $0.standardizedFileURL.path,
                canonicalPath: $0.resolvingSymlinksInPath().standardizedFileURL.path
            )
        }
    }

    private static func relativePath(_ url: URL, roots: [RelativeRoot]) -> String {
        let path = url.standardizedFileURL.path
        for root in roots {
            for rootPath in [root.rawPath, root.canonicalPath] {
                guard path.hasPrefix(rootPath + "/") else { continue }
                return String(path.dropFirst(rootPath.count + 1))
            }
        }
        return path
    }

    private static func matches(
        _ pattern: String,
        value: String,
        regex: NSRegularExpression?,
        wholeWord: Bool
    ) -> Bool {
        if let regex {
            return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
        }
        if containsWildcard(pattern) {
            return globMatches(pattern, value)
        }
        guard wholeWord else { return value.localizedCaseInsensitiveContains(pattern) }
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
        return (try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: .caseInsensitive))?
            .firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    private static func looksLikeRegex(_ pattern: String) -> Bool {
        pattern.range(of: #"[\[\](){}|+?^$\\]"#, options: .regularExpression) != nil
    }
}

// MARK: - Headless ignore evaluation

/// Maps enumeration bases to the workspace root that owns their ignore chain.
private final class HeadlessIgnoreContext: @unchecked Sendable {
    struct Located {
        let evaluator: HeadlessIgnoreEvaluator
        /// Path of the enumeration base relative to the workspace root ("" for the root itself).
        let basePrefix: String
        /// Equivalent spellings of the base path; the enumerator may report `/private/var/...`
        /// for a base given as `/var/...`.
        let basePaths: [String]

        /// Root-relative path of an enumerated item, or nil when it cannot be attributed to the
        /// base (the caller then applies no ignore decision rather than a wrong one).
        func relativePath(of url: URL) -> String? {
            let path = url.path
            guard let basePath = basePaths.first(where: { path.hasPrefix($0 + "/") }) else { return nil }
            let local = String(path.dropFirst(basePath.count + 1))
            return basePrefix.isEmpty ? local : basePrefix + "/" + local
        }
    }

    private let evaluators: [(rootPath: String, evaluator: HeadlessIgnoreEvaluator)]

    init(roots: [URL], configuration: DomainIgnoreConfiguration) {
        evaluators = roots.map { root in
            let rootPath = root.standardizedFileURL.path
            return (rootPath, HeadlessIgnoreEvaluator(rootPath: rootPath, configuration: configuration))
        }
    }

    /// The evaluator for the workspace root containing `base`, or nil when `base` is outside
    /// every root (ignore rules then do not apply).
    func locate(_ base: URL) -> Located? {
        let basePaths = Self.equivalentPaths(base)
        for (rootPath, evaluator) in evaluators {
            for rootSpelling in Self.equivalentPaths(URL(fileURLWithPath: rootPath, isDirectory: true)) {
                for basePath in basePaths {
                    if basePath == rootSpelling {
                        return Located(evaluator: evaluator, basePrefix: "", basePaths: basePaths)
                    }
                    if basePath.hasPrefix(rootSpelling + "/") {
                        return Located(
                            evaluator: evaluator,
                            basePrefix: String(basePath.dropFirst(rootSpelling.count + 1)),
                            basePaths: basePaths
                        )
                    }
                }
            }
        }
        return nil
    }

    /// The given, symlink-resolved, and `/private`-toggled spellings of a path. macOS exposes
    /// `/var`, `/tmp`, and `/etc` as symlinks into `/private`, and `resolvingSymlinksInPath()`
    /// strips `/private`, so the same directory can be reported either way.
    static func equivalentPaths(_ url: URL) -> [String] {
        let given = url.standardizedFileURL.path
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        var spellings: [String] = []
        for path in [given, resolved] {
            spellings.append(path)
            if path.hasPrefix("/private/") {
                spellings.append(String(path.dropFirst("/private".count)))
            } else if ["/var/", "/tmp/", "/etc/"].contains(where: { path.hasPrefix($0) }) {
                spellings.append("/private" + path)
            }
        }
        var seen: Set<String> = []
        return spellings.filter { seen.insert($0).inserted }
    }
}

/// App-equivalent ignore evaluation for one workspace root, built with `IgnoreLayerAssembly`.
///
/// A root that contains `.git` is treated as a Git work-tree root (mandatory `.gitignore` floor).
/// Roots nested inside a repository do not yet load their ancestors' `.gitignore` files.
private final class HeadlessIgnoreEvaluator: @unchecked Sendable {
    private let rootPath: String
    private let configuration: DomainIgnoreConfiguration
    private let policy: IgnoreRulePolicy
    private let rootRules: IgnoreRules
    private let lock = NSLock()
    private var rulesByDirectory: [String: IgnoreRules] = [:]

    init(rootPath: String, configuration: DomainIgnoreConfiguration) {
        self.rootPath = rootPath
        self.configuration = configuration
        let isGitRoot = FileManager.default.fileExists(atPath: rootPath + "/.git")
        if isGitRoot, let prefix = try? IgnoreRepositoryRootPrefix("") {
            policy = .gitRoot(repositoryRelativeRootPrefix: prefix)
        } else {
            policy = .nonGitRoot
        }
        let authority = IgnoreLayerAssembly.compileRootAuthority(
            gitignoreContent: Self.content(at: rootPath + "/.gitignore"),
            globalIgnoreContent: configuration.globalPatterns,
            repoIgnoreContent: configuration.respectRepoIgnore ? Self.content(at: rootPath + "/.repo_ignore") : nil,
            cursorignoreContent: configuration.respectCursorignore ? Self.content(at: rootPath + "/.cursorignore") : nil
        )
        rootRules = IgnoreLayerAssembly.makeRootRules(
            authority: authority,
            respectRepoIgnore: configuration.respectRepoIgnore,
            respectCursorignore: configuration.respectCursorignore,
            policy: policy
        )
    }

    func admits(_ relativePath: String, isDirectory: Bool) -> Bool {
        !rules(forDirectory: Self.parent(of: relativePath)).isIgnored(
            relativePath: relativePath,
            isDirectory: isDirectory
        )
    }

    /// Whether an ignored directory must still be traversed because a negation may re-include
    /// something beneath it.
    func requiresTraversal(_ relativePath: String) -> Bool {
        rules(forDirectory: Self.parent(of: relativePath)).requiresTraversal(for: relativePath)
    }

    private func rules(forDirectory relativeDirectory: String) -> IgnoreRules {
        guard configuration.hierarchicalIgnores, !relativeDirectory.isEmpty else { return rootRules }
        if let cached = lock.withLock({ rulesByDirectory[relativeDirectory] }) {
            return cached
        }
        let parentRules = rules(forDirectory: Self.parent(of: relativeDirectory))
        let directoryPath = rootPath + "/" + relativeDirectory
        let gitignore = Self.content(at: directoryPath + "/.gitignore")
        let repoIgnore = configuration.respectRepoIgnore ? Self.content(at: directoryPath + "/.repo_ignore") : nil
        let cursorignore = configuration.respectCursorignore ? Self.content(at: directoryPath + "/.cursorignore") : nil
        let resolved = gitignore == nil && repoIgnore == nil && cursorignore == nil
            ? parentRules
            : IgnoreLayerAssembly.appendingDirectoryLayers(
                to: parentRules,
                policy: policy,
                directoryRelativePath: relativeDirectory,
                gitignoreContent: gitignore,
                repoIgnoreContent: repoIgnore,
                cursorignoreContent: cursorignore
            )
        lock.withLock { rulesByDirectory[relativeDirectory] = resolved }
        return resolved
    }

    private static func parent(of relativePath: String) -> String {
        guard let slash = relativePath.lastIndex(of: "/") else { return "" }
        return String(relativePath[..<slash])
    }

    private static func content(at path: String) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }
}
