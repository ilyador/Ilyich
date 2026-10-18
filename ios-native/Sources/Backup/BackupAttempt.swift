import Foundation
import Photos

/// Continue only for a failure proven to concern one resource. Unknown errors,
/// authentication, connectivity and insufficient storage stop the whole run.
enum BackupAttempt {
    static func canContinue(after error: any Error) -> Bool {
        if case BackupError.item = error { return true }
        if case APIError.http(let status) = error { return [413, 415, 422].contains(status) }
        let details = error as NSError
        if details.domain == PHPhotosErrorDomain {
            return [PHPhotosError.networkAccessRequired, .identifierNotFound, .invalidResource,
                    .missingResource, .requestNotSupportedForAsset].contains { $0.rawValue == details.code }
        }
        if details.domain == NSCocoaErrorDomain {
            return [CocoaError.fileNoSuchFile, .fileReadNoSuchFile, .fileReadCorruptFile].contains { $0.rawValue == details.code }
        }
        return false
    }
}
