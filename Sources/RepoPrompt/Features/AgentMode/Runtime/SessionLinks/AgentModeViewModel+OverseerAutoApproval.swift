import Foundation

@MainActor
extension AgentModeViewModel {
    /// One-time provider permission response, never a provider-wide or app-wide permission mode.
    /// The observer's opt-in is checked against the current exact grant by the bridge; this target
    /// session and request are checked again after that actor hop before any response is submitted.
    func autoApproveOverseenProviderPermissions(
        for session: AgentTabSession,
        requestIDs: Set<UUID>
    ) async {
        guard sessions[session.tabID] === session,
              let targetEndpoint = agentSessionLinkObserverEndpoint(tabID: session.tabID),
              await AgentSessionLinkRuntimeBridge.shared.autoApprovalIsAuthorized(for: targetEndpoint),
              sessions[session.tabID] === session,
              agentSessionLinkObserverEndpoint(tabID: session.tabID) == targetEndpoint
        else { return }

        if let request = session.pendingApproval, requestIDs.contains(request.id) {
            let hasController: Bool = switch request.requestID {
            case .codex: session.codexController != nil
            case .claudeControl: session.claudeController != nil
            case .acp: session.acpController != nil
            }
            if hasController {
                submitApprovalDecision(tabID: session.tabID, decision: .accept)
            }
        }
        if let request = session.pendingPermissionsRequest, requestIDs.contains(request.id) {
            codexCoordinator.submitPermissionsDecision(session: session, request: request, decision: .accept)
        }
    }
}
