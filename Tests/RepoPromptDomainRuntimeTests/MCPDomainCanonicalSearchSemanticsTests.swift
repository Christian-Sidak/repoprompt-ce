import Foundation
import MCP
@testable import RepoPromptDomainRuntime
import XCTest

/// M12: headless `file_search` semantics that must match the app backend (proven end to end by
/// `MCPBackendParityHarnessTests.testFileSearchParityAndLatencyGate`), plus the shared pattern
/// heuristics both backends now use for `auto` mode and regex auto-detection.
final class MCPDomainCanonicalSearchSemanticsTests: XCTestCase {
    // MARK: - Shared heuristics

    func testInferredAutoModeTable() {
        let table: [(String, FileSearchInferredMode)] = [
            ("foo|bar", .content), // regex syntax searches content
            ("*.swift", .path),
            (".gitignore", .path),
            ("src/search", .path),
            ("a long sentence with spaces", .content),
            ("go", .both), // short patterns search both
            ("SearchTarget", .both), // identifier-like tokens search both
            ("MyClass.swift", .both),
            ("go()", .content)
        ]
        for (pattern, expected) in table {
            XCTAssertEqual(FileSearchPatternHeuristics.inferredAutoMode(pattern), expected, pattern)
        }
    }

    func testRegexSyntaxDetectionTable() {
        let regex = ["foo|bar", "(foo|bar)", "\\bword\\b", "a.*b", "[abc]", "a{2,3}", "^start", "end$", "(?i)x"]
        let literal = ["go()", "frame(minWidth:", "plain", "a.b", "run() { }"]
        for pattern in regex {
            XCTAssertTrue(FileSearchPatternHeuristics.containsRegexSyntax(pattern), pattern)
        }
        for pattern in literal {
            XCTAssertFalse(FileSearchPatternHeuristics.containsRegexSyntax(pattern), pattern)
        }
    }

    // MARK: - Headless search semantics

    func testWhitespaceOnlyPatternIsRejectedAsEmpty() async throws {
        let service = try makeService(files: ["a.txt": "    indented\n"])
        do {
            _ = try await service.searchFiles(readRequest(["pattern": .string("   "), "mode": .string("content")]))
            XCTFail("Expected a whitespace-only pattern to be rejected")
        } catch let error as MCPError {
            XCTAssertTrue("\(error)".contains("pattern cannot be empty"), "\(error)")
        }
    }

    func testRegexContentSearchIsCaseInsensitive() async throws {
        let service = try makeService(files: ["a.txt": "let parityMarker = 1\n"])
        let object = try await search(service, ["pattern": .string("PARITY[a-z]+"), "mode": .string("content"), "regex": .bool(true)])
        XCTAssertEqual(object["count"], .int(1))
    }

    func testMaxResultsCapsPathAndContentStagesSeparately() async throws {
        let service = try makeService(files: ["limit.txt": "limit one\nlimit two\n"])
        let object = try await search(service, ["pattern": .string("limit"), "mode": .string("both"), "max_results": .int(1)])
        let matches = try XCTUnwrap(object["matches"]?.arrayValue?.compactMap(\.objectValue))
        XCTAssertEqual(matches.filter { $0["line"] == nil }.count, 1, "one path hit")
        XCTAssertEqual(matches.compactMap { $0["line"] }, [.int(1)], "one content hit")
        XCTAssertEqual(object["count"], .int(2))
    }

    func testCountOnlyCountsEveryContentMatchBeyondMaxResults() async throws {
        let service = try makeService(files: ["a.txt": "hit\nhit\n", "b.txt": "hit\n"])
        let object = try await search(service, [
            "pattern": .string("hit"),
            "mode": .string("content"),
            "count_only": .bool(true),
            "max_results": .int(1)
        ])
        XCTAssertEqual(object["count"], .int(3))
        XCTAssertNil(object["matches"])
    }

    func testAutoModeSearchesPathsForIdentifierPatterns() async throws {
        let service = try makeService(files: ["src/search_target.txt": "unrelated\n"])
        let object = try await search(service, ["pattern": .string("search_target")])
        XCTAssertEqual(object["matches"], .array([.object(["path": .string("src/search_target.txt")])]))
    }

    func testCallParenthesesStayLiteralWithoutRegexFlag() async throws {
        let service = try makeService(files: ["a.txt": "func go() {}\n", "b.txt": "long ago\n"])
        let object = try await search(service, ["pattern": .string("go()"), "mode": .string("content")])
        let paths = try XCTUnwrap(object["matches"]?.arrayValue?.compactMap { $0.objectValue?["path"]?.stringValue })
        XCTAssertEqual(paths, ["a.txt"])
    }

    func testLiteralContentWildcardsMatchAsCharactersButGlobPaths() async throws {
        let service = try makeService(files: ["notes.txt": "is it done? yes\n", "src/done1.txt": "unrelated\n"])
        let content = try await search(service, ["pattern": .string("done?"), "mode": .string("content"), "regex": .bool(false)])
        XCTAssertEqual(content["count"], .int(1), "a literal content `?` is a character, not a glob")
        let paths = try await search(service, ["pattern": .string("src/done?.txt"), "mode": .string("path"), "regex": .bool(false)])
        XCTAssertEqual(paths["matches"], .array([.object(["path": .string("src/done1.txt")])]), "path wildcards still glob")
    }

    // MARK: - Fixture

    private func search(
        _ service: MCPDomainCanonicalWorkspaceService,
        _ arguments: [String: Value]
    ) async throws -> [String: Value] {
        let value = try await service.searchFiles(readRequest(arguments)).mcpValue()
        return try XCTUnwrap(value.objectValue)
    }

    private func makeService(files: [String: String]) throws -> MCPDomainCanonicalWorkspaceService {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-canonical-search-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for (relative, contents) in files {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
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
