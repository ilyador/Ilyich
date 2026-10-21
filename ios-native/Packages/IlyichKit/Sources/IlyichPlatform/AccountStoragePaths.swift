import Foundation

/// The names an account's data is stored under, in one place. A test pins each one to the
/// name earlier builds used: a changed name loses the data or forces a full re-sync.
public struct AccountStoragePaths: Sendable {
    public let account: AccountID

    public init(_ account: AccountID) { self.account = account }

    /// The offline library database, in Application Support.
    public var entitiesDatabase: String { "IlyichEntities/\(account.digest).sqlite" }

    /// Grid thumbnails, in Caches. The folder takes only the first 32 digits of the digest.
    public var thumbnails: String { "IlyichThumbnails/\(account.digest.prefix(32))" }

    /// The disk path of the media URL cache.
    public var mediaCache: String { "IlyichMedia/\(account.digest)" }

    /// Backup state and staged files, in the App Group container.
    public var backup: String { "Backup/\(account.digest)" }

    /// The transfers database, in Application Support: never the App Group, where a lock held
    /// at suspension gets the app killed.
    public var transfersDatabase: String { "IlyichTransfers/\(account.digest).sqlite" }

    /// Widget snapshots, in the App Group container.
    public var widgetCache: String { "WidgetCache2/\(account.digest)" }

    /// The read-only flag, in the App Group's preferences.
    public var readOnlyKey: String { "readOnly.\(account.digest)" }

    /// The Keychain account that holds the Locked Folder PIN.
    public var lockedPINAccount: String { account.digest }

    /// The preferences key for the order of people or albums on the shelves.
    public func shelfOrderKey(_ kind: String) -> String { "shelfOrder.\(kind).\(account.cacheScope)" }
}
