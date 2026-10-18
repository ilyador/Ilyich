import Foundation
import XCTest
@testable import Ilyich

@MainActor final class LivePhotoPairingTests: XCTestCase {
    func testAnExistingStillWithoutMotionIsPairedAfterDuplicateUpload() async throws {
        let (api, host) = try fixture("unpaired")
        try await LivePhotoPairing.ensure(assetID: "photo", motionID: "motion", api: api)
        let requests = PairingRequests.shared.requests(host: host)
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "PUT"])
        let update = try XCTUnwrap(requests.last)
        XCTAssertEqual(update.url?.path, "/api/assets/photo")
        let body = try XCTUnwrap(bodyData(update))
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: body), ["livePhotoVideoId": "motion"])
    }

    func testRetryKeepsTheExistingCorrectPairWithoutAnotherWrite() async throws {
        let (api, host) = try fixture("paired")
        try await LivePhotoPairing.ensure(assetID: "photo", motionID: "motion", api: api)
        XCTAssertEqual(PairingRequests.shared.requests(host: host).map(\.httpMethod), ["GET"])
    }

    func testDifferentExistingMotionIsNeverOverwritten() async throws {
        let (api, host) = try fixture("different")
        do {
            try await LivePhotoPairing.ensure(assetID: "photo", motionID: "motion", api: api)
            XCTFail("A conflicting Live Photo pairing must be left for review.")
        } catch is BackupError { }
        XCTAssertEqual(PairingRequests.shared.requests(host: host).map(\.httpMethod), ["GET"])
    }

    private func fixture(_ state: String) throws -> (APIClient, String) {
        let host = state + "-" + UUID().uuidString.lowercased() + ".test"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PairingURLProtocol.self]
        return (try APIClient(baseURL: URL(string: "https://\(host)")!, accessToken: "test-token", userID: "test-user",
                              session: URLSession(configuration: configuration), networkConfiguration: .init()), host)
    }

    private func bodyData(_ request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

private final class PairingRequests: @unchecked Sendable {
    static let shared = PairingRequests()
    private let lock = NSLock()
    private var values: [String: [URLRequest]] = [:]
    func append(_ request: URLRequest) { lock.withLock { values[request.url?.host ?? "", default: []].append(request) } }
    func requests(host: String) -> [URLRequest] { lock.withLock { values[host] ?? [] } }
}

private final class PairingURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        PairingRequests.shared.append(request)
        guard let url = request.url else { return }
        let body: String
        if request.httpMethod == "GET" {
            let pair = url.host?.hasPrefix("unpaired-") == true ? "null" : url.host?.hasPrefix("paired-") == true ? "\"motion\"" : "\"another-motion\""
            body = "{\"id\":\"photo\",\"type\":\"IMAGE\",\"livePhotoVideoId\":\(pair)}"
        } else { body = "{}" }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
