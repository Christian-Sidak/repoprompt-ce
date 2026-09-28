/// The single owner of `file_search`'s `max_results` contract, shared by the app provider, headless
/// `searchFiles`, and the canonical tool schema: the path stage and the content stage are each capped
/// at `max_results` (so a `both` search can return up to twice that many hits), and `count_only`
/// counts every content match.
package enum FileSearchResultLimits {
    package static let defaultMaxResults = 50

    /// The `max_results` input-schema property description.
    package static let maxResultsPropertyDescription =
        "Per-stage result limit (default: \(defaultMaxResults)): path hits and content matches are each capped at this value; count_only counts every content match"

    /// The vendored tool-description line that canonicalization replaces with `maxResultsOptionLine`.
    static let vendoredMaxResultsOptionLine = "- `max_results`: Result limit (default: 50)"

    /// The tool-description "Key options" line for `max_results`.
    package static let maxResultsOptionLine =
        "- `max_results`: Per-stage result limit (default: \(defaultMaxResults)); path and content hits are capped separately"
}
