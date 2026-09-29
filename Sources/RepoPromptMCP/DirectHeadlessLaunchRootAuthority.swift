import Foundation
import RepoPromptDomainRuntime

// M21: one launch-scoped root authority per pinned discovery Oracle lane.
//
// Discovery commits its selection over one context, at known revisions, and over known physical
// roots, then mints the Oracle step's carriers for that context (`DomainChildLaunchContextPin`).
// Each lane's launch turns that authority into a `DirectHeadlessLaunchRootLease`
// (`DirectHeadlessDomainContext.acquireLaunchRootLease`), and everything that names a root for the
// lane derives from that one lease until its process exits:
//
// - the provider process's working directory is the lease's active root;
// - the lane's launch token is issued with `launchScopedRoots`, so its redemption attaches the
//   child connection to the lease and is refused when the lease is gone;
// - every tool call on that connection resolves roots and worktree overlay from the lease, never
//   from the workspace's live roots, and fails closed if the live canonical roots drifted.
//
// Workspace-root mutations made through this runtime take a root-mutation claim and are serialized
// against leases in `DirectHeadlessDomainContext`: a claim that wins refuses the launch, a lease
// that wins refuses the mutation with a typed, retryable `root_authority_leased` failure until the
// lease is released. External writers (another process replacing the workspace file) are not
// serialized; a leased connection detects their root change and fails closed instead.

/// The authority one pinned discovery Oracle step launches under: its token authority, the
/// physical roots the commit was made over, and the ledger of which lanes actually started.
struct DirectHeadlessPinnedLaunch {
    /// The committed context at the revisions the commit produced (what the carriers authorize).
    let pin: DomainChildLaunchContextPin
    /// The physical roots (worktree overlays applied) discovery read and committed over.
    let committedRoots: [String]
    let ledger: DirectHeadlessLaunchLedger

    init(pin: DomainChildLaunchContextPin, committedRoots: [URL]) {
        self.pin = pin
        self.committedRoots = committedRoots.map(\.path)
        ledger = DirectHeadlessLaunchLedger()
    }

    func lane(_ carrier: DomainChildLaunchCarrier) -> Lane {
        Lane(launch: self, carrier: carrier)
    }

    /// One lane's launch: the step's authority plus the carrier minted for this lane.
    struct Lane {
        let launch: DirectHeadlessPinnedLaunch
        let carrier: DomainChildLaunchCarrier
    }
}

/// Which lane launches of one pinned Oracle step began and which processes actually started.
/// A lane launches at most once; settlement reports `oracle_started` from here, never from the
/// shape of an error.
final class DirectHeadlessLaunchLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var begun: Set<UUID> = []
    private var started: Set<UUID> = []

    /// Marks `launchID` as launching; false when it already was.
    func begin(_ launchID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return begun.insert(launchID).inserted
    }

    /// Called once the lane's provider process is running.
    func markStarted(_ launchID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        started.insert(launchID)
    }

    func hasStarted(_ launchID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return started.contains(launchID)
    }

    var anyStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !started.isEmpty
    }
}

/// Every launch-scoped root authority, root-mutation claim, and leased child connection of one
/// direct-headless runtime, behind one lock so each check-and-record is atomic and so the host's
/// synchronous provider entry/return callbacks can take part.
///
/// A lease is `pending` while its launch validates, `active` while its process runs, and
/// `releasing` once the process exited but a child invocation that entered under it has not
/// settled. A `releasing` lease admits no new child invocation and resolves no new snapshot, but
/// it still excludes root mutations: a child write that captured the lease's roots before the exit
/// finishes before any roots change can land. The record is removed when the last such invocation
/// settles. A leased connection is forgotten only after it closed and its invocations settled, so
/// a late resolution on it never falls back to live roots.
final class DirectHeadlessLaunchRootRegistry: @unchecked Sendable {
    /// Who holds roots a refused mutation wanted (reported in `root_authority_leased`).
    struct Holder {
        let context: DomainContextIdentity
        let runID: UUID
        let launchID: UUID
    }

    enum Lookup {
        /// Not a leased connection: resolve live.
        case unleased
        case active(DirectHeadlessLaunchRootLease)
        /// Leased, but its lease is released (or releasing): fail closed.
        case released
    }

    enum PendingRegistration {
        case registered
        case duplicateLaunch
        case rootsChanging
    }

    struct Counts: Equatable {
        /// Leases in any state (pending, active, releasing).
        let leases: Int
        let activeLeases: Int
        let releasingLeases: Int
        let claims: Int
        let leasedConnections: Int
        let inFlightInvocations: Int
    }

    private enum State {
        case pending
        case active(DirectHeadlessLaunchRootLease)
        case releasing(DirectHeadlessLaunchRootLease)
    }

    private struct Record {
        let leaseID: UUID
        let holder: Holder
        let overlaySessionID: UUID?
        var state: State
        var inFlight = 0
    }

    private struct Claim {
        let workspaceID: UUID
        let contextID: UUID?

        func covers(_ context: DomainContextIdentity) -> Bool {
            workspaceID == context.workspaceID && (contextID == nil || contextID == context.contextID)
        }
    }

    private struct ConnectionEntry {
        let launchID: UUID
        var closed = false
        var inFlight = 0
    }

    private let lock = NSLock()
    private var records: [UUID: Record] = [:]
    private var claims: [UUID: Claim] = [:]
    private var connections: [UUID: ConnectionEntry] = [:]
    /// Child invocations that entered under a lease: invocation ID to (connection, launch).
    private var invocations: [UUID: (connectionID: UUID, launchID: UUID)] = [:]

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: Leases

    func registerPending(
        launchID: UUID,
        leaseID: UUID,
        holder: Holder,
        overlaySessionID: UUID?
    ) -> PendingRegistration {
        locked {
            guard records[launchID] == nil else { return .duplicateLaunch }
            guard !claims.values.contains(where: { $0.covers(holder.context) }) else { return .rootsChanging }
            records[launchID] = Record(
                leaseID: leaseID,
                holder: holder,
                overlaySessionID: overlaySessionID,
                state: .pending
            )
            return .registered
        }
    }

    /// Activates a still-pending registration; false when it is gone.
    func activate(_ lease: DirectHeadlessLaunchRootLease) -> Bool {
        locked {
            guard var record = records[lease.launchID], record.leaseID == lease.leaseID,
                  case .pending = record.state
            else { return false }
            record.state = .active(lease)
            records[lease.launchID] = record
            return true
        }
    }

    func abandonPending(launchID: UUID, leaseID: UUID) {
        locked {
            guard let record = records[launchID], record.leaseID == leaseID, case .pending = record.state else { return }
            records.removeValue(forKey: launchID)
        }
    }

    /// Ends `lease`'s activity (its process exited). Returns true for the one call that did, so the
    /// caller revokes the lane's token exactly once. Root exclusion lasts until in-flight child
    /// invocations settle.
    func release(_ lease: DirectHeadlessLaunchRootLease) -> Bool {
        locked {
            guard var record = records[lease.launchID], record.leaseID == lease.leaseID,
                  case .active = record.state
            else { return false }
            if record.inFlight == 0 {
                records.removeValue(forKey: lease.launchID)
            } else {
                record.state = .releasing(lease)
                records[lease.launchID] = record
            }
            return true
        }
    }

    func isActive(_ lease: DirectHeadlessLaunchRootLease) -> Bool {
        locked {
            guard let record = records[lease.launchID], record.leaseID == lease.leaseID,
                  case .active = record.state
            else { return false }
            return true
        }
    }

    func isRegistered(launchID: UUID, leaseID: UUID) -> Bool {
        locked { records[launchID]?.leaseID == leaseID }
    }

    // MARK: Leased connections and their invocations

    /// Binds a child connection that redeemed a launch-scoped-roots token to its lane's active
    /// lease; false (the connection must be refused) when there is none for that run and context.
    func attach(connectionID: UUID, launchID: UUID, runID: UUID, context: DomainContextIdentity) -> Bool {
        locked {
            guard let record = records[launchID], case let .active(lease) = record.state,
                  lease.runID == runID, lease.context == context
            else { return false }
            connections[connectionID] = ConnectionEntry(launchID: launchID)
            return true
        }
    }

    /// The connection closed. It keeps failing closed until its in-flight invocations settle.
    func detach(connectionID: UUID) {
        locked {
            guard var entry = connections[connectionID] else { return }
            if entry.inFlight == 0 {
                connections.removeValue(forKey: connectionID)
            } else {
                entry.closed = true
                connections[connectionID] = entry
            }
        }
    }

    func lookup(connectionID: UUID) -> Lookup {
        locked {
            guard let entry = connections[connectionID] else { return .unleased }
            guard !entry.closed, let record = records[entry.launchID], case let .active(lease) = record.state else {
                return .released
            }
            return .active(lease)
        }
    }

    /// Host provider entry for `invocationID` on `connectionID`: a leased connection's invocation
    /// runs only under its active lease and holds that lease's root exclusion until
    /// `endInvocation`. Throws (nothing runs) once the lease is released or the connection closed.
    func beginInvocation(_ invocationID: UUID, connectionID: UUID) throws {
        try locked {
            guard var entry = connections[connectionID] else { return }
            guard !entry.closed, var record = records[entry.launchID], case .active = record.state,
                  invocations[invocationID] == nil
            else {
                throw DirectHeadlessDomainContext.Error.launchRootAuthorityReleased
            }
            record.inFlight += 1
            entry.inFlight += 1
            records[entry.launchID] = record
            connections[connectionID] = entry
            invocations[invocationID] = (connectionID, entry.launchID)
        }
    }

    /// Host provider return: the invocation settled. The last settled invocation of a releasing
    /// lease ends its root exclusion; the last of a closed connection forgets the connection.
    func endInvocation(_ invocationID: UUID) {
        locked {
            guard let use = invocations.removeValue(forKey: invocationID) else { return }
            if var record = records[use.launchID] {
                record.inFlight -= 1
                if record.inFlight == 0, case .releasing = record.state {
                    records.removeValue(forKey: use.launchID)
                } else {
                    records[use.launchID] = record
                }
            }
            if var entry = connections[use.connectionID] {
                entry.inFlight -= 1
                if entry.inFlight == 0, entry.closed {
                    connections.removeValue(forKey: use.connectionID)
                } else {
                    connections[use.connectionID] = entry
                }
            }
        }
    }

    // MARK: Root mutations

    /// Registers a root-mutation claim, or returns the lease (in any state) holding those roots.
    func claim(workspaceID: UUID, contextID: UUID?) -> Result<UUID, HolderConflict> {
        locked {
            let claim = Claim(workspaceID: workspaceID, contextID: contextID)
            if let holder = records.values.first(where: { claim.covers($0.holder.context) })?.holder {
                return .failure(HolderConflict(holder: holder))
            }
            let claimID = UUID()
            claims[claimID] = claim
            return .success(claimID)
        }
    }

    func endClaim(_ claimID: UUID) {
        locked { _ = claims.removeValue(forKey: claimID) }
    }

    /// The lease that resolved (or is resolving) its roots from `sessionID`'s overlay.
    func overlayHolder(sessionID: UUID) -> Holder? {
        locked { records.values.first { $0.overlaySessionID == sessionID }?.holder }
    }

    struct HolderConflict: Error {
        let holder: Holder
    }

    func counts() -> Counts {
        locked {
            var active = 0
            var releasing = 0
            for record in records.values {
                switch record.state {
                case .pending: break
                case .active: active += 1
                case .releasing: releasing += 1
                }
            }
            return Counts(
                leases: records.count,
                activeLeases: active,
                releasingLeases: releasing,
                claims: claims.count,
                leasedConnections: connections.count,
                inFlightInvocations: invocations.count
            )
        }
    }
}

/// The launch-scoped root authority of one pinned Oracle lane, held from its launch until its
/// process exits (or until the launch fails before the process starts).
struct DirectHeadlessLaunchRootLease: Equatable {
    let leaseID: UUID
    let launchID: UUID
    let runID: UUID
    let launchTokenID: UUID
    let context: DomainContextIdentity
    /// The workspace's canonical roots at the launch. A leased read refuses once they differ.
    let canonicalRoots: [String]
    /// Canonical-to-physical root mapping and active root at the launch.
    let rootOverlay: DirectHeadlessRootOverlay
    /// The session whose worktree overlay was resolved (nil: the process overlay, which is fixed).
    let overlaySessionID: UUID?

    /// The provider process's working directory.
    var workingDirectory: URL? {
        rootOverlay.activeRoot
    }
}
