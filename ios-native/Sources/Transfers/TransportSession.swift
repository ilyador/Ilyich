import Foundation
import IlyichPlatform
import Synchronization

/// A background URLSession as BackgroundTransport uses it, so tests can stand in for iOS.
protocol TransportSession: Sendable {
    /// The tasks iOS holds for the session, including those from an earlier launch or build.
    func tasks() async -> [SessionTask]
    /// Creates an upload task from a file, describes it and resumes it. Returns the task's ID.
    func startUpload(_ request: URLRequest, fromFile body: URL, description: String) -> Int
    /// Resumes a task. Resuming a running task changes nothing.
    func resumeTask(_ id: Int) async
    /// Cancels a task. A task that is gone is ignored.
    func cancelTask(_ id: Int) async
}

struct SessionTask: Equatable, Sendable {
    let id: Int
    let description: String?
    let state: TransportTaskSnapshot.State
    let sent: Int64
    let expected: Int64
}

/// The TaskEventHandling seam: what a background session's delegate reports, in plain values.
/// The live delegate turns URLSession callbacks into these calls on the session's serial delegate
/// queue, and tests make the same calls to play a session's events without iOS.
protocol TaskEventHandling: Sendable {
    /// More of a task's answer. Returns false when the task must be cancelled.
    func task(_ id: Int, didReceive data: Data) -> Bool
    func task(_ id: Int, description: String?, didSend sent: Int64, of expected: Int64)
    func taskDidComplete(_ task: CompletedTask)
    /// iOS has delivered every event it queued for the session.
    func sessionDidFinishEvents()
}

/// A finished task, as its delegate saw it.
struct CompletedTask: Equatable, Sendable {
    struct Failure: Equatable, Sendable {
        let domain: String
        let code: Int
        /// In the phone's language: recorded for display, never parsed.
        let description: String
        /// NSURLErrorBackgroundTaskCancelledReasonKey, when iOS cancelled the task.
        let cancelReason: Int?

        init(domain: String, code: Int, description: String, cancelReason: Int? = nil) {
            self.domain = domain
            self.code = code
            self.description = description
            self.cancelReason = cancelReason
        }

        init(_ error: any Error) {
            let details = error as NSError
            self.init(domain: details.domain, code: details.code, description: details.localizedDescription,
                      cancelReason: details.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] as? Int)
        }
    }

    let id: Int
    let description: String?
    /// The answer's status, when the server answered.
    let httpStatus: Int?
    let failure: Failure?
}

/// The real background session for one TransferSessionID. B9 creates one per identifier at launch;
/// until then nothing in the app does, and `created` stays zero, which a test checks.
final class URLSessionTransportSession: TransportSession {
    /// How many this process has created.
    static var created: Int { count.withLock { $0 } }
    private static let count = Mutex(0)

    private let session: URLSession

    init(_ id: TransferSessionID, handler: any TaskEventHandling, challenges: UploadChallengeResponder = UploadChallengeResponder()) {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "app.ilyich.transfers." + id.rawValue
        session = URLSession(configuration: TransferSessionConfiguration.make(identifier: id.identifier),
                             delegate: BackgroundSessionDelegate(handler: handler, challenges: challenges), delegateQueue: queue)
        Self.count.withLock { $0 += 1 }
    }

    func tasks() async -> [SessionTask] {
        await session.allTasks.map {
            SessionTask(id: $0.taskIdentifier, description: $0.taskDescription, state: TransportTaskSnapshot.State($0.state),
                        sent: $0.countOfBytesSent, expected: $0.countOfBytesExpectedToSend)
        }
    }

    func startUpload(_ request: URLRequest, fromFile body: URL, description: String) -> Int {
        let task = session.uploadTask(with: request, fromFile: body)
        // Described before it resumes, so even an instant failure reaches the delegate described.
        task.taskDescription = description
        task.resume()
        return task.taskIdentifier
    }

    func resumeTask(_ id: Int) async { await session.allTasks.first { $0.taskIdentifier == id }?.resume() }

    func cancelTask(_ id: Int) async { await session.allTasks.first { $0.taskIdentifier == id }?.cancel() }
}

extension TransportTaskSnapshot.State {
    init(_ state: URLSessionTask.State) {
        switch state {
        case .running: self = .running
        case .suspended: self = .suspended
        case .canceling: self = .canceling
        case .completed: self = .completed
        @unknown default: self = .completed
        }
    }
}

/// Turns a background session's delegate callbacks into TaskEventHandling calls. It refuses every
/// redirect, since redirecting a multipart POST can drop its body or forward its credentials, and
/// answers client certificate challenges through UploadChallengeResponder.
final class BackgroundSessionDelegate: NSObject, URLSessionDataDelegate, Sendable {
    private let handler: any TaskEventHandling
    private let challenges: UploadChallengeResponder

    init(handler: any TaskEventHandling, challenges: UploadChallengeResponder) {
        self.handler = handler
        self.challenges = challenges
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if !handler.task(dataTask.taskIdentifier, didReceive: data) { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        handler.task(task.taskIdentifier, description: task.taskDescription, didSend: totalBytesSent, of: totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        handler.taskDidComplete(CompletedTask(id: task.taskIdentifier, description: task.taskDescription,
                                              httpStatus: (task.response as? HTTPURLResponse)?.statusCode,
                                              failure: error.map(CompletedTask.Failure.init)))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        handler.sessionDidFinishEvents()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        challenges.respond(to: challenge, request: task.originalRequest, completion: completionHandler)
    }
}

/// Answers a client certificate challenge with the certificate saved for the signed-in server,
/// through IlyichPlatform's ClientCertificateStore, but only for a request that carries the
/// signed-in token to one of that server's configured addresses, the local one included. Any other
/// request gets the system's default handling.
struct UploadChallengeResponder: Sendable {
    typealias Completion = @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void

    var credential: @Sendable () -> StoredCredential? = { try? KeychainCredentialStore().load() }
    var configuration: @Sendable (_ server: URL) -> NetworkConfiguration? = { try? NetworkConfigurationStore.load(server: $0) }
    var answer: @Sendable (URLAuthenticationChallenge, _ server: URL, _ requestURL: URL, @escaping Completion) -> Void = {
        ClientCertificateStore.respond(to: $0, server: $1, requestURL: $2, completion: $3)
    }

    func respond(to challenge: URLAuthenticationChallenge, request: URLRequest?, completion: @escaping Completion) {
        guard let saved = credential(), let request, let url = request.url,
              request.value(forHTTPHeaderField: "Authorization") == "Bearer \(saved.token)"
                || request.value(forHTTPHeaderField: "x-immich-user-token") == saved.token,
              let settings = configuration(saved.server) else {
            completion(.performDefaultHandling, nil); return
        }
        let addresses = [saved.server] + settings.alternateEndpoints + [settings.localEndpoint].compactMap { $0 }
        guard addresses.contains(where: { SameOriginRedirectDelegate.sameOrigin($0, url) }) else {
            completion(.performDefaultHandling, nil); return
        }
        answer(challenge, saved.server, url, completion)
    }
}
