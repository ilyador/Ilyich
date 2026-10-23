import Foundation
import XCTest
@testable import Ilyich

/// F6: what is selected is the selection's, which records each photo as it was selected and
/// reads a whole month through the feed. The month is read whole, whatever the grid holds; one
/// month at a time; and leaving selection, or the feed moving on, drops a month on its way.
@MainActor final class FeedSelectionTests: XCTestCase {
    // MARK: - The selection

    /// A photo is recorded when it is selected, so the selection still says what it holds once the
    /// grid has let its month go; deselected, its record goes. A server photo's copy on the phone
    /// stays beside it, and a photo only the phone has is selected under its own name.
    func testSelectingRecordsEachPhotoAndDeselectingForgetsIt() {
        let selection = FeedSelection()
        let copy = LocalPhoto(id: "copy", date: nil), phoneOnly = LocalPhoto(id: "phone", date: nil)
        selection.isSelecting = true
        selection.toggle(LibraryEntry.remote(Asset(id: "server"), local: copy))
        selection.toggle(LibraryEntry.local(phoneOnly))
        XCTAssertEqual(selection.selected, ["server", "local:phone"])
        XCTAssertEqual(selection.assets(among: { [] }).map(\.id), ["server"], "The record serves when the grid has none.")
        XCTAssertEqual(selection.localPhotos.map(\.id), ["phone"])
        XCTAssertEqual(Set(selection.devicePhotos.map(\.id)), ["copy", "phone"])

        selection.toggle(LibraryEntry.remote(Asset(id: "server"), local: copy))
        XCTAssertEqual(selection.selected, ["local:phone"])
        XCTAssertEqual(selection.assets(among: { [Asset(id: "server")] }).map(\.id), [], "A deselected photo is forgotten.")
        XCTAssertEqual(selection.devicePhotos.map(\.id), ["phone"], "Its phone copy goes with it.")
        selection.toggle(LibraryEntry.local(phoneOnly))
        XCTAssertTrue(selection.selected.isEmpty)
        XCTAssertTrue(selection.localPhotos.isEmpty)
    }

    /// A photo selected by its ID alone is found among the feed's rows; one selected from the grid
    /// keeps the record it was selected with.
    func testAPhotoSelectedByIDAloneIsFoundAmongTheRows() {
        let selection = FeedSelection()
        selection.select(Asset(id: "chosen", originalFileName: "as-selected.jpg"))
        selection.selected.insert("by-id")
        let rows = [Asset(id: "chosen", originalFileName: "newer.jpg"), Asset(id: "by-id"), Asset(id: "other")]
        let assets = selection.assets(among: { rows })
        XCTAssertEqual(Set(assets.map(\.id)), ["chosen", "by-id"])
        XCTAssertEqual(assets.first { $0.id == "chosen" }?.originalFileName, "as-selected.jpg")
    }

    /// One step of a sideways drag adds what the range took in and takes out what it left; the
    /// photos selected before it stay.
    func testADragStepAddsWhatTheRangeTookInAndTakesOutWhatItLeft() {
        let selection = FeedSelection()
        selection.isSelecting = true
        let before = LibraryEntry.remote(Asset(id: "before")), left = LibraryEntry.remote(Asset(id: "left"))
        selection.change(adding: [before, left], removing: [])
        let copy = LocalPhoto(id: "copy", date: nil)
        selection.change(adding: [.remote(Asset(id: "entered"), local: copy), .local(LocalPhoto(id: "phone", date: nil))], removing: [left])
        XCTAssertEqual(selection.selected, ["before", "entered", "local:phone"])
        XCTAssertEqual(Set(selection.assets(among: { [] }).map(\.id)), ["before", "entered"], "The photo the range left is forgotten.")
        XCTAssertEqual(Set(selection.devicePhotos.map(\.id)), ["copy", "phone"])
        selection.change(adding: [], removing: [])
        XCTAssertEqual(selection.selected, ["before", "entered", "local:phone"], "An empty step changes nothing.")
    }

    // MARK: - Whole months

    /// Every photo the feed reads for the month is selected, with its record and its phone copy;
    /// deselecting the month takes out only its photos.
    func testSelectingAMonthSelectsEveryPhotoTheFeedReadsForIt() async throws {
        let selection = FeedSelection()
        selection.isSelecting = true
        selection.select(Asset(id: "elsewhere"))
        let copy = LocalPhoto(id: "copy", date: nil)
        let month: [LibraryEntry] = [.remote(Asset(id: "a"), local: copy), .remote(Asset(id: "b")), .local(LocalPhoto(id: "phone", date: nil))]
        selection.selectMonth(true, reading: { month }, failed: { XCTFail("\($0)") })
        XCTAssertTrue(selection.isSelectingMonth)
        try await settle(selection)
        XCTAssertEqual(selection.selected, ["elsewhere", "a", "b", "local:phone"])
        XCTAssertEqual(Set(selection.assets(among: { [] }).map(\.id)), ["elsewhere", "a", "b"])
        XCTAssertEqual(Set(selection.devicePhotos.map(\.id)), ["copy", "phone"])

        selection.selectMonth(false, reading: { month }, failed: { XCTFail("\($0)") })
        try await settle(selection)
        XCTAssertEqual(selection.selected, ["elsewhere"], "Deselecting the month leaves the rest of the selection.")
        XCTAssertTrue(selection.devicePhotos.isEmpty)
    }

    /// Leaving selection while the month is read drops it: nothing is selected when it arrives.
    func testLeavingSelectionDropsAMonthStillBeingRead() async throws {
        let selection = FeedSelection()
        let gate = StubServer.Gate()
        selection.isSelecting = true
        selection.selectMonth(true, reading: {
            await gate.wait()
            try Task.checkCancellation()
            return [.remote(Asset(id: "a"))]
        }, failed: { XCTFail("\($0)") })
        try await until("The month was never read.") { gate.waiting == 1 }
        selection.isSelecting = false
        XCTAssertFalse(selection.isSelectingMonth)
        gate.open()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(selection.selected.isEmpty)
        XCTAssertFalse(selection.isSelectingMonth)
    }

    /// The feed answers nil when it moved on while the month was read: nothing changes and no
    /// error shows. A month that fails to read selects nothing and says why.
    func testAMonthTheFeedMovedOnFromOrFailedToReadChangesNothing() async throws {
        let selection = FeedSelection()
        selection.isSelecting = true
        selection.select(Asset(id: "kept"))
        selection.selectMonth(true, reading: { nil }, failed: { XCTFail("\($0)") })
        try await settle(selection)
        XCTAssertEqual(selection.selected, ["kept"])

        let failure = Box<(any Error)?>(nil)
        selection.selectMonth(true, reading: { throw URLError(.notConnectedToInternet) }, failed: { failure.value = $0 })
        try await settle(selection)
        XCTAssertEqual((failure.value as? URLError)?.code, .notConnectedToInternet)
        XCTAssertEqual(selection.selected, ["kept"])
        XCTAssertTrue(selection.isSelecting, "A failure keeps selecting.")
    }

    /// One month at a time: a second request while one is read is ignored. A month the feed
    /// cancelled doesn't end the one asked for after it.
    func testOneMonthIsReadAtATimeAndACancelledOneEndsNothingAfterIt() async throws {
        let selection = FeedSelection()
        let first = StubServer.Gate(), second = StubServer.Gate()
        selection.isSelecting = true
        selection.selectMonth(true, reading: { await first.wait(); return [.remote(Asset(id: "first"))] }, failed: { _ in })
        let asked = Box(false)
        selection.selectMonth(true, reading: { asked.value = true; return [.remote(Asset(id: "ignored"))] }, failed: { _ in })
        try await until("The first month was never read.") { first.waiting == 1 }
        XCTAssertFalse(asked.value, "A month asked for while another is read is ignored.")

        // The feed changes under it, as a sync's reload does, and the next month is asked for.
        selection.cancelMonthSelection()
        XCTAssertFalse(selection.isSelectingMonth)
        selection.selectMonth(true, reading: { await second.wait(); return [.remote(Asset(id: "second"))] }, failed: { _ in })
        try await until("The second month was never read.") { second.waiting == 1 }
        first.open()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(selection.isSelectingMonth, "The cancelled month's end leaves the one on its way alone.")
        XCTAssertFalse(selection.selected.contains("first"))
        second.open()
        try await settle(selection)
        XCTAssertEqual(selection.selected, ["second"])
    }

    // MARK: - Through the feed

    /// The month under the viewport is selected through the feed: a month still loading is joined,
    /// not read twice, and every photo of it is selected, though the grid holds none of them.
    func testSelectingAMonthJoinsItsLoadThroughTheFeed() async throws {
        let assets = (0..<40).map { Asset(id: "june-\($0)") }
        let api = SelectionLibrary(months: [Self.june: assets, Self.july: [Asset(id: "july")]], slow: [Self.june])
        let store = LibraryFeedStore(source: api)
        defer { store.stop() }
        await store.reload()
        let section = try XCTUnwrap(store.buckets.firstIndex { $0.id == Self.june })
        try await until("June never started loading.") { await api.calls[Self.june] == 1 }
        XCTAssertNil(store.loaded[Self.june], "June is still on its way.")
        store.navigation.section = section
        store.isSelecting = true
        store.selectMonth(true)
        XCTAssertTrue(store.isSelectingGroup)
        try await until("The month was not selected.", within: .seconds(5)) { !store.isSelectingGroup }
        XCTAssertEqual(store.selected, Set(assets.map(\.id)))
        XCTAssertEqual(Set(store.selectedAssets.map(\.id)), Set(assets.map(\.id)))
        let calls = await api.calls
        XCTAssertEqual(calls[Self.june], 1, "The selection joined the load on its way.")
        XCTAssertNil(store.error)
    }

    /// A sync's reload while a month is read for selection drops it, as the feed it was read
    /// from has changed; leaving selection does too, and nothing is selected after either.
    func testAReloadOrLeavingSelectionDropsTheMonthOnItsWay() async throws {
        let api = SelectionLibrary(months: [Self.june: [Asset(id: "june")], Self.july: [Asset(id: "july")]], slow: [Self.june])
        let store = LibraryFeedStore(source: api)
        defer { store.stop() }
        await store.reload()
        let section = try XCTUnwrap(store.buckets.firstIndex { $0.id == Self.june })
        store.navigation.section = section
        store.isSelecting = true
        store.selectMonth(true)
        XCTAssertTrue(store.isSelectingGroup)
        await store.reload(preservingPosition: true)
        XCTAssertFalse(store.isSelectingGroup, "The reload drops the month on its way.")
        try await until("June never loaded.", within: .seconds(5)) { store.loaded[Self.june] != nil }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(store.selected.isEmpty)
        XCTAssertTrue(store.isSelecting, "Selection goes on.")

        // Selected again, June is read again (the reload left it stale) and selected whole.
        store.selectMonth(true)
        try await until("June was not selected.", within: .seconds(5)) { !store.isSelectingGroup }
        XCTAssertEqual(store.selected, ["june"])
        store.selectMonth(false)
        try await until("June was not deselected.") { !store.isSelectingGroup }
        XCTAssertTrue(store.selected.isEmpty)

        // Another sync leaves June stale; selecting it reads it once more, and leaving selection
        // meanwhile drops it.
        await store.reload(preservingPosition: true)
        store.selectMonth(true)
        XCTAssertTrue(store.isSelectingGroup)
        store.isSelecting = false
        XCTAssertFalse(store.isSelectingGroup)
        try await Task.sleep(for: .milliseconds(1_300))
        XCTAssertTrue(store.selected.isEmpty)
        XCTAssertNil(store.error)
    }

    // MARK: - Support

    private static let july = "2025-07-01T00:00:00Z", june = "2025-06-01T00:00:00Z"

    /// A value a closure sets for the test to read.
    @MainActor private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    private func settle(_ selection: FeedSelection) async throws {
        try await until("The month selection never ended.") { !selection.isSelectingMonth }
    }

    private func until(_ message: String, within timeout: Duration = .seconds(3), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(message)
        throw CancellationError()
    }
}

/// Months of photos, counted as they are read; a slow month takes a second.
private actor SelectionLibrary: FakeFeedSource {
    nonisolated let cacheScope = "test-selection-" + UUID().uuidString
    private let months: [String: [Asset]]
    private let slow: Set<String>
    private(set) var calls: [String: Int] = [:]

    init(months: [String: [Asset]], slow: Set<String> = []) { self.months = months; self.slow = slow }

    func monthList(_ query: LibraryQuery) async throws -> [TimeBucket] {
        months.keys.sorted(by: >).map { TimeBucket(timeBucket: $0, count: months[$0]?.count ?? 0) }
    }
    func month(_ bucket: String, of query: LibraryQuery) async throws -> [Asset] {
        calls[bucket, default: 0] += 1
        if slow.contains(bucket) { try await Task.sleep(for: .seconds(1)) }
        return months[bucket] ?? []
    }
    func search(_ query: SearchQuery) async throws -> SearchResponse { throw ServerFailure.http(500, nil) }
    func metadataSearch(_ query: MetadataQuery) async throws -> SearchResponse { throw ServerFailure.http(500, nil) }
}
