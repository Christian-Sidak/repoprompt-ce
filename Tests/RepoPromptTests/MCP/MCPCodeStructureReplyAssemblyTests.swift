import Foundation
import MCP
import os
@testable import RepoPromptApp
import RepoPromptCodeMapCore
import XCTest

#if DEBUG
    /// M9: `get_code_structure` reply assembly (ordering, signature token-budget accounting, issue
    /// mapping, status rollup) is a pure function of immutable inputs. These tests pin its exact
    /// output with a golden captured from the pre-extraction MainActor implementation. Since M15 the
    /// query core calls it off the main actor (`MCPCodeStructureQueryOrchestratorTests`); only the
    /// final `Value` encoding still hops to the projection worker.
    final class MCPCodeStructureReplyAssemblyTests: XCTestCase {
        private typealias Fixture = CodeStructureReplyAssemblyFixture

        /// Nonisolated on purpose: this only compiles while the assembler stays actor-free.
        func testPureAssemblyMatchesPreExtractionGolden() throws {
            let reply = try MCPCodeStructureReplyProjection.assemble(Fixture.input())

            let golden = try JSONDecoder().decode(
                ToolResultDTOs.CodeStructureReplyDTO.self,
                from: Data(Self.goldenJSON.utf8)
            )
            XCTAssertEqual(reply, golden)
            XCTAssertEqual(try Fixture.formattedText(reply), Self.goldenText)
        }

        @MainActor
        func testReplyEncodingRunsOnProjectionWorkerWithIdenticalValue() async throws {
            let reply = try MCPCodeStructureReplyProjection.assemble(Fixture.input())
            let recorder = ProjectionExecutionRecorder()
            MCPProviderProjectionWorker.executionObserverForTesting = recorder.observer
            defer { MCPProviderProjectionWorker.executionObserverForTesting = nil }

            let value = try await MCPCodeStructureReplyProjection.encodeReply(reply)

            XCTAssertEqual(value, try Value(reply))
            XCTAssertEqual(value.decode(ToolResultDTOs.CodeStructureReplyDTO.self), reply)
            XCTAssertEqual(recorder.events, [.init(
                toolName: MCPWindowToolName.getCodeStructure,
                phase: "value_encoding",
                ranOnMainThread: false
            )])
        }

        /// M10: seed order is UTF-8 logical path, then UUID string. Paths equal as `String`
        /// (canonically equivalent) fall through to the UUID, and a decomposed `é` orders by its UTF-8
        /// bytes before `f`, unlike `String` ordering. Nonisolated: the sort stays actor-free.
        func testSeedOrderIsUTF8LogicalPathThenUUIDString() {
            let decomposed = "src/e\u{301}.swift"
            let precomposed = "src/\u{E9}.swift"
            // The fixture must separate UTF-8 from `String` ordering to prove which one applies.
            XCTAssertEqual(decomposed, precomposed)
            XCTAssertTrue(decomposed > "src/f.swift")
            let keys = [
                Self.seedKey("src/b.swift", 10),
                Self.seedKey("src/f.swift", 20),
                Self.seedKey(decomposed, 30),
                Self.seedKey(precomposed, 40),
                Self.seedKey("src/a.swift", 60),
                Self.seedKey("src/a.swift", 50),
                Self.seedKey("Beta/src/a.swift", 70),
                Self.seedKey("Alpha/src/a.swift", 80),
                Self.seedKey("src/Z.swift", 90)
            ]
            let expected = [80, 70, 90, 50, 60, 10, 30, 20, 40].map(Fixture.uuid)

            XCTAssertEqual(MCPCodeStructureReplyProjection.orderedSeedFileIDs(keys), expected)
            XCTAssertEqual(MCPCodeStructureReplyProjection.orderedSeedFileIDs(keys.reversed()), expected)
            XCTAssertEqual(MCPCodeStructureReplyProjection.orderedSeedFileIDs(Array(keys[4...] + keys[..<4])), expected)
        }

        /// M10: keys projected once per seed and ordered by the pure sort give exactly the order of
        /// the former comparator, which re-projected both logical paths on every comparison:
        /// single-root relative paths, labelled multi-root paths, and an unlabelled root whose
        /// relative-path fallback ties with a labelled path and falls through to the UUID.
        /// Nonisolated: since M15 the key projection is actor-free.
        func testSeedOrderKeysReproduceFormerComparatorOrder() {
            let alpha = WorkspaceRootRef(id: Fixture.uuid(901), name: "Alpha", fullPath: "/repo/alpha")
            let beta = WorkspaceRootRef(id: Fixture.uuid(902), name: "Beta", fullPath: "/repo/beta")
            let unlabelled = WorkspaceRootRef(id: Fixture.uuid(903), name: "Gamma", fullPath: "/repo/gamma")
            let labels = [alpha.id: "Alpha", beta.id: "Beta"]
            let records = [
                Self.record(1, alpha, "src/b.swift"),
                Self.record(2, beta, "src/a.swift"),
                Self.record(3, unlabelled, "Alpha/src/b.swift"),
                Self.record(4, alpha, "src/e\u{301}.swift"),
                Self.record(5, alpha, "src/f.swift"),
                Self.record(6, unlabelled, "src/a.swift"),
                Self.record(7, beta, "Z.swift")
            ]
            let cases: [(roots: [WorkspaceRootRef], files: [WorkspaceFileRecord], expected: [Int])] = [
                ([alpha, beta, unlabelled], records, [1, 3, 4, 5, 7, 2, 6]),
                ([alpha], records.filter { $0.rootID == alpha.id }, [1, 4, 5])
            ]

            for (roots, files, expected) in cases {
                let keys = files.map {
                    MCPCodeStructureReplyProjection.seedOrderKey(
                        for: $0,
                        roots: roots,
                        lookupContext: .visibleWorkspace,
                        logicalRootDisplayNamesByRootID: labels
                    )
                }
                let ordered = MCPCodeStructureReplyProjection.orderedSeedFileIDs(keys)

                XCTAssertEqual(ordered, expected.map(Fixture.uuid), "roots: \(roots.map(\.name))")
                XCTAssertEqual(
                    ordered,
                    Self.formerComparatorOrder(files, roots: roots, labels: labels),
                    "roots: \(roots.map(\.name))"
                )
            }
        }

        private static func seedKey(_ logicalPath: String, _ id: Int) -> MCPCodeStructureReplyProjection.SeedOrderKey {
            MCPCodeStructureReplyProjection.SeedOrderKey(logicalPath: logicalPath, fileID: Fixture.uuid(id))
        }

        private static func record(_ id: Int, _ root: WorkspaceRootRef, _ relativePath: String) -> WorkspaceFileRecord {
            WorkspaceFileRecord(
                id: Fixture.uuid(id),
                rootID: root.id,
                name: (relativePath as NSString).lastPathComponent,
                relativePath: relativePath,
                fullPath: "\(root.fullPath)/\(relativePath)",
                parentFolderID: nil
            )
        }

        /// The pre-M10 main-actor comparator, verbatim apart from its inputs.
        private static func formerComparatorOrder(
            _ files: [WorkspaceFileRecord],
            roots: [WorkspaceRootRef],
            labels: [UUID: String]
        ) -> [UUID] {
            func logicalPath(_ file: WorkspaceFileRecord) -> String {
                WorkspaceLookupContext.visibleWorkspace.logicalDisplayPath(
                    for: file,
                    roots: roots,
                    rootDisplayNamesByRootID: labels,
                    display: .relative
                ) ?? file.standardizedRelativePath
            }
            return files.sorted { lhs, rhs in
                let left = logicalPath(lhs)
                let right = logicalPath(rhs)
                if left != right { return left.utf8.lexicographicallyPrecedes(right.utf8) }
                return lhs.id.uuidString < rhs.id.uuidString
            }.map(\.id)
        }

        /// Captured from the pre-extraction MainActor `MCPServerViewModel.codeStructureReplyDTO`.
        private static let goldenJSON = #"{"files":[{"content":"a1 signatures","depth":0,"path":"a1.swift","reached_by":[],"role":"seed","tokens":10},{"content":"a3 signatures","depth":1,"path":"a3.swift","reached_by":["used_by","uses"],"role":"related","tokens":4}],"issues":[{"code":"graph_size_limit","message":"The graph was truncated to fit the requested size.","phase":"graph_traversal","retryable":false},{"code":"signature_pending","message":"Signature generation is still pending.","path":"c1.swift","phase":"render_demand","retry_after_ms":100,"retryable":true},{"code":"signature_unavailable","message":"A signature artifact is unavailable; graph data remains usable.","path":"d2.swift","phase":"render_demand","retry_after_ms":100,"retryable":true},{"code":"signature_unavailable","message":"A signature artifact is unavailable; graph data remains usable.","path":"d1.swift","phase":"render_demand","retryable":false},{"code":"signature_freeze_failed","message":"Signatures could not be frozen; graph data remains usable.","phase":"freeze","retryable":false},{"code":"signature_unavailable","message":"A current signature candidate is unavailable.","phase":"render_demand","retryable":false},{"code":"signature_size_limit","message":"Some signatures were omitted to fit the requested output size.","phase":"render","retryable":false}],"retry":{"retry_after_ms":100,"retryable":true},"roots":[{"edges":[{"from":"a1.swift","symbols":["Foo","Bar"],"to":"a2.swift"},{"ambiguous":true,"from":"a3.swift","symbols":["run"],"to":"a1.swift"}],"index":{"indexed":3,"state":"complete","total":3},"issues":[],"nodes":[{"depth":0,"path":"a1.swift","reached_by":[],"seed":true},{"depth":1,"path":"a3.swift","reached_by":["used_by","uses"]},{"depth":1,"path":"a2.swift","reached_by":["uses"]}],"root":"Alpha","seeds":[{"path":"a1.swift","state":"covered"}],"status":"ok","truncated":{"dropped_nodes":2,"reason":"size"},"unresolved":[{"from":"a1.swift","name":"Baz","reason":"missing"},{"from":"a2.swift","name":"Qux","reason":"not_indexed_yet"}]},{"edges":[],"index":{"indexed":3,"state":"indexing","total":4},"issues":[{"attempted":3,"code":"seed_not_indexed","limit":4,"message":"Seed is not indexed yet.","path":"b1.swift","phase":"seed_resolution","retry_after_ms":100,"retryable":true},{"code":"signature_unavailable","message":"One or more signatures could not be rendered; graph data remains usable.","phase":"render","retryable":false}],"nodes":[{"depth":0,"path":"b2.swift","reached_by":[],"seed":true}],"root":"Beta","seeds":[{"path":"b1.swift","state":"not_indexed"},{"path":"b2.swift","state":"pending"}],"status":"partial","unresolved":[],"updates_pending":true},{"edges":[],"index":{"indexed":3,"state":"complete","total":3},"issues":[],"nodes":[{"depth":0,"path":"d1.swift","reached_by":[],"seed":true},{"depth":1,"path":"d2.swift","reached_by":["used_by"]}],"root":"Delta","seeds":[{"path":"d1.swift","state":"excluded"}],"status":"ok","unresolved":[]},{"edges":[],"index":{"indexed":3,"state":"complete","total":3},"issues":[{"code":"graph_revoked","message":"The graph was revoked.","phase":"graph_revalidation","retryable":false}],"nodes":[],"root":"Gamma","seeds":[{"path":"c1.swift","state":"covered"}],"status":"unavailable","unresolved":[]}],"size":"small","status":"partial","summary":{"edges":2,"files":2,"nodes":6,"seeds":5,"tokens":14},"worktree_scope":{"display_identity":"logical","effective_identity":"physical","kind":"session_bound","root_mappings":[]}}"#

        private static let goldenText = [
            #"## Code Structure ⚠️ partial — a retry may return more relationships; rerun with size: medium"#,
            #"- Result: 5 seeds + 3 related • 2 edges • signatures 2 files, 14 tokens"#,
            #"- Roots: 4 (1 partial, 1 unavailable, 2 ok)"#,
            #"- Scope: session-bound worktree. Displayed paths use logical/canonical roots; codemap scans use the bound checkout."#,
            #""#,
            #"### Root `Alpha` — paths below are root-relative"#,
            #""#,
            #"#### Graph"#,
            #"- `a1.swift` (seed) → uses:"#,
            #"  - `a2.swift` — Foo, Bar"#,
            #"- `a3.swift` → uses:"#,
            #"  - `a1.swift` — run (ambiguous)"#,
            #""#,
            #"#### Signatures"#,
            #"- Omitted (3): `a1.swift`, `a3.swift`, `a2.swift` — rerun with size: medium"#,
            #""#,
            #"### Root `Beta` — paths below are root-relative"#,
            #""#,
            #"#### Graph"#,
            #"- `b2.swift` (seed) — no relationships returned"#,
            #""#,
            #"#### Signatures"#,
            #"- Omitted (1): `b2.swift` — rerun with size: medium"#,
            #""#,
            #"### Root `Delta` — paths below are root-relative"#,
            #""#,
            #"#### Graph"#,
            #"- `d1.swift` (seed) — no relationships returned"#,
            #"- `d2.swift` — no relationships returned"#,
            #""#,
            #"#### Signatures"#,
            #"- Omitted (2): `d1.swift`, `d2.swift` — rerun with size: medium"#,
            #""#,
            #"### Root `Gamma` — paths below are root-relative"#,
            #""#,
            #"### Signatures"#,
            #"#### `a1.swift` — seed • 10 tokens"#,
            #"```text"#,
            #"a1 signatures"#,
            #"```"#,
            #"#### `a3.swift` — used_by/uses, depth 1 • 4 tokens"#,
            #"```text"#,
            #"a3 signatures"#,
            #"```"#,
            #""#,
            #"### Diagnostics"#,
            #"- `Alpha` Truncated: 2 files dropped"#,
            #"- `Beta` Seed `b1.swift` returned nothing — excluded or unsupported type"#,
            #"- `Beta` Seed `b2.swift` returned nothing — excluded or unsupported type"#,
            #"- `Delta` Seed `d1.swift` returned nothing — excluded or unsupported type"#,
            #"- Signatures could not be frozen; graph data remains usable"#
        ].joined(separator: "\n")
    }

    /// Lock-protected record of projection-worker executions, written from the worker.
    final class ProjectionExecutionRecorder: Sendable {
        private let storage = OSAllocatedUnfairLock(initialState: [MCPProviderProjectionWorker.ExecutionForTesting]())

        var events: [MCPProviderProjectionWorker.ExecutionForTesting] {
            storage.withLock { $0 }
        }

        var observer: @Sendable (MCPProviderProjectionWorker.ExecutionForTesting) -> Void {
            { [storage] event in storage.withLock { $0.append(event) } }
        }
    }

    enum CodeStructureReplyAssemblyFixture {
        typealias Input = MCPCodeStructureReplyProjection.AssemblyInput

        static func canonicalJSON(_ reply: ToolResultDTOs.CodeStructureReplyDTO) throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            return try String(decoding: encoder.encode(reply), as: UTF8.self)
        }

        static func formattedText(_ reply: ToolResultDTOs.CodeStructureReplyDTO) throws -> String {
            try ToolOutputFormatter.formatCodeStructure(value: Value(reply)).map { content -> String in
                if case let .text(text, _, _) = content { return text }
                return String(describing: content)
            }.joined(separator: "\n---\n")
        }

        static func uuid(_ n: Int) -> UUID {
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
        }

        static func epoch(_ n: Int) -> WorkspaceCodemapRootEpoch {
            WorkspaceCodemapRootEpoch(rootID: uuid(900 + n), rootLifetimeID: uuid(950 + n))
        }

        static func coverage(
            _ rootEpoch: WorkspaceCodemapRootEpoch,
            complete: Bool
        ) throws -> WorkspaceCodemapGraphCatalogCoverage {
            let token = WorkspaceCodemapGraphIndexCatalogToken(
                rootEpoch: rootEpoch,
                topologyGeneration: 1,
                appliedIndexGeneration: 1,
                catalogGeneration: 1,
                ingressGeneration: 1,
                graphIndexInvalidationGeneration: 1
            )
            return try WorkspaceCodemapGraphCatalogCoverage.validated(
                rootEpoch: rootEpoch,
                catalogWatermark: token,
                enumerationState: complete ? .complete : .partial,
                isCatalogSealed: complete,
                supportedCount: complete ? 3 : 4,
                classifiedCount: 3,
                pendingCount: complete ? 0 : 1,
                contributedCount: 3,
                emptyCount: 0,
                terminalArtifactCount: 0,
                terminalExcludedCount: 0
            ).get()
        }

        static func node(
            _ id: Int,
            _ path: String,
            depth: Int,
            seed: Bool = false,
            reachedBy: Set<WorkspaceCodemapStructureTraversalReachDirection> = []
        ) -> WorkspaceCodemapStructureNodeResult {
            WorkspaceCodemapStructureNodeResult(fileID: uuid(id), path: path, depth: depth, isSeed: seed, reachedBy: reachedBy)
        }

        static func root(
            _ rootEpoch: WorkspaceCodemapRootEpoch,
            name: String,
            status: WorkspaceCodemapStructureStatus = .ok,
            coverage: WorkspaceCodemapGraphCatalogCoverage?,
            updatesPending: Bool = false,
            seeds: [WorkspaceCodemapStructureSeedResult],
            nodes: [WorkspaceCodemapStructureNodeResult],
            edges: [WorkspaceCodemapStructureEdgeResult] = [],
            unresolved: [WorkspaceCodemapStructureUnresolvedResult] = [],
            truncation: WorkspaceCodemapGraphStructureTruncation? = nil,
            issues: [WorkspaceCodemapStructureIssueRecord] = []
        ) -> WorkspaceCodemapStructureRootResult {
            WorkspaceCodemapStructureRootResult(
                rootEpoch: rootEpoch,
                rootDisplayName: name,
                status: status,
                coverage: coverage,
                updatesPending: updatesPending,
                seeds: seeds,
                nodes: nodes,
                edges: edges,
                unresolved: unresolved,
                truncation: truncation,
                issues: issues,
                receipt: nil
            )
        }

        static func entry(
            _ id: Int,
            _ rootEpoch: WorkspaceCodemapRootEpoch,
            root: String,
            path: String,
            text: String,
            tokens: Int,
            pipeline: CodeMapPipelineIdentity
        ) throws -> WorkspaceCodemapOperationRenderedEntry {
            try WorkspaceCodemapOperationRenderedEntry(
                bundleID: WorkspaceCodemapFrozenPresentationBundleID(rawValue: uuid(800)),
                fileID: uuid(id),
                rootEpoch: rootEpoch,
                artifactKey: CodeMapArtifactKey(
                    rawSHA256: CodeMapRawSourceDigest(bytes: Data(repeating: UInt8(id % 256), count: 32)),
                    rawByteCount: UInt64(id),
                    pipelineIdentity: pipeline
                ),
                logicalPath: XCTUnwrap(WorkspaceCodemapLogicalPresentationPath(
                    rootDisplayName: root,
                    standardizedRelativePath: path
                )),
                text: text,
                tokenCount: tokens
            )
        }

        static func ticket(_ id: Int, _ rootEpoch: WorkspaceCodemapRootEpoch) -> WorkspaceCodemapArtifactDemandTicket {
            WorkspaceCodemapArtifactDemandTicket(
                retainID: uuid(700 + id),
                requestID: uuid(750),
                rootEpoch: rootEpoch,
                fileID: uuid(id),
                requestGeneration: 1,
                catalogGeneration: 1,
                pathGeneration: 1,
                ingressGeneration: 1
            )
        }

        /// Four roots supplied out of display order: Beta (partial coverage, pending revalidation,
        /// retry-upgraded `seed_not_indexed`, missing signature), Alpha (complete, budget omission),
        /// Gamma (revalidation invalid), Delta (freeze issue covers the root; a busy node).
        static func input() throws -> Input {
            let pipeline = try SyntaxManager().pipelineIdentity(for: .swift, decoderPolicy: .workspaceAutomaticV1)
            let alpha = epoch(1), beta = epoch(2), gamma = epoch(3), delta = epoch(4)
            let aggregate = try WorkspaceCodemapStructureAggregateResult(
                status: .partial,
                roots: [
                    root(
                        beta,
                        name: "Beta",
                        status: .partial,
                        coverage: coverage(beta, complete: false),
                        updatesPending: false,
                        seeds: [
                            WorkspaceCodemapStructureSeedResult(fileID: uuid(21), path: "b1.swift", state: .notIndexed),
                            WorkspaceCodemapStructureSeedResult(fileID: uuid(22), path: "b2.swift", state: .pending)
                        ],
                        nodes: [node(22, "b2.swift", depth: 0, seed: true)],
                        issues: [WorkspaceCodemapStructureIssueRecord(
                            code: "seed_not_indexed",
                            phase: "seed_resolution",
                            path: "b1.swift",
                            retryable: false,
                            retryAfterMilliseconds: nil,
                            attempted: 3,
                            limit: 4,
                            message: "Seed is not indexed yet."
                        )]
                    ),
                    root(
                        alpha,
                        name: "Alpha",
                        coverage: coverage(alpha, complete: true),
                        seeds: [WorkspaceCodemapStructureSeedResult(fileID: uuid(11), path: "a1.swift", state: .covered)],
                        nodes: [
                            node(11, "a1.swift", depth: 0, seed: true),
                            node(13, "a3.swift", depth: 1, reachedBy: [.referrers, .referencedDefinitions]),
                            node(12, "a2.swift", depth: 1, reachedBy: [.referencedDefinitions])
                        ],
                        edges: [
                            WorkspaceCodemapStructureEdgeResult(fromPath: "a1.swift", toPath: "a2.swift", symbols: ["Foo", "Bar"], ambiguous: false),
                            WorkspaceCodemapStructureEdgeResult(fromPath: "a3.swift", toPath: "a1.swift", symbols: ["run"], ambiguous: true)
                        ],
                        unresolved: [
                            WorkspaceCodemapStructureUnresolvedResult(fromPath: "a1.swift", name: "Baz", reason: .missing),
                            WorkspaceCodemapStructureUnresolvedResult(fromPath: "a2.swift", name: "Qux", reason: .notIndexedYet)
                        ],
                        truncation: WorkspaceCodemapGraphStructureTruncation(droppedNodeCount: 2)
                    ),
                    root(
                        gamma,
                        name: "Gamma",
                        coverage: coverage(gamma, complete: true),
                        seeds: [WorkspaceCodemapStructureSeedResult(fileID: uuid(31), path: "c1.swift", state: .covered)],
                        nodes: [node(31, "c1.swift", depth: 0, seed: true)],
                        edges: [WorkspaceCodemapStructureEdgeResult(fromPath: "c1.swift", toPath: "c1.swift", symbols: ["x"], ambiguous: false)],
                        unresolved: [WorkspaceCodemapStructureUnresolvedResult(fromPath: "c1.swift", name: "Y", reason: .tooCommon)]
                    ),
                    root(
                        delta,
                        name: "Delta",
                        coverage: coverage(delta, complete: true),
                        seeds: [WorkspaceCodemapStructureSeedResult(fileID: uuid(41), path: "d1.swift", state: .excluded)],
                        nodes: [node(41, "d1.swift", depth: 0, seed: true), node(42, "d2.swift", depth: 1, reachedBy: [.referrers])]
                    )
                ],
                issues: [WorkspaceCodemapStructureIssueRecord(
                    code: "graph_size_limit",
                    phase: "graph_traversal",
                    path: nil,
                    retryable: false,
                    retryAfterMilliseconds: nil,
                    attempted: 500,
                    limit: 200,
                    message: "The graph was truncated to fit the requested size."
                )]
            )
            let presentation = try WorkspaceCodemapOperationPresentation(
                id: uuid(600),
                orderedEntries: [
                    entry(11, alpha, root: "Alpha", path: "a1.swift", text: "a1 signatures", tokens: 10, pipeline: pipeline),
                    entry(12, alpha, root: "Alpha", path: "a2.swift", text: "a2 signatures", tokens: 30, pipeline: pipeline),
                    entry(13, alpha, root: "Alpha", path: "a3.swift", text: "a3 signatures", tokens: 4, pipeline: pipeline),
                    entry(31, gamma, root: "Gamma", path: "c1.swift", text: "c1 signatures", tokens: 1, pipeline: pipeline)
                ],
                coverage: .partial([]),
                issues: [
                    .pending(fileID: uuid(31), ticket: ticket(31, gamma)),
                    .unavailable(fileID: uuid(42), reason: .busy(retryAfterMilliseconds: 50)),
                    .unavailable(fileID: uuid(41), reason: .unsupportedFileType),
                    .freezeUnavailable(rootEpoch: delta, reason: .mixedRootEpoch),
                    .candidate(.fileNotCataloged(uuid(99)))
                ],
                publicationReceipt: nil
            )
            return Input(
                aggregate: aggregate,
                presentation: presentation,
                revalidation: [
                    alpha: .valid(updatesPending: false),
                    beta: .valid(updatesPending: true),
                    gamma: .invalid(code: "graph_revoked", message: "The graph was revoked.")
                ],
                includesSignatures: true,
                budget: WorkspaceCodemapGraphQueryBudget(
                    maximumTokenCount: 2000,
                    maximumNodeCount: 40,
                    maximumEdgeCount: 4000,
                    maximumGraphByteCount: 32000,
                    graphEvidenceTokenCount: 1984,
                    renderTokenCount: 16
                ),
                size: .small,
                worktreeScope: ToolResultDTOs.WorktreeScopeDTO(
                    kind: "session_bound",
                    displayIdentity: "logical",
                    effectiveIdentity: "physical",
                    rootMappings: []
                )
            )
        }
    }
#endif
