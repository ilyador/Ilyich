import Foundation
import IlyichPlatform
import XCTest
@testable import Ilyich

/// What the server's answers become. Only Immich's own errors, which carry its correlation header
/// and a JSON message, can mean an expired session; a proxy's refusal is told apart.
final class FailureMappingTests: XCTestCase {
    private let url = URL(string: "https://photos.example/api/assets/photo")!

    private func failure(_ status: Int, headers: [String: String] = [:], body: String? = nil, path: String? = "assets/photo") -> ServerFailure? {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        do {
            try ServerFailure.check(response, body: body.map { Data($0.utf8) }, path: path)
            return nil
        } catch { return error }
    }

    private let immich = ["Content-Type": "application/json", "X-Correlation-ID": "5f0c3c35-6a1f-4b5c-9a52-0c6e9f3e2a11"]
    private let html = "<html><head><title>401 Authorization Required</title></head><body><center><h1>401 Authorization Required</h1></center><hr><center>nginx</center></body></html>"

    func testSuccessPassesAndImmichErrorsKeepTheirMessage() {
        XCTAssertNil(failure(200, body: "{}"))
        XCTAssertNil(failure(204))
        XCTAssertEqual(failure(401, headers: immich, body: #"{"message":"Invalid user token"}"#), .sessionExpired("Invalid user token"))
        XCTAssertEqual(failure(403, headers: immich, body: #"{"message":"Forbidden"}"#), .forbidden("Forbidden"))
        XCTAssertEqual(failure(404, headers: immich, body: #"{"message":"Not found"}"#), .notFound)
        XCTAssertEqual(failure(400, headers: immich, body: #"{"message":["name must be a string","name should not be empty"]}"#),
                       .http(400, "name must be a string name should not be empty"))
        XCTAssertEqual(failure(500, headers: immich, body: #"{"message":"Internal server error"}"#), .http(500, "Internal server error"))
    }

    func testCredentialEndpointsShowTheServersText() {
        for path in ["auth/login", "/auth/login", "oauth/callback"] {
            let rejected = failure(401, headers: immich, body: #"{"message":"Incorrect email or password"}"#, path: path)
            XCTAssertEqual(rejected, .credentialsRejected("Incorrect email or password"), path)
            XCTAssertEqual(rejected?.localizedDescription, "Incorrect email or password", path)
        }
        XCTAssertEqual(failure(401, headers: immich, body: #"{"message":"Invalid user token"}"#, path: "auth/validateToken"),
                       .sessionExpired("Invalid user token"), "Checking a session is not signing in.")
    }

    func testProxyRefusalsAreSeparate() {
        XCTAssertEqual(failure(401, headers: ["Content-Type": "text/html", "WWW-Authenticate": "Basic realm=\"Restricted\""], body: html), .proxyRejected(401))
        XCTAssertEqual(failure(403, headers: ["Content-Type": "text/html"], body: html), .proxyRejected(403))
        XCTAssertEqual(failure(407, headers: immich, body: #"{"message":"Proxy authentication required"}"#), .proxyRejected(407),
                       "Immich never asks for proxy authentication.")
        XCTAssertEqual(failure(401, body: nil), .proxyRejected(401), "An empty refusal without Immich's header is a proxy's.")
        XCTAssertEqual(failure(401, headers: ["Content-Type": "text/html"], body: html, path: "auth/login"), .proxyRejected(401),
                       "A proxy refusing sign-in is not a wrong password.")
        // API gateways answer with Immich's JSON shape but not its correlation header.
        XCTAssertEqual(failure(401, headers: ["Content-Type": "application/json"], body: #"{"message":"Unauthorized"}"#), .proxyRejected(401))
        // A proxy page passed on with the header still isn't Immich's error.
        XCTAssertEqual(failure(403, headers: ["X-Correlation-ID": "abc", "Content-Type": "text/html"], body: html), .proxyRejected(403))
    }

    func testTheHeaderAloneIsImmichsWhenNoBodyWasRead() {
        XCTAssertEqual(failure(401, headers: immich, body: nil), .sessionExpired(nil))
        XCTAssertEqual(failure(403, headers: immich, body: nil), .forbidden(nil))
        XCTAssertEqual(failure(401, headers: [:], body: nil), .proxyRejected(401))
    }

    func testAnAnswerThatIsNotHTTPCannotBeRead() {
        let response = URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        XCTAssertThrowsError(try ServerFailure.check(response, body: nil)) { error in
            XCTAssertEqual(error as? ServerFailure, .undecodable)
        }
    }

    /// Recorded backup errors and outcome files hold these texts, so they stay as before.
    func testTextsMatchWhatEarlierBuildsShowedAndRecorded() {
        XCTAssertEqual(ServerFailure.sessionExpired("Invalid user token").localizedDescription, "Your session has expired. Please sign in again.")
        XCTAssertEqual(ServerFailure.forbidden(nil).localizedDescription, "This account cannot access that item. It may require unlocking.")
        XCTAssertEqual(ServerFailure.notFound.localizedDescription, "This item is unavailable. Refresh and try again.")
        XCTAssertEqual(ServerFailure.http(500, "Internal server error").localizedDescription, "The server could not complete the request (HTTP 500).")
        XCTAssertEqual(ServerFailure.undecodable.localizedDescription, "The server returned data this version of Ilyich could not read.")
        XCTAssertTrue(ServerFailure.proxyRejected(407).localizedDescription.contains("proxy"))
        XCTAssertEqual(TransportFailure.allEndpointsUnavailable.localizedDescription,
                       "None of the configured server addresses could be reached. Check your connection and try again.")
    }

    // MARK: - Through the client

    /// With password login turned off, the server says so in its 401, and sign-in shows that
    /// instead of an expired session.
    func testPasswordLoginDisabledShowsTheServerMessage() async throws {
        let server = makeStubServer()
        server.route("POST", "auth/login", .immichError(401, message: "Password login has been disabled"))
        let api = try client(server)
        do {
            _ = try await api.login(email: "maya@example.test", password: "secret")
            XCTFail("Sign-in must fail.")
        } catch {
            XCTAssertEqual(error as? ServerFailure, .credentialsRejected("Password login has been disabled"))
            XCTAssertEqual(error.localizedDescription, "Password login has been disabled")
        }
    }

    func testClientRequestsMapEveryAnswer() async throws {
        let server = makeStubServer()
        server.route("POST", "auth/validateToken", .immichError(401, message: "Invalid user token"), .proxyError(401))
        server.route("GET", "albums/forbidden", .immichError(403, message: "Forbidden"))
        server.route("GET", "albums/proxied", .proxyError(403))
        server.route("GET", "albums/garbled", .json("{not json"))
        let api = try client(server, token: "session-token")

        await assertThrows(ServerFailure.sessionExpired("Invalid user token")) { try await api.validateToken() }
        await assertThrows(ServerFailure.proxyRejected(401)) { try await api.validateToken() }
        await assertThrows(ServerFailure.forbidden("Forbidden")) { let _: Album = try await api.request(.get, path: "albums/forbidden") }
        await assertThrows(ServerFailure.proxyRejected(403)) { let _: Album = try await api.request(.get, path: "albums/proxied") }
        await assertThrows(ServerFailure.notFound) { let _: Album = try await api.request(.get, path: "albums/missing") }
        await assertThrows(ServerFailure.undecodable) { let _: Album = try await api.request(.get, path: "albums/garbled") }
        XCTAssertEqual(server.requests("POST", "auth/validateToken").first?.headers["Authorization"], "Bearer session-token")
    }

    private func client(_ server: StubServer, token: String? = nil) throws -> APIClient {
        let api = try APIClient(baseURL: server.baseURL, accessToken: token, userID: token.map { _ in "alice" },
                                sessionConfiguration: server.configuration(), networkConfiguration: NetworkConfiguration())
        addTeardownBlock { await api.shutdown() }
        return api
    }

    private func assertThrows(_ expected: ServerFailure, file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("Expected \(expected).", file: file, line: line)
        } catch { XCTAssertEqual(error as? ServerFailure, expected, file: file, line: line) }
    }
}
