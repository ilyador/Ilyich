import Foundation
import IlyichPlatform

/// The server answered, but not with what was asked. Transport problems, where no answer came,
/// are IlyichPlatform's TransportFailure.
enum ServerFailure: Error, Equatable, Sendable {
    /// A 401 with an Immich error body: the session is gone. Carries the server's message.
    case sessionExpired(String?)
    /// A 401 from auth/login or oauth/callback. The server's text is shown as it is.
    case credentialsRejected(String)
    /// A 401, 403 or 407 without an Immich error body: a proxy in front of the server refused.
    case proxyRejected(Int)
    case forbidden(String?)
    case notFound
    case http(Int, String?)
    /// The answer could not be read.
    case undecodable
    /// Refused on the phone because read-only mode is on.
    case readOnly
    /// Refused on the phone until the account's password is changed.
    case passwordChangeRequired
}

extension ServerFailure {
    /// The paths where a 401 means the sign-in details were wrong, not that a session ended.
    static let credentialPaths: Set<String> = ["auth/login", "oauth/callback"]

    /// Returns the HTTP response when it is a success, and throws what the server said otherwise.
    /// `body` is the answer's body, or nil when it was not read; `path` is the request's path below
    /// /api.
    @discardableResult
    static func check(_ response: URLResponse, body: Data?, path: String? = nil) throws(ServerFailure) -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw .undecodable }
        guard !(200..<300).contains(http.statusCode) else { return http }
        throw ServerFailure(status: http.statusCode, immich: ImmichError(response: http, body: body), path: path)
    }

    init(status: Int, immich: ImmichError?, path: String?) {
        switch status {
        case 401:
            guard let immich else { self = .proxyRejected(401); return }
            let path = path?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
            if Self.credentialPaths.contains(path) {
                self = .credentialsRejected(immich.message ?? "The server didn’t accept these sign-in details.")
            } else { self = .sessionExpired(immich.message) }
        case 403: self = immich.map { .forbidden($0.message) } ?? .proxyRejected(403)
        // Immich never asks for proxy authentication.
        case 407: self = .proxyRejected(407)
        case 404: self = .notFound
        default: self = .http(status, immich?.message)
        }
    }
}

/// An error Immich itself wrote, as opposed to a proxy in front of it. Immich stamps every answer
/// with an X-Correlation-ID header and writes errors as a JSON object with a message. Both are
/// required, because API gateways write the same JSON for their own refusals; a header without a
/// body to read is taken as Immich's.
struct ImmichError: Equatable, Sendable {
    let message: String?

    init?(response: HTTPURLResponse, body: Data?) {
        guard response.value(forHTTPHeaderField: "X-Correlation-ID") != nil else { return nil }
        guard let body, !body.isEmpty else { message = nil; return }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        if let text = object["message"] as? String { message = text }
        else if let texts = object["message"] as? [String] { message = texts.joined(separator: " ") }
        else { message = nil }
    }
}

extension ServerFailure: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .sessionExpired: "Your session has expired. Please sign in again."
        case .credentialsRejected(let message): message
        case .proxyRejected(let status): "A proxy in front of your server refused the request (HTTP \(status)). Check the network settings for this server."
        case .forbidden: "This account cannot access that item. It may require unlocking."
        case .notFound: "This item is unavailable. Refresh and try again."
        case .http(let status, _): "The server could not complete the request (HTTP \(status))."
        case .undecodable: "The server returned data this version of Ilyich could not read."
        case .readOnly: ReadOnlyPolicy.ReadOnlyError().errorDescription
        case .passwordChangeRequired: "Change your account password before continuing."
        }
    }
}

/// How a failed transfer or job is handled, from section 5 of the rebuild plan.
enum FailureClass: Equatable, Sendable {
    /// Retried by itself with backoff, after the server's Retry-After when it sent one.
    case transient(retryAfter: Duration?)
    /// Waits for a condition. A job-scoped wait holds only that job; otherwise the whole engine waits.
    case waiting(WaitReason, jobScoped: Bool)
    /// Stops the engine until the user acts. Automatic triggers never clear it.
    case account(AccountRestriction)
    /// Only this item failed, and only the user retries it. Carries the message to show.
    case item(String)
}

enum WaitReason: Hashable, Sendable {
    /// Charging, temperature or Low Power Mode, as the backup settings require.
    case deviceConditions
    /// An iCloud original or a video that may only download or upload on Wi-Fi.
    case unmeteredNetwork
    case connectivity
    /// Several server errors in a row.
    case serverBackoff
}

enum AccountRestriction: Hashable, Sendable {
    case signedOut
    case sessionExpired
    case proxyRejected
    case readOnly
    case passwordChange
    case photosAccess
    case deviceStorage
}
