import Synchronization
import Photos
import UIKit
import XCTest
@testable import Ilyich

final class DeviceMediaTests: XCTestCase {
    @MainActor func testNetworkRequiredIsAnExpectedCloudStateThenExplicitRetryLoads() async throws {
        let provider = FakeDeviceMedia()
        let media = LocalPhotoMedia(device: provider)
        let photo = LocalPhoto(id: "local-photo", date: Date())

        media.load(photo, network: false)
        XCTAssertEqual(provider.requests, [.image(pixels: 3000, network: false)])
        provider.send(.unavailable(inCloud: true, message: nil))
        try await until { !media.loading }
        XCTAssertTrue(media.cloud)
        XCTAssertNil(media.failure, "A Photos network requirement is an expected availability state.")

        media.load(photo, network: true)
        XCTAssertEqual(provider.requests.last, .image(pixels: 3000, network: true))
        provider.send(.progress(0.42))
        try await until { media.progress != nil }
        XCTAssertEqual(media.progress, 0.42)
        let image = UIImage()
        provider.send(.image(image, final: true))
        try await until { media.image != nil && !media.loading }
        XCTAssertNotNil(media.image)
        XCTAssertFalse(media.cloud)
    }

    @MainActor func testNetworkDownloadCanBeCancelledAndRetried() async throws {
        let provider = FakeDeviceMedia()
        let media = LocalPhotoMedia(device: provider)
        let photo = LocalPhoto(id: "cloud-photo", date: Date())

        media.load(photo, network: true)
        XCTAssertEqual(provider.requests.count, 1)
        media.cancelDownload()
        XCTAssertFalse(media.loading)
        XCTAssertTrue(media.cloud)
        XCTAssertEqual(media.failure, "Download cancelled.")
        try await until { provider.terminationCount == 1 }

        media.load(photo, network: true)
        XCTAssertEqual(provider.requests.count, 2)
        let image = UIImage()
        provider.send(.image(image, final: true))
        try await until { media.image != nil && !media.loading }
        XCTAssertNotNil(media.image)
    }

    func testPhotos3164IsClassifiedAsNetworkRequired() {
        let required = NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.networkAccessRequired.rawValue)
        let failed = NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.networkError.rawValue)

        XCTAssertTrue(DeviceMediaFailure.requiresNetwork(required))
        XCTAssertNil(DeviceMediaFailure.message(required))
        XCTAssertFalse(DeviceMediaFailure.requiresNetwork(failed))
        XCTAssertEqual(DeviceMediaFailure.message(failed), "Photos couldn’t load this item. Try again.")
    }

    @MainActor private func until(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Media request did not finish.") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private final class FakeDeviceMedia: DeviceMediaProviding, @unchecked Sendable {
    private struct State {
        var requests: [DeviceMediaRequest] = []
        var continuations: [AsyncStream<DeviceMediaEvent>.Continuation] = []
        var terminations = 0
    }
    private let state = Mutex(State())

    var requests: [DeviceMediaRequest] { state.withLock { $0.requests } }
    var terminationCount: Int { state.withLock { $0.terminations } }

    func media(_ localID: String, _ request: DeviceMediaRequest) -> AsyncStream<DeviceMediaEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: DeviceMediaEvent.self)
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { $0.terminations += 1 }
        }
        state.withLock { state in
            state.requests.append(request)
            state.continuations.append(continuation)
        }
        return stream
    }

    func send(_ event: DeviceMediaEvent) {
        let continuation = state.withLock { $0.continuations.last }
        continuation?.yield(event)
        if case .image(_, final: true) = event { continuation?.finish() }
        if case .unavailable = event { continuation?.finish() }
    }
}
