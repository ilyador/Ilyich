import Foundation

/// A photo PhotoKitAdapter.stage copied out of Photos for upload: its files in the stage folder,
/// the multipart fields and the stage ID that names the attempt.
struct PreparedPhoto: Sendable {
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
