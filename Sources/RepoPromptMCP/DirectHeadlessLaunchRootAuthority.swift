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
