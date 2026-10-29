import CryptoKit
import Foundation

/// Verbatim Codable mirrors of what earlier builds left on disk, for the importers that move it
/// into the new stores. Each mirror reads every shape its writer ever produced and keeps the
/// writer's key names and types. The writers used JSONEncoder's defaults, so dates are seconds
/// since 2001 (deferredToDate) and URLs are absolute strings: decode with `Legacy.decoder()`.
/// Golden fixtures in Tests/Fixtures pin each format. Outcome files and task descriptions written
/// before B9 were retired in B10: nothing reads them any more. state.json stays readable for an
/// account whose state.json no import read (LegacyBackupImporter).
enum Legacy {
    /// JSONDecoder's defaults, which every legacy writer's JSONEncoder matched.
    static func decoder() -> JSONDecoder { JSONDecoder() }

    // MARK: Backup

    /// <AppGroup>/Backup/<digest>/state.json, written whole by BackupCoordinator.persist() in
    /// builds before B9. Every key is optional here, so the oldest shape (commit 9780e9625, without
    /// receipts, links, album adds, suspended stages, failures or a transfer notification) and a
    /// damaged file still read.
    struct BackupState: Codable, Sendable {
        var preferences: BackupPreferences?
        /// Local IDs in upload order. The current stage's ID stays first until it is confirmed.
        var queue: [String]?
        var current: PreparedPhoto?
        /// Each backed-up photo's modification date when it was confirmed.
        var confirmed: [String: Date]?
        var receipts: [String: BackupReceipt]?
        /// Device album ID to server album ID.
        var linkedAlbums: [String: String]?
        /// Local ID to the server albums it still has to join.
        var pendingAlbumAdds: [String: Set<String>]?
        /// Stages kept after a failed attempt because part of them already reached the server.
        var suspended: [String: PreparedPhoto]?
        var failures: [String: BackupFailure]?
        var transferNotification: TransferNotification?
        var paused: Bool?
        var error: String?
    }

    /// BackupPreferences, decoded as the app decoded it: a missing key takes its default and the
    /// trigger delay is clamped to an hour.
    struct BackupPreferences: Codable, Equatable, Sendable {
        var includedAlbums = Set<String>()
        var excludedAlbums = Set<String>()
        var cellularPhotos = false
        var cellularVideos = false
        var downloadCloudOriginals = false
        var automatic = false
        var requireCharging = false
        var triggerDelay = 30
        var syncAlbums = false

        init() {}
        private enum CodingKeys: String, CodingKey {
            case includedAlbums, excludedAlbums, cellularPhotos, cellularVideos, downloadCloudOriginals
            case automatic, requireCharging, triggerDelay, syncAlbums
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            includedAlbums = try c.decodeIfPresent(Set<String>.self, forKey: .includedAlbums) ?? []
            excludedAlbums = try c.decodeIfPresent(Set<String>.self, forKey: .excludedAlbums) ?? []
            cellularPhotos = try c.decodeIfPresent(Bool.self, forKey: .cellularPhotos) ?? false
            cellularVideos = try c.decodeIfPresent(Bool.self, forKey: .cellularVideos) ?? false
            downloadCloudOriginals = try c.decodeIfPresent(Bool.self, forKey: .downloadCloudOriginals) ?? false
            automatic = try c.decodeIfPresent(Bool.self, forKey: .automatic) ?? false
            requireCharging = try c.decodeIfPresent(Bool.self, forKey: .requireCharging) ?? false
            triggerDelay = min(3600, max(0, try c.decodeIfPresent(Int.self, forKey: .triggerDelay) ?? 30))
            syncAlbums = try c.decodeIfPresent(Bool.self, forKey: .syncAlbums) ?? false
        }
    }

    /// A photo staged for upload by PhotoKitAdapter.stage, kept in state.json while it uploads.
    /// Its files are in <AppGroup>/Backup/<digest>/<folder>/, beside <stageID>.multipart and
    /// <stageID>.receipt. It records no checksum of the original.
    struct PreparedPhoto: Codable, Sendable {
        let localID: String
        let modificationDate: Date
        let original: UploadFile
        let motion: UploadFile?
        let sidecar: UploadFile?
        /// The multipart form fields, including the mobile-app metadata JSON when there is one.
        let fields: [String: String]
        let isVideo: Bool
        /// The server ID of the uploaded Live Photo video.
        var livePhotoID: String?
        /// The uploaded Live Photo video's SHA-1. Absent before commit 8688f10e0.
        var motionChecksum: String?
        /// Names the attempt's body and outcome files and its multipart boundary, Ilyich-<stageID>.
        let stageID: String
    }

    /// Proof of a completed backup, written by BackupCoordinator's upload loop.
    struct BackupReceipt: Codable, Sendable {
        /// The photo's PHAsset.modificationDate when it was uploaded, bit for bit.
        let modificationDate: Date
        var original: RemoteFile
        var motion: RemoteFile?
        /// Absent before commit 7de7015f1.
        var confirmedAt: Date?
    }

    struct RemoteFile: Codable, Sendable {
        let id: String
        /// Base64 SHA-1, as the server reports it.
        let checksum: String
        /// The original's size from the last cleanup check. Absent before commit ff05778cd.
        var byteCount: Int64?
    }

    struct BackupFailure: Codable, Sendable {
        let id: String
        let filename: String
        /// A localized description in the phone's language when it failed. Never parse it.
        let message: String
        let date: Date
    }

    /// The backup notification batch. Absent before commit b5b701f77.
    struct TransferNotification: Codable, Sendable {
        let id: UUID
        let total: Int
        let completed: Int
        /// Set once the batch ended, until its final notification was posted.
        let terminalFailures: Int?
    }

    // MARK: Share inbox

    /// <AppGroup>/ShareInbox/<batch>/manifest.json, version 1, written by SharedInbox.save from
    /// the Share extension and again after each upload, in builds before rebuild milestone W3.
    /// File URLs are absolute. Version 2 (ShareManifest) keeps every key, so this reads it too.
    struct SharedBatch: Codable, Sendable {
        let id: UUID
        let createdAt: Date
        var attachments: [SharedAttachment]
    }

    /// One shared item. Its identity is its original's file name, which the extension makes a UUID.
    struct SharedAttachment: Codable, Sendable {
        let original: UploadFile
        var motion: UploadFile?
        var sidecar: UploadFile?
    }

    /// A staged file as state.json records it, or a shared file as a version 1 manifest does. The
    /// URL is absolute, under whatever container path iOS reported when it was written: resolve it
    /// with AppGroupLayout.
    struct UploadFile: Codable, Sendable {
        let url: URL
        let filename: String
        let contentType: String
    }

    // MARK: Widget

    /// <AppGroup>/WidgetCache2/<digest>/<key>_metadata.json beside <key>_image.png, written by
    /// the widget's ImageEntry.cache(for:). Keys are random_<album ID>_<family> and
    /// memory_<family>, the family being WidgetFamily's raw value. Flutter builds wrote the same
    /// pair at the container's root, without an account scope; builds before 3040055 wrote it
    /// under WidgetCache/<digest>.
    struct WidgetMetadata: Codable, Sendable {
        var subtitle: String? = nil
        var error: WidgetError? = nil
        var deepLink: URL? = nil
        var forceFullColor: Bool = true
        /// The account digest the snapshot belongs to. Absent in Flutter snapshots.
        var accountScope: String? = nil

        init(subtitle: String? = nil, error: WidgetError? = nil, deepLink: URL? = nil, forceFullColor: Bool = true, accountScope: String? = nil) {
            self.subtitle = subtitle; self.error = error; self.deepLink = deepLink
            self.forceFullColor = forceFullColor; self.accountScope = accountScope
        }
        private enum CodingKeys: String, CodingKey { case subtitle, error, deepLink, forceFullColor, accountScope }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
            error = try c.decodeIfPresent(WidgetError.self, forKey: .error)
            deepLink = try c.decodeIfPresent(URL.self, forKey: .deepLink)
            forceFullColor = try c.decodeIfPresent(Bool.self, forKey: .forceFullColor) ?? true
            accountScope = try c.decodeIfPresent(String.self, forKey: .accountScope)
        }
    }

    /// Encoded as Swift encodes a case without values: {"fetchFailed":{}}.
    enum WidgetError: Codable, Equatable, Sendable {
        case noLogin
        case fetchFailed
        case albumNotFound
        case noAssetsAvailable
    }

    /// What the Flutter app left in the App Group's preferences for its widget, through
    /// home_widget's saveWidgetData. Signing out wrote empty strings rather than removing them.
    struct FlutterWidgetCredentials: Equatable, Sendable {
        static let serverURLKey = "widget_server_url"
        static let tokenKey = "widget_auth_token"
        /// A JSON object of header names and values, written only when there were headers.
        static let customHeadersKey = "widget_custom_headers"
        static let keys = [serverURLKey, tokenKey, customHeadersKey]

        let serverURL: String
        let token: String
        let customHeaders: [String: String]

        /// Read as the Flutter widget read them: both strings set and non-empty, and headers that
        /// fail to parse ignored.
        init?(defaults: UserDefaults) {
            guard let serverURL = defaults.string(forKey: Self.serverURLKey), let token = defaults.string(forKey: Self.tokenKey),
                  !serverURL.isEmpty, !token.isEmpty else { return nil }
            self.serverURL = serverURL; self.token = token
            let headers = defaults.string(forKey: Self.customHeadersKey) ?? ""
            customHeaders = headers.isEmpty ? [:] : (try? JSONDecoder().decode([String: String].self, from: Data(headers.utf8))) ?? [:]
        }
    }

    // MARK: Caches

    /// Caches/IlyichTimelinePlaces/<sha256(cache scope)>/<sha256(feed key)>.json, written by
    /// TimelinePlacesCache.save until F5. The file doesn't name its feed: LegacyPlacesImport finds a
    /// feed's file by hashing the feed's key, LibraryQuery.stableKey (byte-equal to the key before
    /// Q5 for the library, the shelves and places), and moves it into the index's month_places.
    struct TimelinePlaces: Codable, Sendable {
        /// Bucket ID (YYYY-MM-01) to the month's places, most photos first.
        var months: [String: [PlaceTally]]
        /// Bucket ID to the name of a trip abroad marked on that month.
        var trips: [String: String]
    }

    struct PlaceTally: Codable, Equatable, Sendable {
        let name: String
        let count: Int
    }

    /// The places file of one feed, below Caches.
    static func placesPath(scope: String, feedKey: String) -> String {
        "IlyichTimelinePlaces/\(sha256(scope))/\(sha256(feedKey)).json"
    }

    /// Caches/IlyichFingerprints/<sha256(cache scope)>.json, written by LocalFingerprintCache.save:
    /// local ID to the SHA-1 of the photo's current full-size file and the modification date it
    /// was hashed at. Checksums don't depend on the account.
    struct Fingerprint: Codable, Sendable {
        let modified: Date?
        let checksum: String
    }

    /// The fingerprint file of one account, below Caches.
    static func fingerprintsPath(scope: String) -> String { "IlyichFingerprints/\(sha256(scope)).json" }

    /// A grid thumbnail written by ThumbnailDiskStore, below Caches:
    /// IlyichThumbnails/<32 digits of sha256(cache scope)>/<stem's first 2>/<stem>.<16 digits of
    /// sha256(revision)>. The stem is the lowercased asset ID, or 32 digits of its SHA-256 when the
    /// ID holds anything but ASCII letters, digits and hyphens. The revision is the asset's media
    /// revision, else its thumbhash, else "unversioned". The file holds the server's bytes.
    static func thumbnailPath(scope: String, assetID: String, revision: String) -> String {
        let safe = !assetID.isEmpty && assetID.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        let stem = safe ? assetID.lowercased() : String(sha256(assetID).prefix(32))
        return "IlyichThumbnails/\(sha256(scope).prefix(32))/\(stem.prefix(2))/\(stem).\(sha256(revision).prefix(16))"
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
