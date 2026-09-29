import Darwin
import Foundation
import MCP

/// A selected file admitted by the frozen workspace's explicit-read authority.
package struct ContextBuilderDiscoveryAuthorizedPath: Equatable, Sendable {
    /// Absolute path spelled under the frozen physical root that owns it.
    package let absolutePath: String
    /// Root-relative path, prefixed with the root's folder name when there are several roots.
    package let displayPath: String
    package let byteCount: Int
}

/// The read-only view a discovery run explores. Every read is served from the frozen snapshot's
/// roots through the canonical headless read service (the same bounds, ignore layers, and symlink
/// policy as `read_file`, `file_search`, `get_file_tree`, and `get_code_structure`), and the
/// adapter's mutation hook always refuses. Selected paths are admitted through
/// `HeadlessReadAuthority`, the headless explicit-read authority.
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
        let frozen = DomainCanonicalWorkspaceSnapshot(
            identity: snapshot.identity,
            roots: snapshot.roots,
            prompt: snapshot.prompt,
            selection: stagedSelection
        )
        let service = MCPDomainCanonicalWorkspaceService(adapter: DomainCanonicalWorkspaceAdapter(
            toolSnapshot: { _ in frozen },
            readSnapshot: { _ in frozen },
            mutate: { _, _ in throw ContextBuilderDiscoveryError.readOnlyWorkspace },
            resolvePath: resolvePath,
            ignoreConfiguration: ignoreConfiguration
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

    /// Admits `rawPath` as a selectable file: inside one frozen root (a relative path must exist
    /// under exactly one), not a symbolic link and without a symlinked component (per the
    /// `skip_symlinks` policy), canonically contained, a regular file, and within the read limit.
    package func authorize(
        _ rawPath: String,
        skipSymlinks: Bool
    ) throws -> ContextBuilderDiscoveryAuthorizedPath {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0") else {
            throw ContextBuilderDiscoveryError.invalidSelectedPath(path: rawPath, reason: "empty_path")
        }
        let logical: String
        if trimmed.hasPrefix("/") {
            logical = URL(fileURLWithPath: trimmed).standardizedFileURL.path
        } else {
            let candidates = snapshot.roots.map {
                URL(fileURLWithPath: $0.path + "/" + trimmed).standardizedFileURL.path
            }.filter { candidate in
                var status = stat()
                return lstat(candidate, &status) == 0
            }
            guard candidates.count <= 1 else {
                throw ContextBuilderDiscoveryError.invalidSelectedPath(path: rawPath, reason: "ambiguous_across_roots")
            }
            logical = candidates.first ?? URL(fileURLWithPath: (snapshot.roots.first?.path ?? "") + "/" + trimmed)
                .standardizedFileURL.path
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

    private func displayPath(rootIndex: Int, relativePath: String) -> String {
        guard snapshot.roots.count > 1 else { return relativePath }
        return rootLabel(rootIndex) + "/" + relativePath
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
