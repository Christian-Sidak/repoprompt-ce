import CryptoKit
import Foundation
@testable import RepoPromptApp
import RepoPromptCodeMapCore
import XCTest

/// Regression coverage for #1082: graph-index publication and graph commits must scale with the
/// published batch, not with the resident graph, while producing the same deterministic graph.
final class WorkspaceCodemapGraphIncrementalIndexTests: XCTestCase {
    // MARK: - Ordering

    func testFastOrderingsMatchHistoricalOrderings() {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("aAzZ09_/.-é漢😀")
        var strings = ["", "a", "ab", "abc", "b", "Sources/A.swift", "Sources/A.swift.bak", "Sources/a.swift"]
        for _ in 0 ..< 200 {
            let length = Int.random(in: 0 ... 12, using: &generator)
            strings.append(String((0 ..< length).map { _ in
                alphabet[Int.random(in: alphabet.indices, using: &generator)]
            }))
        }
        for lhs in strings {
            for rhs in strings {
                XCTAssertEqual(
                    WorkspaceCodemapGraphOrdering.utf8Precedes(lhs, rhs),
                    lhs.utf8.lexicographicallyPrecedes(rhs.utf8),
                    "\(lhs) vs \(rhs)"
                )
            }
        }

        let edgeUUIDs = [
            UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
            UUID(uuid: (0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF)),
            UUID(uuid: (0, 0, 0, 0x0A, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
            UUID(uuid: (0, 0, 0, 0x09, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        ]
        let uuids = (0 ..< 300).map { _ in UUID() } + edgeUUIDs
        for lhs in uuids {
            for rhs in uuids.prefix(40) {
                XCTAssertEqual(
                    WorkspaceCodemapGraphOrdering.uuidPrecedes(lhs, rhs),
                    lhs.uuidString < rhs.uuidString
                )
            }
        }

        var sorted = strings.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
        sorted = Array(Set(sorted)).sorted(by: WorkspaceCodemapGraphOrdering.utf8Precedes)
        let inserted = Array(Set(strings).subtracting(sorted))
        var merged = sorted
        WorkspaceCodemapGraphOrdering.mergeSortedInsertion(
            into: &merged,
            inserting: inserted,
            by: WorkspaceCodemapGraphOrdering.utf8Precedes
        )
        XCTAssertEqual(merged, Array(Set(strings)).sorted(by: WorkspaceCodemapGraphOrdering.utf8Precedes))
    }

    // MARK: - Per-batch work bound

    func testGraphIndexPublicationWorkStaysProportionalToBatchSize() async throws {
        // More files than the changed-set policy (4096) so acknowledgement pruning is exercised.
        let fileCount = 4608
        let batchSize = 64
        let harness = try await Harness(seed: 0x21)
        let files = try harness.makeFiles(count: fileCount)

        var overlayVisits: [UInt64] = []
        var diffSizes: [Int] = []
        var commitVisits: [UInt64] = []
        var commitComparisons: [UInt64] = []
        for start in stride(from: 0, to: fileCount, by: batchSize) {
            let page = Array(files[start ..< min(start + batchSize, fileCount)])
            for slots in [page.map(\.pending), page.map(\.contributed)] {
                let published = await harness.overlay.publishGraphIndexSlots(
                    rootEpoch: harness.rootEpoch,
                    catalogToken: harness.catalogToken,
                    slots: slots,
                    projectedSupportedCandidateTotal: UInt64(fileCount),
                    catalogSealed: true
                )
                XCTAssertTrue(published)
                let ledger = try await harness.ledger()
                overlayVisits.append(ledger.lastReconcileVisitCount)
                let disposition = await harness.pull()
                if case .committed(_, _, _, _, false) = disposition {
                    let accounting = await harness.graph.incrementalAccounting()
                    commitVisits.append(accounting.lastCandidateVisitCount)
                    commitComparisons.append(accounting.lastCandidateComparisonCount)
                    let diffLedger = try await harness.ledger()
                    diffSizes.append(diffLedger.lastDiffSlotCount)
                }
            }
        }
        let finished = await harness.overlay.publishGraphIndexSlots(
            rootEpoch: harness.rootEpoch,
            catalogToken: harness.catalogToken,
            slots: [],
            catalogSealed: true,
            enumerationFinished: true
        )
        XCTAssertTrue(finished)
        _ = await harness.pull()

        let ledger = try await harness.ledger()
        // Every page publication reconciles only its own paths; only enumeration completion
        // performs one full reconciliation.
        XCTAssertEqual(ledger.incrementalReconcileCount, UInt64(2 * fileCount / batchSize) + 1)
        XCTAssertLessThanOrEqual(ledger.fullReconcileCount, 1)
        XCTAssertEqual(ledger.incrementalFallbackCount, 0)
        XCTAssertLessThanOrEqual(ledger.maximumIncrementalReconcileVisitCount, UInt64(8 * batchSize))
        XCTAssertLessThanOrEqual(overlayVisits.max() ?? 0, UInt64(8 * batchSize))
        // The changed set outgrew policy, but acknowledged entries were pruned instead of forcing
        // a floor reset and a whole-graph checkpoint resync.
        XCTAssertGreaterThan(ledger.acknowledgedPruneCount, 0)
        XCTAssertEqual(ledger.floorResetCount, 0)

        let graphAccounting = await harness.graph.incrementalAccounting()
        XCTAssertEqual(graphAccounting.resyncCommitCount, 1, "Only the initial checkpoint may resync")
        XCTAssertTrue(graphAccounting.coverage?.isComplete == true)
        // Diffs carry only the latest publication, never the whole changed set since the floor.
        XCTAssertLessThanOrEqual(diffSizes.max() ?? 0, batchSize)
        // Candidate builds stay bounded by the batch and the postings it reaches. A whole-graph
        // recount alone would visit every node, slot, and posting (well over 4 * fileCount).
        XCTAssertFalse(commitVisits.isEmpty)
        XCTAssertLessThanOrEqual(commitVisits.max() ?? 0, UInt64(48 * batchSize))
        let quarter = commitVisits.count / 4
        let early = commitVisits[quarter ..< 2 * quarter]
        let late = commitVisits[(3 * quarter)...]
        let earlyAverage = Double(early.reduce(0, +)) / Double(early.count)
        let lateAverage = Double(late.reduce(0, +)) / Double(late.count)
        XCTAssertLessThanOrEqual(lateAverage, earlyAverage * 1.5, "Per-batch work must not grow with the graph")
        // Sorted lists are maintained by binary-searched merges, so comparator invocations grow
        // only logarithmically with hub lists (re-sorting one hub list alone is n log n).
        XCTAssertLessThanOrEqual(commitComparisons.max() ?? 0, UInt64(512 * batchSize))
        let earlyComparisons = commitComparisons[quarter ..< 2 * quarter]
        let lateComparisons = commitComparisons[(3 * quarter)...]
        XCTAssertLessThanOrEqual(
            Double(lateComparisons.reduce(0, +)) / Double(lateComparisons.count),
            Double(earlyComparisons.reduce(0, +)) / Double(earlyComparisons.count) * 1.5,
            "Comparator work must not grow with the graph"
        )

        // Determinism: the incrementally maintained graph equals a from-scratch checkpoint build.
        let incremental = try await harness.latestSnapshot(harness.graph)
        let rebuilt = try await harness.rebuiltFromCheckpoint()
        assertSameGraph(incremental, rebuilt)
    }

    // MARK: - Path-scoped reconcile parity

    func testPathScopedReconcileMatchesFullReconcile() async throws {
        let incremental = try await Harness(seed: 0x31, mode: .incremental)
        let full = try await Harness(seed: 0x31, mode: .alwaysFull)
        let files = try incremental.makeFiles(count: 240)
        let batches = stride(from: 0, to: files.count, by: 32).map { Array(files[$0 ..< min($0 + 32, files.count)]) }

        var steps: [[WorkspaceCodemapGraphSlot]] = []
        for batch in batches {
            steps.append(batch.map(\.pending))
            steps.append(batch.map(\.contributed))
        }
        // Republish unchanged slots (idempotent), move one file to a new path, and replace a
        // path with a different file ID.
        steps.append(Array(files[10 ..< 20]).map(\.contributed))
        try steps.append([incremental.makeSlot(
            fileID: files[5].fileID,
            path: "Sources/Moved/Renamed5.swift",
            definitions: ["Type5"],
            references: ["Type0"],
            requestGeneration: 2
        )])
        try steps.append([incremental.makeSlot(
            fileID: UUID(uuid: (0x31, 0xEE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)),
            path: files[7].path,
            definitions: ["Replacement7"],
            references: ["Type1"],
            requestGeneration: 3
        )])

        var previousGeneration: WorkspaceCodemapSelectionGraphContributionGeneration?
        for slots in steps {
            for harness in [incremental, full] {
                let published = await harness.overlay.publishGraphIndexSlots(
                    rootEpoch: harness.rootEpoch,
                    catalogToken: harness.catalogToken,
                    slots: slots,
                    projectedSupportedCandidateTotal: UInt64(files.count + 1),
                    catalogSealed: true,
                    reconciliationFence: { _, _ in .fenced(safetyCounter: 1) }
                )
                XCTAssertTrue(published)
            }
            try await assertSameLedger(incremental, full, since: previousGeneration, expectCheckpoint: true)
            previousGeneration = try await incremental.ledger().contributionGeneration
        }

        // A watcher-gap reconciliation pass drops files missing from the authoritative pass.
        for harness in [incremental, full] {
            let began = await harness.overlay.beginGraphReconciliation(rootEpoch: harness.rootEpoch)
            XCTAssertTrue(began)
        }
        let survivors = Array(files.prefix(200))
        for start in stride(from: 0, to: survivors.count, by: 50) {
            let slots = survivors[start ..< min(start + 50, survivors.count)].map(\.contributed)
            for harness in [incremental, full] {
                let published = await harness.overlay.publishGraphIndexSlots(
                    rootEpoch: harness.rootEpoch,
                    catalogToken: harness.catalogToken,
                    slots: slots,
                    catalogSealed: true,
                    reconciliationFence: { _, _ in .fenced(safetyCounter: 1) }
                )
                XCTAssertTrue(published)
            }
            // Mid-pass coverage counts only re-seen slots, so a checkpoint is not constructible;
            // both modes must agree on that and on the floor-relative diff.
            try await assertSameLedger(incremental, full, since: nil, expectCheckpoint: false)
        }
        for harness in [incremental, full] {
            let published = await harness.overlay.publishGraphIndexSlots(
                rootEpoch: harness.rootEpoch,
                catalogToken: harness.catalogToken,
                slots: [],
                catalogSealed: true,
                enumerationFinished: true,
                reconciliationFence: { _, _ in .fenced(safetyCounter: 1) }
            )
            XCTAssertTrue(published)
        }
        try await assertSameLedger(incremental, full, since: nil, expectCheckpoint: true)

        let incrementalLedger = try await incremental.ledger()
        let fullLedger = try await full.ledger()
        XCTAssertGreaterThan(incrementalLedger.incrementalReconcileCount, 0)
        XCTAssertEqual(fullLedger.incrementalReconcileCount, 0)
    }

    // MARK: - Engine diagnostics and warm relaunch

    func testGraphIndexReportsBatchTimingAndWarmRelaunchReusesArtifacts() async throws {
        let repository = try ReviewGitRepositoryFixture(name: #function)
        let rootURL = try repository.makeRepository(
            named: "root",
            files: [
                "Sources/First.swift": "struct First { let second: Second }\n",
                "Sources/Second.swift": "struct Second {}\n",
                "Sources/Third.swift": "struct Third { let first: First }\n"
            ]
        )
        let fixture = try CodemapStoreFixture(name: #function)
        let store = fixture.makeStore()
        addTeardownBlock {
            await fixture.shutdown()
            repository.cleanup()
        }

        let firstLoad = try await store.loadRoot(path: rootURL.path)
        let engine = try fixture.runtime().bindingEngine()
        let firstRun = try await waitForGraphCompletion(engine: engine, rootID: firstLoad.id)
        XCTAssertGreaterThan(firstRun.batchTiming.batchCount, 0)
        XCTAssertGreaterThanOrEqual(firstRun.batchTiming.publishedSlotCount, 3)
        XCTAssertGreaterThan(firstRun.batchTiming.totalBatchDurationNanoseconds, 0)
        XCTAssertGreaterThanOrEqual(
            firstRun.batchTiming.totalBatchDurationNanoseconds,
            firstRun.batchTiming.maximumBatchDurationNanoseconds
        )
        let afterFirst = await engine.accounting()
        XCTAssertGreaterThanOrEqual(afterFirst.counters.graphIndexPublishedSlots, 3)
        XCTAssertGreaterThan(afterFirst.counters.graphIndexBatchNanoseconds, 0)
        let buildsAfterFirst = fixture.builtSourceTexts.values.count
        XCTAssertGreaterThan(buildsAfterFirst, 0)

        // A warm relaunch of the unchanged root rebuilds the in-memory graph from durable
        // artifacts; it must not parse any source again.
        await store.unloadRoot(id: firstLoad.id)
        let secondLoad = try await store.loadRoot(path: rootURL.path)
        addTeardownBlock { await store.unloadRoot(id: secondLoad.id) }
        let secondRun = try await waitForGraphCompletion(
            engine: engine,
            rootID: secondLoad.id,
            excluding: firstRun.rootEpoch
        )
        XCTAssertEqual(secondRun.progress.counts.processedCandidateCount, 3)
        XCTAssertEqual(fixture.builtSourceTexts.values.count, buildsAfterFirst)
        let afterSecond = await engine.accounting()
        XCTAssertEqual(
            afterSecond.counters.graphIndexArtifactBuildsStarted,
            afterFirst.counters.graphIndexArtifactBuildsStarted
        )
    }

    // MARK: - Helpers

    private func waitForGraphCompletion(
        engine: WorkspaceCodemapBindingEngine,
        rootID: UUID,
        excluding excludedRootEpoch: WorkspaceCodemapRootEpoch? = nil
    ) async throws -> WorkspaceCodemapBindingEngineGraphIndexRootAccounting {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while clock.now < deadline {
            let accounting = await engine.accounting()
            if let root = accounting.graphIndexRoots.first(where: {
                $0.rootEpoch.rootID == rootID && $0.rootEpoch != excludedRootEpoch
            }),
                root.phase == .complete
            {
                return root
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw HarnessError.timedOut
    }

    private func assertSameLedger(
        _ lhs: Harness,
        _ rhs: Harness,
        since generation: WorkspaceCodemapSelectionGraphContributionGeneration?,
        expectCheckpoint: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let left = await lhs.overlay.graphCheckpoint(rootEpoch: lhs.rootEpoch)
        let right = await rhs.overlay.graphCheckpoint(rootEpoch: rhs.rootEpoch)
        XCTAssertEqual(left, right, file: file, line: line)
        if expectCheckpoint, case .revoked = left {
            XCTFail("Expected a constructible checkpoint", file: file, line: line)
        }
        let leftLedger = try await lhs.ledger()
        let rightLedger = try await rhs.ledger()
        XCTAssertEqual(leftLedger.contributionGeneration, rightLedger.contributionGeneration, file: file, line: line)
        XCTAssertEqual(leftLedger.floorGeneration, rightLedger.floorGeneration, file: file, line: line)
        XCTAssertEqual(leftLedger.slotCount, rightLedger.slotCount, file: file, line: line)
        for since in [generation, leftLedger.floorGeneration].compactMap(\.self) {
            let leftChanges = await lhs.overlay.graphChanges(rootEpoch: lhs.rootEpoch, since: since)
            let rightChanges = await rhs.overlay.graphChanges(rootEpoch: rhs.rootEpoch, since: since)
            XCTAssertEqual(leftChanges, rightChanges, file: file, line: line)
        }
    }

    private func assertSameGraph(
        _ lhs: WorkspaceCodemapGraphCommittedSnapshot,
        _ rhs: WorkspaceCodemapGraphCommittedSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(lhs.coverage, rhs.coverage, file: file, line: line)
        XCTAssertEqual(lhs.appliedGeneration, rhs.appliedGeneration, file: file, line: line)
        XCTAssertEqual(lhs.slotsByFileID, rhs.slotsByFileID, file: file, line: line)
        XCTAssertEqual(lhs.nodesByFileID, rhs.nodesByFileID, file: file, line: line)
        XCTAssertEqual(lhs.definitionPostings, rhs.definitionPostings, file: file, line: line)
        XCTAssertEqual(lhs.referencePostings, rhs.referencePostings, file: file, line: line)
        XCTAssertEqual(lhs.outgoingEdgesBySource, rhs.outgoingEdgesBySource, file: file, line: line)
        XCTAssertEqual(lhs.reverseEdgesByTarget, rhs.reverseEdgesByTarget, file: file, line: line)
        XCTAssertEqual(lhs.unresolvedBySource, rhs.unresolvedBySource, file: file, line: line)
        XCTAssertEqual(lhs.sizeAccounting, rhs.sizeAccounting, file: file, line: line)
    }
}

private enum HarnessError: Error {
    case timedOut
    case missingLedger
    case unexpectedDisposition(String)
}

private struct HarnessFile {
    let fileID: UUID
    let path: String
    let pending: WorkspaceCodemapGraphSlot
    let contributed: WorkspaceCodemapGraphSlot
}

/// Drives the overlay and selection graph directly, emulating the engine's pull loop.
private final class Harness {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let catalogToken: WorkspaceCodemapGraphIndexCatalogToken
    let overlay: WorkspaceCodemapLiveOverlay
    let graph: WorkspaceCodemapSelectionGraph
    private let pipeline: CodeMapPipelineIdentity
    private let authority: WorkspaceCodemapRepositoryAuthorityToken
    private let seed: UInt8

    init(seed: UInt8, mode: WorkspaceCodemapGraphReconcileMode = .incremental) async throws {
        self.seed = seed
        rootEpoch = WorkspaceCodemapRootEpoch(
            rootID: UUID(uuid: (seed, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)),
            rootLifetimeID: UUID(uuid: (seed, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2))
        )
        catalogToken = WorkspaceCodemapGraphIndexCatalogToken(
            rootEpoch: rootEpoch,
            topologyGeneration: 1,
            appliedIndexGeneration: 2,
            catalogGeneration: 3,
            ingressGeneration: 4,
            graphIndexInvalidationGeneration: 5
        )
        pipeline = try SyntaxManager().pipelineIdentity(for: .swift, decoderPolicy: .workspaceAutomaticV1)
        let namespace = try GitBlobRepositoryNamespace(rawValue: String(repeating: "cd", count: 32))
        authority = WorkspaceCodemapRepositoryAuthorityToken(
            authorityGeneration: 1,
            repositoryNamespace: namespace,
            objectFormat: .sha1,
            repositoryBindingEpoch: "repository",
            worktreeBindingEpoch: "worktree",
            layoutGeneration: "layout",
            indexGeneration: "index",
            checkoutConfigurationGeneration: "checkout",
            attributeGeneration: "attributes",
            sparseGeneration: "sparse",
            metadataGeneration: "metadata"
        )
        let root = URL(fileURLWithPath: "/workspace")
        let git = root.appendingPathComponent(".git", isDirectory: true)
        let capability = GitCodemapRootCapability(
            rootEpoch: rootEpoch,
            repositoryLayout: GitRepositoryLayout(
                workTreeRoot: root,
                dotGitPath: git,
                gitDir: git,
                commonDir: git,
                isWorktree: false
            ),
            repositoryIdentity: GitWorktreeRepositoryIdentity(
                repositoryID: "repository",
                repoKey: "repository",
                displayName: "workspace",
                commonGitDir: git.path,
                mainWorktreeRoot: root.path
            ),
            worktreeID: "worktree",
            repositoryNamespace: namespace,
            objectFormat: .sha1,
            repositoryRelativeLoadedRootPrefix: "",
            repositoryAuthority: authority
        )
        overlay = WorkspaceCodemapLiveOverlay(graphReconcileMode: mode)
        graph = WorkspaceCodemapSelectionGraph(rootEpoch: rootEpoch)
        let registration = await overlay.register(capability: .eligible(capability), catalogGeneration: 3)
        guard case .registered = registration else {
            throw HarnessError.unexpectedDisposition("\(registration)")
        }
    }

    /// Files reference their successor, a hub type defined by file 0, a name with a handful of
    /// early definers (ambiguous edges), and a never-defined name (unresolved evidence).
    func makeFiles(count: Int) throws -> [HarnessFile] {
        try (0 ..< count).map { index in
            let fileID = fileID(index)
            let path = "Sources/Module\(index % 16)/File\(index).swift"
            var definitions = ["Type\(index)"]
            if index < 8 { definitions.append("Shared") }
            let references = ["Type\((index + 1) % count)", "Type0", "Shared", "Missing\(index % 5)"]
            let pending = try makeSlot(fileID: fileID, path: path, state: .pending)
            let contributed = try makeSlot(
                fileID: fileID,
                path: path,
                definitions: definitions,
                references: references
            )
            return HarnessFile(fileID: fileID, path: path, pending: pending, contributed: contributed)
        }
    }

    func makeSlot(
        fileID: UUID,
        path: String,
        definitions: [String],
        references: [String],
        requestGeneration: UInt64 = 1
    ) throws -> WorkspaceCodemapGraphSlot {
        let digest = Data(SHA256.hash(data: Data((fileID.uuidString + path).utf8)))
        let contribution = CodeMapSelectionGraphContribution(
            artifactKey: CodeMapArtifactKey(
                rawSHA256: CodeMapRawSourceDigest(bytes: digest),
                rawByteCount: UInt64(path.utf8.count),
                pipelineIdentity: pipeline
            ),
            definitions: definitions,
            references: references
        )
        return try makeSlot(
            fileID: fileID,
            path: path,
            state: .contributed(contribution),
            requestGeneration: requestGeneration
        )
    }

    private func makeSlot(
        fileID: UUID,
        path: String,
        state: WorkspaceCodemapGraphSlotState,
        requestGeneration: UInt64 = 1
    ) throws -> WorkspaceCodemapGraphSlot {
        guard let identity = WorkspaceCodemapArtifactBindingIdentity(
            rootID: rootEpoch.rootID,
            rootLifetimeID: rootEpoch.rootLifetimeID,
            fileID: fileID,
            standardizedRootPath: "/workspace",
            standardizedRelativePath: path,
            standardizedFullPath: "/workspace/\(path)"
        ) else { throw HarnessError.unexpectedDisposition("identity") }
        return try WorkspaceCodemapGraphSlot.validated(
            rootEpoch: rootEpoch,
            identity: identity,
            requestGeneration: requestGeneration,
            pathGeneration: 1,
            pipelineIdentity: pipeline,
            state: state,
            diagnostics: WorkspaceCodemapGraphSlotDiagnostics(
                contributionDigest: state.contributionDigestForTesting,
                source: .graphIndex
            )
        ).get()
    }

    private func fileID(_ index: Int) -> UUID {
        let value = UInt32(index)
        return UUID(uuid: (
            seed, 0x10, 0, 0,
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
            0, 0, 0, 0, 0, 0, 0, 0
        ))
    }

    func ledger() async throws -> WorkspaceCodemapGraphLedgerAccounting {
        guard let ledger = await overlay.graphLedgerAccounting(rootEpoch: rootEpoch) else {
            throw HarnessError.missingLedger
        }
        return ledger
    }

    func checkpoint() async throws -> WorkspaceCodemapGraphCheckpoint {
        switch await overlay.graphCheckpoint(rootEpoch: rootEpoch) {
        case let .checkpoint(checkpoint): return checkpoint
        case let .revoked(reason): throw HarnessError.unexpectedDisposition("\(reason)")
        }
    }

    /// One iteration of the engine's pull loop.
    @discardableResult
    func pull() async -> WorkspaceCodemapGraphApplyDisposition? {
        let accounting = await graph.incrementalAccounting()
        await overlay.acknowledgeGraphChanges(rootEpoch: rootEpoch, through: accounting.appliedGeneration)
        let changes = await overlay.graphChanges(rootEpoch: rootEpoch, since: accounting.appliedGeneration)
        if case .unchanged = changes { return nil }
        return await graph.apply(changes)
    }

    func latestSnapshot(
        _ graph: WorkspaceCodemapSelectionGraph
    ) async throws -> WorkspaceCodemapGraphCommittedSnapshot {
        guard case let .ready(pinned) = await graph.latestSnapshot() else {
            throw HarnessError.unexpectedDisposition("snapshot")
        }
        return pinned.snapshot
    }

    func rebuiltFromCheckpoint() async throws -> WorkspaceCodemapGraphCommittedSnapshot {
        let checkpoint = try await checkpoint()
        let rebuilt = WorkspaceCodemapSelectionGraph(rootEpoch: rootEpoch)
        let disposition = await rebuilt.apply(.resync(checkpoint: checkpoint, generation: checkpoint.generation))
        guard case .committed = disposition else {
            throw HarnessError.unexpectedDisposition("\(disposition)")
        }
        return try await latestSnapshot(rebuilt)
    }
}

private extension WorkspaceCodemapGraphSlotState {
    var contributionDigestForTesting: CodeMapSHA256Digest? {
        switch self {
        case let .contributed(value), let .empty(value): value.contributionDigest
        case .pending, .terminalArtifact, .terminalExcluded: nil
        }
    }
}
