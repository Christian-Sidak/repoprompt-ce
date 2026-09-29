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

    // MARK: - M14: authority safety

    /// The migration marker is recorded only after the migrated value is durably saved: a failed
    /// write keeps the live customization, leaves the marker unset, and the next launch retries.
    func testFailedMigrationWriteRetriesOnRelaunchInsteadOfLosingTheCustomization() throws {
        let fileURL = try makeSettingsURL()
        // An earlier launch seeded an uncustomized settings file.
        _ = makeStore(fileURL: fileURL, defaults: makeDefaults(), authority: nil)
        XCTAssertEqual(try storedGlobalIgnoreDefaults(at: fileURL), IgnoreSettingsDefaults.canonicalGlobalIgnoreDefaults)

        let defaults = makeDefaults()
        let legacy = "**/legacy-custom/\n"
        defaults.set(legacy, forKey: legacyKey)
        defaults.set(IgnoreSettingsDefaults.currentGlobalIgnoreDefaultsVersion, forKey: legacyVersionKey)
        let authority = GlobalIgnoreDefaultsAuthority()
        let failed = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(
                fileURL: fileURL,
                startupMigrationAtomicWriter: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
            ),
            ignoreDefaultsAuthority: authority
        )

        XCTAssertEqual(failed.persistenceBlockReason, .saveFailed)
        XCTAssertEqual(failed.globalIgnoreDefaults(), legacy, "the live session keeps the customization")
        XCTAssertEqual(authority.current(), legacy)
        XCTAssertFalse(IgnoreSettingsDefaults.isSettingsAuthorityMigrated(defaults: defaults))
        XCTAssertEqual(try storedGlobalIgnoreDefaults(at: fileURL), IgnoreSettingsDefaults.canonicalGlobalIgnoreDefaults)

        // Relaunch with a working disk: the migration runs again and is then recorded.
        let relaunchAuthority = GlobalIgnoreDefaultsAuthority()
        let relaunched = makeStore(fileURL: fileURL, defaults: defaults, authority: relaunchAuthority)
        XCTAssertNil(relaunched.persistenceBlockReason)
        XCTAssertEqual(relaunched.globalIgnoreDefaults(), legacy)
        XCTAssertEqual(relaunchAuthority.current(), legacy)
        XCTAssertEqual(try storedGlobalIgnoreDefaults(at: fileURL), legacy)
        XCTAssertTrue(IgnoreSettingsDefaults.isSettingsAuthorityMigrated(defaults: defaults))
    }

    /// A same-session retry that durably saves the migrated value records the marker.
    func testSuccessfulRetryAfterFailedMigrationWriteRecordsTheMarker() throws {
        let fileURL = try makeSettingsURL()
        _ = makeStore(fileURL: fileURL, defaults: makeDefaults(), authority: nil)
        let defaults = makeDefaults()
        let legacy = "**/legacy-custom/\n"
        defaults.set(legacy, forKey: legacyKey)
        defaults.set(IgnoreSettingsDefaults.currentGlobalIgnoreDefaultsVersion, forKey: legacyVersionKey)
        let gate = WriteGate()
        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(
                fileURL: fileURL,
                startupMigrationAtomicWriter: { data, url in
                    if gate.failWrites { throw CocoaError(.fileWriteOutOfSpace) }
                    try data.write(to: url, options: .atomic)
                }
            ),
            ignoreDefaultsAuthority: GlobalIgnoreDefaultsAuthority()
        )
        XCTAssertEqual(store.persistenceBlockReason, .saveFailed)
        XCTAssertFalse(IgnoreSettingsDefaults.isSettingsAuthorityMigrated(defaults: defaults))

        gate.failWrites = false
        XCTAssertTrue(store.retryBlockedPersistenceSave())
        XCTAssertEqual(try storedGlobalIgnoreDefaults(at: fileURL), legacy)
        XCTAssertTrue(IgnoreSettingsDefaults.isSettingsAuthorityMigrated(defaults: defaults))
    }

    /// A blocked settings file installs provisional defaults, which must not replace the user's
    /// legacy exclusions in the crawl. Explicit recovery then persists those exclusions.
    func testBlockedSettingsLoadKeepsLegacyExclusionsInTheCrawlUntilRecovered() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ignore-authority-blocked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("legacy-out", isDirectory: true),
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        addTeardownBlock { await IgnoreRulesManager.shared.setGlobalDefaultsAuthorityOverride(nil) }
        let legacy = "**/legacy-out/\n"
        let blockedDocuments: [(String, [String: Any])] = [
            ("unsupported future schema", [
                "schemaVersion": GlobalSettingsDocument.currentSchemaVersion + 90,
                "schemaLineage": GlobalSettingsDocument.schemaLineage
            ]),
            ("incompatible lineage", ["schemaVersion": 1, "schemaLineage": "another-app.global-settings"])
        ]

        for (label, header) in blockedDocuments {
            let fileURL = try makeSettingsURL()
            var document = header
            document["scalarPreferences"] = ["fileSystem": ["globalIgnoreDefaults": "**/unreadable-choice/\n"]]
            let blockedBytes = try JSONSerialization.data(withJSONObject: document)
            try blockedBytes.write(to: fileURL)
            let defaults = makeDefaults()
            defaults.set(legacy, forKey: legacyKey)
            defaults.set(IgnoreSettingsDefaults.currentGlobalIgnoreDefaultsVersion, forKey: legacyVersionKey)
            let authority = GlobalIgnoreDefaultsAuthority()
            await IgnoreRulesManager.shared.setGlobalDefaultsAuthorityOverride(authority)

            let store = makeStore(fileURL: fileURL, defaults: defaults, authority: authority)
            XCTAssertNotNil(store.persistenceBlockReason, label)
            XCTAssertEqual(store.globalIgnoreDefaults(), legacy, label)
            XCTAssertEqual(authority.current(), legacy, "\(label): the crawl keeps the legacy exclusions")
            XCTAssertFalse(IgnoreSettingsDefaults.isSettingsAuthorityMigrated(defaults: defaults), label)
            XCTAssertEqual(try Data(contentsOf: fileURL), blockedBytes, "\(label): the blocked file is untouched")
            let blocked = try await IgnoreRulesManager.shared.resolvedIgnoreRules(for: root.path, policy: .nonGitRoot)
            XCTAssertTrue(blocked.rules.isIgnored(relativePath: "legacy-out", isDirectory: true), label)

            XCTAssertTrue(store.recoverBlockedPersistenceAfterBackup(), label)
            XCTAssertNil(store.persistenceBlockReason, label)
            XCTAssertEqual(store.globalIgnoreDefaults(), legacy, label)
            XCTAssertEqual(try storedGlobalIgnoreDefaults(at: fileURL), legacy, "\(label): recovery persists the exclusions")
            XCTAssertTrue(IgnoreSettingsDefaults.isSettingsAuthorityMigrated(defaults: defaults), label)
            let recovered = try await IgnoreRulesManager.shared.resolvedIgnoreRules(for: root.path, policy: .nonGitRoot)
            XCTAssertTrue(recovered.rules.isIgnored(relativePath: "legacy-out", isDirectory: true), label)
        }
    }

    // MARK: - Helpers

    private final class WriteGate: @unchecked Sendable {
        var failWrites = true
    }

    private func storedGlobalIgnoreDefaults(at fileURL: URL) throws -> String? {
        let document = try GlobalSettingsFileStore(fileURL: fileURL).load()
        return document.scalarPreferences?.fileSystem?.globalIgnoreDefaults
    }

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
