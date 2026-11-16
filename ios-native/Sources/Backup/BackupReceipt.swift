import Foundation

/// A photo's copy on the server, as cleanup reads it to prove a backup before anything is removed.
struct BackupRemoteAsset: Decodable, Sendable {
    let id: String
    let ownerId: String
    let checksum: String
    let checksumAlgorithm: String?
    let contentChecksum: String?
    let isExternal: Bool?
    let stack: AssetStack?

    /// Primary external checksums identify paths, never file bytes.
    var fileChecksum: String? {
        ContentFingerprint.checksum(primary: checksum, algorithm: checksumAlgorithm, content: contentChecksum, isExternal: isExternal)
    }
    let isTrashed: Bool
    let livePhotoVideoId: String?
    /// A copy in the Locked Folder does not count as a backup that cleanup can rely on.
    let visibility: String?
    /// The server's file is missing, as for an offline external library. Nil when not said.
    let isOffline: Bool?
    /// Server-reported original size, or nil when missing or invalid.
    let knownByteCount: Int64?

    init(id: String, ownerId: String, checksum: String, isTrashed: Bool, livePhotoVideoId: String?, visibility: String? = nil,
         isOffline: Bool? = nil, knownByteCount: Int64? = nil, checksumAlgorithm: String? = "sha1",
         contentChecksum: String? = nil, isExternal: Bool? = nil, stack: AssetStack? = nil) {
        self.id = id
        self.ownerId = ownerId
        self.checksum = checksum
        self.checksumAlgorithm = checksumAlgorithm
        self.contentChecksum = contentChecksum
        self.isExternal = isExternal
        self.stack = stack
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

    private enum CodingKeys: String, CodingKey { case id, ownerId, checksum, checksumAlgorithm, contentChecksum, isExternal, libraryId, isTrashed, livePhotoVideoId, visibility, isOffline, exifInfo, stack }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        ownerId = try c.decode(String.self, forKey: .ownerId)
        checksum = try c.decode(String.self, forKey: .checksum)
        checksumAlgorithm = try c.decodeIfPresent(String.self, forKey: .checksumAlgorithm)
        contentChecksum = try c.decodeIfPresent(String.self, forKey: .contentChecksum)
        if let explicit = try c.decodeIfPresent(Bool.self, forKey: .isExternal) { isExternal = explicit }
        else if c.contains(.libraryId) { isExternal = !(try c.decodeNil(forKey: .libraryId)) }
        else { isExternal = nil }
        stack = try c.decodeIfPresent(AssetStack.self, forKey: .stack)
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

/// Algorithm-aware content evidence shared by catalog matching and strict server checks.
enum ContentFingerprint {
    static func checksum(primary: String, algorithm: String?, content: String?, isExternal: Bool?) -> String? {
        if let content, !content.isEmpty { return content }
        guard algorithm == "sha1" || (algorithm == nil && isExternal == false), !primary.isEmpty else { return nil }
        return primary
    }
}
