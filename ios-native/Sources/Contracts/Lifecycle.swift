import Foundation
import Synchronization

enum LaunchReason: Hashable, Sendable {
    case user
    case backgroundTask
    /// iOS relaunched the app for a background URLSession, by its identifier.
    case urlSessionEvents(String)
}

/// The conditions background work depends on.
struct EnvironmentSnapshot: Hashable, Sendable {
    enum Network: Hashable, Sendable {
        case none
        /// Wi-Fi or wired, without Low Data Mode.
        case unmetered
        /// Cellular or a personal hotspot.
        case expensive
        /// Low Data Mode.
        case constrained
    }

    var appActive: Bool
    var network: Network
    var charging: Bool
    var thermal: ProcessInfo.ThermalState
    var lowPower: Bool
}

enum LifecycleEvent: Sendable {
    /// A background task started and may run until its lease expires.
    case window(BGTaskLease)
    case becameActive
    case enteredBackground
    case environment(EnvironmentSnapshot)
    case photoLibraryChanged
    case urlSessionEvents(String)
    case preferencesChanged
    case readOnlyChanged
}

/// The two kinds of background time iOS grants, under the identifiers every build has registered.
enum BackgroundWindowKind: String, CaseIterable, Hashable, Sendable {
    /// A BGProcessingTask: minutes, at a time iOS picks, optionally only on power.
    case processing
    /// A BGAppRefreshTask: about thirty seconds.
    case refresh

    var identifier: String {
        switch self {
        case .processing: "app.ilyich.native.backup.processing"
        case .refresh: "app.ilyich.native.backup.refresh"
        }
    }

    init?(identifier: String) {
        guard let kind = Self.allCases.first(where: { $0.identifier == identifier }) else { return nil }
        self = kind
    }
}

/// The background windows the transfer engine wants iOS to grant. It holds delays, not dates, so
/// working out the same plan again gives an equal value, and LifecycleEventSource submits a
/// request only when the plan changes or iOS used up the last one: a burst of library changes
/// never pushes a window back.
struct SchedulePlan: Hashable, Sendable {
    struct Processing: Hashable, Sendable {
        var requiresExternalPower: Bool
        /// From when the request is submitted.
        var earliestBegin: Duration
    }

    var processing: Processing?
    /// From when the request is submitted; nil asks for no refresh window.
    var refresh: Duration?

    /// No windows.
    static let none = SchedulePlan(processing: nil, refresh: nil)

    /// What automatic backup asks for, as BackupLifecycle schedules today: a processing window,
    /// needing the network, no sooner than the trigger delay (at least 30 s), and a refresh window
    /// after five minutes.
    static func automatic(requireCharging: Bool, triggerDelay: Int) -> SchedulePlan {
        SchedulePlan(processing: Processing(requiresExternalPower: requireCharging, earliestBegin: .seconds(max(30, triggerDelay))),
                     refresh: .seconds(5 * 60))
    }
}

/// A background task's time. It completes exactly once: when the work finishes, or with failure
/// the moment iOS takes the time back, synchronously, so the expiration handler never waits.
final class BGTaskLease: Sendable {
    let identifier: String
    let kind: BackgroundWindowKind
    private let complete: @Sendable (Bool) -> Void
    private struct State {
        var completed = false
        var expired = false
        var onExpiration: [@Sendable () -> Void] = []
    }
    private let state = Mutex(State())

    /// Complete calls the task's setTaskCompleted(success:). The kind comes from the identifier,
    /// processing for one this app never registered.
    init(identifier: String, complete: @escaping @Sendable (Bool) -> Void) {
        self.identifier = identifier
        kind = BackgroundWindowKind(identifier: identifier) ?? .processing
        self.complete = complete
    }

    var isCompleted: Bool { state.withLock { $0.completed } }
    var isExpired: Bool { state.withLock { $0.expired } }

    func finish(success: Bool) {
        let first = state.withLock { state in
            defer { state.completed = true }
            return !state.completed
        }
        if first { complete(success) }
    }

    /// For the task's expiration handler: completes the task first, then tells the work to stop.
    func expire() {
        finish(success: false)
        let handlers = state.withLock { state -> [@Sendable () -> Void] in
            guard !state.expired else { return [] }
            state.expired = true
            defer { state.onExpiration = [] }
            return state.onExpiration
        }
        for handler in handlers { handler() }
    }

    /// Runs `handler` when iOS takes the time back, at once if it already has.
    func onExpiration(_ handler: @escaping @Sendable () -> Void) {
        let expired = state.withLock { state -> Bool in
            if !state.expired { state.onExpiration.append(handler) }
            return state.expired
        }
        if expired { handler() }
    }
}
