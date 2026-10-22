import Foundation
import IlyichPlatform

struct UploadProgressSnapshot: Sendable {
    let taskID: Int
    let sent: Int64
    let expected: Int64
}

/// URLSession owns transfer lifetime. Receipts survive a terminated app and are
/// written before continuations are resumed, closing the completion/relaunch race.
final class BackgroundUploads: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = BackgroundUploads(identifier: identifier)
    static let sharing = BackgroundUploads(identifier: shareIdentifier)
    static var identifier: String { (Bundle.main.bundleIdentifier ?? "app.alextran.immich") + ".backup" }
    static var shareIdentifier: String { (Bundle.main.bundleIdentifier ?? "app.alextran.immich") + ".share-upload" }

    struct Descriptor: Codable, Equatable { let id: String; let receipt: URL }
    struct Outcome: Codable { let receipt: UploadReceipt?; let error: String?; var httpStatus: Int? }
    private struct TransferError: LocalizedError { let errorDescription: String? }
    private let lock = NSLock()
    private var responses: [Int: Data] = [:]
    private var waiting: [Int: CheckedContinuation<UploadReceipt, any Error>] = [:]
    private var eventsCompletion: (@Sendable () -> Void)?
    private let identifier: String
    private var progressReported: (taskID: Int, time: ContinuousClock.Instant)?
    private var session: URLSession!

    private init(identifier: String) {
        self.identifier = identifier
        super.init()
        let configuration = TransferSessionConfiguration.make(identifier: identifier)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    func handleEvents(completion: @escaping @Sendable () -> Void) {
        lock.withLock { eventsCompletion = completion }
    }

    func completedReceipt(at url: URL) -> UploadReceipt? {
        lock.withLock {
            guard let data = try? Data(contentsOf: url), let outcome = try? JSONDecoder().decode(Outcome.self, from: data) else { return nil }
            return outcome.receipt
        }
    }

    func clearFailedReceipt(at url: URL) {
        lock.withLock {
            guard let data = try? Data(contentsOf: url), let outcome = try? JSONDecoder().decode(Outcome.self, from: data), outcome.receipt == nil else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    func upload(_ request: URLRequest, body: URL, id: String, receipt: URL) async throws -> UploadReceipt {
        if let saved = try KeychainCredentialStore().load(), ReadOnlyPolicy.isEnabled(server: saved.server, userID: saved.userID) {
            throw ReadOnlyPolicy.ReadOnlyError()
        }
        let descriptor = Descriptor(id: id, receipt: receipt)
        let description = String(decoding: try JSONEncoder().encode(descriptor), as: UTF8.self)
        let existing = await session.allTasks.first { task in
            guard let text = task.taskDescription,
                  let existing = try? JSONDecoder().decode(Descriptor.self, from: Data(text.utf8)) else { return false }
            return existing == descriptor
        }
        let task = existing ?? session.uploadTask(with: request, fromFile: body)
        task.taskDescription = description
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let completed = lock.withLock { () -> Bool in
                    if let data = try? Data(contentsOf: receipt), let outcome = try? JSONDecoder().decode(Outcome.self, from: data) {
                        if let value = outcome.receipt { continuation.resume(returning: value) }
                        // A recorded outcome keeps only the status, as earlier builds wrote it.
                        else if let status = outcome.httpStatus, !(200..<300).contains(status) { continuation.resume(throwing: ServerFailure.http(status, nil)) }
                        else { continuation.resume(throwing: TransferError(errorDescription: outcome.error)) }
                        return true
                    }
                    waiting[task.taskIdentifier] = continuation
                    return false
                }
                if completed { if existing == nil { task.taskDescription = nil; task.cancel() } }
                else { task.resume() }
            }
        } onCancel: { task.cancel() }
    }

    func cancelAll() async {
        let tasks = await session.allTasks
        for task in tasks { task.cancel() }
    }

    /// Hands each upload's progress in the session `identifier` to `observer` as the session
    /// reports it, at most four times a second per upload and always at its last byte, so no
    /// screen has to poll for it. It is kept apart from the session, so that registering it at
    /// launch doesn't make the session: one relaunched for its events must not deliver them
    /// before handleEventsForBackgroundURLSession has handed over its completion.
    static func observeProgress(of identifier: String, _ observer: @escaping @Sendable (UploadProgressSnapshot) -> Void) {
        progressObservers.set(observer, for: identifier)
    }

    private static let progressObservers = ProgressObservers()

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let now = ContinuousClock.now
        guard let observer = Self.progressObservers.observer(for: identifier) else { return }
        let report = lock.withLock { () -> Bool in
            if let last = progressReported, last.taskID == task.taskIdentifier, last.time.duration(to: now) < .milliseconds(250),
               totalBytesSent < totalBytesExpectedToSend { return false }
            progressReported = (task.taskIdentifier, now)
            return true
        }
        guard report else { return }
        observer(UploadProgressSnapshot(taskID: task.taskIdentifier, sent: totalBytesSent, expected: totalBytesExpectedToSend))
    }

    func hasActiveTransfer() async -> Bool { await session.allTasks.contains { $0.state == .running } }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock {
            // Upload responses are tiny JSON. Never buffer an arbitrary server response.
            if (responses[dataTask.taskIdentifier]?.count ?? 0) + data.count <= 64 * 1024 {
                responses[dataTask.taskIdentifier, default: Data()].append(data)
            } else { dataTask.cancel() }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.withLock {
            let data = responses.removeValue(forKey: task.taskIdentifier) ?? Data()
            let result: Result<UploadReceipt, any Error>
            do {
                if let error { throw error }
                guard let response = task.response else { throw APIError.invalidResponse("The upload returned no server response.") }
                try ServerFailure.check(response, body: data, path: "assets")
                let receipt = try JSONDecoder().decode(UploadReceipt.self, from: data)
                guard UUID(uuidString: receipt.id) != nil, ["created", "duplicate"].contains(receipt.status) else {
                    throw TransferError(errorDescription: "The server did not confirm this upload. Retry to verify its checksum.")
                }
                result = .success(receipt)
            } catch { result = .failure(error) }
            if let text = task.taskDescription,
               let descriptor = try? JSONDecoder().decode(Descriptor.self, from: Data(text.utf8)) {
                let outcome: Outcome
                switch result {
                case .success(let receipt): outcome = Outcome(receipt: receipt, error: nil)
                case .failure(let error): outcome = Outcome(receipt: nil, error: error.localizedDescription,
                    httpStatus: (task.response as? HTTPURLResponse)?.statusCode)
                }
                // Failure to persist is surfaced rather than claiming a resumable success.
                do { try JSONEncoder().encode(outcome).write(to: descriptor.receipt, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
                catch {
                    waiting.removeValue(forKey: task.taskIdentifier)?.resume(throwing: error)
                    return
                }
            }
            waiting.removeValue(forKey: task.taskIdentifier)?.resume(with: result)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Redirecting a multipart POST can lose its body or forward credentials.
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let saved = try? KeychainCredentialStore().load(), let request = task.originalRequest, let url = request.url,
              let configuration = try? NetworkConfigurationStore.load(server: saved.server),
              Self.offersCertificate(for: request, saved: saved, configuration: configuration) else {
            completionHandler(.performDefaultHandling, nil); return
        }
        ClientCertificateStore.respond(to: challenge, server: saved.server, requestURL: url, completion: completionHandler)
    }

    /// Whether an upload may be offered the saved client certificate: it carries the saved
    /// session's token and goes to one of the server's configured addresses, the local one included.
    static func offersCertificate(for request: URLRequest, saved: StoredCredential, configuration: NetworkConfiguration) -> Bool {
        guard let url = request.url,
              request.value(forHTTPHeaderField: "Authorization") == "Bearer \(saved.token)" ||
              request.value(forHTTPHeaderField: "x-immich-user-token") == saved.token else { return false }
        return configuration.isConfiguredEndpoint(url, primary: saved.server)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = lock.withLock { let value = eventsCompletion; eventsCompletion = nil; return value }
        if let completion { DispatchQueue.main.async(execute: completion) }
    }
}

/// The progress observers of each background session, by its identifier.
private final class ProgressObservers: @unchecked Sendable {
    private let lock = NSLock()
    private var observers: [String: @Sendable (UploadProgressSnapshot) -> Void] = [:]

    func set(_ observer: @escaping @Sendable (UploadProgressSnapshot) -> Void, for identifier: String) {
        lock.withLock { observers[identifier] = observer }
    }

    func observer(for identifier: String) -> (@Sendable (UploadProgressSnapshot) -> Void)? {
        lock.withLock { observers[identifier] }
    }
}
