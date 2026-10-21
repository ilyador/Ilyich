import Foundation
import Synchronization
import UIKit

// MARK: - Seams

/// What background time is spent on (B7). B9 builds it from the transfer engine
/// (TransferEngine.handoff and daemonOwnsWork), B6's recovery, the account's sync engine and
/// LibraryDiscovery; tests use a fake.
protocol BackgroundWindowWork: Sendable {
    /// Recovery.reconcile (B6): what the sessions and the database say, made to agree.
    func reconcile() async throws
    /// Commits the outcomes the sessions delivered.
    func applyOutcomes() async throws
    /// Hands bodies already staged to the transport, staging nothing new.
    func submitStaged() async throws
    /// Whether a job's part is with the background session now.
    func daemonOwnsWork() async -> Bool
    /// Lets the engine prepare and submit the next job; returns once a part is with the session or
    /// nothing can run, without polling.
    func runUntilHandedOff() async -> WindowHandoff
    /// One sync pass of the library's metadata, best effort: album uploads and duplicate checks
    /// read it, and nothing waits on it.
    func preSyncMetadata() async throws
    /// Finds new photos to back up and queues them.
    func discover() async throws
    /// A condition changed: the engine's waits end.
    func conditionsChanged() async
    /// How long after the app comes forward, or Photos or the backup settings change, automatic
    /// backup looks for new photos; nil while automatic backup is off.
    func automaticTriggerDelay() async -> Duration?
}

/// UIApplication.beginBackgroundTask behind a seam.
@MainActor protocol BackgroundTimeGranting: AnyObject, Sendable {
    /// Nil when iOS grants no time. iOS calls `expiration` on the main thread when the time is up,
    /// and the assertion must end before it returns.
    func begin(name: String, expiration: @escaping @MainActor () -> Void) -> Int?
    func end(_ id: Int)
}

// MARK: - Background assertion

/// Extra time for a step that started in the foreground and must not stop halfway when the app
/// goes to the background: discovery, or staging the job that is about to go to the daemon. It
/// ends once, when the step finishes or when iOS takes the time back, which also cancels the step.
@MainActor final class BackgroundAssertion {
    private let granting: any BackgroundTimeGranting
    private var id: Int?
    private var ended = false

    private init(granting: any BackgroundTimeGranting) { self.granting = granting }

    /// `expired` runs, synchronously, when iOS takes the time back, before the assertion ends.
    static func begin(_ name: String, granting: any BackgroundTimeGranting, expired: @escaping @Sendable () -> Void) -> BackgroundAssertion {
        let assertion = BackgroundAssertion(granting: granting)
        assertion.id = granting.begin(name: name) { [weak assertion] in
            expired()
            assertion?.end()
        }
        return assertion
    }

    var isEnded: Bool { ended }

    func end() {
        guard !ended else { return }
        ended = true
        if let id { granting.end(id) }
        id = nil
    }

    /// Runs `body` in a task of its own, under an assertion that iOS's expiry ends and that
    /// cancels the task.
    nonisolated static func run<T: Sendable>(_ name: String, granting: any BackgroundTimeGranting,
                                             _ body: @escaping @Sendable () async -> T) async -> T {
        let task = Task { await body() }
        let assertion = await MainActor.run { begin(name, granting: granting) { task.cancel() } }
        let value = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        await assertion.end()
        return value
    }
}

/// UIApplication's background time. For B9's launch sequence only.
@MainActor final class SystemBackgroundTime: BackgroundTimeGranting {
    func begin(name: String, expiration: @escaping @MainActor () -> Void) -> Int? {
        let id = UIApplication.shared.beginBackgroundTask(withName: name) { MainActor.assumeIsolated { expiration() } }
        return id == .invalid ? nil : id.rawValue
    }

    func end(_ id: Int) {
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: id))
    }
}

// MARK: - Lifecycle

/// Turns LifecycleEvent into backup work (B7), dormant until the cutover (B9): BackupLifecycle and
/// BackupAppDelegate run backup's background time today.
///
/// - A background window runs runWindow's steps. One window works at a time; another that comes
///   meanwhile completes at once, as today.
/// - In the foreground, the app coming forward, a Photos change or a settings change looks for new
///   photos after the trigger delay. A later trigger restarts the delay, but never stops a search
///   already under way: it searches once more when that one finishes.
/// - A condition change (network, power, temperature) only ends the engine's waits; it never stops
///   a search or a window.
/// - In the background nothing starts foreground work, and Photos changes do nothing at all.
/// - Going to the background holds an assertion until the job the engine is preparing reaches the
///   daemon, or nothing is left that can run.
actor TransferLifecycle<C: Clock> where C.Duration == Duration {
    /// A pre-sync gets at most 20 s, or 30 % of the window's budget if that is less.
    static func preSyncLimit(budget: Duration) -> Duration { min(.seconds(20), budget * 0.3) }

    private let work: any BackgroundWindowWork
    private let time: any BackgroundTimeGranting
    private let clock: C
    /// What a processing window is assumed to last: iOS does not say.
    private let processingBudget: Duration

    private var appActive: Bool
    private var consumer: Task<Void, Never>?
    private var window: Task<Void, Never>?
    /// The trigger delay running before a foreground search.
    private var pendingStart: Task<Void, Never>?
    /// The foreground search under way.
    private var foreground: Task<Void, Never>?
    private var searchAgain = false
    /// The assertion held after going to the background.
    private var holding: Task<Void, Never>?
    private var others: [UUID: Task<Void, Never>] = [:]

    /// Events handled so far, for tests.
    private(set) var handled = 0

    init(work: any BackgroundWindowWork, time: any BackgroundTimeGranting, clock: C, appActive: Bool,
         processingBudget: Duration = .seconds(120)) {
        self.work = work
        self.time = time
        self.clock = clock
        self.appActive = appActive
        self.processingBudget = processingBudget
    }

    /// Handles the source's events, in order, until the stream ends or stop().
    func start(_ events: AsyncStream<LifecycleEvent>) {
        guard consumer == nil else { return }
        consumer = Task {
            for await event in events { await self.handle(event) }
        }
    }

    func stop() {
        consumer?.cancel()
        consumer = nil
        for task in [window, pendingStart, foreground, holding] { task?.cancel() }
        for task in others.values { task.cancel() }
        others = [:]
        pendingStart = nil
    }

    func handle(_ event: LifecycleEvent) async {
        defer { handled += 1 }
        switch event {
        case .window(let lease):
            openWindow(lease)
        case .becameActive:
            appActive = true
            requestSearch()
        case .enteredBackground:
            appActive = false
            pendingStart?.cancel()
            pendingStart = nil
            holdUntilHandedOff()
        case .environment:
            await work.conditionsChanged()
        case .photoLibraryChanged, .preferencesChanged:
            if appActive { requestSearch() }
        case .urlSessionEvents:
            spawn { [work] in try? await work.applyOutcomes() }
        case .readOnlyChanged:
            // The engine follows the authorization itself.
            break
        }
    }

    // MARK: Windows

    private func openWindow(_ lease: BGTaskLease) {
        guard window == nil else {
            // The window already working does what this one would.
            lease.finish(success: true)
            return
        }
        let task = Task {
            let success = await self.runWindow(lease.kind)
            lease.finish(success: success && !Task.isCancelled)
            self.windowClosed()
        }
        window = task
        lease.onExpiration { task.cancel() }
    }

    private func windowClosed() { window = nil }

    /// A window's steps. Every window reconciles, applies the outcomes and submits what is already
    /// staged; a refresh window stops there. A processing window then lets the engine prepare the
    /// next job unless the daemon already holds one, runs a bounded metadata pre-sync whose failure
    /// changes nothing, looks for new photos, and returns once a part is with the daemon or nothing
    /// can run. False when a step failed or iOS took the time back.
    private func runWindow(_ kind: BackgroundWindowKind) async -> Bool {
        do {
            try await work.reconcile()
            try Task.checkCancellation()
            try await work.applyOutcomes()
            try Task.checkCancellation()
            try await work.submitStaged()
            try Task.checkCancellation()
        } catch {
            return false
        }
        guard kind == .processing else { return true }
        var handedOff = await work.daemonOwnsWork()
        if !handedOff { handedOff = await work.runUntilHandedOff() == .handedToDaemon }
        guard !Task.isCancelled else { return false }
        await preSync()
        guard !Task.isCancelled else { return false }
        var success = true
        do { try await work.discover() } catch { success = false }
        guard !Task.isCancelled else { return false }
        if !handedOff { _ = await work.runUntilHandedOff() }
        return success && !Task.isCancelled
    }

    /// The pre-sync, abandoned at its limit: the window goes on without waiting for it to stop.
    private func preSync() async {
        let limit = Self.preSyncLimit(budget: processingBudget)
        let work = self.work
        let clock = self.clock
        let sync = Task { _ = try? await work.preSyncMetadata() }
        let timer = Task { _ = try? await clock.sleep(for: limit) }
        await firstOf(sync, timer)
        sync.cancel()
        timer.cancel()
    }

    // MARK: Foreground

    private func requestSearch() {
        if foreground != nil {
            searchAgain = true
            return
        }
        pendingStart?.cancel()
        let work = self.work
        let clock = self.clock
        pendingStart = Task {
            guard let delay = await work.automaticTriggerDelay() else { return }
            do { try await clock.sleep(for: delay) } catch { return }
            self.beginSearch()
        }
    }

    private func beginSearch() {
        pendingStart = nil
        guard appActive, foreground == nil, !Task.isCancelled else { return }
        let work = self.work
        let time = self.time
        foreground = Task {
            // Its own task: nothing that cancels a trigger reaches it.
            _ = await BackgroundAssertion.run("Backup: finding new photos", granting: time) { try? await work.discover() }
            self.searchFinished()
        }
    }

    private func searchFinished() {
        foreground = nil
        guard searchAgain else { return }
        searchAgain = false
        if appActive { requestSearch() }
    }

    private func holdUntilHandedOff() {
        guard holding == nil else { return }
        let work = self.work
        let time = self.time
        holding = Task {
            _ = await BackgroundAssertion.run("Backup: handing over to iOS", granting: time) { await work.runUntilHandedOff() }
            self.holdFinished()
        }
    }

    private func holdFinished() { holding = nil }

    private func spawn(_ body: @escaping @Sendable () async -> Void) {
        let id = UUID()
        others[id] = Task {
            await body()
            self.spawned(id)
        }
    }

    private func spawned(_ id: UUID) { others[id] = nil }

    // MARK: Testing

    var isSearching: Bool { foreground != nil }
    var hasWindow: Bool { window != nil }
}

/// Returns when the first of two tasks ends, or when the caller is cancelled.
private func firstOf(_ first: Task<Void, Never>, _ second: Task<Void, Never>) async {
    let signal = OneShotSignal()
    await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            signal.set(continuation)
            Task { await first.value; signal.fire() }
            Task { await second.value; signal.fire() }
        }
    } onCancel: {
        signal.fire()
    }
}

private final class OneShotSignal: Sendable {
    private let state = Mutex<(fired: Bool, continuation: CheckedContinuation<Void, Never>?)>((false, nil))

    func set(_ continuation: CheckedContinuation<Void, Never>) {
        let fired = state.withLock { state -> Bool in
            if !state.fired { state.continuation = continuation }
            return state.fired
        }
        if fired { continuation.resume() }
    }

    func fire() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.fired else { return nil }
            state.fired = true
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume()
    }
}
