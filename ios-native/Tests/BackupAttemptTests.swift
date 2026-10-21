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

    /// Changed network settings give the backup flows a new client. A flow still sending on the
    /// old one, a long upload or the Free up space check, carries on there rather than being cut
    /// off and stopping without a word: the old client is not shut down.
    func testANewBackupClientLeavesTheOneItReplacesWorking() async throws {
        let server = makeStubServer()
        let gate = StubServer.Gate()
        server.route("GET", "albums", StubServer.Response.json("[]").waiting(for: gate), .json("[]"))
        let session = StoredCredential(server: server.baseURL, token: "session-token", userID: "alice", name: "Owner")
        func client(_ settings: NetworkConfiguration) throws -> APIClient {
            let api = try APIClient(baseURL: server.baseURL, accessToken: session.token, userID: session.userID,
                                    sessionConfiguration: server.configuration(), networkConfiguration: settings)
            addTeardownBlock { await api.shutdown() }
            return api
        }
        var clients = BackupClientCache()
        let first = try clients.client(for: session, settings: NetworkConfiguration()) { try client(NetworkConfiguration()) }
        let kept = try clients.client(for: session, settings: NetworkConfiguration()) { try client(NetworkConfiguration()) }
        XCTAssertTrue(kept === first, "Unchanged settings keep the client.")
        let held = Task { () -> [Album] in try await first.request(.get, path: "albums") }
        try await until { gate.waiting == 1 }

        let changed = NetworkConfiguration(customHeaders: ["CF-Access-Client-Id": "proxy-id"])
        let second = try clients.client(for: session, settings: changed) { try client(changed) }
        XCTAssertFalse(second === first, "Changed settings make a new client.")
        // Long enough for a shutdown of the old client to reach the request it has out.
        try await Task.sleep(for: .milliseconds(200))
        gate.open()
        let albums = try await held.value
        XCTAssertEqual(albums, [], "The request already out on the old client finishes.")
        let later: [Album] = try await first.request(.get, path: "albums")
        XCTAssertEqual(later, [], "A flow holding the old client can still send on it.")
    }

    func testUnknownFailuresStopInsteadOfSkippingTheWholeLibrary() {
        XCTAssertFalse(BackupAttempt.canContinue(after: APIError.invalidResponse("Unexpected upload response")))
        XCTAssertFalse(BackupAttempt.canContinue(after: BackupError.message("Change password first")))
        XCTAssertFalse(BackupAttempt.canContinue(after: NSError(domain: "Unknown", code: 1)))
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out.") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
