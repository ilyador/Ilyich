import CryptoKit
import Foundation

/// One signed-in account: a user on a server.
public struct AccountID: Hashable, Sendable {
    /// The server's normalized API address, ending in /api.
    public let server: URL
    public let userID: String

    /// The server is taken as given: every name below derives from its exact text.
    public init(server: URL, userID: String) {
        self.server = server
        self.userID = userID
    }

    /// The server address and the user joined by a bar. It keys the shelf order and, hashed,
    /// everything else stored for the account.
    public var cacheScope: String { server.absoluteString + "|" + userID }

    /// The cache scope's SHA-256 in lowercase hex. It names the account's database, caches and
    /// Backup folder.
    public var digest: String { Self.hex(SHA256.hash(data: Data(cacheScope.utf8))) }

    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
}
