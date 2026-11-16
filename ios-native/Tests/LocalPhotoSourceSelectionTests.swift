import XCTest
@testable import Ilyich

final class LocalPhotoSourceSelectionTests: XCTestCase {
    @MainActor func testInactiveNeighborDoesNotResolveAndReactivationChoosesFreshSource() async {
        let photo = LocalPhoto(id: "phone-1", date: Date())
        let selection = LocalPhotoSourceSelection()
        let device = CountingPhotoSourceResolver(result: .device(photo))
        await selection.resolve(photo, using: device, active: false)
        XCTAssertEqual(device.calls.value, 0)
        XCTAssertNil(selection.resolution)
        XCTAssertFalse(selection.isResolving)
        await selection.resolve(photo, using: device, active: true)
        XCTAssertEqual(device.calls.value, 1)
        XCTAssertEqual(selection.resolution, .device(photo))
        await selection.resolve(photo, using: device, active: false)
        XCTAssertEqual(device.calls.value, 1, "Paging away does not recheck or read full-size media.")
        let asset = Asset(id: "newly-backed-up")
        let server = CountingPhotoSourceResolver(result: .server(asset))
        await selection.resolve(photo, using: server, active: true)
        XCTAssertEqual(selection.resolution, .server(asset), "Returning to the same page can adopt its newly available server copy.")
    }

    @MainActor func testAnEarlierPageResolutionCannotReplaceTheNewPagesIdentity() async throws {
        let first = LocalPhoto(id: "first", date: Date())
        let second = LocalPhoto(id: "second", date: Date())
        let selection = LocalPhotoSourceSelection()
        let delayed = Task {
            await selection.resolve(first, using: FakePhotoSourceResolver(result: .device(first), delay: .milliseconds(120)))
        }
        try await Task.sleep(for: .milliseconds(10))
        await selection.resolve(second, using: FakePhotoSourceResolver(result: .device(second)))
        await delayed.value
        XCTAssertEqual(selection.resolution, .device(second))
        XCTAssertFalse(selection.isResolving)
    }

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

private final class CountingPhotoSourceResolver: LocalPhotoSourceResolving {
    let calls = Locked(0)
    let result: MediaSourceResolution
    init(result: MediaSourceResolution) { self.result = result }
    func resolve(_ photo: LocalPhoto) async -> MediaSourceResolution {
        calls.mutate { $0 += 1 }
        return result
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
