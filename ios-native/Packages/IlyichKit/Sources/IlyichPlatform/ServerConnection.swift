import Foundation

/// Chooses which configured address requests go to. Each choice is one numbered generation, and a
/// request keeps the route it was sent along, so a lost route is reported with its address and
/// generation: the first report starts one new check of every address, and the rest of a burst,
/// or a report about an address already left, changes nothing. Requests waiting for a check that
/// is replaced move to the new one rather than failing.
///
/// A failed mutation is never replayed against another address: its server-side result may be
/// unknown. Callers decide what may be sent again.
public actor ServerConnection {
    /// The address one request was sent to, and the generation of the choice that sent it there.
    public struct Route: Hashable, Sendable {
        public let endpoint: URL
        public let generation: UInt64

        public init(endpoint: URL, generation: UInt64) {
            self.endpoint = endpoint
            self.generation = generation
        }
    }

    public nonisolated let primary: URL
    private var configuration: NetworkConfiguration
    private let wifiName: any WiFiNameProviding
    private let probes: GuardedURLSession
    private var generation: UInt64 = 0
    private var selected: (url: URL, expires: Date)?
    /// The address that last answered. A busy server that misses one check keeps it.
    private var lastGood: URL?
    private var resolution: (generation: UInt64, task: Task<URL, any Error>)?
    private var isShutDown = false
    /// How many times every address has been checked.
    public private(set) var checks = 0

    /// The caller loads and saves the settings; they are only validated here. The probe
    /// configuration is adopted for the address checks, with their short timeouts.
    public init(server: URL, configuration: NetworkConfiguration, wifiName: any WiFiNameProviding,
                probeConfiguration: URLSessionConfiguration = .ephemeral) throws {
        primary = try ServerAddress.normalized(server)
        self.configuration = try configuration.validated()
        self.wifiName = wifiName
        probeConfiguration.timeoutIntervalForRequest = 4
        probeConfiguration.timeoutIntervalForResource = 5
        probes = GuardedURLSession(configuration: probeConfiguration, origin: primary)
    }

    public func settings() -> NetworkConfiguration { configuration }

    /// Switches to settings the caller has already saved.
    public func update(_ value: NetworkConfiguration) throws {
        configuration = try value.validated()
        invalidate()
    }

    /// Forgets the chosen address, as a new generation. The next request checks every address
    /// again, and requests waiting for a check move to that new one.
    public func invalidate() {
        generation &+= 1
        selected = nil
        resolution?.task.cancel()
        resolution = nil
    }

    /// Reports that a request sent along `route` lost its way to the server, and says whether
    /// that started a new choice. Only a report about the address in use, from its own
    /// generation, does.
    @discardableResult
    public func routeFailed(_ route: Route) -> Bool {
        guard switchesEndpoints, route.generation == generation, selected?.url == route.endpoint else { return false }
        invalidate()
        return true
    }

    /// Stops checking addresses for good. Requests waiting for an address end with CancellationError.
    public func shutdown() {
        isShutDown = true
        invalidate()
        probes.invalidate()
    }

    /// The address to send the next request to.
    public func endpoint() async throws -> URL { try await route().endpoint }

    /// The route for the next request: the chosen address and its generation.
    public func route() async throws -> Route {
        while true {
            guard !isShutDown else { throw CancellationError() }
            try Task.checkCancellation()
            guard switchesEndpoints else { return Route(endpoint: primary, generation: generation) }
            if let selected {
                if selected.expires > Date() { return Route(endpoint: selected.url, generation: generation) }
                // The choice has aged: check every address again, as a new generation.
                invalidate()
            }
            let current = resolution ?? startResolution()
            let outcome: Result<URL, any Error>
            do { outcome = .success(try await current.task.value) } catch { outcome = .failure(error) }
            // Replaced while it ran: wait for the new check instead.
            guard current.generation == generation else { continue }
            if resolution?.generation == current.generation { resolution = nil }
            guard !isShutDown else { throw CancellationError() }
            switch outcome {
            case .success(let url):
                selected = (url, Date().addingTimeInterval(30))
                lastGood = url
                return Route(endpoint: url, generation: generation)
            case .failure(let error):
                if let lastGood {
                    selected = (lastGood, Date().addingTimeInterval(5))
                    return Route(endpoint: lastGood, generation: generation)
                }
                throw error
            }
        }
    }

    /// A request to `path` on the chosen address, with the custom headers and the token.
    public func request(path: String, query: [URLQueryItem] = [], token: String? = nil) async throws -> URLRequest {
        let chosen = try await route()
        return try request(path: path, query: query, token: token, route: chosen)
    }

    /// A request to `path` along a route this connection gave out.
    public func request(path: String, query: [URLQueryItem] = [], token: String? = nil, route: Route) throws -> URLRequest {
        var request = URLRequest(url: try ServerAddress.url(base: route.endpoint, path: path, query: query))
        for (name, value) in configuration.customHeaders { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("Ilyich/3.3.3 (iOS)", forHTTPHeaderField: "User-Agent")
        if let token {
            if request.value(forHTTPHeaderField: "Authorization") != nil {
                request.setValue(token, forHTTPHeaderField: "x-immich-user-token")
            } else { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        }
        return request
    }

    private var switchesEndpoints: Bool {
        let hasLocalPreference = configuration.preferredWifiName != nil && configuration.localEndpoint != nil
        return configuration.automaticallySwitchEndpoints && (!configuration.alternateEndpoints.isEmpty || hasLocalPreference)
    }

    private func startResolution() -> (generation: UInt64, task: Task<URL, any Error>) {
        checks += 1
        let configuration = configuration, primary = primary, wifiName = wifiName, probes = probes
        let task = Task<URL, any Error>.detached(priority: .userInitiated) {
            let hasLocalPreference = configuration.preferredWifiName != nil && configuration.localEndpoint != nil
            let currentWifiName = hasLocalPreference ? await wifiName.currentName() : nil
            try Task.checkCancellation()
            let candidates = configuration.candidates(primary: primary, currentWifiName: currentWifiName)
            return try await Self.firstAnswering(candidates, headers: configuration.customHeaders, probes: probes)
        }
        let started = (generation: generation, task: task)
        resolution = started
        return started
    }

    /// Checks every address at once and returns the most preferred one that answers as Immich.
    /// An address is taken only once every address before it has failed its check.
    static func firstAnswering(_ candidates: [URL], headers: [String: String], probes: GuardedURLSession) async throws -> URL {
        let choice = await withTaskGroup(of: (Int, Bool).self) { group -> Int? in
            for (index, candidate) in candidates.enumerated() {
                group.addTask { (index, await answersAsImmich(candidate, headers: headers, probes: probes)) }
            }
            var answers = [Bool?](repeating: nil, count: candidates.count)
            while let answer = await group.next() {
                answers[answer.0] = answer.1
                if let choice = preferredAnswer(answers) {
                    group.cancelAll()
                    return choice
                }
            }
            return nil
        }
        try Task.checkCancellation()
        guard let choice else { throw TransportFailure.allEndpointsUnavailable }
        return candidates[choice]
    }

    /// The index of the address to use, given each check's result in preference order (nil while
    /// it runs): the first that answered, once every address before it has failed. Nil while an
    /// earlier address is still being checked, or when none answered.
    public static func preferredAnswer(_ answers: [Bool?]) -> Int? {
        for (index, answer) in answers.enumerated() {
            switch answer {
            case true?: return index
            case false?: continue
            case nil: return nil
            }
        }
        return nil
    }

    private static func answersAsImmich(_ candidate: URL, headers: [String: String], probes: GuardedURLSession) async -> Bool {
        do {
            var ping = URLRequest(url: try ServerAddress.url(base: candidate, path: "server/ping"))
            for (name, value) in headers { ping.setValue(value, forHTTPHeaderField: name) }
            let (data, response) = try await probes.data(for: ping)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  (try? JSONDecoder().decode(Ping.self, from: data))?.res == "pong" else { return false }
            // A share-only proxy answers ping but hides the API. Immich itself answers an
            // unauthenticated account request with 401, never 404.
            var account = URLRequest(url: try ServerAddress.url(base: candidate, path: "users/me"))
            for (name, value) in headers { account.setValue(value, forHTTPHeaderField: name) }
            let (_, accountResponse) = try await probes.data(for: account)
            guard let status = (accountResponse as? HTTPURLResponse)?.statusCode else { return false }
            return [200, 401, 403].contains(status)
        } catch { return false }
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
