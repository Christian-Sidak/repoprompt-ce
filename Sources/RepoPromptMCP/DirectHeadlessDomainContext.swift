import Foundation
import MCP
import RepoPromptDomainRuntime

actor DirectHeadlessDomainContext {
    struct SessionRootOverlayPreparation {
        let sessionID: UUID
        let resolvedOverlay: DirectHeadlessRootOverlay
        let previousOverlay: DirectHeadlessRootOverlay?
        let bindings: [DomainAgentRunSnapshot.WorktreeBinding]
    }

    enum Error: Swift.Error, LocalizedError {
        case routingUnavailable
        case workspaceUnavailable
        case contextUnavailable
        case rootMappingUnavailable
        case invalidWorkspaceDocument
        case stateConflict(String)
        case pathOutsideWorkspace(String)
        /// The launch this connection was started under has ended; its root authority is gone.
        case launchRootAuthorityReleased
        /// This launch's root authority no longer matches the workspace (for example, an external
        /// writer replaced the roots after the launch); nothing is resolved against other roots.
        case launchRootAuthorityChanged(String)

        var errorDescription: String? {
            switch self {
            case .routingUnavailable: "Standalone connection is not bound to a context"
            case .workspaceUnavailable: "Bound workspace is unavailable"
            case .contextUnavailable: "Bound context is unavailable"
            case .rootMappingUnavailable: "Direct-headless root mapping is incomplete or ambiguous"
            case .invalidWorkspaceDocument: "Workspace document is invalid"
            case let .stateConflict(reason): "Workspace state conflict: \(reason)"
            case let .pathOutsideWorkspace(path): "Path is outside the bound workspace roots: \(path)"
            case .launchRootAuthorityReleased:
                "launch_root_authority_released: the provider launch this connection belongs to has ended"
            case let .launchRootAuthorityChanged(reason):
                "launch_root_authority_changed: \(reason); this launch's roots are not resolved against other roots"
            }
        }
    }

    enum ContextMutation {
        case setPrompt(String)
        case setSelection([String])
    }

    struct Snapshot {
        let identity: DomainContextIdentity
        let workspace: DomainWorkspaceSnapshot
        let context: DomainContextSnapshot
        let rootOverlay: DirectHeadlessRootOverlay
        let prompt: String
        let selection: [String]

        var canonicalRoots: [URL] {
            rootOverlay.mappings.map(\.canonicalRoot)
        }

        var roots: [URL] {
            rootOverlay.mappings.map(\.physicalRoot)
        }

        var activeRoot: URL? {
            rootOverlay.activeRoot
        }
    }

    let runtime: MCPDomainRuntime
    let scopeID: DomainStandaloneScopeID
    private let processRootOverlay: DirectHeadlessRootOverlay
    private var sessionRootOverlays: [UUID: DirectHeadlessRootOverlay] = [:]
    /// Launch-scoped root authorities, root-mutation claims, leased child connections, and their
    /// in-flight invocations (M21, every carrier-bearing launch since M22). Synchronous, so the
    /// host's provider entry/return callbacks can hold a lease's root exclusion for exactly the life
    /// of a child invocation.
    nonisolated let launchRoots = DirectHeadlessLaunchRootRegistry()

    init(
        runtime: MCPDomainRuntime,
        scopeID: DomainStandaloneScopeID,
        processRootOverlay: DirectHeadlessRootOverlay = .init(mappings: [], activeRoot: nil)
    ) {
        self.runtime = runtime
        self.scopeID = scopeID
        self.processRootOverlay = processRootOverlay
    }

    func snapshot(for request: DomainPhysicalToolRequest) async throws -> Snapshot {
        guard let securityContext = request.securityContext else { throw Error.routingUnavailable }
        return try await snapshot(
            connectionID: securityContext.connectionID,
            sessionID: securityContext.principal.runID
        )
    }

    func snapshot(for request: DomainPhysicalReadRequest) async throws -> Snapshot {
        if let handle = request.context.handle {
            return try await snapshot(
                identity: handle.context,
                sessionID: request.request.securityContext?.principal.runID,
                connectionID: handle.connectionID
            )
        }
        guard let connectionID = request.context.connectionID else { throw Error.routingUnavailable }
        return try await snapshot(
            connectionID: connectionID,
            sessionID: request.request.securityContext?.principal.runID
        )
    }

    func snapshot(connectionID: UUID, sessionID: UUID? = nil) async throws -> Snapshot {
        let handle = try await resolvedHandle(connectionID: connectionID)
        return try await snapshot(identity: handle.context, sessionID: sessionID, connectionID: connectionID)
    }

    private func resolvedHandle(connectionID: UUID) async throws -> DomainReadContextHandle {
        let registration = try await runtime.routingCoordinator.currentRegistration(connectionID: connectionID)
        return try await runtime.routingCoordinator.resolveReadContext(connection: registration)
    }

    /// `identity` as `connectionID` reads it: through the connection's launch-scoped root authority
    /// when it is a launched child's connection, else with the session's (or process's) live overlay.
    private func snapshot(
        identity: DomainContextIdentity,
        sessionID: UUID?,
        connectionID: UUID?
    ) async throws -> Snapshot {
        guard let connectionID else { return try await snapshot(identity: identity, sessionID: sessionID) }
        switch launchRoots.lookup(connectionID: connectionID) {
        case .unleased:
            return try await snapshot(identity: identity, sessionID: sessionID)
        case .released:
            throw Error.launchRootAuthorityReleased
        case let .active(lease):
            return try await leasedSnapshot(lease, context: identity)
        }
    }

    /// A leased connection's view: the lease's context, canonical roots, and physical overlay. It
    /// never falls back to live resolution: a released lease or drifted roots fail closed.
    private func leasedSnapshot(
        _ lease: DirectHeadlessLaunchRootLease,
        context: DomainContextIdentity
    ) async throws -> Snapshot {
        guard context == lease.context else {
            throw Error.launchRootAuthorityChanged("the connection no longer resolves to the launch's context")
        }
        let snapshot = try await snapshot(identity: lease.context, sessionID: nil, lease: lease)
        // Released while it was read: nothing read under it may be served.
        guard launchRoots.isActive(lease) else { throw Error.launchRootAuthorityReleased }
        return snapshot
    }

    // MARK: - Launch-scoped root authority (M21, every carrier-bearing launch since M22)

    /// Acquires the root authority `lane` launches under, or throws
    /// `DomainChildLaunchContextPin.Mismatch` and nothing may be launched.
    ///
    /// The lease is registered, pending, before anything is read. From then on a roots change made
    /// through `withRootMutationClaim`, or an overlay change for the lease's session, is refused
    /// instead of landing under the launch; a claim already in flight refuses the launch
    /// (`rootsChanging`). Then:
    ///
    /// - the connection must resolve to the lane's context: exactly the pin (context and revisions)
    ///   for a discovered lane, the context its carrier's token was minted for otherwise (`rebound`);
    /// - a launching connection that is itself a leased child must still hold an active authority
    ///   over the live canonical roots;
    /// - the pinned context must still be at the pinned revisions (discovered lanes only);
    /// - the physical roots the launch resolves through `sessionID`'s overlay must be the step's
    ///   roots (`DirectHeadlessLaunchAuthority.admitRoots`: the committed roots, or those of the
    ///   step's first lane);
    /// - the connection must still resolve to the lane's context after those reads.
    ///
    /// Only then is the lease active. The caller releases it when the process exits or if it never
    /// starts.
    func acquireLaunchRootLease(
        _ lane: DirectHeadlessLaunchAuthority.Lane,
        kind: DirectHeadlessLaunchRootRegistry.Holder.Kind,
        connectionID: UUID,
        sessionID: UUID?
    ) async throws -> DirectHeadlessLaunchRootLease {
        typealias Mismatch = DomainChildLaunchContextPin.Mismatch
        let carrier = lane.carrier
        // The lease's context is the one the carrier's token redeems to, so the two cannot differ.
        guard let context = lane.context, carrier.context.map({ $0 == context }) ?? true else {
            throw Mismatch.contextUnavailable
        }
        let leaseID = UUID()
        switch launchRoots.registerPending(
            launchID: carrier.launchID,
            leaseID: leaseID,
            holder: .init(context: context, runID: carrier.runID, launchID: carrier.launchID, kind: kind),
            overlaySessionID: sessionID
        ) {
        case .registered:
            break
        case .duplicateLaunch:
            throw Error.stateConflict("launch \(carrier.launchID.uuidString) already holds a root authority")
        case .rootsChanging:
            throw Mismatch.rootsChanging
        }
        do {
            try await Self.requireLaneContext(lane, context: context, resolvedHandle(connectionID: connectionID))
            let snapshot = try await launchSnapshot(identity: context, sessionID: sessionID, connectionID: connectionID)
            if let pin = lane.authority.pin {
                guard snapshot.context.revisions.workingRevision == pin.contextRevision else {
                    throw Mismatch.contextRevisionChanged(
                        expected: pin.contextRevision,
                        actual: snapshot.context.revisions.workingRevision
                    )
                }
                guard snapshot.workspace.revisions.workingRevision == pin.workspaceRevision else {
                    throw Mismatch.workspaceRevisionChanged(
                        expected: pin.workspaceRevision,
                        actual: snapshot.workspace.revisions.workingRevision
                    )
                }
            }
            try lane.authority.admitRoots(snapshot.roots.map(\.path))
            // Revalidated after the reads: the connection still resolves to the lane's context.
            try await Self.requireLaneContext(lane, context: context, resolvedHandle(connectionID: connectionID))
            let lease = try DirectHeadlessLaunchRootLease(
                leaseID: leaseID,
                launchID: carrier.launchID,
                runID: carrier.runID,
                launchTokenID: carrier.launchTokenID,
                context: context,
                canonicalRoots: Self.canonicalRoots(of: snapshot.workspace).map(\.path),
                rootOverlay: snapshot.rootOverlay,
                overlaySessionID: sessionID
            )
            guard launchRoots.activate(lease) else { throw CancellationError() }
            return lease
        } catch {
            launchRoots.abandonPending(launchID: carrier.launchID, leaseID: leaseID)
            throw Self.launchRefusal(error)
        }
    }

    /// A discovered lane's connection must resolve to exactly its pin; any other lane's to the
    /// context its carrier's token was minted for.
    private static func requireLaneContext(
        _ lane: DirectHeadlessLaunchAuthority.Lane,
        context: DomainContextIdentity,
        _ handle: DomainReadContextHandle
    ) throws {
        if let pin = lane.authority.pin {
            try pin.validate(handle)
        } else if handle.context != context {
            throw DomainChildLaunchContextPin.Mismatch.rebound(current: handle.context)
        }
    }

    /// The roots a launch from `connectionID` runs in: `identity` through `sessionID`'s overlay (or
    /// the process's). A launching connection that is itself a leased child (an agent starting a
    /// sub-agent or an Oracle) must still hold an active authority whose canonical roots are the
    /// live ones, so the launch's canonical roots are its launcher's. Its physical roots come from
    /// its own session's overlay: the launcher's (inherited by default) or an explicitly selected
    /// existing linked worktree of those canonical roots, fixed for the new launch by its own lease.
    private func launchSnapshot(
        identity: DomainContextIdentity,
        sessionID: UUID?,
        connectionID: UUID
    ) async throws -> Snapshot {
        switch launchRoots.lookup(connectionID: connectionID) {
        case .unleased:
            break
        case .released:
            throw Error.launchRootAuthorityReleased
        case let .active(parent):
            _ = try await leasedSnapshot(parent, context: identity)
        }
        return try await snapshot(identity: identity, sessionID: sessionID, lease: nil)
    }

    /// Ends `lease` when its process exited (idempotent) and revokes its launch token (the lease owns
    /// it from acquisition on), so a token never redeemed by the exited process cannot admit a
    /// connection later. From here the
    /// lease admits no new child invocation and resolves no new snapshot (attached connections fail
    /// closed with `launchRootAuthorityReleased`), but its root exclusion lasts until every child
    /// invocation that entered under it has settled, so no write captured under it can land after
    /// a roots change.
    func releaseLaunchRootLease(_ lease: DirectHeadlessLaunchRootLease) async {
        guard launchRoots.release(lease) else { return }
        await runtime.routingCoordinator.revokeLaunchToken(lease.launchTokenID)
    }

    /// Binds a child connection that redeemed a launch-scoped-roots token to its launch's active
    /// lease; throws (the connection must be refused) when there is none for that run and context.
    func attachLaunchConnection(_ connectionID: UUID, redemption: DomainRunLaunchRedemption) throws {
        guard case let .runScoped(runID, context) = redemption.binding.binding,
              launchRoots.attach(
                  connectionID: connectionID,
                  launchID: redemption.launchID,
                  runID: runID,
                  context: context
              )
        else {
            throw Error.launchRootAuthorityReleased
        }
    }

    /// The connection closed; it is forgotten once its in-flight invocations settled.
    func detachLaunchConnection(_ connectionID: UUID) {
        launchRoots.detach(connectionID: connectionID)
    }

    /// Runs `body` (a workspace-roots change, or with `contextID` the removal of one context) under
    /// a root-mutation claim. A launch holding or validating a root authority over the same roots
    /// refuses it with a typed, retryable `root_authority_leased` failure before anything is
    /// written; while the claim is held, launches over those roots are refused instead.
    func withRootMutationClaim<T: Sendable>(
        toolName: String,
        workspaceID: UUID,
        contextID: UUID? = nil,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        let claimID: UUID
        switch launchRoots.claim(workspaceID: workspaceID, contextID: contextID) {
        case let .success(id):
            claimID = id
        case let .failure(conflict):
            throw Self.rootAuthorityLeased(toolName: toolName, holder: conflict.holder)
        }
        defer { launchRoots.endClaim(claimID) }
        return try await body()
    }

    /// Live launch-root leases, claims, leased connections, and in-flight child invocations
    /// (validation and diagnostics).
    nonisolated func launchRootAuthorityCounts() -> DirectHeadlessLaunchRootRegistry.Counts {
        launchRoots.counts()
    }

    private static func rootAuthorityLeased(
        toolName: String,
        holder: DirectHeadlessLaunchRootRegistry.Holder
    ) -> MCPDomainToolFailure {
        let launch = switch holder.kind {
        case .agent: "agent"
        case .oracle: "Oracle"
        }
        return MCPDomainToolFailure(
            toolName: toolName,
            code: "root_authority_leased",
            message: "A running \(launch) launch holds the roots of context \(holder.context.contextID.uuidString) "
                + "until its process exits and its in-flight child calls settle; nothing was changed. "
                + "Retry once it has ended.",
            retryability: .retryable,
            mutationState: DomainProtectedMutationState.notApplied.rawValue,
            details: [
                "workspace_id": .string(holder.context.workspaceID.uuidString),
                "context_id": .string(holder.context.contextID.uuidString),
                "run_id": .string(holder.runID.uuidString),
                "launch_id": .string(holder.launchID.uuidString),
                "launch_kind": .string(holder.kind.rawValue)
            ]
        )
    }

    /// Every refusal of a launch before its process starts is a typed launch-context mismatch;
    /// cancellation and unrelated failures pass through.
    private static func launchRefusal(_ error: Swift.Error) -> Swift.Error {
        typealias Mismatch = DomainChildLaunchContextPin.Mismatch
        if error is Mismatch || error is CancellationError { return error }
        if error is DomainReadContextResolutionError { return Mismatch.contextUnavailable }
        if let error = error as? Error {
            switch error {
            case .workspaceUnavailable, .contextUnavailable, .invalidWorkspaceDocument, .routingUnavailable:
                return Mismatch.contextUnavailable
            case .rootMappingUnavailable:
                return Mismatch.rootsUnavailable("the worktree root mapping is incomplete or ambiguous")
            case .launchRootAuthorityReleased, .launchRootAuthorityChanged:
                return Mismatch.rootsUnavailable(error.errorDescription ?? "launch root authority unavailable")
            case .stateConflict, .pathOutsideWorkspace:
                return error
            }
        }
        if case let DomainStandaloneScopeError.invalidWorkingDirectory(path)? = error as? DomainStandaloneScopeError {
            return Mismatch.rootsUnavailable("\(path) is not a directory")
        }
        if error is MCPError {
            // Worktree identity verification at use.
            return Mismatch.rootsUnavailable((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
        return error
    }

    private nonisolated static func canonicalRoots(of workspace: DomainWorkspaceSnapshot) throws -> [URL] {
        try workspace.document.metadata.repoPaths.map { raw -> URL in
            let url = URL(fileURLWithPath: raw).standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw DomainStandaloneScopeError.invalidWorkingDirectory(raw)
            }
            return url
        }
    }

    func snapshot(identity: DomainContextIdentity, sessionID: UUID? = nil) async throws -> Snapshot {
        try await snapshot(identity: identity, sessionID: sessionID, lease: nil)
    }

    /// With `lease`, the roots and overlay are the lease's (the live canonical roots must still be
    /// the lease's); without, they are resolved from the session's (or process's) live overlay.
    private func snapshot(
        identity: DomainContextIdentity,
        sessionID: UUID?,
        lease: DirectHeadlessLaunchRootLease?
    ) async throws -> Snapshot {
        guard let workspace = await runtime.contextStore.workspaceSnapshot(identity.workspaceID) else {
            throw Error.workspaceUnavailable
        }
        guard let context = workspace.contexts.first(where: { $0.metadata.identity == identity }) else {
            throw Error.contextUnavailable
        }
        let canonicalRoots = try Self.canonicalRoots(of: workspace)
        let rootOverlay: DirectHeadlessRootOverlay
        if let lease {
            guard canonicalRoots.map(\.path) == lease.canonicalRoots else {
                throw Error.launchRootAuthorityChanged("the workspace roots changed after the launch")
            }
            try await DirectHeadlessWorktreeRouting.verifyMappingsAtUse(lease.rootOverlay.mappings)
            rootOverlay = lease.rootOverlay
        } else {
            rootOverlay = try await resolveRootOverlay(
                canonicalRoots: canonicalRoots,
                sessionID: sessionID
            )
        }
        for mapping in rootOverlay.mappings {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: mapping.physicalRoot.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                throw DomainStandaloneScopeError.invalidWorkingDirectory(mapping.physicalRoot.path)
            }
        }
        let contextObject = try Self.contextObject(from: workspace, contextID: identity.contextID)
        let prompt = contextObject["prompt"] as? String ?? ""
        let selection = contextObject["selectedPaths"] as? [String]
            ?? contextObject["selection"] as? [String]
            ?? []
        return Snapshot(
            identity: identity,
            workspace: workspace,
            context: context,
            rootOverlay: rootOverlay,
            prompt: prompt,
            selection: Self.translateSelectionToPhysical(selection, mappings: rootOverlay.mappings)
        )
    }

    func prepareSessionRootOverlay(
        sessionID: UUID,
        sourceSessionID: UUID?,
        arguments: [String: Value],
        connectionID: UUID
    ) async throws -> SessionRootOverlayPreparation {
        let processSnapshot = try await snapshot(connectionID: connectionID)
        let inherits = try Self.parseOptionalBool(
            arguments["inherit_worktree"],
            name: "inherit_worktree"
        ) ?? true
        let selectorIntent = try DirectHeadlessWorktreeRouting.parseSessionSelector(arguments: arguments)
        let inheritedOverlay = inherits
            ? sourceSessionID.flatMap { sessionRootOverlays[$0] }
            : nil
        let baseOverlay = inheritedOverlay ?? processSnapshot.rootOverlay
        let resolved = try await DirectHeadlessWorktreeRouting.resolveSessionOverlay(
            arguments: arguments,
            selectorIntent: selectorIntent,
            canonicalRoots: processSnapshot.canonicalRoots,
            baseOverlay: baseOverlay
        )
        // A pinned launch resolved (or is resolving) its roots from this session's overlay: the
        // overlay cannot move under it.
        if let holder = launchRoots.overlayHolder(sessionID: sessionID) {
            throw Self.rootAuthorityLeased(toolName: "agent_run", holder: holder)
        }
        let previousOverlay = sessionRootOverlays.updateValue(resolved, forKey: sessionID)
        let isUnmodifiedInheritance = inheritedOverlay != nil
            && selectorIntent.selector == nil
            && selectorIntent.worktreeID == nil
            && !selectorIntent.create
        let bindingSource = isUnmodifiedInheritance
            ? "direct-headless-inherited-overlay"
            : "direct-headless-session-overlay"
        let bindings = resolved.mappings.compactMap {
            DirectHeadlessWorktreeRouting.binding(mapping: $0, source: bindingSource)
        }
        return SessionRootOverlayPreparation(
            sessionID: sessionID,
            resolvedOverlay: resolved,
            previousOverlay: previousOverlay,
            bindings: bindings
        )
    }

    func rollbackSessionRootOverlay(_ preparation: SessionRootOverlayPreparation) {
        guard sessionRootOverlays[preparation.sessionID] == preparation.resolvedOverlay else { return }
        if let previousOverlay = preparation.previousOverlay {
            sessionRootOverlays[preparation.sessionID] = previousOverlay
        } else {
            sessionRootOverlays.removeValue(forKey: preparation.sessionID)
        }
    }

    func validateBinding(_ identity: DomainContextIdentity) async throws {
        _ = try await snapshot(identity: identity)
    }

    func validateWorkspaceRoots(_ rawRoots: [String]) async throws {
        let canonicalRoots = try rawRoots.map { raw -> URL in
            let url = URL(fileURLWithPath: raw).standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw DomainStandaloneScopeError.invalidWorkingDirectory(raw)
            }
            return url
        }
        _ = try await resolveRootOverlay(canonicalRoots: canonicalRoots, sessionID: nil)
    }

    private func resolveRootOverlay(
        canonicalRoots: [URL],
        sessionID: UUID?
    ) async throws -> DirectHeadlessRootOverlay {
        let preferred = sessionID.flatMap { sessionRootOverlays[$0] } ?? processRootOverlay
        let mappings: [DirectHeadlessRootMapping]
        let activeRoot: URL?
        if preferred.mappings.isEmpty {
            mappings = canonicalRoots.map {
                DirectHeadlessRootMapping(
                    canonicalRoot: $0,
                    physicalRoot: $0,
                    worktree: nil,
                    visualLabel: nil,
                    visualColorHex: nil
                )
            }
            activeRoot = mappings.first?.physicalRoot
        } else {
            guard preferred.mappings.count == canonicalRoots.count else { throw Error.rootMappingUnavailable }
            var physicalPaths: Set<String> = []
            mappings = try canonicalRoots.map { canonicalRoot in
                let matches = preferred.mappings.filter {
                    $0.canonicalRoot.standardizedFileURL.resolvingSymlinksInPath().path == canonicalRoot.path
                }
                guard matches.count == 1, let match = matches.first,
                      physicalPaths.insert(match.physicalRoot.path).inserted
                else { throw Error.rootMappingUnavailable }
                return match
            }
            activeRoot = preferred.activeRoot?.standardizedFileURL.resolvingSymlinksInPath()
            guard activeRoot.map({ physicalPaths.contains($0.path) }) == !mappings.isEmpty else {
                throw Error.rootMappingUnavailable
            }
        }
        try await DirectHeadlessWorktreeRouting.verifyMappingsAtUse(mappings)
        return DirectHeadlessRootOverlay(mappings: mappings, activeRoot: activeRoot)
    }

    func mutate(
        request: DomainPhysicalToolRequest,
        mutation: ContextMutation
    ) async throws -> Snapshot {
        let current = try await snapshot(for: request)
        guard var document = try JSONSerialization.jsonObject(
            with: current.workspace.document.documentBytes
        ) as? [String: Any],
            var contexts = document["composeTabs"] as? [[String: Any]],
            let index = contexts.firstIndex(where: { ($0["id"] as? String) == current.identity.contextID.uuidString })
        else {
            throw Error.invalidWorkspaceDocument
        }
        switch mutation {
        case let .setPrompt(prompt):
            contexts[index]["prompt"] = prompt
        case let .setSelection(paths):
            contexts[index]["selectedPaths"] = try Self.translateSelectionToCanonical(
                paths,
                mappings: current.rootOverlay.mappings
            )
        }
        document["composeTabs"] = contexts
        let bytes = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        let replacement = try DomainWorkspaceDocument.decode(
            documentBytes: bytes,
            fileURL: current.workspace.document.fileURL
        )
        try await MCPDomainMutationCommitContext.willCommit()
        let operationID = request.securityContext?.invocationID ?? UUID()
        let outcome = await runtime.workspaceStore.execute(DomainWorkspaceCommandEnvelope(
            operationID: operationID,
            expectedCatalogRevision: nil,
            expectedWorkspaceRevision: current.workspace.revisions.workingRevision,
            expectedContextRevision: current.context.revisions.workingRevision,
            origin: .standalone,
            command: .replaceWorkingDocument(replacement)
        ))
        guard outcome.disposition == .applied
            || outcome.disposition == .unchanged
            || outcome.disposition == .deduplicated
        else {
            throw Error.stateConflict(outcome.diagnostic ?? outcome.errorCode?.rawValue ?? outcome.disposition.rawValue)
        }
        return try await snapshot(
            identity: current.identity,
            sessionID: request.securityContext?.principal.runID,
            connectionID: request.securityContext?.connectionID
        )
    }

    /// Freezes the context bound to `request` for one Context Builder discovery run.
    func discoverySnapshot(for request: DomainPhysicalToolRequest) async throws -> ContextBuilderDiscoverySnapshot {
        try await discoveryFreeze(for: request).snapshot
    }

    /// The frozen discovery snapshot plus the active root of the same resolution: the working
    /// directory of discovery's provider turns, so a turn's process never runs in roots other than
    /// the ones its protocol tools read.
    func discoveryFreeze(
        for request: DomainPhysicalToolRequest
    ) async throws -> (snapshot: ContextBuilderDiscoverySnapshot, workingDirectory: URL?) {
        let current = try await snapshot(for: request)
        let frozen = ContextBuilderDiscoverySnapshot(
            identity: current.identity,
            workspaceRevision: current.workspace.revisions.workingRevision,
            contextRevision: current.context.revisions.workingRevision,
            roots: current.roots,
            prompt: current.prompt,
            selection: current.selection
        )
        return (frozen, current.activeRoot)
    }

    /// Compare-and-set commit of a discovered selection. It writes only when the connection is still
    /// bound to the frozen context, the physical roots are unchanged, and neither the workspace nor
    /// the context revision moved since the freeze; the store enforces the same revisions again.
    /// Every refusal is `ContextBuilderDiscoveryError.contextChanged` and writes nothing.
    func commitDiscoveredSelection(
        _ absolutePaths: [String],
        over frozen: ContextBuilderDiscoverySnapshot,
        request: DomainPhysicalToolRequest
    ) async throws -> ContextBuilderDiscoveryCommitReceipt {
        let current: Snapshot
        do {
            current = try await snapshot(for: request)
        } catch {
            throw ContextBuilderDiscoveryError.contextChanged(
                "the bound context is no longer available: \(error.localizedDescription)"
            )
        }
        guard current.identity == frozen.identity else {
            throw ContextBuilderDiscoveryError.contextChanged("the connection is now bound to a different context")
        }
        guard current.roots.map(\.path) == frozen.roots.map(\.path) else {
            throw ContextBuilderDiscoveryError.contextChanged("the workspace roots changed")
        }
        guard current.workspace.revisions.workingRevision == frozen.workspaceRevision,
              current.context.revisions.workingRevision == frozen.contextRevision
        else {
            throw ContextBuilderDiscoveryError.contextChanged("the bound context was modified")
        }
        guard var document = try JSONSerialization.jsonObject(
            with: current.workspace.document.documentBytes
        ) as? [String: Any],
            var contexts = document["composeTabs"] as? [[String: Any]],
            let index = contexts.firstIndex(where: { ($0["id"] as? String) == current.identity.contextID.uuidString })
        else {
            throw Error.invalidWorkspaceDocument
        }
        let canonicalPaths = try Self.translateSelectionToCanonical(
            absolutePaths,
            mappings: current.rootOverlay.mappings
        )
        let storedPaths = contexts[index]["selectedPaths"] as? [String] ?? contexts[index]["selection"] as? [String]
        if storedPaths == canonicalPaths {
            // Already exactly this selection: a context-scoped replacement would change no context.
            return ContextBuilderDiscoveryCommitReceipt(
                applied: false,
                workspaceRevision: frozen.workspaceRevision,
                contextRevision: frozen.contextRevision
            )
        }
        contexts[index]["selectedPaths"] = canonicalPaths
        document["composeTabs"] = contexts
        let bytes = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        let replacement = try DomainWorkspaceDocument.decode(
            documentBytes: bytes,
            fileURL: current.workspace.document.fileURL
        )
        try await MCPDomainMutationCommitContext.willCommit()
        // `failClosed`: a concurrent durable writer (another process) wins; the captured document is
        // never replayed over it without the expected revisions.
        let outcome = await runtime.workspaceStore.execute(DomainWorkspaceCommandEnvelope(
            operationID: request.securityContext?.invocationID ?? UUID(),
            expectedCatalogRevision: nil,
            expectedWorkspaceRevision: frozen.workspaceRevision,
            expectedContextRevision: frozen.contextRevision,
            conflictRecoveryPolicy: .failClosed,
            origin: .standalone,
            command: .replaceWorkingDocument(replacement)
        ))
        guard outcome.disposition == .applied || outcome.disposition == .deduplicated else {
            throw ContextBuilderDiscoveryError.contextChanged(
                outcome.diagnostic ?? outcome.errorCode?.rawValue ?? outcome.disposition.rawValue
            )
        }
        // Nothing after the store command may throw: the selection is committed.
        let committedContext = outcome.workspace?.contexts.first { $0.metadata.identity == frozen.identity }
        return ContextBuilderDiscoveryCommitReceipt(
            applied: true,
            workspaceRevision: outcome.workspace?.revisions.workingRevision
                ?? outcome.after?.workingRevision
                ?? frozen.workspaceRevision,
            contextRevision: committedContext?.revisions.workingRevision ?? frozen.contextRevision
        )
    }

    nonisolated static func resolvePath(_ rawPath: String, roots: [URL], allowMissingLeaf: Bool = false) throws -> URL {
        guard !rawPath.contains("\0") else {
            throw Error.pathOutsideWorkspace(rawPath)
        }
        guard !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPError.invalidParams("path must not be empty")
        }
        let candidate: URL
        if rawPath.hasPrefix("/") {
            candidate = URL(fileURLWithPath: rawPath)
        } else if roots.count == 1, let root = roots.first {
            candidate = root.appendingPathComponent(rawPath)
        } else {
            let matches = roots.map { $0.appendingPathComponent(rawPath) }.filter {
                FileManager.default.fileExists(atPath: $0.path)
            }
            guard matches.count == 1, let match = matches.first else {
                throw MCPError.invalidParams("Relative path is ambiguous across workspace roots")
            }
            candidate = match
        }
        let standardized = candidate.standardizedFileURL
        let checked = allowMissingLeaf
            ? standardized.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(standardized.lastPathComponent)
            : standardized.resolvingSymlinksInPath()
        // `resolvingSymlinksInPath()` strips a leading `/private`, so a root spelled
        // `/private/var/...` must also be matched by its resolved spelling.
        guard roots.contains(where: { root in
            [root.path, root.resolvingSymlinksInPath().path].contains { rootPath in
                checked.path == rootPath || checked.path.hasPrefix(rootPath + "/")
            }
        }) else {
            throw Error.pathOutsideWorkspace(rawPath)
        }
        return checked
    }

    nonisolated func resolvePath(_ rawPath: String, roots: [URL], allowMissingLeaf: Bool = false) throws -> URL {
        try Self.resolvePath(rawPath, roots: roots, allowMissingLeaf: allowMissingLeaf)
    }

    private static func parseOptionalBool(_ value: Value?, name: String) throws -> Bool? {
        guard let value else { return nil }
        switch value {
        case .null:
            return nil
        case let .bool(boolValue):
            return boolValue
        case let .string(stringValue):
            switch stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes":
                return true
            case "false", "0", "no":
                return false
            default:
                break
            }
        case let .int(intValue):
            return intValue != 0
        case let .double(doubleValue):
            return doubleValue != 0
        default:
            break
        }
        throw MCPError.invalidParams("\(name) must be a boolean.")
    }

    private nonisolated static func translateSelectionToPhysical(
        _ paths: [String],
        mappings: [DirectHeadlessRootMapping]
    ) -> [String] {
        translateAbsolutePaths(paths, mappings: mappings, from: \.canonicalRoot, to: \.physicalRoot)
    }

    private nonisolated static func translateSelectionToCanonical(
        _ paths: [String],
        mappings: [DirectHeadlessRootMapping]
    ) throws -> [String] {
        try paths.map { rawPath in
            guard rawPath.hasPrefix("/") else { return rawPath }
            let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            if let translated = translateAbsolutePathPreservingSuffix(
                path,
                mappings: mappings,
                from: \.physicalRoot,
                to: \.canonicalRoot
            ) {
                return translated
            }
            guard mappings.contains(where: {
                path == $0.canonicalRoot.path || path.hasPrefix($0.canonicalRoot.path + "/")
            }) else {
                throw Error.pathOutsideWorkspace(rawPath)
            }
            return path
        }
    }

    private nonisolated static func translateAbsolutePaths(
        _ paths: [String],
        mappings: [DirectHeadlessRootMapping],
        from source: KeyPath<DirectHeadlessRootMapping, URL>,
        to destination: KeyPath<DirectHeadlessRootMapping, URL>
    ) -> [String] {
        paths.map { rawPath in
            guard rawPath.hasPrefix("/") else { return rawPath }
            let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            return translateAbsolutePathPreservingSuffix(
                path,
                mappings: mappings,
                from: source,
                to: destination
            ) ?? rawPath
        }
    }

    private nonisolated static func translateAbsolutePathPreservingSuffix(
        _ path: String,
        mappings: [DirectHeadlessRootMapping],
        from source: KeyPath<DirectHeadlessRootMapping, URL>,
        to destination: KeyPath<DirectHeadlessRootMapping, URL>
    ) -> String? {
        if let translated = translateAbsolutePath(path, mappings: mappings, from: source, to: destination) {
            return translated
        }

        var ancestor = URL(fileURLWithPath: path).standardizedFileURL
        var suffix: [String] = []
        while true {
            let resolvedAncestor = ancestor.resolvingSymlinksInPath().standardizedFileURL.path
            if let mapping = mappings.first(where: { resolvedAncestor == $0[keyPath: source].path }) {
                var translated = mapping[keyPath: destination]
                for component in suffix.reversed() {
                    translated.appendPathComponent(component)
                }
                return translated.standardizedFileURL.path
            }
            guard ancestor.path != "/" else { return nil }
            suffix.append(ancestor.lastPathComponent)
            ancestor = ancestor.deletingLastPathComponent()
        }
    }

    private nonisolated static func translateAbsolutePath(
        _ path: String,
        mappings: [DirectHeadlessRootMapping],
        from source: KeyPath<DirectHeadlessRootMapping, URL>,
        to destination: KeyPath<DirectHeadlessRootMapping, URL>
    ) -> String? {
        guard let mapping = mappings
            .filter({ path == $0[keyPath: source].path || path.hasPrefix($0[keyPath: source].path + "/") })
            .max(by: { $0[keyPath: source].path.count < $1[keyPath: source].path.count })
        else { return nil }
        let sourcePath = mapping[keyPath: source].path
        let suffix = String(path.dropFirst(sourcePath.count))
        return mapping[keyPath: destination].path + suffix
    }

    private static func contextObject(
        from workspace: DomainWorkspaceSnapshot,
        contextID: UUID
    ) throws -> [String: Any] {
        guard let document = try JSONSerialization.jsonObject(
            with: workspace.document.documentBytes
        ) as? [String: Any],
            let contexts = document["composeTabs"] as? [[String: Any]],
            let context = contexts.first(where: { ($0["id"] as? String) == contextID.uuidString })
        else {
            throw Error.invalidWorkspaceDocument
        }
        return context
    }
}
