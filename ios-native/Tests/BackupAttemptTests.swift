import IlyichPlatform
import XCTest
import Photos
@testable import Ilyich

final class BackupAttemptTests: XCTestCase {
    func testIsolatesUnavailableResourcesAndFormatRejections() {
        XCTAssertTrue(BackupAttempt.canContinue(after: BackupError.item("Existing XMP needs review")))
        for status in [413, 415, 422] {
            XCTAssertTrue(BackupAttempt.canContinue(after: ServerFailure.http(status, nil)), "HTTP \(status) concerns this file alone.")
        }
        XCTAssertTrue(BackupAttempt.canContinue(after: ServerFailure.http(415, "Unsupported file type")))
        for code in [PHPhotosError.networkAccessRequired, .identifierNotFound, .invalidResource, .missingResource] {
            XCTAssertTrue(BackupAttempt.canContinue(after: NSError(domain: PHPhotosErrorDomain, code: code.rawValue)))
        }
        XCTAssertTrue(BackupAttempt.canContinue(after: CocoaError(.fileReadNoSuchFile)))
    }

    func testStopsForAuthenticationConnectivityAndStorageFailures() {
        // Every server answer that is not about one file stops the run, as 401, 403, 404 and other
        // statuses did before the failures were told apart.
        let stops: [ServerFailure] = [.sessionExpired(nil), .sessionExpired("Invalid user token"), .credentialsRejected("Incorrect email or password"),
                                      .proxyRejected(401), .proxyRejected(403), .proxyRejected(407), .forbidden(nil), .forbidden("Forbidden"),
                                      .notFound, .http(429, nil), .http(500, "Internal server error"), .http(400, nil), .undecodable,
                                      .readOnly, .passwordChangeRequired]
        for failure in stops { XCTAssertFalse(BackupAttempt.canContinue(after: failure), "\(failure)") }
        XCTAssertFalse(BackupAttempt.canContinue(after: URLError(.notConnectedToInternet)))
        XCTAssertFalse(BackupAttempt.canContinue(after: TransportFailure.allEndpointsUnavailable))
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
