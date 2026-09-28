import Foundation

/// The search strategy `file_search` infers for `mode: "auto"`.
package enum FileSearchInferredMode: String, Sendable {
    case path, content, both
}

/// Pure `file_search` pattern heuristics shared by the app (`FileSearchActor`, `RegexToolkit`) and the
/// headless backend (`MCPDomainCanonicalWorkspaceService.searchFiles`), so `auto` mode and regex
/// auto-detection cannot drift between backends. Moved verbatim from the app's search actor.
package enum FileSearchPatternHeuristics {
    private static let regexMeta: Set<Character> = ["(", ")", "[", "]", "{", "}", ".", "*", "+", "?", "|", "^", "$"]

    /// The strategy for `mode: "auto"`, decided from the (trimmed) pattern alone.
    package static func inferredAutoMode(_ raw: String) -> FileSearchInferredMode {
        // Quick heuristics (order matters) - designed for intuitive user experience

        // REGEX PATTERNS should search content, not paths
        if containsRegexSyntax(raw) {
            return .content
        }

        // Strong path indicators should override other signals
        if raw.hasPrefix("*") || raw.hasPrefix(".") {
            return .path
        }

        // Check for wildcards anywhere in the pattern
        if raw.contains("*") || raw.contains("?") {
            return .path
        }

        // Forward slashes are strong path indicators unless it's clearly content (like a sentence)
        if raw.contains("/") {
            // If it has spaces but is short and path-like, still treat as path
            if raw.contains(" "), raw.count > 20 {
                return .content // Long patterns with spaces are likely content
            }
            return .path
        }

        // Backslashes are ambiguous: they may indicate Windows paths, or escaped literal metacharacters.
        if raw.contains("\\") {
            if backslashesOnlyEscapeRegexMeta(raw) {
                return .content
            }
            if raw.contains(" "), raw.count > 20 {
                return .content
            }
            return .path
        }

        // Content indicators
        if raw.contains("\n") { return .content }
        if raw.contains(" "), raw.count > 10 { return .content }

        // Short patterns should search both to be thorough
        if raw.count <= 3 { return .both }

        // Identifier-like tokens (e.g., "Player", "Bomb", "MyClass.swift") should search both
        // paths and content - this is the most intuitive UX for code search
        if isIdentifierLike(raw) { return .both }

        // Medium patterns with spaces are likely content searches
        if raw.contains(" ") { return .content }

        // Everything else defaults to content (most common use case)
        return .content
    }

    private static func backslashesOnlyEscapeRegexMeta(_ raw: String) -> Bool {
        let chars = Array(raw)
        var index = 0
        var sawEscapedMeta = false
        while index < chars.count {
            guard chars[index] == "\\" else {
                index += 1
                continue
            }
            if index + 2 < chars.count,
               chars[index + 1] == "\\",
               regexMeta.contains(chars[index + 2])
            {
                sawEscapedMeta = true
                index += 3
                continue
            }
            if index + 1 < chars.count,
               regexMeta.contains(chars[index + 1])
            {
                sawEscapedMeta = true
                index += 2
                continue
            }
            return false
        }
        return sawEscapedMeta
    }

    /// Checks if a pattern looks like an identifier or filename (no spaces, no regex chars).
    /// Used to determine if auto mode should search both paths and content.
    private static func isIdentifierLike(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }

        // Must be a single token (no spaces or path separators)
        if s.contains(" ") || s.contains("/") || s.contains("\\") { return false }

        // No obvious regex metacharacters
        let forbidden: Set<Character> = ["*", "+", "?", "[", "]", "{", "}", "(", ")", "|", "^", "$"]
        if s.contains(where: forbidden.contains) { return false }

        // Restrict to common identifier/filename characters: letters, digits, dot, underscore, hyphen
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        if s.unicodeScalars.contains(where: { !allowed.contains($0) }) { return false }

        return true
    }

    // MARK: - Path stage

    /// Whether a path pattern has glob wildcards. Only `*` and `?` count: path search matches `[`
    /// literally.
    package static func hasPathWildcards(_ pattern: String) -> Bool {
        pattern.contains("*") || pattern.contains("?")
    }

    /// Whether the path stage matches the (trimmed) pattern as a regex. A `regex` request whose
    /// pattern is only glob wildcards (e.g. "*.swift") prefers glob semantics.
    package static func pathStageUsesRegex(_ trimmedPattern: String, isRegex: Bool) -> Bool {
        let hasWildcards = hasPathWildcards(trimmedPattern)
        let strongRegex = containsRegexSyntax(trimmedPattern)
        if isRegex && hasWildcards && !strongRegex {
            // Looks like a pure glob (e.g., "*.swift") → prefer glob
            return false
        }
        return isRegex
    }

    /// Friendly glob candidates for a path pattern, tried in order: the pattern itself, then any
    /// depth (`**/`) when it has no `/`, then a trailing `*` when it does not already end with a
    /// wildcard.
    package static func pathGlobCandidates(for pattern: String) -> [String] {
        var cands: [String] = [pattern]
        let hasSlash = pattern.contains("/")
        let needsSuffixStar = !endsWithWildcard(pattern)

        // Try matching at any depth if user didn't scope with '/'
        if !hasSlash, !pattern.hasPrefix("**/") {
            cands.append("**/" + pattern)
        }
        // If user forgot a trailing wildcard, try broadening
        if needsSuffixStar {
            cands.append(pattern + "*")
            if !hasSlash, !pattern.hasPrefix("**/") {
                cands.append("**/" + pattern + "*")
            }
        }
        // Deduplicate while preserving order
        var seen = Set<String>()
        var out: [String] = []
        for c in cands where seen.insert(c).inserted {
            out.append(c)
        }
        return out
    }

    /// Helper: does a glob end with a wildcard token?
    private static func endsWithWildcard(_ s: String) -> Bool {
        guard let last = s.last else { return false }
        return last == "*" || last == "?"
    }

    // MARK: - Regex detection

    /// Detects if a pattern contains regex syntax that should trigger regex mode
    package static func containsRegexSyntax(_ pattern: String) -> Bool {
        if usesPCREOnlyFeatures(pattern) {
            return true
        }

        // Check for clear regex patterns that are unlikely to be literal searches

        // Check for parentheses (capture groups) - but only if they look like regex
        // e.g., "(foo|bar)" or "func()" - we need to be smart about this
        if pattern.contains("(") && pattern.contains(")") {
            // Check if it's likely a regex group (has | inside or special chars)
            if let openParen = pattern.firstIndex(of: "("),
               let closeParen = pattern.firstIndex(of: ")"),
               openParen < closeParen
            {
                let insideParens = String(pattern[pattern.index(after: openParen) ..< closeParen])
                // If there's a pipe inside parens, it's likely regex
                if insideParens.contains("|") {
                    return true
                }
                // If the pattern starts with common regex anchors/modifiers before the paren
                let beforeParen = String(pattern[..<openParen])
                if beforeParen.hasSuffix("?:") || beforeParen.hasSuffix("?=") ||
                    beforeParen.hasSuffix("?!") || beforeParen.hasSuffix("?<=") ||
                    beforeParen.hasSuffix("?<!")
                {
                    return true
                }
            }
        }

        // Pipe operator with non-empty alternatives on both sides (e.g., "foo|bar")
        // This avoids false positives for lone pipes or pipes at edges
        if pattern.contains("|") {
            let components = pattern.split(separator: "|", omittingEmptySubsequences: false)
            // Only treat as regex if there are at least 2 non-empty components
            let nonEmptyCount = components.count(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            if nonEmptyCount >= 2 {
                return true
            }
        }

        // Common regex patterns that are very unlikely to be literal searches
        let strongRegexPatterns = [
            "\\b", // Word boundary
            "\\w", // Word character
            "\\d", // Digit
            "\\s", // Whitespace
            "\\n", // Newline
            "\\t", // Tab
            "^$", // Empty line
            ".*", // Any character sequence
            ".+" // At least one character
        ]

        for regexPattern in strongRegexPatterns {
            if pattern.contains(regexPattern) {
                return true
            }
        }

        // Check for character classes [...]
        if let openBracket = pattern.firstIndex(of: "["),
           let closeBracket = pattern.firstIndex(of: "]"),
           openBracket < closeBracket
        {
            return true
        }

        // Check for quantifiers {n,m}
        if let openBrace = pattern.firstIndex(of: "{"),
           let closeBrace = pattern.firstIndex(of: "}"),
           openBrace < closeBrace
        {
            let between = pattern[pattern.index(after: openBrace) ..< closeBrace]
            // Check if it looks like a quantifier (digits and comma)
            if between.allSatisfy({ $0.isNumber || $0 == "," }) {
                return true
            }
        }

        // Check for anchors at start/end
        if pattern.hasPrefix("^") || pattern.hasSuffix("$") {
            return true
        }

        return false
    }

    /// Detects if pattern uses PCRE-only features unsupported by Swift Regex
    package static func usesPCREOnlyFeatures(_ pattern: String) -> Bool {
        let pcreTokens = [
            "\\w",
            "\\d",
            "\\s",
            "(?=",
            "(?<!",
            "(?<=",
            "(?!",
            "(?>",
            "\\b",
            "[[:",
            "\\Q",
            "\\E",
            "(?i)",
            "(?m)",
            "(?s)",
            "(?x)"
        ]
        return pcreTokens.contains { pattern.contains($0) } || containsInlineOptionGroup(pattern)
    }

    private static func containsInlineOptionGroup(_ pattern: String) -> Bool {
        var searchStart = pattern.startIndex
        while let intro = pattern.range(of: "(?", range: searchStart ..< pattern.endIndex) {
            var index = intro.upperBound
            var sawFlag = false
            var awaitingFlagAfterHyphen = false

            while index < pattern.endIndex {
                let ch = pattern[index]
                if isInlineOptionFlag(ch) {
                    sawFlag = true
                    awaitingFlagAfterHyphen = false
                    index = pattern.index(after: index)
                    continue
                }
                if ch == "-" {
                    awaitingFlagAfterHyphen = true
                    index = pattern.index(after: index)
                    continue
                }
                if ch == ")" || ch == ":", sawFlag, !awaitingFlagAfterHyphen {
                    return true
                }
                break
            }

            searchStart = intro.upperBound
        }
        return false
    }

    private static func isInlineOptionFlag(_ ch: Character) -> Bool {
        switch ch {
        case "i", "m", "s", "x", "U", "J":
            true
        default:
            false
        }
    }
}
