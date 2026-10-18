import Foundation

/// Resolve an explicitly configured address before sending a request. A failed mutation
/// is never replayed against another address: its server-side result may be unknown.
actor ServerConnection {
    nonisolated let primary: URL
    private var configuration: NetworkConfiguration
    private let probeSession: URLSession
    private var selected: (url: URL, expires: Date)?
    private var resolution: Task<URL, Error>?
    private var generation = UUID()

    init(server: URL, configuration: NetworkConfiguration? = nil) throws {
        primary = try ServerAddress.normalized(server)
        if let configuration { self.configuration = try configuration.validated() }
        else if Bundle.main.object(forInfoDictionaryKey: "AppGroupId") != nil { self.configuration = try NetworkConfigurationStore.load(server: primary) }
        else { self.configuration = .init() }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 4
        sessionConfiguration.timeoutIntervalForResource = 5
        probeSession = URLSession(configuration: sessionConfiguration, delegate: SameOriginRedirectDelegate(origin: primary), delegateQueue: nil)
    }

    func settings() -> NetworkConfiguration { configuration }
    func update(_ value: NetworkConfiguration) throws {
        let validated = try value.validated()
        try NetworkConfigurationStore.save(validated, server: primary)
        configuration = validated
        invalidate()
    }
    func invalidate() { generation = UUID(); resolution?.cancel(); resolution = nil; selected = nil }

    func request(path: String, query: [URLQueryItem] = [], token: String? = nil) async throws -> URLRequest {
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

    func endpoint() async throws -> URL {
        let hasLocalPreference = configuration.preferredWifiName != nil && configuration.localEndpoint != nil
        guard configuration.automaticallySwitchEndpoints,
              !configuration.alternateEndpoints.isEmpty || hasLocalPreference else { return primary }
        if let selected, selected.expires > Date() { return selected.url }
        if let resolution { return try await resolution.value }
        let configurationSnapshot = configuration
        let headers = configurationSnapshot.customHeaders
        let session = probeSession
        let currentGeneration = generation
        let task = Task<URL, Error> {
            let currentWifiName: String?
            if hasLocalPreference { currentWifiName = await WiFiNetworkAccess.currentNameIfAvailable() }
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
            resolution = nil
            return url
        } catch { if generation == currentGeneration { resolution = nil }; throw error }
    }
    private struct Ping: Decodable { let res: String }
}
