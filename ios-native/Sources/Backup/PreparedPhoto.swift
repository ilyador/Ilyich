import Foundation

/// A photo staged for upload by PhotoKitAdapter.stage, kept in state.json while it uploads.
struct PreparedPhoto: Codable, Sendable {
    let localID: String
    let modificationDate: Date
    let original: UploadFile
    let motion: UploadFile?
    let sidecar: UploadFile?
    let fields: [String: String]
    let isVideo: Bool
    var livePhotoID: String?
    var motionChecksum: String?
    var stageID = UUID().uuidString
}

enum BackupError: LocalizedError {
    case message(String)
    case item(String)
    var errorDescription: String? {
        switch self { case .message(let message), .item(let message): message }
    }
}
