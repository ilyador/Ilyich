import Foundation
import Synchronization
import XCTest
@testable import Ilyich

/// A background task iOS launched, recording how it was completed.
@MainActor final class FakeBackgroundTask: BackgroundTaskHandle {
    let identifier: String
    var expirationHandler: (() -> Void)?
    private(set) var completions: [Bool] = []

    init(identifier: String) { self.identifier = identifier }

    func setTaskCompleted(success: Bool) { completions.append(success) }
}

/// BGTaskScheduler as a test drives it: it records requests and launches tasks on demand.
@MainActor final class FakeTaskScheduler: BackgroundTaskScheduling {
    private var handlers: [String: @MainActor (any BackgroundTaskHandle) -> Void] = [:]
    private(set) var submitted: [WindowRequest] = []
    private(set) var cancelled: [String] = []
    /// What iOS held from an earlier launch.
    var pendingAtLaunch: [WindowRequest] = []

    func register(identifier: String, launch: @escaping @MainActor (any BackgroundTaskHandle) -> Void) -> Bool {
        guard handlers[identifier] == nil else { return false }
        handlers[identifier] = launch
        return true
    }

    func submit(_ request: WindowRequest, refused: @escaping @MainActor @Sendable () -> Void) { submitted.append(request) }
    func cancel(identifier: String) { cancelled.append(identifier) }
    func pending() async -> [WindowRequest] { pendingAtLaunch }

    /// iOS starts a window of this kind.
    @discardableResult
    func launch(_ kind: BackgroundWindowKind) -> FakeBackgroundTask {
        let task = FakeBackgroundTask(identifier: kind.identifier)
        handlers[kind.identifier]?(task)
        return task
    }
}

/// UIApplication's background time, recording what began and ended.
@MainActor final class FakeBackgroundTime: BackgroundTimeGranting {
    private var next = 0
    private var expirations: [Int: @MainActor () -> Void] = [:]
    private(set) var begun: [String] = []
    private(set) var ended: [Int] = []

    func begin(name: String, expiration: @escaping @MainActor () -> Void) -> Int? {
        next += 1
        begun.append(name)
        expirations[next] = expiration
        return next
    }

    func end(_ id: Int) {
        ended.append(id)
        expirations[id] = nil
    }

    var held: Int { expirations.count }

    /// iOS takes every assertion's time back.
    func expireAll() {
        for (_, expiration) in expirations.sorted(by: { $0.key < $1.key }) { expiration() }
    }
}

/// A recorder behind the window's steps. Each step can be held at a gate or made to fail; held
/// steps note whether they were cancelled once the gate opens.
final class FakeWindowWork: BackgroundWindowWork {
    struct Failure: Error {}

    private struct State {
        var calls: [String] = []
        var gates: [String: TransferGate] = [:]
        var failing: Set<String> = []
        var handoffs: [WindowHandoff] = []
        var triggerDelay: Duration? = .zero
        var daemonOwns = false
    }

    private let state = Mutex(State())

    var calls: [String] { state.withLock { $0.calls } }
    func count(_ step: String) -> Int { calls.filter { $0 == step }.count }

    func hold(_ step: String, at gate: TransferGate) { state.withLock { $0.gates[step] = gate } }
    func fail(_ step: String) { state.withLock { _ = $0.failing.insert(step) } }
    /// What runUntilHandedOff returns, in turn; nothingRunnable once they run out.
    func handoffs(_ results: WindowHandoff...) { state.withLock { $0.handoffs = results } }
    func setTriggerDelay(_ delay: Duration?) { state.withLock { $0.triggerDelay = delay } }

    private func step(_ name: String) async throws {
        let (gate, fails) = state.withLock { state in
            state.calls.append(name)
            return (state.gates[name], state.failing.contains(name))
        }
        if let gate {
            await gate.wait()
            if Task.isCancelled { state.withLock { $0.calls.append(name + " cancelled") } }
        }
        if fails { throw Failure() }
    }

    func reconcile() async throws { try await step("reconcile") }
    func applyOutcomes() async throws { try await step("applyOutcomes") }
    func submitStaged() async throws { try await step("submitStaged") }
    func preSyncMetadata() async throws { try await step("preSync") }
    func discover() async throws { try await step("discover") }
    func conditionsChanged() async { try? await step("conditionsChanged") }

    func daemonOwnsWork() async -> Bool {
        state.withLock { state in
            state.calls.append("daemonOwnsWork")
            return state.daemonOwns
        }
    }

    func runUntilHandedOff() async -> WindowHandoff {
        try? await step("runUntilHandedOff")
        return state.withLock { $0.handoffs.isEmpty ? .nothingRunnable : $0.handoffs.removeFirst() }
    }

    func automaticTriggerDelay() async -> Duration? { state.withLock { $0.triggerDelay } }
}

/// Records the plans an engine hands over.
final class RecordingWindowScheduler: WindowScheduling {
    private let recorded = Mutex<[SchedulePlan]>([])
    var plans: [SchedulePlan] { recorded.withLock { $0 } }
    func schedule(_ plan: SchedulePlan) async { recorded.withLock { $0.append(plan) } }
}

extension EnvironmentSnapshot {
    static func launch(active: Bool) -> EnvironmentSnapshot {
        EnvironmentSnapshot(appActive: active, network: .none, charging: false, thermal: .nominal, lowPower: false)
    }
}
