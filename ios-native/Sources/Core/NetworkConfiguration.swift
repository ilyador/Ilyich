import CryptoKit
import Foundation
import Security

struct NetworkConfiguration: Codable, Equatable, Sendable {
    var customHeaders: [String: String] = [:]
    var alternateEndpoints: [URL] = []
    var automaticallySwitchEndpoints = false
    var preferredWifiName: String?
    var localEndpoint: URL?

    func validated() throws -> Self {
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

    func candidates(primary: URL, currentWifiName: String? = nil) -> [URL] {
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

enum NetworkConfigurationError: LocalizedError {
    case invalidAddress, invalidHeader, reservedHeader(String), keychain, invalidCertificate, incorrectCertificatePassword, unavailable
    var errorDescription: String? {
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

enum TransportFailure {
    /// A definite, non-cancelled transport failure, including every configured endpoint being unreachable.
    static func isDefinite(_ error: any Error) -> Bool {
        if let urlError = error as? URLError { return urlError.code != .cancelled }
        if case .unavailable? = error as? NetworkConfigurationError { return true }
        return false
    }
}

enum ServerAddress {
    static func normalized(_ input: URL) throws -> URL {
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

    static func url(base: URL, path: String, query: [URLQueryItem] = []) throws -> URL {
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
enum NetworkConfigurationStore {
    static func load(server: URL) throws -> NetworkConfiguration {
        guard let data = try NetworkKeychain.read(server: server, kind: "settings") else { return .init() }
        return try JSONDecoder().decode(NetworkConfiguration.self, from: data).validated()
    }
    static func save(_ configuration: NetworkConfiguration, server: URL) throws {
        try NetworkKeychain.save(JSONEncoder().encode(configuration.validated()), server: server, kind: "settings")
    }
    static func remove(server: URL) throws {
        try NetworkKeychain.remove(server: server, kind: "settings")
        try ClientCertificateStore.remove(server: server)
    }
}

private enum NetworkKeychain {
    static func query(server: URL, kind: String) throws -> [String: Any] {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "AppGroupId") as? String,
              group.hasPrefix("group."), !group.contains("$(") else { throw NetworkConfigurationError.keychain }
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

enum ClientCertificateStore {
    private struct Package: Codable { let data: Data; let password: String }
    static func hasCertificate(server: URL) throws -> Bool { try NetworkKeychain.read(server: server, kind: "certificate") != nil }
    static func importCertificate(data: Data, password: String, server: URL) throws {
        _ = try credential(data: data, password: password)
        try NetworkKeychain.save(JSONEncoder().encode(Package(data: data, password: password)), server: server, kind: "certificate")
    }
    static func remove(server: URL) throws { try NetworkKeychain.remove(server: server, kind: "certificate") }
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
    static func respond(to challenge: URLAuthenticationChallenge, server: URL, requestURL: URL?,
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

final class SameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let origin: URL
    init(origin: URL) { self.origin = origin }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let source = task.originalRequest?.url, let target = request.url, Self.sameOrigin(source, target) else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        ClientCertificateStore.respond(to: challenge, server: origin, requestURL: task.originalRequest?.url, completion: completionHandler)
    }
    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        func port(_ url: URL) -> Int { url.port ?? (["https", "wss"].contains(url.scheme?.lowercased() ?? "") ? 443 : 80) }
        return a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased() && port(a) == port(b)
    }
}
