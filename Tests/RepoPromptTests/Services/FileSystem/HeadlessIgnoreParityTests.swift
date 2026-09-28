import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// M8N: for the same non-Git fixture and global defaults, the app crawl's root ignore rules
/// (`IgnoreRulesManager`) and headless enumeration admit exactly the same files.
final class HeadlessIgnoreParityTests: XCTestCase {
    func testHeadlessEnumerationMatchesAppRootIgnoreRules() async throws {
        let globalPatterns = "**/node_modules/\n**/*.tmp\n"
        let root = try makeTree([
            ".gitignore": "build/\n*.log\n!keep.log\n",
            ".repo_ignore": "secret.txt\n!cache/keep.tmp\n",
            ".cursorignore": "!important.tmp\n",
            "src/a.swift": "struct A {}\n",
            "build/out.o": "x",
            "logs/x.log": "x",
            "logs/keep.log": "x",
            "node_modules/pkg/index.js": "x",
            "cache/b.tmp": "x",
            "cache/keep.tmp": "x",
            "important.tmp": "x",
            "secret.txt": "x",
            ".hidden/config": "x"
        ])

        let authority = GlobalIgnoreDefaultsAuthority()
        authority.publish(globalPatterns)
        await IgnoreRulesManager.shared.setGlobalDefaultsAuthorityOverride(authority)
        addTeardownBlock { await IgnoreRulesManager.shared.setGlobalDefaultsAuthorityOverride(nil) }
        let appRules = try await IgnoreRulesManager.shared.resolvedIgnoreRules(
            for: root.path,
            respectRepoIgnore: true,
            respectCursorignore: true,
            policy: .nonGitRoot
        ).rules
        let appAdmitted = allFiles(under: root).filter { admitted($0, by: appRules) }

        let headless = try await headlessListedPaths(
            root: root,
            configuration: DomainIgnoreConfiguration(globalPatterns: globalPatterns, hierarchicalIgnores: false)
        )

        XCTAssertEqual(Set(headless), Set(appAdmitted))
        XCTAssertFalse(appAdmitted.isEmpty)
    }

    // MARK: - Helpers

    /// The crawl's rule use: a file is listed unless an ancestor directory is ignored without a
    /// negation that requires traversal, or the file itself is ignored.
    private func admitted(_ relativePath: String, by rules: IgnoreRules) -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        for depth in 1 ..< components.count {
            let directory = components[0 ..< depth].joined(separator: "/")
            if rules.isIgnored(relativePath: directory, isDirectory: true),
               !rules.requiresTraversal(for: directory)
            {
                return false
            }
        }
        return !rules.isIgnored(relativePath: relativePath, isDirectory: false)
    }

    private func allFiles(under root: URL) -> [String] {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        var paths: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            paths.append(String(url.path.dropFirst(root.path.count + 1)))
        }
        return paths
    }

    private func headlessListedPaths(root: URL, configuration: DomainIgnoreConfiguration) async throws -> [String] {
        let snapshot = DomainCanonicalWorkspaceSnapshot(
            identity: DomainContextIdentity(workspaceID: UUID(), contextID: UUID()),
            roots: [root],
            prompt: "",
            selection: []
        )
        let service = MCPDomainCanonicalWorkspaceService(adapter: DomainCanonicalWorkspaceAdapter(
            toolSnapshot: { _ in snapshot },
            readSnapshot: { _ in snapshot },
            mutate: { _, _ in snapshot },
            resolvePath: { raw, roots, _ in roots[0].appendingPathComponent(raw) },
            ignoreConfiguration: { configuration }
        ))
        let arguments: [String: Value] = ["pattern": .string("*"), "mode": .string("path"), "max_results": .int(1000)]
        let result = try await service.searchFiles(DomainPhysicalReadRequest(
            request: DomainPhysicalToolRequest(argumentsJSON: JSONEncoder().encode(arguments), securityContext: nil),
            context: DomainReadInvocationContext(handle: nil, connectionID: nil),
            sideEffects: MCPDomainReadSideEffectEmitter(submit: { _, _, _, _, _ in })
        ))
        let value = try JSONDecoder().decode(Value.self, from: result.json)
        let matches = try XCTUnwrap(value.objectValue?["matches"]?.arrayValue)
        return matches.compactMap { $0.objectValue?["path"]?.stringValue }
    }

    private func makeTree(_ files: [String: String]) throws -> URL {
        let created = FileManager.default.temporaryDirectory
            .appendingPathComponent("headless-ignore-parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
        // Kernel-canonical path (`/private/var/...`), the spelling the enumerator reports, so this
        // helper's relative paths are exact.
        let canonical = try XCTUnwrap(realpath(created.path, nil))
        defer { free(canonical) }
        let root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for (relative, contents) in files {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        return root
    }
}
