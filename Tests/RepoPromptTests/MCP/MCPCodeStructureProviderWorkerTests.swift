import Foundation
import MCP
import os
@testable import RepoPromptApp
import XCTest

#if DEBUG
    /// M10/M15: the real app `get_code_structure` path runs its whole query — seed ordering from keys
    /// projected once per seed, graph query, signature demand, and reply assembly — off the main
    /// actor in `MCPCodeStructureQueryOrchestrator`, stops at cancellation, encodes on the projection
    /// worker, and never releases a reply whose workspace authority changed while any phase was in
    /// flight. Over a settled index, the headless query core returns exactly the app's reply.
    @MainActor
    final class MCPCodeStructureProviderWorkerTests: XCTestCase {
        /// Supplied out of order; UTF-8 order is `Z` (0x5A) < `_` (0x5F) < `a` < `b`.
        private static let seedPaths = ["src/b.swift", "src/_m.swift", "src/a.swift", "src/Z.swift"]
        private static let orderedSeedPaths = ["src/Z.swift", "src/_m.swift", "src/a.swift", "src/b.swift"]
        /// Cross-referencing sources, so a settled graph has edges and related files.
        private static let sources = [
            "src/Z.swift": "struct Zed {\n    let alpha: Alpha\n}\n",
            "src/_m.swift": "struct Middle {\n    func run() -> Beta { Beta() }\n}\n",
            "src/a.swift": "struct Alpha {\n    let value = 1\n}\n",
            "src/b.swift": "struct Beta {\n    let alpha = Alpha()\n}\n"
        ]
        private static let graphArguments: [String: Value] = [
            "paths": .array([.string("src/b.swift")]),
            "expand": "both",
            "depth": 2,
            "signatures": true
        ]

        func testQueryRunsOffMainActorWithSeedsOrderedFromKeysProjectedOncePerSeed() async throws {
            let fixture = try await makeFixture()
            let server = fixture.window.window.mcpServer
            server.resetCodeStructureAdmissionWorkCountsForTesting()
            server.resetLastCodeStructureRequestForTesting()
            let phases = CodeStructureQueryPhaseRecorder()
            server.codeStructureQueryPhaseObserverForTesting = phases.observer()
            defer { server.codeStructureQueryPhaseObserverForTesting = nil }
            let recorder = ProjectionExecutionRecorder()
            MCPProviderProjectionWorker.executionObserverForTesting = recorder.observer
            defer { MCPProviderProjectionWorker.executionObserverForTesting = nil }

            let reply = try await fixture.codeStructure(paths: Self.seedPaths)

            XCTAssertFalse(reply.issues.contains { $0.phase == "workspace_authority" }, "\(reply.issues)")
            let captured = try XCTUnwrap(server.capturedCodeStructureSeedOrderForTesting())
            let pathByFileID = Dictionary(uniqueKeysWithValues: captured.keys.map { ($0.fileID, $0.logicalPath) })
            XCTAssertEqual(captured.orderedFileIDs.compactMap { pathByFileID[$0] }, Self.orderedSeedPaths)
            XCTAssertEqual(captured.orderedFileIDs.count, captured.keys.count)
            XCTAssertEqual(server.codeStructureAdmissionWorkCountsForTesting().logicalPathComputations, Self.seedPaths.count)
            XCTAssertEqual(phases.phases, [.seedOrdering, .graphQuery, .replyAssembly])
            XCTAssertFalse(phases.events.contains(where: \.ranOnMainThread), "\(phases.events)")
            let events = recorder.events.filter { $0.toolName == MCPWindowToolName.getCodeStructure }
            XCTAssertEqual(events.map(\.phase), ["value_encoding"])
            XCTAssertFalse(events.contains(where: \.ranOnMainThread), "\(events)")
        }

        func testCancellationDuringSeedOrderingStopsBeforeGraphQuery() async throws {
            try await assertCancellation(duringPhase: .seedOrdering, expectedPhases: [.seedOrdering])
        }

        func testCancellationDuringGraphQueryStopsBeforeSignatureDemand() async throws {
            try await assertCancellation(duringPhase: .graphQuery, expectedPhases: [.seedOrdering, .graphQuery])
        }

        func testAuthoritySupersededDuringSeedOrderingFailsClosed() async throws {
            try await assertAuthoritySuperseded(duringQueryPhase: .seedOrdering)
        }

        func testAuthoritySupersededDuringGraphQueryFailsClosed() async throws {
            try await assertAuthoritySuperseded(duringQueryPhase: .graphQuery)
        }

        func testAuthoritySupersededDuringReplyAssemblyFailsClosed() async throws {
            try await assertAuthoritySuperseded(duringQueryPhase: .replyAssembly)
        }

        /// The M9 race: authority validated before encoding must be revalidated after the worker
        /// hop, or a reply built under superseded authority is released.
        func testAuthoritySupersededDuringValueEncodingFailsClosed() async throws {
            let fixture = try await makeFixture()
            let workspaceManager = fixture.window.window.workspaceManager
            let injections = OSAllocatedUnfairLock(initialState: 0)
            MCPProviderProjectionWorker.executionObserverForTesting = { event in
                guard event.toolName == MCPWindowToolName.getCodeStructure, event.phase == "value_encoding" else { return }
                Self.supersedeAuthority(workspaceManager)
                injections.withLock { $0 += 1 }
            }
            defer { MCPProviderProjectionWorker.executionObserverForTesting = nil }

            let reply = try await fixture.codeStructure(paths: Self.seedPaths)

            XCTAssertEqual(injections.withLock { $0 }, 1, "authority change was not injected")
            Self.assertAuthorityFailure(reply)
        }

        /// Signature demand runs only for a settled graph with renderable nodes.
        func testAuthoritySupersededDuringSignatureDemandFailsClosed() async throws {
            let fixture = try await makeFixture()
            _ = try await settledReply(fixture, arguments: Self.graphArguments)
            try await assertAuthoritySuperseded(
                duringQueryPhase: .signatureDemand,
                fixture: fixture,
                arguments: Self.graphArguments
            )
        }

        /// M15 parity: over a settled index, the query core run headlessly — the store actor and a
        /// value request only, no window, provider, or `MCPServerViewModel` — returns exactly the
        /// reply the full app provider path returns for the same arguments, including graph
        /// expansion and signatures.
        ///
        /// App code-map readiness is not monotonic right after activation (M8T): a graph update can
        /// still be in flight after the first settled answer, and a sample taken during it reports
        /// `updates_pending`. The core is therefore compared only when app replies sampled
        /// immediately before and after it are equal, and an iteration whose core sample disagrees
        /// is retried within a bound. A systematic divergence fails every iteration.
        func testHeadlessQueryCoreMatchesAppProviderReplyOnSettledIndex() async throws {
            let fixture = try await makeFixture()
            let settled = try await settledReply(fixture, arguments: Self.graphArguments)
            XCTAssertEqual(settled.status, .ok, "\(settled.issues)")

            var lastMismatch = "the app reply never stayed stable across a core query"
            for _ in 0 ..< 10 {
                let before = try await fixture.call(Self.graphArguments)
                let core = try await headlessCoreReply(fixture, arguments: Self.graphArguments, paths: ["src/b.swift"])
                let after = try await fixture.call(Self.graphArguments)
                guard before == after else { continue }
                guard core == after else {
                    lastMismatch = "core \(core.status) \(core.roots.map(\.updatesPending)) \(core.issues.map(\.code)) "
                        + "vs app \(after.status) \(after.roots.map(\.updatesPending)) \(after.issues.map(\.code))"
                    try await Task.sleep(for: .milliseconds(200))
                    continue
                }
                XCTAssertEqual(core.status, .ok, "\(core.issues)")
                // Graph paths carry the root label; the formatter strips it for display.
                let seeds = core.files.filter { $0.role == "seed" }
                XCTAssertEqual(seeds.map(\.path), ["root/src/b.swift"], "\(core.files.map { "\($0.role) \($0.path)" })")
                XCTAssertFalse(seeds.contains { $0.content.isEmpty })
                XCTAssertFalse(core.roots.flatMap(\.edges).isEmpty, "\(core.roots)")
                XCTAssertNil(core.worktreeScope)
                return
            }
            XCTFail("no app/core agreement over a stable app reply: \(lastMismatch)")
        }

        // MARK: - Helpers

        private func assertCancellation(
            duringPhase target: MCPCodeStructureQueryOrchestrator.Phase,
            expectedPhases: [MCPCodeStructureQueryOrchestrator.Phase],
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws {
            let fixture = try await makeFixture()
            let server = fixture.window.window.mcpServer
            let store = fixture.window.window.promptManager.workspaceFileContextStore
            _ = await store.awaitAppliedIngress(rootScope: .visibleWorkspace)
            let records = await Array(store.lookupFiles(atPaths: Self.seedPaths).values)
            XCTAssertEqual(records.count, Self.seedPaths.count, file: file, line: line)
            server.resetLastCodeStructureRequestForTesting()
            let request = try MCPCodeStructureQueryRequest.parse(["signatures": true])
            let build = OSAllocatedUnfairLock<Task<ToolResultDTOs.CodeStructureReplyDTO, Error>?>(initialState: nil)
            let phases = CodeStructureQueryPhaseRecorder()
            server.codeStructureQueryPhaseObserverForTesting = phases.observer { phase in
                if phase == target { build.withLock { $0 }?.cancel() }
            }
            defer { server.codeStructureQueryPhaseObserverForTesting = nil }

            // The task cannot start before this test suspends, so the handle is published first.
            let task = Task { @MainActor in
                try await server.buildCodeStructureDTO(
                    fromRecords: records,
                    request: request,
                    includePathNotFoundIssue: true
                )
            }
            build.withLock { $0 = task }
            let result = await task.result

            XCTAssertThrowsError(try result.get(), file: file, line: line) { error in
                XCTAssertTrue(error is CancellationError, "\(error)", file: file, line: line)
            }
            XCTAssertEqual(phases.phases, expectedPhases, file: file, line: line)
            XCTAssertNil(server.capturedCodeStructureSeedOrderForTesting(), file: file, line: line)
        }

        /// Supersedes the window's root catalog as `phase` begins in the off-main query core. The
        /// provider's main-actor task is suspended awaiting the core, so the synchronous main-queue
        /// hop lands the change deterministically before the phase runs.
        private func assertAuthoritySuperseded(
            duringQueryPhase phase: MCPCodeStructureQueryOrchestrator.Phase,
            fixture existing: Fixture? = nil,
            arguments: [String: Value]? = nil,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws {
            let fixture: Fixture = if let existing {
                existing
            } else {
                try await makeFixture()
            }
            let server = fixture.window.window.mcpServer
            let workspaceManager = fixture.window.window.workspaceManager
            let injections = OSAllocatedUnfairLock(initialState: 0)
            let phases = CodeStructureQueryPhaseRecorder()
            server.codeStructureQueryPhaseObserverForTesting = phases.observer { observed in
                guard observed == phase else { return }
                Self.supersedeAuthority(workspaceManager)
                injections.withLock { $0 += 1 }
            }
            defer { server.codeStructureQueryPhaseObserverForTesting = nil }

            let reply: ToolResultDTOs.CodeStructureReplyDTO = if let arguments {
                try await fixture.call(arguments)
            } else {
                try await fixture.codeStructure(paths: Self.seedPaths)
            }

            XCTAssertEqual(injections.withLock { $0 }, 1, "authority change was not injected", file: file, line: line)
            XCTAssertFalse(phases.events.contains(where: \.ranOnMainThread), "\(phases.events)", file: file, line: line)
            Self.assertAuthorityFailure(reply, file: file, line: line)
        }

        private static func assertAuthorityFailure(
            _ reply: ToolResultDTOs.CodeStructureReplyDTO,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            XCTAssertEqual(reply.status, .unavailable, file: file, line: line)
            XCTAssertEqual(reply.issues.map(\.code), ["workspace_authority_superseded"], file: file, line: line)
            XCTAssertEqual(reply.issues.map(\.phase), ["workspace_authority"], file: file, line: line)
            XCTAssertEqual(reply.issues.map(\.retryable), [true], file: file, line: line)
            XCTAssertEqual(reply.roots, [], file: file, line: line)
            XCTAssertEqual(reply.files, [], file: file, line: line)
        }

        /// Republishes the root catalog synchronously on the main actor. Called from off the main
        /// actor; if a regression ran the caller on the main thread, it applies directly rather than
        /// deadlocking, and the phase recorder reports the isolation failure.
        private nonisolated static func supersedeAuthority(_ workspaceManager: WorkspaceManagerViewModel) {
            if Thread.isMainThread {
                MainActor.assumeIsolated { workspaceManager.republishReadyRootCatalogWithNextGenerationForTesting() }
            } else {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated { workspaceManager.republishReadyRootCatalogWithNextGenerationForTesting() }
                }
            }
        }

        /// Calls the app tool until it answers `ok` with the seed's signature rendered.
        private func settledReply(
            _ fixture: Fixture,
            arguments: [String: Value],
            timeout: Duration = .seconds(60)
        ) async throws -> ToolResultDTOs.CodeStructureReplyDTO {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            var last: ToolResultDTOs.CodeStructureReplyDTO?
            while clock.now < deadline {
                let reply = try await fixture.call(arguments)
                last = reply
                if reply.status == .ok, reply.files.contains(where: { $0.role == "seed" && !$0.content.isEmpty }) {
                    return reply
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTFail("code structure did not settle: \(String(describing: last?.status)) \(last?.issues ?? [])")
            throw CancellationError()
        }

        /// Runs the query core with only the window's store actor and a value request, preceded by the
        /// same ingress wait and explicit-path seeding the app adapter performs.
        private func headlessCoreReply(
            _ fixture: Fixture,
            arguments: [String: Value],
            paths: [String]
        ) async throws -> ToolResultDTOs.CodeStructureReplyDTO {
            let store = fixture.window.window.promptManager.workspaceFileContextStore
            let request = try MCPCodeStructureQueryRequest.parse(arguments)
            let codeMapsGloballyDisabled = fixture.window.window.promptManager.codeMapsGloballyDisabled
            _ = await store.awaitAppliedIngress(rootScope: .visibleWorkspace)
            let records = await store.lookupFiles(atPaths: paths, profile: .mcpRead, rootScope: .visibleWorkspace)
            let orchestrator = MCPCodeStructureQueryOrchestrator(
                backend: WorkspaceStoreCodeStructureQueryBackend(store: store)
            )
            return try await orchestrator.run(MCPCodeStructureQueryInput(
                request: request,
                seeds: paths.compactMap { records[$0] },
                requestedPaths: paths,
                includePathNotFoundIssue: true,
                lookupContext: .visibleWorkspace,
                codeMapsGloballyDisabled: codeMapsGloballyDisabled
            )).reply
        }

        private struct Fixture {
            let window: InProcessMCPWindowServerFixture.RegisteredWindow
            let codemapRuntime: CodemapStoreFixture
            let tool: RepoPromptApp.Tool

            func codeStructure(paths: [String]) async throws -> ToolResultDTOs.CodeStructureReplyDTO {
                try await call([
                    "paths": .array(paths.map { .string($0) }),
                    "signatures": .bool(false)
                ])
            }

            func call(_ arguments: [String: Value]) async throws -> ToolResultDTOs.CodeStructureReplyDTO {
                let value = try await tool(arguments)
                return try XCTUnwrap(value.decode(ToolResultDTOs.CodeStructureReplyDTO.self))
            }

            func close() async {
                await InProcessMCPWindowServerFixture.close(window)
                await codemapRuntime.shutdown()
            }
        }

        /// A registered window over a non-Git root holding `sources`, with non-Git Code Maps pinned on
        /// and an isolated code-map runtime so no process-wide artifact state is read or written.
        private func makeFixture() async throws -> Fixture {
            let root = try makeRoot()
            let codemapRuntime = try CodemapStoreFixture(name: "mcp-code-structure-worker")
            let store = WorkspaceFileContextStore(
                enableCatalogShardShadowValidation: false,
                codemapRuntimeProvider: { try codemapRuntime.runtime() },
                nonGitCodeMapsEnabled: true
            )
            let window: InProcessMCPWindowServerFixture.RegisteredWindow
            do {
                window = try await InProcessMCPWindowServerFixture.makeRegisteredWindow(
                    root: root,
                    workspaceFileContextStore: store
                )
            } catch {
                await codemapRuntime.shutdown()
                throw error
            }
            let fixture: Fixture
            do {
                fixture = try await Fixture(
                    window: window,
                    codemapRuntime: codemapRuntime,
                    tool: InProcessMCPWindowServerFixture.tool(
                        named: MCPWindowToolName.getCodeStructure,
                        from: window.window.mcpServer
                    )
                )
            } catch {
                await InProcessMCPWindowServerFixture.close(window)
                await codemapRuntime.shutdown()
                throw error
            }
            addTeardownBlock { @MainActor in await fixture.close() }
            return fixture
        }

        private func makeRoot() throws -> URL {
            let temporary = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
            defer { free(temporary) }
            let parent = URL(fileURLWithPath: String(cString: temporary), isDirectory: true)
                .appendingPathComponent("mcp-code-structure-worker-\(UUID().uuidString)", isDirectory: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
            let root = parent.appendingPathComponent("root", isDirectory: true)
            for path in Self.seedPaths {
                let file = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(XCTUnwrap(Self.sources[path]).utf8).write(to: file)
            }
            return root
        }
    }
#endif
