import Foundation
import IlyichPlatform

// MARK: - Seams

/// Runs one leased job: staging, the server checks and the transport (B3 and B4 build the real
/// ones). It reports through `context`, and calls `context.ensureOwned()` after every await of its
/// own, so a job whose lease is gone stops before it sends anything more. It returns what to
/// commit, or throws what went wrong for the classifier.
protocol JobExecuting: Sendable {
    func execute(_ job: LeasedJob, context: JobContext) async throws -> JobResult
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
    /// nil for a legacy Live Photo confirmed without its video's checksum.
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
        return hasEnded ? nil : snapshot
    }
}

/// The lease is gone: released by a command, or fenced by a change of authorization.
struct LeaseLost: Error, Equatable, Sendable {}

/// What an executor may do with its lease. Every call first checks that the lease still holds.
struct JobContext: Sendable {
    let lease: Lease
    fileprivate let owned: @Sendable (Lease) async -> Bool
    fileprivate let advanceTo: @Sendable (Lease, JobState, String?) async throws -> Void
    fileprivate let report: @Sendable (Lease, Int64, Int64) async -> Void

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
    func progress(sent: Int64, expected: Int64) async { await report(lease, sent, expected) }
}

// MARK: - Engine

/// The transfer engine (B2), dormant until the cutover (B9): nothing in the app creates it, and
/// backup still runs through BackupCoordinator and state.json.
///
/// Commands only write rows and wake the loop. One owned loop leases the next job, runs it
/// through the executor, then commits the result or records the failure, each WHERE the lease
/// still holds (BM12). A result that arrives after its lease was released is dropped.
///
/// The run intent gates only the library lane. An account block stops both lanes until the user
/// acts; nothing automatic lifts it. An engine-wide wait lasts until a condition changes. A
/// transient failure retries after a backoff, keeping the job eligible; an item failure waits for
/// the user, which a manual run does for every failed photo at its start.
///
/// It runs only on a database it owns (TransferStore.claimForEngine, or B9's authoritative
/// import), never on the shadow copy a shadow import rewrites.
actor TransferEngine<C: Clock>: TransferControlling where C.Duration == Duration {
    enum StartError: Error, Equatable {
        /// The database is still BackupCoordinator's shadow copy.
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

    // Persisted engine state, loaded at start.
    private var intent: RunIntent = .paused
    private var blocker: AccountRestriction?
    private var lastMessage: String?
    private var preferences: TransferPreferences?

    /// An engine-wide wait, and when it ends by itself (server backoff only).
    private var wait: WaitReason?
    private var waitUntil: Date?
    private var consecutiveServerErrors = 0

    private struct Active {
        let job: LeasedJob
        let task: Task<JobResult, any Error>
        /// What the lease was taken under: an upload needs the same token and write generation.
        let tokenDigest: String
        let writeGeneration: UInt64
    }
    private var active: Active?
    private var fileProgress: (sent: Int64, expected: Int64)?

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
    private var subscribers: [UUID: AsyncStream<TransferSnapshot>.Continuation] = [:]
    private var latest: TransferSnapshot?
    private var lastSent: TransferSnapshot?
    private var lastSentAt: C.Instant?
    private var flush: Task<Void, Never>?

    init(store: TransferStore, executor: any JobExecuting, authorization: any TransferAuthorizing, clock: C,
         now: @escaping @Sendable () -> Date = { Date() }, random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }) {
        self.store = store
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
        let updates = authorization.updates()
        watcher = Task { [weak self] in
            for await snapshot in updates { await self?.authorizationChanged(snapshot) }
            // The stream ends with the session, or when the engine stops.
            if !Task.isCancelled { await self?.authorizationChanged(nil) }
        }
        loop = Task { [weak self] in await self?.run() }
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
        loop = nil
        watcher = nil
        flush?.cancel()
        for subscriber in subscribers.values { subscriber.finish() }
        subscribers = [:]
    }

    /// A condition changed (network, power, temperature): every wait ends, whatever the intent.
    /// An account block stays.
    func conditionsChanged() async {
        wait = nil
        waitUntil = nil
        consecutiveServerErrors = 0
        _ = try? await store.requeueWaiting()
        await changed()
    }

    // MARK: TransferControlling

    func setIntent(_ intent: RunIntent) async throws {
        self.intent = intent
        if intent == .manual {
            // A manual run retries every failed photo once; a second start changes nothing else.
            try await store.requeueFailed(lane: .library)
        }
        if intent != .paused {
            // The user asked: lift a block whose cause has gone, and try again now.
            liftBlock()
            wait = nil
            waitUntil = nil
        }
        try await saveEngineState()
        if intent == .paused, active?.job.lane == .library { await releaseActive() }
        await changed()
    }

    func enqueue(_ requests: [TransferRequest]) async throws -> EnqueueResult {
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
        if let running = active, sources.contains(running.job.source) { await releaseActive() }
        for lane in [TransferLane.library, .share] {
            let keys = sources.filter { $0.lane == lane }.map(\.key)
            if !keys.isEmpty { try await store.removeJobs(lane: lane, sourceKeys: keys) }
        }
        await changed()
    }

    func setPreferences(_ preferences: TransferPreferences) async throws {
        try await store.savePreferences(preferences)
        self.preferences = preferences
        await changed()
    }

    func retry(_ sources: [TransferSource]?) async throws {
        if let sources {
            for lane in [TransferLane.library, .share] {
                let keys = sources.filter { $0.lane == lane }.map(\.key)
                if !keys.isEmpty { try await store.requeueFailed(lane: lane, sourceKeys: keys) }
            }
        } else {
            try await store.requeueFailed(lane: .library)
            try await store.requeueFailed(lane: .share)
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

    func queuePage(lane: TransferLane, after seq: Int64?, limit: Int) async throws -> [TransferQueueItem] {
        try await store.queuePage(lane: lane, after: seq, limit: limit)
    }

    func historyPage(offset: Int, limit: Int) async throws -> [TransferHistoryItem] {
        try await store.historyPage(offset: offset, limit: limit)
    }

    func failures(limit: Int) async throws -> [TransferQueueItem] {
        try await store.failures(limit: limit)
    }

    func albumUploadCounts() async throws -> [String: Int] {
        try await store.albumUploadCounts()
    }

    // MARK: Loop

    private func run() async {
        while !Task.isCancelled {
            if let refusal = restriction(authorization.current()) { await block(refusal) }
            if let until = waitUntil, now() >= until { wait = nil; waitUntil = nil }
            if blocker != nil || wait != nil {
                await publish()
                await sleep(until: wait == nil ? nil : waitUntil)
                continue
            }
            let job: LeasedJob?
            do { job = try await reserve() } catch {
                if Task.isCancelled { return }
                lastMessage = error.localizedDescription
                await publish()
                await sleep(until: now().addingTimeInterval(30))
                continue
            }
            guard let job else {
                await publish()
                let lanes: [TransferLane] = intent == .paused ? [.share] : [.share, .library]
                await sleep(until: try? await store.nextRetry(lanes: lanes))
                continue
            }
            await perform(job)
        }
    }

    /// Leases the next job: the share lane first, as the user approved each share, then the
    /// library lane unless it is paused.
    private func reserve() async throws -> LeasedJob? {
        guard let snapshot = authorization.current() else { return nil }
        let lanes: [TransferLane] = intent == .paused ? [.share] : [.share, .library]
        for lane in lanes {
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
                    report: { [weak self] lease, sent, expected in await self?.progress(lease, sent: sent, expected: expected) })
                let executor = self.executor
                active = Active(job: job, task: Task { try await executor.execute(job, context: context) },
                                tokenDigest: current.tokenDigest, writeGeneration: current.writeGeneration)
                return job
            }
        }
        return nil
    }

    private func perform(_ job: LeasedJob) async {
        await publish()
        guard let running = active, running.job.lease == job.lease else { return }
        let result = await running.task.result
        // A released lease drops whatever came back.
        guard active?.job.lease == job.lease else { return }
        active = nil
        fileProgress = nil
        switch result {
        case .success(let outcome):
            do {
                if try await commit(outcome, of: job) { consecutiveServerErrors = 0 }
            } catch {
                lastMessage = error.localizedDescription
                _ = try? await store.release(job: job.lease.job, token: job.lease.token)
            }
        case .failure(let error):
            // A write fenced by a read-only toggle runs again under the new generation; it is
            // not the photo's failure.
            if error is LeaseLost || error is WriteFenced || Task.isCancelled {
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
            return try await store.complete(TransferCompletion(job: job.lease.job, lease: job.lease.token, localID: id.rawValue, revision: revision,
                                                               assetID: assetID, receipt: receipt, confirmedAt: now()))
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
        guard let active, active.job.lease == lease, blocker == nil, !stopped else { return false }
        guard let current = authorization.current(), restriction(current) == nil else { return false }
        if active.job.lane == .library, intent == .paused { return false }
        return current.tokenDigest == active.tokenDigest && current.writeGeneration == active.writeGeneration
    }

    private func advance(_ lease: Lease, to state: JobState, phase: String?) async throws {
        guard owns(lease) else { throw LeaseLost() }
        guard try await store.advance(job: lease.job, token: lease.token, to: state, phase: phase) else { throw LeaseLost() }
        // ensureOwned after the await.
        guard owns(lease) else { throw LeaseLost() }
    }

    private func progress(_ lease: Lease, sent: Int64, expected: Int64) async {
        guard active?.job.lease == lease else { return }
        fileProgress = (sent, expected)
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
        } else if let active, active.writeGeneration != snapshot?.writeGeneration {
            // Uploads taken under another write generation are fenced; the job runs again.
            await releaseActive()
        }
        await changed()
    }

    /// Stops both lanes until the user acts. The running job gives its lease back, keeping its
    /// stage.
    private func block(_ restriction: AccountRestriction) async {
        if blocker != restriction {
            blocker = restriction
            // An ended session's block is this engine's alone: the database outlives the session.
            if restriction != .signedOut { try? await saveEngineState() }
        }
        await releaseActive()
    }

    /// An explicit command lifts the block if its cause has gone. A changed token never clears:
    /// that session's engine is done, and the next session has its own.
    private func liftBlock() {
        guard let blocker, restriction(authorization.current()) == nil, blocker != .signedOut else { return }
        if blocker == .sessionExpired, authorization.current()?.tokenDigest != tokenDigest { return }
        self.blocker = nil
    }

    /// Cancels the running job and gives its lease back. What it returns later is dropped.
    private func releaseActive() async {
        guard let running = active else { return }
        active = nil
        fileProgress = nil
        running.task.cancel()
        _ = try? await store.release(job: running.job.lease.job, token: running.job.lease.token)
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
    }

    private func snapshot() -> TransferSnapshot {
        let phase: TransferPhase = if let blocker { .blocked(blocker) } else if let wait { .waiting(wait) } else if active != nil { .running } else { .idle }
        let progress = fileProgress
        return TransferSnapshot(intent: intent, phase: phase, remaining: counts.remaining, confirmed: counts.confirmed, failed: counts.failed,
                                fileProgress: progress.flatMap { $0.expected > 0 ? min(Double($0.sent) / Double($0.expected), 1) : nil },
                                bytesSent: progress?.sent ?? 0, bytesExpected: max(progress?.expected ?? 0, 0), bytesPerSecond: nil,
                                lastMessage: lastMessage)
    }

    /// Sends the snapshot now, or, within the interval of the last one, the latest at its end.
    private func publish(refreshingCounts: Bool = true) async {
        if refreshingCounts { await refreshCounts() }
        guard !stopped else { return }
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

    /// The running job's lease, for tests.
    var runningLease: Lease? { active?.job.lease }
    /// The snapshot as it stands, unthrottled, for tests.
    var currentSnapshot: TransferSnapshot { snapshot() }
}

private extension Duration {
    var seconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
