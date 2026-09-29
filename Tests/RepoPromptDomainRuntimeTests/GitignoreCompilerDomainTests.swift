import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

/// M8L: the gitignore compiler the app crawl uses now lives in the domain runtime, so headless
/// code can apply the same matcher. This covers the moved entry points from the headless module.
final class GitignoreCompilerDomainTests: XCTestCase {
    func testCompiledRulesHonorAnchoringDirectoryOnlyNegationAndWildstar() {
        let rules = GitignoreCompiler.compile(content: """
        # comment
        /build/
        *.log
        !keep.log
        **/node_modules/
        docs/generated
        """)

        XCTAssertTrue(rules.denies("build", isDirectory: true))
        XCTAssertFalse(rules.denies("src/build", isDirectory: true), "leading slash anchors to the root")
        XCTAssertFalse(rules.denies("build", isDirectory: false), "trailing slash matches directories only")
        XCTAssertTrue(rules.denies("logs/debug.log", isDirectory: false))
        XCTAssertFalse(rules.denies("keep.log", isDirectory: false), "negation re-includes")
        XCTAssertTrue(rules.denies("a/b/node_modules", isDirectory: true))
        XCTAssertTrue(rules.denies("docs/generated", isDirectory: true))
        XCTAssertTrue(rules.hasAnyNegativePattern)
    }

    /// `directoryPath` prefixes only anchored patterns (leading `/` or an inner `/`). Basename
    /// patterns stay unanchored: restricting a nested ignore file's basename rules to its
    /// directory is the caller's job (the app's hierarchical evaluator), not the compiler's.
    func testDirectoryPathAnchorsOnlyAnchoredPatterns() {
        let rules = GitignoreCompiler.compile(content: "/out\nbuild/cache\n*.tmp\n", directoryPath: "sub")

        XCTAssertTrue(rules.denies("sub/out", isDirectory: true))
        XCTAssertFalse(rules.denies("out", isDirectory: true), "a root-anchored pattern is scoped to its directory")
        XCTAssertTrue(rules.denies("sub/build/cache", isDirectory: true))
        XCTAssertFalse(rules.denies("build/cache", isDirectory: true), "an inner-slash pattern is scoped too")

        XCTAssertTrue(rules.denies("sub/a.tmp", isDirectory: false))
        XCTAssertTrue(rules.denies("a.tmp", isDirectory: false), "basename patterns are not scoped by the compiler")
    }
}
