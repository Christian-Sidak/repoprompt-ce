import Darwin
import Foundation

/// Explicit `read_file` authority for headless, mirroring the app's explicit-read contract:
/// `WorkspaceFileContextStore` explicit materialization admits a catalog-eligible file *and* an
/// ignored one (ignore rules filter discovery; they do not authorize reads), and
/// `FileSystemService.validateContentFileForReading` / `catalogRegularFileEligibility` refuse
///
/// - a path whose final component is a symbolic link (`.symbolicLink`), whatever `skip_symlinks` says;
/// - a path with a symlinked directory component while `skip_symlinks` is on (`.symlinkComponent`);
/// - a path whose canonical target is outside the root's canonical root (`.outsideCanonicalRoot`);
/// - anything that is not a regular file.
///
/// The checks run on the *logical* path (as the caller named it, below the root spelling it
/// matched), independent of any adapter-side symlink resolution. The content is then read through a
/// component-by-component `openat(O_NOFOLLOW)` walk of the canonical path from the canonical root,
/// so a component swapped for a symlink after authorization fails closed instead of escaping.
enum HeadlessReadAuthority {
    struct Target: Equatable {
        /// Kernel-canonical workspace root the read is contained in.
        let canonicalRoot: String
        /// Components of the canonical target below `canonicalRoot`.
        let canonicalComponents: [String]
    }

    static func readText(rawPath: String, roots: [URL], skipSymlinks: Bool, limit: Int) throws -> String {
        let target = try authorize(rawPath: rawPath, roots: roots, skipSymlinks: skipSymlinks)
        return try decodeText(readContained(target, limit: limit))
    }

    /// Applies the app's explicit-read gates to the logical path and returns the contained target.
    static func authorize(rawPath: String, roots: [URL], skipSymlinks: Bool) throws -> Target {
        let candidates = rawPath.hasPrefix("/") ? [rawPath] : roots.map { $0.path + "/" + rawPath }
        var attributed = false
        for candidate in candidates {
            let logical = URL(fileURLWithPath: candidate).standardizedFileURL.path
            guard let (root, rootSpelling) = owningRoot(of: logical, roots: roots) else { continue }
            attributed = true
            var status = stat()
            // Not present below this root (a relative path may belong to another root).
            guard lstat(logical, &status) == 0 else { continue }
            let components = logical.dropFirst(rootSpelling.count + 1).split(separator: "/").map(String.init)
            var path = rootSpelling
            for (index, component) in components.enumerated() {
                path += "/" + component
                var componentStatus = stat()
                guard lstat(path, &componentStatus) == 0 else { throw POSIXError(.ENOENT) }
                guard componentStatus.st_mode & S_IFMT == S_IFLNK else { continue }
                if index == components.count - 1 { throw MCPDomainCanonicalReadError.symbolicLinkPath }
                if skipSymlinks { throw MCPDomainCanonicalReadError.symlinkComponent }
            }
            guard let canonicalRoot = canonicalPath(root.path),
                  let canonical = canonicalPath(logical),
                  canonical.hasPrefix(canonicalRoot + "/")
            else { throw MCPDomainCanonicalReadError.outsideCanonicalRoot }
            return Target(
                canonicalRoot: canonicalRoot,
                canonicalComponents: canonical.dropFirst(canonicalRoot.count + 1).split(separator: "/").map(String.init)
            )
        }
        if attributed { throw POSIXError(.ENOENT) }
        throw MCPDomainCanonicalReadError.outsideRoot
    }

    /// Reads `target` by walking its canonical components from the canonical root with
    /// `O_NOFOLLOW`, so no symlink is traversed at read time; a swapped component fails closed.
    static func readContained(_ target: Target, limit: Int) throws -> Data {
        var descriptor = open(target.canonicalRoot, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        for (index, component) in target.canonicalComponents.enumerated() {
            let isLast = index == target.canonicalComponents.count - 1
            let next = openat(descriptor, component, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | (isLast ? 0 : O_DIRECTORY))
            let openError = errno
            close(descriptor)
            guard next >= 0 else {
                // ELOOP: a symlink now sits where authorization saw none. ENOTDIR: a directory
                // component became something else. Either way the path changed; fail closed.
                if openError == ELOOP || openError == ENOTDIR {
                    throw MCPDomainCanonicalReadError.pathChangedDuringRead
                }
                throw POSIXError(POSIXErrorCode(rawValue: openError) ?? .EIO)
            }
            descriptor = next
        }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard status.st_mode & S_IFMT == S_IFREG else { throw MCPDomainCanonicalReadError.notARegularFile }
        guard status.st_size <= off_t(limit) else {
            throw MCPDomainCanonicalReadError.fileTooLarge(byteCount: Int(status.st_size), limit: limit)
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard data.count + count <= limit else {
                throw MCPDomainCanonicalReadError.fileTooLarge(byteCount: data.count + count, limit: limit)
            }
            data.append(contentsOf: buffer[0 ..< count])
        }
        return data
    }

    /// UTF-8 text, or UTF-16 when a byte-order mark says so.
    static func decodeText(_ data: Data) throws -> String {
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

    /// The root containing `logicalPath` and the spelling of that root it is written under.
    private static func owningRoot(of logicalPath: String, roots: [URL]) -> (URL, String)? {
        for root in roots {
            for spelling in HeadlessPathSpelling.equivalentPaths(root) where logicalPath.hasPrefix(spelling + "/") {
                return (root, spelling)
            }
        }
        return nil
    }

    private static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

enum HeadlessPathSpelling {
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
