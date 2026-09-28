import Foundation
import MCP
import os
@testable import RepoPromptApp
import XCTest

#if DEBUG
    /// M11: the real app `read_file` path never releases a reply whose workspace authority changed
    /// while any projection-worker phase was in flight, including the final value encoding.
    @MainActor
    final class MCPReadFileProviderAuthorityTests: XCTestCase {
        private static let filePath = "src/readme.txt"
        private static let fileContent = "authority-sensitive content\n"

        func testUnchangedAuthorityReturnsContentAndRunsPhasesOffMain() async throws {
            let fixture = try await makeFixture()
            let recorder = ProjectionExecutionRecorder()
            MCPProviderProjectionWorker.executionObserverForTesting = recorder.observer
            defer { MCPProviderProjectionWorker.executionObserverForTesting = nil }

            let reply = try await fixture.readFile()

            XCTAssertNil(reply.errorCode, reply.errorMessage ?? "")
            XCTAssertTrue(reply.content.contains("authority-sensitive content"), reply.content)
            let events = recorder.events.filter { $0.toolName == MCPWindowToolName.readFile }
            XCTAssertEqual(events.map(\.phase).suffix(2), ["reply_projection", "value_encoding"])
            XCTAssertFalse(events.contains(where: \.ranOnMainThread), "\(events)")
        }

        func testAuthoritySupersededDuringReplyProjectionFailsClosed() async throws {
            try await assertAuthoritySuperseded(duringPhase: "reply_projection")
        }

        /// Validation before encoding is not enough: the encode hop suspends MainActor, so the
        /// provider must revalidate after it or release content read under superseded authority.
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
                guard event.toolName == MCPWindowToolName.readFile, event.phase == phase else { return }
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        workspaceManager.republishReadyRootCatalogWithNextGenerationForTesting()
                    }
                }
                injections.withLock { $0 += 1 }
            }
            defer { MCPProviderProjectionWorker.executionObserverForTesting = nil }

            let reply = try await fixture.readFile()

            XCTAssertEqual(injections.withLock { $0 }, 1, "authority change was not injected", file: file, line: line)
            XCTAssertEqual(reply.errorCode, "workspace_authority_superseded", file: file, line: line)
            XCTAssertEqual(reply.retryable, true, file: file, line: line)
            XCTAssertEqual(reply.content, "", file: file, line: line)
            XCTAssertEqual(reply.totalLines, 0, file: file, line: line)
            XCTAssertEqual(reply.displayPath, Self.filePath, file: file, line: line)
        }

        private struct Fixture {
            let window: InProcessMCPWindowServerFixture.RegisteredWindow
            let tool: RepoPromptApp.Tool

            func readFile() async throws -> ToolResultDTOs.ReadFileReply {
                let value = try await tool(["path": .string(MCPReadFileProviderAuthorityTests.filePath)])
                return try XCTUnwrap(value.decode(ToolResultDTOs.ReadFileReply.self))
            }
        }

        private func makeFixture() async throws -> Fixture {
            let root = try makeRoot()
            let window = try await InProcessMCPWindowServerFixture.makeRegisteredWindow(root: root)
            addTeardownBlock { @MainActor in await InProcessMCPWindowServerFixture.close(window) }
            return try await Fixture(
                window: window,
                tool: InProcessMCPWindowServerFixture.tool(
                    named: MCPWindowToolName.readFile,
                    from: window.window.mcpServer
                )
            )
        }

        private func makeRoot() throws -> URL {
            let temporary = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
            defer { free(temporary) }
            let parent = URL(fileURLWithPath: String(cString: temporary), isDirectory: true)
                .appendingPathComponent("mcp-read-file-authority-\(UUID().uuidString)", isDirectory: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
            let root = parent.appendingPathComponent("root", isDirectory: true)
            let file = root.appendingPathComponent(Self.filePath)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(Self.fileContent.utf8).write(to: file)
            return root
        }
    }
#endif
