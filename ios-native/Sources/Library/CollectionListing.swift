import Foundation
import IlyichPlatform

/// A collection list and whether the server or this account's saved library answered it.
/// An empty saved list is different from having no saved list at all.
struct CollectionListing<Item: Sendable>: Sendable {
    let items: [Item]
    var isOffline = false
}

/// Independent access fences: denying one list must not disable the other offline collection.
enum CollectionKind: String, Sendable { case albums, people }

enum CollectionReadError: LocalizedError {
    case accessChanged
    var errorDescription: String? { "Your library access changed. Refresh to continue." }
}

enum CollectionFailure {
    /// An explicit refusal must not leave saved content on screen or let a later transport
    /// failure bring it back. A server outage, in contrast, keeps the last known list visible.
    static func clearsSavedContent(_ error: any Error) -> Bool {
        if error is CollectionReadError { return true }
        if case APIError.signedOut = error { return true }
        guard let failure = error as? ServerFailure else { return false }
        switch failure {
        case .sessionExpired, .forbidden, .notFound: return true
        case .proxyRejected(let code): return [401, 403, 407].contains(code)
        default: return false
        }
    }

    static func isOffline(_ error: any Error) -> Bool { TransportFailure.isDefinite(error) }
}
