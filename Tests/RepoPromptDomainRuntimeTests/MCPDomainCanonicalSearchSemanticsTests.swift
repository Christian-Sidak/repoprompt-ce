import Foundation
import MCP
@testable import RepoPromptDomainRuntime
import XCTest

/// M12/M13: headless `file_search` semantics that must match the app backend (proven end to end by
/// `MCPBackendParityHarnessTests.testFileSearchParityAndLatencyGate`), plus the shared owners both
/// backends use: pattern heuristics (`auto` mode, regex auto-detection, path-stage glob/regex choice),
/// the line model, and the `max_results` contract.
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

    // MARK: - M13: capped selection order, line model, and path-stage semantics

    /// The app scans files in full-path order (`a-z.txt` < `a.txt` < `a/b.txt`, since `-` < `.` < `/`),
    /// so a capped search keeps the first hits in that order, never a depth-first walk order.
    func testCappedHitsFollowFullPathOrderNotWalkOrder() async throws {
        let service = try makeService(files: [
            "order/a/b.txt": "orderMarker\n",
            "order/a.txt": "orderMarker\n",
            "order/a-z.txt": "orderMarker\n"
        ])
        let content = try await search(service, ["pattern": .string("orderMarker"), "mode": .string("content"), "max_results": .int(2)])
        XCTAssertEqual(paths(content), ["order/a-z.txt", "order/a.txt"])
        let pathHits = try await search(service, ["pattern": .string("order/a"), "mode": .string("path"), "max_results": .int(2)])
        XCTAssertEqual(paths(pathHits), ["order/a-z.txt", "order/a.txt"])
    }

    /// Lines end at LF, CR, or CRLF, and a trailing terminator starts no phantom empty line (an empty
    /// file has no lines), as in the app's line index.
    func testEmptyLineRegexMatchesOnlyRealLines() async throws {
        let service = try makeService(files: ["blank.txt": "above\n\nbelow\n", "plain.txt": "x\n", "empty.txt": ""])
        let object = try await search(service, ["pattern": .string("^$"), "mode": .string("content"), "regex": .bool(true)])
        XCTAssertEqual(object["matches"], .array([.object(["path": .string("blank.txt"), "line": .int(2), "text": .string("")])]))
        let count = try await search(service, ["pattern": .string("^$"), "mode": .string("content"), "regex": .bool(true), "count_only": .bool(true)])
        XCTAssertEqual(count["count"], .int(1))
    }

    func testCRLFAndCRLineNumbers() async throws {
        let service = try makeService(files: ["crlf.txt": "first\r\nsecond marker\r\n", "cr.txt": "first\rsecond marker\r"])
        let object = try await search(service, ["pattern": .string("marker"), "mode": .string("content")])
        XCTAssertEqual(object["matches"], .array([
            .object(["path": .string("cr.txt"), "line": .int(2), "text": .string("second marker")]),
            .object(["path": .string("crlf.txt"), "line": .int(2), "text": .string("second marker")])
        ]))
    }

    /// Like the app, an explicit `regex: true` wildcard-only path pattern is a glob, and an
    /// uncompilable path regex falls back to glob/literal matching instead of failing.
    func testPathStageRegexFallsBackLikeTheApp() async throws {
        let service = try makeService(files: ["src/a.swift": "x\n", "b.md": "x\n", "docs/call(unclosed.txt": "x\n"])
        let glob = try await search(service, ["pattern": .string("*.swift"), "mode": .string("path"), "regex": .bool(true)])
        XCTAssertEqual(paths(glob), ["src/a.swift"])
        let autoGlob = try await search(service, ["pattern": .string("*.swift"), "regex": .bool(true)])
        XCTAssertEqual(paths(autoGlob), ["src/a.swift"], "auto mode infers a path search")
        let fallback = try await search(service, ["pattern": .string("(unclosed"), "mode": .string("path"), "regex": .bool(true)])
        XCTAssertEqual(paths(fallback), ["docs/call(unclosed.txt"])
        do {
            _ = try await service.searchFiles(readRequest(["pattern": .string("(unclosed"), "mode": .string("content"), "regex": .bool(true)]))
            XCTFail("an uncompilable content regex stays rejected (documented divergence)")
        } catch {}
    }

    /// The app's path stage has no whole-word mode, retries a glob with its friendly candidates, and
    /// treats only `*` and `?` as path wildcards (`[` stays literal).
    func testPathStageMatchingMirrorsTheApp() async throws {
        let service = try makeService(files: ["src/search_target.txt": "x\n", "src/a.swift": "x\n", "a[1].txt": "x\n"])
        let wholeWord = try await search(service, ["pattern": .string("search"), "mode": .string("path"), "whole_word": .bool(true)])
        XCTAssertEqual(paths(wholeWord), ["src/search_target.txt"])
        let suffix = try await search(service, ["pattern": .string("src/*.sw"), "mode": .string("path")])
        XCTAssertEqual(paths(suffix), ["src/a.swift"])
        let anyDepth = try await search(service, ["pattern": .string("a.sw*"), "mode": .string("path")])
        XCTAssertEqual(paths(anyDepth), ["src/a.swift"])
        let bracket = try await search(service, ["pattern": .string("a[1]"), "mode": .string("path"), "regex": .bool(false)])
        XCTAssertEqual(paths(bracket), ["a[1].txt"])
    }

    func testPathGlobHeuristicsTable() {
        XCTAssertEqual(
            FileSearchPatternHeuristics.pathGlobCandidates(for: "a.sw"),
            ["a.sw", "**/a.sw", "a.sw*", "**/a.sw*"]
        )
        XCTAssertEqual(FileSearchPatternHeuristics.pathGlobCandidates(for: "src/*.sw"), ["src/*.sw", "src/*.sw*"])
        // Not ending in a wildcard, so the trailing-`*` candidates follow (the app's pre-M12 behavior).
        XCTAssertEqual(
            FileSearchPatternHeuristics.pathGlobCandidates(for: "*.swift"),
            ["*.swift", "**/*.swift", "*.swift*", "**/*.swift*"]
        )
        XCTAssertFalse(FileSearchPatternHeuristics.pathStageUsesRegex("*.swift", isRegex: true))
        XCTAssertTrue(FileSearchPatternHeuristics.pathStageUsesRegex(".*\\.swift", isRegex: true))
        XCTAssertTrue(FileSearchPatternHeuristics.pathStageUsesRegex("(unclosed", isRegex: true))
        XCTAssertFalse(FileSearchPatternHeuristics.pathStageUsesRegex("plain", isRegex: false))
    }

    func testSearchLineSplitterTable() {
        let table: [(String, [String])] = [
            ("", []),
            ("a", ["a"]),
            ("a\n", ["a"]),
            ("a\n\n", ["a", ""]),
            ("a\r\nb", ["a", "b"]),
            ("a\rb\r", ["a", "b"]),
            ("a\n\rb", ["a", "", "b"]),
            ("a\u{2028}b", ["a\u{2028}b"])
        ]
        for (text, expected) in table {
            XCTAssertEqual(FileSearchLines.lines(of: text).map(String.init), expected, text.debugDescription)
        }
    }

    // MARK: - M13: `max_results` contract

    func testOmittedMaxResultsUsesTheSharedDefaultPerStage() async throws {
        let limit = FileSearchResultLimits.defaultMaxResults
        let lines = String(repeating: "hit\n", count: limit + 5)
        let service = try makeService(files: ["hit.txt": lines])
        let content = try await search(service, ["pattern": .string("hit"), "mode": .string("content")])
        XCTAssertEqual(content["count"], .int(limit))
        let both = try await search(service, ["pattern": .string("hit"), "mode": .string("both")])
        XCTAssertEqual(both["count"], .int(limit + 1), "the path stage has its own cap: one path hit plus a full content page")
    }

    /// The shared schema states the per-stage contract from `FileSearchResultLimits`, not the vendored
    /// "Maximum total results" wording, and canonicalization is idempotent.
    func testFileSearchSchemaDescribesThePerStageLimit() throws {
        let vendored = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.test_vendoredDefinition(named: "file_search"))
        XCTAssertTrue(
            vendored.description.contains(FileSearchResultLimits.vendoredMaxResultsOptionLine),
            "the vendored wording drifted; update FileSearchResultLimits.vendoredMaxResultsOptionLine"
        )
        let canonical = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: "file_search"))
        XCTAssertTrue(canonical.description.contains(FileSearchResultLimits.maxResultsOptionLine))
        XCTAssertFalse(canonical.description.contains(FileSearchResultLimits.vendoredMaxResultsOptionLine))
        let properties = try XCTUnwrap(canonical.inputSchema.objectValue?["properties"]?.objectValue)
        let maxResults = try XCTUnwrap(properties["max_results"]?.objectValue)
        XCTAssertEqual(maxResults["description"], .string(FileSearchResultLimits.maxResultsPropertyDescription))
        XCTAssertEqual(maxResults["type"], .string("integer"))
        XCTAssertEqual(MCPDomainCanonicalToolDefinitions.test_canonicalizeFileSearchResultLimit(canonical), canonical)
    }

    // MARK: - Fixture

    private func paths(_ object: [String: Value]) -> [String] {
        object["matches"]?.arrayValue?.compactMap { $0.objectValue?["path"]?.stringValue } ?? []
    }

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
