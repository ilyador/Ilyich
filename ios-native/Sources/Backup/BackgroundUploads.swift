import Foundation

/// URLSession owns transfer lifetime. Receipts survive a terminated app and are
/// written before continuations are resumed, closing the completion/relaunch race.
final class BackgroundUploads: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = BackgroundUploads()
    static var identifier: String { (Bundle.main.bundleIdentifier ?? "app.alextran.immich") + ".backup" }

    private struct Descriptor: Codable, Equatable { let id: String; let receipt: URL }
    private struct Outcome: Codable { let receipt: UploadReceipt?; let error: String? }
    private struct TransferError: LocalizedError { let errorDescription: String? }
    private let lock = NSLock()
    private var responses: [Int: Data] = [:]
    private var waiting: [Int: CheckedContinuation<UploadReceipt, any Error>] = [:]
    private var eventsCompletion: (@Sendable () -> Void)?
    private var session: URLSession!

    private override init() {
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.sharedContainerIdentifier = try? SessionKeychain.appGroup
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    func handleEvents(completion: @escaping @Sendable () -> Void) {
        lock.withLock { eventsCompletion = completion }
    }

    func upload(_ request: URLRequest, body: URL, id: String, receipt: URL) async throws -> UploadReceipt {
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

    func currentProgress() async -> Double? {
        guard let task = await session.allTasks.first, task.countOfBytesExpectedToSend > 0 else { return nil }
        return Double(task.countOfBytesSent) / Double(task.countOfBytesExpectedToSend)
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
                guard let response = task.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                    throw TransferError(errorDescription: "Upload failed (HTTP \((task.response as? HTTPURLResponse)?.statusCode ?? 0)). Retry after checking your server.")
                }
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
                case .failure(let error): outcome = Outcome(receipt: nil, error: error.localizedDescription)
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

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = lock.withLock { let value = eventsCompletion; eventsCompletion = nil; return value }
        if let completion { DispatchQueue.main.async(execute: completion) }
    }
}
