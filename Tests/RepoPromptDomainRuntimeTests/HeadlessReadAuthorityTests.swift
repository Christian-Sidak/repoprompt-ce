import Foundation
import MCP
@testable import RepoPromptDomainRuntime
import XCTest

/// M8Q: headless explicit `read_file` follows the app's explicit-read contract — ignored files are
/// readable (ignore filters discovery, not authorization); final-component links, symlinked
/// components under `skip_symlinks`, outside-root targets, and non-regular files are refused — and
/// reads through a no-follow canonical walk so a post-authorization symlink swap fails closed.
final class HeadlessReadAuthorityTests: XCTestCase {
    private static let outsideToken = "OUTSIDE_ROOT_SECRET"

    func testIgnoredFileIsReadable() async throws {
        let fixture = try makeFixture()
        let text = try await read("real/debug.log", fixture, skipSymlinks: true)
        XCTAssertEqual(text, "log line")
    }

    func testFinalComponentLinkIsRefusedUnderEitherPolicy() async throws {
        let fixture = try makeFixture()
        for skipSymlinks in [true, false] {
            await assertRefused("linkfile.swift", fixture, skipSymlinks: skipSymlinks, with: .symbolicLinkPath)
            await assertRefused("secret.swift", fixture, skipSymlinks: skipSymlinks, with: .symbolicLinkPath)
        }
    }

    func testSymlinkedDirectoryComponentFollowsPolicy() async throws {
        let fixture = try makeFixture()
        await assertRefused("linkdir/a.swift", fixture, skipSymlinks: true, with: .symlinkComponent)
        let followed = try await read("linkdir/a.swift", fixture, skipSymlinks: false)
        XCTAssertEqual(followed, "struct A {}\n")
    }

    func testOutsideRootTargetsAreRefused() async throws {
        let fixture = try makeFixture()
        await assertRefused("outside/ext.swift", fixture, skipSymlinks: true, with: .symlinkComponent)
        await assertRefused("outside/ext.swift", fixture, skipSymlinks: false, with: .outsideCanonicalRoot)
        await assertRefused("up/ext.swift", fixture, skipSymlinks: false, with: .outsideCanonicalRoot)
        await assertRefused("../external/ext.swift", fixture, skipSymlinks: false, with: .outsideRoot)
        await assertRefused(
            fixture.external.appendingPathComponent("ext.swift").path,
            fixture,
            skipSymlinks: false,
            with: .outsideRoot
        )
    }

    func testDirectoryIsNotARegularFile() async throws {
        let fixture = try makeFixture()
        await assertRefused("real", fixture, skipSymlinks: true, with: .notARegularFile)
    }

    func testDirectoryComponentSwappedForLinkAfterAuthorizationFailsClosed() throws {
        let fixture = try makeFixture()
        let target = try HeadlessReadAuthority.authorize(
            rawPath: "real/a.swift",
            roots: [fixture.root],
            skipSymlinks: true
        )
        let real = fixture.root.appendingPathComponent("real")
        try FileManager.default.moveItem(at: real, to: fixture.root.appendingPathComponent("real-moved"))
        try FileManager.default.createSymbolicLink(at: real, withDestinationURL: fixture.external)
        try Data("\(Self.outsideToken)\n".utf8).write(to: fixture.external.appendingPathComponent("a.swift"))

        XCTAssertThrowsError(try HeadlessReadAuthority.readContained(target, limit: 1_000_000)) { error in
            XCTAssertEqual(error as? MCPDomainCanonicalReadError, .pathChangedDuringRead)
        }
    }

    func testFinalFileSwappedForLinkAfterAuthorizationFailsClosed() throws {
        let fixture = try makeFixture()
        let target = try HeadlessReadAuthority.authorize(
            rawPath: "real/a.swift",
            roots: [fixture.root],
            skipSymlinks: true
        )
        let file = fixture.root.appendingPathComponent("real/a.swift")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(
            at: file,
            withDestinationURL: fixture.external.appendingPathComponent("secret.swift")
        )

        XCTAssertThrowsError(try HeadlessReadAuthority.readContained(target, limit: 1_000_000)) { error in
            XCTAssertEqual(error as? MCPDomainCanonicalReadError, .pathChangedDuringRead)
        }
    }

    // MARK: - Helpers

    private struct Fixture {
        let root: URL
        let external: URL
    }

    /// ```
    /// .gitignore            *.log
    /// real/a.swift, real/debug.log
    /// linkdir -> real       linkfile.swift -> real/a.swift
    /// outside -> <external> up -> ../external
    /// secret.swift -> <external>/secret.swift
    /// <external>/ext.swift, <external>/secret.swift            (both contain the outside token)
    /// ```
    private func makeFixture() throws -> Fixture {
        let parent = try makeDirectory("headless-read-authority")
        let root = parent.appendingPathComponent("root", isDirectory: true)
        let external = parent.appendingPathComponent("external", isDirectory: true)
        try write("struct Ext {} // \(Self.outsideToken)\n", to: external.appendingPathComponent("ext.swift"))
        try write("let secret = \"\(Self.outsideToken)\"\n", to: external.appendingPathComponent("secret.swift"))
        try write("*.log\n", to: root.appendingPathComponent(".gitignore"))
        try write("struct A {}\n", to: root.appendingPathComponent("real/a.swift"))
        try write("log line", to: root.appendingPathComponent("real/debug.log"))
        let links: [(String, String)] = [
            ("linkdir", "real"),
            ("linkfile.swift", "real/a.swift"),
            ("outside", external.path),
            ("up", "../external"),
            ("secret.swift", external.appendingPathComponent("secret.swift").path)
        ]
        for (link, destination) in links {
            try FileManager.default.createSymbolicLink(
                atPath: root.appendingPathComponent(link).path,
                withDestinationPath: destination
            )
        }
        return Fixture(root: root, external: external)
    }

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

    private func read(_ path: String, _ fixture: Fixture, skipSymlinks: Bool) async throws -> String? {
        let value = try await makeService(fixture.root, skipSymlinks: skipSymlinks)
            .readFile(readRequest(["path": .string(path)]))
            .mcpValue()
        return value.stringValue
    }

    private func assertRefused(
        _ path: String,
        _ fixture: Fixture,
        skipSymlinks: Bool,
        with expected: MCPDomainCanonicalReadError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            let text = try await read(path, fixture, skipSymlinks: skipSymlinks)
            XCTFail("\(path) (skip=\(skipSymlinks)) was read: \(text ?? "nil")", file: file, line: line)
        } catch let error as MCPDomainCanonicalReadError {
            XCTAssertEqual(error, expected, "\(path) (skip=\(skipSymlinks))", file: file, line: line)
        } catch {
            XCTFail("\(path) (skip=\(skipSymlinks)): unexpected \(error)", file: file, line: line)
        }
    }

    private func makeService(_ root: URL, skipSymlinks: Bool) -> MCPDomainCanonicalWorkspaceService {
        let snapshot = DomainCanonicalWorkspaceSnapshot(
            identity: DomainContextIdentity(workspaceID: UUID(), contextID: UUID()),
            roots: [root],
            prompt: "",
            selection: []
        )
        let configuration = DomainIgnoreConfiguration(globalPatterns: "", skipSymlinks: skipSymlinks)
        return MCPDomainCanonicalWorkspaceService(adapter: DomainCanonicalWorkspaceAdapter(
            toolSnapshot: { _ in snapshot },
            readSnapshot: { _ in snapshot },
            mutate: { _, _ in snapshot },
            // Deliberately non-resolving: the read authority must not depend on the adapter to
            // enforce containment or symlink policy.
            resolvePath: { raw, roots, _ in
                raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : roots[0].appendingPathComponent(raw)
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
