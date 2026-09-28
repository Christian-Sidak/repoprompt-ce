import Foundation

/// Ignore-layer assembly shared by the app crawl and headless enumeration. Callers load file
/// contents (with their own I/O and error policy); this type owns layer order and authority.
package enum IgnoreLayerAssembly {
    package struct CompiledRootAuthority {
        package let gitignore: CompiledIgnoreRules?
        package let global: CompiledIgnoreRules
        package let repoIgnore: CompiledIgnoreRules?
        package let cursorignore: CompiledIgnoreRules?

        package init(
            gitignore: CompiledIgnoreRules?,
            global: CompiledIgnoreRules,
            repoIgnore: CompiledIgnoreRules?,
            cursorignore: CompiledIgnoreRules?
        ) {
            self.gitignore = gitignore
            self.global = global
            self.repoIgnore = repoIgnore
            self.cursorignore = cursorignore
        }
    }

    package static func compileRootAuthority(
        gitignoreContent: String?,
        globalIgnoreContent: String,
        repoIgnoreContent: String?,
        cursorignoreContent: String?
    ) -> CompiledRootAuthority {
        CompiledRootAuthority(
            gitignore: gitignoreContent.map { GitignoreCompiler.compile(content: $0) },
            global: GitignoreCompiler.compile(content: globalIgnoreContent),
            repoIgnore: repoIgnoreContent.map { GitignoreCompiler.compile(content: $0) },
            cursorignore: cursorignoreContent.map { GitignoreCompiler.compile(content: $0) }
        )
    }

    /// Builds the authoritative root chain. For Git roots, Git's own ignore chain is a mandatory
    /// floor: global/app controls may add exclusions but their negations cannot re-include a
    /// Git-ignored path. Non-Git callers retain the historical single-chain precedence.
    package static func makeRootRules(
        authority: CompiledRootAuthority,
        respectRepoIgnore: Bool,
        respectCursorignore: Bool,
        policy: IgnoreRulePolicy
    ) -> IgnoreRules {
        let rules = IgnoreRules(policy: policy)
        if let gitignore = authority.gitignore {
            rules.addCompiledLayer(gitignore, authority: .mandatoryGit)
        }
        rules.addCompiledLayer(authority.global, authority: .secondary)
        if respectRepoIgnore, let repoIgnore = authority.repoIgnore {
            rules.addCompiledLayer(repoIgnore, authority: .secondary)
        }
        if respectCursorignore, let cursorignore = authority.cursorignore {
            rules.addCompiledLayer(cursorignore, authority: .secondary)
        }
        return rules
    }

    /// Returns `parent` extended with one directory's own ignore files, compiled relative to that
    /// directory: `.gitignore` as the mandatory Git layer, then `.repo_ignore` and `.cursorignore`
    /// as secondary layers. Pass nil for files that are absent or disabled.
    package static func appendingDirectoryLayers(
        to parent: IgnoreRules,
        policy: IgnoreRulePolicy,
        directoryRelativePath: String,
        gitignoreContent: String?,
        repoIgnoreContent: String?,
        cursorignoreContent: String?
    ) -> IgnoreRules {
        let rules = parent.clone()
        let repositoryRelativeDirectory = policy.repositoryRelativePath(appending: directoryRelativePath)
        if let gitignoreContent {
            rules.addCompiledLayer(
                GitignoreCompiler.compile(content: gitignoreContent, directoryPath: repositoryRelativeDirectory),
                authority: .mandatoryGit
            )
        }
        for content in [repoIgnoreContent, cursorignoreContent].compactMap(\.self) {
            rules.addCompiledLayer(
                GitignoreCompiler.compile(content: content, directoryPath: repositoryRelativeDirectory),
                authority: .secondary
            )
        }
        return rules
    }
}
