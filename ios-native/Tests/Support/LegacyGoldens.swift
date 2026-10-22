import Foundation
import IlyichPlatform
import IlyichShareInbox
@testable import Ilyich

/// The values behind the golden fixtures in Tests/Fixtures, built with today's production types.
/// Encoding them as each writer does gives the fixture files (in some key order). They describe
/// one account on a phone whose App Group container is `container`.
enum LegacyGoldens {
    static let account = AccountID(server: URL(string: "https://photos.example.org/api")!, userID: "5f3c9a1e-7b2d-4c8e-9f10-2a3b4c5d6e7f")
    /// sha256(account.cacheScope), pinned.
    static let digest = "af60ad43866ab2fed0ab93fc6aa03bdeaaa5e190dca5884d2f57af6919b19395"
    /// The App Group container as iOS reported it to the writer, in its two forms.
    static let container = "/private/var/mobile/Containers/Shared/AppGroup/0E4C1B7A-9D2F-4A63-8B5E-7C1D2E3F4A5B"
    static let varContainer = "/var/mobile/Containers/Shared/AppGroup/0E4C1B7A-9D2F-4A63-8B5E-7C1D2E3F4A5B"

    /// Modification dates as PhotoKit reports them, with fractions; one is a whole number of
    /// seconds, which JSONEncoder writes without a decimal point.
    enum Dates {
        static let current = Date(timeIntervalSinceReferenceDate: 782_481_234.567_891)
        static let l2 = Date(timeIntervalSinceReferenceDate: 781_234_567.123_456_7)
        static let l4 = Date(timeIntervalSinceReferenceDate: 760_000_123.25)
        static let l5 = Date(timeIntervalSinceReferenceDate: 700_000_000)
        static let l6 = Date(timeIntervalSinceReferenceDate: 771_122_334.000_125)
        static let l2ConfirmedAt = Date(timeIntervalSinceReferenceDate: 782_400_000.987_654)
        static let failure = Date(timeIntervalSinceReferenceDate: 782_481_300.456_7)
        static let manifest = Date(timeIntervalSinceReferenceDate: 782_481_500.123_456)
    }

    /// The same dates' bits, pinned apart from the literals above.
    enum Bits {
        static let current: UInt64 = 0x41C7_51DB_A948_B0A7
        static let l2: UInt64 = 0x41C7_4858_C38F_CD6E
        static let l4: UInt64 = 0x41C6_A657_3DA0_0000
        static let l5: UInt64 = 0x41C4_DC93_8000_0000
        static let l6: UInt64 = 0x41C6_FB32_4F00_0419
        static let l2ConfirmedAt: UInt64 = 0x41C7_513D_007E_6B72
        static let failure: UInt64 = 0x41C7_51DB_CA3A_7525
        static let manifest: UInt64 = 0x41C7_51DC_2E0F_CD68
    }

    // MARK: Backup

    static let l1 = "4A1C2B3D-5E6F-4071-8293-A4B5C6D7E8F9/L0/001"
    static let l2 = "8E2F3A4B-6C7D-4E8F-9A0B-1C2D3E4F5A6B/L0/001"
    static let l3 = "C3D4E5F6-0718-4293-A4B5-C6D7E8F90A1B/L0/001"
    static let l4 = "1F2E3D4C-5B6A-4798-8A9B-0C1D2E3F4A5B/L0/001"
    static let l5 = "9A8B7C6D-5E4F-4321-8765-0FEDCBA98765/L0/001"
    static let l6 = "6D5C4B3A-2918-4776-9554-433221100FFE/L0/001"
    static let includedAlbums: Set<String> = ["3B1A8F4C-1D5E-4F7A-9C2B-6E8D0A1B2C3D/L0/040", "B7E2D9A0-55C1-4E3F-8A6B-1C2D3E4F5A6B/L0/040"]
    static let excludedAlbum = "9C8B7A6F-5E4D-4C3B-2A19-0F1E2D3C4B5A/L0/040"
    static let serverAlbum = "d4c3b2a1-0f9e-4d8c-b7a6-958473625140"
    static let otherServerAlbum = "11111111-2222-4333-8444-555555555555"
    static let currentStage = "7F3E2D1C-0B9A-4876-A5B4-C3D2E1F0A9B8"
    static let currentFolder = "2B7D4E91-6A3C-4F08-9E15-3C4D5E6F7A8B"
    static let suspendedStage = "3C2B1A09-8F7E-4D6C-B5A4-938271605F4E"
    static let suspendedFolder = "E1D2C3B4-A596-4877-8695-A4B3C2D1E0F9"
    static let motionAsset = "0b9c8d7e-6f5a-4b3c-9d2e-1f0a9b8c7d6e"
    static let originalAsset = "e1f2a3b4-c5d6-4e7f-8091-a2b3c4d5e6f7"
    static let pairedMotionAsset = "f7e6d5c4-b3a2-4190-8f7e-6d5c4b3a2190"
    static let oldOriginalAsset = "a0b1c2d3-e4f5-4607-8819-2a3b4c5d6e7f"
    static let notificationID = UUID(uuidString: "5E4D3C2B-1A09-4F8E-9D7C-6B5A49382716")!

    static func backupFile(_ folder: String, _ name: String, container: String = container) -> URL {
        URL(fileURLWithPath: "\(container)/Backup/\(digest)/\(folder)/\(name)")
    }

    /// A Live Photo with an XMP sidecar, its video already uploaded.
    static let currentPhoto = PreparedPhoto(
        localID: l1, modificationDate: Dates.current,
        original: UploadFile(url: backupFile(currentFolder, "original"), filename: "IMG_0001.HEIC", contentType: "image/heic"),
        motion: UploadFile(url: backupFile(currentFolder, "motion"), filename: "IMG_0001.MOV", contentType: "video/quicktime"),
        sidecar: UploadFile(url: backupFile(currentFolder, "sidecar"), filename: "IMG_0001.xmp", contentType: "application/rdf+xml"),
        fields: ["fileCreatedAt": "2025-10-18T09:41:12Z", "fileModifiedAt": "2025-10-18T10:53:54Z", "isFavorite": "true", "duration": "2933",
                 "metadata": #"[{"key":"mobile-app","value":{"iCloudId":"0C2F3A1B-7D4E-4F5A-8B6C-9D0E1F2A3B4C:001:AbCdEfGhIjKlMnOpQrStUvWxYz01","createdAt":"2025-10-18T09:41:12Z","latitude":"38.7223","longitude":"-9.1393"}}]"#],
        isVideo: false, livePhotoID: motionAsset, motionChecksum: "q83vEjRWeJq83vEjRWeJq83vEjQ=", stageID: currentStage)

    /// A video kept after its transfer completed but its album add failed.
    static let suspendedVideo = PreparedPhoto(
        localID: l6, modificationDate: Dates.l6,
        original: UploadFile(url: backupFile(suspendedFolder, "original"), filename: "IMG_0006.MOV", contentType: "video/quicktime"),
        motion: nil, sidecar: nil,
        fields: ["fileCreatedAt": "2025-06-09T00:38:40Z", "fileModifiedAt": "2025-06-09T00:38:54Z", "isFavorite": "false", "duration": "15233"],
        isVideo: true, stageID: suspendedStage)

    /// state.json with every key present.
    static func backupState() -> BackupState {
        var preferences = BackupPreferences()
        preferences.includedAlbums = includedAlbums
        preferences.excludedAlbums = [excludedAlbum]
        preferences.cellularPhotos = true
        preferences.cellularVideos = false
        preferences.downloadCloudOriginals = true
        preferences.automatic = true
        preferences.requireCharging = true
        preferences.triggerDelay = 120
        preferences.syncAlbums = true
        var state = BackupState()
        state.preferences = preferences
        state.queue = [l1, l3, l6]
        state.current = currentPhoto
        state.confirmed = [l2: Dates.l2, l4: Dates.l4, l5: Dates.l5]
        state.receipts = [
            l2: BackupReceipt(modificationDate: Dates.l2,
                              original: BackupRemoteFile(id: originalAsset, checksum: "2jmj7l5rSw0yVb/vlWAYkK/YBwk=", byteCount: 3_145_728),
                              motion: BackupRemoteFile(id: pairedMotionAsset, checksum: "Vtn0aoJu2VTK9bjfr/yx/SprVGo=", byteCount: 1_843_200),
                              confirmedAt: Dates.l2ConfirmedAt),
            l4: BackupReceipt(modificationDate: Dates.l4, original: BackupRemoteFile(id: oldOriginalAsset, checksum: "fRFG0SH6nfZJt5SsRtJWzkOvsmk=")),
        ]
        state.linkedAlbums = ["B7E2D9A0-55C1-4E3F-8A6B-1C2D3E4F5A6B/L0/040": serverAlbum]
        state.pendingAlbumAdds = [l3: [serverAlbum, otherServerAlbum]]
        state.suspended = [l6: suspendedVideo]
        state.failures = [l3: BackupFailure(id: l3, filename: "IMG_0003.HEIC",
                                            message: "The photo uploaded but could not be added to the selected album. Check album permissions and retry.",
                                            date: Dates.failure)]
        state.transferNotification = BackupTransferNotification(id: notificationID, total: 12, completed: 9, terminalFailures: 2)
        state.paused = false
        state.error = ServerFailure.sessionExpired(nil).localizedDescription
        return state
    }

    /// Arrays that encode a Set, so their order is the encoder's choice.
    static let stateSets: Set<String> = ["preferences.includedAlbums", "preferences.excludedAlbums", "pendingAlbumAdds.*"]

    /// Outcome files as BackgroundUploads' delegate writes them. The failure texts are the
    /// English localized descriptions of the errors it saw; they are recorded, never parsed.
    static let outcomes: [String: BackgroundUploads.Outcome] = [
        "created": .init(receipt: UploadReceipt(id: originalAsset, status: "created"), error: nil),
        "duplicate": .init(receipt: UploadReceipt(id: originalAsset, status: "duplicate"), error: nil),
        "401": .init(receipt: nil, error: ServerFailure.sessionExpired(nil).localizedDescription, httpStatus: 401),
        "lost": .init(receipt: nil, error: lostConnectionText),
        "force-quit": .init(receipt: nil, error: forceQuitText),
    ]
    /// What CFNetwork calls a dropped connection (-1005) in English.
    static let lostConnectionText = "The network connection was lost."
    /// What CFNetwork calls a cancelled task (-999), as a force-quit leaves it, in English.
    static let forceQuitText = "cancelled"

    /// The backup task descriptor for the current stage.
    static let backupDescriptor = BackgroundUploads.Descriptor(id: currentStage, receipt: backupFile(currentFolder, currentStage + ".receipt"))

    // MARK: Share inbox

    static let batchID = UUID(uuidString: "A9B8C7D6-E5F4-4321-9876-543210FEDCBA")!
    static let sharedFiles = ["1D0C9B8A-7F6E-4D5C-B4A3-928170615243", "2E1D0C9B-8A7F-4E6D-9C5B-A49382716051", "3F2E1D0C-9B8A-4F7E-8D6C-5B4A39281706",
                              "4A3F2E1D-0C9B-4A8F-B7E6-D5C4B3A29180", "5B4A3F2E-1D0C-4B9A-8F7E-6D5C4B3A2918"]

    static func sharedFile(_ name: String, container: String = container) -> URL {
        URL(fileURLWithPath: "\(container)/ShareInbox/\(batchID.uuidString)/\(name)")
    }

    /// A plain photo, a Live Photo, and a RAW file with its XMP sidecar, as a build before W3 wrote
    /// their version 1 manifest on a phone whose container is `container`.
    static func legacyManifest(container: String = container) -> Legacy.SharedBatch {
        func file(_ index: Int, _ filename: String, _ type: String) -> Legacy.UploadFile {
            Legacy.UploadFile(url: sharedFile(sharedFiles[index], container: container), filename: filename, contentType: type)
        }
        return Legacy.SharedBatch(id: batchID, createdAt: Dates.manifest, attachments: [
            Legacy.SharedAttachment(original: file(0, "IMG_2001.JPG", "image/jpeg")),
            Legacy.SharedAttachment(original: file(1, "IMG_2002.HEIC", "image/heic"), motion: file(2, "IMG_2002.MOV", "video/quicktime")),
            Legacy.SharedAttachment(original: file(3, "DSC_0042.NEF", "image/x-nikon-nef"), sidecar: file(4, "DSC_0042.xmp", "application/rdf+xml")),
        ])
    }
    static let manifest = legacyManifest()

    /// The same batch's folder on that phone.
    static let sharedFolder = URL(fileURLWithPath: "\(container)/ShareInbox/\(batchID.uuidString)", isDirectory: true)

    /// The same batch as today's types hold it, which the version 2 manifest fixture encodes.
    static let manifestV2: SharedBatch = {
        func file(_ index: Int, _ filename: String, _ type: String) -> SharedFile {
            SharedFile(name: sharedFiles[index], filename: filename, contentType: type, folder: sharedFolder)
        }
        return SharedBatch(id: batchID, createdAt: Dates.manifest, attachments: [
            SharedAttachment(original: file(0, "IMG_2001.JPG", "image/jpeg")),
            SharedAttachment(original: file(1, "IMG_2002.HEIC", "image/heic"), motion: file(2, "IMG_2002.MOV", "video/quicktime")),
            SharedAttachment(original: file(3, "DSC_0042.NEF", "image/x-nikon-nef"), sidecar: file(4, "DSC_0042.xmp", "application/rdf+xml")),
        ])
    }()

    /// The first attachment's SHA-1, as ShareInboxStore computes it before uploading.
    static let sharedChecksum = "3Hx2v0Vv7mbuIQ0lU2T8E6xgBNs="

    /// The first attachment's upload descriptor, under each container form. The identity hashes
    /// the path as the manifest recorded it.
    static func shareDescriptor(container: String) -> BackgroundUploads.Descriptor {
        let file = sharedFile(sharedFiles[0], container: container)
        let identity = Legacy.shareIdentity(scope: digest, path: file.path, checksum: sharedChecksum)
        return BackgroundUploads.Descriptor(id: identity, receipt: file.deletingLastPathComponent().appendingPathComponent(identity + ".receipt"))
    }

    // MARK: Widget

    static let widgetAsset = "c7d8e9f0-a1b2-4c3d-8e4f-5a6b7c8d9e0f"
    static let memoryID = "e9f0a1b2-c3d4-4e5f-9a6b-7c8d9e0f1a2b"
    static let widgetMetadata: [String: Legacy.WidgetMetadata] = [
        "random_NONE_0": .init(deepLink: URL(string: "immich://asset?id=\(widgetAsset)"), forceFullColor: false, accountScope: digest),
        "memory_1": .init(subtitle: "3 years ago", deepLink: URL(string: "immich://memory?id=\(memoryID)"), accountScope: digest),
    ]
    /// The Flutter widget's snapshot, at the container's root and without an account.
    static let flutterMetadata = Legacy.WidgetMetadata(deepLink: URL(string: "immich://asset?id=\(widgetAsset)"))
    static let flutterDefaults: [String: String] = [
        Legacy.FlutterWidgetCredentials.serverURLKey: "https://photos.example.org/api",
        Legacy.FlutterWidgetCredentials.tokenKey: "flutter-session-token",
        Legacy.FlutterWidgetCredentials.customHeadersKey: #"{"CF-Access-Client-Id":"client.access","CF-Access-Client-Secret":"access-secret"}"#,
    ]

    // MARK: Session

    static let networkConfiguration = NetworkConfiguration(
        customHeaders: ["CF-Access-Client-Id": "client.access", "CF-Access-Client-Secret": "access-secret"],
        alternateEndpoints: [URL(string: "https://photos.tailnet-1234.ts.net/api")!], automaticallySwitchEndpoints: true,
        preferredWifiName: "Home", localEndpoint: URL(string: "http://192.168.1.20:2283/api")!)
    static let credential = StoredCredential(server: account.server, token: "opaque-access-token", userID: account.userID, name: "Owner",
                                             requiresPasswordChange: false)

    // MARK: Caches

    static let fingerprints: [String: LocalFingerprintCache.Fingerprint] = [
        l4: .init(modified: Dates.l4, checksum: "fRFG0SH6nfZJt5SsRtJWzkOvsmk="),
        l5: .init(modified: Dates.l5, checksum: "L9ThxnotKPzthJ7hu3bnORuT6xI="),
        "7B6A5948-3726-4150-8F6E-5D4C3B2A1908/L0/001": .init(modified: nil, checksum: "qUqP5cyxm6YcTAhz05Hph5gvu9M="),
    ]

    static let person = "7c6b5a49-3827-4165-9f8e-7d6c5b4a3928"
    /// The places of the library feed and of one person's, by their feed keys (written by
    /// TimelineFilter.cacheKey before Q5, and by LibraryQuery.stableKey since, byte for byte).
    static let places: [(query: LibraryQuery, places: TimelinePlaces)] = [
        (.library, TimelinePlaces(months: ["2025-10-01": [PlaceTally(name: "Lisbon", count: 42), PlaceTally(name: "Sintra", count: 7)],
                                                   "2025-09-01": [PlaceTally(name: "London", count: 12)]],
                                          trips: ["2025-10-01": "Lisbon"])),
        (.person(person), TimelinePlaces(months: ["2025-10-01": [PlaceTally(name: "Lisbon", count: 5)]], trips: [:])),
    ]

    /// Thumbnails by asset and revision: a media revision, a thumbhash, none at all, and an ID
    /// the store must hash.
    static let thumbnails: [(assetID: String, revision: String)] = [
        ("6F1C2A40-0000-4000-8000-000000000001", "2025-10-18T09:41:12.123Z"),
        ("8a2b3c4d-1111-4222-8333-944455566677", "1QcSHQRnh493V4dIh4eXh1h4kJUI"),
        ("8a9f0e1d-2c3b-4a59-8687-a6b5c4d3e2f1", "unversioned"),
        ("local:ABC/1", "xmp-7"),
    ]
}
