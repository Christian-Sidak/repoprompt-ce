import Combine
import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    @MainActor
    final class DomainWorkspaceProjectionObserver {
        private let bridge: DomainWorkspacePresentationBridge
        private(set) var pendingWaiterCount = 0

        init(bridge: DomainWorkspacePresentationBridge) {
            self.bridge = bridge
        }

        func waitForProjection(
            afterGeneration: UInt64,
            through publicationSequence: UInt64 = 0,
            timeout: Duration = .seconds(5)
        ) async -> DomainWorkspacePresentationBridge.ProjectionCheckpoint? {
            let ticket = WaitTicket(
                afterGeneration: afterGeneration,
                publicationSequence: publicationSequence
            )
            return await withTaskCancellationHandler {
                if Task.isCancelled {
                    ticket.finish(with: nil)
                    return nil
                }

                register(ticket)
                guard !ticket.isTerminal else { return ticket.result }

                let waitResult = await XCTWaiter.fulfillment(
                    of: [ticket.expectation],
                    timeout: Self.timeInterval(for: timeout)
                )
                if waitResult != .completed {
                    ticket.finish(with: nil)
                    return nil
                }
                return ticket.result
            } onCancel: {
                Task { @MainActor [weak ticket] in
                    ticket?.finish(with: nil)
                }
            }
        }

        private func register(_ ticket: WaitTicket) {
            let state = bridge.projectionObservationStateForTesting
            guard let runID = state.runID, !Task.isCancelled else {
                ticket.finish(with: nil)
                return
            }
            ticket.runID = runID
            if let checkpoint = state.checkpoint, ticket.isSatisfied(by: checkpoint) {
                ticket.finish(with: checkpoint)
                return
            }

            pendingWaiterCount += 1
            ticket.didFinish = { [weak self] in
                guard let self else { return }
                pendingWaiterCount -= 1
            }
            ticket.token = bridge.projectionObservationPublisherForTesting.sink { [weak ticket] event in
                guard let ticket else { return }
                switch event {
                case let .applied(checkpoint) where ticket.isSatisfied(by: checkpoint):
                    ticket.finish(with: checkpoint)
                case let .stopped(stoppedRunID) where stoppedRunID == ticket.runID:
                    ticket.finish(with: nil)
                case .applied, .stopped:
                    break
                }
            }
        }

        private static func timeInterval(for duration: Duration) -> TimeInterval {
            let components = duration.components
            return TimeInterval(components.seconds)
                + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
        }

        @MainActor
        private final class WaitTicket {
            let expectation = XCTestExpectation(description: "domain workspace projection observed")
            let afterGeneration: UInt64
            let publicationSequence: UInt64
            var runID: UUID?
            var token: AnyCancellable?
            var result: DomainWorkspacePresentationBridge.ProjectionCheckpoint?
            var isTerminal = false
            var didFinish: (() -> Void)?

            init(afterGeneration: UInt64, publicationSequence: UInt64) {
                self.afterGeneration = afterGeneration
                self.publicationSequence = publicationSequence
            }

            func isSatisfied(by checkpoint: DomainWorkspacePresentationBridge.ProjectionCheckpoint) -> Bool {
                checkpoint.runID == runID
                    && checkpoint.generation > afterGeneration
                    && checkpoint.publicationSequence >= publicationSequence
            }

            func finish(with checkpoint: DomainWorkspacePresentationBridge.ProjectionCheckpoint?) {
                guard !isTerminal else { return }
                isTerminal = true
                result = checkpoint
                token?.cancel()
                token = nil
                let completion = didFinish
                didFinish = nil
                completion?()
                expectation.fulfill()
            }
        }
    }

    extension DomainWorkspacePresentationBridge {
        func waitUntilProjected(
            through publicationSequence: UInt64,
            timeout: Duration = .seconds(5)
        ) async -> Bool {
            let observer = DomainWorkspaceProjectionObserver(bridge: self)
            return await observer.waitForProjection(
                afterGeneration: 0,
                through: publicationSequence,
                timeout: timeout
            ) != nil
        }
    }
#endif
