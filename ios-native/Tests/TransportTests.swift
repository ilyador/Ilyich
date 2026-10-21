import Foundation
import IlyichPlatform
import XCTest
@testable import Ilyich

/// The transport's sessions, redirects, retries and certificates, against stub servers and a real
/// loopback HTTP server.
final class TransportTests: XCTestCase {
    // MARK: - Shutdown

    func testShutdownInvalidatesAndRefusesLaterRequests() async throws {
        let server = makeStubServer()
        let gate = StubServer.Gate()
        server.route("GET", "server/version", .json(#"{"major":3,"minor":3,"patch":3}"#))
        server.route("GET", "albums", StubServer.Response.json("[]").waiting(for: gate))
        let api = try client(server)
        let _: Version = try await api.request(.get, path: "server/version")

        let held = Task { () -> [Album] in try await api.request(.get, path: "albums") }
        try await until { gate.waiting == 1 }
        await api.shutdown()
        do { _ = try await held.value; XCTFail("Shutdown ends requests already out.") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }

        // Nothing is sent once the sessions are gone, and nothing crashes trying.
        do { let _: Version = try await api.request(.get, path: "server/version"); XCTFail("A shut down client sends nothing.") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        do { _ = try await api.authorizedRequest(path: "albums"); XCTFail("A shut down client builds nothing.") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertTrue(api.transport.isShutDown)
        XCTAssertEqual(server.requests("GET", "server/version").count, 1)
        gate.open()
    }

    // MARK: - Redirects

    /// The server redirects a full-size photo it never generated to its preview or original. The
    /// follow-up keeps the token and the proxy's headers within the origin, and never leaves it.
    func testSameOriginRedirectKeepsCredentialsAndOtherOriginsAreRefused() async throws {
        let elsewhere = try LoopbackHTTPServer { _ in .json(#"{"major":9,"minor":9,"patch":9}"#) }
        let elsewherePort = try await elsewhere.start()
        defer { elsewhere.stop() }
        let server = try LoopbackHTTPServer { request in
            switch request.target {
            case "/api/start": .redirect(to: "/api/finish")
            case "/api/away": .redirect(to: "http://127.0.0.1:\(elsewherePort)/api/finish")
            case "/api/finish": .json(#"{"major":3,"minor":3,"patch":3}"#)
            default: LoopbackHTTPServer.Response(status: 404)
            }
        }
        let port = try await server.start()
        defer { server.stop() }
        let api = try APIClient(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:\(port)")), accessToken: "session-token", userID: "alice",
                                networkConfiguration: NetworkConfiguration(customHeaders: ["CF-Access-Client-Id": "proxy-id"]))
        addTeardownBlock { await api.shutdown() }

        let version: Version = try await api.request(.get, path: "start")
        XCTAssertEqual(version.major, 3)
        let finish = try XCTUnwrap(server.requests.first { $0.target == "/api/finish" })
        XCTAssertEqual(finish.headers["authorization"], "Bearer session-token")
        XCTAssertEqual(finish.headers["cf-access-client-id"], "proxy-id")

        do { let _: Version = try await api.request(.get, path: "away"); XCTFail("A redirect to another origin is not followed.") }
        catch { XCTAssertEqual(error as? ServerFailure, .http(302, nil)) }
        XCTAssertTrue(elsewhere.requests.isEmpty, "The token never reaches another origin.")
    }

    // MARK: - Lost routes

    func testAReadGoesOnceMoreToTheNewAddress() async throws {
        let (home, away) = homeAndAway()
        home.route("GET", "albums", .transportFailure(.networkConnectionLost))
        away.route("GET", "albums", .json("[]"))
        let api = try client(home, switchingTo: [home, away])

        let albums = try await api.albums()
        XCTAssertEqual(albums, [])
        XCTAssertEqual(home.requests("GET", "albums").count, 1)
        XCTAssertEqual(away.requests("GET", "albums").count, 1, "The read went once more, to the address now chosen.")
        let endpoint = try await api.activeEndpoint()
        XCTAssertEqual(endpoint, away.baseURL)
    }

    /// Whether the server made the album before the route was lost is unknown, so the write is
    /// not sent again elsewhere.
    func testAWriteThatLosesItsRouteIsNeverReplayed() async throws {
        let (home, away) = homeAndAway()
        home.route("POST", "albums", .transportFailure(.networkConnectionLost))
        let api = try client(home, switchingTo: [home, away])

        do { _ = try await api.createAlbum(name: "Trip"); XCTFail("The lost write fails.") }
        catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost, "\(error)") }
        XCTAssertEqual(home.requests("POST", "albums").count, 1)
        XCTAssertEqual(away.requests("POST", "albums").count, 0, "A write is never replayed.")
        let endpoint = try await api.activeEndpoint()
        XCTAssertEqual(endpoint, away.baseURL, "The lost route still moves later requests.")
    }

    func testAReadIsNotRepeatedWhenTheAddressStaysTheSame() async throws {
        let server = makeStubServer()
        server.route("GET", "albums", .transportFailure(.timedOut))
        let api = try client(server)
        do { _ = try await api.albums(); XCTFail("The read fails.") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut, "\(error)") }
        XCTAssertEqual(server.requests("GET", "albums").count, 1)
    }

    // MARK: - Client certificates

    /// Background uploads to the local address are offered the client certificate, like those to
    /// the server's other addresses; nothing else is.
    func testClientCertificateIsOfferedForTheLocalEndpoint() throws {
        let saved = StoredCredential(server: URL(string: "https://photos.example/api")!, token: "session-token", userID: "alice", name: "Owner")
        let configuration = try NetworkConfiguration(alternateEndpoints: [URL(string: "https://photos.tailnet.example")!],
                                                     automaticallySwitchEndpoints: true, preferredWifiName: "Home",
                                                     localEndpoint: URL(string: "https://192.168.1.20:2283")!).validated()
        func upload(_ address: String, token: String = "session-token", proxy: Bool = false) -> URLRequest {
            var request = URLRequest(url: URL(string: address)!)
            if proxy {
                request.setValue("Basic proxy", forHTTPHeaderField: "Authorization")
                request.setValue(token, forHTTPHeaderField: "x-immich-user-token")
            } else { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            return request
        }
        for address in ["https://192.168.1.20:2283/api/assets", "https://photos.example/api/assets", "https://photos.tailnet.example/api/assets"] {
            XCTAssertTrue(BackgroundUploads.offersCertificate(for: upload(address), saved: saved, configuration: configuration), address)
        }
        XCTAssertTrue(BackgroundUploads.offersCertificate(for: upload("https://192.168.1.20:2283/api/assets", proxy: true), saved: saved,
                                                          configuration: configuration))
        XCTAssertFalse(BackgroundUploads.offersCertificate(for: upload("https://192.168.1.20:443/api/assets"), saved: saved, configuration: configuration))
        XCTAssertFalse(BackgroundUploads.offersCertificate(for: upload("https://elsewhere.example/api/assets"), saved: saved, configuration: configuration))
        XCTAssertFalse(BackgroundUploads.offersCertificate(for: upload("https://192.168.1.20:2283/api/assets", token: "other"), saved: saved,
                                                           configuration: configuration))
    }

    // MARK: - Streamed answers

    /// The sync stream's lines arrive in pieces that cut through them, with either line ending.
    func testStreamedLinesSurviveBeingCutAnywhere() async throws {
        // U+2028 is a line separator to Swift's own line splitting, but not to JSON lines.
        let text = "{\"a\":1}\r\n\n{\"b\":\"line\u{2028}separator\"}\n{\"c\":3}"
        for size in [1, 2, 3, 7, 64] {
            let server = makeStubServer()
            server.route("POST", "sync/stream", StubServer.Response(status: 200, body: Data(text.utf8)).inPieces(of: size))
            let api = try client(server)
            var (request, _) = try await api.transport.prepare(path: "sync/stream")
            request.httpMethod = "POST"
            let (_, body) = try await api.transport.stream(request, path: "sync/stream")
            var lines: [String] = []
            for try await line in ResponseLines(body: body, limit: 1_024, tooLong: { APIError.invalidResponse("too long") }) {
                lines.append(String(decoding: line, as: UTF8.self))
            }
            XCTAssertEqual(lines, ["{\"a\":1}", "", "{\"b\":\"line\u{2028}separator\"}", "{\"c\":3}"], "pieces of \(size)")
        }
    }

    func testAStreamedLineLongerThanTheLimitFails() async throws {
        let server = makeStubServer()
        server.route("POST", "sync/stream", StubServer.Response(status: 200, body: Data(repeating: 0x61, count: 5_000)).inPieces(of: 512))
        let api = try client(server)
        var (request, _) = try await api.transport.prepare(path: "sync/stream")
        request.httpMethod = "POST"
        let (_, body) = try await api.transport.stream(request, path: "sync/stream")
        do {
            for try await _ in ResponseLines(body: body, limit: 1_024, tooLong: { APIError.invalidResponse("too long") }) {}
            XCTFail("A runaway line fails the stream.")
        } catch { XCTAssertEqual(error.localizedDescription, "too long") }
    }

    func testAStreamTheServerRefusesSaysWhy() async throws {
        let server = makeStubServer()
        server.route("POST", "sync/stream", .immichError(401, message: "Invalid user token"))
        let api = try client(server)
        var (request, _) = try await api.transport.prepare(path: "sync/stream")
        request.httpMethod = "POST"
        do { _ = try await api.transport.stream(request, path: "sync/stream"); XCTFail("The refusal is thrown.") }
        catch { XCTAssertEqual(error as? ServerFailure, .sessionExpired("Invalid user token")) }
    }

    /// An answer longer than a reader keeps up with pauses and resumes, and arrives whole.
    func testALongAnswerArrivesWholeForASlowReader() async throws {
        // A pattern of prime length, so every megabyte differs from the next.
        let pattern = Data((0..<1_048_573).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        var payload = Data()
        while payload.count < 24 * 1024 * 1024 { payload.append(pattern) }
        let size = payload.count
        let answer = payload
        let server = try LoopbackHTTPServer { _ in LoopbackHTTPServer.Response(status: 200, headers: ["Content-Type": "application/octet-stream"], body: answer) }
        let port = try await server.start()
        defer { server.stop() }
        let api = try APIClient(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:\(port)")), accessToken: "session-token", userID: "alice",
                                networkConfiguration: NetworkConfiguration())
        addTeardownBlock { await api.shutdown() }
        let request = try await api.authorizedRequest(path: "download")
        let (_, body) = try await api.transport.stream(request, path: "download")
        var received = Data()
        var pieces = 0
        for try await piece in body {
            received.append(piece)
            pieces += 1
            // Slow at first, so far more arrives than is read and the transfer has to pause.
            if received.count < 12 * 1024 * 1024 { try await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertEqual(received.count, size)
        XCTAssertTrue(received == payload, "Every byte arrives in order.")
        XCTAssertGreaterThan(pieces, 1)
    }

    /// A sync pass that is cancelled mid-answer stops with CancellationError; it never reads as a
    /// complete answer whose last batch is then applied.
    func testAReaderCancelledMidAnswerEndsWithCancellation() async throws {
        let answer = Data(repeating: 0x0A, count: 8 * 1024 * 1024)
        let server = try LoopbackHTTPServer { _ in LoopbackHTTPServer.Response(status: 200, body: answer) }
        let port = try await server.start()
        defer { server.stop() }
        let api = try APIClient(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:\(port)")), accessToken: "session-token", userID: "alice",
                                networkConfiguration: NetworkConfiguration())
        addTeardownBlock { await api.shutdown() }
        let request = try await api.authorizedRequest(path: "sync/stream")
        let reader = Task { () -> Int in
            let (_, body) = try await api.transport.stream(request, path: "sync/stream")
            var pieces = 0
            for try await _ in body {
                pieces += 1
                if pieces == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
            return pieces
        }
        do { _ = try await reader.value; XCTFail("A cancelled reader does not see the answer end.") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled, "\(error)") }
    }

    /// A sync pass that stops before its stream ends, here because a batch could not be saved,
    /// ends the transfer. Left paused for a reader that is gone, the transfer would hold its
    /// connection for good, and the server would wait to write the rest.
    func testASyncPassThatStopsEarlyEndsItsTransfer() async throws {
        let line = try JSONEncoder().encode(EntitySyncEvent(type: "AssetV2", data: [:], ack: "AssetV2|photo")) + Data("\n".utf8)
        var block = Data()
        while block.count < 1024 * 1024 { block.append(line) }
        // Far more than a paused transfer holds.
        var lines = Data()
        for _ in 0..<64 { lines.append(block) }
        let answer = lines
        let server = try LoopbackHTTPServer { _ in
            LoopbackHTTPServer.Response(status: 200, headers: ["Content-Type": "application/jsonlines+json"], body: answer)
        }
        let port = try await server.start()
        defer { server.stop() }
        let api = try APIClient(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:\(port)")), accessToken: "session-token", userID: "alice",
                                networkConfiguration: NetworkConfiguration())
        addTeardownBlock { await api.shutdown() }

        struct Unsaved: Error {}
        do {
            try await api.consumeSyncStream(reset: false) { _ in throw Unsaved() }
            XCTFail("A batch that can't be saved ends the pass.")
        } catch { XCTAssertTrue(error is Unsaved, "\(error)") }
        try await until { !server.endedAnswers.isEmpty }
        XCTAssertEqual(server.endedAnswers, [false], "The phone let go of the answer before its end.")
    }

    // MARK: - Downloads

    func testADownloadLandsInItsOwnFileAndARefusalLeavesNothing() async throws {
        let server = makeStubServer()
        let original = Data("original bytes".utf8)
        server.route("GET", "assets/photo/original", StubServer.Response(status: 200, headers: [
            "Content-Type": "image/jpeg", "Content-Disposition": #"attachment; filename="IMG_0001.JPG""#,
        ], body: original).inPieces(of: 4))
        server.route("GET", "assets/gone/original", .immichError(404, message: "Not found"))
        let api = try client(server)

        let file = try await api.download(asset: Asset(id: "photo"), original: true)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        XCTAssertEqual(file.lastPathComponent, "IMG_0001.JPG")
        XCTAssertEqual(try Data(contentsOf: file), original)

        let pending = try leftoverDownloads()
        do { _ = try await api.download(asset: Asset(id: "gone"), original: true); XCTFail("A missing original fails.") }
        catch { XCTAssertEqual(error as? ServerFailure, .notFound) }
        XCTAssertEqual(try leftoverDownloads(), pending, "A refused download leaves no file behind.")
    }

    private func leftoverDownloads() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasSuffix(".download") })
    }

    // MARK: - Support

    private struct Version: Decodable, Sendable { let major: Int }

    private func client(_ server: StubServer) throws -> APIClient {
        let api = try APIClient(baseURL: server.baseURL, accessToken: "session-token", userID: "alice",
                                sessionConfiguration: server.configuration(), networkConfiguration: NetworkConfiguration())
        addTeardownBlock { await api.shutdown() }
        return api
    }

    /// A client of `primary` that switches among `addresses`, in that order of preference.
    private func client(_ primary: StubServer, switchingTo addresses: [StubServer]) throws -> APIClient {
        let configuration = NetworkConfiguration(alternateEndpoints: addresses.map(\.baseURL), automaticallySwitchEndpoints: true)
        let api = try APIClient(baseURL: primary.baseURL, accessToken: "session-token", userID: "alice",
                                sessionConfiguration: primary.configuration(), networkConfiguration: configuration, wifiName: NoWiFi())
        addTeardownBlock { await api.shutdown() }
        return api
    }

    /// Two addresses of one server. Home, preferred, answers the first check and then can no
    /// longer be reached; away always answers.
    private func homeAndAway() -> (home: StubServer, away: StubServer) {
        let home = makeStubServer(), away = makeStubServer()
        home.route("GET", "server/ping", .json(#"{"res":"pong"}"#), .transportFailure(.cannotConnectToHost))
        away.route("GET", "server/ping", .json(#"{"res":"pong"}"#))
        for server in [home, away] { server.route("GET", "users/me", .immichError(401, message: "Authentication required")) }
        return (home, away)
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out.") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
