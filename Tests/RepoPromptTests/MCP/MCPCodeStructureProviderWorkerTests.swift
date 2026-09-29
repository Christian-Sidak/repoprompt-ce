import Foundation
import MCP
import os
@testable import RepoPromptApp
import XCTest

#if DEBUG
    /// M10: the real app `get_code_structure` path orders seeds on the projection worker from keys
    /// projected once per seed on the main actor, stops at cancellation after that hop, and never
    /// releases a reply whose workspace authority changed while any projection-worker phase was in
    /// flight.
    @MainActor
    final class MCPCodeStructureProviderWorkerTests: XCTestCase {
        /// Supplied out of order; UTF-8 order is `Z` (0x5A) < `_` (0x5F) < `a` < `b`.
        private static let seedPaths = ["src/b.swift", "src/_m.swift", "src/a.swift", "src/Z.swift"]
        private static let orderedSeedPaths = ["src/Z.swift", "src/_m.swift", "src/a.swift", "src/b.swift"]

        func testSeedsAreOrderedOnProjectionWorkerFromKeysProjectedOncePerSeed() async throws {
            let fixture = try await makeFixture()
            let server = fixture.window.window.mcpServer
            server.resetCodeStructureAdmissionWorkCountsForTesting()
            server.resetLastCodeStructureRequestForTesting()
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
            let events = recorder.events.filter { $0.toolName == MCPWindowToolName.getCodeStructure }
            XCTAssertEqual(events.map(\.phase), ["seed_ordering", "reply_assembly", "value_encoding"])
            XCTAssertFalse(events.contains(where: \.ranOnMainThread), "\(events)")
        }

        func testCancellationDuringSeedOrderingStopsBeforeGraphQuery() async throws {
            let fixture = try await makeFixture()
            let server = fixture.window.window.mcpServer
            let store = fixture.window.window.promptManager.workspaceFileContextStore
            _ = await store.awaitAppliedIngress(rootScope: .visibleWorkspace)
            let records = await Array(store.lookupFiles(atPaths: Self.seedPaths).values)
            XCTAssertEqual(records.count, Self.seedPaths.count)
            server.resetLastCodeStructureRequestForTesting()
            let request = MCPServerViewModel.CodeStructureRequest(
                direction: nil,
                maximumDepth: 0,
                includesSignatures: false,
                size: .medium,
                budget: WorkspaceCodemapGraphPolicy.initial.queryBudget(size: .medium, includesSignatures: false)
            )
            let recorder = ProjectionExecutionRecorder()
            let build = OSAllocatedUnfairLock<Task<ToolResultDTOs.CodeStructureReplyDTO, Error>?>(initialState: nil)
            MCPProviderProjectionWorker.executionObserverForTesting = { event in
                recorder.observer(event)
                if event.phase == "seed_ordering" {
                    build.withLock { $0 }?.cancel()
                }
            }
            defer { MCPProviderProjectionWorker.executionObserverForTesting = nil }

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

            XCTAssertThrowsError(try result.get()) { error in
                XCTAssertTrue(error is CancellationError, "\(error)")
            }
            XCTAssertEqual(recorder.events.map(\.phase), ["seed_ordering"])
            XCTAssertNil(server.capturedCodeStructureSeedOrderForTesting())
        }

        func testAuthoritySupersededDuringSeedOrderingFailsClosed() async throws {
            try await assertAuthoritySuperseded(duringPhase: "seed_ordering")
        }

        func testAuthoritySupersededDuringReplyAssemblyFailsClosed() async throws {
            try await assertAuthoritySuperseded(duringPhase: "reply_assembly")
        }

        /// The M9 race: authority validated before encoding must be revalidated after the worker
        /// hop, or a reply built under superseded authority is released.
        func testAuthoritySupersededDuringValueEncodingFailsClosed() async throws {
            try await assertAuthoritySuperseded(duringPhase: "value_encoding")
        }

        // MARK: - Helpers

        /// Supersedes the window's root catalog while `phase` is in flight on the projection worker.
        /// The main actor is suspended awaiting that worker, so the synchronous main-queue hop lands
        /// the change deterministically before the phase's operation runs.
        private func assertAuthoritySuperseded(
            duringPhase phase: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async throws {
            let fixture = try await makeFixture()
            let workspaceManager = fixture.window.window.workspaceManager
            let injections = OSAllocatedUnfairLock(initialState: 0)
            MCPProviderProjectionWorker.executionObserverForTesting = { event in
                guard event.toolName == MCPWindowToolName.getCodeStructure, event.phase == phase else { return }
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        workspaceManager.republishReadyRootCatalogWithNextGenerationForTesting()
                    }
                }
                injections.withLock { $0 += 1 }
            }
            defer { MCPProviderProjectionWorker.executionObserverForTesting = nil }

            let reply = try await fixture.codeStructure(paths: Self.seedPaths)

            XCTAssertEqual(injections.withLock { $0 }, 1, "authority change was not injected", file: file, line: line)
            XCTAssertEqual(reply.status, .unavailable, file: file, line: line)
            XCTAssertEqual(reply.issues.map(\.code), ["workspace_authority_superseded"], file: file, line: line)
            XCTAssertEqual(reply.issues.map(\.phase), ["workspace_authority"], file: file, line: line)
            XCTAssertEqual(reply.issues.map(\.retryable), [true], file: file, line: line)
            XCTAssertEqual(reply.roots, [], file: file, line: line)
            XCTAssertEqual(reply.files, [], file: file, line: line)
        }

        private struct Fixture {
            let window: InProcessMCPWindowServerFixture.RegisteredWindow
            let codemapRuntime: CodemapStoreFixture
            let tool: RepoPromptApp.Tool

            func codeStructure(paths: [String]) async throws -> ToolResultDTOs.CodeStructureReplyDTO {
                let value = try await tool([
                    "paths": .array(paths.map { .string($0) }),
                    "signatures": .bool(false)
                ])
                return try XCTUnwrap(value.decode(ToolResultDTOs.CodeStructureReplyDTO.self))
            }

            func close() async {
                await InProcessMCPWindowServerFixture.close(window)
                await codemapRuntime.shutdown()
            }
        }

        /// A registered window over a non-Git root holding `seedPaths`, with an isolated code-map
        /// runtime so no process-wide artifact state is read or written.
        private func makeFixture() async throws -> Fixture {
            let root = try makeRoot()
            let codemapRuntime = try CodemapStoreFixture(name: "mcp-code-structure-worker")
            let store = WorkspaceFileContextStore(
                enableCatalogShardShadowValidation: false,
                codemapRuntimeProvider: { try codemapRuntime.runtime() }
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
                try Data("struct S {}\n".utf8).write(to: file)
            }
            return root
        }
    }
#endif
