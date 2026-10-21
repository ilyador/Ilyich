import Foundation
import Photos
import Synchronization
import XCTest
@testable import Ilyich

/// On this phone, read a page at a time from the Photos adapter and kept up to date from its
/// changes without reading again what didn't change.
@MainActor final class DeviceBrowserStoreTests: XCTestCase {
    /// A change to one photo already shown re-reads only the page holding it.
    func testSingleChangeUpdatesOnlyThatPage() async throws {
        let browser = FakeBrowser(count: 600)
        let store = DeviceBrowserStore(browser: browser)
        await store.refresh()
        await store.loadMore()
        XCTAssertEqual(store.photos.count, 480)
        XCTAssertEqual(store.total, 600)
        XCTAssertEqual(browser.reads, [0..<240, 240..<480])

        browser.reset()
        browser.favorite(300)
        await store.apply(change(changed: ["photo-300"]))

        XCTAssertEqual(browser.reads, [240..<480], "Only the second page is read again.")
        XCTAssertEqual(store.photos.count, 480)
        XCTAssertTrue(store.photos[300].isFavorite)
        XCTAssertEqual(store.photos.map(\.id), (0..<480).map { "photo-\($0)" })
    }

    /// A change to a photo not yet read, or a removal of one, reads no page.
    func testChangesBeyondThePagesReadReadNothing() async throws {
        let browser = FakeBrowser(count: 600)
        let store = DeviceBrowserStore(browser: browser)
        await store.refresh()
        browser.reset()

        await store.apply(change(changed: ["photo-500"]))
        browser.remove(550)
        await store.apply(change(removed: ["photo-550"]))

        XCTAssertEqual(browser.reads, [])
        XCTAssertEqual(store.photos.count, 240)
        XCTAssertEqual(store.total, 599)
    }

    /// A new photo moves every page after it, so the pages read are read again.
    func testInsertionReadsThePagesShownAgain() async throws {
        let browser = FakeBrowser(count: 600)
        let store = DeviceBrowserStore(browser: browser)
        await store.refresh()
        await store.loadMore()
        browser.reset()

        browser.insertNewest("new")
        await store.apply(change(inserted: ["new"]))

        XCTAssertEqual(browser.reads, [0..<480])
        XCTAssertEqual(store.photos.first?.id, "new")
        XCTAssertEqual(store.photos.count, 480)
        XCTAssertEqual(store.total, 601)
    }

    /// A photo shown near the end asks for the next page; one further up doesn't.
    func testPhotosNearTheEndAskForTheNextPage() async throws {
        let store = DeviceBrowserStore(browser: FakeBrowser(count: 600))
        await store.refresh()
        XCTAssertFalse(store.isNearEnd("photo-0"))
        XCTAssertTrue(store.isNearEnd("photo-239"))
        XCTAssertTrue(store.isNearEnd("photo-\(240 - DeviceBrowserStore.prefetchDistance)"))
    }

    private func change(inserted: Set<String> = [], removed: Set<String> = [], changed: Set<String> = []) -> DeviceLibraryChange {
        DeviceLibraryChange(access: DeviceAccess(status: .authorized, generation: 1),
                            inserted: Set(inserted.map(DeviceAssetID.init)), removed: Set(removed.map(DeviceAssetID.init)),
                            changed: Set(changed.map(DeviceAssetID.init)))
    }
}

/// The Photos library On this phone reads: photos named photo-0, photo-1… newest first. Each query
/// is a snapshot, as a PhotoKit fetch result is, and every page read is recorded.
private final class FakeBrowser: DeviceBrowsing {
    private struct State {
        var photos: [LocalPhoto]
        var reads: [Range<Int>] = []
    }
    private let state: Mutex<State>

    init(count: Int) {
        let date = Date(timeIntervalSinceReferenceDate: 700_000_000)
        state = Mutex(State(photos: (0..<count).map { LocalPhoto(id: "photo-\($0)", date: date.addingTimeInterval(-Double($0))) }))
    }

    var reads: [Range<Int>] { state.withLock { $0.reads } }
    func reset() { state.withLock { $0.reads = [] } }

    func favorite(_ index: Int) {
        state.withLock { state in
            let photo = state.photos[index]
            state.photos[index] = LocalPhoto(id: photo.id, date: photo.date, isFavorite: true)
        }
    }

    func remove(_ index: Int) { state.withLock { _ = $0.photos.remove(at: index) } }
    func insertNewest(_ id: String) { state.withLock { $0.photos.insert(LocalPhoto(id: id, date: Date()), at: 0) } }

    var authorization: PHAuthorizationStatus { .authorized }
    func requestAccess() async -> DeviceAccess { DeviceAccess(status: .authorized, generation: 1) }
    func albums() async -> [DeviceAlbum] { [] }
    func changes() -> AsyncStream<DeviceLibraryChange> { AsyncStream { _ in } }

    func query(album: String) async -> DevicePhotoQuery {
        DevicePhotoQuery(album: album, paging: Snapshot(photos: state.withLock { $0.photos }))
    }

    func photos(_ query: DevicePhotoQuery, in range: Range<Int>) async -> [LocalPhoto] {
        state.withLock { $0.reads.append(range) }
        return query.paging.photos(in: range)
    }

    private struct Snapshot: DevicePhotoPaging {
        let photos: [LocalPhoto]
        var count: Int { photos.count }
        func photos(in range: Range<Int>) -> [LocalPhoto] { Array(photos[range.clamped(to: 0..<photos.count)]) }
    }
}
