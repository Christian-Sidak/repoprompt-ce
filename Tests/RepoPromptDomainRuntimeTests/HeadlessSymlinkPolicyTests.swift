import Foundation
import MCP
@testable import RepoPromptDomainRuntime
import XCTest

/// M8P: configured headless enumeration applies the app's symlink authority. By default
/// (`skip_symlinks`) every link is skipped; otherwise only a directory link whose canonical target
/// stays inside the root is followed (with the app's ancestor-cycle guard). File links, broken links,
/// and links escaping the root are never listed or read, so no outside-root name or content is
/// disclosed under an in-root logical path.
final class HeadlessSymlinkPolicyTests: XCTestCase {
    private static let outsideToken = "OUTSIDE_ROOT_SECRET"

    func testDefaultPolicySkipsEveryLink() async throws {
        let fixture = try makeFixture()
        let configuration = DomainIgnoreConfiguration(globalPatterns: "")
        XCTAssertTrue(configuration.skipSymlinks, "the default matches the app's skip_symlinks default")

        let listed = try await searchedPaths(fixture.root, configuration: configuration)
        XCTAssertEqual(listed, [".gitignore", "loop/b.swift", "real/a.swift"])

        let tree = try await treeLines(fixture.root, configuration: configuration)
        for name in Self.linkNames {
            XCTAssertFalse(tree.contains(name), "\(name) is a link and must not be listed")
        }
    }

    func testFollowingAdmitsOnlyInRootDirectoryLinksWithCycleGuard() async throws {
        let fixture = try makeFixture()
        let configuration = DomainIgnoreConfiguration(globalPatterns: "", skipSymlinks: false)

        let listed = try await searchedPaths(fixture.root, configuration: configuration)
        XCTAssertEqual(
            listed,
            [".gitignore", "linkdir/a.swift", "loop/b.swift", "real/a.swift"],
            "an in-root directory link is followed; `*.log` still excludes linkdir/debug.log by its logical "
                + "path and `build/` excludes the linked build directory"
        )

        let tree = try await treeLines(fixture.root, configuration: configuration)
        XCTAssertTrue(tree.contains("linkdir/"))
        XCTAssertTrue(tree.contains("self/"), "an in-root link back to an ancestor is listed")
        XCTAssertEqual(tree.count(where: { $0 == "b.swift" }), 1, "the cycle is not descended")
        for name in ["linkfile.swift", "broken", "build/", "outside/", "secret.swift", "escape/", "up/"] {
            XCTAssertFalse(tree.contains(name), "\(name) must not be listed")
        }
    }

    func testOutsideRootLinksNeverDiscloseNamesOrContent() async throws {
        let fixture = try makeFixture()
        let service = makeService(fixture.root, configuration: .init(globalPatterns: "", skipSymlinks: false))

        let content = try await service.searchFiles(readRequest([
            "pattern": .string(Self.outsideToken),
            "mode": .string("content")
        ])).mcpValue()
        XCTAssertEqual(content.objectValue?["matches"]?.arrayValue?.count, 0, "outside-root content is never read")

        let names = try await service.searchFiles(readRequest([
            "pattern": .string("*.swift"),
            "mode": .string("path"),
            "max_results": .int(1000)
        ])).mcpValue()
        let namePaths = try XCTUnwrap(names.objectValue?["matches"]?.arrayValue).compactMap {
            $0.objectValue?["path"]?.stringValue
        }
        XCTAssertFalse(namePaths.contains { $0.hasSuffix("ext.swift") || $0.hasSuffix("secret.swift") })

        let treeValue = try await service.renderFileTree(readRequest([:])).mcpValue()
        let tree = try XCTUnwrap(treeValue.stringValue)
        XCTAssertFalse(tree.contains("ext.swift"))
        XCTAssertFalse(tree.contains("secret.swift"))

        let structure = try await service.inspectCodeStructure(readRequest([
            "paths": .array([.string(fixture.root.path)])
        ])).mcpValue()
        let structurePaths = try XCTUnwrap(structure.objectValue?["files"]?.arrayValue).compactMap {
            $0.objectValue?["path"]?.stringValue
        }
        XCTAssertTrue(structurePaths.contains(fixture.root.appendingPathComponent("linkdir/a.swift").path))
        XCTAssertFalse(
            structurePaths.contains { $0.hasSuffix("ext.swift") || $0.hasSuffix("secret.swift") },
            "directory expansion never reaches outside-root files: \(structurePaths)"
        )
    }

    func testContentSearchReadsOnlyRegularInRootFiles() async throws {
        let fixture = try makeFixture()
        let value = try await makeService(fixture.root, configuration: .init(globalPatterns: "", skipSymlinks: false))
            .searchFiles(readRequest(["pattern": .string("struct A"), "mode": .string("content")]))
            .mcpValue()
        let paths = try Set(XCTUnwrap(value.objectValue?["matches"]?.arrayValue).compactMap {
            $0.objectValue?["path"]?.stringValue
        })
        XCTAssertEqual(
            paths,
            ["real/a.swift", "linkdir/a.swift"],
            "a file link is not read, as the app refuses a final-component symlink"
        )
    }

    func testTreeBaseThroughSkippedLinkEnumeratesNothing() async throws {
        let fixture = try makeFixture()
        let skipped = try await treeLines(fixture.root, path: "linkdir", configuration: .init(globalPatterns: ""))
        XCTAssertEqual(skipped, ["linkdir/"], "the app catalogs nothing reached through a skipped link")

        let followed = try await treeLines(
            fixture.root,
            path: "linkdir",
            configuration: .init(globalPatterns: "", skipSymlinks: false)
        )
        XCTAssertEqual(followed, ["linkdir/", "a.swift"], "the nested escape link below the base is not listed")
    }

    func testHeadlessSettingsDefaultMatchesApp() {
        XCTAssertEqual(
            DomainAppSettingsCatalog.descriptor(for: "file_system.skip_symlinks")?.defaultValue,
            .bool(true)
        )
    }

    // MARK: - Helpers

    private static let linkNames = [
        "linkdir/", "linkfile.swift", "build/", "self/", "broken", "outside/", "secret.swift", "escape/", "up/"
    ]

    private struct Fixture {
        let root: URL
        let external: URL
    }

    /// ```
    /// .gitignore            *.log, build/
    /// real/a.swift, real/debug.log, real/escape -> <external>
    /// linkdir -> real       linkfile.swift -> real/a.swift     build -> real
    /// loop/b.swift          loop/self -> ..  (the root)
    /// broken -> missing     outside -> <external>              up -> ../<external name>
    /// secret.swift -> <external>/secret.swift
    /// <external>/ext.swift, <external>/secret.swift            (both contain the outside token)
    /// ```
    private func makeFixture() throws -> Fixture {
        let parent = try makeDirectory("headless-symlink")
        let root = parent.appendingPathComponent("root", isDirectory: true)
        let external = parent.appendingPathComponent("external", isDirectory: true)
        try write("struct Ext {} // \(Self.outsideToken)\n", to: external.appendingPathComponent("ext.swift"))
        try write("let secret = \"\(Self.outsideToken)\"\n", to: external.appendingPathComponent("secret.swift"))
        try write("*.log\nbuild/\n", to: root.appendingPathComponent(".gitignore"))
        try write("struct A {}\n", to: root.appendingPathComponent("real/a.swift"))
        try write("x", to: root.appendingPathComponent("real/debug.log"))
        try write("struct B {}\n", to: root.appendingPathComponent("loop/b.swift"))
        let links: [(String, String)] = [
            ("linkdir", "real"),
            ("linkfile.swift", "real/a.swift"),
            ("build", "real"),
            ("loop/self", ".."),
            ("broken", "missing"),
            ("outside", external.path),
            ("up", "../external"),
            ("secret.swift", external.appendingPathComponent("secret.swift").path),
            ("real/escape", external.path)
        ]
        for (link, destination) in links {
            try FileManager.default.createSymbolicLink(
                atPath: root.appendingPathComponent(link).path,
                withDestinationPath: destination
            )
        }
        return Fixture(root: root, external: external)
    }

    /// Kernel-canonical temporary directory (`/private/var/...`).
    private func makeDirectory(_ prefix: String) throws -> URL {
        let created = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
        let canonical = try XCTUnwrap(realpath(created.path, nil))
        defer { free(canonical) }
        let url = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    private func searchedPaths(_ root: URL, configuration: DomainIgnoreConfiguration) async throws -> [String] {
        let value = try await makeService(root, configuration: configuration).searchFiles(readRequest([
            "pattern": .string("*"),
            "mode": .string("path"),
            "max_results": .int(1000)
        ])).mcpValue()
        let matches = try XCTUnwrap(value.objectValue?["matches"]?.arrayValue)
        return matches.compactMap { $0.objectValue?["path"]?.stringValue }.sorted()
    }

    private func treeLines(
        _ root: URL,
        path: String? = nil,
        configuration: DomainIgnoreConfiguration
    ) async throws -> [String] {
        var arguments: [String: Value] = [:]
        if let path { arguments["path"] = .string(path) }
        let tree = try await makeService(root, configuration: configuration)
            .renderFileTree(readRequest(arguments)).mcpValue().stringValue
        return try XCTUnwrap(tree).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func makeService(_ root: URL, configuration: DomainIgnoreConfiguration) -> MCPDomainCanonicalWorkspaceService {
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
            resolvePath: { raw, roots, _ in
                raw.hasPrefix("/") ? URL(fileURLWithPath: raw, isDirectory: true) : roots[0].appendingPathComponent(raw)
            },
            ignoreConfiguration: { configuration }
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
