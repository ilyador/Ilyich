import XCTest
import Photos
@testable import Ilyich

final class BackupAttemptTests: XCTestCase {
    func testIsolatesUnavailableResourcesAndFormatRejections() {
        XCTAssertTrue(BackupAttempt.canContinue(after: BackupError.item("Existing XMP needs review")))
        XCTAssertTrue(BackupAttempt.canContinue(after: APIError.http(415)))
        for code in [PHPhotosError.networkAccessRequired, .identifierNotFound, .invalidResource, .missingResource] {
            XCTAssertTrue(BackupAttempt.canContinue(after: NSError(domain: PHPhotosErrorDomain, code: code.rawValue)))
        }
        XCTAssertTrue(BackupAttempt.canContinue(after: CocoaError(.fileReadNoSuchFile)))
    }

    func testStopsForAuthenticationConnectivityAndStorageFailures() {
        XCTAssertFalse(BackupAttempt.canContinue(after: APIError.unauthorized))
        XCTAssertFalse(BackupAttempt.canContinue(after: APIError.forbidden))
        XCTAssertFalse(BackupAttempt.canContinue(after: APIError.http(429)))
        XCTAssertFalse(BackupAttempt.canContinue(after: APIError.http(500)))
        XCTAssertFalse(BackupAttempt.canContinue(after: URLError(.notConnectedToInternet)))
        XCTAssertFalse(BackupAttempt.canContinue(after: CancellationError()))
        XCTAssertFalse(BackupAttempt.canContinue(after: BackupDeferral.waitingForWiFi))
        XCTAssertFalse(BackupAttempt.canContinue(after: CocoaError(.fileWriteOutOfSpace)))
        for code in [PHPhotosError.networkError, .notEnoughSpace, .accessUserDenied, .accessRestricted] {
            XCTAssertFalse(BackupAttempt.canContinue(after: NSError(domain: PHPhotosErrorDomain, code: code.rawValue)))
        }
    }

    func testUnknownFailuresStopInsteadOfSkippingTheWholeLibrary() {
        XCTAssertFalse(BackupAttempt.canContinue(after: APIError.invalidResponse("Unexpected upload response")))
        XCTAssertFalse(BackupAttempt.canContinue(after: BackupError.message("Change password first")))
        XCTAssertFalse(BackupAttempt.canContinue(after: NSError(domain: "Unknown", code: 1)))
    }
}
