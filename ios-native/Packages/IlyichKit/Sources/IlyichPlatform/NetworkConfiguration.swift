import CryptoKit
import Foundation
import Security

public struct NetworkConfiguration: Codable, Equatable, Sendable {
    public var customHeaders: [String: String] = [:]
    public var alternateEndpoints: [URL] = []
    public var automaticallySwitchEndpoints = false
    public var preferredWifiName: String?
    public var localEndpoint: URL?

    public init(customHeaders: [String: String] = [:], alternateEndpoints: [URL] = [], automaticallySwitchEndpoints: Bool = false,
                preferredWifiName: String? = nil, localEndpoint: URL? = nil) {
        self.customHeaders = customHeaders
        self.alternateEndpoints = alternateEndpoints
        self.automaticallySwitchEndpoints = automaticallySwitchEndpoints
        self.preferredWifiName = preferredWifiName
        self.localEndpoint = localEndpoint
    }

    public func validated() throws -> Self {
        var result = self
        result.preferredWifiName = preferredWifiName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.preferredWifiName?.isEmpty == true { result.preferredWifiName = nil }
        if let localEndpoint { result.localEndpoint = try ServerAddress.normalized(localEndpoint) }
        var names = Set<String>()
        let tokenCharacters = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        for (name, value) in customHeaders {
            guard !name.isEmpty, name.unicodeScalars.allSatisfy(tokenCharacters.contains),
                  !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                  names.insert(name.lowercased()).inserted else { throw NetworkConfigurationError.invalidHeader }
            guard !["host", "content-length", "connection", "transfer-encoding", "x-immich-user-token", "x-immich-session-token"].contains(name.lowercased()) else {
                throw NetworkConfigurationError.reservedHeader(name)
            }
        }
        result.alternateEndpoints = try alternateEndpoints.map(ServerAddress.normalized)
        var urls = Set<URL>()
        result.alternateEndpoints = result.alternateEndpoints.filter { urls.insert($0).inserted }
        return result
    }

    public func candidates(primary: URL, currentWifiName: String? = nil) -> [URL] {
        guard automaticallySwitchEndpoints else { return [primary] }
        var result: [URL] = []
        if preferredWifiName == currentWifiName, let preferredWifiName, !preferredWifiName.isEmpty,
           let localEndpoint {
            result.append(localEndpoint)
        }
        result += alternateEndpoints
        if !result.contains(primary) { result.append(primary) }
        var seen = Set<URL>()
        return result.filter { seen.insert($0).inserted }
    }
}

public enum NetworkConfigurationError: LocalizedError {
    case invalidAddress, invalidHeader, reservedHeader(String), keychain, invalidCertificate, incorrectCertificatePassword, unavailable
    public var errorDescription: String? {
        switch self {
        case .invalidAddress: "Enter an HTTP or HTTPS server address without a password, query, or fragment."
        case .invalidHeader: "Header names must be valid HTTP names, with no duplicates or line breaks."
        case .reservedHeader(let name): "Ilyich manages the \(name) header. Use a separate header for your proxy credentials."
        case .keychain: "Network credentials couldn’t be accessed. Unlock your phone and try again."
        case .invalidCertificate: "This file does not contain a usable PKCS#12 client certificate and private key."
        case .incorrectCertificatePassword: "The certificate password is incorrect, or the PKCS#12 file is damaged."
        case .unavailable: "None of the configured server addresses could be reached. Check your connection and try again."
        }
    }
}

/// A request that never got an answer from the server.
public enum TransportFailure: Error, Equatable, Sendable {
    /// The network or the server could not be reached.
    case unreachable(URLError.Code)
    /// The connection moved to another configured address while the request was out.
    case endpointChanged
    /// None of the configured addresses answered.
    case allEndpointsUnavailable
    /// iOS cancelled a background transfer, for example when the user force-quit the app. The
    /// reason is the task's NSURLErrorBackgroundTaskCancelledReasonKey, when it has one.
    case systemCancelled(reason: Int?)

    /// A definite, non-cancelled transport failure, including every configured endpoint being unreachable.
    public static func isDefinite(_ error: any Error) -> Bool {
        if let urlError = error as? URLError { return urlError.code != .cancelled }
        if case .unavailable? = error as? NetworkConfigurationError { return true }
        return false
    }
}

public enum ServerAddress {
    public static func normalized(_ input: URL) throws -> URL {
        guard var parts = URLComponents(url: input, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { throw NetworkConfigurationError.invalidAddress }
        parts.scheme = scheme
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/api") { path += "/api" }
        parts.path = path
        guard let url = parts.url else { throw NetworkConfigurationError.invalidAddress }
        return url
    }

    public static func url(base: URL, path: String, query: [URLQueryItem] = []) throws -> URL {
        guard !path.contains("://"), !path.contains("?"), !path.contains("#"), !path.hasPrefix("//"),
              !path.split(separator: "/").contains("..") else { throw NetworkConfigurationError.invalidAddress }
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard var parts = URLComponents(url: base.appendingPathComponent(relative), resolvingAgainstBaseURL: false) else {
            throw NetworkConfigurationError.invalidAddress
        }
        if !query.isEmpty {
            parts.queryItems = query
            parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = parts.url else { throw NetworkConfigurationError.invalidAddress }
        return url
    }
}

/// Credentials are shared with uploads and extensions, scoped to the explicitly configured server.
/// They remain in the Keychain rather than preferences or diagnostic logs.
public enum NetworkConfigurationStore {
    public static func load(server: URL) throws -> NetworkConfiguration {
        guard let data = try NetworkKeychain.read(server: server, kind: "settings") else { return .init() }
        return try JSONDecoder().decode(NetworkConfiguration.self, from: data).validated()
    }
    /// The settings a new connection starts with. A bundle that names no App Group, such as a
    /// test host, has nothing saved and gets the defaults.
    public static func connectionSettings(server: URL) throws -> NetworkConfiguration {
        guard AppGroup.isDeclared else { return .init() }
        return try load(server: server)
    }
    public static func save(_ configuration: NetworkConfiguration, server: URL) throws {
        try NetworkKeychain.save(JSONEncoder().encode(configuration.validated()), server: server, kind: "settings")
    }
    public static func remove(server: URL) throws {
        try NetworkKeychain.remove(server: server, kind: "settings")
        try ClientCertificateStore.remove(server: server)
    }
}

private enum NetworkKeychain {
    static func query(server: URL, kind: String) throws -> [String: Any] {
        guard let group = try? AppGroup.identifier else { throw NetworkConfigurationError.keychain }
        let scope = SHA256.hash(data: Data(try ServerAddress.normalized(server).absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.ilyich.native.network",
                kSecAttrAccount as String: kind + ":" + scope, kSecAttrAccessGroup as String: group]
    }
    static func read(server: URL, kind: String) throws -> Data? {
        var query = try query(server: server, kind: kind)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw NetworkConfigurationError.keychain }
        return data
    }
    static func save(_ data: Data, server: URL, kind: String) throws {
        let query = try query(server: server, kind: kind)
        let values: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw NetworkConfigurationError.keychain }
    }
    static func remove(server: URL, kind: String) throws {
        let status = SecItemDelete(try query(server: server, kind: kind) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NetworkConfigurationError.keychain }
    }
}

public enum ClientCertificateStore {
    private struct Package: Codable { let data: Data; let password: String }
    public static func hasCertificate(server: URL) throws -> Bool { try NetworkKeychain.read(server: server, kind: "certificate") != nil }
    public static func importCertificate(data: Data, password: String, server: URL) throws {
        _ = try credential(data: data, password: password)
        try NetworkKeychain.save(JSONEncoder().encode(Package(data: data, password: password)), server: server, kind: "certificate")
    }
    public static func remove(server: URL) throws { try NetworkKeychain.remove(server: server, kind: "certificate") }
    private static func credential(data: Data, password: String) throws -> URLCredential {
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: password] as CFDictionary, &items)
        if status == errSecAuthFailed { throw NetworkConfigurationError.incorrectCertificatePassword }
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let value = first[kSecImportItemIdentity as String], CFGetTypeID(value as CFTypeRef) == SecIdentityGetTypeID() else {
            throw NetworkConfigurationError.invalidCertificate
        }
        let identity = value as! SecIdentity
        return URLCredential(identity: identity, certificates: first[kSecImportItemCertChain as String] as? [Any], persistence: .forSession)
    }
    public static func respond(to challenge: URLAuthenticationChallenge, server: URL, requestURL: URL?,
                               completion: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate else {
            completion(.performDefaultHandling, nil); return
        }
        guard challenge.previousFailureCount == 0, let requestURL,
              ["https", "wss"].contains(requestURL.scheme?.lowercased() ?? ""),
              requestURL.host?.lowercased() == challenge.protectionSpace.host.lowercased(),
              (requestURL.port ?? 443) == challenge.protectionSpace.port else { completion(.cancelAuthenticationChallenge, nil); return }
        do {
            guard let data = try NetworkKeychain.read(server: server, kind: "certificate") else { completion(.performDefaultHandling, nil); return }
            let package = try JSONDecoder().decode(Package.self, from: data)
            completion(.useCredential, try credential(data: package.data, password: package.password))
        } catch { completion(.cancelAuthenticationChallenge, nil) }
    }
}

public final class SameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    public let origin: URL
    public init(origin: URL) { self.origin = origin }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let source = task.originalRequest?.url, let target = request.url, Self.sameOrigin(source, target) else {
            completionHandler(nil); return
        }
        completionHandler(Self.carryingHeaders(of: task.currentRequest ?? task.originalRequest, to: request))
    }
    /// The server redirects a full-size photo it never generated to its preview or original.
    /// The follow-up request must keep the token and custom headers, or the server answers 401.
    public static func carryingHeaders(of source: URLRequest?, to request: URLRequest) -> URLRequest {
        guard let headers = source?.allHTTPHeaderFields else { return request }
        var redirected = request
        for (name, value) in headers where redirected.value(forHTTPHeaderField: name) == nil {
            if redirected.httpBody == nil, ["content-length", "content-type"].contains(name.lowercased()) { continue }
            redirected.setValue(value, forHTTPHeaderField: name)
        }
        return redirected
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        ClientCertificateStore.respond(to: challenge, server: origin, requestURL: task.originalRequest?.url, completion: completionHandler)
    }
    public static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        func port(_ url: URL) -> Int { url.port ?? (["https", "wss"].contains(url.scheme?.lowercased() ?? "") ? 443 : 80) }
        return a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased() && port(a) == port(b)
    }
}
