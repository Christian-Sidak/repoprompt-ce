import CryptoKit
import Foundation
import RepoPromptDomainRuntime
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
    import Darwin // for stat()
#else
    import Glibc
#endif

/// Shared defaults and legacy key handling for app-wide ignore preferences.
///
/// Kept outside `IgnoreRulesManager` so JSON-backed settings, legacy mirrors,
/// and runtime ignore-rule loading agree on the canonical defaults/version.
enum IgnoreSettingsDefaults {
    static let globalIgnoreDefaultsKey = "globalIgnoreDefaults"
    static let globalIgnoreDefaultsVersionKey = "globalIgnoreDefaultsVersion"
    /// Version and canonical list live in the domain runtime so the app crawl and headless
    /// enumeration share one definition.
    static let currentGlobalIgnoreDefaultsVersion = DomainGlobalIgnoreDefaults.currentVersion

    /// Canonical default patterns (do NOT include `.git`; that is always ignored separately).
    static let canonicalGlobalIgnoreDefaults: String = DomainGlobalIgnoreDefaults.canonical

    static func resolvedGlobalIgnoreDefaults(defaults: UserDefaults = .standard) -> String {
        let storedObject = defaults.object(forKey: globalIgnoreDefaultsKey)
        let stored = defaults.string(forKey: globalIgnoreDefaultsKey)
        let storedVersion = defaults.object(forKey: globalIgnoreDefaultsVersionKey) as? Int ?? 0

        guard storedObject != nil, let stored else {
            defaults.set(canonicalGlobalIgnoreDefaults, forKey: globalIgnoreDefaultsKey)
            defaults.set(currentGlobalIgnoreDefaultsVersion, forKey: globalIgnoreDefaultsVersionKey)
            return canonicalGlobalIgnoreDefaults
        }

        guard storedVersion < currentGlobalIgnoreDefaultsVersion else {
            return stored
        }

        guard !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            defaults.set(canonicalGlobalIgnoreDefaults, forKey: globalIgnoreDefaultsKey)
            defaults.set(currentGlobalIgnoreDefaultsVersion, forKey: globalIgnoreDefaultsVersionKey)
            return canonicalGlobalIgnoreDefaults
        }

        let have = normalizedPatterns(stored)
        let required = normalizedPatterns(canonicalGlobalIgnoreDefaults)
        let missing = required.subtracting(have)

        guard !missing.isEmpty else {
            defaults.set(currentGlobalIgnoreDefaultsVersion, forKey: globalIgnoreDefaultsVersionKey)
            return stored
        }

        let upgraded = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n\n# (Auto-upgraded to v\(currentGlobalIgnoreDefaultsVersion))\n"
            + missing.sorted().joined(separator: "\n")
            + "\n"
        defaults.set(upgraded, forKey: globalIgnoreDefaultsKey)
        defaults.set(currentGlobalIgnoreDefaultsVersion, forKey: globalIgnoreDefaultsVersionKey)
        return upgraded
    }

    /// One-time marker for carrying a customized legacy value into `globalSettings.json`.
    static let settingsAuthorityMigrationKey = "globalIgnoreDefaultsSettingsAuthorityMigration"
    static let currentSettingsAuthorityMigration = 1

    /// Before `globalSettings.json` became the authority, the crawl read the legacy
    /// `UserDefaults` value while `app_settings` wrote JSON, which startup seeded with the
    /// canonical list. Returns the legacy effective value when it must replace the JSON value:
    /// only when the legacy value was customized and the JSON value was not. An explicitly
    /// customized JSON value always wins. Callers record completion with
    /// `markSettingsAuthorityMigrated(defaults:)` once the result can be persisted.
    static func legacyValueToMigrate(jsonValue: String?, defaults: UserDefaults) -> String? {
        guard !isSettingsAuthorityMigrated(defaults: defaults),
              defaults.object(forKey: globalIgnoreDefaultsKey) != nil
        else {
            return nil
        }
        // The value the crawl was actually using, including its version upgrade.
        let legacyEffective = resolvedGlobalIgnoreDefaults(defaults: defaults)
        let canonical = normalizedPatterns(canonicalGlobalIgnoreDefaults)
        guard normalizedPatterns(legacyEffective) != canonical,
              normalizedPatterns(jsonValue ?? canonicalGlobalIgnoreDefaults) == canonical
        else {
            return nil
        }
        return legacyEffective
    }

    static func isSettingsAuthorityMigrated(defaults: UserDefaults) -> Bool {
        defaults.integer(forKey: settingsAuthorityMigrationKey) >= currentSettingsAuthorityMigration
    }

    static func markSettingsAuthorityMigrated(defaults: UserDefaults) {
        defaults.set(currentSettingsAuthorityMigration, forKey: settingsAuthorityMigrationKey)
    }

    private static func normalizedPatterns(_ text: String) -> Set<String> {
        Set(
            text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        )
    }
}

/// Lock-protected effective global ignore defaults published by the settings authority
/// (`GlobalSettingsStore`, backed by `globalSettings.json`), readable from the ignore actor without
/// a MainActor hop.
final class GlobalIgnoreDefaultsAuthority: @unchecked Sendable {
    /// Published by the process-wide `GlobalSettingsStore` only.
    static let processWide = GlobalIgnoreDefaultsAuthority()

    private let lock = NSLock()
    private var value: String?

    func publish(_ content: String) {
        lock.withLock { value = content }
    }

    func current() -> String? {
        lock.withLock { value }
    }
}

/// A lightweight manager that builds `IgnoreRules` on demand, with no caching.
actor IgnoreRulesManager {
    /// Root layer inputs; assembly is shared with headless enumeration via `IgnoreLayerAssembly`.
    typealias CompiledRootAuthority = IgnoreLayerAssembly.CompiledRootAuthority

    struct ResolvedIgnoreRules {
        let rules: IgnoreRules
        let globalIgnoreDefaultsDigest: String
    }

    static let shared = IgnoreRulesManager()
    private let fileManager = FileManager.default

    #if DEBUG
        private var fileManagerOverride: (any FileSystemProviding)?

        func setFileManagerOverride(_ fm: (any FileSystemProviding)?) {
            fileManagerOverride = fm
        }

        private var globalDefaultsAuthorityOverride: GlobalIgnoreDefaultsAuthority?

        /// Test seam: resolve global defaults from `authority` instead of the canonical test value.
        func setGlobalDefaultsAuthorityOverride(_ authority: GlobalIgnoreDefaultsAuthority?) {
            globalDefaultsAuthorityOverride = authority
        }

        private var fm: any FileSystemProviding {
            fileManagerOverride ?? fileManager
        }
    #else
        private var fm: FileManager {
            fileManager
        }
    #endif

    private let ioSemaphore = TaskSemaphore(4) // Max 4 concurrent file reads
    /// Compile-result cache keyed by (dev, ino, mtime) to avoid duplicate work across symlinks.
    private struct FileMetaKey: Hashable {
        let dev: UInt64
        let ino: UInt64
        let mtime: UInt64
    }

    private var compiledCache = LRUCache<FileMetaKey, Task<CompiledIgnoreRules, Error>>(
        capacity: 500
    ) // metadata → task

    private init() {}

    #if DEBUG
        /// Detect if we're running under XCTest to make ignore behavior deterministic
        private static let isRunningTests: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    #endif

    // MARK: - File metadata helper

    /// Compute a unique cache key based on (device, inode, modification time).
    /// Falls back to a hash of the path if `stat()` fails.
    private func fileMetaKey(for url: URL) -> FileMetaKey {
        var st = stat()
        if stat(url.path, &st) == 0 {
            let dev = safeDeviceID(st.st_dev)
            let ino = UInt64(st.st_ino)
            #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
                let mtime = UInt64(st.st_mtimespec.tv_sec)
            #else
                let mtime = UInt64(st.st_mtim.tv_sec)
            #endif
            return FileMetaKey(dev: dev, ino: ino, mtime: mtime)
        }
        // Fallback – rare (e.g. file deleted between calls)
        return FileMetaKey(
            dev: 0,
            ino: UInt64(url.path.hashValue),
            mtime: 0
        )
    }

    /// Loads .gitignore and/or .repo_ignore content from disk, merges them into a single IgnoreRules.
    func resolvedIgnoreRules(
        for path: String,
        respectRepoIgnore: Bool = true,
        respectCursorignore: Bool = true,
        policy: IgnoreRulePolicy
    ) async throws -> ResolvedIgnoreRules {
        if case let .gitRoot(repositoryRelativeRootPrefix) = policy {
            return try await resolvedGitIgnoreRules(
                loadedPath: path,
                repositoryRelativeRootPrefix: repositoryRelativeRootPrefix,
                respectRepoIgnore: respectRepoIgnore,
                respectCursorignore: respectCursorignore,
                policy: policy
            )
        }
        let gitignorePath = (path as NSString).appendingPathComponent(".gitignore")
        let gitignoreContent: String? = if fm.fileExists(atPath: gitignorePath, isDirectory: nil) {
            try await loadFileContent(at: gitignorePath)
        } else { nil }

        // Always add global ignore defaults from user settings (lower priority)
        let globalIgnoreContent = fetchGlobalDefaults()

        // If enabled and a local .repo_ignore exists, add it with higher priority (overriding global defaults)
        let repoIgnoreContent: String?
        if respectRepoIgnore {
            let repoIgnorePath = (path as NSString).appendingPathComponent(".repo_ignore")
            if fm.fileExists(atPath: repoIgnorePath, isDirectory: nil) {
                repoIgnoreContent = try await loadFileContent(at: repoIgnorePath)
            } else { repoIgnoreContent = nil }
        } else { repoIgnoreContent = nil }

        // If enabled and a local .cursorignore exists, add it with highest local priority.
        let cursorignoreContent: String?
        if respectCursorignore {
            let cursorignorePath = (path as NSString).appendingPathComponent(".cursorignore")
            if fm.fileExists(atPath: cursorignorePath, isDirectory: nil) {
                cursorignoreContent = try await loadFileContent(at: cursorignorePath)
            } else { cursorignoreContent = nil }
        } else { cursorignoreContent = nil }

        let authority = Self.compileRootAuthority(
            gitignoreContent: gitignoreContent,
            globalIgnoreContent: globalIgnoreContent,
            repoIgnoreContent: repoIgnoreContent,
            cursorignoreContent: cursorignoreContent
        )
        let ignoreRules = Self.makeRootRules(
            authority: authority,
            respectRepoIgnore: respectRepoIgnore,
            respectCursorignore: respectCursorignore,
            policy: policy
        )

        return ResolvedIgnoreRules(
            rules: ignoreRules,
            globalIgnoreDefaultsDigest: Self.globalIgnoreDefaultsDigest(for: globalIgnoreContent)
        )
    }

    private func resolvedGitIgnoreRules(
        loadedPath: String,
        repositoryRelativeRootPrefix: IgnoreRepositoryRootPrefix,
        respectRepoIgnore: Bool,
        respectCursorignore: Bool,
        policy: IgnoreRulePolicy
    ) async throws -> ResolvedIgnoreRules {
        let globalIgnoreContent = fetchGlobalDefaults()
        let fm = fm
        let rules = try IgnoreLayerAssembly.gitRootChain(
            loadedPath: loadedPath,
            repositoryRelativeRootPrefix: repositoryRelativeRootPrefix,
            globalIgnoreContent: globalIgnoreContent,
            respectRepoIgnore: respectRepoIgnore,
            respectCursorignore: respectCursorignore,
            policy: policy,
            loadSecondaryIfPresent: { path in
                guard fm.fileExists(atPath: path, isDirectory: nil) else { return nil }
                return try Self.loadFileContentSynchronously(at: path, fileManager: fm)
            }
        )
        return ResolvedIgnoreRules(
            rules: rules,
            globalIgnoreDefaultsDigest: Self.globalIgnoreDefaultsDigest(for: globalIgnoreContent)
        )
    }

    nonisolated static func globalIgnoreDefaultsDigest(for content: String) -> String {
        Data(SHA256.hash(data: Data(content.utf8)))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    nonisolated static func loadMandatoryGitIgnoreContent(
        at url: URL,
        maximumBytes: Int = 4 * 1024 * 1024
    ) throws -> String {
        try MandatoryGitIgnoreFile.load(at: url, maximumBytes: maximumBytes)
    }

    nonisolated static func decodeMandatoryGitIgnoreContent(
        _ data: Data,
        maximumBytes: Int = 4 * 1024 * 1024
    ) throws -> String {
        try MandatoryGitIgnoreFile.decode(data, maximumBytes: maximumBytes)
    }

    nonisolated static func compileRootAuthority(
        gitignoreContent: String?,
        globalIgnoreContent: String,
        repoIgnoreContent: String?,
        cursorignoreContent: String?
    ) -> CompiledRootAuthority {
        IgnoreLayerAssembly.compileRootAuthority(
            gitignoreContent: gitignoreContent,
            globalIgnoreContent: globalIgnoreContent,
            repoIgnoreContent: repoIgnoreContent,
            cursorignoreContent: cursorignoreContent
        )
    }

    /// Builds the authoritative ordinary-crawl root chain; see `IgnoreLayerAssembly.makeRootRules`.
    nonisolated static func makeRootRules(
        authority: CompiledRootAuthority,
        respectRepoIgnore: Bool,
        respectCursorignore: Bool,
        policy: IgnoreRulePolicy
    ) -> IgnoreRules {
        IgnoreLayerAssembly.makeRootRules(
            authority: authority,
            respectRepoIgnore: respectRepoIgnore,
            respectCursorignore: respectCursorignore,
            policy: policy
        )
    }

    func resolvedGlobalIgnoreContent() -> String {
        fetchGlobalDefaults()
    }

    private func loadFileContent(at path: String) async throws -> String {
        try Self.loadFileContentSynchronously(at: path, fileManager: fm)
    }

    #if DEBUG
        private static func loadFileContentSynchronously(
            at path: String,
            fileManager: any FileSystemProviding
        ) throws -> String {
            if let data = fileManager.contents(atPath: path),
               let str = String(data: data, encoding: .utf8)
            {
                return str
            }
            return try String(contentsOfFile: path, encoding: .utf8)
        }
    #else
        private static func loadFileContentSynchronously(
            at path: String,
            fileManager _: FileManager
        ) throws -> String {
            try String(contentsOfFile: path, encoding: .utf8)
        }
    #endif

    private func fetchGlobalDefaults() -> String {
        #if DEBUG
            if let globalDefaultsAuthorityOverride {
                return globalDefaultsAuthorityOverride.current()
                    ?? IgnoreSettingsDefaults.canonicalGlobalIgnoreDefaults
            }
            // In test runs, always return canonical defaults to ensure deterministic behavior.
            // This prevents user-customized patterns from leaking into tests.
            if Self.isRunningTests {
                return IgnoreSettingsDefaults.canonicalGlobalIgnoreDefaults
            }
        #endif

        // `globalSettings.json` (via GlobalSettingsStore) is the authority `app_settings` writes.
        // The legacy defaults read remains only for a crawl that starts before the store loads.
        // After a blocked load the store publishes this same legacy effective value, not the
        // canonical list, until a compatible document is loaded or recovered.
        return GlobalIgnoreDefaultsAuthority.processWide.current()
            ?? IgnoreSettingsDefaults.resolvedGlobalIgnoreDefaults(defaults: .standard)
    }

    /// Asynchronously compile a `.gitignore` / `.repo_ignore` file.
    /// The first caller starts the compilation task; subsequent callers await
    /// the same task, ensuring the file is compiled exactly once.
    func compiledIgnoreFile(at url: URL) async throws -> CompiledIgnoreRules {
        let key = fileMetaKey(for: url)

        // Fast path: if we already have a task in-flight or completed, just await it.
        if let existing = compiledCache[key] {
            return try await existing.value
        }

        // Create a single shared compilation task.
        let task = Task<CompiledIgnoreRules, Error> {
            // Bounded parallelism
            guard await ioSemaphore.acquire() else { throw CancellationError() }
            do {
                // Perform the (blocking) file read on the current executor – it's fine
                // because we have limited the total number of concurrent reads.
                let txt = try String(contentsOf: url, encoding: .utf8)

                // Compile patterns
                let compiled = GitignoreCompiler.compile(content: txt)

                // Release the permit before returning
                await ioSemaphore.release()
                return compiled
            } catch {
                // Make sure we always release the permit
                await ioSemaphore.release()
                throw error
            }
        }

        // Store the task so subsequent callers share it.
        compiledCache[key] = task

        do {
            return try await task.value
        } catch {
            // On failure remove from cache so a later attempt can retry.
            compiledCache.removeValue(forKey: key)
            throw error
        }
    }
}
