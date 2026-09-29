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

    /// Presents an enumerated file or directory to the caller. `rootRelativePath` is the path the
    /// service matches against ("" for a root itself). Returning nil keeps the default rendering:
    /// the root-relative path in `file_search` results, the base's folder name as a tree heading.
    package typealias PresentPath = @Sendable (_ url: URL, _ rootRelativePath: String) -> String?

    package let toolSnapshot: ToolSnapshot
    package let readSnapshot: ReadSnapshot
    package let mutate: Mutate
    package let resolvePath: ResolvePath
    /// When present, enumeration applies the app's ignore layers; when nil, enumeration keeps the
    /// legacy hidden-file-only filtering.
    package let ignoreConfiguration: IgnoreConfigurationProvider?
    /// Nil for the ordinary headless tools. Context Builder discovery sets it so every path it
    /// shows is a spelling its selection authority resolves back to the same file.
    package let presentPath: PresentPath?

    package init(
        toolSnapshot: @escaping ToolSnapshot,
        readSnapshot: @escaping ReadSnapshot,
        mutate: @escaping Mutate,
        resolvePath: @escaping ResolvePath,
        ignoreConfiguration: IgnoreConfigurationProvider? = nil,
        presentPath: PresentPath? = nil
    ) {
        self.toolSnapshot = toolSnapshot
        self.readSnapshot = readSnapshot
        self.mutate = mutate
        self.resolvePath = resolvePath
        self.ignoreConfiguration = ignoreConfiguration
        self.presentPath = presentPath
    }
}

/// Ignore inputs for headless enumeration: the app's effective global defaults and the
/// respect/hierarchical switches, matching the app crawl's defaults when settings are unset.
package struct DomainIgnoreConfiguration: Equatable {
    package let globalPatterns: String
    package let respectRepoIgnore: Bool
    package let respectCursorignore: Bool
    package let hierarchicalIgnores: Bool
    /// The app crawl's `skip_symlinks` policy (default on): skip every symlink, or follow links
    /// with the app's cycle guard. See `HeadlessDirectoryWalk`.
    package let skipSymlinks: Bool

    package init(
        globalPatterns: String,
        respectRepoIgnore: Bool = true,
        respectCursorignore: Bool = true,
        hierarchicalIgnores: Bool = true,
        skipSymlinks: Bool = true
    ) {
        self.globalPatterns = globalPatterns
        self.respectRepoIgnore = respectRepoIgnore
        self.respectCursorignore = respectCursorignore
        self.hierarchicalIgnores = hierarchicalIgnores
        self.skipSymlinks = skipSymlinks
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
    /// Per-file code-map read cap: the syntax engine refuses larger UTF-8 sources as oversize, so
    /// nothing beyond it (plus a byte-order mark) is ever read.
    package static let maximumCodeStructureFileBytes = CodeMapSyntaxEngine.parseUTF8Limit + 3
    /// Aggregate source bytes one `get_code_structure` call may read; files past it are reported
    /// `budget_exhausted` without being read.
    package static let maximumCodeStructureSourceBytes = 64_000_000
}

package enum MCPDomainCanonicalReadError: Error, Equatable, LocalizedError {
    case fileTooLarge(byteCount: Int, limit: Int)
    case undecodableText
    case notARegularFile
    /// A root's ignore rules could not be established (ambiguous Git topology or an unreadable
    /// mandatory `.gitignore`), so enumeration fails closed rather than apply the wrong rules.
    case ignoreRulesUnavailable(root: String)
    /// Explicit-read refusals mirroring the app's `CatalogRegularFileIneligibilityReason` (see
    /// `HeadlessReadAuthority`): ignore rules never refuse an explicit read, these do.
    case symbolicLinkPath
    case symlinkComponent
    case outsideCanonicalRoot
    case outsideRoot
    /// A path component became a symlink or stopped being a directory after authorization.
    case pathChangedDuringRead
    /// The caller's aggregate source-byte budget could not admit the file; nothing was read.
    case readBudgetExhausted

    /// Stable machine-readable code for per-item diagnostics.
    package var code: String {
        switch self {
        case .fileTooLarge: "file_too_large"
        case .undecodableText: "undecodable_text"
        case .notARegularFile: "not_a_regular_file"
        case .ignoreRulesUnavailable: "ignore_rules_unavailable"
        case .symbolicLinkPath: "symbolic_link_path"
        case .symlinkComponent: "symlink_component"
        case .outsideCanonicalRoot: "outside_canonical_root"
        case .outsideRoot: "outside_root"
        case .pathChangedDuringRead: "path_changed_during_read"
        case .readBudgetExhausted: "read_budget_exhausted"
        }
    }

    package var errorDescription: String? {
        switch self {
        case let .fileTooLarge(byteCount, limit):
            "File is \(byteCount) bytes, which exceeds the \(limit)-byte read limit."
        case .undecodableText:
            "File is not UTF-8 or UTF-16 text."
        case .notARegularFile:
            "Path is not a regular file."
        case let .ignoreRulesUnavailable(root):
            "Ignore rules for \(root) could not be resolved (ambiguous Git topology or unreadable .gitignore)."
        case .symbolicLinkPath:
            "Path is a symbolic link."
        case .symlinkComponent:
            "Path contains a symbolic-link component."
        case .outsideCanonicalRoot:
            "Canonical path is outside the workspace root."
        case .outsideRoot:
            "Path is outside the workspace root."
        case .pathChangedDuringRead:
            "Path changed during the read (a component became a symbolic link); the read was refused."
        case .readBudgetExhausted:
            "The request's source-byte budget is exhausted; the file was not read."
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
        // The adapter's resolution keeps its own path errors; each file's bytes are then read only
        // through the explicit-read authority (see `codeStructureResults`).
        let resolved = try requested.prefix(limit).map { raw in
            try (raw: raw, url: adapter.resolvePath(raw, snapshot.roots, false))
        }
        let ignoreContext = try await makeIgnoreContext(roots: snapshot.roots)
        let skipSymlinks = await adapter.ignoreConfiguration?()?.skipSymlinks ?? true
        let roots = snapshot.roots
        let (files, truncated) = try await Self.runCancellableBlocking { cancellation in
            var candidates: [CodeStructureCandidate] = []
            var truncated = false
            for (raw, url) in resolved {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    let scan = try Self.forEachFile(
                        under: [url],
                        ignore: ignoreContext,
                        cancellation: cancellation
                    ) { file, _ in
                        guard CodeMapSyntaxEngine.supportsCodeMap(fileExtension: file.pathExtension) else { return true }
                        candidates.append(CodeStructureCandidate(authorizationPath: file.path, displayPath: file.path))
                        return candidates.count < limit
                    }
                    truncated = truncated || scan.stoppedEarly
                } else if CodeMapSyntaxEngine.supportsCodeMap(fileExtension: url.pathExtension) {
                    candidates.append(CodeStructureCandidate(authorizationPath: raw, displayPath: url.path))
                }
                if candidates.count >= limit {
                    truncated = truncated || raw != resolved.last?.raw
                    break
                }
            }
            let results = try Self.codeStructureResults(
                for: Array(candidates.prefix(limit)),
                roots: roots,
                skipSymlinks: skipSymlinks,
                sourceByteBudget: MCPDomainCanonicalReadBounds.maximumCodeStructureSourceBytes,
                checkCancellation: { try cancellation.check() }
            )
            return (results.files, truncated || results.budgetExhausted || requested.count > limit)
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
        let ignoreContext = try await makeIgnoreContext(roots: snapshot.roots)
        let relativeRoots = Self.relativeRoots(snapshot.roots)
        let headings = roots.map { base in
            let relative = snapshot.roots.contains(where: { $0.standardizedFileURL.path == base.standardizedFileURL.path })
                ? ""
                : Self.relativePath(base, roots: relativeRoots)
            return (adapter.presentPath?(base, relative) ?? base.lastPathComponent) + "/"
        }
        let lines = try await Self.runCancellableBlocking { cancellation in
            var lines: [String] = []
            for (root, heading) in zip(roots, headings) {
                let remaining = MCPDomainCanonicalReadBounds.maximumTreeLines - lines.count
                guard remaining > 0 else { break }
                try lines.append(contentsOf: Self.treeLines(
                    root: root,
                    heading: heading,
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
        // The adapter's resolution keeps its own path errors (outside the workspace, ambiguous
        // relative path); the read itself goes through the app-equivalent explicit-read authority.
        _ = try adapter.resolvePath(rawPath, snapshot.roots, false)
        let skipSymlinks = await adapter.ignoreConfiguration?()?.skipSymlinks ?? true
        let roots = snapshot.roots
        let text = try await Self.runCancellableBlocking { _ in
            try HeadlessReadAuthority.readText(
                rawPath: rawPath,
                roots: roots,
                skipSymlinks: skipSymlinks,
                limit: MCPDomainCanonicalReadBounds.maximumReadFileBytes
            )
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
        // Trimmed like the app provider, so a whitespace-only pattern is empty.
        let pattern = (args["pattern"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else {
            throw MCPError.invalidParams("pattern cannot be empty")
        }
        let maxResults = FileSearchResultLimits.effectiveMaxResults(args["max_results"]?.intValue)
        let countOnly = args["count_only"]?.boolValue == true
        // Regex auto-detection and `auto` mode share the app's heuristics.
        let regexEnabled = args["regex"]?.boolValue ?? FileSearchPatternHeuristics.containsRegexSyntax(pattern)
        let wholeWord = args["whole_word"]?.boolValue ?? false
        let mode = (args["mode"]?.stringValue ?? "auto").lowercased()
        guard ["auto", "path", "content", "both"].contains(mode) else {
            throw MCPError.invalidParams("mode must be auto, path, content, or both")
        }
        let inferred = mode == "auto" ? FileSearchPatternHeuristics.inferredAutoMode(pattern) : nil
        let searchesPaths = mode == "path" || mode == "both" || inferred == .path || inferred == .both
        let searchesContent = mode == "content" || mode == "both" || inferred == .content || inferred == .both
        let contentRegexPattern = wholeWord ? "\\b(?:\(pattern))\\b" : pattern
        // The app runs every MCP search case-insensitively, regex included. Only the content stage
        // rejects an uncompilable regex (a documented divergence: the app repairs it); the path stage
        // falls back to glob/literal matching like the app. Validate once here; the blocking scan
        // compiles its own instances.
        if searchesContent, regexEnabled {
            _ = try NSRegularExpression(pattern: contentRegexPattern, options: .caseInsensitive)
        }
        let filter = Self.searchFilter(args)
        let relativeRoots = Self.relativeRoots(snapshot.roots)
        let roots = snapshot.roots
        let presentPath = adapter.presentPath
        let ignoreContext = try await makeIgnoreContext(roots: roots)
        let (results, count, enumerationTruncated, skippedLargeFiles) = try await Self.runCancellableBlocking { cancellation in
            // Like the app, each stage scans every admitted file in full-path order (the path stage by
            // UTF-8 bytes, the content stage by `String` order) and keeps the first `max_results` hits,
            // so a cap never depends on directory walk order. `count_only` counts every content match
            // (path hits stay capped).
            var candidates: [SearchCandidate] = []
            let scan = try Self.forEachFile(under: roots, ignore: ignoreContext, cancellation: cancellation) { file, byteCount in
                let relative = Self.relativePath(file, roots: relativeRoots)
                if Self.includes(relativePath: relative, file: file, filter: filter) {
                    candidates.append(SearchCandidate(
                        file: file,
                        fullPath: file.standardizedFileURL.path,
                        relativePath: relative,
                        byteCount: byteCount
                    ))
                }
                return true
            }
            var results: [Value] = []
            var pathCount = 0
            if searchesPaths {
                let matcher = PathStageMatcher(pattern: pattern, isRegex: regexEnabled)
                for candidate in candidates.sorted(by: { $0.fullPath.utf8.lexicographicallyPrecedes($1.fullPath.utf8) }) {
                    guard pathCount < maxResults else { break }
                    try cancellation.check()
                    guard matcher.matches(candidate.relativePath) else { continue }
                    pathCount += 1
                    if !countOnly {
                        let shown = presentPath?(candidate.file, candidate.relativePath) ?? candidate.relativePath
                        results.append(.object(["path": .string(shown)]))
                    }
                }
            }
            var contentCount = 0
            var skippedLargeFiles = 0
            if searchesContent {
                // A literal whole-word pattern matches as an escaped `\b...\b` regex, compiled once.
                let regex: NSRegularExpression?
                if regexEnabled {
                    regex = try NSRegularExpression(pattern: contentRegexPattern, options: .caseInsensitive)
                } else if wholeWord {
                    regex = try? NSRegularExpression(
                        pattern: "\\b\(NSRegularExpression.escapedPattern(for: pattern))\\b",
                        options: .caseInsensitive
                    )
                } else {
                    regex = nil
                }
                scanning: for candidate in candidates.sorted(by: { $0.fullPath < $1.fullPath }) {
                    guard countOnly || contentCount < maxResults else { break }
                    try cancellation.check()
                    if let byteCount = candidate.byteCount, byteCount > MCPDomainCanonicalReadBounds.maximumSearchFileBytes {
                        skippedLargeFiles += 1
                        continue
                    }
                    guard let text = try? Self.readText(
                        at: candidate.file,
                        limit: MCPDomainCanonicalReadBounds.maximumSearchFileBytes
                    ) else { continue }
                    for (index, line) in FileSearchLines.lines(of: text).enumerated() {
                        guard Self.contentLineMatches(pattern, line: line, regex: regex) else {
                            continue
                        }
                        contentCount += 1
                        if countOnly { continue }
                        results.append(.object([
                            "path": .string(presentPath?(candidate.file, candidate.relativePath) ?? candidate.relativePath),
                            "line": .int(index + 1),
                            "text": .string(String(line))
                        ]))
                        if contentCount >= maxResults { break scanning }
                    }
                }
            }
            return (results, pathCount + contentCount, scan.enumerationLimitReached, skippedLargeFiles)
        }
        var bounds: [String: Value] = [:]
        if enumerationTruncated { bounds["truncated"] = .bool(true) }
        if skippedLargeFiles > 0 { bounds["skipped_large_files"] = .int(skippedLargeFiles) }
        if countOnly {
            return try .object(["count": .int(count)].merging(bounds) { current, _ in current })
        }
        return try .object(
            ["matches": .array(results), "count": .int(count)].merging(bounds) { current, _ in current }
        )
    }

    /// A filtered file admitted to both search stages. `fullPath` is the standardized logical path the
    /// stages sort by, like the app's `fullPath`.
    private struct SearchCandidate {
        let file: URL
        let fullPath: String
        let relativePath: String
        let byteCount: Int?
    }

    /// The app's path stage (`FileSearchActor.searchPaths`): a `regex` request whose pattern is only glob
    /// wildcards is a glob, an uncompilable path regex falls back to glob/literal matching, a glob is
    /// retried with its friendly candidates, only `*` and `?` are wildcards, and `whole_word` does not
    /// apply. Matching is case-insensitive against the root-relative path.
    private struct PathStageMatcher {
        private enum Strategy {
            case regex(NSRegularExpression)
            case glob([String])
            case literal
        }

        private let pattern: String
        private let strategy: Strategy

        init(pattern: String, isRegex: Bool) {
            self.pattern = pattern
            if FileSearchPatternHeuristics.pathStageUsesRegex(pattern, isRegex: isRegex),
               let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            {
                strategy = .regex(regex)
            } else if FileSearchPatternHeuristics.hasPathWildcards(pattern) {
                strategy = .glob(FileSearchPatternHeuristics.pathGlobCandidates(for: pattern))
            } else {
                strategy = .literal
            }
        }

        func matches(_ relativePath: String) -> Bool {
            switch strategy {
            case let .regex(regex):
                regex.firstMatch(in: relativePath, range: NSRange(relativePath.startIndex..., in: relativePath)) != nil
            case let .glob(candidates):
                candidates.contains { MCPDomainCanonicalWorkspaceService.globMatches($0, relativePath) }
            case .literal:
                relativePath.localizedCaseInsensitiveContains(pattern)
            }
        }
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

    /// A code-structure input: the path the read authority checks (the caller's logical path for an
    /// explicit file, the enumerated logical path for a directory member) and the path reported.
    struct CodeStructureCandidate: Equatable {
        let authorizationPath: String
        let displayPath: String
    }

    /// Fault-isolated, bounded code maps. Each file is read only through `HeadlessReadAuthority`
    /// (the `read_file` gates plus the no-follow canonical read), capped at
    /// `maximumCodeStructureFileBytes`, and charged against `sourceByteBudget` before any byte is
    /// read. A refusal, a missing or unreadable file, an oversize or undecodable source, or a
    /// code-map failure becomes that file's diagnostic; only cancellation ends the call. Once the
    /// budget refuses a file, every later file is reported `budget_exhausted` without being read.
    static func codeStructureResults(
        for candidates: [CodeStructureCandidate],
        roots: [URL],
        skipSymlinks: Bool,
        sourceByteBudget: Int,
        checkCancellation: () throws -> Void
    ) throws -> (files: [Value], budgetExhausted: Bool) {
        var remaining = sourceByteBudget
        var budgetExhausted = false
        var files: [Value] = []
        files.reserveCapacity(candidates.count)
        for candidate in candidates {
            try checkCancellation()
            let path = Value.string(candidate.displayPath)
            func diagnostic(_ code: String, reason: String? = nil) -> Value {
                var object: [String: Value] = ["path": path, "diagnostic": .string(code)]
                if let reason { object["reason"] = .string(reason) }
                return .object(object)
            }
            guard !budgetExhausted else {
                files.append(diagnostic("budget_exhausted"))
                continue
            }
            let data: Data
            do {
                let target = try HeadlessReadAuthority.authorize(
                    rawPath: candidate.authorizationPath,
                    roots: roots,
                    skipSymlinks: skipSymlinks
                )
                data = try HeadlessReadAuthority.readContained(
                    target,
                    limit: MCPDomainCanonicalReadBounds.maximumCodeStructureFileBytes
                ) { size in
                    guard size <= remaining else { return false }
                    remaining -= size
                    return true
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch MCPDomainCanonicalReadError.fileTooLarge {
                files.append(diagnostic("source_oversize"))
                continue
            } catch MCPDomainCanonicalReadError.readBudgetExhausted {
                budgetExhausted = true
                files.append(diagnostic("budget_exhausted"))
                continue
            } catch let error as MCPDomainCanonicalReadError {
                files.append(diagnostic("read_refused", reason: error.code))
                continue
            } catch let error as POSIXError where error.code == .ENOENT {
                files.append(diagnostic("missing"))
                continue
            } catch {
                files.append(diagnostic("unreadable"))
                continue
            }
            do {
                try files.append(codeMapResult(data: data, displayPath: candidate.displayPath))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                files.append(diagnostic("codemap_failed"))
            }
        }
        return (files, budgetExhausted)
    }

    private static func codeMapResult(data: Data, displayPath: String) throws -> Value {
        let url = URL(fileURLWithPath: displayPath)
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
        return try HeadlessReadAuthority.decodeText(data)
    }

    private func makeIgnoreContext(roots: [URL]) async throws -> HeadlessIgnoreContext? {
        guard let configuration = await adapter.ignoreConfiguration?() else { return nil }
        return try HeadlessIgnoreContext(roots: roots, configuration: configuration)
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
            if let located = ignore?.locate(root) {
                try forEachConfiguredFile(
                    under: root,
                    located: located,
                    visited: &visited,
                    scan: &scan,
                    cancellation: cancellation,
                    visit
                )
                if scan.stoppedEarly || scan.enumerationLimitReached { return scan }
                continue
            }
            // Legacy enumeration (no ignore configuration, or a base outside every root).
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                try cancellation.check()
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
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

    /// Configured enumeration: the app's ignore layers and symlink policy over logical paths.
    private static func forEachConfiguredFile(
        under base: URL,
        located: HeadlessIgnoreContext.Located,
        visited: inout Int,
        scan: inout FileScan,
        cancellation: BlockingCancellation,
        _ visit: (URL, Int?) throws -> Bool
    ) throws {
        guard !located.baseIsUnreachableUnderSymlinkPolicy() else { return }
        try located.makeWalk(cancellation: cancellation).walk(
            base: base,
            ancestorIDs: located.ancestorDirectoryIDs()
        ) { entry in
            if let decision = try located.ignoreDecision(for: entry) { return decision }
            guard entry.isRegularFile else { return .descend }
            guard visited < MCPDomainCanonicalReadBounds.maximumEnumeratedFiles else {
                scan.enumerationLimitReached = true
                return .stop
            }
            visited += 1
            guard try visit(entry.url, entry.fileSize) else {
                scan.stoppedEarly = true
                return .stop
            }
            return .descend
        }
    }

    private static func configuredTreeLines(
        root: URL,
        heading: String,
        located: HeadlessIgnoreContext.Located,
        maxDepth: Int,
        maximumLines: Int,
        cancellation: BlockingCancellation
    ) throws -> [String] {
        var lines = [heading]
        guard !located.baseIsUnreachableUnderSymlinkPolicy() else { return lines }
        try located.makeWalk(cancellation: cancellation).walk(
            base: root,
            ancestorIDs: located.ancestorDirectoryIDs()
        ) { entry in
            guard lines.count < maximumLines else { return .stop }
            if entry.depth > maxDepth { return .skipDescendants }
            if let decision = try located.ignoreDecision(for: entry) { return decision }
            lines.append(
                String(repeating: "  ", count: entry.depth) + entry.url.lastPathComponent
                    + (entry.isDirectory ? "/" : "")
            )
            return .descend
        }
        return lines
    }

    private static func treeLines(
        root: URL,
        heading: String,
        maxDepth: Int,
        maximumLines: Int,
        ignore: HeadlessIgnoreContext? = nil,
        cancellation: BlockingCancellation
    ) throws -> [String] {
        if let located = ignore?.locate(root) {
            return try configuredTreeLines(
                root: root,
                heading: heading,
                located: located,
                maxDepth: maxDepth,
                maximumLines: maximumLines,
                cancellation: cancellation
            )
        }
        // Legacy enumeration (no ignore configuration, or a base outside every root).
        var lines = [heading]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
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

    /// Content-stage line match. Like the app, a literal content pattern matches `*`, `?`, and `[` as
    /// characters; wildcards are path syntax only.
    private static func contentLineMatches(_ pattern: String, line: Substring, regex: NSRegularExpression?) -> Bool {
        guard let regex else { return line.localizedCaseInsensitiveContains(pattern) }
        let value = String(line)
        return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
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
        /// The spelling of the workspace root that `basePrefix` is relative to.
        let rootSpelling: String
        let skipSymlinks: Bool

        /// Root-relative path of an enumerated item, or nil when it cannot be attributed to the
        /// base (the caller then applies no ignore decision rather than a wrong one).
        func relativePath(of url: URL) -> String? {
            let path = url.path
            guard let basePath = basePaths.first(where: { path.hasPrefix($0 + "/") }) else { return nil }
            let local = String(path.dropFirst(basePath.count + 1))
            return basePrefix.isEmpty ? local : basePrefix + "/" + local
        }

        /// A walk with this root's symlink policy, containing followed links to its canonical root.
        func makeWalk(cancellation: BlockingCancellation) -> HeadlessDirectoryWalk {
            HeadlessDirectoryWalk(
                skipSymlinks: skipSymlinks,
                canonicalRootPath: skipSymlinks ? nil : HeadlessDirectoryWalk.canonicalPath(rootSpelling),
                skipsPackageDescendants: true,
                checkCancellation: { try cancellation.check() }
            )
        }

        /// The walk decision for an entry the ignore rules reject, or nil when it is admitted. A
        /// rejected directory is still descended when a negation beneath it requires traversal.
        func ignoreDecision(for entry: HeadlessDirectoryWalk.Entry) throws -> HeadlessDirectoryWalk.Decision? {
            guard let relative = relativePath(of: entry.url),
                  try !evaluator.admits(relative, isDirectory: entry.isDirectory)
            else { return nil }
            return try entry.isDirectory && evaluator.requiresTraversal(relative) ? .descend : .skipDescendants
        }

        /// Under `skip_symlinks` the app catalogs nothing reached through a link, so a base below
        /// the root that passes through a symlinked directory enumerates nothing (fail closed).
        func baseIsUnreachableUnderSymlinkPolicy() -> Bool {
            guard skipSymlinks else { return false }
            return basePrefixDirectories().contains { path in
                var status = stat()
                return lstat(path, &status) != 0 || status.st_mode & S_IFMT == S_IFLNK
            }
        }

        /// Directory identities from the workspace root down to the base itself, seeding the
        /// walk's cycle guard as the app seeds its `DirChain` from the root and base components.
        func ancestorDirectoryIDs() -> [HeadlessDirectoryWalk.DirectoryID] {
            guard !skipSymlinks else { return [] }
            return ([rootSpelling] + basePrefixDirectories()).compactMap(HeadlessDirectoryWalk.directoryID(atPath:))
        }

        /// Logical paths of each directory from just below the root down to the base itself.
        private func basePrefixDirectories() -> [String] {
            var path = rootSpelling
            return basePrefix.split(separator: "/").map { component in
                path += "/" + component
                return path
            }
        }
    }

    private let evaluators: [(rootPath: String, evaluator: HeadlessIgnoreEvaluator)]
    private let skipSymlinks: Bool

    init(roots: [URL], configuration: DomainIgnoreConfiguration) throws {
        skipSymlinks = configuration.skipSymlinks
        evaluators = try roots.map { root in
            let rootPath = root.standardizedFileURL.path
            return try (rootPath, HeadlessIgnoreEvaluator(rootPath: rootPath, configuration: configuration))
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
                        return Located(
                            evaluator: evaluator,
                            basePrefix: "",
                            basePaths: basePaths,
                            rootSpelling: rootSpelling,
                            skipSymlinks: skipSymlinks
                        )
                    }
                    if basePath.hasPrefix(rootSpelling + "/") {
                        return Located(
                            evaluator: evaluator,
                            basePrefix: String(basePath.dropFirst(rootSpelling.count + 1)),
                            basePaths: basePaths,
                            rootSpelling: rootSpelling,
                            skipSymlinks: skipSymlinks
                        )
                    }
                }
            }
        }
        return nil
    }

    static func equivalentPaths(_ url: URL) -> [String] {
        HeadlessPathSpelling.equivalentPaths(url)
    }
}

/// App-equivalent ignore evaluation for one workspace root, built with `IgnoreLayerAssembly`.
///
/// The policy comes from `IgnoreRulePolicy.resolvingLoadedRoot`, the app crawl's resolver: a root at
/// or inside a structurally valid Git work tree is a Git root whose chain runs from the repository
/// root down to the loaded root (ancestor `.gitignore` files are the mandatory floor), and every
/// `.gitignore` under a Git root is read through `MandatoryGitIgnoreFile`. Ambiguous topology or an
/// unreadable mandatory `.gitignore` fails closed with `ignoreRulesUnavailable`, as the app crawl
/// does, rather than enumerate with the wrong rules.
private final class HeadlessIgnoreEvaluator: @unchecked Sendable {
    private let rootPath: String
    private let configuration: DomainIgnoreConfiguration
    private let policy: IgnoreRulePolicy
    private let rootRules: IgnoreRules
    private let lock = NSLock()
    private var rulesByDirectory: [String: IgnoreRules] = [:]

    init(rootPath: String, configuration: DomainIgnoreConfiguration) throws {
        self.rootPath = rootPath
        self.configuration = configuration
        // Root-level files are read strictly, as the app's `IgnoreRulesManager` does: a present but
        // unreadable root layer fails the root closed instead of silently dropping exclusions.
        do {
            policy = try IgnoreRulePolicy.resolvingLoadedRoot(URL(fileURLWithPath: rootPath, isDirectory: true))
            if case let .gitRoot(prefix) = policy {
                rootRules = try IgnoreLayerAssembly.gitRootChain(
                    loadedPath: rootPath,
                    repositoryRelativeRootPrefix: prefix,
                    globalIgnoreContent: configuration.globalPatterns,
                    respectRepoIgnore: configuration.respectRepoIgnore,
                    respectCursorignore: configuration.respectCursorignore,
                    policy: policy,
                    loadSecondaryIfPresent: { try Self.strictContent(at: $0) }
                )
            } else {
                let authority = try IgnoreLayerAssembly.compileRootAuthority(
                    gitignoreContent: Self.strictContent(at: rootPath + "/.gitignore"),
                    globalIgnoreContent: configuration.globalPatterns,
                    repoIgnoreContent: configuration.respectRepoIgnore
                        ? Self.strictContent(at: rootPath + "/.repo_ignore") : nil,
                    cursorignoreContent: configuration.respectCursorignore
                        ? Self.strictContent(at: rootPath + "/.cursorignore") : nil
                )
                rootRules = IgnoreLayerAssembly.makeRootRules(
                    authority: authority,
                    respectRepoIgnore: configuration.respectRepoIgnore,
                    respectCursorignore: configuration.respectCursorignore,
                    policy: policy
                )
            }
        } catch {
            throw MCPDomainCanonicalReadError.ignoreRulesUnavailable(root: rootPath)
        }
    }

    func admits(_ relativePath: String, isDirectory: Bool) throws -> Bool {
        try !rules(forDirectory: Self.parent(of: relativePath)).isIgnored(
            relativePath: relativePath,
            isDirectory: isDirectory
        )
    }

    /// Whether an ignored directory must still be traversed because a negation may re-include
    /// something beneath it.
    func requiresTraversal(_ relativePath: String) throws -> Bool {
        try rules(forDirectory: Self.parent(of: relativePath)).requiresTraversal(for: relativePath)
    }

    private func rules(forDirectory relativeDirectory: String) throws -> IgnoreRules {
        guard configuration.hierarchicalIgnores, !relativeDirectory.isEmpty else { return rootRules }
        if let cached = lock.withLock({ rulesByDirectory[relativeDirectory] }) {
            return cached
        }
        let parentRules = try rules(forDirectory: Self.parent(of: relativeDirectory))
        let directoryPath = rootPath + "/" + relativeDirectory
        let gitignore = try gitignoreContent(inDirectory: directoryPath)
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

    /// A directory's `.gitignore`. Under a Git root it is Git's mandatory floor, so it is read with
    /// the app crawl's integrity checks and an unreadable file fails closed; otherwise it is an
    /// ordinary best-effort layer.
    private func gitignoreContent(inDirectory directoryPath: String) throws -> String? {
        guard policy.enforcesGitIgnoreFloor else { return Self.content(at: directoryPath + "/.gitignore") }
        let url = URL(fileURLWithPath: directoryPath, isDirectory: true).appendingPathComponent(".gitignore")
        do {
            guard try MandatoryGitIgnoreFile.exists(at: url) else { return nil }
            return try MandatoryGitIgnoreFile.load(at: url)
        } catch {
            throw MCPDomainCanonicalReadError.ignoreRulesUnavailable(root: rootPath)
        }
    }

    private static func parent(of relativePath: String) -> String {
        guard let slash = relativePath.lastIndex(of: "/") else { return "" }
        return String(relativePath[..<slash])
    }

    /// A root-level ignore file with the app crawl's root policy: absent is nil, but anything present
    /// (including a directory at that name) must read as UTF-8 text or the root fails closed.
    private static func strictContent(at path: String) throws -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    /// A nested secondary ignore file with the app crawl's per-directory policy: best effort.
    private static func content(at path: String) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }
}
