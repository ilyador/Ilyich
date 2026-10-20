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

/// A background task's time. It completes exactly once: when the work finishes, or with failure
/// the moment iOS takes the time back, synchronously, so the expiration handler never waits.
final class BGTaskLease: Sendable {
    let identifier: String
    private let complete: @Sendable (Bool) -> Void
    private let completed = Mutex(false)

    /// Complete calls the task's setTaskCompleted(success:).
    init(identifier: String, complete: @escaping @Sendable (Bool) -> Void) {
        self.identifier = identifier
        self.complete = complete
    }

    var isCompleted: Bool { completed.withLock { $0 } }

    func finish(success: Bool) {
        let first = completed.withLock { done in
            defer { done = true }
            return !done
        }
        if first { complete(success) }
    }

    /// For the task's expiration handler.
    func expire() { finish(success: false) }
}
