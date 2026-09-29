import Foundation

/// Schema identity and load gate for the app's `globalSettings.json`, shared by the app
/// (`GlobalSettingsDocument` / `GlobalSettingsFileStore`) and headless read-only views so both
/// decide identically whether a settings document may be trusted.
package enum DomainGlobalSettingsSchema {
    /// Lineage marker for settings files written by the open-source CE schema family.
    ///
    /// CE inherited numeric schema versions from classic/internal builds, so version numbers
    /// alone are not globally meaningful. Unlineaged v1/v2 files are accepted as legacy CE
    /// documents; unlineaged higher versions are treated as foreign/future documents even if
    /// this fork later reaches the same numeric schema version.
    package static let lineage = "repoprompt-ce.global-settings"

    /// Newest schema version this build reads and writes. Bump together with the app's
    /// `GlobalSettingsDocument` feature-version constants.
    package static let currentVersion = 10

    package static let rejectedExperimentalVersions = 6 ... 6

    /// FROZEN at 2 forever: the last schema version OSS CE wrote without a lineage marker. It must
    /// never track `currentVersion`.
    package static let legacyUnlineagedVersionCeiling = 2

    package enum Verdict: Equatable {
        case accepted
        case incompatible
        case unsupportedFuture(onDiskVersion: Int, supportedVersion: Int)
    }

    package static func verdict(
        schemaVersion: Int,
        schemaLineage: String?,
        supportedVersion: Int = currentVersion
    ) -> Verdict {
        let normalizedLineage = schemaLineage?.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedLineage == lineage {
            if rejectedExperimentalVersions.contains(schemaVersion) {
                return .incompatible
            }
            return schemaVersion > supportedVersion
                ? .unsupportedFuture(onDiskVersion: schemaVersion, supportedVersion: supportedVersion)
                : .accepted
        }
        if normalizedLineage != nil { return .incompatible }

        // COMPATIBILITY INVARIANT — do not simplify this to `schemaVersion > supportedVersion`.
        // Numeric schema versions above the inherited v1/v2 CE baseline are ambiguous without a
        // lineage marker: classic/internal RepoPrompt wrote unlineaged v3/v4 globalSettings.json
        // into live Application Support folders before CE introduced `schemaLineage`. An
        // unlineaged version above the frozen ceiling is therefore foreign, permanently — even
        // after CE's own currentVersion catches up numerically. Guarded by
        // testLegacyUnlineagedCeilingIsFrozenAtTwo and
        // testUnlineagedHigherSchemaStaysBlockedAfterFutureNumericSchemaCatchup.
        // See docs/architecture/settings-persistence.md.
        return schemaVersion > legacyUnlineagedVersionCeiling ? .incompatible : .accepted
    }
}

/// Read-only view of the app's effective global ignore defaults for headless use.
///
/// The app (`GlobalSettingsStore`, backed by `globalSettings.json`) is the only writer. This view
/// never writes and never trusts a document the app itself would refuse to load: a foreign,
/// experimental, newer, or unreadable document is reported `blocked`, and its value is not used.
package enum DomainGlobalIgnoreDefaultsView {
    package enum BlockReason: String, Equatable {
        case unreadable
        case incompatibleSchema = "incompatible_schema"
        case unsupportedFutureSchema = "unsupported_future_schema"
        case invalidValue = "invalid_value"
    }

    package enum Source: Equatable {
        /// The document is trusted and sets the value explicitly.
        case settings(String)
        /// The document is trusted but has no value; the app uses the canonical list.
        case valueAbsent
        /// No settings document exists; the app would seed the canonical list.
        case fileMissing
        /// The document exists but must not be trusted.
        case blocked(BlockReason)
    }

    package struct Resolution: Equatable {
        package let source: Source

        /// The patterns the app itself applies in this state. A blocked document is never read;
        /// like the app's blocked load, the canonical list applies.
        package var effectivePatterns: String {
            if case let .settings(value) = source { return value }
            return DomainGlobalIgnoreDefaults.canonical
        }

        package var status: String {
            switch source {
            case .settings: "settings"
            case .valueAbsent: "value_absent"
            case .fileMissing: "file_missing"
            case let .blocked(reason): "blocked_\(reason.rawValue)"
            }
        }
    }

    /// `<storage>/Settings/globalSettings.json`, matching the app's settings file for the default
    /// profile and an isolated per-profile file otherwise.
    package static func settingsFileURL(storageDirectory: URL) -> URL {
        storageDirectory
            .appendingPathComponent("Settings", isDirectory: true)
            .appendingPathComponent("globalSettings.json", isDirectory: false)
    }

    package static func resolve(
        settingsFileURL: URL,
        fileManager: FileManager = .default
    ) -> Resolution {
        guard fileManager.fileExists(atPath: settingsFileURL.path) else {
            return Resolution(source: .fileMissing)
        }
        guard let data = try? Data(contentsOf: settingsFileURL) else {
            return Resolution(source: .blocked(.unreadable))
        }
        return resolve(documentData: data)
    }

    package static func resolve(documentData data: Data) -> Resolution {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return Resolution(source: .blocked(.unreadable))
        }
        // Match the app's typed header decode: an integer, not a JSON boolean or fraction.
        guard let number = object["schemaVersion"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let schemaVersion = Int(exactly: number.doubleValue)
        else {
            return Resolution(source: .blocked(.incompatibleSchema))
        }
        let lineageValue = object["schemaLineage"]
        if lineageValue != nil, !(lineageValue is NSNull), !(lineageValue is String) {
            return Resolution(source: .blocked(.incompatibleSchema))
        }
        switch DomainGlobalSettingsSchema.verdict(
            schemaVersion: schemaVersion,
            schemaLineage: lineageValue as? String
        ) {
        case .incompatible:
            return Resolution(source: .blocked(.incompatibleSchema))
        case .unsupportedFuture:
            return Resolution(source: .blocked(.unsupportedFutureSchema))
        case .accepted:
            break
        }
        let scalarPreferences = object["scalarPreferences"]
        guard let scalarPreferences, !(scalarPreferences is NSNull) else {
            return Resolution(source: .valueAbsent)
        }
        guard let scalarObject = scalarPreferences as? [String: Any] else {
            return Resolution(source: .blocked(.invalidValue))
        }
        let fileSystem = scalarObject["fileSystem"]
        guard let fileSystem, !(fileSystem is NSNull) else {
            return Resolution(source: .valueAbsent)
        }
        guard let fileSystemObject = fileSystem as? [String: Any] else {
            return Resolution(source: .blocked(.invalidValue))
        }
        let value = fileSystemObject["globalIgnoreDefaults"]
        guard let value, !(value is NSNull) else {
            return Resolution(source: .valueAbsent)
        }
        guard let patterns = value as? String else {
            return Resolution(source: .blocked(.invalidValue))
        }
        return Resolution(source: .settings(patterns))
    }
}
