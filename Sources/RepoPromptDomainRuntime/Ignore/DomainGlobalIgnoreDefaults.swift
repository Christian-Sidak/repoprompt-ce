import Foundation

/// App-wide global ignore defaults shared by the app crawl (`IgnoreSettingsDefaults`) and headless
/// enumeration. The effective value is the user's `globalSettings.json`
/// `fileSystem.globalIgnoreDefaults`; this is the canonical list used when that value is absent.
package enum DomainGlobalIgnoreDefaults {
    /// `app_settings` key; owned by the app, read-only in headless.
    package static let settingKey = "file_system.global_ignore_defaults"

    /// Bump when new "required by default" patterns are added.
    package static let currentVersion = 2

    /// Canonical default patterns (does not include `.git`, which is always excluded separately).
    /// These mirror the "big dirs" heuristic plus a few common temp files.
    package static let canonical: String = """
    # RepoPrompt global ignore defaults (v\(currentVersion))
    **/node_modules/
    **/.npm/
    **/.pnpm-store/
    **/.yarn/
    **/.cache/
    **/bower_components/

    **/__pycache__/
    **/.pytest_cache/
    **/.mypy_cache/

    **/.gradle/
    **/.m2/
    **/.nuget/
    **/.cargo/
    **/.stack-work/
    **/.ccache/

    **/.idea/
    **/.vscode/
    **/.bundle/
    **/.gem/

    # Virtual environments
    **/.venv/
    **/venv/

    # Common temp/junk files
    **/*.swp
    **/*~
    **/*.tmp
    **/*.temp
    **/*.bak
    """
}
