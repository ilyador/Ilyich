import Foundation
import IlyichPlatform
import Synchronization

/// Downloads grid thumbnails for the scheduler. The session keeps the configuration thumbnails
/// always had: no URL cache or cookies, six connections, 30 s per request. A request is made from
/// a template built once every few seconds instead of asking the account's transport for every
/// photo; a failure rebuilds it, so a new address or token is picked up. A photo whose download
/// failed waits before it is tried again, longer after each failure. Downloads the grid shows
/// now go at high priority, coverage at low.
final class ThumbnailFetcher: Sendable {
    /// Loads one thumbnail's bytes at a URLSession task priority.
    typealias Load = @Sendable (_ assetID: String, _ revision: String, _ priority: Float) async throws -> Data

    private struct Backoff {
        var failures: Int
        var retryAt: TimeInterval
    }
    private let load: Load
    private let now: @Sendable () -> TimeInterval
    private let backoff = Mutex<[String: Backoff]>([:])
    /// The first wait after a failure, doubled after each further one up to `maximumDelay`.
    let baseDelay: TimeInterval
    let maximumDelay: TimeInterval

    init(load: @escaping Load, baseDelay: TimeInterval = 2, maximumDelay: TimeInterval = 300,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.load = load
        self.baseDelay = baseDelay
        self.maximumDelay = maximumDelay
        self.now = now
    }

    /// Downloads from `client`'s server with today's thumbnail session.
    convenience init(client: APIClient, protocolClasses: [AnyClass]? = nil) {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.timeoutIntervalForRequest = 30
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        let session = URLSession(configuration: configuration, delegate: SameOriginRedirectDelegate(origin: client.baseURL), delegateQueue: nil)
        let template = ThumbnailRequestTemplate(client: client)
        self.init(load: { assetID, revision, priority in
            let request: URLRequest
            do { request = try await template.request(assetID: assetID, revision: revision) } catch { template.invalidate(); throw error }
            do {
                let (data, response) = try await session.data(for: request, delegate: TaskPriority(priority))
                try ServerFailure.check(response, body: data)
                return data
            } catch {
                template.invalidate()
                throw error
            }
        })
    }

    static func key(assetID: String, revision: String) -> String { assetID + "|" + revision }

    /// When the photo may be downloaded again, if it is waiting after a failure.
    func retryTime(assetID: String, revision: String) -> TimeInterval? {
        let key = Self.key(assetID: assetID, revision: revision), now = now()
        return backoff.withLock { backoff in
            guard let entry = backoff[key], entry.retryAt > now else { return nil }
            return entry.retryAt
        }
    }

    func currentTime() -> TimeInterval { now() }

    /// Starts a download and calls `completion` once with its result. Cancelling the task cancels
    /// the download. Failures other than cancellation make the photo wait.
    func fetch(assetID: String, revision: String, band: DemandBand,
               completion: @escaping @Sendable (Result<Data, Error>) -> Void) -> Task<Void, Never> {
        let load = load
        let priority: Float = band <= .target ? URLSessionTask.highPriority : band == .coverage ? URLSessionTask.lowPriority : URLSessionTask.defaultPriority
        return Task.detached(priority: band <= .explicit ? .userInitiated : .utility) { [self] in
            do {
                let data = try await load(assetID, revision, priority)
                succeeded(assetID: assetID, revision: revision)
                completion(.success(data))
            } catch {
                if !Self.isCancellation(error) { failed(assetID: assetID, revision: revision) }
                completion(.failure(error))
            }
        }
    }

    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private func succeeded(assetID: String, revision: String) {
        let key = Self.key(assetID: assetID, revision: revision)
        backoff.withLock { _ = $0.removeValue(forKey: key) }
    }

    private func failed(assetID: String, revision: String) {
        let key = Self.key(assetID: assetID, revision: revision), now = now()
        backoff.withLock { backoff in
            let failures = (backoff[key]?.failures ?? 0) + 1
            let delay = min(maximumDelay, baseDelay * pow(2, Double(failures - 1)))
            backoff[key] = Backoff(failures: failures, retryAt: now + delay)
            // Old entries go once there are many; a photo that failed long ago may simply try again.
            if backoff.count > 2_000 { backoff = backoff.filter { $0.value.retryAt > now } }
        }
    }

    /// Every waiting photo may be tried again, as after signing in again.
    func clearBackoff() { backoff.withLock { $0.removeAll() } }
}

/// One thumbnail request, built by the account's transport, reused for every photo for a few
/// seconds by putting the photo's ID and revision in place.
final class ThumbnailRequestTemplate: Sendable {
    private static let placeholderID = "ilyich-thumbnail-asset"
    private static let placeholderRevision = "ilyich-thumbnail-revision"
    private static let lifetime: TimeInterval = 10
    private let client: APIClient
    private let cached = Mutex<(request: URLRequest, built: TimeInterval)?>(nil)

    init(client: APIClient) { self.client = client }

    func invalidate() { cached.withLock { $0 = nil } }

    func request(assetID: String, revision: String) async throws -> URLRequest {
        let now = ProcessInfo.processInfo.systemUptime
        let template: URLRequest
        if let fresh = cached.withLock({ cached in cached.flatMap { now - $0.built < Self.lifetime ? $0.request : nil } }) {
            template = fresh
        } else {
            template = try await client.authorizedRequest(path: "assets/\(Self.placeholderID)/thumbnail", query: [
                .init(name: "size", value: MediaSize.thumbnail.rawValue), .init(name: "edited", value: "true"),
                .init(name: "c", value: Self.placeholderRevision)
            ])
            cached.withLock { $0 = (template, now) }
        }
        return try Self.specialize(template, assetID: assetID, revision: revision)
    }

    static func specialize(_ template: URLRequest, assetID: String, revision: String) throws -> URLRequest {
        guard let url = template.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = assetID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))),
              components.percentEncodedPath.contains(placeholderID) else { throw URLError(.badURL) }
        components.percentEncodedPath = components.percentEncodedPath.replacingOccurrences(of: placeholderID, with: id)
        // Encoded as ServerAddress encodes every request's query, "+" included.
        components.queryItems = components.queryItems?.map { $0.name == "c" ? URLQueryItem(name: "c", value: revision) : $0 }
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let specialized = components.url else { throw URLError(.badURL) }
        var request = template
        request.url = specialized
        return request
    }
}

/// Sets a download's URLSession priority as its task is created.
private final class TaskPriority: NSObject, URLSessionTaskDelegate, Sendable {
    private let priority: Float
    init(_ priority: Float) { self.priority = priority }
    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) { task.priority = priority }
}
