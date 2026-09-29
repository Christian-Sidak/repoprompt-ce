import Foundation
import MCP
@testable import RepoPromptDomainRuntime
import XCTest

/// Contract tests for M8C: direct-headless physical reads are bounded and never turn an empty
/// selection into a whole-root walk.
final class MCPDomainCanonicalWorkspaceBoundsTests: XCTestCase {
    func testCodeStructureWithEmptySelectionDoesNotWalkTheRoot() async throws {
        let root = try makeRoot(files: ["a.swift": "struct A {}\n"])
        let service = makeService(root: root, selection: [])

        let value = try await service.inspectCodeStructure(readRequest([:])).mcpValue()
        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(object["files"], .array([]))
        XCTAssertNotNil(object["note"]?.stringValue)
    }

    func testCodeStructureExpandsExplicitDirectoriesToSupportedFilesOnly() async throws {
        let root = try makeRoot(files: [
            "src/a.swift": "struct A { func run() {} }\n",
            "src/notes.txt": "not code\n"
        ])
        let service = makeService(root: root, selection: [])

        let value = try await service.inspectCodeStructure(readRequest(["paths": .array([.string("src")])])).mcpValue()
        let files = try XCTUnwrap(value.objectValue?["files"]?.arrayValue)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].objectValue?["path"]?.stringValue?.hasSuffix("src/a.swift") == true)
        XCTAssertNil(value.objectValue?["truncated"])
    }

    func testReadFileRejectsFilesOverTheReadLimit() async throws {
        let root = try makeRoot(files: [:])
        let large = root.appendingPathComponent("large.txt")
        try Data(count: MCPDomainCanonicalReadBounds.maximumReadFileBytes + 1).write(to: large)
        let service = makeService(root: root, selection: [])

        do {
            _ = try await service.readFile(readRequest(["path": .string("large.txt")]))
            XCTFail("Expected the read limit to reject the file")
        } catch let error as MCPDomainCanonicalReadError {
            XCTAssertEqual(error, .fileTooLarge(
                byteCount: MCPDomainCanonicalReadBounds.maximumReadFileBytes + 1,
                limit: MCPDomainCanonicalReadBounds.maximumReadFileBytes
            ))
        }
    }

    func testReadFileDecodesByteOrderMarksAndRejectsBinary() async throws {
        let root = try makeRoot(files: [:])
        try (Data([0xEF, 0xBB, 0xBF]) + Data("one\ntwo\nthree".utf8))
            .write(to: root.appendingPathComponent("bom8.txt"))
        try XCTUnwrap("wide\ntext".data(using: .utf16)).write(to: root.appendingPathComponent("bom16.txt"))
        try Data([0xC3, 0x28, 0xFF]).write(to: root.appendingPathComponent("binary.bin"))
        let service = makeService(root: root, selection: [])

        let sliced = try await service.readFile(readRequest([
            "path": .string("bom8.txt"),
            "start_line": .int(2),
            "limit": .int(1)
        ])).mcpValue()
        XCTAssertEqual(sliced.stringValue, "two")

        let wide = try await service.readFile(readRequest(["path": .string("bom16.txt")])).mcpValue()
        XCTAssertEqual(wide.stringValue, "wide\ntext")

        do {
            _ = try await service.readFile(readRequest(["path": .string("binary.bin")]))
            XCTFail("Expected undecodable text to fail")
        } catch let error as MCPDomainCanonicalReadError {
            XCTAssertEqual(error, .undecodableText)
        }
    }

    func testSearchSkipsOversizedFileContentAndReportsIt() async throws {
        let root = try makeRoot(files: ["small.txt": "needle here\nnothing\n"])
        var oversized = Data(repeating: UInt8(ascii: "x"), count: MCPDomainCanonicalReadBounds.maximumSearchFileBytes)
        oversized.append(contentsOf: Array("\nneedle\n".utf8))
        try oversized.write(to: root.appendingPathComponent("huge.txt"))
        let service = makeService(root: root, selection: [])

        let value = try await service.searchFiles(readRequest([
            "pattern": .string("needle"),
            "mode": .string("content")
        ])).mcpValue()
        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(object["count"], .int(1))
        XCTAssertEqual(object["skipped_large_files"], .int(1))
        XCTAssertNil(object["truncated"])
        let match = try XCTUnwrap(object["matches"]?.arrayValue?.first?.objectValue)
        XCTAssertEqual(match["path"], .string("small.txt"))
        XCTAssertEqual(match["line"], .int(1))
    }

    // MARK: - Fixture

    private func makeRoot(files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-canonical-bounds-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for (relative, contents) in files {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }
        return root
    }

    private func makeService(root: URL, selection: [String]) -> MCPDomainCanonicalWorkspaceService {
        let snapshot = DomainCanonicalWorkspaceSnapshot(
            identity: DomainContextIdentity(workspaceID: UUID(), contextID: UUID()),
            roots: [root],
            prompt: "",
            selection: selection
        )
        return MCPDomainCanonicalWorkspaceService(adapter: DomainCanonicalWorkspaceAdapter(
            toolSnapshot: { _ in snapshot },
            readSnapshot: { _ in snapshot },
            mutate: { _, _ in snapshot },
            resolvePath: { raw, roots, _ in roots[0].appendingPathComponent(raw) }
        ))
    }

    private func readRequest(_ arguments: [String: Value]) throws -> DomainPhysicalReadRequest {
        try DomainPhysicalReadRequest(
            request: DomainPhysicalToolRequest(
                argumentsJSON: JSONEncoder().encode(arguments),
                securityContext: nil
            ),
            context: DomainReadInvocationContext(handle: nil, connectionID: nil),
            sideEffects: MCPDomainReadSideEffectEmitter(submit: { _, _, _, _, _ in })
        )
    }
}
