import Foundation
import IlyichPlatform
import os

/// Per-call delegate for `URLSession.download(for:delegate:)`. A task delegate replaces the session delegate for
/// redirect and challenge handling, so both are forwarded to the same-origin policy explicitly.
final class DownloadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let policy: SameOriginRedirectDelegate
    private let progress: @Sendable (Double?) -> Void
    private let lastStep = OSAllocatedUnfairLock(initialState: -2)
    private let observation = OSAllocatedUnfairLock<NSKeyValueObservation?>(initialState: nil)

    init(origin: URL, progress: @escaping @Sendable (Double?) -> Void) {
        policy = SameOriginRedirectDelegate(origin: origin)
        self.progress = progress
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        // Async downloads do not forward download-delegate byte callbacks. Observe the task before it resumes.
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

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        policy.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        policy.urlSession(session, task: task, didReceive: challenge, completionHandler: completionHandler)
    }
}
