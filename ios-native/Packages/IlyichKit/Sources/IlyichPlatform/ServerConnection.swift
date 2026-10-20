import Foundation

/// Resolve an explicitly configured address before sending a request. A failed mutation
/// is never replayed against another address: its server-side result may be unknown.
public actor ServerConnection {
    public nonisolated let primary: URL
    private var configuration: NetworkConfiguration
    private let wifiName: any WiFiNameProviding
    private let probeSession: URLSession
    private var selected: (url: URL, expires: Date)?
    /// The address that last answered. A busy server that misses one check keeps it.
    private var lastGood: URL?
    private var resolution: Task<URL, Error>?
    private var generation = UUID()

    /// The caller loads and saves the settings; they are only validated here.
    public init(server: URL, configuration: NetworkConfiguration, wifiName: any WiFiNameProviding) throws {
        primary = try ServerAddress.normalized(server)
        self.configuration = try configuration.validated()
        self.wifiName = wifiName
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 4
        sessionConfiguration.timeoutIntervalForResource = 5
        probeSession = URLSession(configuration: sessionConfiguration, delegate: SameOriginRedirectDelegate(origin: primary), delegateQueue: nil)
    }

    public func settings() -> NetworkConfiguration { configuration }
    /// Switches to settings the caller has already saved.
    public func update(_ value: NetworkConfiguration) throws {
        configuration = try value.validated()
        invalidate()
    }
    public func invalidate() { generation = UUID(); resolution?.cancel(); resolution = nil; selected = nil }

    public func request(path: String, query: [URLQueryItem] = [], token: String? = nil) async throws -> URLRequest {
        let currentGeneration = generation
        let endpoint = try await endpoint()
        try Task.checkCancellation()
        guard generation == currentGeneration else { throw CancellationError() }
        var request = URLRequest(url: try ServerAddress.url(base: endpoint, path: path, query: query))
        for (name, value) in configuration.customHeaders { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("Ilyich/3.3.3 (iOS)", forHTTPHeaderField: "User-Agent")
        if let token {
            if request.value(forHTTPHeaderField: "Authorization") != nil {
                request.setValue(token, forHTTPHeaderField: "x-immich-user-token")
            } else { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        }
        return request
    }

    public func endpoint() async throws -> URL {
        let hasLocalPreference = configuration.preferredWifiName != nil && configuration.localEndpoint != nil
        guard configuration.automaticallySwitchEndpoints,
              !configuration.alternateEndpoints.isEmpty || hasLocalPreference else { return primary }
        if let selected, selected.expires > Date() { return selected.url }
        if let resolution { return try await resolution.value }
        let configurationSnapshot = configuration
        let headers = configurationSnapshot.customHeaders
        let session = probeSession
        let wifiName = self.wifiName
        let currentGeneration = generation
        let task = Task<URL, Error> {
            let currentWifiName: String?
            if hasLocalPreference { currentWifiName = await wifiName.currentName() }
            else { currentWifiName = nil }
            try Task.checkCancellation()
            let candidates = configurationSnapshot.candidates(primary: primary, currentWifiName: currentWifiName)
            for candidate in candidates {
                try Task.checkCancellation()
                do {
                    var request = URLRequest(url: try ServerAddress.url(base: candidate, path: "server/ping"))
                    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
                    let (data, response) = try await session.data(for: request)
                    try Task.checkCancellation()
                    guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                          let ping = try? JSONDecoder().decode(Ping.self, from: data), ping.res == "pong" else { continue }
                    // A share-only proxy answers ping but hides the API. Immich itself answers an
                    // unauthenticated account request with 401, never 404.
                    var account = URLRequest(url: try ServerAddress.url(base: candidate, path: "users/me"))
                    for (name, value) in headers { account.setValue(value, forHTTPHeaderField: name) }
                    let (_, accountResponse) = try await session.data(for: account)
                    try Task.checkCancellation()
                    guard let status = (accountResponse as? HTTPURLResponse)?.statusCode, [200, 401, 403].contains(status) else { continue }
                    return candidate
                } catch is CancellationError { throw CancellationError() }
                catch let error as URLError where error.code == .cancelled { throw CancellationError() }
                catch { continue }
            }
            throw NetworkConfigurationError.unavailable
        }
        resolution = task
        do {
            let url = try await task.value
            try Task.checkCancellation()
            guard generation == currentGeneration else { throw CancellationError() }
            selected = (url, Date().addingTimeInterval(30))
            lastGood = url
            resolution = nil
            return url
        } catch {
            if generation == currentGeneration { resolution = nil }
            if !(error is CancellationError), generation == currentGeneration, let lastGood {
                selected = (lastGood, Date().addingTimeInterval(5))
                return lastGood
            }
            throw error
        }
    }
    private struct Ping: Decodable { let res: String }
}

extension URLError {
    /// Only a lost route to the server suggests another address might work. Cancelled requests,
    /// which scrolling produces by the hundred, say nothing about the server.
    public var meansEndpointUnreachable: Bool {
        switch code {
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet,
             .timedOut, .secureConnectionFailed, .internationalRoamingOff, .dataNotAllowed: true
        default: false
        }
    }
}
