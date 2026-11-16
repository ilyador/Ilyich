import Foundation
import IlyichPlatform

// MARK: - Seams

/// Runs one leased job: staging, the server checks and the transport (B3 and B4 build the real
/// ones). It reports through `context`, and calls `context.ensureOwned()` after every await of its
/// own, so a job whose lease is gone stops before it sends anything more. It returns what to
/// commit, or throws what went wrong for the classifier.
protocol JobExecuting: Sendable {
    func execute(_ job: LeasedJob, context: JobContext) async throws -> JobResult
    /// The engine committed what `execute` returned for the job: its files can go. Never awaited
    /// by anything that has to finish first, and a failure here changes nothing committed.
    func committed(_ job: LeasedJob, result: JobResult) async
}

extension JobExecuting {
    func committed(_ job: LeasedJob, result: JobResult) async {}
}

/// A job under a lease, as the executor sees it. An interrupted job (a released lease, a relaunch)
/// keeps the state an earlier lease reached. A job that failed and is retried, or waited and was
/// queued again, comes back as retryScheduled or queued: its phase and its stage rows, which both
/// stay, say how far it got, so an executor resumes from those, never from the state alone.
struct LeasedJob: Hashable, Sendable {
    let lease: Lease
    let lane: TransferLane
    let source: TransferSource
    let origin: JobOrigin
    let state: JobState
    let phase: String?
    let retryCount: Int
    let batch: UUID?
    let displayName: String?
}

/// What a finished job commits.
enum JobResult: Hashable, Sendable {
    /// A photo the server now holds: its revision when staged, its server ID and the receipt,
    /// nil for a Live Photo an earlier build staged, confirmed without its video's checksum.
    case backedUp(revision: AssetRevision, assetID: String, receipt: TransferReceipt?)
    /// A shared file the server now holds.
    case shared(remoteID: String?)
}

/// The account's authorization as the engine needs it: nil once the session ended.
protocol TransferAuthorizing: Sendable {
    func current() -> AuthorizationSnapshot?
    /// The snapshot now, then each change; it finishes when the session ends.
    func updates() -> AsyncStream<AuthorizationSnapshot>
}

extension AuthorizationState: TransferAuthorizing {
    func current() -> AuthorizationSnapshot? {
        let snapshot = snapshot
        return permitsServiceUse ? snapshot : nil
    }
}

/// Where the engine's background windows go: LifecycleEventSource (B7). The engine hands over a
/// plan only when it changes, in order.
protocol WindowScheduling: Sendable {
    func schedule(_ plan: SchedulePlan) async
}

/// How far a background window got the engine (B7).
enum WindowHandoff: Hashable, Sendable {
    /// A job's part is with the background session, which carries on once the app is suspended.
    case handedToDaemon
    /// Nothing can run now: no job, all waiting, retrying later, paused or blocked.
    case nothingRunnable
}

/// The lease is gone: released by a command, or fenced by a change of authorization.
struct LeaseLost: Error, Equatable, Sendable {}

/// What an executor may do with its lease. Every call first checks that the lease still holds.
struct JobContext: Sendable {
    let lease: Lease
    fileprivate let owned: @Sendable (Lease) async -> Bool
    fileprivate let advanceTo: @Sendable (Lease, JobState, String?) async throws -> Void
    fileprivate let report: @Sendable (Lease, Int64, Int64, String?) async -> Void
    fileprivate let preparation: @Sendable (Lease, Double?) async -> Void
    fileprivate let checking: @Sendable (Lease, Bool) async -> Void
    fileprivate let absent: @Sendable (Lease, AssetRevision) async -> Void

    /// Throws LeaseLost unless the lease still holds and the authorization it was taken under
    /// still allows uploads. Call it after every await.
    func ensureOwned() async throws {
        try Task.checkCancellation()
        guard await owned(lease) else { throw LeaseLost() }
    }

    /// Records the job's state and the executor's phase, nil to keep the phase.
    func advance(to state: JobState, phase: String? = nil) async throws {
        try await ensureOwned()
        try await advanceTo(lease, state, phase)
    }

    /// Bytes of the current file sent so far.
    func progress(sent: Int64, expected: Int64, phase: String? = nil) async { await report(lease, sent, expected, phase) }
    func preparationProgress(_ fraction: Double?) async { await preparation(lease, fraction) }
    func checkingExistingBackups(_ value: Bool) async { await checking(lease, value) }
    func checkedOriginalAbsent(revision: AssetRevision) async { await absent(lease, revision) }
}

// MARK: - Engine

/// The transfer engine (B2). From the cutover (B9) each signed-in account's runtime runs one,
/// over the account's transfers database (TransferRuntime).
///
/// Commands only write rows and wake the loop. One owned loop leases the next job, runs it
/// through the executor, then commits the result or records the failure, each WHERE the lease
/// still holds (BM12). A result that arrives after its lease was released is dropped. Up to
/// `concurrency` jobs run at once, each under its own lease: one by default, and the library
/// executor's pipeline for it (B3), which takes the turns within it.
///
/// The run intent gates only the library lane. An account block stops both lanes until the user
/// acts; nothing automatic lifts it, except that turning read-only mode off, the user's own act,
/// lifts its block. Turning it on also does what the toggle always did: backup pauses, with
/// automatic backup switched off, and shared uploads stop, so turning it off resumes nothing (the
/// owner's decision). An engine-wide wait lasts until a condition changes. A transient failure
/// retries after a backoff, keeping the job eligible; an item failure waits for the user, which a
/// manual run does for every failed photo at its start.
///
/// It runs only on a database it owns (TransferStore.claimForEngine, or, on the phone, B9's
/// import).
actor TransferEngine<C: Clock>: TransferControlling where C.Duration == Duration {
    enum StartError: Error, Equatable {
        /// The engine doesn't own the database.
        case notOwned
    }

    /// Snapshots go out at most this often.
    static var snapshotInterval: Duration { .milliseconds(250) }

    private let store: TransferStore
    private let executor: any JobExecuting
    private let authorization: any TransferAuthorizing
    private let clock: C
    private let now: @Sendable () -> Date
    private let random: @Sendable () -> Double
    private let scheduler: (any WindowScheduling)?
    /// The post-upload work (B4): told after each commit, when the library lane drains, and when
    /// the user asks for a run. Never awaited.
    private let followUp: (@Sendable (FollowUpTrigger) -> Void)?
    /// Library jobs ran since the lane last had nothing runnable.
    private var ranSinceDrain = false

    // Persisted engine state, loaded at start.
    private var intent: RunIntent = .paused
    private var blocker: AccountRestriction?
    private var lastMessage: String?
    private var preferences: TransferPreferences?

    /// An engine-wide wait, and when it ends by itself (server backoff only).
    private var wait: WaitReason?
    private var waitUntil: Date?
    /// A partial server identity catalog delays the library lane, never shared uploads.
    private var identityIndexRetryAt: Date?
    private var preparingServerLibrary = false
    private var consecutiveServerErrors = 0

    private struct Active {
        let job: LeasedJob
        let task: Task<JobResult, any Error>
        /// What the lease was taken under: an upload needs the same token and write generation.
        let tokenDigest: String
        let writeGeneration: UInt64
    }
    /// The running jobs, by job ID.
    private var active: [Int64: Active] = [:]
    /// Bytes sent of each running job's current file.
    private var fileProgress: [Int64: (sent: Int64, expected: Int64)] = [:]
    /// Reject a previous Live Photo part's callback queued before its phase finished.
    private var fileProgressPhase: [Int64: String] = [:]
    private var preparationProgress: [Int64: Double] = [:]
    private var checkingExisting: Set<Int64> = []
    private let concurrency: Int
    /// Each running job's wait for its result and commit, by lease token.
    private var finishing: [UUID: Task<Void, Never>] = [:]
    /// Discovery passes under way.
    private var discovering = 0
    /// Only the latest discovery may report an error. A stopped or cancelled pass is silent.
    private var discoveryGeneration: UInt64 = 0
    private var newPhotosActivation: UUID?
    private var futureConfirmed = 0
    private var discoveryMessage: String?
    private var backupSelectionChecked = false
    private var selectionInventory: SelectionInventory?
    private var selectionCheckedAt: Date?
    private struct BackupSelection: Equatable {
        let scope: PhotoSelectionScope
        let included: Set<String>
        let excluded: Set<String>
        let newPhotosOnly: Bool

        init(_ preferences: TransferPreferences) {
            scope = preferences.scope
            included = preferences.includedAlbums
            excluded = preferences.excludedAlbums
            newPhotosOnly = preferences.newPhotosOnly
        }
    }
    /// Manual runs still setting up: the run doesn't end meanwhile.
    private var manualHolds = 0

    private var loop: Task<Void, Never>?
    private var watcher: Task<Void, Never>?
    /// The start in progress: a second start waits for it rather than loading again.
    private var starting: Task<Void, any Error>?
    /// Bumped by every cancel, and the sources a cancel is removing, so a lease taken while a
    /// cancel ran is given back rather than run.
    private var cancelGeneration = 0
    private var cancelling: [TransferSource: Int] = [:]
    private var sleeper: CheckedContinuation<Void, Never>?
    private var woken = false
    private var stopped = false
    /// The token of the session the engine started under.
    private var tokenDigest: String?

    // Snapshots.
    private var counts = TransferCounts()
    private var preferencesRevision: UInt64 = 0
    private var subscribers: [UUID: AsyncStream<TransferSnapshot>.Continuation] = [:]
    private var latest: TransferSnapshot?
    private var lastSent: TransferSnapshot?
    private var lastSentAt: C.Instant?
    private var flush: Task<Void, Never>?

    // Background windows.
    /// The last plan handed to the scheduler.
    private var plan: SchedulePlan?
    private var plans: AsyncStream<SchedulePlan>.Continuation?
    private var planner: Task<Void, Never>?
    /// Windows waiting for a job to reach the transport or for nothing to be runnable.
    private var handoffs: [UUID: CheckedContinuation<WindowHandoff, Never>] = [:]
    /// Waits cancelled before they were stored.
    private var cancelledHandoffs: Set<UUID> = []
    /// Counts jobs reaching the transport, so a hand-off that was reading the store meanwhile sees
    /// one it would otherwise miss.
    private var submissions = 0

    init(store: TransferStore, executor: any JobExecuting, authorization: any TransferAuthorizing, clock: C, concurrency: Int = 1,
         scheduler: (any WindowScheduling)? = nil, followUp: (@Sendable (FollowUpTrigger) -> Void)? = nil,
         now: @escaping @Sendable () -> Date = { Date() }, random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }) {
        self.store = store
        self.scheduler = scheduler
        self.followUp = followUp
        self.concurrency = max(concurrency, 1)
        self.executor = executor
        self.authorization = authorization
        self.clock = clock
        self.now = now
        self.random = random
    }

    // MARK: Lifecycle

    /// Starts the loop. A second start only wakes it: it never clears the running job or its
    /// stage.
    func start() async throws {
        guard !stopped else { return }
        if loop != nil { return wake() }
        // A start already loading: the actor is reentrant at its awaits, so a second start would
        // otherwise run a second loop and release the first one's lease.
        if let starting { return try await starting.value }
        let task = Task { try await self.begin() }
        starting = task
        defer { starting = nil }
        try await task.value
    }

    private func begin() async throws {
        guard try await store.meta().engine == .transfer else { throw StartError.notOwned }
        // Leases of a process that ended are free again; jobs keep their state.
        try await store.releaseAllLeases()
        let saved = try await store.engineState()
        intent = saved?.intent ?? .paused
        // An expired session's block belonged to the session before: an engine starts only with a
        // new one, which signing in again made.
        blocker = saved?.blocker.flatMap(AccountRestriction.init(storedValue:)).flatMap { [.signedOut, .sessionExpired].contains($0) ? nil : $0 }
        lastMessage = saved?.lastMessage
        preferences = try await store.preferences()
        tokenDigest = authorization.current()?.tokenDigest
        await refreshCounts()
        // A stop that came while this loaded wins: the engine stays stopped.
        guard !stopped else { return }
        if let scheduler {
            // One consumer, so plans reach iOS in the order the engine made them.
            let (stream, continuation) = AsyncStream.makeStream(of: SchedulePlan.self)
            plans = continuation
            planner = Task {
                for await plan in stream { await scheduler.schedule(plan) }
            }
        }
        let updates = authorization.updates()
        watcher = Task { [weak self] in
            for await snapshot in updates { await self?.authorizationChanged(snapshot) }
            // The stream ends with the session, or when the engine stops.
            if !Task.isCancelled { await self?.authorizationChanged(nil) }
        }
        loop = Task { [weak self] in await self?.run() }
        followUp?(.started)
    }

    /// Stops the loop and the running job, gives the job's lease back and ends the snapshot
    /// streams. The engine can't start again.
    func stop() async {
        stopped = true
        watcher?.cancel()
        loop?.cancel()
        wake()
        await releaseActive()
        await loop?.value
        for task in finishing.values { await task.value }
        loop = nil
        watcher = nil
        resolveHandoffs(.nothingRunnable)
        // The plan already handed over stays with iOS: the database outlives this engine.
        plans?.finish()
        plans = nil
        flush?.cancel()
        for subscriber in subscribers.values { subscriber.finish() }
        subscribers = [:]
    }

    /// A condition changed (network, power, temperature): every wait ends, whatever the intent.
    /// An account block stays.
    func conditionsChanged() async {
        if !preparingServerLibrary { identityIndexRetryAt = nil }
        wait = nil
        waitUntil = nil
        consecutiveServerErrors = 0
        _ = try? await store.requeueWaiting()
        followUp?(.conditionsChanged)
        await changed()
    }

    // MARK: TransferControlling

    func setIntent(_ intent: RunIntent) async throws {
        try await setIntent(intent, requeueingFailures: true)
    }

    /// Sets the run intent. A manual intent retries every failed photo once unless
    /// `requeueingFailures` is off, as when automatic backup is switched off during a run and the
    /// run only carries on.
    func setIntent(_ intent: RunIntent, requeueingFailures: Bool) async throws {
        guard newPhotosActivation == nil else { throw NewPhotosBackupError.changingPolicy }
        self.intent = intent
        if intent == .manual, requeueingFailures {
            // A manual run retries every failed photo once, and the albums and stacks that failed
            // after an upload; a second start changes nothing else.
            try await store.requeueFailed(lane: .library)
            followUp?(.manualRun)
        }
        if intent != .paused {
            preparingServerLibrary = false
            identityIndexRetryAt = nil
            // The user asked: lift a block whose cause has gone, and try again now.
            liftBlock()
            wait = nil
            waitUntil = nil
        }
        try await saveEngineState()
        if intent == .paused { await releaseActive { $0.job.lane == .library } }
        await changed()
    }

    func enqueue(_ requests: [TransferRequest]) async throws -> EnqueueResult {
        guard newPhotosActivation == nil || requests.allSatisfy({ $0.source.lane == .share }) else { throw NewPhotosBackupError.changingPolicy }
        // A read-only block that outlived read-only mode (a refusal handled after it went off)
        // doesn't refuse the user's own uploads.
        if blocker == .readOnly, restriction(authorization.current()) == nil {
            blocker = nil
            try await saveEngineState()
        }
        if let refusal = blocker ?? restriction(authorization.current()) { return .refused(refusal) }
        let result = try await store.enqueue(requests)
        await changed()
        if result.queued == 0, result.alreadyBackedUp > 0 { return .alreadyBackedUp(result.alreadyBackedUp) }
        return .queued(result.queued)
    }

    func cancel(_ sources: [TransferSource]) async throws {
        cancelGeneration += 1
        for source in sources { cancelling[source, default: 0] += 1 }
        defer {
            for source in sources {
                let left = (cancelling[source] ?? 1) - 1
                cancelling[source] = left > 0 ? left : nil
            }
        }
        await releaseActive { sources.contains($0.job.source) }
        for lane in [TransferLane.library, .share] {
            let keys = sources.filter { $0.lane == lane }.map(\.key)
            if !keys.isEmpty { try await store.removeJobs(lane: lane, sourceKeys: keys) }
        }
        await changed()
    }

    /// Captures identifiers only while paused, then removes pre-existing library work and
    /// commits the immutable baseline together with the new automatic policy. No executor runs.
    func enableNewPhotosBackup(staging: any PhotoLibraryStaging,
                              cancelAttempts: @Sendable ([AttemptID]) async throws -> Void,
                              policyChangeBegan: @Sendable () -> Void = {}) async throws {
        try Task.checkCancellation()
        guard !stopped, newPhotosActivation == nil else { throw NewPhotosBackupError.changingPolicy }
        let token = UUID()
        newPhotosActivation = token
        discoveryGeneration &+= 1
        cancelGeneration += 1
        do {
            guard let started = authorization.current(), restriction(started) == nil else { throw PurchaseAccessRequired() }
            let saved = try await store.preferences() ?? TransferPreferences()
            let savedIntent = try await store.engineState()?.intent ?? .paused
            let existing = try await store.newPhotosBaselineIDs()
            if saved.newPhotosOnly, saved.automatic, savedIntent == .automatic, existing != nil,
               try await store.newPhotosPolicyChanging() == false {
                preferences = saved
                intent = .automatic
                newPhotosActivation = nil
                await changed()
                return
            }
            guard (intent == .paused && savedIntent == .paused && !saved.automatic)
                    || (saved.newPhotosOnly && existing != nil) else {
                throw BackupError.message("Pause backup before choosing new photos only.")
            }
            let access = await newPhotosBaselineAccess(staging)
            guard access.status == .authorized else { throw BackupError.message("Full Photos access is required to exclude every existing photo.") }
            let auth = authorization
            let permits: @Sendable () -> Bool = { auth.current() == started && staging.authorization == .authorized }
            let startedAt = now()
            try await store.beginNewPhotosPolicyChange(token, permits: permits)
            policyChangeBegan()
            var baseline = existing ?? Set<String>()
            if existing == nil {
                for try await batch in staging.candidates(scope: .entireLibrary, included: [], excluded: []) {
                    try Task.checkCancellation()
                    guard !stopped, newPhotosActivation == token, permits(), await newPhotosBaselineAccess(staging) == access else { throw CancellationError() }
                    baseline.formUnion(batch.map(\.id))
                }
            }
            try Task.checkCancellation()
            guard !stopped, newPhotosActivation == token, permits(), await newPhotosBaselineAccess(staging) == access else { throw CancellationError() }
            let old = try await store.newPhotosCutoverJobs(existing == nil ? nil : baseline)
            try await cancel(old.sources)
            try await cancelAttempts(old.attempts)
            try Task.checkCancellation()
            guard !stopped, newPhotosActivation == token, permits(), await newPhotosBaselineAccess(staging) == access else { throw CancellationError() }
            let updated = try await store.commitNewPhotosBackupBaseline(existing == nil ? baseline : nil, startedAt: startedAt,
                                                                        expectedPreferences: saved, permits: permits)
            preferences = updated
            preferencesRevision &+= 1
            intent = .automatic
            blocker = nil
            wait = nil
            waitUntil = nil
            identityIndexRetryAt = nil
            preparingServerLibrary = false
            backupSelectionChecked = true
            selectionInventory = SelectionInventory(revisions: [:], confirmed: [])
            selectionCheckedAt = now()
            newPhotosActivation = nil
            await changed()
        } catch {
            try? await store.endNewPhotosPolicyChange(token)
            newPhotosActivation = nil
            await changed()
            throw error
        }
    }

    func setPreferences(_ preferences: TransferPreferences) async throws {
        guard newPhotosActivation == nil else { throw NewPhotosBackupError.changingPolicy }
        try await store.savePreferences(preferences)
        if self.preferences.map(BackupSelection.init) != BackupSelection(preferences) {
            backupSelectionChecked = false
            selectionInventory = nil
            selectionCheckedAt = nil
            discoveryGeneration &+= 1
            if let discoveryMessage, lastMessage == discoveryMessage { lastMessage = nil }
            discoveryMessage = nil
        }
        if self.preferences != preferences { preferencesRevision &+= 1 }
        self.preferences = preferences
        await changed()
    }

    /// Saves the preferences as the backup screen edits them, with the Automatic backup switch
    /// taking effect as it always has: switched on, a paused engine starts automatic backup;
    /// switched off, a run under way finishes as a manual one, and then the engine pauses.
    func setPreferencesFollowingAutomatic(_ preferences: TransferPreferences) async throws {
        let wasAutomatic = self.preferences?.automatic == true
        try await setPreferences(preferences)
        if preferences.automatic, intent == .paused {
            try await setIntent(.automatic, requeueingFailures: false)
        } else if !preferences.automatic, wasAutomatic, intent == .automatic {
            try await setIntent(.manual, requeueingFailures: false)
            await settleManualRun()
        }
    }

    /// The run intent now.
    var runIntent: RunIntent { intent }

    func retry(_ sources: [TransferSource]?) async throws {
        if let sources {
            for lane in [TransferLane.library, .share] {
                let keys = sources.filter { $0.lane == lane }.map(\.key)
                if !keys.isEmpty { try await store.requeueFailed(lane: lane, sourceKeys: keys) }
            }
        } else {
            try await store.requeueFailed(lane: .library)
            try await store.requeueFailed(lane: .share)
            try await store.requeueFailedFollowUps()
            followUp?(.retried)
        }
        liftBlock()
        try await saveEngineState()
        await changed()
    }

    func snapshots() -> AsyncStream<TransferSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: TransferSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        guard !stopped else {
            continuation.finish()
            return stream
        }
        let id = UUID()
        subscribers[id] = continuation
        continuation.yield(lastSent ?? snapshot())
        continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
        return stream
    }

    /// Reads one item's persisted transfer state and overlays only that job's in-memory progress.
    /// This does not wake discovery, run a checker, or touch PhotoKit/server APIs.
    func photoBackupStatus(localID: String, revision: AssetRevision?) async throws -> PhotoBackupStatus {
        let statuses = try await photoBackupStatuses(for: [PhotoBackupStatusRequest(localID: localID, revision: revision)])
        return statuses[localID] ?? PhotoBackupStatus(localID: localID, revision: revision, phase: .unknown)
    }

    /// Reads only requested rows and combines them with the matching active jobs' real progress.
    func photoBackupStatuses(for requests: [PhotoBackupStatusRequest]) async throws -> [String: PhotoBackupStatus] {
        guard !requests.isEmpty else { return [:] }
        let localIDs = Array(Set(requests.map(\.localID)))
        let revisions = try await store.confirmationRevisions(for: localIDs)
        let jobs = try await store.jobs(lane: .library, sourceKeys: localIDs)
        let stages = try await store.libraryStages(jobs: jobs.values.map(\.id))
        let changingPolicy = try await store.newPhotosPolicyChanging()
        let baselineExcluded = try await store.excludedFromNewPhotosBackup(localIDs)
        var statuses: [String: PhotoBackupStatus] = [:]

        for request in requests {
            let localID = request.localID
            let revision = request.revision
            let phase: PhotoBackupPhase
            if let revision, revisions[localID] == revision {
                phase = .completed
            } else if revision == nil {
                phase = .unknown
            } else if let job = jobs[localID] {
                if let stage = stages[job.id], stage.revision != revision {
                    phase = .unknown
                } else if job.state == .failed {
                    phase = .needsAttention(message: job.errorMessage)
                } else if active[job.id] != nil {
                    let progress = fileProgress[job.id].flatMap { report -> Double? in
                        guard report.expected > 0 else { return nil }
                        return min(max(Double(report.sent) / Double(report.expected), 0), 1)
                    }
                    if let progress {
                        phase = .uploading(progress: progress)
                    } else if job.state == .submitted || job.state == .submitting {
                        phase = .uploading(progress: nil)
                    } else {
                        phase = .preparing(progress: preparationProgress[job.id])
                    }
                } else if job.state == .submitted {
                    // The background URLSession may own the task after the engine has released
                    // its lease (or before the app has rebound it after launch).
                    phase = .uploading(progress: nil)
                } else if intent == .paused {
                    phase = .paused
                } else if job.state == .waiting {
                    phase = .waiting(message: job.errorMessage)
                } else if let blocker {
                    phase = .needsAttention(message: blocker.backupMessage)
                } else if let wait {
                    phase = .waiting(message: Self.photoStatusMessage(for: wait))
                } else {
                    phase = .waiting(message: nil)
                }
            } else if changingPolicy {
                phase = .unknown
            } else if baselineExcluded.contains(localID) {
                phase = .outsideAutomaticBackup
            } else {
                phase = .notQueued
            }
            statuses[localID] = PhotoBackupStatus(localID: localID, revision: revision, phase: phase)
        }
        return statuses
    }

    private static func photoStatusMessage(for reason: WaitReason) -> String {
        switch reason {
        case .deviceConditions: "Waiting for device conditions"
        case .unmeteredNetwork: "Waiting for an unmetered network"
        case .connectivity: "Waiting for a network connection"
        case .serverBackoff: "Waiting for the server"
        }
    }

    /// Runs a discovery pass and wakes the loop for the jobs it queued; the snapshot says
    /// discovering meanwhile. Nil, with nothing read, while an account block or the session's
    /// authorization refuses transfers, as enqueue refuses.
    func discover(_ discovery: LibraryDiscovery) async throws -> DiscoveryMerge? {
        if stopped || Task.isCancelled || newPhotosActivation != nil || blocker != nil || restriction(authorization.current()) != nil { return nil }
        discoveryGeneration &+= 1
        let generation = discoveryGeneration
        let selection = preferences.map(BackupSelection.init)
        let hasSelection = preferences?.hasSelection == true
        backupSelectionChecked = false
        selectionInventory = nil
        selectionCheckedAt = nil
        if let discoveryMessage, lastMessage == discoveryMessage { lastMessage = nil }
        discoveryMessage = nil
        discovering += 1
        await publish()
        let merge: DiscoveryMerge
        do { merge = try await discovery.run() } catch {
            discovering -= 1
            if !stopped, !Task.isCancelled, generation == discoveryGeneration,
               restriction(authorization.current()) == nil, !(error is CancellationError), !(error is PurchaseAccessRequired) {
                discoveryMessage = error.localizedDescription
                lastMessage = discoveryMessage
            }
            await changed()
            // A changed selection invalidates its old scan without turning a normal settings
            // change into a failed command. Genuine cancellation of this caller still throws.
            if error is CancellationError, generation != discoveryGeneration, !Task.isCancelled { return nil }
            throw error
        }
        discovering -= 1
        if !stopped, !Task.isCancelled, generation == discoveryGeneration, hasSelection,
           restriction(authorization.current()) == nil, selection == preferences.map(BackupSelection.init) {
            backupSelectionChecked = true
            selectionInventory = merge.inventory
            selectionCheckedAt = now()
            // A job can commit after the merge transaction returns but before this actor
            // adopts its inventory. Catch up once; later accepted commits update the set directly.
            await refreshSelectionConfirmations()
        }
        await changed()
        return merge
    }

    // MARK: Manual runs

    /// Back up now: the library lane runs, failed photos are retried once, `discovery` looks for
    /// new photos, and the run ends once nothing is left to upload, as today's run does: the
    /// intent then goes back to automatic when automatic backup is on, else to paused. Background
    /// windows are asked for while it runs (the owner's decision). Nil, with nothing read, when
    /// discovery is refused.
    @discardableResult
    func runManually(_ discovery: LibraryDiscovery?) async throws -> DiscoveryMerge? {
        manualHolds += 1
        var merge: DiscoveryMerge?
        do {
            try await setIntent(.manual)
            if let discovery { merge = try await discover(discovery) }
        } catch {
            manualHolds -= 1
            await settleManualRun()
            throw error
        }
        manualHolds -= 1
        await settleManualRun()
        return merge
    }

    /// Ends a manual run that has nothing left to upload: no job running, none queued, retrying,
    /// waiting or with the transport, and no discovery under way.
    func settleManualRun() async {
        guard intent == .manual, manualHolds == 0, discovering == 0, active.isEmpty, !stopped else { return }
        await refreshCounts()
        guard intent == .manual, manualHolds == 0, discovering == 0, active.isEmpty, counts.remaining == 0 else { return }
        intent = preferences?.automatic == true ? .automatic : .paused
        try? await saveEngineState()
        await changed()
    }

    /// Something outside the engine changed the database (recovery committed an outcome): the
    /// counts and the snapshot are read again, and the loop looks for work.
    func refresh() async {
        await refreshSelectionConfirmations()
        await changed()
    }

    private func refreshSelectionConfirmations() async {
        guard let inventory = selectionInventory else { return }
        let generation = discoveryGeneration
        guard let confirmations = try? await store.confirmationRevisions(for: Array(inventory.revisions.keys)),
              !stopped, generation == discoveryGeneration else { return }
        let current = Set(confirmations.compactMap { id, revision in
            (inventory.revisions[id] ?? nil) == revision ? id : nil
        })
        // Reconciliation may remove a server copy. Rebuild this set rather than only adding
        // confirmations, so paused selected counts cannot retain a deleted backup forever.
        selectionInventory?.confirmed = current
        selectionInventory?.pending.subtract(current)
    }

    // MARK: Background windows

    /// Wakes the loop and returns once a job's part is with the transport, or once nothing can
    /// run. It waits on the loop, never polling: a background window finishes the moment its
    /// work is the daemon's. A part already with the transport returns at once.
    func handoff() async -> WindowHandoff {
        let seen = submissions
        if (try? await store.hasSubmittedJobs()) == true || submissions != seen { return .handedToDaemon }
        guard loop != nil, !stopped, !Task.isCancelled else { return .nothingRunnable }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if cancelledHandoffs.remove(id) != nil {
                    continuation.resume(returning: .nothingRunnable)
                } else if submissions != seen {
                    // A job reached the transport while the store answered: its advance resolved
                    // the waiters before this one was stored.
                    continuation.resume(returning: .handedToDaemon)
                } else {
                    handoffs[id] = continuation
                    wake()
                }
            }
        } onCancel: {
            Task { await self.cancelHandoff(id) }
        }
    }

    /// Whether a job's part is with the transport now.
    func daemonOwnsWork() async -> Bool {
        (try? await store.hasSubmittedJobs()) ?? false
    }

    private func cancelHandoff(_ id: UUID) {
        if let waiter = handoffs.removeValue(forKey: id) {
            waiter.resume(returning: .nothingRunnable)
        } else {
            cancelledHandoffs.insert(id)
        }
    }

    private func resolveHandoffs(_ handoff: WindowHandoff) {
        guard !handoffs.isEmpty else { return }
        let waiters = handoffs.values
        handoffs = [:]
        for waiter in waiters { waiter.resume(returning: handoff) }
    }

    /// The windows this state asks for: automatic backup's while the preference is on and nothing
    /// blocks the engine, as the old backup scheduled them. A manual run asks for them too, even
    /// with automatic backup off (the owner's decision), until it ends; a pause drops them.
    private func currentPlan() -> SchedulePlan {
        guard intent != .paused, blocker == nil else { return .none }
        let automaticWork = preferences?.automatic == true && (preferences?.hasSelection == true || counts.remaining > 0)
        guard intent == .manual || automaticWork else { return .none }
        return .automatic(requireCharging: preferences?.requireCharging ?? false, triggerDelay: preferences?.triggerDelay ?? 0)
    }

    private func updatePlan() {
        guard let plans else { return }
        let current = currentPlan()
        guard current != plan else { return }
        plan = current
        plans.yield(current)
    }

    func queuePage(lane: TransferLane, after seq: Int64?, limit: Int) async throws -> [TransferQueueItem] {
        try await store.queuePage(lane: lane, after: seq, limit: limit)
    }

    func historyPage(offset: Int, limit: Int) async throws -> [TransferHistoryItem] {
        try await store.historyPage(offset: offset, limit: limit)
    }

    func failures(limit: Int) async throws -> [TransferQueueItem] {
        try await store.failures(limit: limit)
    }

    func preferences() async throws -> TransferPreferences? {
        if let preferences { return preferences }
        return try await store.preferences()
    }

    func albumUploadCounts() async throws -> [String: AlbumUploadCount] {
        try await store.albumUploadCounts()
    }

    // MARK: Loop

    private func run() async {
        while !Task.isCancelled {
            if let deadline = identityIndexRetryAt, now() >= deadline { identityIndexRetryAt = nil; preparingServerLibrary = false }
            if let refusal = restriction(authorization.current()) { await block(refusal) }
            if let until = waitUntil, now() >= until { wait = nil; waitUntil = nil }
            if blocker != nil || wait != nil {
                await publish()
                if active.isEmpty { resolveHandoffs(.nothingRunnable) }
                await sleep(until: wait == nil ? nil : waitUntil)
                continue
            }
            if active.count < concurrency {
                let job: LeasedJob?
                do { job = try await reserve() } catch {
                    if Task.isCancelled { return }
                    lastMessage = error.localizedDescription
                    await publish()
                    if active.isEmpty { resolveHandoffs(.nothingRunnable) }
                    await sleep(until: now().addingTimeInterval(30))
                    continue
                }
                if let job {
                    launch(job)
                    continue
                }
            }
            await publish()
            // Full, or nothing runnable: a finished job, a command or the next retry wakes it.
            if active.isEmpty {
                resolveHandoffs(.nothingRunnable)
                if ranSinceDrain {
                    ranSinceDrain = false
                    followUp?(.drained)
                }
                // A manual run ends once nothing is left, whoever finished its last photo: a job
                // of this loop, or recovery applying an outcome after a relaunch (refresh).
                if intent == .manual, counts.remaining == 0 { await settleManualRun() }
            }
            let lanes: [TransferLane] = intent == .paused || identityIndexRetryAt != nil ? [.share] : [.share, .library]
            let hasRoom = active.count < concurrency
            let nextRetry = hasRoom ? try? await store.nextRetry(lanes: lanes) : nil
            let catalogRetry = hasRoom && intent != .paused ? identityIndexRetryAt : nil
            await sleep(until: [nextRetry, catalogRetry].compactMap { $0 }.min())
        }
    }

    /// Waits for the job's result, and commits it, beside the loop.
    private func launch(_ job: LeasedJob) {
        if job.lane == .library { ranSinceDrain = true }
        let token = job.lease.token
        finishing[token] = Task { [weak self] in
            await self?.perform(job)
            await self?.finished(token)
        }
    }

    private func finished(_ token: UUID) {
        finishing[token] = nil
    }

    /// Leases the next job: the share lane first, as the user approved each share, then the
    /// library lane unless it is paused.
    private func reserve() async throws -> LeasedJob? {
        guard let snapshot = authorization.current() else { return nil }
        let lanes: [TransferLane] = intent == .paused ? [.share] : [.share, .library]
        for lane in lanes {
            if lane == .library, newPhotosActivation != nil { continue }
            if lane == .library, let deadline = identityIndexRetryAt, now() < deadline { continue }
            let token = UUID()
            let generation = cancelGeneration
            if let stored = try await store.reserve(lane: lane, now: now(), token: token, epoch: snapshot.epoch.value) {
                let lease = Lease(job: stored.id, token: token, epoch: snapshot.epoch)
                // Checked again after the await: the fence or a pause may have moved meanwhile.
                // A cancel meanwhile may have removed the row: the job must not run.
                guard let current = authorization.current(), restriction(current) == nil, blocker == nil,
                      current.writeGeneration == snapshot.writeGeneration, lane == .share || intent != .paused, !Task.isCancelled,
                      !stopped, cancelGeneration == generation, cancelling[stored.source] == nil else {
                    try await store.release(job: stored.id, token: token)
                    return nil
                }
                let job = LeasedJob(lease: lease, lane: lane, source: stored.source, origin: stored.origin, state: stored.state,
                                    phase: stored.phase, retryCount: stored.retryCount, batch: stored.batch, displayName: stored.displayName)
                let context = JobContext(
                    lease: lease,
                    owned: { [weak self] lease in await self?.owns(lease) ?? false },
                    advanceTo: { [weak self] lease, state, phase in
                        guard let self else { throw LeaseLost() }
                        try await self.advance(lease, to: state, phase: phase)
                    },
                    report: { [weak self] lease, sent, expected, phase in await self?.progress(lease, sent: sent, expected: expected, phase: phase) },
                    preparation: { [weak self] lease, fraction in await self?.preparationChanged(lease, fraction: fraction) },
                    checking: { [weak self] lease, value in await self?.checkingExisting(lease, value: value) },
                    absent: { [weak self] lease, revision in await self?.checkedAbsent(lease, revision: revision) })
                let executor = self.executor
                active[stored.id] = Active(job: job, task: Task { try await executor.execute(job, context: context) },
                                           tokenDigest: current.tokenDigest, writeGeneration: current.writeGeneration)
                fileProgressPhase[stored.id] = job.phase
                return job
            }
        }
        return nil
    }

    private func perform(_ job: LeasedJob) async {
        await publish()
        let id = job.lease.job
        guard let running = active[id], running.job.lease == job.lease else { return }
        let result = await running.task.result
        // A released lease drops whatever came back.
        guard active[id]?.job.lease == job.lease else { return }
        active[id] = nil
        fileProgress[id] = nil
        fileProgressPhase[id] = nil
        preparationProgress[id] = nil
        checkingExisting.remove(id)
        switch result {
        case .success(let outcome):
            do {
                if try await commit(outcome, of: job) {
                    consecutiveServerErrors = 0
                    followUp?(.committed(job.lane))
                    await executor.committed(job, result: outcome)
                }
            } catch {
                lastMessage = error.localizedDescription
                _ = try? await store.release(job: job.lease.job, token: job.lease.token)
            }
        case .failure(let error):
            // Authorization can expire synchronously inside the API/transport before the
            // account's asynchronous teardown runs. That refusal is never the file's failure,
            // even when earlier genuine failures already exhausted its unknown-error retries.
            // Successful OS outcomes above are still committed and durably acknowledged.
            if error is LeaseLost || error is WriteFenced || error is PurchaseAccessRequired ||
                authorization.current() == nil || Task.isCancelled {
                _ = try? await store.release(job: job.lease.job, token: job.lease.token)
            } else {
                await fail(job, error)
            }
        }
        await changed()
    }

    private func commit(_ outcome: JobResult, of job: LeasedJob) async throws -> Bool {
        switch (outcome, job.source) {
        case (.backedUp(let revision, let assetID, let receipt), .photo(let id)):
            let committed = try await store.complete(TransferCompletion(job: job.lease.job, lease: job.lease.token, localID: id.rawValue, revision: revision,
                                                                        assetID: assetID, receipt: receipt, confirmedAt: now()))
            if committed, let selected = selectionInventory?.revisions[id.rawValue] ?? nil, selected == revision {
                selectionInventory?.confirmed.insert(id.rawValue)
                selectionInventory?.pending.remove(id.rawValue)
            }
            return committed
        case (.shared(let remoteID), .shared(let batch, let attachment)):
            return try await store.completeShare(job: job.lease.job, token: job.lease.token, batch: batch, attachment: attachment,
                                                 remoteID: remoteID, at: now())
        default:
            // A result of the other lane's kind: the executor is wrong, so the user sees it.
            return try await store.markFailed(job: job.lease.job, token: job.lease.token, message: "This transfer finished in an unexpected way.",
                                              at: now())
        }
    }

    private func fail(_ job: LeasedJob, _ error: any Error) async {
        if job.lane == .library, let failure = error as? ServerFailure, failure == .externalContentFingerprintsPending {
            // One bounded account-wide hold, never one retry per selected photo. It does
            // not change the user's pause or automatic preference; shared files may continue.
            _ = try? await store.release(job: job.lease.job, token: job.lease.token)
            preparingServerLibrary = true
            identityIndexRetryAt = now().addingTimeInterval(60)
            await releaseActive { $0.job.lane == .library }
            return
        }
        if error is BackupIdentityIndexNotReady {
            _ = try? await store.release(job: job.lease.job, token: job.lease.token)
            identityIndexRetryAt = now().addingTimeInterval(5)
            return
        }
        let context = TransferFailureClassifier.Context(retryCount: job.retryCount, consecutiveServerErrors: consecutiveServerErrors,
                                                        downloadCloudOriginals: preferences?.downloadCloudOriginals ?? true)
        let failure = TransferFailureClassifier.classify(error, context: context)
        let serverError = TransferFailureClassifier.isServerError(error)
        consecutiveServerErrors = serverError ? consecutiveServerErrors + 1 : 0
        let lease = job.lease
        let date = now()
        do {
            switch failure {
            case .transient(let retryAfter):
                let delay = retryAfter ?? TransferFailureClassifier.backoff(retryCount: job.retryCount, random: random())
                _ = try await store.scheduleRetry(job: lease.job, token: lease.token, notBefore: date.addingTimeInterval(delay.seconds),
                                                  message: error.localizedDescription, at: date)
            case .waiting(let reason, jobScoped: true):
                _ = try await store.markWaiting(job: lease.job, token: lease.token, reason: reason, at: date)
            case .waiting(let reason, jobScoped: false):
                try await store.release(job: lease.job, token: lease.token)
                wait = reason
                waitUntil = reason == .serverBackoff
                    ? date.addingTimeInterval(TransferFailureClassifier.backoff(retryCount: consecutiveServerErrors, random: random()).seconds) : nil
            case .account(let restriction):
                try await store.release(job: lease.job, token: lease.token)
                await block(restriction)
            case .item(let message):
                _ = try await store.markFailed(job: lease.job, token: lease.token, message: message, at: date)
                lastMessage = message
            }
        } catch {
            lastMessage = error.localizedDescription
            _ = try? await store.release(job: lease.job, token: lease.token)
        }
    }

    // MARK: Lease and fence

    /// Whether `lease` is the running job's and the authorization it was taken under still allows
    /// uploads: the same session token and write generation, no read-only mode, no block.
    private func owns(_ lease: Lease) -> Bool {
        guard let active = active[lease.job], active.job.lease == lease, blocker == nil, !stopped else { return false }
        guard let current = authorization.current(), restriction(current) == nil else { return false }
        if active.job.lane == .library, intent == .paused || newPhotosActivation != nil { return false }
        return current.tokenDigest == active.tokenDigest && current.writeGeneration == active.writeGeneration
    }

    private func advance(_ lease: Lease, to state: JobState, phase: String?) async throws {
        guard owns(lease) else { throw LeaseLost() }
        guard try await store.advance(job: lease.job, token: lease.token, to: state, phase: phase) else { throw LeaseLost() }
        // ensureOwned after the await.
        guard owns(lease) else { throw LeaseLost() }
        if let phase { fileProgressPhase[lease.job] = phase }
        if state == .staging || state == .staged || state == .submitting {
            fileProgress[lease.job] = nil
        }
        if state == .submitted {
            submissions += 1
            resolveHandoffs(.handedToDaemon)
        }
        await publish(refreshingCounts: false)
    }

    private func progress(_ lease: Lease, sent: Int64, expected: Int64, phase: String?) async {
        guard active[lease.job]?.job.lease == lease else { return }
        guard phase == nil || fileProgressPhase[lease.job] == phase else { return }
        fileProgress[lease.job] = (sent, expected)
        await publish(refreshingCounts: false)
    }

    private func preparationChanged(_ lease: Lease, fraction: Double?) async {
        guard owns(lease) else { return }
        preparationProgress[lease.job] = fraction.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
        await publish(refreshingCounts: false)
    }

    private func checkingExisting(_ lease: Lease, value: Bool) async {
        guard owns(lease) else { return }
        if value { checkingExisting.insert(lease.job) } else { checkingExisting.remove(lease.job) }
        await publish(refreshingCounts: false)
    }

    private func checkedAbsent(_ lease: Lease, revision: AssetRevision) async {
        guard owns(lease), let running = active[lease.job], case .photo(let id) = running.job.source,
              let selected = selectionInventory?.revisions[id.rawValue] ?? nil, selected == revision,
              selectionInventory?.confirmed.contains(id.rawValue) == false else { return }
        selectionInventory?.pending.insert(id.rawValue)
        await publish(refreshingCounts: false)
    }

    /// What the authorization forbids the engine outright: an ended session, a changed token, a
    /// password to change, or read-only mode.
    private func restriction(_ snapshot: AuthorizationSnapshot?) -> AccountRestriction? {
        guard let snapshot else { return .signedOut }
        if let tokenDigest, snapshot.tokenDigest != tokenDigest { return .sessionExpired }
        if snapshot.requiresPasswordChange { return .passwordChange }
        if snapshot.readOnly { return .readOnly }
        return nil
    }

    private func authorizationChanged(_ snapshot: AuthorizationSnapshot?) async {
        guard !stopped else { return }
        if let refusal = restriction(snapshot) {
            await block(refusal)
        } else {
            // Uploads taken under another write generation are fenced; the jobs run again.
            await releaseActive { $0.writeGeneration != snapshot?.writeGeneration }
            // Read-only mode is off: its block goes. Turning it on paused backup and stopped
            // shared uploads, so nothing resumes (the owner's decision), and the user's own
            // uploads are taken again.
            if blocker == .readOnly {
                blocker = nil
                try? await saveEngineState()
            }
        }
        await changed()
    }

    /// Stops both lanes until the user acts. The running jobs give their leases back, keeping
    /// their stages. Read-only mode coming on does what the toggle always did besides: backup
    /// pauses, switching automatic backup off, and shared uploads stop, their files staying in the
    /// inbox. The pause is saved with the block, so a relaunch keeps both.
    private func block(_ restriction: AccountRestriction) async {
        let entering = blocker != restriction
        if entering {
            blocker = restriction
            if restriction == .readOnly { await pauseForReadOnly() }
            // An ended session's block is this engine's alone: the database outlives the session.
            if restriction != .signedOut { try? await saveEngineState() }
        }
        await releaseActive()
        if entering, restriction == .readOnly { _ = try? await store.removeUnfailedJobs(lane: .share) }
    }

    /// Read-only mode came on: the library lane pauses and automatic backup goes off, as Pause
    /// does.
    private func pauseForReadOnly() async {
        intent = .paused
        guard var paused = preferences, paused.automatic else { return }
        paused.automatic = false
        preferences = paused
        try? await store.savePreferences(paused)
    }

    /// An explicit command lifts the block if its cause has gone. A changed token never clears:
    /// that session's engine is done, and the next session has its own.
    private func liftBlock() {
        guard let blocker, restriction(authorization.current()) == nil, blocker != .signedOut else { return }
        if blocker == .sessionExpired, authorization.current()?.tokenDigest != tokenDigest { return }
        self.blocker = nil
    }

    /// Cancels the running jobs that match, every one by default, and gives their leases back.
    /// What they return later is dropped.
    private func releaseActive(where matches: (Active) -> Bool = { _ in true }) async {
        let released = active.values.filter(matches)
        guard !released.isEmpty else { return }
        for running in released {
            active[running.job.lease.job] = nil
            fileProgress[running.job.lease.job] = nil
            fileProgressPhase[running.job.lease.job] = nil
            preparationProgress[running.job.lease.job] = nil
            checkingExisting.remove(running.job.lease.job)
            running.task.cancel()
        }
        for running in released { _ = try? await store.release(job: running.job.lease.job, token: running.job.lease.token) }
        wake()
    }

    private func saveEngineState() async throws {
        try await store.saveEngineState(intent: intent, blocker: blocker, lastMessage: lastMessage)
    }

    // MARK: Waking

    private func wake() {
        if let sleeper {
            self.sleeper = nil
            sleeper.resume()
        } else {
            woken = true
        }
    }

    /// Sleeps until a command wakes the loop, or until `deadline`.
    private func sleep(until deadline: Date?) async {
        if woken || Task.isCancelled {
            woken = false
            return
        }
        var timer: Task<Void, Never>?
        if let deadline {
            let delay = max(deadline.timeIntervalSince(now()), 0)
            let clock = self.clock
            timer = Task { [weak self] in
                do { try await clock.sleep(for: .milliseconds(Int64((delay * 1_000).rounded(.up)))) } catch { return }
                await self?.wake()
            }
        }
        await withCheckedContinuation { sleeper = $0 }
        woken = false
        timer?.cancel()
    }

    // MARK: Snapshots

    private func changed() async {
        wake()
        await publish()
    }

    private func refreshCounts() async {
        if let fresh = try? await store.counts() { counts = fresh }
        if preferences?.newPhotosOnly == true { futureConfirmed = (try? await store.newPhotosConfirmedCount()) ?? 0 }
    }

    private func snapshot() -> TransferSnapshot {
        let catalogWaiting = identityIndexRetryAt != nil && intent != .paused && counts.remaining > 0 && blocker == nil && wait == nil
        let phase: TransferPhase = if let blocker { .blocked(blocker) } else if let wait { .waiting(wait) } else if !active.isEmpty { .running }
            else if discovering > 0 { .discovering } else if catalogWaiting { .waiting(.serverBackoff) } else { .idle }
        let libraryJobs = active.filter { $0.value.job.lane == .library }
        let backupPhase: TransferPhase = if let blocker { .blocked(blocker) } else if !libraryJobs.isEmpty { .running }
            else if discovering > 0 { .discovering }
            else if catalogWaiting { .waiting(.serverBackoff) }
            else if let wait, counts.remaining > 0, intent != .paused { .waiting(wait) } else { .idle }
        let libraryReports = libraryJobs.keys.compactMap { fileProgress[$0] }
        let expectedKnown = libraryReports.count == libraryJobs.count && libraryReports.allSatisfy { $0.expected > 0 }
        let backupProgress: TransferProgress? = libraryJobs.isEmpty ? nil : TransferProgress(
            activeFileCount: libraryJobs.count,
            sentBytes: libraryReports.reduce(0) { $0 + max($1.sent, 0) },
            expectedBytes: expectedKnown ? libraryReports.reduce(0) { $0 + $1.expected } : nil)
        let progress: (sent: Int64, expected: Int64)? = fileProgress.isEmpty ? nil
            : fileProgress.values.reduce((sent: Int64(0), expected: Int64(0))) { ($0.sent + $1.sent, $0.expected + max($1.expected, 0)) }
        return TransferSnapshot(intent: intent, phase: phase, remaining: counts.remaining, confirmed: preferences?.newPhotosOnly == true ? futureConfirmed : counts.confirmed, failed: counts.failed,
                                fileProgress: progress.flatMap { $0.expected > 0 ? min(Double($0.sent) / Double($0.expected), 1) : nil },
                                bytesSent: progress?.sent ?? 0, bytesExpected: max(progress?.expected ?? 0, 0), bytesPerSecond: nil,
                                lastMessage: lastMessage, backupPhase: backupPhase, backupProgress: backupProgress,
                                backupPreparationFraction: libraryJobs.keys.compactMap { preparationProgress[$0] }.min(),
                                preferencesRevision: preferencesRevision, backupSelectionChecked: backupSelectionChecked,
                                selectionProgress: selectionInventory.flatMap { inventory in
                                    selectionCheckedAt.map { SelectionProgress(total: inventory.revisions.count, backedUp: inventory.confirmed.count,
                                                                               unchecked: inventory.revisions.count - inventory.confirmed.count - inventory.pending.count,
                                                                               checkedAt: $0) }
                                }, checkingExistingBackups: (catalogWaiting && libraryJobs.isEmpty)
                                    || (!libraryJobs.isEmpty && libraryJobs.keys.allSatisfy { checkingExisting.contains($0) }),
                                preparingServerLibrary: preparingServerLibrary)
    }

    /// Sends the snapshot now, or, within the interval of the last one, the latest at its end.
    private func publish(refreshingCounts: Bool = true) async {
        if refreshingCounts { await refreshCounts() }
        guard !stopped else { return }
        updatePlan()
        let value = snapshot()
        latest = value
        guard value != lastSent else { return }
        let current = clock.now
        if let sentAt = lastSentAt, sentAt.duration(to: current) < Self.snapshotInterval {
            guard flush == nil else { return }
            let due = sentAt.advanced(by: Self.snapshotInterval)
            let clock = self.clock
            flush = Task { [weak self] in
                do { try await clock.sleep(until: due, tolerance: nil) } catch { return }
                await self?.flushLatest()
            }
            return
        }
        send(value)
    }

    private func flushLatest() {
        flush = nil
        if let latest, latest != lastSent, !stopped { send(latest) }
    }

    private func send(_ value: TransferSnapshot) {
        lastSent = value
        lastSentAt = clock.now
        for subscriber in subscribers.values { subscriber.yield(value) }
    }

    private func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
    }

    // MARK: Testing

    /// The running job's lease, the first by job ID when several run, for tests.
    var runningLease: Lease? { active.keys.min().flatMap { active[$0]?.job.lease } }
    /// Every running job's lease, for tests.
    var runningLeases: [Lease] { active.values.map(\.job.lease) }
    /// The snapshot as it stands, unthrottled, for tests.
    var currentSnapshot: TransferSnapshot { snapshot() }
}

private extension Duration {
    var seconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
