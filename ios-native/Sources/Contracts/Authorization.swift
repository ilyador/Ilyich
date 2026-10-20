import Foundation
import IlyichPlatform

/// One account's access generation. It moves when the account, its token or its access to some
/// assets changes, and fences reads, caches and persisted rows: a store commits a result only if
/// its epoch is still current.
struct AuthorizationEpoch: Hashable, Sendable {
    let account: AccountID
    let value: UInt64
}

/// What the signed-in account may do right now. Three generations fence different work, so a
/// read-only toggle or a Locked Folder unlock never discards library reads.
struct AuthorizationSnapshot: Hashable, Sendable {
    enum Operation: Hashable, Sendable {
        /// Browsing, searching and syncing the library.
        case read
        /// Changing anything on the server.
        case write
        /// Backup and share uploads.
        case upload
        /// Locked Folder photos and their media.
        case lockedMedia
    }

    /// Fences reads, caches and persisted rows.
    var epoch: AuthorizationEpoch
    /// Fences writes and uploads. Moves on every read-only or password-change toggle.
    var writeGeneration: UInt64
    /// Fences locked media. Moves on every Locked Folder unlock and relock.
    var privateEpoch: UInt64
    /// SHA-256 of the access token, so a token change is visible without holding the token.
    var tokenDigest: String
    var readOnly: Bool
    var requiresPasswordChange: Bool
    var lockedFolderUnlocked: Bool

    /// The app's rules today: until the password is changed nothing else is offered; read-only
    /// blocks writes and uploads; locked media needs an unlocked Locked Folder.
    func allows(_ operation: Operation) -> Bool {
        guard !requiresPasswordChange else { return false }
        switch operation {
        case .read: return true
        case .write, .upload: return !readOnly
        case .lockedMedia: return lockedFolderUnlocked
        }
    }
}

/// A result tagged with the epoch it was produced under.
struct Fenced<V: Sendable>: Sendable {
    let epoch: AuthorizationEpoch
    let value: V

    /// The value, if it was produced under the current epoch.
    func value(ifCurrent current: AuthorizationEpoch) -> V? { epoch == current ? value : nil }
}

extension Fenced: Equatable where V: Equatable {}
