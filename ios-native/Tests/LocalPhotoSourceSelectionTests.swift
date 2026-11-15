import XCTest
@testable import Ilyich

final class LocalPhotoSourceSelectionTests: XCTestCase {
    @MainActor func testServerSelectionDoesNotFallThroughToDevice() async {
        let photo = LocalPhoto(id: "phone-1", date: Date())
        let asset = Asset(id: "server-1")
        let selection = LocalPhotoSourceSelection()

        await selection.resolve(photo, using: FakePhotoSourceResolver(result: .server(asset)))

        XCTAssertEqual(selection.resolution, .server(asset))
    }

    @MainActor func testServerOutageNeedsExplicitViewOnPhoneChoice() async {
        let photo = LocalPhoto(id: "phone-1", date: Date())
        let selection = LocalPhotoSourceSelection()
        let outage = MediaSourceResolution.serverUnavailable(photo: photo, serverID: "server-1", message: "Server is offline.")

        await selection.resolve(photo, using: FakePhotoSourceResolver(result: outage))
        XCTAssertEqual(selection.resolution, outage)

        selection.viewOnPhone()
        XCTAssertEqual(selection.resolution, .device(photo))
    }

    @MainActor func testAuthorizationOrIdentityFailureDoesNotOpenPhotoKit() async {
        let photo = LocalPhoto(id: "phone-1", date: Date())
        let failure = MediaSourceResolution.unavailable(message: "Allow Photos access to open this phone photo.")
        let selection = LocalPhotoSourceSelection()

        await selection.resolve(photo, using: FakePhotoSourceResolver(result: failure))

        XCTAssertEqual(selection.resolution, failure)
        XCTAssertFalse(selection.isResolving)
    }

    @MainActor func testCancelledStaleResolutionCannotChooseSource() async throws {
        let photo = LocalPhoto(id: "phone-1", date: Date())
        let selection = LocalPhotoSourceSelection()
        let resolver = FakePhotoSourceResolver(result: .device(photo), delay: .milliseconds(150))
        let request = Task { await selection.resolve(photo, using: resolver) }
        try await Task.sleep(for: .milliseconds(10))

        selection.cancel()
        await request.value

        XCTAssertNil(selection.resolution)
        XCTAssertFalse(selection.isResolving)
    }
}

private struct FakePhotoSourceResolver: LocalPhotoSourceResolving {
    let result: MediaSourceResolution
    var delay: Duration = .zero

    func resolve(_ photo: LocalPhoto) async -> MediaSourceResolution {
        try? await Task.sleep(for: delay)
        return result
    }
}
