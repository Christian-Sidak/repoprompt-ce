import Foundation
import MCP
import os
@testable import RepoPromptApp
import XCTest

#if DEBUG
    /// M15: `get_code_structure` query orchestration is an app-independent value seam. These tests
    /// drive `MCPCodeStructureQueryOrchestrator` through a scripted backend, with no window, tab, or
    /// UI model, and pin request parsing, the backend call sequence, reply parity with direct
    /// assembly, root invalidation, early answers, and the cancellation fences around graph query
    /// and signature demand.
    final class MCPCodeStructureQueryOrchestratorTests: XCTestCase {
        private typealias Fixture = CodeStructureReplyAssemblyFixture
        private typealias Orchestrator = MCPCodeStructureQueryOrchestrator
        private typealias Backend = ScriptedCodeStructureQueryBackend
        private typealias RevalidationMap = [WorkspaceCodemapRootEpoch: WorkspaceCodemapStructureGraphRevalidationResult]

        // MARK: - Request parsing

        func testRequestParsingKeepsDefaultsAndDepthOnlyWithExpand() throws {
            let defaults = try MCPCodeStructureQueryRequest.parse([:])
            XCTAssertEqual(defaults, MCPCodeStructureQueryRequest(
                direction: nil,
                maximumDepth: 0,
                includesSignatures: true,
                size: .medium,
                budget: WorkspaceCodemapGraphPolicy.initial.queryBudget(size: .medium, includesSignatures: true)
            ))
            XCTAssertEqual(try MCPCodeStructureQueryRequest.parse(["depth": 3]).maximumDepth, 0)

            let explicit = try MCPCodeStructureQueryRequest.parse([
                "paths": .array([.string("src/a.swift")]),
                "expand": "used_by",
                "depth": 3,
                "signatures": false,
                "size": "large"
            ])
            XCTAssertEqual(explicit, MCPCodeStructureQueryRequest(
                direction: .referrers,
                maximumDepth: 3,
                includesSignatures: false,
                size: .large,
                budget: WorkspaceCodemapGraphPolicy.initial.queryBudget(size: .large, includesSignatures: false)
            ))
            XCTAssertEqual(try MCPCodeStructureQueryRequest.parse(["expand": "uses"]).direction, .referencedDefinitions)
            XCTAssertEqual(try MCPCodeStructureQueryRequest.parse(["expand": "both"]).direction, .both)
            XCTAssertEqual(MCPCodeStructureQueryRequest.maximumSeedCount, 8192)
        }

        /// The first invalid option in the historical order wins, with its exact message.
        func testRequestParsingRejectsInHistoricalOrderWithContractMessages() {
            let cases: [(args: [String: Value], message: String)] = [
                (["bogus": 1, "expand": 5], "unknown get_code_structure parameter"),
                (["expand": 5, "depth": 9], "expand must be 'uses', 'used_by', or 'both'"),
                (["expand": "sideways"], "expand must be 'uses', 'used_by', or 'both'"),
                (["depth": "2", "signatures": "yes"], "depth must be an integer"),
                (["depth": 0], "depth must be between 1 and 4"),
                (["depth": 5, "size": "huge"], "depth must be between 1 and 4"),
                (["signatures": "yes", "size": "huge"], "signatures must be a boolean"),
                (["size": "huge"], "size must be 'small', 'medium', or 'large'"),
                (["size": 1], "size must be 'small', 'medium', or 'large'")
            ]
            for (args, message) in cases {
                assertInvalidParams(message, "\(args)") { _ = try MCPCodeStructureQueryRequest.parse(args) }
            }
        }

        func testRequestedPathsAcceptOneTo256StringsOnly() throws {
            XCTAssertEqual(
                try MCPCodeStructureQueryRequest.requestedPaths(from: .array([.string("a"), .string("b")])),
                ["a", "b"]
            )
            XCTAssertEqual(
                try MCPCodeStructureQueryRequest.requestedPaths(from: .array(Array(repeating: .string("a"), count: 256))).count,
                256
            )
            let invalid: [Value] = [
                .array([]),
                .array(Array(repeating: .string("a"), count: 257)),
                .array([.string("a"), 1]),
                .string("a")
            ]
            for value in invalid {
                assertInvalidParams("paths must contain one to 256 strings", "\(value)") {
                    _ = try MCPCodeStructureQueryRequest.requestedPaths(from: value)
                }
            }
        }

        // MARK: - Successful parity

        /// The orchestrated reply equals direct assembly of the backend's graph and signatures under
        /// the merged revalidation, seeds are admitted once and ordered by logical path before the
        /// query, only valid roots are demanded, and every phase runs off the main actor even though
        /// the caller is on it.
        @MainActor
        func testSuccessfulQueryMatchesDirectAssemblyAndRunsOffMainActor() async throws {
            let assembly = try Fixture.input()
            let finalPass: RevalidationMap = [
                Fixture.epoch(1): .valid(updatesPending: false),
                Fixture.epoch(2): .valid(updatesPending: false),
                Fixture.epoch(3): .valid(updatesPending: false),
                Fixture.epoch(4): .valid(updatesPending: false)
            ]
            let backend = try Self.backend(revalidations: [assembly.revalidation, finalPass])
            let phases = CodeStructureQueryPhaseRecorder()
            let request = try MCPCodeStructureQueryRequest.parse(["expand": "both", "depth": 2, "size": "small"])

            let outcome = try await Orchestrator(backend: backend, phaseWillBegin: phases.observer())
                .run(Self.input(request: request))

            let expectedSeedOrder = [11, 21, 22, 41, 31].map(Fixture.uuid)
            // Gamma was invalid before demand, so it stays invalid although the final pass is valid.
            let merged: RevalidationMap = [
                Fixture.epoch(1): .valid(updatesPending: false),
                Fixture.epoch(2): .valid(updatesPending: false),
                Fixture.epoch(3): .invalid(code: "graph_revoked", message: "The graph was revoked."),
                Fixture.epoch(4): .valid(updatesPending: false)
            ]
            XCTAssertEqual(outcome.reply, MCPCodeStructureReplyProjection.assemble(.init(
                aggregate: assembly.aggregate,
                presentation: assembly.presentation,
                revalidation: merged,
                includesSignatures: true,
                budget: request.budget,
                size: .small,
                worktreeScope: nil
            )))
            XCTAssertEqual(outcome.reply.roots.first { $0.root == "Gamma" }?.status, .unavailable)
            XCTAssertEqual(backend.calls, [
                .availability(.visibleWorkspace),
                .rootRefs(.visibleWorkspace),
                .logicalRootNames(.visibleWorkspace),
                .query(
                    WorkspaceCodemapGraphStructureQuery(
                        seedFileIDs: expectedSeedOrder,
                        direction: .both,
                        maximumDepth: 2,
                        budget: request.budget
                    ),
                    names: Self.rootNames
                ),
                .revalidate,
                .signatures(
                    fileIDs: [22, 11, 13, 12, 41, 42].map(Fixture.uuid),
                    maximumCandidateDemandCount: request.budget.maximumNodeCount
                ),
                .revalidate
            ])
            XCTAssertEqual(outcome.seedOrder?.orderedFileIDs, expectedSeedOrder)
            XCTAssertEqual(outcome.seedOrder?.keys.map(\.logicalPath).sorted(), [
                "Alpha/a1.swift", "Beta/b1.swift", "Beta/b2.swift", "Delta/d1.swift", "Gamma/c1.swift"
            ])
            XCTAssertTrue(outcome.signatureDemandInvoked)
            XCTAssertEqual(phases.phases, [.seedOrdering, .graphQuery, .signatureDemand, .replyAssembly])
            XCTAssertFalse(phases.events.contains(where: \.ranOnMainThread), "\(phases.events)")
        }

        // MARK: - Root invalidation

        /// A root that goes stale while signatures are demanded is reported unavailable, and its
        /// signatures are not rendered.
        func testRootInvalidatedDuringSignatureDemandIsReportedUnavailable() async throws {
            let assembly = try Fixture.input()
            let allValid: RevalidationMap = [
                Fixture.epoch(1): .valid(updatesPending: false),
                Fixture.epoch(2): .valid(updatesPending: false),
                Fixture.epoch(3): .valid(updatesPending: false),
                Fixture.epoch(4): .valid(updatesPending: false)
            ]
            var alphaInvalidated = allValid
            alphaInvalidated[Fixture.epoch(1)] = .invalid(code: "graph_revoked", message: "The graph was revoked.")
            let backend = try Self.backend(revalidations: [allValid, alphaInvalidated])
            let request = try MCPCodeStructureQueryRequest.parse(["size": "large"])

            let outcome = try await Orchestrator(backend: backend).run(Self.input(request: request))

            XCTAssertEqual(backend.calls.compactMap(\.demandedFileIDs), [[22, 11, 13, 12, 31, 41, 42].map(Fixture.uuid)])
            XCTAssertEqual(outcome.reply, MCPCodeStructureReplyProjection.assemble(.init(
                aggregate: assembly.aggregate,
                presentation: assembly.presentation,
                revalidation: alphaInvalidated,
                includesSignatures: true,
                budget: request.budget,
                size: .large,
                worktreeScope: nil
            )))
            let alpha = try XCTUnwrap(outcome.reply.roots.first { $0.root == "Alpha" })
            XCTAssertEqual(alpha.status, .unavailable)
            XCTAssertEqual(alpha.issues.map(\.code), ["graph_revoked"])
            XCTAssertFalse(outcome.reply.files.contains { $0.path.hasPrefix("a") }, "\(outcome.reply.files.map(\.path))")
        }

        /// When every root is stale before demand, nothing is demanded and no signatures are rendered.
        func testNoSignatureDemandWhenEveryRootIsInvalidBeforeDemand() async throws {
            let assembly = try Fixture.input()
            let allInvalid = Dictionary(uniqueKeysWithValues: (1 ... 4).map {
                (Fixture.epoch($0), WorkspaceCodemapStructureGraphRevalidationResult.invalid(
                    code: "graph_revoked",
                    message: "The graph was revoked."
                ))
            })
            let backend = try Self.backend(revalidations: [allInvalid, [:]])
            let phases = CodeStructureQueryPhaseRecorder()
            let request = try MCPCodeStructureQueryRequest.parse([:])

            let outcome = try await Orchestrator(backend: backend, phaseWillBegin: phases.observer())
                .run(Self.input(request: request))

            XCTAssertFalse(outcome.signatureDemandInvoked)
            XCTAssertEqual(backend.calls.compactMap(\.demandedFileIDs), [])
            XCTAssertEqual(backend.calls.count(where: { $0 == .revalidate }), 2)
            XCTAssertEqual(phases.phases, [.seedOrdering, .graphQuery, .replyAssembly])
            XCTAssertEqual(outcome.reply, MCPCodeStructureReplyProjection.assemble(.init(
                aggregate: assembly.aggregate,
                presentation: nil,
                revalidation: allInvalid,
                includesSignatures: true,
                budget: request.budget,
                size: .medium,
                worktreeScope: nil
            )))
            XCTAssertEqual(outcome.reply.files, [])
        }

        // MARK: - Early answers

        func testDisabledCodeMapsAnswerWithoutTouchingTheBackend() async throws {
            let backend = try Self.backend()
            let outcome = try await Orchestrator(backend: backend).run(Self.input(
                request: MCPCodeStructureQueryRequest.parse(["size": "small"]),
                codeMapsGloballyDisabled: true
            ))

            XCTAssertEqual(outcome.reply, Self.unavailable(
                code: "codemaps_disabled",
                phase: "graph_snapshot",
                message: "Codemap generation is disabled.",
                size: .small
            ))
            XCTAssertNil(outcome.seedOrder)
            XCTAssertEqual(backend.calls, [])
        }

        func testUnavailableSessionWorktreeAnswersBeforeRootResolution() async throws {
            let backend = try Self.backend(availability: .sessionWorktreeUnavailable(missingPhysicalRootPaths: ["/gone"]))
            let outcome = try await Orchestrator(backend: backend).run(Self.input(request: .parse([:])))

            XCTAssertEqual(outcome.reply, Self.unavailable(
                code: "git_root_unavailable",
                phase: "seed_resolution",
                message: "The session-bound worktree root is unavailable.",
                size: .medium
            ))
            XCTAssertEqual(backend.calls, [.availability(.visibleWorkspace)])
        }

        /// Seeds outside the lookup scope are not admitted; with none left the first requested path
        /// is reported, and without the path issue the query proceeds with no seeds.
        func testOutOfScopeSeedsAnswerPathNotFoundOrQueryEmpty() async throws {
            let outside = WorkspaceRootRef(id: Fixture.uuid(999), name: "Outside", fullPath: "/repo/outside")
            let seeds = [Self.record(91, outside, "x.swift")]

            let refused = try Self.backend()
            let refusedOutcome = try await Orchestrator(backend: refused).run(Self.input(
                request: .parse([:]),
                seeds: seeds,
                requestedPaths: ["Outside/x.swift", "Outside/y.swift"]
            ))
            XCTAssertEqual(refusedOutcome.reply, Self.unavailable(
                code: "path_not_found",
                phase: "seed_resolution",
                path: "Outside/x.swift",
                message: "No requested path resolved to a file.",
                size: .medium
            ))
            XCTAssertEqual(refused.calls, [.availability(.visibleWorkspace), .rootRefs(.visibleWorkspace)])

            let queried = try Self.backend(revalidations: [[:], [:]])
            let queriedOutcome = try await Orchestrator(backend: queried).run(Self.input(
                request: .parse(["signatures": false]),
                seeds: seeds,
                includePathNotFoundIssue: false
            ))
            XCTAssertEqual(queriedOutcome.seedOrder, .init(keys: [], orderedFileIDs: []))
            XCTAssertEqual(queried.calls.compactMap(\.querySeedFileIDs), [[]])
        }

        // MARK: - Cancellation

        /// A backend that finishes its graph query normally after the caller was cancelled still
        /// cannot advance the query: revalidation, demand, and assembly never run.
        func testCancellationDuringGraphQueryStopsBeforeRevalidation() async throws {
            let backend = try Self.backend(suspension: .graphQuery)
            let phases = CodeStructureQueryPhaseRecorder()
            let orchestrator = Orchestrator(backend: backend, phaseWillBegin: phases.observer())
            let input = try Self.input(request: .parse([:]))

            let task = Task { try await orchestrator.run(input) }
            await backend.waitUntilSuspended()
            task.cancel()
            let result = await task.result

            XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
            XCTAssertEqual(backend.calls.count, 4)
            XCTAssertNotNil(backend.calls.last?.querySeedFileIDs)
            XCTAssertEqual(phases.phases, [.seedOrdering, .graphQuery])
        }

        /// Cancellation while signatures are demanded ends the query before the final revalidation
        /// and assembly, whether the demand returns normally or throws its own cancellation.
        func testCancellationDuringSignatureDemandStopsBeforeFinalRevalidationAndAssembly() async throws {
            for throwsWhenCancelled in [false, true] {
                let backend = try Self.backend(
                    revalidations: [[:], [:]],
                    suspension: .signatureDemand,
                    throwsWhenCancelled: throwsWhenCancelled
                )
                let phases = CodeStructureQueryPhaseRecorder()
                let orchestrator = Orchestrator(backend: backend, phaseWillBegin: phases.observer())
                let input = try Self.input(request: .parse([:]))

                let task = Task { try await orchestrator.run(input) }
                await backend.waitUntilSuspended()
                task.cancel()
                let result = await task.result

                let label = "throwsWhenCancelled: \(throwsWhenCancelled)"
                XCTAssertThrowsError(try result.get(), label) { XCTAssertTrue($0 is CancellationError, "\(label): \($0)") }
                XCTAssertNotNil(backend.calls.last?.demandedFileIDs, label)
                XCTAssertEqual(backend.calls.count(where: { $0 == .revalidate }), 1, label)
                XCTAssertEqual(phases.phases, [.seedOrdering, .graphQuery, .signatureDemand], label)
            }
        }

        // MARK: - Helpers

        private static let rootNames: [UUID: String] = [
            Fixture.epoch(1).rootID: "Alpha",
            Fixture.epoch(2).rootID: "Beta",
            Fixture.epoch(3).rootID: "Gamma",
            Fixture.epoch(4).rootID: "Delta"
        ]

        private static var roots: [WorkspaceRootRef] {
            (1 ... 4).map { index in
                let name = rootNames[Fixture.epoch(index).rootID] ?? ""
                return WorkspaceRootRef(id: Fixture.epoch(index).rootID, name: name, fullPath: "/repo/\(name.lowercased())")
            }
        }

        /// Seeds out of logical order, with a second record for `a1.swift`'s path (not admitted) and
        /// a record under a root outside the lookup scope (not admitted).
        private static var seeds: [WorkspaceFileRecord] {
            let roots = Self.roots
            return [
                record(31, roots[2], "c1.swift"),
                record(22, roots[1], "b2.swift"),
                record(11, roots[0], "a1.swift"),
                record(111, roots[0], "a1.swift"),
                record(41, roots[3], "d1.swift"),
                record(91, WorkspaceRootRef(id: Fixture.uuid(999), name: "Outside", fullPath: "/repo/outside"), "x.swift"),
                record(21, roots[1], "b1.swift")
            ]
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

        private static func input(
            request: MCPCodeStructureQueryRequest,
            seeds: [WorkspaceFileRecord]? = nil,
            requestedPaths: [String] = [],
            includePathNotFoundIssue: Bool = true,
            codeMapsGloballyDisabled: Bool = false
        ) -> MCPCodeStructureQueryInput {
            MCPCodeStructureQueryInput(
                request: request,
                seeds: seeds ?? Self.seeds,
                requestedPaths: requestedPaths,
                includePathNotFoundIssue: includePathNotFoundIssue,
                lookupContext: .visibleWorkspace,
                codeMapsGloballyDisabled: codeMapsGloballyDisabled
            )
        }

        private static func backend(
            availability: WorkspaceLookupRootScopeAvailability = .available,
            revalidations: [RevalidationMap] = [],
            suspension: Backend.Suspension? = nil,
            throwsWhenCancelled: Bool = false
        ) throws -> Backend {
            let assembly = try Fixture.input()
            let presentation = try XCTUnwrap(assembly.presentation)
            return Backend(
                availability: availability,
                roots: roots,
                logicalRootNames: rootNames,
                aggregate: assembly.aggregate,
                presentation: presentation,
                revalidations: revalidations,
                suspension: suspension,
                throwsWhenCancelled: throwsWhenCancelled
            )
        }

        private static func unavailable(
            code: String,
            phase: String,
            path: String? = nil,
            message: String,
            size: WorkspaceCodemapGraphOutputSize
        ) -> ToolResultDTOs.CodeStructureReplyDTO {
            ToolResultDTOs.CodeStructureReplyDTO(
                status: .unavailable,
                size: size,
                roots: [],
                files: [],
                summary: .init(seeds: 0, nodes: 0, edges: 0, files: 0, tokens: 0),
                issues: [.init(
                    code: code,
                    phase: phase,
                    path: path,
                    retryable: false,
                    retryAfterMilliseconds: nil,
                    attempted: nil,
                    limit: nil,
                    message: message
                )],
                retry: nil,
                worktreeScope: nil
            )
        }

        private func assertInvalidParams(
            _ message: String,
            _ label: String,
            file: StaticString = #filePath,
            line: UInt = #line,
            _ body: () throws -> Void
        ) {
            XCTAssertThrowsError(try body(), label, file: file, line: line) { error in
                guard case let MCPError.invalidParams(detail) = error else {
                    return XCTFail("\(label): expected invalidParams, got \(error)", file: file, line: line)
                }
                XCTAssertEqual(detail, message, label, file: file, line: line)
            }
        }
    }

    /// Lock-protected record of orchestration phases and whether each began on the main thread.
    /// The observer is synchronous, so it runs on the orchestrating executor.
    final class CodeStructureQueryPhaseRecorder: Sendable {
        struct Event: Equatable {
            let phase: MCPCodeStructureQueryOrchestrator.Phase
            let ranOnMainThread: Bool
        }

        private let storage = OSAllocatedUnfairLock(initialState: [Event]())

        var events: [Event] {
            storage.withLock { $0 }
        }

        var phases: [MCPCodeStructureQueryOrchestrator.Phase] {
            events.map(\.phase)
        }

        /// Records each phase, then runs `then` (for example to cancel or to change authority).
        func observer(
            then: (@Sendable (MCPCodeStructureQueryOrchestrator.Phase) -> Void)? = nil
        ) -> @Sendable (MCPCodeStructureQueryOrchestrator.Phase) -> Void {
            { [storage] phase in
                storage.withLock { $0.append(Event(phase: phase, ranOnMainThread: Thread.isMainThread)) }
                then?(phase)
            }
        }
    }

    /// A scripted `MCPCodeStructureQueryBackend`: canned answers, a call log, and an optional
    /// suspension in the graph query or signature demand that lasts until the calling task is
    /// cancelled. After cancellation it returns its canned answer normally, like a store that does
    /// not itself observe cancellation, unless `throwsWhenCancelled` is set.
    final class ScriptedCodeStructureQueryBackend: MCPCodeStructureQueryBackend {
        enum Suspension {
            case graphQuery
            case signatureDemand
        }

        enum Call: Equatable {
            case availability(WorkspaceLookupRootScope)
            case rootRefs(WorkspaceLookupRootScope)
            case logicalRootNames(WorkspaceLookupRootScope)
            case query(WorkspaceCodemapGraphStructureQuery, names: [UUID: String])
            case revalidate
            case signatures(fileIDs: [UUID], maximumCandidateDemandCount: Int)

            var querySeedFileIDs: [UUID]? {
                if case let .query(query, _) = self { return query.seedFileIDs }
                return nil
            }

            var demandedFileIDs: [UUID]? {
                if case let .signatures(fileIDs, _) = self { return fileIDs }
                return nil
            }
        }

        private struct State {
            var calls: [Call] = []
            var revalidations: [[WorkspaceCodemapRootEpoch: WorkspaceCodemapStructureGraphRevalidationResult]]
        }

        private let availability: WorkspaceLookupRootScopeAvailability
        private let roots: [WorkspaceRootRef]
        private let logicalRootNames: [UUID: String]
        private let aggregate: WorkspaceCodemapStructureAggregateResult
        private let presentation: WorkspaceCodemapOperationPresentation
        private let suspension: Suspension?
        private let throwsWhenCancelled: Bool
        private let state: OSAllocatedUnfairLock<State>
        private let suspended: AsyncStream<Void>
        private let suspendedContinuation: AsyncStream<Void>.Continuation

        init(
            availability: WorkspaceLookupRootScopeAvailability,
            roots: [WorkspaceRootRef],
            logicalRootNames: [UUID: String],
            aggregate: WorkspaceCodemapStructureAggregateResult,
            presentation: WorkspaceCodemapOperationPresentation,
            revalidations: [[WorkspaceCodemapRootEpoch: WorkspaceCodemapStructureGraphRevalidationResult]],
            suspension: Suspension?,
            throwsWhenCancelled: Bool
        ) {
            self.availability = availability
            self.roots = roots
            self.logicalRootNames = logicalRootNames
            self.aggregate = aggregate
            self.presentation = presentation
            self.suspension = suspension
            self.throwsWhenCancelled = throwsWhenCancelled
            state = OSAllocatedUnfairLock(initialState: State(revalidations: revalidations))
            (suspended, suspendedContinuation) = AsyncStream.makeStream(of: Void.self)
        }

        var calls: [Call] {
            state.withLock { $0.calls }
        }

        /// Returns once the scripted suspension has been entered. Call at most once.
        func waitUntilSuspended() async {
            var iterator = suspended.makeAsyncIterator()
            _ = await iterator.next()
        }

        func rootScopeAvailability(_ rootScope: WorkspaceLookupRootScope) async -> WorkspaceLookupRootScopeAvailability {
            record(.availability(rootScope))
            return availability
        }

        func rootRefs(scope rootScope: WorkspaceLookupRootScope) async -> [WorkspaceRootRef] {
            record(.rootRefs(rootScope))
            return roots
        }

        func logicalRootDisplayNamesByRootID(for lookupContext: WorkspaceLookupContext) async -> [UUID: String] {
            record(.logicalRootNames(lookupContext.rootScope))
            return logicalRootNames
        }

        func queryStructureGraphs(
            _ query: WorkspaceCodemapGraphStructureQuery,
            rootScope _: WorkspaceLookupRootScope,
            logicalRootDisplayNamesByRootID: [UUID: String]
        ) async throws -> WorkspaceCodemapStructureAggregateResult {
            record(.query(query, names: logicalRootDisplayNamesByRootID))
            try await suspendIfScripted(.graphQuery)
            return aggregate
        }

        func revalidateStructureGraphs(
            _: WorkspaceCodemapStructureAggregateResult
        ) async -> [WorkspaceCodemapRootEpoch: WorkspaceCodemapStructureGraphRevalidationResult] {
            state.withLock { state in
                state.calls.append(.revalidate)
                return state.revalidations.isEmpty ? [:] : state.revalidations.removeFirst()
            }
        }

        func structureSignaturePresentation(
            fileIDs: [UUID],
            maximumCandidateDemandCount: Int,
            rootScope _: WorkspaceLookupRootScope,
            logicalRootDisplayNamesByRootID _: [UUID: String]
        ) async throws -> WorkspaceCodemapOperationPresentation {
            record(.signatures(fileIDs: fileIDs, maximumCandidateDemandCount: maximumCandidateDemandCount))
            try await suspendIfScripted(.signatureDemand)
            return presentation
        }

        private func record(_ call: Call) {
            state.withLock { $0.calls.append(call) }
        }

        private func suspendIfScripted(_ point: Suspension) async throws {
            guard suspension == point else { return }
            suspendedContinuation.yield()
            // Ends as soon as the calling task is cancelled.
            try? await Task.sleep(for: .seconds(300))
            if throwsWhenCancelled {
                try Task.checkCancellation()
            }
        }
    }
#endif
