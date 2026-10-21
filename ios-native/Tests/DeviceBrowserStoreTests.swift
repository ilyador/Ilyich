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

    /// A next page read from the query an insertion then replaced never lands: its photos sit one
    /// place further on in the new reading, so it would hide one photo and show another twice.
    func testNextPageReadBeforeAnInsertionLandsDoesNotLand() async throws {
        let browser = FakeBrowser(count: 600)
        let store = DeviceBrowserStore(browser: browser)
        await store.refresh()
        await store.loadMore()

        browser.insertNewest("new")
        browser.holdNextQuery()
        browser.holdRead(480..<600)
        let applying = Task { await store.apply(change(inserted: ["new"])) }
        await browser.waitUntilHeld(query: true)
        let loading = Task { await store.loadMore() }
        await browser.waitUntilHeld(query: false)
        browser.release(query: true)
        await applying.value
        browser.release(query: false)
        await loading.value

        let ids = store.photos.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "No photo is shown twice.")
        XCTAssertEqual(ids, Array((["new"] + (0..<600).map { "photo-\($0)" }).prefix(ids.count)))
    }

    /// A change that lands while another album is being read doesn't publish the album shown
    /// before under the one chosen.
    func testChangeWhileAnotherAlbumIsReadShowsTheChosenAlbum() async throws {
        let browser = FakeBrowser(count: 600)
        let store = DeviceBrowserStore(browser: browser)
        store.albumID = "odd"
        await store.refresh()
        XCTAssertEqual(store.photos.first?.id, "photo-1")

        store.albumID = ""
        browser.holdNextQuery()
        let selecting = Task { await store.selectAlbum() }
        await browser.waitUntilHeld(query: true)
        browser.remove(550)
        await store.apply(change(removed: ["photo-550"]))
        browser.release(query: true)
        await selecting.value

        XCTAssertEqual(store.photos.map(\.id), (0..<240).map { "photo-\($0)" })
        XCTAssertEqual(store.total, 599)
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
        var holdQuery = false
        var heldRange: Range<Int>?
        var heldQuery: CheckedContinuation<Void, Never>?
        var heldRead: CheckedContinuation<Void, Never>?
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

    /// Makes the next query wait until `release(query: true)`.
    func holdNextQuery() { state.withLock { $0.holdQuery = true } }
    /// Makes the next read of `range` wait until `release(query: false)`.
    func holdRead(_ range: Range<Int>) { state.withLock { $0.heldRange = range } }

    func waitUntilHeld(query: Bool) async {
        while !state.withLock({ query ? $0.heldQuery != nil : $0.heldRead != nil }) {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    func release(query: Bool) {
        let held = state.withLock { state in
            defer { if query { state.heldQuery = nil } else { state.heldRead = nil } }
            return query ? state.heldQuery : state.heldRead
        }
        held?.resume()
    }

    var authorization: PHAuthorizationStatus { .authorized }
    func requestAccess() async -> DeviceAccess { DeviceAccess(status: .authorized, generation: 1) }
    func albums() async -> [DeviceAlbum] { [] }
    func changes() -> AsyncStream<DeviceLibraryChange> { AsyncStream { _ in } }

    /// The album "odd" holds the photos with an odd number; any other album the whole library.
    func query(album: String) async -> DevicePhotoQuery {
        let photos = state.withLock { $0.photos }
        if state.withLock({ state in defer { state.holdQuery = false }; return state.holdQuery }) {
            await withCheckedContinuation { continuation in state.withLock { $0.heldQuery = continuation } }
        }
        let shown = album == "odd" ? photos.filter { Int($0.id.dropFirst(6)).map { $0 % 2 == 1 } ?? false } : photos
        return DevicePhotoQuery(album: album, paging: Snapshot(photos: shown))
    }

    func photos(_ query: DevicePhotoQuery, in range: Range<Int>) async -> [LocalPhoto] {
        let hold = state.withLock { state in
            state.reads.append(range)
            defer { if state.heldRange == range { state.heldRange = nil } }
            return state.heldRange == range
        }
        if hold { await withCheckedContinuation { continuation in state.withLock { $0.heldRead = continuation } } }
        return query.paging.photos(in: range)
    }

    private struct Snapshot: DevicePhotoPaging {
        let photos: [LocalPhoto]
        var count: Int { photos.count }
        func photos(in range: Range<Int>) -> [LocalPhoto] { Array(photos[range.clamped(to: 0..<photos.count)]) }
    }
}
