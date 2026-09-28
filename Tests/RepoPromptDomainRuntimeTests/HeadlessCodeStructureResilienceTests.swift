import Foundation
import MCP
@testable import RepoPromptDomainRuntime
import XCTest

/// M8R: headless `get_code_structure` is bounded and fault-isolated. Every source is read only
/// through the `read_file` authority (M8Q), capped per file at the syntax engine's oversize limit and
/// charged against a per-call byte budget before any byte is read; one file's failure becomes that
/// file's diagnostic instead of failing the batch, and only cancellation ends the call.
final class HeadlessCodeStructureResilienceTests: XCTestCase {
    func testOneFilesFailureDoesNotFailTheBatch() async throws {
        let root = try makeRoot()
        try write("struct A { func run() {} }\n", to: root.appendingPathComponent("src/a.swift"))
        let locked = root.appendingPathComponent("src/locked.swift")
        try write("struct Locked {}\n", to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let oversize = MCPDomainCanonicalReadBounds.maximumCodeStructureFileBytes + 1
        try Data(repeating: UInt8(ascii: "a"), count: oversize).write(to: root.appendingPathComponent("src/big.swift"))

        let files = try await codeStructure(root, paths: ["src"])

        XCTAssertEqual(files["a.swift"]?["language"], .string("swift"))
        XCTAssertNil(files["a.swift"]?["diagnostic"])
        XCTAssertEqual(files["a.swift"]?["signatures"]?.stringValue?.isEmpty, false)
        XCTAssertEqual(files["locked.swift"]?["diagnostic"], .string("unreadable"))
        XCTAssertEqual(files["big.swift"]?["diagnostic"], .string("source_oversize"))
    }

    func testExplicitPathsAreReadOnlyThroughTheReadAuthority() async throws {
        let root = try makeRoot()
        try write("gen.swift\n", to: root.appendingPathComponent(".gitignore"))
        try write("struct A {}\n", to: root.appendingPathComponent("real/a.swift"))
        try write("struct Gen { func make() {} }\n", to: root.appendingPathComponent("gen.swift"))
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("link.swift").path,
            withDestinationPath: "real/a.swift"
        )
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("linkdir").path,
            withDestinationPath: "real"
        )

        let files = try await codeStructure(root, paths: ["link.swift", "linkdir/a.swift", "gen.swift"])

        XCTAssertEqual(files["link.swift"]?["diagnostic"], .string("read_refused"))
        XCTAssertEqual(files["link.swift"]?["reason"], .string("symbolic_link_path"))
        XCTAssertEqual(files["a.swift"]?["reason"], .string("symlink_component"), "linkdir/a.swift under skip_symlinks")
        XCTAssertNil(files["gen.swift"]?["diagnostic"], "an explicitly named ignored file is read, as read_file does")
        XCTAssertEqual(files["gen.swift"]?["signatures"]?.stringValue?.isEmpty, false)
    }

    func testSourceByteBudgetStopsReadingAndReportsTheRemainder() throws {
        let root = try makeRoot()
        // Symbols make a fully mapped file distinguishable from any diagnostic outcome.
        let source = "struct S { func run() {} }\n"
        let candidates = try ["a", "b", "c"].map { name -> MCPDomainCanonicalWorkspaceService.CodeStructureCandidate in
            let url = root.appendingPathComponent("\(name).swift")
            try write(source, to: url)
            return .init(authorizationPath: url.path, displayPath: url.path)
        }

        let results = try MCPDomainCanonicalWorkspaceService.codeStructureResults(
            for: candidates,
            roots: [root],
            skipSymlinks: true,
            sourceByteBudget: source.utf8.count,
            checkCancellation: {}
        )

        XCTAssertTrue(results.budgetExhausted)
        XCTAssertEqual(results.files.map { $0.objectValue?["diagnostic"] }, [
            nil, .string("budget_exhausted"), .string("budget_exhausted")
        ])
        XCTAssertEqual(results.files[0].objectValue?["language"], .string("swift"))
        XCTAssertEqual(results.files[0].objectValue?["signatures"]?.stringValue?.isEmpty, false)
    }

    func testVanishedFileIsReportedMissing() throws {
        let root = try makeRoot()
        let gone = root.appendingPathComponent("gone.swift").path

        let results = try MCPDomainCanonicalWorkspaceService.codeStructureResults(
            for: [.init(authorizationPath: gone, displayPath: gone)],
            roots: [root],
            skipSymlinks: true,
            sourceByteBudget: 1000,
            checkCancellation: {}
        )

        XCTAssertEqual(results.files.first?.objectValue?["diagnostic"], .string("missing"))
    }

    func testCancellationStillEndsTheCall() throws {
        let root = try makeRoot()
        let url = root.appendingPathComponent("a.swift")
        try write("struct A {}\n", to: url)

        XCTAssertThrowsError(try MCPDomainCanonicalWorkspaceService.codeStructureResults(
            for: [.init(authorizationPath: url.path, displayPath: url.path)],
            roots: [root],
            skipSymlinks: true,
            sourceByteBudget: 1000,
            checkCancellation: { throw CancellationError() }
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    // MARK: - Helpers

    /// Code-structure results keyed by file name.
    private func codeStructure(_ root: URL, paths: [String]) async throws -> [String: [String: Value]] {
        let value = try await makeService(root).inspectCodeStructure(readRequest([
            "paths": .array(paths.map(Value.string))
        ])).mcpValue()
        let files = try XCTUnwrap(value.objectValue?["files"]?.arrayValue).compactMap(\.objectValue)
        var byName: [String: [String: Value]] = [:]
        for file in files {
            guard let path = file["path"]?.stringValue else { continue }
            byName[URL(fileURLWithPath: path).lastPathComponent] = file
        }
        return byName
    }

    private func makeRoot() throws -> URL {
        let created = FileManager.default.temporaryDirectory
            .appendingPathComponent("headless-code-structure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
        let canonical = try XCTUnwrap(realpath(created.path, nil))
        defer { free(canonical) }
        let root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    private func makeService(_ root: URL) -> MCPDomainCanonicalWorkspaceService {
        let snapshot = DomainCanonicalWorkspaceSnapshot(
            identity: DomainContextIdentity(workspaceID: UUID(), contextID: UUID()),
            roots: [root],
            prompt: "",
            selection: []
        )
        let configuration = DomainIgnoreConfiguration(globalPatterns: "")
        return MCPDomainCanonicalWorkspaceService(adapter: DomainCanonicalWorkspaceAdapter(
            toolSnapshot: { _ in snapshot },
            readSnapshot: { _ in snapshot },
            mutate: { _, _ in snapshot },
            // Non-resolving: authority must come from the read gates, not the adapter.
            resolvePath: { raw, roots, _ in roots[0].appendingPathComponent(raw) },
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
