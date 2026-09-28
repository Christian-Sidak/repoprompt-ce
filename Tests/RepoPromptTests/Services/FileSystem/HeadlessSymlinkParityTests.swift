import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// M8P: for the same fixture, ignore rules, and `skip_symlinks` value, headless enumeration lists
/// exactly the files the app will discover and read: its raw crawl
/// (`FileSystemService.gatherPathsUsingEnumerator`) filtered by its authoritative
/// `catalogRegularFileEligibility`. The raw crawl alone is not the contract — with links followed it
/// enumerates a file link and files beneath a link escaping the root, which the app's eligibility
/// (and content-read validation) then refuses; headless never lists them.
final class HeadlessSymlinkParityTests: XCTestCase {
    func testSkippingLinksMatchesApp() async throws {
        try await assertParity(skipSymlinks: true, expected: [".gitignore", "loop/b.swift", "real/a.swift"])
    }

    func testFollowingLinksMatchesAppEligibility() async throws {
        let (appItems, service) = try await assertParity(
            skipSymlinks: false,
            expected: [".gitignore", "linkdir/a.swift", "loop/b.swift", "real/a.swift"]
        )
        // Evidence that the raw crawl is broader than the app's read/discovery authority.
        XCTAssertEqual(appItems["linkfile.swift"], false)
        XCTAssertEqual(appItems["outside/ext.swift"], false)
        let fileLink = await service.catalogRegularFileEligibility(relativePath: "linkfile.swift")
        XCTAssertEqual(fileLink, .ineligible(.symbolicLink))
        let escaped = await service.catalogRegularFileEligibility(relativePath: "outside/ext.swift")
        XCTAssertEqual(escaped, .ineligible(.outsideCanonicalRoot))
    }

    // MARK: - Helpers

    @discardableResult
    private func assertParity(
        skipSymlinks: Bool,
        expected: Set<String>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> (appItems: [String: Bool], service: FileSystemService) {
        let root = try makeFixture()
        let authority = GlobalIgnoreDefaultsAuthority()
        authority.publish("")
        await IgnoreRulesManager.shared.setGlobalDefaultsAuthorityOverride(authority)
        addTeardownBlock { await IgnoreRulesManager.shared.setGlobalDefaultsAuthorityOverride(nil) }

        let service = try await FileSystemService(path: root.path, skipSymlinks: skipSymlinks)
        let appItems = try await service.gatherPathsUsingEnumerator(
            rootURL: root,
            skipSymlinks: skipSymlinks,
            baseRelativePath: ""
        )
        var appFiles: Set<String> = []
        for (path, isDirectory) in appItems where !isDirectory {
            if await service.catalogRegularFileEligibility(relativePath: path) == .eligible {
                appFiles.insert(path)
            }
        }

        let headlessFiles = try await Set(headlessListedPaths(
            root: root,
            configuration: DomainIgnoreConfiguration(globalPatterns: "", skipSymlinks: skipSymlinks)
        ))

        XCTAssertEqual(headlessFiles, appFiles, file: file, line: line)
        XCTAssertEqual(appFiles, expected, file: file, line: line)
        return (appItems, service)
    }

    /// ```
    /// .gitignore            *.log, build/
    /// real/a.swift, real/debug.log
    /// linkdir -> real       linkfile.swift -> real/a.swift     build -> real
    /// loop/b.swift          loop/self -> ..  (the root)
    /// outside -> <external>/ (ext.swift)
    /// ```
    private func makeFixture() throws -> URL {
        let parent = try makeDirectory("headless-symlink-parity")
        let root = parent.appendingPathComponent("root", isDirectory: true)
        let external = parent.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write("struct Ext {}\n", to: external.appendingPathComponent("ext.swift"))
        try write("*.log\nbuild/\n", to: root.appendingPathComponent(".gitignore"))
        try write("struct A {}\n", to: root.appendingPathComponent("real/a.swift"))
        try write("x", to: root.appendingPathComponent("real/debug.log"))
        try write("struct B {}\n", to: root.appendingPathComponent("loop/b.swift"))
        let links: [(String, String)] = [
            ("linkdir", "real"),
            ("linkfile.swift", "real/a.swift"),
            ("build", "real"),
            ("loop/self", ".."),
            ("outside", external.path)
        ]
        for (link, destination) in links {
            try FileManager.default.createSymbolicLink(
                atPath: root.appendingPathComponent(link).path,
                withDestinationPath: destination
            )
        }
        return root
    }

    /// Kernel-canonical temporary directory (`/private/var/...`), the spelling both crawls report.
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
}
