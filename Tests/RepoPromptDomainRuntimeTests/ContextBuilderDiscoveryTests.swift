import Foundation
import MCP
@testable import RepoPromptDomainRuntime
import XCTest

/// Deterministic M17 coverage for `ContextBuilderDiscoveryEngine`: scripted providers, a real
/// temporary workspace for the explicit-read authority, and recording commit and pack ports.
final class ContextBuilderDiscoveryTests: XCTestCase {
    // MARK: - Happy path

    func testDiscoveryCommitsValidatedSelectionAndCanonicalPack() async throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanup() }
        let provider = ScriptedProvider(replies: [
            #"{"tool_calls":[{"tool":"file_search","arguments":{"pattern":"FEATURE_MARKER","mode":"content"}},{"tool":"manage_selection","arguments":{"op":"add","paths":["Sources/Feature.swift"]}}]}"#,
            "Staged it.\n```json\n{\"final\":{\"prompt\":\"Explain how Feature exposes its marker.\"}}\n```"
        ])
        let committer = RecordingCommitter()
        let store = RecordingPackStore()

        let outcome = try await ContextBuilderDiscoveryEngine().run(
            ContextBuilderDiscoveryRequest(instructions: "  Where is the feature marker?  ", mode: .plan),
            workspace: fixture.workspace(),
            provider: provider,
            committer: committer,
            packStore: store
        )

        let featurePath = fixture.root.path + "/Sources/Feature.swift"
        XCTAssertEqual(outcome.selection, [featurePath])
        XCTAssertEqual(outcome.displayPaths, ["Sources/Feature.swift"])
        XCTAssertEqual(outcome.prompt, "Explain how Feature exposes its marker.")
        XCTAssertEqual(outcome.context, fixture.snapshot.identity)
        XCTAssertEqual(outcome.turns, 2)
        XCTAssertEqual(outcome.toolCalls, 2)
        XCTAssertEqual(outcome.refusedToolCalls, 0)
        XCTAssertEqual(outcome.pack.mode, .plan)
        XCTAssertEqual(outcome.pack.provenance, [OracleEvidenceReference(path: "Sources/Feature.swift")])
        XCTAssertTrue(outcome.pack.content.contains("FEATURE_MARKER"))
        XCTAssertTrue(outcome.pack.content.hasPrefix("<task>\nExplain how Feature exposes its marker."))
        XCTAssertTrue(outcome.pack.content.contains("<user_instructions>\nWhere is the feature marker?\n</user_instructions>"))
        XCTAssertTrue(outcome.pack.content.contains(#"<file path="Sources/Feature.swift">"#))
        XCTAssertFalse(outcome.pack.content.contains("Other.swift"))

        let data = try outcome.pack.canonicalData()
        XCTAssertEqual(outcome.packBytes, data.count)
        XCTAssertEqual(outcome.packReference.artifactID, DomainContentDigest.sha256(data))
        let stored = await store.artifacts
        XCTAssertEqual(stored, [outcome.packReference.artifactID: data])
        XCTAssertEqual(try OracleFrozenContextPack.decodeCanonical(data), outcome.pack)

        let commits = await committer.commits
        XCTAssertEqual(commits.map(\.paths), [[featurePath]])
        XCTAssertEqual(commits.first?.snapshot, fixture.snapshot)
        XCTAssertEqual(outcome.receipt.contextRevision, fixture.snapshot.contextRevision + 1)

        let input = try outcome.oracleInput()
        XCTAssertEqual(input.userMessage, outcome.pack.content)
        XCTAssertEqual(input.mode, .plan)
        XCTAssertEqual(input.context?.content, .durableArtifact(id: outcome.packReference.artifactID))
        XCTAssertEqual(input.context?.sha256, outcome.packReference.artifactID)

        let prompts = await provider.prompts
        XCTAssertEqual(prompts.count, 2)
        XCTAssertTrue(prompts[0].contains(ContextBuilderDiscoveryPrompt.protocolVersion))
        XCTAssertTrue(prompts[0].contains("<user_instructions>\nWhere is the feature marker?\n</user_instructions>"))
        XCTAssertTrue(prompts[0].contains("No files are staged."))
        XCTAssertTrue(prompts[1].contains(#"tool="file_search" status="ok""#))
        XCTAssertTrue(prompts[1].contains("Sources/Feature.swift"))
        XCTAssertTrue(prompts[1].contains("1 staged file(s):\n- Sources/Feature.swift"))
    }

    func testFinalSelectedPathsReplaceStagedSelectionAndDeduplicate() async throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanup() }
        let provider = ScriptedProvider(replies: [
            #"{"tool_calls":[{"tool":"manage_selection","arguments":{"op":"add","paths":["README.md"]}}]}"#,
            #"{"final":{"selected_paths":["Sources/Other.swift","./Sources/Other.swift","\#(fixture.root.path)/Sources/Feature.swift"]}}"#
        ])
        let committer = RecordingCommitter()

        let outcome = try await ContextBuilderDiscoveryEngine().run(
            ContextBuilderDiscoveryRequest(instructions: "Pick the sources", mode: .chat),
            workspace: fixture.workspace(),
            provider: provider,
            committer: committer,
            packStore: RecordingPackStore()
        )

        XCTAssertEqual(outcome.displayPaths, ["Sources/Other.swift", "Sources/Feature.swift"])
        XCTAssertEqual(outcome.prompt, "Pick the sources", "an absent final prompt falls back to the instructions")
        XCTAssertFalse(outcome.pack.content.contains("<user_instructions>"))
        let commits = await committer.commits
        XCTAssertEqual(commits.map(\.paths), [[
            fixture.root.path + "/Sources/Other.swift",
            fixture.root.path + "/Sources/Feature.swift"
        ]])
    }

    // MARK: - Tool allowlist

    func testRefusedToolsAreNeverExecutedAndTheRunContinues() async throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanup() }
        let readme = fixture.root.appendingPathComponent("README.md")
        let original = try Data(contentsOf: readme)
        let provider = ScriptedProvider(replies: [
            #"{"tool_calls":[{"tool":"apply_edits","arguments":{"path":"README.md","rewrite":"owned"}},{"tool":"file_actions","arguments":{"action":"delete","path":"README.md"}},{"tool":"read_file","arguments":{"path":"README.md"}}]}"#,
            #"{"final":{"selected_paths":["README.md"]}}"#
        ])
        let committer = RecordingCommitter()

        let outcome = try await ContextBuilderDiscoveryEngine().run(
            ContextBuilderDiscoveryRequest(instructions: "Read the readme", mode: .chat),
            workspace: fixture.workspace(),
            provider: provider,
            committer: committer,
            packStore: RecordingPackStore()
        )

        XCTAssertEqual(try Data(contentsOf: readme), original)
        XCTAssertEqual(outcome.toolCalls, 3)
        XCTAssertEqual(outcome.refusedToolCalls, 2)
        let prompts = await provider.prompts
        XCTAssertEqual(prompts[1].components(separatedBy: #"status="refused""#).count - 1, 2)
        XCTAssertTrue(prompts[1].contains("tool_not_allowed: apply_edits"))
        XCTAssertTrue(prompts[1].contains("tool_not_allowed: file_actions"))
        XCTAssertTrue(prompts[1].contains(#"tool="read_file" status="ok""#))
        XCTAssertTrue(prompts[1].contains("README_MARKER"))
        let commits = await committer.commits
        XCTAssertEqual(commits.count, 1)
    }

    // MARK: - Path authority

    func testStagedSelectionRejectsSymlinksOutsidePathsAndDirectories() async throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanup() }
        let provider = ScriptedProvider(replies: [
            """
            {"tool_calls":[
              {"tool":"manage_selection","arguments":{"op":"add","paths":["Sources/Feature.swift"]}},
              {"tool":"manage_selection","arguments":{"op":"add","paths":["Sources/Link.swift"]}},
              {"tool":"manage_selection","arguments":{"op":"add","paths":["../\(fixture.outside.lastPathComponent)/secret.txt"]}},
              {"tool":"manage_selection","arguments":{"op":"add","paths":["\(fixture.outside.path)/secret.txt"]}},
              {"tool":"manage_selection","arguments":{"op":"add","paths":["Sources"]}},
              {"tool":"manage_selection","arguments":{"op":"add","paths":["LinkedDir/Feature.swift"]}}
            ]}
            """,
            #"{"final":{}}"#
        ])
        let committer = RecordingCommitter()

        let outcome = try await ContextBuilderDiscoveryEngine().run(
            ContextBuilderDiscoveryRequest(instructions: "Stage things", mode: .chat),
            workspace: fixture.workspace(),
            provider: provider,
            committer: committer,
            packStore: RecordingPackStore()
        )

        XCTAssertEqual(outcome.displayPaths, ["Sources/Feature.swift"])
        let prompts = await provider.prompts
        let second = prompts[1]
        XCTAssertEqual(second.components(separatedBy: #"tool="manage_selection" status="error""#).count - 1, 5)
        XCTAssertTrue(second.contains("symbolic_link_path"))
        XCTAssertTrue(second.contains("outside_root"))
        XCTAssertTrue(second.contains("not_a_regular_file"))
        XCTAssertTrue(second.contains("symlink_component"))
        XCTAssertTrue(second.contains("The staged selection is unchanged."))
    }

    func testReadToolOnAFIFOFailsTypedInsteadOfBlocking() async throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanup() }
        let provider = ScriptedProvider(replies: [
            #"{"tool_calls":[{"tool":"read_file","arguments":{"path":"Pipe"}},{"tool":"get_code_structure","arguments":{"paths":["Pipe"]}}]}"#,
            #"{"final":{"selected_paths":["README.md"]}}"#
        ])
        // Before the non-blocking leaf open, `read_file` on a FIFO waited for a writer forever and
        // the exploration deadline could not unwind it.
        var limits = ContextBuilderDiscoveryLimits.default
        limits.maximumDuration = .seconds(30)
        let outcome = try await ContextBuilderDiscoveryEngine(limits: limits).run(
            ContextBuilderDiscoveryRequest(instructions: "Read the pipe", mode: .chat),
            workspace: fixture.workspace(),
            provider: provider,
            committer: RecordingCommitter(),
            packStore: RecordingPackStore()
        )
        XCTAssertEqual(outcome.displayPaths, ["README.md"])
        let prompts = await provider.prompts
        XCTAssertTrue(prompts[1].contains(#"tool="read_file" status="error""#))
        XCTAssertTrue(prompts[1].contains("Path is not a regular file."))
    }

    func testFinalSelectionWithInadmissiblePathFailsClosed() async throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanup() }
        let cases: [(path: String, reason: String)] = [
            ("Sources/Link.swift", "symbolic_link_path"),
            ("LinkedDir/Feature.swift", "symlink_component"),
            (fixture.outside.path + "/secret.txt", "outside_root"),
            ("Sources", "not_a_regular_file"),
            ("Pipe", "not_a_regular_file"),
            ("Sources/Missing.swift", "not_found")
        ]
        for testCase in cases {
            let provider = ScriptedProvider(replies: [
                #"{"final":{"selected_paths":["Sources/Feature.swift","\#(testCase.path)"]}}"#
            ])
            let committer = RecordingCommitter()
            let store = RecordingPackStore()
            do {
                _ = try await ContextBuilderDiscoveryEngine().run(
                    ContextBuilderDiscoveryRequest(instructions: "Select", mode: .chat),
                    workspace: fixture.workspace(),
                    provider: provider,
                    committer: committer,
                    packStore: store
                )
                XCTFail("Expected \(testCase.reason) for \(testCase.path)")
            } catch let error as ContextBuilderDiscoveryError {
                XCTAssertEqual(error, .invalidSelectedPath(path: testCase.path, reason: testCase.reason))
                XCTAssertTrue(error.localizedDescription.hasPrefix("discovery_selection_invalid:"))
            }
            let commits = await committer.commits
            let artifacts = await store.artifacts
            XCTAssertTrue(commits.isEmpty, testCase.path)
            XCTAssertTrue(artifacts.isEmpty, testCase.path)
        }
    }

    func testFileSwappedForSymlinkAfterStagingFailsClosedAtFinalization() async throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanup() }
        let feature = fixture.root.appendingPathComponent("Sources/Feature.swift")
        let secret = fixture.outside.appendingPathComponent("secret.txt")
        let provider = ScriptedProvider(steps: [
            { _, _ in #"{"tool_calls":[{"tool":"manage_selection","arguments":{"op":"add","paths":["Sources/Feature.swift"]}}]}"# },
            { _, _ in
                try FileManager.default.removeItem(at: feature)
                try FileManager.default.createSymbolicLink(at: feature, withDestinationURL: secret)
                return #"{"final":{}}"#
            }
        ])
        let committer = RecordingCommitter()
        let store = RecordingPackStore()

        do {
            _ = try await ContextBuilderDiscoveryEngine().run(
                ContextBuilderDiscoveryRequest(instructions: "Select", mode: .chat),
                workspace: fixture.workspace(),
                provider: provider,
                committer: committer,
                packStore: store
            )
            XCTFail("Expected the swapped path to be refused")
        } catch let error as ContextBuilderDiscoveryError {
            XCTAssertEqual(error.code, "discovery_selection_invalid")
        }
        let commits = await committer.commits
        let artifacts = await store.artifacts
        XCTAssertTrue(commits.isEmpty)
        XCTAssertTrue(artifacts.isEmpty)
    }

    func testMovedRootFailsClosedBeforePackOrCommit() async throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanup() }
        let moved = fixture.root.deletingLastPathComponent()
            .appendingPathComponent(fixture.root.lastPathComponent + "-moved")
        let root = fixture.root
        let provider = ScriptedProvider(steps: [
            { _, _ in #"{"tool_calls":[{"tool":"manage_selection","arguments":{"op":"add","paths":["README.md"]}}]}"# },
            { _, _ in
                try FileManager.default.moveItem(at: root, to: moved)
                return #"{"final":{}}"#
            }
        ])
        defer { try? FileManager.default.removeItem(at: moved) }
        let committer = RecordingCommitter()
        let store = RecordingPackStore()

        do {
            _ = try await ContextBuilderDiscoveryEngine().run(
                ContextBuilderDiscoveryRequest(instructions: "Select", mode: .chat),
                workspace: fixture.workspace(),
                provider: provider,
                committer: committer,
                packStore: store
            )
            XCTFail("Expected a stale root to fail closed")
        } catch let error as ContextBuilderDiscoveryError {
            XCTAssertEqual(error.code, "discovery_context_changed")
        }
        let commits = await committer.commits
        let artifacts = await store.artifacts
        XCTAssertTrue(commits.isEmpty)
        XCTAssertTrue(artifacts.isEmpty)
    }

    // MARK: - Bounds and failures

    func testTurnLimitFailsClosedAndWarnsOnTheLastTurn() async throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanup() }
        let provider = ScriptedProvider(replies: [
            #"{"tool_calls":[{"tool":"get_file_tree","arguments":{"max_depth":1}}]}"#
        ])
        let committer = RecordingCommitter()
        var limits = ContextBuilderDiscoveryLimits.default
        limits.maximumTurns = 3

        await assertDiscoveryFails(
            .turnLimitExceeded(3),
            engine: ContextBuilderDiscoveryEngine(limits: limits),
            fixture: fixture,
            provider: provider,
            committer: committer
        )
        let prompts = await provider.prompts
        XCTAssertEqual(prompts.count, 3)
        XCTAssertFalse(prompts[1].contains("This is your last reply"))
        XCTAssertTrue(prompts[2].contains("Reply 3 of 3. This is your last reply"))
        XCTAssertTrue(prompts[2].contains(#"tool="get_file_tree" status="ok""#))
    }

    func testMalformedRepliesAreRepairedWithinTheLimitAndFailClosedPastIt() async throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanup() }

        let recovering = ScriptedProvider(replies: [
            "I will look at the readme first.",
            #"{"final":{"selected_paths":["README.md"]}}"#
        ])
        let outcome = try await ContextBuilderDiscoveryEngine().run(
            ContextBuilderDiscoveryRequest(instructions: "Readme", mode: .chat),
            workspace: fixture.workspace(),
            provider: recovering,
            committer: RecordingCommitter(),
            packStore: RecordingPackStore()
        )
        XCTAssertEqual(outcome.displayPaths, ["README.md"])
        let prompts = await recovering.prompts
        XCTAssertTrue(prompts[1].contains(#"status="protocol_error""#))

        let violating = ScriptedProvider(replies: [
            "no json",
            #"{"tool_calls":[],"final":{}}"#,
            #"{"tool_calls":"read everything"}"#
        ])
        let committer = RecordingCommitter()
        await assertDiscoveryFails(
            .protocolViolation("\"tool_calls\" must be a non-empty array"),
            engine: ContextBuilderDiscoveryEngine(),
            fixture: fixture,
            provider: violating,
            committer: committer
        )
    }

    func testProviderFailureFailsClosed() async throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanup() }
        let provider = ScriptedProvider(steps: [
            { _, _ in throw NSError(domain: "fake-provider", code: 7, userInfo: [NSLocalizedDescriptionKey: "exit 7"]) }
        ])
        let committer = RecordingCommitter()
        let store = RecordingPackStore()
        await assertDiscoveryFails(
            .providerFailed("exit 7"),
            engine: ContextBuilderDiscoveryEngine(),
            fixture: fixture,
            provider: provider,
            committer: committer,
            store: store
        )
        let artifacts = await store.artifacts
        XCTAssertTrue(artifacts.isEmpty)
    }

    func testCancellationDuringAProviderTurnFailsClosed() async throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanup() }
        let provider = ScriptedProvider(steps: [
            { _, _ in #"{"tool_calls":[{"tool":"manage_selection","arguments":{"op":"add","paths":["README.md"]}}]}"# },
            { _, _ in
                try await Task.sleep(for: .seconds(3600))
                return #"{"final":{}}"#
            }
        ])
        let committer = RecordingCommitter()
        let store = RecordingPackStore()
        let workspace = fixture.workspace()
        let task = Task {
            try await ContextBuilderDiscoveryEngine().run(
                ContextBuilderDiscoveryRequest(instructions: "Select", mode: .chat),
                workspace: workspace,
                provider: provider,
                committer: committer,
                packStore: store
            )
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while await provider.prompts.count < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let commits = await committer.commits
        let artifacts = await store.artifacts
        XCTAssertTrue(commits.isEmpty)
        XCTAssertTrue(artifacts.isEmpty)
    }

    func testExplorationDeadlineFailsClosed() async throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanup() }
        let provider = ScriptedProvider(steps: [
            { _, _ in
                try await Task.sleep(for: .seconds(3600))
                return #"{"final":{}}"#
            }
        ])
        var limits = ContextBuilderDiscoveryLimits.default
        limits.maximumDuration = .seconds(42)
        let committer = RecordingCommitter()
        await assertDiscoveryFails(
            .timedOut(.seconds(42)),
            engine: ContextBuilderDiscoveryEngine(limits: limits, sleep: { _ in }),
            fixture: fixture,
            provider: provider,
            committer: committer
        )
    }

    func testSelectionAndPackBudgetsFailClosed() async throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanup() }
        var fileLimit = ContextBuilderDiscoveryLimits.default
        fileLimit.maximumSelectedFiles = 1
        await assertDiscoveryFails(
            .selectionLimitExceeded(count: 2, limit: 1),
            engine: ContextBuilderDiscoveryEngine(limits: fileLimit),
            fixture: fixture,
            provider: ScriptedProvider(replies: [#"{"final":{"selected_paths":["README.md","Sources/Feature.swift"]}}"#]),
            committer: RecordingCommitter()
        )

        var packLimit = ContextBuilderDiscoveryLimits.default
        packLimit.maximumPackBytes = 64
        let store = RecordingPackStore()
        let committer = RecordingCommitter()
        do {
            _ = try await ContextBuilderDiscoveryEngine(limits: packLimit).run(
                ContextBuilderDiscoveryRequest(instructions: "Select", mode: .chat),
                workspace: fixture.workspace(),
                provider: ScriptedProvider(replies: [#"{"final":{"selected_paths":["Sources/Feature.swift"]}}"#]),
                committer: committer,
                packStore: store
            )
            XCTFail("Expected the pack budget to fail closed")
        } catch let error as ContextBuilderDiscoveryError {
            XCTAssertEqual(error.code, "discovery_pack_budget_exceeded")
        }
        let commits = await committer.commits
        let artifacts = await store.artifacts
        XCTAssertTrue(commits.isEmpty)
        XCTAssertTrue(artifacts.isEmpty)

        await assertDiscoveryFails(
            .emptySelection,
            engine: ContextBuilderDiscoveryEngine(),
            fixture: fixture,
            provider: ScriptedProvider(replies: [#"{"final":{"prompt":"nothing relevant"}}"#]),
            committer: RecordingCommitter()
        )
    }

    func testCommitConflictPropagatesWithoutWritingSelection() async throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanup() }
        let committer = RecordingCommitter(failure: .contextChanged("the bound context was modified"))
        let store = RecordingPackStore()
        do {
            _ = try await ContextBuilderDiscoveryEngine().run(
                ContextBuilderDiscoveryRequest(instructions: "Select", mode: .review),
                workspace: fixture.workspace(),
                provider: ScriptedProvider(replies: [#"{"final":{"selected_paths":["README.md"]}}"#]),
                committer: committer,
                packStore: store
            )
            XCTFail("Expected the committer's conflict")
        } catch let error as ContextBuilderDiscoveryError {
            XCTAssertEqual(error, .contextChanged("the bound context was modified"))
            XCTAssertTrue(error.isRetryable)
        }
        let commits = await committer.commits
        XCTAssertEqual(commits.count, 1, "the conflict is decided by the committer, once")
        // The content-addressed pack is stored before the commit; a rejected commit leaves at most
        // this one unreferenced artifact and never a selection.
        let artifacts = await store.artifacts
        XCTAssertEqual(artifacts.count, 1)
    }

    // MARK: - Commit boundary (M18)

    func testCancellationObservedAfterTheCommitStillReturnsTheCommittedOutcome() async throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanup() }
        // The committer writes, then cancellation lands before the engine resumes.
        let committer = RecordingCommitter(afterCommit: { withUnsafeCurrentTask { $0?.cancel() } })
        let store = RecordingPackStore()
        let workspace = fixture.workspace()
        let task = Task {
            try await ContextBuilderDiscoveryEngine().run(
                ContextBuilderDiscoveryRequest(instructions: "Select", mode: .plan),
                workspace: workspace,
                provider: ScriptedProvider(replies: [#"{"final":{"selected_paths":["README.md"]}}"#]),
                committer: committer,
                packStore: store
            )
        }

        let outcome = try await task.value
        XCTAssertTrue(task.isCancelled)
        XCTAssertEqual(outcome.selection, [fixture.root.path + "/README.md"])
        XCTAssertTrue(outcome.receipt.applied)
        let commits = await committer.commits
        let artifacts = await store.artifacts
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(Array(artifacts.keys), [outcome.packReference.artifactID])
    }

    func testCancellationAtThePackStoreBoundaryFailsBeforeTheCommit() async throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanup() }
        let committer = RecordingCommitter()
        // Cancellation lands while the pack is being stored, the last step before the commit.
        let store = RecordingPackStore(onStore: { withUnsafeCurrentTask { $0?.cancel() } })
        let workspace = fixture.workspace()
        let task = Task {
            try await ContextBuilderDiscoveryEngine().run(
                ContextBuilderDiscoveryRequest(instructions: "Select", mode: .plan),
                workspace: workspace,
                provider: ScriptedProvider(replies: [#"{"final":{"selected_paths":["README.md"]}}"#]),
                committer: committer,
                packStore: store
            )
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation before the commit")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let commits = await committer.commits
        let artifacts = await store.artifacts
        XCTAssertTrue(commits.isEmpty, "pre-commit cancellation writes no selection")
        XCTAssertEqual(artifacts.count, 1, "at most the one unreferenced content-addressed pack remains")
    }

    // MARK: - Multi-root spellings (M18)

    func testMultiRootEmittedSpellingsRoundTripThroughTheFinalSelectionAndPack() async throws {
        let fixture = try MultiRootFixture()
        defer { fixture.cleanup() }
        let provider = ScriptedProvider(steps: [
            { _, _ in
                #"""
                {"tool_calls":[
                  {"tool":"file_search","arguments":{"pattern":"_MARKER","mode":"content"}},
                  {"tool":"get_file_tree","arguments":{"max_depth":1}},
                  {"tool":"read_file","arguments":{"path":"lib/Only.swift"}},
                  {"tool":"manage_selection","arguments":{"op":"add","paths":["Sources/Feature.swift"]}},
                  {"tool":"manage_selection","arguments":{"op":"add","paths":["lib/Sources/Feature.swift"]}}
                ]}
                """#
            },
            { prompt, _ in
                // Select exactly the spellings the search emitted.
                let paths = try MultiRootFixture.searchResultPaths(in: prompt)
                let final: [String: Any] = ["final": ["selected_paths": paths]]
                return try String(decoding: JSONSerialization.data(withJSONObject: final), as: UTF8.self)
            }
        ])
        let committer = RecordingCommitter()

        let outcome = try await ContextBuilderDiscoveryEngine().run(
            ContextBuilderDiscoveryRequest(instructions: "Collect every marker", mode: .review),
            workspace: fixture.workspace(),
            provider: provider,
            committer: committer,
            packStore: RecordingPackStore()
        )

        // Duplicate basenames are labelled by full path; the unique root by its folder name. A short
        // spelling that another root also holds (`lib/Sources/Feature.swift` exists under the first
        // root) is emitted absolute instead, so every emitted spelling names one file.
        let expectedDisplay = [
            "lib/Only.swift",
            fixture.lib.path + "/Sources/Feature.swift",
            fixture.appOne.path + "/Sources/Feature.swift",
            fixture.appOne.path + "/lib/Sources/Feature.swift",
            fixture.appTwo.path + "/Sources/Feature.swift"
        ]
        let expectedSelection = [
            fixture.lib.path + "/Only.swift",
            fixture.lib.path + "/Sources/Feature.swift",
            fixture.appOne.path + "/Sources/Feature.swift",
            fixture.appOne.path + "/lib/Sources/Feature.swift",
            fixture.appTwo.path + "/Sources/Feature.swift"
        ]
        let prompts = await provider.prompts
        XCTAssertEqual(try MultiRootFixture.searchResultPaths(in: prompts[1]), expectedDisplay)
        XCTAssertEqual(outcome.displayPaths, expectedDisplay)
        XCTAssertEqual(outcome.selection, expectedSelection)
        let commits = await committer.commits
        XCTAssertEqual(commits.map(\.paths), [expectedSelection])
        XCTAssertEqual(outcome.pack.provenance, expectedDisplay.map { OracleEvidenceReference(path: $0) })
        for (display, marker) in zip(expectedDisplay, ["ONLY", "LIB", "APP_ONE", "SHADOW", "APP_TWO"]) {
            XCTAssertTrue(outcome.pack.content.contains("<file path=\"\(display)\">\nlet value = \"\(marker)_MARKER\""), display)
        }

        // Read tools accept the same spellings, and tree headings are the root labels.
        XCTAssertTrue(prompts[1].contains("tool=\"read_file\" status=\"ok\">\nlet value = \"ONLY_MARKER\""))
        XCTAssertTrue(prompts[1].contains("\n" + fixture.appOne.path + "/\n"))
        XCTAssertTrue(prompts[1].contains("\n" + fixture.appTwo.path + "/\n"))
        XCTAssertTrue(prompts[1].contains("\nlib/\n"))
        // A bare path under two roots, and a short spelling another root also holds, are refused.
        XCTAssertEqual(prompts[1].components(separatedBy: "ambiguous_across_roots").count - 1, 2)
        XCTAssertTrue(prompts[1].contains("No files are staged."))
        XCTAssertTrue(prompts[0].contains("`<root label>/<path in that root>`"))

        // Every emitted spelling is admitted back to its own file; ambiguous ones are not guessed.
        let workspace = fixture.workspace()
        for (display, absolute) in zip(expectedDisplay, expectedSelection) {
            XCTAssertEqual(try workspace.authorize(display, skipSymlinks: true).absolutePath, absolute)
        }
        for ambiguous in ["Sources/Feature.swift", "lib/Sources/Feature.swift"] {
            XCTAssertThrowsError(try workspace.authorize(ambiguous, skipSymlinks: true)) { error in
                XCTAssertEqual(
                    error as? ContextBuilderDiscoveryError,
                    .invalidSelectedPath(path: ambiguous, reason: "ambiguous_across_roots")
                )
            }
        }
    }

    func testPromptBudgetElidesOldestToolResultsFirst() async throws {
        let fixture = try WorkspaceFixture()
        defer { fixture.cleanup() }
        let large = String(repeating: "L", count: 5000)
        try Data(large.utf8).write(to: fixture.root.appendingPathComponent("Large.txt"))
        var limits = ContextBuilderDiscoveryLimits.default
        limits.maximumToolResultCharacters = 2500
        limits.maximumPromptCharacters = 7000
        let provider = ScriptedProvider(replies: [
            #"{"tool_calls":[{"tool":"read_file","arguments":{"path":"Large.txt"}}]}"#,
            #"{"tool_calls":[{"tool":"read_file","arguments":{"path":"Large.txt","start_line":1}}]}"#,
            #"{"tool_calls":[{"tool":"read_file","arguments":{"path":"README.md"}}]}"#,
            #"{"final":{"selected_paths":["README.md"]}}"#
        ])
        _ = try await ContextBuilderDiscoveryEngine(limits: limits).run(
            ContextBuilderDiscoveryRequest(instructions: "Budget", mode: .chat),
            workspace: fixture.workspace(),
            provider: provider,
            committer: RecordingCommitter(),
            packStore: RecordingPackStore()
        )
        let prompts = await provider.prompts
        XCTAssertEqual(prompts.count, 4)
        for prompt in prompts {
            XCTAssertLessThanOrEqual(prompt.count, limits.maximumPromptCharacters)
        }
        XCTAssertTrue(prompts[3].contains("[elided to stay within the prompt budget"))
        XCTAssertTrue(prompts[3].contains("README_MARKER"), "the newest result is kept")
        XCTAssertTrue(prompts[1].contains("[truncated:"))

        await assertDiscoveryFails(
            .emptyInstructions,
            engine: ContextBuilderDiscoveryEngine(),
            fixture: fixture,
            provider: ScriptedProvider(replies: ["unused"]),
            committer: RecordingCommitter(),
            instructions: " \n "
        )
    }

    // MARK: - Reply protocol

    func testReplyParserToleratesProseAndFencesAndRejectsAmbiguity() throws {
        let fenced = ContextBuilderDiscoveryReply.parse(
            "Plan:\n```json\n{\"tool_calls\":[{\"tool\":\"read_file\",\"arguments\":{\"path\":\"a {b} \\\"c\\\".swift\"}}]}\n```",
            maximumToolCalls: 2
        )
        XCTAssertEqual(try fenced.get(), .toolCalls([
            ContextBuilderDiscoveryToolCall(tool: "read_file", arguments: ["path": .string("a {b} \"c\".swift")])
        ]))
        XCTAssertEqual(
            try ContextBuilderDiscoveryReply.parse(
                #"{"note":"skip me"} then {"final":{"prompt":"p","selected_paths":["x"]}}"#,
                maximumToolCalls: 1
            ).get(),
            .final(selectedPaths: ["x"], prompt: "p")
        )
        for (text, reason) in [
            ("", "no JSON object"),
            (#"{"tool_calls":[{"tool":"a"}],"final":{}}"#, "exactly one"),
            (#"{"tool_calls":[{"tool":"a"},{"tool":"b"},{"tool":"c"}]}"#, "exceed the 2-call limit"),
            (#"{"tool_calls":[{"arguments":{}}]}"#, "needs a string"),
            (#"{"final":{"selected_paths":"x"}}"#, "array of strings"),
            (#"{"final":"done"}"#, "must be an object")
        ] {
            guard case let .failure(failure) = ContextBuilderDiscoveryReply.parse(text, maximumToolCalls: 2) else {
                XCTFail("Expected a parse failure for \(text)")
                continue
            }
            XCTAssertTrue(failure.reason.contains(reason), "\(text): \(failure.reason)")
        }
    }

    // MARK: - Helpers

    private func assertDiscoveryFails(
        _ expected: ContextBuilderDiscoveryError,
        engine: ContextBuilderDiscoveryEngine,
        fixture: WorkspaceFixture,
        provider: ScriptedProvider,
        committer: RecordingCommitter,
        store: RecordingPackStore = RecordingPackStore(),
        instructions: String = "Discover",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await engine.run(
                ContextBuilderDiscoveryRequest(instructions: instructions, mode: .chat),
                workspace: fixture.workspace(),
                provider: provider,
                committer: committer,
                packStore: store
            )
            XCTFail("Expected \(expected.code)", file: file, line: line)
        } catch let error as ContextBuilderDiscoveryError {
            XCTAssertEqual(error, expected, file: file, line: line)
            XCTAssertTrue(error.localizedDescription.hasPrefix(expected.code + ":"), file: file, line: line)
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
        let commits = await committer.commits
        XCTAssertTrue(commits.isEmpty, "a failed discovery must not commit", file: file, line: line)
    }
}

private struct WorkspaceFixture {
    let base: URL
    let root: URL
    let outside: URL
    let snapshot: ContextBuilderDiscoverySnapshot

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-discovery-\(UUID().uuidString)", isDirectory: true)
        let rawRoot = base.appendingPathComponent("repo", isDirectory: true)
        outside = base.appendingPathComponent("outside", isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: rawRoot.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("struct Feature { let marker = \"FEATURE_MARKER\" }\n".utf8)
            .write(to: rawRoot.appendingPathComponent("Sources/Feature.swift"))
        try Data("struct Other {}\n".utf8).write(to: rawRoot.appendingPathComponent("Sources/Other.swift"))
        try Data("# Readme\nREADME_MARKER\n".utf8).write(to: rawRoot.appendingPathComponent("README.md"))
        try Data("secret\n".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try manager.createSymbolicLink(
            at: rawRoot.appendingPathComponent("Sources/Link.swift"),
            withDestinationURL: rawRoot.appendingPathComponent("Sources/Feature.swift")
        )
        try manager.createSymbolicLink(
            at: rawRoot.appendingPathComponent("LinkedDir"),
            withDestinationURL: rawRoot.appendingPathComponent("Sources")
        )
        // A FIFO must be refused without ever being opened for reading (which would block).
        guard mkfifo(rawRoot.appendingPathComponent("Pipe").path, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // Spelled like the direct-headless context spells roots.
        root = rawRoot.standardizedFileURL.resolvingSymlinksInPath()
        snapshot = ContextBuilderDiscoverySnapshot(
            identity: DomainContextIdentity(workspaceID: UUID(), contextID: UUID()),
            workspaceRevision: 4,
            contextRevision: 9,
            roots: [root],
            prompt: "existing prompt",
            selection: [root.path + "/README.md"]
        )
    }

    func workspace() -> ContextBuilderFrozenWorkspace {
        ContextBuilderFrozenWorkspace(snapshot: snapshot, resolvePath: { rawPath, roots, _ in
            let candidate = rawPath.hasPrefix("/")
                ? URL(fileURLWithPath: rawPath)
                : roots[0].appendingPathComponent(rawPath)
            let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath().path
            guard roots.contains(where: { root in
                let rootPath = root.resolvingSymlinksInPath().path
                return resolved == rootPath || resolved.hasPrefix(rootPath + "/")
            }) else {
                throw MCPError.invalidParams("Path is outside the bound workspace roots: \(rawPath)")
            }
            return URL(fileURLWithPath: resolved)
        })
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: base)
    }
}

/// Three roots: two share the folder name `app`, and the first holds `lib/Sources/Feature.swift`,
/// which is also the short spelling of the `lib` root's `Sources/Feature.swift`. Every
/// `Sources/Feature.swift` exists under all three roots.
private struct MultiRootFixture {
    let base: URL
    let appOne: URL
    let appTwo: URL
    let lib: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("rp-discovery-multi-\(UUID().uuidString)", isDirectory: true)
        self.base = base
        let files = [
            ("one/app/Sources/Feature.swift", "APP_ONE"),
            ("one/app/lib/Sources/Feature.swift", "SHADOW"),
            ("two/app/Sources/Feature.swift", "APP_TWO"),
            ("lib/Sources/Feature.swift", "LIB"),
            ("lib/Only.swift", "ONLY")
        ]
        for (path, marker) in files {
            let url = base.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("let value = \"\(marker)_MARKER\"\n".utf8).write(to: url)
        }
        func root(_ path: String) -> URL {
            base.appendingPathComponent(path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        }
        appOne = root("one/app")
        appTwo = root("two/app")
        lib = root("lib")
    }

    func workspace() -> ContextBuilderFrozenWorkspace {
        ContextBuilderFrozenWorkspace(
            snapshot: ContextBuilderDiscoverySnapshot(
                identity: DomainContextIdentity(workspaceID: UUID(), contextID: UUID()),
                workspaceRevision: 1,
                contextRevision: 1,
                roots: [appOne, appTwo, lib],
                prompt: "",
                selection: []
            ),
            resolvePath: { rawPath, roots, _ in
                let candidates = rawPath.hasPrefix("/")
                    ? [URL(fileURLWithPath: rawPath)]
                    : roots.map { $0.appendingPathComponent(rawPath) }
                        .filter { FileManager.default.fileExists(atPath: $0.path) }
                guard candidates.count == 1, let candidate = candidates.first else {
                    throw MCPError.invalidParams("Relative path is ambiguous across workspace roots")
                }
                let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath().path
                guard roots.contains(where: { root in
                    let rootPath = root.resolvingSymlinksInPath().path
                    return resolved == rootPath || resolved.hasPrefix(rootPath + "/")
                }) else {
                    throw MCPError.invalidParams("Path is outside the bound workspace roots: \(rawPath)")
                }
                return URL(fileURLWithPath: resolved)
            }
        )
    }

    /// The `path` of every `file_search` match shown in a discovery prompt, in order.
    static func searchResultPaths(in prompt: String) throws -> [String] {
        let opening = #"tool="file_search" status="ok">"# + "\n"
        guard let start = prompt.range(of: opening),
              let end = prompt.range(of: "\n</tool_result>", range: start.upperBound ..< prompt.endIndex)
        else {
            throw CocoaError(.coderValueNotFound)
        }
        let body = Data(prompt[start.upperBound ..< end.lowerBound].utf8)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let matches = try XCTUnwrap(object["matches"] as? [[String: Any]])
        return matches.compactMap { $0["path"] as? String }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: base)
    }
}

private actor ScriptedProvider: ContextBuilderDiscoveryProvider {
    typealias Step = @Sendable (_ prompt: String, _ turn: Int) async throws -> String

    private let steps: [Step]
    private(set) var prompts: [String] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    init(replies: [String]) {
        steps = replies.map { reply in { _, _ in reply } }
    }

    func complete(prompt: String, turn: Int) async throws -> String {
        prompts.append(prompt)
        return try await steps[min(turn, steps.count) - 1](prompt, turn)
    }
}

private actor RecordingCommitter: ContextBuilderDiscoveryCommitter {
    struct Commit {
        let paths: [String]
        let snapshot: ContextBuilderDiscoverySnapshot
    }

    private let failure: ContextBuilderDiscoveryError?
    private let afterCommit: (@Sendable () -> Void)?
    private(set) var commits: [Commit] = []

    init(failure: ContextBuilderDiscoveryError? = nil, afterCommit: (@Sendable () -> Void)? = nil) {
        self.failure = failure
        self.afterCommit = afterCommit
    }

    func commitSelection(
        _ absolutePaths: [String],
        over snapshot: ContextBuilderDiscoverySnapshot
    ) async throws -> ContextBuilderDiscoveryCommitReceipt {
        commits.append(Commit(paths: absolutePaths, snapshot: snapshot))
        if let failure { throw failure }
        afterCommit?()
        return ContextBuilderDiscoveryCommitReceipt(
            applied: true,
            workspaceRevision: snapshot.workspaceRevision + 1,
            contextRevision: snapshot.contextRevision + 1
        )
    }
}

private actor RecordingPackStore: OracleArtifactStore {
    private let onStore: (@Sendable () -> Void)?
    private(set) var artifacts: [String: Data] = [:]

    init(onStore: (@Sendable () -> Void)? = nil) {
        self.onStore = onStore
    }

    func storeArtifact(_ data: Data) async throws -> String {
        let id = DomainContentDigest.sha256(data)
        artifacts[id] = data
        onStore?()
        return id
    }

    func loadArtifact(id: String) async throws -> Data {
        guard let data = artifacts[id] else { throw CocoaError(.fileNoSuchFile) }
        return data
    }
}
