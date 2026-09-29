import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

/// M8M: headless reads the app's global ignore defaults read-only, trusting exactly the settings
/// documents the app loads and never writing them.
final class DomainGlobalIgnoreDefaultsViewTests: XCTestCase {
    // MARK: - Shared schema gate

    func testSchemaGateMatchesTheAppLoadRules() {
        let lineage = DomainGlobalSettingsSchema.lineage
        let current = DomainGlobalSettingsSchema.currentVersion
        XCTAssertEqual(DomainGlobalSettingsSchema.verdict(schemaVersion: current, schemaLineage: lineage), .accepted)
        XCTAssertEqual(DomainGlobalSettingsSchema.verdict(schemaVersion: 2, schemaLineage: " \(lineage) "), .accepted)
        XCTAssertEqual(DomainGlobalSettingsSchema.verdict(schemaVersion: 6, schemaLineage: lineage), .incompatible)
        XCTAssertEqual(
            DomainGlobalSettingsSchema.verdict(schemaVersion: current + 1, schemaLineage: lineage),
            .unsupportedFuture(onDiskVersion: current + 1, supportedVersion: current)
        )
        XCTAssertEqual(DomainGlobalSettingsSchema.verdict(schemaVersion: 2, schemaLineage: "someone-else"), .incompatible)
        XCTAssertEqual(DomainGlobalSettingsSchema.verdict(schemaVersion: 1, schemaLineage: nil), .accepted)
        XCTAssertEqual(DomainGlobalSettingsSchema.verdict(schemaVersion: 2, schemaLineage: nil), .accepted)
        XCTAssertEqual(DomainGlobalSettingsSchema.verdict(schemaVersion: 3, schemaLineage: nil), .incompatible)
        XCTAssertEqual(DomainGlobalSettingsSchema.verdict(schemaVersion: 4, schemaLineage: nil), .incompatible)
    }

    func testLegacyUnlineagedCeilingIsFrozenAtTwo() {
        XCTAssertEqual(DomainGlobalSettingsSchema.legacyUnlineagedVersionCeiling, 2)
    }

    func testUnlineagedHigherSchemaStaysBlockedAfterFutureNumericSchemaCatchup() {
        XCTAssertEqual(
            DomainGlobalSettingsSchema.verdict(schemaVersion: 3, schemaLineage: nil, supportedVersion: 50),
            .incompatible
        )
    }

    // MARK: - Read-only view

    func testViewReportsMissingAbsentAndExplicitValuesDistinctly() throws {
        let missing = DomainGlobalIgnoreDefaultsView.resolve(settingsFileURL: temporaryURL())
        XCTAssertEqual(missing.source, .fileMissing)
        XCTAssertEqual(missing.status, "file_missing")
        XCTAssertEqual(missing.effectivePatterns, DomainGlobalIgnoreDefaults.canonical)

        for document in [
            ["schemaVersion": 10, "schemaLineage": DomainGlobalSettingsSchema.lineage],
            ["schemaVersion": 10, "schemaLineage": DomainGlobalSettingsSchema.lineage, "scalarPreferences": [:]],
            ["schemaVersion": 10, "schemaLineage": DomainGlobalSettingsSchema.lineage, "scalarPreferences": ["fileSystem": [:]]],
            ["schemaVersion": 10, "schemaLineage": DomainGlobalSettingsSchema.lineage, "scalarPreferences": ["fileSystem": ["globalIgnoreDefaults": NSNull()]]]
        ] as [[String: Any]] {
            let absent = try resolve(document)
            XCTAssertEqual(absent.source, .valueAbsent, "\(document)")
            XCTAssertEqual(absent.effectivePatterns, DomainGlobalIgnoreDefaults.canonical)
        }

        let explicit = try resolve([
            "schemaVersion": 10,
            "schemaLineage": DomainGlobalSettingsSchema.lineage,
            "scalarPreferences": ["fileSystem": ["globalIgnoreDefaults": "**/dist/\n"]]
        ])
        XCTAssertEqual(explicit.source, .settings("**/dist/\n"))
        XCTAssertEqual(explicit.effectivePatterns, "**/dist/\n")

        let emptyExplicit = try resolve([
            "schemaVersion": 1,
            "scalarPreferences": ["fileSystem": ["globalIgnoreDefaults": ""]]
        ])
        XCTAssertEqual(emptyExplicit.source, .settings(""), "an explicit empty list disables defaults, as in the app")
    }

    func testViewNeverTrustsDocumentsTheAppWouldRefuse() throws {
        let value: [String: Any] = ["fileSystem": ["globalIgnoreDefaults": "**/secret-choice/\n"]]
        let cases: [([String: Any], DomainGlobalIgnoreDefaultsView.BlockReason)] = [
            (["schemaVersion": 6, "schemaLineage": DomainGlobalSettingsSchema.lineage, "scalarPreferences": value], .incompatibleSchema),
            (["schemaVersion": 99, "schemaLineage": DomainGlobalSettingsSchema.lineage, "scalarPreferences": value], .unsupportedFutureSchema),
            (["schemaVersion": 10, "schemaLineage": "classic", "scalarPreferences": value], .incompatibleSchema),
            (["schemaVersion": 3, "scalarPreferences": value], .incompatibleSchema),
            (["schemaVersion": true, "scalarPreferences": value], .incompatibleSchema),
            (["schemaVersion": 10.5, "schemaLineage": DomainGlobalSettingsSchema.lineage], .incompatibleSchema),
            (["schemaLineage": DomainGlobalSettingsSchema.lineage, "scalarPreferences": value], .incompatibleSchema),
            (["schemaVersion": 10, "schemaLineage": DomainGlobalSettingsSchema.lineage, "scalarPreferences": ["fileSystem": ["globalIgnoreDefaults": 7]]], .invalidValue),
            (["schemaVersion": 10, "schemaLineage": DomainGlobalSettingsSchema.lineage, "scalarPreferences": ["fileSystem": "oops"]], .invalidValue)
        ]
        for (document, reason) in cases {
            let resolution = try resolve(document)
            XCTAssertEqual(resolution.source, .blocked(reason), "\(document)")
            XCTAssertEqual(resolution.effectivePatterns, DomainGlobalIgnoreDefaults.canonical, "a blocked value is never used")
        }
        XCTAssertEqual(
            DomainGlobalIgnoreDefaultsView.resolve(documentData: Data("not json".utf8)).source,
            .blocked(.unreadable)
        )
    }

    // MARK: - Headless settings contract

    func testHeadlessStoreServesAppOwnedKeyReadOnlyAndKeepsOtherKeysWritable() async throws {
        let runtime = try await makeRuntime()
        let store = DomainDirectSettingsStore(
            persistence: runtime.persistenceCoordinator,
            profileIdentifier: runtime.configuration.profileIdentifier,
            appGlobalIgnoreDefaults: { .init(source: .settings("**/from-app/\n")) }
        )
        await store.bootstrap()

        let value = try await store.effectiveValue(for: DomainGlobalIgnoreDefaults.settingKey)
        XCTAssertEqual(value, .string("**/from-app/\n"))
        let status = await store.appAuthorityStatus(for: DomainGlobalIgnoreDefaults.settingKey)
        XCTAssertEqual(status, "settings")

        do {
            _ = try await store.set(key: DomainGlobalIgnoreDefaults.settingKey, value: .string("**/headless/\n"))
            XCTFail("Headless wrote an app-owned setting")
        } catch let error as DomainDirectSettingsError {
            XCTAssertEqual(error, .appAuthorityReadOnly(DomainGlobalIgnoreDefaults.settingKey))
        }

        _ = try await store.set(key: "file_system.respect_repo_ignore", value: .bool(false))
        let other = try await store.effectiveValue(for: "file_system.respect_repo_ignore")
        XCTAssertEqual(other, .bool(false))
        let otherStatus = await store.appAuthorityStatus(for: "file_system.respect_repo_ignore")
        XCTAssertNil(otherStatus)
    }

    // MARK: - Helpers

    private func resolve(_ document: [String: Any]) throws -> DomainGlobalIgnoreDefaultsView.Resolution {
        let url = temporaryURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: document).write(to: url)
        return DomainGlobalIgnoreDefaultsView.resolve(settingsFileURL: url)
    }

    private func temporaryURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("global-ignore-view-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return DomainGlobalIgnoreDefaultsView.settingsFileURL(storageDirectory: directory)
    }

    private func makeRuntime() async throws -> MCPDomainRuntime {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("global-ignore-store-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let runtime = MCPDomainRuntime(configuration: .init(
            mode: .standalone,
            profileIdentifier: "ignore-view-test",
            storageDirectory: directory,
            eventDirectory: directory,
            temporaryDirectory: directory,
            externalReloadInterval: nil,
            hostDrainTimeout: .milliseconds(25)
        ))
        try await runtime.start()
        return runtime
    }
}
