import Darwin
import Foundation
import MCP

/// A selected file admitted by the frozen workspace's explicit-read authority.
package struct ContextBuilderDiscoveryAuthorizedPath: Equatable, Sendable {
    /// Absolute path spelled under the frozen physical root that owns it.
    package let absolutePath: String
    /// The spelling shown to the provider, the client, and the pack. With one root it is
    /// root-relative. With several it is `<root label>/<relative path>` when that spelling resolves
    /// back to exactly this file, and the absolute path otherwise. `authorize` accepts it.
    package let displayPath: String
    package let byteCount: Int
}

/// The read-only view a discovery run explores. Every read is served from the frozen snapshot's
/// roots through the canonical headless read service (the same bounds, ignore layers, and symlink
/// policy as `read_file`, `file_search`, `get_file_tree`, and `get_code_structure`), and the
/// adapter's mutation hook always refuses. Selected paths are admitted through
/// `HeadlessReadAuthority`, the headless explicit-read authority.
///
/// Path spellings round-trip. Every path discovery shows (search results, tree headings, the staged
/// selection, selected paths, pack provenance) is accepted back by `authorize` and by the read
/// tools, and names the same file. With several roots, a relative spelling may lead with a root's
/// label (its folder name, or its full path when another root shares the folder name). A spelling
/// that could name two different entries is refused as `ambiguous_across_roots`, never guessed.
package struct ContextBuilderFrozenWorkspace: Sendable {
    package static let readToolNames: Set<String> = [
        "get_file_tree",
        "file_search",
        "read_file",
        "get_code_structure"
    ]

    package let snapshot: ContextBuilderDiscoverySnapshot
    private let resolvePath: DomainCanonicalWorkspaceAdapter.ResolvePath
    private let ignoreConfiguration: DomainCanonicalWorkspaceAdapter.IgnoreConfigurationProvider?
    /// Kernel-canonical spelling of each root at freeze time, compared again before the commit.
    private let frozenCanonicalRoots: [String?]

    package init(
        snapshot: ContextBuilderDiscoverySnapshot,
        resolvePath: @escaping DomainCanonicalWorkspaceAdapter.ResolvePath,
        ignoreConfiguration: DomainCanonicalWorkspaceAdapter.IgnoreConfigurationProvider? = nil
    ) {
        self.snapshot = snapshot
        self.resolvePath = resolvePath
        self.ignoreConfiguration = ignoreConfiguration
        frozenCanonicalRoots = snapshot.roots.map { Self.canonicalDirectory($0.path) }
    }

    /// The `skip_symlinks` policy the explicit-read authority applies (default on, as in the app).
    package func skipsSymlinks() async -> Bool {
        await ignoreConfiguration?()?.skipSymlinks ?? true
    }

    /// Runs one allowed read tool against the frozen snapshot and renders its result as text.
    /// `stagedSelection` stands in for the context selection, so `get_code_structure` without
    /// `paths` describes what the run has staged so far.
    package func executeRead(
        tool: String,
        arguments: [String: Value],
        stagedSelection: [String]
    ) async throws -> String {
        guard Self.readToolNames.contains(tool) else {
            throw MCPError.invalidParams("\(tool) is not a discovery read tool")
        }
        let arguments = try resolvingPathArguments(of: tool, in: arguments)
        let frozen = DomainCanonicalWorkspaceSnapshot(
            identity: snapshot.identity,
            roots: snapshot.roots,
            prompt: snapshot.prompt,
            selection: stagedSelection
        )
        var presentPath: DomainCanonicalWorkspaceAdapter.PresentPath?
        if snapshot.roots.count > 1 {
            let workspace = self
            presentPath = { url, _ in workspace.presentedPath(of: url) }
        }
        let service = MCPDomainCanonicalWorkspaceService(adapter: DomainCanonicalWorkspaceAdapter(
            toolSnapshot: { _ in frozen },
            readSnapshot: { _ in frozen },
            mutate: { _, _ in throw ContextBuilderDiscoveryError.readOnlyWorkspace },
            resolvePath: resolvePath,
            ignoreConfiguration: ignoreConfiguration,
            presentPath: presentPath
        ))
        let request = try DomainPhysicalReadRequest(
            request: DomainPhysicalToolRequest(
                argumentsJSON: JSONEncoder().encode(arguments),
                securityContext: nil
            ),
            context: DomainReadInvocationContext(handle: nil, connectionID: nil, refreshesDomainRouting: false),
            sideEffects: MCPDomainReadSideEffectEmitter { _, _, _, _, _ in
                throw ContextBuilderDiscoveryError.readOnlyWorkspace
            }
        )
        let result: DomainPhysicalToolResult = switch tool {
        case "get_file_tree":
            try await service.renderFileTree(request)
        case "file_search":
            try await service.searchFiles(request)
        case "read_file":
            try await service.readFile(request)
        default:
            try await service.inspectCodeStructure(request)
        }
        let value = try JSONDecoder().decode(Value.self, from: result.json)
        if case let .string(text) = value { return text }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try String(decoding: encoder.encode(value), as: UTF8.self)
    }

    /// Admits `rawPath` as a selectable file: inside one frozen root (see the type's spelling rules),
    /// not a symbolic link and without a symlinked component (per the `skip_symlinks` policy),
    /// canonically contained, a regular file, and within the read limit.
    package func authorize(
        _ rawPath: String,
        skipSymlinks: Bool
    ) throws -> ContextBuilderDiscoveryAuthorizedPath {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0") else {
            throw ContextBuilderDiscoveryError.invalidSelectedPath(path: rawPath, reason: "empty_path")
        }
        let logical: String
        do {
            logical = try resolveSpelling(trimmed)
        } catch is AmbiguousSpelling {
            throw ContextBuilderDiscoveryError.invalidSelectedPath(path: rawPath, reason: "ambiguous_across_roots")
        }
        guard let owner = owningRoot(of: logical) else {
            throw ContextBuilderDiscoveryError.invalidSelectedPath(path: rawPath, reason: "outside_root")
        }
        let target: HeadlessReadAuthority.Target
        do {
            target = try HeadlessReadAuthority.authorize(rawPath: logical, roots: snapshot.roots, skipSymlinks: skipSymlinks)
        } catch {
            throw ContextBuilderDiscoveryError.invalidSelectedPath(path: rawPath, reason: Self.reason(error))
        }
        var status = stat()
        guard lstat(logical, &status) == 0 else {
            throw ContextBuilderDiscoveryError.invalidSelectedPath(path: rawPath, reason: "not_found")
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw ContextBuilderDiscoveryError.invalidSelectedPath(path: rawPath, reason: "not_a_regular_file")
        }
        let byteCount: Int
        do {
            byteCount = try HeadlessReadAuthority.containedRegularFileSize(target)
        } catch {
            throw ContextBuilderDiscoveryError.invalidSelectedPath(path: rawPath, reason: Self.reason(error))
        }
        guard byteCount <= MCPDomainCanonicalReadBounds.maximumReadFileBytes else {
            throw ContextBuilderDiscoveryError.invalidSelectedPath(path: rawPath, reason: "file_too_large")
        }
        let root = snapshot.roots[owner.rootIndex]
        let absolutePath = owner.relativePath.isEmpty ? root.path : root.path + "/" + owner.relativePath
        return ContextBuilderDiscoveryAuthorizedPath(
            absolutePath: absolutePath,
            displayPath: displayPath(rootIndex: owner.rootIndex, relativePath: owner.relativePath),
            byteCount: byteCount
        )
    }

    /// Reads an admitted file for the pack through the contained `O_NOFOLLOW` walk. `limit` is the
    /// remaining pack budget in bytes; a larger file fails closed.
    package func readForPack(
        _ path: ContextBuilderDiscoveryAuthorizedPath,
        skipSymlinks: Bool,
        limit: Int
    ) throws -> String {
        let target: HeadlessReadAuthority.Target
        do {
            target = try HeadlessReadAuthority.authorize(
                rawPath: path.absolutePath,
                roots: snapshot.roots,
                skipSymlinks: skipSymlinks
            )
        } catch {
            throw ContextBuilderDiscoveryError.invalidSelectedPath(path: path.displayPath, reason: Self.reason(error))
        }
        let data: Data
        do {
            data = try HeadlessReadAuthority.readContained(
                target,
                limit: min(limit, MCPDomainCanonicalReadBounds.maximumReadFileBytes)
            )
        } catch let error as MCPDomainCanonicalReadError {
            if case let .fileTooLarge(byteCount, _) = error {
                throw ContextBuilderDiscoveryError.packBudgetExceeded(bytes: byteCount, limit: limit)
            }
            throw ContextBuilderDiscoveryError.invalidSelectedPath(path: path.displayPath, reason: error.code)
        } catch {
            throw ContextBuilderDiscoveryError.invalidSelectedPath(path: path.displayPath, reason: Self.reason(error))
        }
        do {
            return try HeadlessReadAuthority.decodeText(data)
        } catch {
            throw ContextBuilderDiscoveryError.invalidSelectedPath(path: path.displayPath, reason: "undecodable_text")
        }
    }

    /// Fails closed when a frozen root disappeared, stopped being a directory, or now resolves to a
    /// different canonical directory.
    package func revalidateRoots() throws {
        for (root, frozen) in zip(snapshot.roots, frozenCanonicalRoots) {
            guard let frozen, Self.canonicalDirectory(root.path) == frozen else {
                throw ContextBuilderDiscoveryError.contextChanged("workspace root \(root.path) changed")
            }
        }
    }

    /// Display names for the frozen roots, as shown to the provider.
    package var rootDisplayNames: [String] {
        guard snapshot.roots.count > 1 else { return snapshot.roots.map(\.path) }
        return snapshot.roots.indices.map { rootLabel($0) }
    }

    /// The discovery spelling of an enumerated file or directory, or nil outside every root.
    /// Used for `file_search` results and tree headings when there are several roots.
    func presentedPath(of url: URL) -> String? {
        let logical = url.standardizedFileURL.path
        for (index, root) in snapshot.roots.enumerated()
            where HeadlessPathSpelling.equivalentPaths(root).contains(logical)
        {
            return rootLabel(index)
        }
        guard let owner = owningRoot(of: logical) else { return nil }
        return displayPath(rootIndex: owner.rootIndex, relativePath: owner.relativePath)
    }

    private func displayPath(rootIndex: Int, relativePath: String) -> String {
        guard snapshot.roots.count > 1 else { return relativePath }
        let absolute = URL(fileURLWithPath: snapshot.roots[rootIndex].path + "/" + relativePath).standardizedFileURL.path
        let qualified = rootLabel(rootIndex) + "/" + relativePath
        // The short spelling is shown only when it resolves back to exactly this entry; otherwise
        // (another root holds `<label>/<relative path>` itself) the absolute path is shown.
        return (try? resolveSpelling(qualified)) == absolute ? qualified : absolute
    }

    private struct AmbiguousSpelling: Error {
        let candidates: [String]
    }

    /// The logical absolute path a spelling names. An absolute spelling is standardized. A relative
    /// one is read under every root, and, with several roots, also as `<root label>/<rest>`; the
    /// readings that exist must all be one entry (`AmbiguousSpelling` otherwise). When none exists,
    /// the root-qualified reading (else the first root's) is returned for the caller to refuse.
    private func resolveSpelling(_ trimmed: String) throws -> String {
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL.path
        }
        var readings: [String] = []
        if snapshot.roots.count > 1 {
            for (index, root) in snapshot.roots.enumerated() {
                let label = rootLabel(index)
                // A full-path label is an absolute spelling, handled above.
                guard !label.hasPrefix("/") else { continue }
                if trimmed == label {
                    readings.append(root.path)
                } else if trimmed.hasPrefix(label + "/") {
                    readings.append(root.path + "/" + trimmed.dropFirst(label.count + 1))
                }
            }
        }
        readings += snapshot.roots.map { $0.path + "/" + trimmed }
        var seen: Set<String> = []
        readings = readings.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            .filter { seen.insert($0).inserted }
        var existing: [(path: String, device: dev_t, inode: ino_t)] = []
        for reading in readings {
            var status = stat()
            guard lstat(reading, &status) == 0,
                  !existing.contains(where: { $0.device == status.st_dev && $0.inode == status.st_ino })
            else { continue }
            existing.append((reading, status.st_dev, status.st_ino))
        }
        guard existing.count <= 1 else { throw AmbiguousSpelling(candidates: existing.map(\.path)) }
        return existing.first?.path ?? readings.first ?? trimmed
    }

    /// Resolves the path arguments of a read tool to absolute paths when there are several roots,
    /// so a root-qualified spelling reads the file it names. Ambiguous spellings are refused with
    /// their unambiguous alternatives; spellings that name nothing are left to the read tool's own
    /// errors.
    private func resolvingPathArguments(of tool: String, in arguments: [String: Value]) throws -> [String: Value] {
        guard snapshot.roots.count > 1 else { return arguments }
        func resolved(_ raw: String) throws -> String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else { return raw }
            let logical: String
            do {
                logical = try resolveSpelling(trimmed)
            } catch let error as AmbiguousSpelling {
                throw MCPError.invalidParams(
                    "ambiguous_across_roots: '\(trimmed)' names more than one entry; use one of: "
                        + error.candidates.joined(separator: ", ")
                )
            }
            var status = stat()
            return lstat(logical, &status) == 0 ? logical : raw
        }
        var arguments = arguments
        switch tool {
        case "read_file", "get_file_tree":
            if let raw = arguments["path"]?.stringValue {
                arguments["path"] = try .string(resolved(raw))
            }
        case "get_code_structure":
            if case let .array(items)? = arguments["paths"] {
                arguments["paths"] = try .array(items.map { item in
                    guard case let .string(raw) = item else { return item }
                    return try .string(resolved(raw))
                })
            }
        default:
            break
        }
        return arguments
    }

    /// The root's folder name, or its full path when another root shares the folder name.
    private func rootLabel(_ index: Int) -> String {
        let name = snapshot.roots[index].lastPathComponent
        let shared = snapshot.roots.enumerated().contains { $0.offset != index && $0.element.lastPathComponent == name }
        return shared ? snapshot.roots[index].path : name
    }

    private func owningRoot(of logicalPath: String) -> (rootIndex: Int, relativePath: String)? {
        for (index, root) in snapshot.roots.enumerated() {
            for spelling in HeadlessPathSpelling.equivalentPaths(root) where logicalPath.hasPrefix(spelling + "/") {
                return (index, String(logicalPath.dropFirst(spelling.count + 1)))
            }
        }
        return nil
    }

    private static func canonicalDirectory(_ path: String) -> String? {
        var status = stat()
        guard stat(path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR,
              let resolved = realpath(path, nil)
        else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func reason(_ error: Error) -> String {
        if let error = error as? MCPDomainCanonicalReadError { return error.code }
        if let error = error as? POSIXError, error.code == .ENOENT { return "not_found" }
        if let error = error as? ContextBuilderDiscoveryError {
            if case let .invalidSelectedPath(_, reason) = error { return reason }
            return error.code
        }
        return "unreadable"
    }
}
