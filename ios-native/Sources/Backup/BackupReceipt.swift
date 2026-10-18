import Foundation

struct BackupFailure: Codable, Identifiable, Sendable {
    let id: String
    let filename: String
    let message: String
    let date: Date
}

struct BackupReceipt: Codable, Sendable {
    let modificationDate: Date
    let original: BackupRemoteFile
    let motion: BackupRemoteFile?
    var confirmedAt: Date?
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
    case waitingForWiFi
    var errorDescription: String? {
        switch self {
        case .waitingForDevice: "Waiting for charging or for the device to cool down"
        case .waitingForWiFi: "Waiting for Wi-Fi to download the iCloud original"
        }
    }
}
