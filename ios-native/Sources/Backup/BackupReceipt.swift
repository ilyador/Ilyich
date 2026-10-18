import Foundation

struct BackupReceipt: Codable, Sendable {
    let modificationDate: Date
    let original: BackupRemoteFile
    let motion: BackupRemoteFile?
}

struct BackupRemoteFile: Codable, Sendable {
    let id: String
    let checksum: String
    func matches(_ asset: BackupRemoteAsset, ownerID: String) -> Bool {
        asset.id == id && asset.ownerId == ownerID && !asset.isTrashed && asset.checksum == checksum
    }
}

struct BackupRemoteAsset: Decodable, Sendable {
    let id: String
    let ownerId: String
    let checksum: String
    let isTrashed: Bool
    let livePhotoVideoId: String?
}

enum BackupDeferral: LocalizedError {
    case waitingForDevice
    var errorDescription: String? { "Waiting for charging or for the device to cool down" }
}
