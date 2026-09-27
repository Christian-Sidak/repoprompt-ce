import Foundation

/// A selection-dependent tool could not observe stable selection state (#1071).
///
/// Before this type, an unmet drain prerequisite was thrown as `CancellationError`, which the host
/// saw as a generic cancellation it could not distinguish from a real cancel. Genuine task
/// cancellation still throws `CancellationError`.
enum MCPSelectionPrerequisiteError: Error, Equatable, LocalizedError {
    /// Pending automatic selection has not converged to the UI mirror yet.
    case deferred(MCPReadFileAutoSelectionCoordinator.DrainRequirement)
    /// The bound tab/context changed while pending selection was draining.
    case invalidated(MCPReadFileAutoSelectionCoordinator.DrainRequirement)

    /// Converts a drain outcome into success, a typed prerequisite failure, or cancellation.
    static func require(
        _ result: MCPReadFileAutoSelectionCoordinator.DrainResult,
        _ requirement: MCPReadFileAutoSelectionCoordinator.DrainRequirement
    ) throws {
        switch result {
        case .completed:
            return
        case .cancelled:
            throw CancellationError()
        case .deferred:
            throw MCPSelectionPrerequisiteError.deferred(requirement)
        case .invalidated:
            throw MCPSelectionPrerequisiteError.invalidated(requirement)
        }
    }

    var code: String {
        switch self {
        case .deferred:
            "tool_prerequisite_selection_deferred"
        case .invalidated:
            "tool_prerequisite_selection_invalidated"
        }
    }

    var requirement: MCPReadFileAutoSelectionCoordinator.DrainRequirement {
        switch self {
        case let .deferred(requirement), let .invalidated(requirement):
            requirement
        }
    }

    var errorDescription: String? {
        switch self {
        case .deferred:
            "Pending automatic file selection has not finished applying, so this tool could not read a stable selection. Nothing was changed; retry the call."
        case .invalidated:
            "The bound tab or workspace context changed while pending selection was applying. Nothing was changed; retry the call, or re-bind with bind_context if the target changed."
        }
    }
}
