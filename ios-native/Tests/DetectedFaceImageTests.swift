import IlyichPlatform
import UIKit
import XCTest
@testable import Ilyich

/// Fix faces shows a face found further into a video than its preview as the server cuts it from
/// that frame, fetched over the account's own connection.
@MainActor final class DetectedFaceImageTests: XCTestCase {
    func testAFaceFromALaterFrameIsTheServersCut() async throws {
        let server = makeStubServer()
        let jpeg = UIGraphicsImageRenderer(size: CGSize(width: 250, height: 250)).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 250, height: 250))
        }
        server.route("GET", "faces/face-1/thumbnail", StubServer.Response(status: 200, headers: ["Content-Type": "image/jpeg"], body: jpeg))
        let api = try APIClient(baseURL: server.baseURL, accessToken: "face-session", userID: "face-" + UUID().uuidString,
                                sessionConfiguration: server.configuration(), networkConfiguration: NetworkConfiguration())
        let pipeline = MediaPipeline(client: api, protocolClasses: [StubURLProtocol.self], earlierURLCacheEntries: false)
        addTeardownBlock { await pipeline.removeAll(); await api.shutdown() }

        let image = try await pipeline.detectedFaceImage(faceID: "face-1", pixelSize: 168)

        XCTAssertEqual(max(image.cgImage.width, image.cgImage.height), 168, "The face is decoded at the size the list shows.")
        let requests = server.requests("GET", "faces/face-1/thumbnail")
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.headers["Authorization"], "Bearer face-session", "The face is fetched as the account.")
    }

    func testAFaceTheServerCantCutFails() async throws {
        let server = makeStubServer()
        server.route("GET", "faces/gone/thumbnail", .immichError(404, message: "Face not found"))
        let api = try APIClient(baseURL: server.baseURL, accessToken: "face-session", userID: "face-" + UUID().uuidString,
                                sessionConfiguration: server.configuration(), networkConfiguration: NetworkConfiguration())
        let pipeline = MediaPipeline(client: api, protocolClasses: [StubURLProtocol.self], earlierURLCacheEntries: false)
        addTeardownBlock { await pipeline.removeAll(); await api.shutdown() }

        do {
            _ = try await pipeline.detectedFaceImage(faceID: "gone", pixelSize: 168)
            XCTFail("A face the server can't cut has no image.")
        } catch {}
    }
}
