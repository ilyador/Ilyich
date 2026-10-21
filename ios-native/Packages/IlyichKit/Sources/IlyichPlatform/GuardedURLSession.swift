import Foundation
import Synchronization

/// A URLSession that can be shut down while other code still sends requests through it.
///
/// URLSession raises an exception when a task is made on a session that was invalidated, and its
/// async methods make their task only after leaving the caller's actor, so no flag checked
/// beforehand rules that out. Here every task is made under a lock that invalidation takes too:
/// once the session is invalidated, new requests end with CancellationError instead.
///
/// Redirects are followed only within the origin, carrying the token and custom headers, and
/// the origin's client certificate is offered when a server asks for one.
public final class GuardedURLSession: Sendable {
    private let state: Mutex<URLSession?>
    private let router: SessionRouter

    public init(configuration: URLSessionConfiguration, origin: URL) {
        let router = SessionRouter(policy: SameOriginRedirectDelegate(origin: origin))
        self.router = router
        state = Mutex(URLSession(configuration: configuration, delegate: router, delegateQueue: nil))
    }

    deinit {
        // A session nobody shut down still lets go of its delegate once its tasks are done.
        state.withLock { $0 }?.finishTasksAndInvalidate()
    }

    /// Whether invalidate has run.
    public var isInvalidated: Bool { state.withLock { $0 == nil } }

    /// Cancels every task and lets the session go. Requests made afterwards throw CancellationError.
    public func invalidate() {
        let session = state.withLock { session -> URLSession? in
            defer { session = nil }
            return session
        }
        session?.invalidateAndCancel()
    }

    /// Makes a task on the live session, or returns nil once the session is invalidated.
    public func makeTask<T: URLSessionTask>(_ make: (URLSession) -> T) -> T? {
        state.withLock { session in session.map(make) }
    }

    /// The answer to a request, as URLSession.data(for:) gives it.
    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await run { session, finish in
            session.dataTask(with: request) { data, response, error in finish(data, response, error) }
        }
    }

    /// The answer to an upload, as URLSession.upload(for:from:) gives it.
    public func upload(for request: URLRequest, from body: Data) async throws -> (Data, URLResponse) {
        try await run { session, finish in
            session.uploadTask(with: request, from: body) { data, response, error in finish(data, response, error) }
        }
    }

    /// Downloads into a new temporary file, which the caller then owns and removes. `starting`
    /// sees the task before it runs, for observing its progress.
    public func download(for request: URLRequest, starting: (@Sendable (URLSessionTask) -> Void)? = nil) async throws -> (URL, URLResponse) {
        let handle = TaskHandle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(URL, URLResponse), any Error>) in
                let task = makeTask { session in
                    session.downloadTask(with: request) { location, response, error in
                        // URLSession deletes the file once this returns, so it moves now.
                        do {
                            if let error { throw error }
                            guard let location, let response else { throw URLError(.badServerResponse) }
                            let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".download")
                            try FileManager.default.moveItem(at: location, to: kept)
                            continuation.resume(returning: (kept, response))
                        } catch { continuation.resume(throwing: error) }
                    }
                }
                guard let task else { return continuation.resume(throwing: CancellationError()) }
                starting?(task)
                handle.start(task)
            }
        } onCancel: { handle.cancel() }
    }

    /// Sends a request whose answer is read as it arrives, for answers too long to hold in memory.
    /// Returns once the response's headers are in. While more than a few megabytes wait to be
    /// read, the transfer pauses. It ends when the reader is cancelled while it waits for a
    /// piece, or lets go of the body before the end.
    public func stream(for request: URLRequest) async throws -> (URLResponse, ResponseBody) {
        let handle = TaskHandle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(URLResponse, ResponseBody), any Error>) in
                let task = makeTask { session in session.dataTask(with: request) }
                guard let task else { return continuation.resume(throwing: CancellationError()) }
                router.register(task, response: continuation)
                handle.start(task)
            }
        } onCancel: { handle.cancel() }
    }

    /// A WebSocket on the live session, not yet resumed, or nil once the session is invalidated.
    public func webSocketTask(with request: URLRequest) -> URLSessionWebSocketTask? {
        makeTask { session in session.webSocketTask(with: request) }
    }

    private typealias Finish = @Sendable (Data?, URLResponse?, (any Error)?) -> Void

    private func run(_ make: (URLSession, @escaping Finish) -> URLSessionTask) async throws -> (Data, URLResponse) {
        let handle = TaskHandle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), any Error>) in
                let task = makeTask { session in
                    make(session) { data, response, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let response { continuation.resume(returning: (data ?? Data(), response)) }
                        else { continuation.resume(throwing: URLError(.badServerResponse)) }
                    }
                }
                guard let task else { return continuation.resume(throwing: CancellationError()) }
                handle.start(task)
            }
        } onCancel: { handle.cancel() }
    }
}

/// An answer's body as it arrives, in pieces.
public struct ResponseBody: AsyncSequence, Sendable {
    public typealias Element = Data
    let chunks: AsyncThrowingStream<Data, any Error>
    let flow: FlowControl

    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: AsyncThrowingStream<Data, any Error>.AsyncIterator
        let flow: FlowControl

        public mutating func next() async throws -> Data? { try await next(isolation: nil) }

        public mutating func next(isolation actor: isolated (any Actor)?) async throws -> Data? {
            guard let chunk = try await base.next(isolation: actor) else {
                // The pieces stop early when the reader is cancelled. That is not the end of the
                // answer, and must not read as one.
                try Task.checkCancellation()
                return nil
            }
            flow.consumed(chunk.count)
            return chunk
        }
    }

    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(base: chunks.makeAsyncIterator(), flow: flow) }
}

/// Pauses a transfer while its reader falls behind, so a long answer never piles up in memory.
final class FlowControl: Sendable {
    static let pauseAbove = 8 * 1024 * 1024
    static let resumeBelow = 2 * 1024 * 1024
    private let task: URLSessionTask
    private let state = Mutex<(waiting: Int, paused: Bool)>((0, false))

    init(task: URLSessionTask) { self.task = task }

    func received(_ count: Int) {
        state.withLock { state in
            state.waiting += count
            guard !state.paused, state.waiting > Self.pauseAbove else { return }
            state.paused = true
            task.suspend()
        }
    }

    func consumed(_ count: Int) {
        state.withLock { state in
            state.waiting -= count
            guard state.paused, state.waiting < Self.resumeBelow else { return }
            state.paused = false
            task.resume()
        }
    }
}

/// Starts the task behind one call and cancels it when the caller is cancelled, even if that
/// happens before the task exists.
private final class TaskHandle: Sendable {
    private let state = Mutex<(task: URLSessionTask?, cancelled: Bool)>((nil, false))

    func start(_ task: URLSessionTask) {
        let cancelled = state.withLock { state in
            state.task = task
            return state.cancelled
        }
        task.resume()
        if cancelled { task.cancel() }
    }

    func cancel() {
        let task = state.withLock { state in
            state.cancelled = true
            return state.task
        }
        task?.cancel()
    }
}

/// The session delegate: the redirect and certificate policy for every task, and the pieces of
/// streamed answers for the tasks that read as they arrive. Tasks with completion handlers get
/// their data there instead.
private final class SessionRouter: NSObject, URLSessionDataDelegate, Sendable {
    /// A streamed answer. Once the headers are in, the router keeps only what feeds the pieces in
    /// and never the body itself, so the reader alone holds that.
    private struct Stream: Sendable {
        /// The caller waiting for the headers, and the body it is handed with them.
        var waiting: (response: CheckedContinuation<(URLResponse, ResponseBody), any Error>, body: ResponseBody)?
        let chunks: AsyncThrowingStream<Data, any Error>.Continuation
        let flow: FlowControl
    }

    private let policy: SameOriginRedirectDelegate
    private let streams = Mutex<[Int: Stream]>([:])

    init(policy: SameOriginRedirectDelegate) { self.policy = policy }

    func register(_ task: URLSessionDataTask, response: CheckedContinuation<(URLResponse, ResponseBody), any Error>) {
        let (chunks, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        // A reader that stops early, or is cancelled, ends the transfer: the pieces end when a
        // reader waiting for one is cancelled, or once nothing holds the body or an iterator of
        // it. A transfer paused for a reader that is gone would otherwise wait for good.
        continuation.onTermination = { _ in task.cancel() }
        let flow = FlowControl(task: task)
        let body = ResponseBody(chunks: chunks, flow: flow)
        streams.withLock { $0[task.taskIdentifier] = Stream(waiting: (response, body), chunks: continuation, flow: flow) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        policy.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        policy.urlSession(session, task: task, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let ready = streams.withLock { streams -> (response: CheckedContinuation<(URLResponse, ResponseBody), any Error>, body: ResponseBody)? in
            guard var stream = streams[dataTask.taskIdentifier], let waiting = stream.waiting else { return nil }
            // From here on the caller alone holds the body.
            stream.waiting = nil
            streams[dataTask.taskIdentifier] = stream
            return waiting
        }
        completionHandler(.allow)
        if let ready { ready.response.resume(returning: (response, ready.body)) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let stream = streams.withLock({ $0[dataTask.taskIdentifier] }) else { return }
        stream.flow.received(data.count)
        stream.chunks.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let stream = streams.withLock({ $0.removeValue(forKey: task.taskIdentifier) }) else { return }
        stream.waiting?.response.resume(throwing: error ?? URLError(.badServerResponse))
        if let error { stream.chunks.finish(throwing: error) } else { stream.chunks.finish() }
    }
}
