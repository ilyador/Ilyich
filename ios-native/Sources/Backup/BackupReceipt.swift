import Foundation

/// A photo's copy on the server, as cleanup reads it to prove a backup before anything is removed.
struct BackupRemoteAsset: Decodable, Sendable {
    let id: String
    let ownerId: String
    let checksum: String
    let isTrashed: Bool
    let livePhotoVideoId: String?
    /// A copy in the Locked Folder does not count as a backup that cleanup can rely on.
    let visibility: String?
    /// The server's file is missing, as for an offline external library. Nil when not said.
    let isOffline: Bool?
    /// Server-reported original size, or nil when missing or invalid.
    let knownByteCount: Int64?

    init(id: String, ownerId: String, checksum: String, isTrashed: Bool, livePhotoVideoId: String?, visibility: String? = nil,
         isOffline: Bool? = nil, knownByteCount: Int64? = nil) {
        self.id = id
        self.ownerId = ownerId
        self.checksum = checksum
        self.isTrashed = isTrashed
        self.livePhotoVideoId = livePhotoVideoId
        self.visibility = visibility
        self.isOffline = isOffline
        self.knownByteCount = knownByteCount
    }

    /// Size-only view of `exifInfo`, so this file does not depend on app models.
    private struct ExifSize: Decodable {
        let fileSizeInByte: Int64?
    }

    private enum CodingKeys: String, CodingKey { case id, ownerId, checksum, isTrashed, livePhotoVideoId, visibility, isOffline, exifInfo }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        ownerId = try c.decode(String.self, forKey: .ownerId)
        checksum = try c.decode(String.self, forKey: .checksum)
        isTrashed = try c.decode(Bool.self, forKey: .isTrashed)
        livePhotoVideoId = try c.decodeIfPresent(String.self, forKey: .livePhotoVideoId)
        visibility = try c.decodeIfPresent(String.self, forKey: .visibility)
        isOffline = try c.decodeIfPresent(Bool.self, forKey: .isOffline)
        // Size metadata is optional and must never affect verification.
        let size = (try? c.decodeIfPresent(ExifSize.self, forKey: .exifInfo))?.fileSizeInByte
        knownByteCount = size.flatMap { $0 >= 0 ? $0 : nil }
    }
}

enum BackupDeferral: LocalizedError {
    case waitingForDevice
    case waitingForWiFi
    var errorDescription: String? {
        switch self {
        case .waitingForDevice: "Waiting for charging or for the device to cool down"
        case .waitingForWiFi: "Waiting for Wi-Fi to download the iCloud original"
        }
    }
}
