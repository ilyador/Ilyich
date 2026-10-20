import Foundation

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
