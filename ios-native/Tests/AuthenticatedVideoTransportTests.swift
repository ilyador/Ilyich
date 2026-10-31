import AVFoundation
import XCTest
@testable import Ilyich

/// The viewer's video transport, which hands AVFoundation the server's bytes through URLSession.
@MainActor final class AuthenticatedVideoTransportTests: XCTestCase {
    /// AVFoundation can still ask a closed transport for bytes: a request it queued before the
    /// close arrives after it. Starting a task on the closed transport's invalidated session
    /// raised, which crashed build 3040096 after videos loaded slowly; it turns the request down.
    func testAClosedTransportTurnsDownRequestsInsteadOfStartingATask() async throws {
        let request = URLRequest(url: URL(string: "https://photos.invalid/api/assets/a/video/playback")!)
        let transport = try AuthenticatedVideoTransport(request: request, server: URL(string: "https://photos.invalid")!)
        let asset = try XCTUnwrap(transport.player.currentItem?.asset)
        transport.close()
        do {
            _ = try await asset.load(.duration)
            XCTFail("A closed transport's video loaded")
        } catch {}
    }
}
