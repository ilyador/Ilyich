import Foundation

enum LivePhotoPairing {
    /// Check both checksum duplicates and duplicate upload responses: another
    /// client may have created the still between our check and multipart POST.
    static func ensure(assetID: String, motionID: String, api: APIClient) async throws {
        let existing = try await api.asset(id: assetID)
        try Task.checkCancellation()
        if let paired = existing.livePhotoVideoId {
            guard paired == motionID else {
                throw BackupError.message("This photo has a different Live Photo video on the server. Its existing pairing was kept; review it before retrying.")
            }
            return
        }
        try await api.requestVoid(.put, path: "assets/\(assetID)", body: ["livePhotoVideoId": motionID])
    }
}
