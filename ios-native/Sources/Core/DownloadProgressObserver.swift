import Foundation
import os

/// Reports a download's progress, a step of a percent at a time, by observing its task. The
/// transport's session delegate keeps handling the download's redirects and certificates.
final class DownloadProgressObserver: Sendable {
    private let progress: @Sendable (Double?) -> Void
    private let lastStep = OSAllocatedUnfairLock(initialState: -2)
    private let observation = OSAllocatedUnfairLock<NSKeyValueObservation?>(initialState: nil)

    init(progress: @escaping @Sendable (Double?) -> Void) { self.progress = progress }

    /// Starts observing a task before it resumes.
    func observe(_ task: URLSessionTask) {
        let token = task.progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self, weak task] _, _ in
            guard let task else { return }
            let expected = task.countOfBytesExpectedToReceive
            let fraction = expected > 0 ? min(1, max(0, Double(task.countOfBytesReceived) / Double(expected))) : nil
            self?.report(fraction)
        }
        observation.withLock { $0 = token }
    }

    func stopObserving() {
        let token = observation.withLock { value in let previous = value; value = nil; return previous }
        token?.invalidate()
    }

    private func report(_ fraction: Double?) {
        let step = fraction.map { Int($0 * 100) } ?? -1
        let changed = lastStep.withLock { last -> Bool in
            guard last != step else { return false }
            last = step; return true
        }
        if changed { progress(fraction) }
    }
}
