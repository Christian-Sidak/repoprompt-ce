import Foundation
import RepoPromptDomainRuntime

// Value types for the exact-link **Answer prompts** delegation: an observer agent inspecting and
// explicitly answering its target's current pending interaction through `agent_session_link`.
//
// Authority is layered and every layer is required:
// 1. the exact outbound grant (`authorizeTarget` lease plus live endpoint revalidation),
// 2. the user's per-exact-link Answer prompts opt-in (process-local, generation-qualified),
// 3. the target's exact current `interaction_id` (compare-and-set before and after the final
//    authority hop, with the submission made synchronously after the last check).
//
// Nothing here answers anything automatically. Provider permission auto-approval is a separate,
// independent opt-in that never reaches questions or elicitations.

/// Why a pending interaction can be inspected but only answered by the target's own user.
enum AgentSessionLinkInteractionManualOnlyReason: String, Equatable {
    /// Codex project-hook trust is persistent project state, not a one-request decision.
    case hookApproval = "hook_approval"
    /// App-owned worktree merge reviews mutate another worktree and stay with the local user.
    case worktreeMergeReview = "worktree_merge_review"
    /// A field marked secret (for example a credential) is never supplied by another session.
    case secretInput = "secret_input"
    /// MCP-controlled instruction prompts are answered by their controller, not by oversight.
    case instructionPrompt = "instruction_prompt"
    /// Session-wide or policy-amending approvals widen authority beyond this one request.
    case persistentDecision = "persistent_decision"
    /// An ACP provider offered no genuine one-time allow option for this request.
    case noOneTimeAllowOption = "no_one_time_allow_option"
}

/// What the observer sees for one target's current pending interaction.
struct AgentSessionLinkPendingInteractionInspection: Equatable {
    /// Redacted interaction, restricted to the options an observer may choose. `nil` when the
    /// target has no pending interaction.
    let interaction: AgentRunMCPSnapshot.Interaction?
    /// Non-nil when the pending interaction exists but only the target's user may answer it.
    let manualOnlyReason: AgentSessionLinkInteractionManualOnlyReason?

    static let none = AgentSessionLinkPendingInteractionInspection(interaction: nil, manualOnlyReason: nil)
}

/// One explicit answer an observer asked RepoPrompt to submit on the target's behalf.
struct AgentSessionLinkInteractionResponseRequest: Equatable {
    let interactionID: UUID
    let payload: AgentModeViewModel.MCPInteractionResponsePayload
}

/// Host-level result of one respond attempt. Every case except `.submitted` applied nothing.
enum AgentSessionLinkInteractionResponseOutcome: Equatable {
    case submitted(kind: AgentRunMCPSnapshot.Interaction.Kind, decision: String?)
    case noPendingInteraction
    case interactionMismatch(currentInteractionID: UUID)
    case manualOnly(AgentSessionLinkInteractionManualOnlyReason)
    /// The answer did not fit the interaction; the message says why. Nothing was applied.
    case invalid(String)
    /// The target endpoint, grant, or delegation stopped holding before submission.
    case unavailable
}

/// Bridge-level result: the delegation gate plus whatever the host reported.
enum AgentSessionLinkInteractionDisposition: Equatable {
    case notEnabled
    case denied
    case shuttingDown
    case inspected(AgentSessionLinkPendingInteractionInspection)
    case responded(AgentSessionLinkInteractionResponseOutcome)
}
