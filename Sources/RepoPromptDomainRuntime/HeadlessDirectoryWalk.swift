import Darwin
import Foundation

/// Depth-first directory walk for configured headless enumeration. Symlink handling follows the
/// app's authoritative discovery and read gates (`FileSystemService.catalogRegularFileEligibility`,
/// `catalogFolderIsDiscoverable`, `validateContentFileForReading`), not merely its raw crawl:
///
/// - `skipSymlinks` (the app default): every symbolic-link entry is dropped, so nothing is reached
///   through a link.
/// - Otherwise the only link admitted is one whose canonical target is a directory inside the
///   owning root's canonical root; it is listed and followed unless its (device, inode) is already
///   on the ancestor chain (the app's `DirChain` guard: the cycle is listed, not descended). A file
///   link (the app's `.symbolicLink`), a broken link (`.missingOrDirectory`), and any link whose
///   canonical target leaves the root (`.outsideCanonicalRoot`) are neither listed nor followed, so
///   enumeration can never disclose outside-root names or content under an in-root logical path.
///   With no readable canonical root every link is dropped (fail closed). A directory whose
///   identity cannot be read is listed but not descended.
///
/// Entries carry logical paths (the link's own location, never the resolved target), so ignore
/// rules and root attribution see the same relative path the app catalogs. Children are visited in
/// name order for deterministic output.
struct HeadlessDirectoryWalk {
    struct Entry {
        let url: URL
        /// 1 for the base's direct children.
        let depth: Int
        let isDirectory: Bool
        let isRegularFile: Bool
        let fileSize: Int?
    }

    enum Decision {
        case descend
        case skipDescendants
        case stop
    }

    struct DirectoryID: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    let skipSymlinks: Bool
    /// Kernel-canonical path of the owning workspace root; links must resolve inside it.
    let canonicalRootPath: String?
    /// Package directories (for example `.app` bundles) are listed but not descended, as the
    /// legacy `FileManager` enumeration did with `.skipsPackageDescendants`.
    let skipsPackageDescendants: Bool
    let checkCancellation: () throws -> Void

    /// Walks `base`, whose own ancestors inside the workspace root are `ancestorIDs`. Returns false
    /// when a visit returned `.stop`.
    @discardableResult
    func walk(base: URL, ancestorIDs: [DirectoryID], _ visit: (Entry) throws -> Decision) throws -> Bool {
        var chain = Set(ancestorIDs)
        if !skipSymlinks, let id = Self.directoryID(atPath: base.path) {
            chain.insert(id)
        }
        return try walkDirectory(base, depth: 1, chain: chain, visit)
    }

    /// The (device, inode) of the directory at `path`, following symlinks, or nil if unreadable.
    static func directoryID(atPath path: String) -> DirectoryID? {
        var status = stat()
        guard stat(path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else { return nil }
        return DirectoryID(device: UInt64(UInt32(bitPattern: status.st_dev)), inode: UInt64(status.st_ino))
    }

    /// The kernel-canonical spelling of `path` (all symlinks resolved, `/private` kept), or nil.
    static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func walkDirectory(
        _ directory: URL,
        depth: Int,
        chain: Set<DirectoryID>,
        _ visit: (Entry) throws -> Decision
    ) throws -> Bool {
        try checkCancellation()
        // An unreadable directory contributes nothing, as with the legacy enumerator.
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return true }
        for name in names.sorted() {
            try checkCancellation()
            let url = directory.appendingPathComponent(name)
            guard let entry = classify(url, depth: depth) else { continue }
            let decision = try visit(entry)
            if decision == .stop { return false }
            guard decision == .descend, entry.isDirectory else { continue }
            if skipsPackageDescendants, (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true {
                continue
            }
            var childChain = chain
            if !skipSymlinks {
                guard let id = Self.directoryID(atPath: url.path), !chain.contains(id) else { continue }
                childChain.insert(id)
            }
            guard try walkDirectory(url, depth: depth + 1, chain: childChain, visit) else { return false }
        }
        return true
    }

    private func classify(_ url: URL, depth: Int) -> Entry? {
        var linkStatus = stat()
        // Vanished between listing and classification: nothing to report.
        guard lstat(url.path, &linkStatus) == 0 else { return nil }
        guard linkStatus.st_mode & S_IFMT == S_IFLNK else {
            let kind = linkStatus.st_mode & S_IFMT
            return Entry(
                url: url,
                depth: depth,
                isDirectory: kind == S_IFDIR,
                isRegularFile: kind == S_IFREG,
                fileSize: kind == S_IFREG ? Int(linkStatus.st_size) : nil
            )
        }
        guard !skipSymlinks, admitsDirectoryLink(at: url.path) else { return nil }
        return Entry(url: url, depth: depth, isDirectory: true, isRegularFile: false, fileSize: nil)
    }

    /// Whether a link is a directory link whose canonical target stays inside the canonical root.
    private func admitsDirectoryLink(at path: String) -> Bool {
        guard let canonicalRootPath,
              let target = Self.canonicalPath(path),
              target == canonicalRootPath || target.hasPrefix(canonicalRootPath + "/")
        else { return false }
        var status = stat()
        return stat(target, &status) == 0 && status.st_mode & S_IFMT == S_IFDIR
    }
}
