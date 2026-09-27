import Foundation
@testable import RepoPromptApp
import XCTest

/// The crawl reads the same global ignore defaults that `app_settings` writes
/// (`globalSettings.json` via `GlobalSettingsStore`). A customized legacy `UserDefaults` value
/// migrates once into an uncustomized JSON value; an explicit JSON value always wins.
@MainActor
final class GlobalIgnoreDefaultsAuthorityTests: XCTestCase {
    private let legacyKey = IgnoreSettingsDefaults.globalIgnoreDefaultsKey
    private let legacyVersionKey = IgnoreSettingsDefaults.globalIgnoreDefaultsVersionKey

    func testCustomizedLegacyValueMigratesIntoUncustomizedJSONOnce() throws {
        let fileURL = try makeSettingsURL()
        let defaults = makeDefaults()
        let legacy = "**/legacy-custom/\n"
        defaults.set(legacy, forKey: legacyKey)
        defaults.set(IgnoreSettingsDefaults.currentGlobalIgnoreDefaultsVersion, forKey: legacyVersionKey)
        let authority = GlobalIgnoreDefaultsAuthority()

        let store = makeStore(fileURL: fileURL, defaults: defaults, authority: authority)
        XCTAssertEqual(store.globalIgnoreDefaults(), legacy)
        XCTAssertEqual(authority.current(), legacy, "the crawl sees the migrated value")
        XCTAssertTrue(IgnoreSettingsDefaults.isSettingsAuthorityMigrated(defaults: defaults))

        // A later legacy change never migrates again; the persisted JSON value is authoritative.
        defaults.set("**/later-legacy/\n", forKey: legacyKey)
        let reloaded = makeStore(fileURL: fileURL, defaults: defaults, authority: GlobalIgnoreDefaultsAuthority())
        XCTAssertEqual(reloaded.globalIgnoreDefaults(), legacy)
    }

    func testExplicitJSONValueWinsOverCustomizedLegacyValue() throws {
        let fileURL = try makeSettingsURL()
        let seeding = makeStore(fileURL: fileURL, defaults: makeDefaults(), authority: nil)
        seeding.setGlobalIgnoreDefaults("**/json-choice/\n")

        let defaults = makeDefaults()
        defaults.set("**/legacy-custom/\n", forKey: legacyKey)
        defaults.set(IgnoreSettingsDefaults.currentGlobalIgnoreDefaultsVersion, forKey: legacyVersionKey)
        let authority = GlobalIgnoreDefaultsAuthority()
        let store = makeStore(fileURL: fileURL, defaults: defaults, authority: authority)

        XCTAssertEqual(store.globalIgnoreDefaults(), "**/json-choice/\n")
        XCTAssertEqual(authority.current(), "**/json-choice/\n")
        XCTAssertEqual(defaults.string(forKey: legacyKey), "**/legacy-custom/\n", "legacy value is left in place")
    }

    func testUncustomizedLegacyValueLeavesCanonicalJSON() throws {
        let fileURL = try makeSettingsURL()
        let defaults = makeDefaults()
        defaults.set(IgnoreSettingsDefaults.canonicalGlobalIgnoreDefaults, forKey: legacyKey)
        defaults.set(IgnoreSettingsDefaults.currentGlobalIgnoreDefaultsVersion, forKey: legacyVersionKey)
        let store = makeStore(fileURL: fileURL, defaults: defaults, authority: nil)

        XCTAssertEqual(store.globalIgnoreDefaults(), IgnoreSettingsDefaults.canonicalGlobalIgnoreDefaults)
        XCTAssertTrue(IgnoreSettingsDefaults.isSettingsAuthorityMigrated(defaults: defaults))
    }

    func testSettingWrittenByAppSettingsDrivesCrawlIgnoreRules() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ignore-authority-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("generated-out", isDirectory: true),
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let authority = GlobalIgnoreDefaultsAuthority()
        let store = try makeStore(fileURL: makeSettingsURL(), defaults: makeDefaults(), authority: authority)
        await IgnoreRulesManager.shared.setGlobalDefaultsAuthorityOverride(authority)
        addTeardownBlock { await IgnoreRulesManager.shared.setGlobalDefaultsAuthorityOverride(nil) }

        let before = try await IgnoreRulesManager.shared.resolvedIgnoreRules(for: root.path, policy: .nonGitRoot)
        XCTAssertFalse(before.rules.isIgnored(relativePath: "generated-out", isDirectory: true))

        // `app_settings set file_system.global_ignore_defaults` writes through this setter.
        store.setGlobalIgnoreDefaults("**/generated-out/\n")

        let after = try await IgnoreRulesManager.shared.resolvedIgnoreRules(for: root.path, policy: .nonGitRoot)
        XCTAssertTrue(after.rules.isIgnored(relativePath: "generated-out", isDirectory: true))
        XCTAssertNotEqual(before.globalIgnoreDefaultsDigest, after.globalIgnoreDefaultsDigest)
    }

    // MARK: - Helpers

    private func makeDefaults() -> UserDefaults {
        let suiteName = "RepoPromptCE.ignore-authority.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return try! XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    private func makeSettingsURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ignore-authority-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("globalSettings.json")
    }

    private func makeStore(
        fileURL: URL,
        defaults: UserDefaults,
        authority: GlobalIgnoreDefaultsAuthority?
    ) -> GlobalSettingsStore {
        GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: fileURL),
            ignoreDefaultsAuthority: authority
        )
    }
}
