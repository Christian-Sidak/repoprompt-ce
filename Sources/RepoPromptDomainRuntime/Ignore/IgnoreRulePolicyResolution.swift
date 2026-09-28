import Darwin
import Foundation

// Git-root policy resolution and the mandatory `.gitignore` control file, shared by the app crawl and
// headless enumeration.

package enum IgnoreRulePolicyResolutionError: Error, Equatable, Sendable {
    case ambiguousGitTopology
}

package enum MandatoryGitIgnoreControlError: Error, Equatable, Sendable {
    case unavailable
    case notRegularFile
    case contentLimitExceeded
    case invalidEncoding
    case changedDuringRead
}

extension IgnoreRulePolicy {
    /// Resolves the ignore policy for a loaded root: a Git root (with its repository-relative prefix)
    /// when an enclosing, structurally valid repository exists, otherwise a non-Git root. Ambiguous
    /// topology throws, and callers fail closed rather than apply the wrong policy.
    package static func resolvingLoadedRoot(_ rawRoot: URL) throws -> IgnoreRulePolicy {
        let loadedRoot = rawRoot.resolvingSymlinksInPath().standardizedFileURL
        var loadedStatus = stat()
        guard lstat(loadedRoot.path, &loadedStatus) == 0,
              loadedStatus.st_mode & S_IFMT == S_IFDIR
        else { throw IgnoreRulePolicyResolutionError.ambiguousGitTopology }

        var candidate = loadedRoot
        while true {
            let dotGit = candidate.appendingPathComponent(".git")
            var dotGitStatus = stat()
            if lstat(dotGit.path, &dotGitStatus) == 0 {
                let kind = dotGitStatus.st_mode & S_IFMT
                guard kind == S_IFDIR || kind == S_IFREG,
                      let layout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: candidate),
                      validatedContainingGitLayout(layout)
                else { throw IgnoreRulePolicyResolutionError.ambiguousGitTopology }
                let repositoryRoot = layout.workTreeRoot.resolvingSymlinksInPath().standardizedFileURL
                guard repositoryRoot == candidate,
                      loadedRoot.path == repositoryRoot.path
                      || loadedRoot.path.hasPrefix(repositoryRoot.path + "/")
                else { throw IgnoreRulePolicyResolutionError.ambiguousGitTopology }
                let relativePath = loadedRoot.path == repositoryRoot.path
                    ? ""
                    : String(loadedRoot.path.dropFirst(repositoryRoot.path.count + 1))
                let prefix = try IgnoreRepositoryRootPrefix(relativePath)
                guard prefix.value.split(separator: "/").first != ".git" else {
                    throw IgnoreRulePolicyResolutionError.ambiguousGitTopology
                }
                return .gitRoot(repositoryRelativeRootPrefix: prefix)
            }
            guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard candidate.path != "/" else { break }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { break }
            candidate = parent
        }
        return .nonGitRoot
    }

    private static func validatedContainingGitLayout(_ layout: GitRepositoryLayout) -> Bool {
        func isRegularFile(_ url: URL) -> Bool {
            var value = stat()
            return lstat(url.path, &value) == 0 && value.st_mode & S_IFMT == S_IFREG
        }
        func isDirectory(_ url: URL) -> Bool {
            var value = stat()
            return lstat(url.path, &value) == 0 && value.st_mode & S_IFMT == S_IFDIR
        }
        return isDirectory(layout.gitDir)
            && isDirectory(layout.commonDir)
            && isRegularFile(layout.gitDir.appendingPathComponent("HEAD"))
            && isRegularFile(layout.commonDir.appendingPathComponent("config"))
            && isDirectory(layout.commonDir.appendingPathComponent("objects"))
    }
}

/// Reads a Git `.gitignore` control file with the integrity checks the mandatory Git floor requires:
/// no symlink following, regular file only, bounded size, UTF-8, and unchanged during the read.
package enum MandatoryGitIgnoreFile {
    package static func load(
        at url: URL,
        maximumBytes: Int = 4 * 1024 * 1024
    ) throws -> String {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw MandatoryGitIgnoreControlError.unavailable }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0 else {
            throw MandatoryGitIgnoreControlError.unavailable
        }
        guard before.st_mode & S_IFMT == S_IFREG else {
            throw MandatoryGitIgnoreControlError.notRegularFile
        }
        var data = Data()
        var buffer = Data(count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let amount = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if amount == 0 { break }
            if amount < 0 {
                if errno == EINTR { continue }
                throw MandatoryGitIgnoreControlError.unavailable
            }
            let (nextCount, overflow) = data.count.addingReportingOverflow(amount)
            guard !overflow, nextCount <= maximumBytes else {
                throw MandatoryGitIgnoreControlError.contentLimitExceeded
            }
            data.append(buffer.prefix(amount))
        }
        var after = stat()
        var rebound = stat()
        guard fstat(descriptor, &after) == 0,
              lstat(url.path, &rebound) == 0,
              rebound.st_mode & S_IFMT == S_IFREG,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              rebound.st_dev == before.st_dev,
              rebound.st_ino == before.st_ino
        else { throw MandatoryGitIgnoreControlError.changedDuringRead }
        return try decode(data, maximumBytes: maximumBytes)
    }

    package static func decode(
        _ data: Data,
        maximumBytes: Int = 4 * 1024 * 1024
    ) throws -> String {
        guard data.count <= maximumBytes else {
            throw MandatoryGitIgnoreControlError.contentLimitExceeded
        }
        guard let content = String(data: data, encoding: .utf8) else {
            throw MandatoryGitIgnoreControlError.invalidEncoding
        }
        return content
    }

    package static func exists(at url: URL) throws -> Bool {
        var value = stat()
        if lstat(url.path, &value) == 0 { return true }
        guard errno == ENOENT else { throw MandatoryGitIgnoreControlError.unavailable }
        return false
    }
}

extension IgnoreLayerAssembly {
    /// The root chain for a loaded root inside a Git work tree: from the repository root down to the
    /// loaded root, each level's `.gitignore` as the mandatory Git layer (with its integrity checks),
    /// the global defaults once at the repository root, and each level's `.repo_ignore` /
    /// `.cursorignore` as secondary layers when enabled. Callers supply how secondary files are read.
    package static func gitRootChain(
        loadedPath: String,
        repositoryRelativeRootPrefix: IgnoreRepositoryRootPrefix,
        globalIgnoreContent: String,
        respectRepoIgnore: Bool,
        respectCursorignore: Bool,
        policy: IgnoreRulePolicy,
        loadSecondaryIfPresent: (String) throws -> String?
    ) throws -> IgnoreRules {
        let loadedRoot = URL(fileURLWithPath: loadedPath).resolvingSymlinksInPath().standardizedFileURL
        let prefixComponents = repositoryRelativeRootPrefix.value.split(separator: "/").map(String.init)
        var repositoryRoot = loadedRoot
        for _ in prefixComponents {
            repositoryRoot.deleteLastPathComponent()
        }
        guard let layout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: repositoryRoot),
              layout.workTreeRoot.resolvingSymlinksInPath().standardizedFileURL == repositoryRoot
        else { throw IgnoreRulePolicyResolutionError.ambiguousGitTopology }

        let rules = IgnoreRules(policy: policy)
        var directory = repositoryRoot
        var relativeDirectory = ""
        for depth in 0 ... prefixComponents.count {
            let gitignoreURL = directory.appendingPathComponent(".gitignore")
            if try MandatoryGitIgnoreFile.exists(at: gitignoreURL) {
                let content = try MandatoryGitIgnoreFile.load(at: gitignoreURL)
                rules.addCompiledLayer(
                    GitignoreCompiler.compile(content: content, directoryPath: relativeDirectory),
                    authority: .mandatoryGit
                )
            }
            if depth == 0 {
                rules.addCompiledLayer(
                    GitignoreCompiler.compile(content: globalIgnoreContent),
                    authority: .secondary
                )
            }
            if respectRepoIgnore,
               let content = try loadSecondaryIfPresent(directory.appendingPathComponent(".repo_ignore").path)
            {
                rules.addCompiledLayer(
                    GitignoreCompiler.compile(content: content, directoryPath: relativeDirectory),
                    authority: .secondary
                )
            }
            if respectCursorignore,
               let content = try loadSecondaryIfPresent(directory.appendingPathComponent(".cursorignore").path)
            {
                rules.addCompiledLayer(
                    GitignoreCompiler.compile(content: content, directoryPath: relativeDirectory),
                    authority: .secondary
                )
            }
            guard depth < prefixComponents.count else { break }
            let component = prefixComponents[depth]
            directory.appendPathComponent(component, isDirectory: true)
            relativeDirectory = relativeDirectory.isEmpty ? component : relativeDirectory + "/" + component
        }
        guard directory == loadedRoot else { throw IgnoreRulePolicyResolutionError.ambiguousGitTopology }
        return rules
    }
}
