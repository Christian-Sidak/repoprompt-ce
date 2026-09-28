import Foundation
import MCP
@testable import RepoPromptDomainRuntime
import XCTest

/// M8N: headless enumeration applies the app's ignore layers through the shared
/// `IgnoreLayerAssembly` / `IgnoreRules` engine.
final class HeadlessIgnoreEnumerationTests: XCTestCase {
    private let fixtureFiles: [String: String] = [
        ".gitignore": "build/\n*.log\n!keep.log\n",
        ".repo_ignore": "secret.txt\n",
        ".cursorignore": "!important.tmp\n",
        "src/a.swift": "struct A {}\n",
        "build/out.o": "x",
        "logs/x.log": "x",
        "logs/keep.log": "x",
        "node_modules/pkg/index.js": "x",
        "cache/b.tmp": "x",
        "important.tmp": "x",
        "secret.txt": "x",
        ".hidden/config": "x",
        "sub/.gitignore": "local.txt\n",
        "sub/local.txt": "x",
        "local.txt": "x"
    ]
    private let globalPatterns = "**/node_modules/\n**/*.tmp\n"

    func testNonGitRootAppliesAllLayersWithSecondaryPrecedence() async throws {
        let root = try makeTree(fixtureFiles)
        let listed = try await listedPaths(root: root, configuration: .init(globalPatterns: globalPatterns))

        XCTAssertEqual(listed, [
            ".cursorignore", ".gitignore", ".hidden/config", ".repo_ignore",
            "important.tmp", "local.txt", "logs/keep.log", "src/a.swift", "sub/.gitignore"
        ])
    }

    func testGitRootKeepsGitignoreAsAMandatoryFloorAndExcludesDotGit() async throws {
        var files = fixtureFiles
        files[".gitignore"] = "build/\n*.log\n!keep.log\n*.tmp\n"
        files[".git/HEAD"] = "ref: refs/heads/main\n"
        let root = try makeTree(files)
        let listed = try await listedPaths(root: root, configuration: .init(globalPatterns: globalPatterns))

        XCTAssertFalse(listed.contains("important.tmp"), "a secondary negation cannot re-include a Git-ignored file")
        XCTAssertFalse(listed.contains(where: { $0.hasPrefix(".git/") }))
        XCTAssertTrue(listed.contains("logs/keep.log"), "a .gitignore negation still applies within Git's own chain")
        XCTAssertFalse(listed.contains("sub/local.txt"))
    }

    func testSwitchesDisableRepoIgnoreAndHierarchicalLayers() async throws {
        let root = try makeTree(fixtureFiles)
        let listed = try await listedPaths(root: root, configuration: .init(
            globalPatterns: globalPatterns,
            respectRepoIgnore: false,
            hierarchicalIgnores: false
        ))
        XCTAssertTrue(listed.contains("secret.txt"), ".repo_ignore is not applied when disabled")
        XCTAssertTrue(listed.contains("sub/local.txt"), "nested .gitignore is not applied when hierarchical ignores are off")
    }

    func testSubdirectoryTreeBaseInheritsRootLayers() async throws {
        let root = try makeTree(fixtureFiles)
        let service = makeService(root: root, configuration: .init(globalPatterns: globalPatterns))
        let tree = try await service.renderFileTree(readRequest(["path": .string("logs")])).mcpValue().stringValue
        let lines = try XCTUnwrap(tree).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertTrue(lines.contains("keep.log"))
        XCTAssertFalse(lines.contains("x.log"), "the root .gitignore applies below a subdirectory base")
    }

    func testWithoutConfigurationEnumerationKeepsLegacyBehavior() async throws {
        let root = try makeTree(fixtureFiles)
        let listed = try await listedPaths(root: root, configuration: nil)
        XCTAssertTrue(listed.contains("build/out.o"))
        XCTAssertFalse(listed.contains(".hidden/config"), "legacy enumeration skips hidden entries")
    }

    // MARK: - Helpers

    private func listedPaths(root: URL, configuration: DomainIgnoreConfiguration?) async throws -> [String] {
        let service = makeService(root: root, configuration: configuration)
        let value = try await service.searchFiles(readRequest([
            "pattern": .string("*"),
            "mode": .string("path"),
            "max_results": .int(1000)
        ])).mcpValue()
        let matches = try XCTUnwrap(value.objectValue?["matches"]?.arrayValue)
        return matches.compactMap { $0.objectValue?["path"]?.stringValue }.sorted()
    }

    private func makeTree(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("headless-ignore-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for (relative, contents) in files {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        return root
    }

    private func makeService(root: URL, configuration: DomainIgnoreConfiguration?) -> MCPDomainCanonicalWorkspaceService {
        let provider: DomainCanonicalWorkspaceAdapter.IgnoreConfigurationProvider? = if let configuration {
            { @Sendable in configuration }
        } else {
            nil
        }
        let snapshot = DomainCanonicalWorkspaceSnapshot(
            identity: DomainContextIdentity(workspaceID: UUID(), contextID: UUID()),
            roots: [root],
            prompt: "",
            selection: []
        )
        return MCPDomainCanonicalWorkspaceService(adapter: DomainCanonicalWorkspaceAdapter(
            toolSnapshot: { _ in snapshot },
            readSnapshot: { _ in snapshot },
            mutate: { _, _ in snapshot },
            resolvePath: { raw, roots, _ in roots[0].appendingPathComponent(raw) },
            ignoreConfiguration: provider
        ))
    }

    private func readRequest(_ arguments: [String: Value]) throws -> DomainPhysicalReadRequest {
        try DomainPhysicalReadRequest(
            request: DomainPhysicalToolRequest(argumentsJSON: JSONEncoder().encode(arguments), securityContext: nil),
            context: DomainReadInvocationContext(handle: nil, connectionID: nil),
            sideEffects: MCPDomainReadSideEffectEmitter(submit: { _, _, _, _, _ in })
        )
    }
}
