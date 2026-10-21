import Foundation
import IlyichPlatform
import Photos
import XCTest
@testable import Ilyich

/// TransferFailureClassifier against section 5 of the architecture, with every input of
/// BackupAttemptTests given its new class. BackupAttempt.canContinue said only "skip this photo"
/// or "stop the run"; the classes now say who retries and when.
final class ClassifierTests: XCTestCase {
    private typealias Classifier = TransferFailureClassifier

    private func classify(_ error: any Error, retries: Int = 0, serverErrors: Int = 0, cloud: Bool = true) -> FailureClass {
        Classifier.classify(error, context: .init(retryCount: retries, consecutiveServerErrors: serverErrors, downloadCloudOriginals: cloud))
    }

    private func isItem(_ failure: FailureClass) -> Bool {
        if case .item = failure { return true }
        return false
    }

    // MARK: Inputs that canContinue let through: each is the photo's own failure.

    func testUnavailableResourcesAndFormatRejectionsAreItemFailures() {
        XCTAssertEqual(classify(BackupError.item("Existing XMP needs review")), .item("Existing XMP needs review"))
        for status in [413, 415, 422] {
            XCTAssertTrue(isItem(classify(ServerFailure.http(status, nil))), "HTTP \(status) concerns this file alone.")
        }
        XCTAssertEqual(classify(ServerFailure.http(415, "Unsupported file type")), .item("Unsupported file type"))
        for code in [PHPhotosError.identifierNotFound, .invalidResource, .missingResource, .requestNotSupportedForAsset] {
            XCTAssertTrue(isItem(classify(NSError(domain: PHPhotosErrorDomain, code: code.rawValue))), "\(code)")
        }
        XCTAssertTrue(isItem(classify(CocoaError(.fileReadNoSuchFile))))
        XCTAssertTrue(isItem(classify(CocoaError(.fileNoSuchFile))))
        XCTAssertTrue(isItem(classify(CocoaError(.fileReadCorruptFile))))
        for failure in [TransferItemFailure.rejected("Duplicate check refused"), .trashedDuplicate, .livePairConflict, .unreadableFile] {
            XCTAssertTrue(isItem(classify(failure)), "\(failure)")
        }
    }

    func testAnICloudOriginalIsTheItemsOnlyWhileDownloadsAreOff() {
        let needsNetwork = NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.networkAccessRequired.rawValue)
        XCTAssertTrue(isItem(classify(needsNetwork, cloud: false)))
        XCTAssertEqual(classify(needsNetwork, cloud: true), .waiting(.unmeteredNetwork, jobScoped: true))
    }

    // MARK: Inputs that stopped the run: now an account block, a wait or a retry.

    func testAuthenticationAndAccountFailuresBlockTheEngine() {
        XCTAssertEqual(classify(ServerFailure.sessionExpired(nil)), .account(.sessionExpired))
        XCTAssertEqual(classify(ServerFailure.sessionExpired("Invalid user token")), .account(.sessionExpired))
        XCTAssertEqual(classify(ServerFailure.credentialsRejected("Incorrect email or password")), .account(.sessionExpired))
        for status in [401, 403, 407] { XCTAssertEqual(classify(ServerFailure.proxyRejected(status)), .account(.proxyRejected)) }
        XCTAssertEqual(classify(ServerFailure.readOnly), .account(.readOnly))
        XCTAssertEqual(classify(ServerFailure.passwordChangeRequired), .account(.passwordChange))
        XCTAssertEqual(classify(APIError.signedOut), .account(.signedOut))
        XCTAssertEqual(classify(CocoaError(.fileWriteOutOfSpace)), .account(.deviceStorage))
        XCTAssertEqual(classify(NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.notEnoughSpace.rawValue)), .account(.deviceStorage))
        XCTAssertEqual(classify(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))), .account(.deviceStorage))
        for code in [PHPhotosError.accessUserDenied, .accessRestricted] {
            XCTAssertEqual(classify(NSError(domain: PHPhotosErrorDomain, code: code.rawValue)), .account(.photosAccess))
        }
    }

    func testConnectivityAndConditionsWait() {
        for code in [URLError.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff] {
            XCTAssertEqual(classify(URLError(code)), .waiting(.connectivity, jobScoped: false), "\(code)")
        }
        XCTAssertEqual(classify(TransportFailure.unreachable(.notConnectedToInternet)), .waiting(.connectivity, jobScoped: false))
        XCTAssertEqual(classify(NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.networkError.rawValue)),
                       .waiting(.connectivity, jobScoped: false))
        XCTAssertEqual(classify(BackupDeferral.waitingForWiFi), .waiting(.unmeteredNetwork, jobScoped: true), "Only that photo waits.")
        XCTAssertEqual(classify(BackupDeferral.waitingForDevice), .waiting(.deviceConditions, jobScoped: false))
        XCTAssertEqual(classify(TransferDeferral.unmeteredNetwork), .waiting(.unmeteredNetwork, jobScoped: true))
        XCTAssertEqual(classify(TransferDeferral.deviceConditions), .waiting(.deviceConditions, jobScoped: false))
    }

    func testTransientFailuresRetry() {
        let transient = FailureClass.transient(retryAfter: nil)
        for code in [URLError.timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed,
                     .serverCertificateUntrusted, .cancelled] {
            XCTAssertEqual(classify(URLError(code)), transient, "\(code)")
        }
        for status in [408, 425, 429, 500, 502, 503, 504] {
            XCTAssertEqual(classify(ServerFailure.http(status, nil)), transient, "HTTP \(status)")
        }
        XCTAssertEqual(classify(ServerFailure.http(500, "Internal server error")), transient)
        XCTAssertEqual(classify(ServerFailure.undecodable), transient, "An answer that can't be read is retried.")
        XCTAssertEqual(classify(APIError.invalidResponse("Unexpected upload response")), transient)
        XCTAssertEqual(classify(TransportFailure.allEndpointsUnavailable), transient)
        XCTAssertEqual(classify(TransportFailure.endpointChanged), transient)
        XCTAssertEqual(classify(TransportFailure.systemCancelled(reason: 0)), transient, "A force-quit's cancelled upload runs again.")
        XCTAssertEqual(classify(CancellationError()), transient)
        XCTAssertEqual(classify(NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue)), transient)
    }

    func testABadRequestIsTheFilesWhileOtherRefusalsRetryAsUnknown() {
        XCTAssertTrue(isItem(classify(ServerFailure.http(400, nil))))
        for failure in [ServerFailure.forbidden(nil), .forbidden("Forbidden"), .notFound] {
            XCTAssertEqual(classify(failure), .transient(retryAfter: nil), "\(failure)")
            XCTAssertTrue(isItem(classify(failure, retries: 5)), "\(failure)")
        }
    }

    func testUnknownFailuresAreTransientForFiveAttemptsThenTheItems() {
        for error in [BackupError.message("Change password first"), NSError(domain: "Unknown", code: 1), CocoaError(.fileWriteNoPermission)] as [any Error] {
            for retries in 0..<5 { XCTAssertEqual(classify(error, retries: retries), .transient(retryAfter: nil), "\(error) after \(retries)") }
            XCTAssertTrue(isItem(classify(error, retries: 5)), "\(error)")
        }
        XCTAssertEqual(classify(ServerFailure.http(418, nil), retries: 4), .transient(retryAfter: nil))
        XCTAssertTrue(isItem(classify(ServerFailure.http(418, nil), retries: 5)))
    }

    func testTheThirdServerErrorInARowBacksOffTheEngine() {
        XCTAssertEqual(classify(ServerFailure.http(500, nil), serverErrors: 1), .transient(retryAfter: nil))
        XCTAssertEqual(classify(ServerFailure.http(503, nil), serverErrors: 2), .waiting(.serverBackoff, jobScoped: false))
        XCTAssertEqual(classify(ServerFailure.http(429, nil), serverErrors: 2), .transient(retryAfter: nil), "Rate limiting is not a server error.")
        XCTAssertTrue(Classifier.isServerError(ServerFailure.http(502, nil)))
        XCTAssertFalse(Classifier.isServerError(ServerFailure.http(429, nil)))
        XCTAssertFalse(Classifier.isServerError(URLError(.timedOut)))
    }

    // MARK: Outcome files

    func testOutcomesCountOnlyTheirReceiptAndStatus() {
        let success = OutcomeRecord(receipt: .init(id: "asset", status: "created"), error: nil, httpStatus: 201)
        XCTAssertNil(Classifier.classify(outcome: success))
        let duplicate = OutcomeRecord(receipt: .init(id: "asset", status: "duplicate"), error: "ignored", httpStatus: 200)
        XCTAssertNil(Classifier.classify(outcome: duplicate))
        XCTAssertEqual(Classifier.classify(outcome: OutcomeRecord(error: "Session expired", httpStatus: 401)), .account(.sessionExpired))
        XCTAssertEqual(Classifier.classify(outcome: OutcomeRecord(error: "x", httpStatus: 413)), .item("The server refused this file (HTTP 413)."))
        XCTAssertEqual(Classifier.classify(outcome: OutcomeRecord(error: "x", httpStatus: 503)), .transient(retryAfter: nil))
        // A legacy error without a status: whatever its text says, in any language, it is an
        // interrupted attempt, checked again or sent again.
        for text in ["The Internet connection appears to be offline.", "Die Internetverbindung scheint offline zu sein.", "Bad request"] {
            XCTAssertEqual(Classifier.classify(outcome: OutcomeRecord(error: text)), .transient(retryAfter: nil), text)
        }
        XCTAssertEqual(Classifier.classify(outcome: OutcomeRecord(error: "x", cancelReason: 0, v: 2)), .transient(retryAfter: nil))
        XCTAssertEqual(Classifier.classify(outcome: OutcomeRecord(error: "x", errorDomain: NSURLErrorDomain,
                                                                  errorCode: URLError.notConnectedToInternet.rawValue, v: 2)),
                       .waiting(.connectivity, jobScoped: false))
        XCTAssertTrue(Classifier.isServerError(outcome: OutcomeRecord(error: "x", httpStatus: 500)))
    }

    func testBackoffDoublesFromThirtySecondsWithinAFifthAndStopsAtAnHour() {
        XCTAssertEqual(Classifier.backoff(retryCount: 0, random: 0.5), .seconds(30))
        XCTAssertEqual(Classifier.backoff(retryCount: 1, random: 0.5), .seconds(60))
        XCTAssertEqual(Classifier.backoff(retryCount: 3, random: 0.5), .seconds(240))
        XCTAssertEqual(Classifier.backoff(retryCount: 0, random: 0), .seconds(24))
        XCTAssertEqual(Classifier.backoff(retryCount: 0, random: 1), .seconds(36))
        XCTAssertEqual(Classifier.backoff(retryCount: 7, random: 0.5), .seconds(3_600))
        XCTAssertEqual(Classifier.backoff(retryCount: 40, random: 1), .seconds(3_600), "Never more than an hour.")
    }
}
