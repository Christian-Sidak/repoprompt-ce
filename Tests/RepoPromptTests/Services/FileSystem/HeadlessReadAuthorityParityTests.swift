import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// M8Q: for each path and `skip_symlinks` value, headless explicit `read_file` succeeds exactly when
/// the app's explicit materialization would admit it — `catalogRegularFileEligibility` is `.eligible`
/// or `.ineligible(.ignored)` (ignore rules never refuse an explicit read) — and refuses with the
/// matching reason otherwise.
final class HeadlessReadAuthorityParityTests: XCTestCase {
    private let paths = [
        "real/a.swift", "real/debug.log", "linkfile.swift", "linkdir/a.swift", "linkdir/debug.log",
        "outside/ext.swift", "up/ext.swift", "secret.swift"
    ]

    func testSkippingLinksMatchesAppExplicitReadAuthority() async throws {
        let readable = try await assertParity(skipSymlinks: true)
        XCTAssertEqual(readable, ["real/a.swift", "real/debug.log"])
    }

    func testFollowingLinksMatchesAppExplicitReadAuthority() async throws {
        let readable = try await assertParity(skipSymlinks: false)
        XCTAssertEqual(readable, ["real/a.swift", "real/debug.log", "linkdir/a.swift", "linkdir/debug.log"])
    }

    // MARK: - Helpers

    /// Returns the paths both sides read.
    private func assertParity(skipSymlinks: Bool) async throws -> Set<String> {
        let root = try makeFixture()
        let authority = GlobalIgnoreDefaultsAuthority()
        authority.publish("")
        await IgnoreRulesManager.shared.setGlobalDefaultsAuthorityOverride(authority)
        addTeardownBlock { await IgnoreRulesManager.shared.setGlobalDefaultsAuthorityOverride(nil) }
        let service = try await FileSystemService(path: root.path, skipSymlinks: skipSymlinks)
        let headless = makeHeadlessService(root: root, skipSymlinks: skipSymlinks)

        var readable: Set<String> = []
        for path in paths {
            let eligibility = await service.catalogRegularFileEligibility(relativePath: path)
            let headlessOutcome: Result<String, Error>
            do {
                let result = try await headless.readFile(readRequest(["path": .string(path)]))
                let value = try JSONDecoder().decode(Value.self, from: result.json)
                headlessOutcome = .success(value.stringValue ?? "")
            } catch {
                headlessOutcome = .failure(error)
            }
            switch (eligibility, headlessOutcome) {
            case (.eligible, .success), (.ineligible(.ignored), .success):
                readable.insert(path)
            case let (.eligible, .failure(error)), let (.ineligible(.ignored), .failure(error)):
                XCTFail("\(path) (skip=\(skipSymlinks)): app admits, headless refused with \(error)")
            case let (.ineligible(reason), .failure(error)):
                XCTAssertEqual(
                    error as? MCPDomainCanonicalReadError,
                    Self.headlessError(for: reason),
                    "\(path) (skip=\(skipSymlinks)): app refused with \(reason)"
                )
            case let (.ineligible(reason), .success(text)):
                XCTFail("\(path) (skip=\(skipSymlinks)): app refused (\(reason)), headless read \(text)")
            }
        }
        return readable
    }

    private static func headlessError(for reason: CatalogRegularFileIneligibilityReason) -> MCPDomainCanonicalReadError? {
        switch reason {
        case .symbolicLink: .symbolicLinkPath
        case .symlinkComponent: .symlinkComponent
        case .outsideCanonicalRoot: .outsideCanonicalRoot
        case .outsideRoot: .outsideRoot
        case .nonRegularFile, .missingOrDirectory: .notARegularFile
        case .invalidRelativePath, .ignored: nil
        }
    }

    /// ```
    /// .gitignore            *.log
    /// real/a.swift, real/debug.log
    /// linkdir -> real       linkfile.swift -> real/a.swift
    /// outside -> <external> up -> ../external    secret.swift -> <external>/secret.swift
    /// ```
    private func makeFixture() throws -> URL {
        let created = FileManager.default.temporaryDirectory
            .appendingPathComponent("headless-read-parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
        let canonical = try XCTUnwrap(realpath(created.path, nil))
        defer { free(canonical) }
        let parent = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("root", isDirectory: true)
        let external = parent.appendingPathComponent("external", isDirectory: true)
        let files = [
            external.appendingPathComponent("ext.swift"): "struct Ext {}\n",
            external.appendingPathComponent("secret.swift"): "let secret = 1\n",
            root.appendingPathComponent(".gitignore"): "*.log\n",
            root.appendingPathComponent("real/a.swift"): "struct A {}\n",
            root.appendingPathComponent("real/debug.log"): "log line"
        ]
        for (url, contents) in files {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
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
        return root
    }

    private func makeHeadlessService(root: URL, skipSymlinks: Bool) -> MCPDomainCanonicalWorkspaceService {
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
