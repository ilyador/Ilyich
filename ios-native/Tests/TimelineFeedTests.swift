import Foundation
import IlyichPlatform
import SwiftUI
import UIKit
import XCTest
@testable import Ilyich

/// The feed keyed by month (F2): months come from the viewport, not from cells, and the grid
/// reports its viewport after a reset too; a sync's reload keeps the loads on their way and lets
/// a refused month be asked for again; a month that failed for a passing reason is asked again
/// while it is on screen; a month just scrolled on is safe from eviction before the feed has
/// handled its viewport; a saved library comes back within the resident bound; a date navigation
/// joins the load on its way; and the whole-snapshot cache is gone.
@MainActor final class TimelineFeedTests: XCTestCase {
    /// The grid asks for no month itself: the months on screen and their neighbours load from the
    /// viewport the store hears of, after the feed's first two.
    func testMonthsLoadFromTheViewportWithoutCellsAsking() async throws {
        let api = FeedLibrary(months: Self.months(12))
        let store = LibraryStore(source: api)
        defer { store.stop() }
        await store.reload()
        let first = Set(store.buckets.prefix(2).map(\.id))
        try await until("The first months did not load.") { Set(store.loaded.keys) == first }
        store.visibleSections([6])
        let wanted = Set([5, 6, 7].map { store.buckets[$0].id })
        try await until("The months on screen and beside it did not load.") { wanted.isSubset(of: store.loaded.keys) }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(Set(store.loaded.keys), first.union(wanted), "Only the months on screen and beside it load.")
        let calls = await api.calls
        XCTAssertEqual(calls.values.reduce(0, +), 5)
    }

    /// A sync lands while the first months load. The loads on their way are kept, not cancelled
    /// and started again: their months show from them, and are read once more only when the grid
    /// wants them, as every month shown is after a sync.
    func testSyncReloadDoesNotRestartAnInFlightMonth() async throws {
        let api = FeedLibrary(months: Self.months(6), delay: .milliseconds(300))
        let store = LibraryStore(source: api)
        defer { store.stop() }
        await store.reload()
        let first = store.buckets[0].id, second = store.buckets[1].id, third = store.buckets[2].id
        try await until("The first months did not start loading.") {
            let calls = await api.calls
            return calls[first] == 1 && calls[second] == 1
        }

        await store.reload(preservingPosition: true)
        try await until("The months on their way never arrived.", within: .seconds(3)) { store.loaded[first] != nil && store.loaded[second] != nil }
        let cancelled = await api.cancelled
        XCTAssertEqual(cancelled, [:], "No load on its way was dropped by the sync's reload.")
        XCTAssertEqual(store.loaded[first]?.map(\.id), [first + "#1"], "A month shows from the load that was on its way.")
        try await Task.sleep(for: .milliseconds(400))
        var calls = await api.calls
        XCTAssertEqual(calls[first], 1, "Off screen, a month is not read again until the grid wants it.")
        XCTAssertEqual(calls[second], 1)

        // The grid shows the second month: it and its neighbours are read again, once.
        store.visibleSections([1])
        try await until("The months on screen were not read again after the sync.", within: .seconds(3)) {
            store.loaded[second]?.map(\.id) == [second + "#2"] && store.loaded[first]?.map(\.id) == [first + "#2"]
                && store.loaded[third]?.map(\.id) == [third + "#1"]
        }
        try await Task.sleep(for: .milliseconds(400))
        calls = await api.calls
        XCTAssertEqual(calls[second], 2, "A month on screen is read once more, no more.")
        XCTAssertEqual(calls[first], 2)
        XCTAssertEqual(calls[third], 1)
    }

    /// The grid tells the feed what new rows or a reset put on screen, not only what a scroll
    /// did: UIKit reports no scroll for an offset that did not move, and cells ask for no month,
    /// so a feed whose first two months fill less than a screen (a cold start, Favorites opened
    /// from the top of the library) loads every month shown without the user dragging.
    func testTheGridReportsItsViewportAfterAReloadWithoutAScroll() async throws {
        let api = FeedLibrary(months: Self.months(24))
        let store = LibraryStore(source: api)
        defer { store.stop() }
        let client = try APIClient(baseURL: XCTUnwrap(URL(string: "https://media.example")), accessToken: "feed-session",
                                   userID: "feed-" + UUID().uuidString)
        let pipeline = MediaPipeline(client: client)
        addTeardownBlock { await pipeline.removeAll() }
        // A phone's screen of one photo a month in three columns: months share rows, some eighteen on screen.
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UIHostingController(rootView: PhotoGrid(store: store, pipeline: pipeline, columns: 3,
                                                                              topInset: 0, bottomInset: 0) { _ in })
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }

        await store.reload()
        let first = Set(store.buckets.prefix(2).map(\.id))
        try await until("The first months did not load.") { first.isSubset(of: store.loaded.keys) }
        try await until("The months on screen beyond the first two did not all load without a scroll.") {
            let shown = store.visibleBucketIDs
            return shown.count > 2 && shown.isSubset(of: store.loaded.keys)
        }
        XCTAssertEqual(store.navigation.section, 0, "The grid reported where it is.")
        try await Task.sleep(for: .milliseconds(200))
        let shown = store.visibleBucketIDs
        let near = Set(store.buckets.indices.filter { shown.contains(store.buckets[$0].id) }
            .flatMap { [$0 - 1, $0, $0 + 1] }.filter { store.buckets.indices.contains($0) }.map { store.buckets[$0].id })
        XCTAssertTrue(Set(store.loaded.keys).isSubset(of: near.union(first)), "Only the months on screen and beside them load.")
        XCTAssertLessThan(store.loaded.count, store.buckets.count, "Months far below the screen stay unread.")
    }

    /// A sync's reload takes the banner and its Retry down and marks every month stale, the
    /// refused ones too: a month that failed with a refusal is asked for again when the grid wants
    /// it, so no month stays placeholders for good.
    func testASyncReloadLetsARefusedMonthBeAskedForAgain() async throws {
        let months = Self.months(6)
        let api = FeedLibrary(months: months)
        let refused = months[2]
        await api.fail(refused, times: 1, with: ServerFailure.http(403, nil))
        let store = LibraryStore(source: api)
        defer { store.stop() }
        await store.reload()
        store.visibleSections([2])
        try await until("The refusal was not reported.") { store.bucketErrors[refused] != nil }
        try await Task.sleep(for: .milliseconds(200))
        var calls = await api.calls
        XCTAssertEqual(calls[refused], 1, "A refusal is not retried by itself.")
        XCTAssertNil(store.loaded[refused])

        await store.reload(preservingPosition: true)
        XCTAssertEqual(store.bucketErrors, [:], "The reload takes the banner down.")
        try await until("The refused month on screen was not asked for again after the sync.") { store.loaded[refused] != nil }
        calls = await api.calls
        XCTAssertEqual(calls[refused], 2)
    }

    /// The months the grid reports on screen are safe from eviction at once, before the feed has
    /// handled the viewport behind them in its queue: a load that lands in between keeps the month
    /// that has just scrolled on and lets the next least recent go instead.
    func testAMonthJustScrolledOnIsNotEvictedBeforeItsViewportArrives() async throws {
        let months = Self.months(14)
        // The month the grid moves to lands during the race; the one beside it never does.
        let api = FeedLibrary(months: months, slow: [months[12]: .milliseconds(300), months[13]: .seconds(10)])
        let keys = try months.map { try XCTUnwrap(MonthKey(bucketID: $0)) }
        let viewport = TimelineFeed.Viewport()
        let feed = TimelineFeed(source: api, viewport: viewport)
        let recorder = FeedRecorder()
        let ticket = TimelineFeed.Ticket()
        let plan = try await api.plan(.library)
        await feed.handle([.attach(recorder), .open(ticket, .library, plan),
                           .months(keys, buckets: Dictionary(uniqueKeysWithValues: zip(keys, months)))])
        // Twelve months resident, the first the least recently loaded.
        for key in keys.prefix(TimelineFeed.residentLimit) { _ = try await feed.assets(of: key, ticket: ticket) }
        XCTAssertEqual(recorder.loaded.count, TimelineFeed.residentLimit)
        XCTAssertEqual(recorder.evicted, [])

        await feed.handle([.viewport(visible: [keys[12]])])
        // The grid is back at the top before the feed hears of it through the queue.
        viewport.show([keys[0]])
        try await until("The month the grid moved to never landed.") { recorder.loaded[keys[12]] != nil }
        XCTAssertEqual(recorder.evicted, [keys[1]], "The month just scrolled on stays; the next least recent goes.")
        XCTAssertNotNil(recorder.loaded[keys[0]])
        await feed.handle([.close])
    }

    /// A sparse feed (an album with a photo or two a month) puts many months on one screen: every
    /// one of them loads, not only the first few the queue holds at a time, without another scroll.
    func testEveryMonthOnASparseScreenLoads() async throws {
        let months = Self.months(20)
        let api = FeedLibrary(months: months, delay: .milliseconds(20))
        let keys = try months.map { try XCTUnwrap(MonthKey(bucketID: $0)) }
        let feed = TimelineFeed(source: api, viewport: TimelineFeed.Viewport())
        let recorder = FeedRecorder()
        let ticket = TimelineFeed.Ticket()
        let plan = try await api.plan(.library)
        await feed.handle([.attach(recorder), .open(ticket, .library, plan),
                           .months(keys, buckets: Dictionary(uniqueKeysWithValues: zip(keys, months))),
                           .viewport(visible: Set(keys))])
        try await until("Months on screen were left as placeholders.") { Set(recorder.loaded.keys) == Set(keys) }
        XCTAssertEqual(recorder.evicted, [], "Months on screen are never let go.")
        let calls = await api.calls
        XCTAssertEqual(calls.values.reduce(0, +), keys.count, "Each month is read once.")
        await feed.handle([.close])
    }

    /// A month on screen that failed for a passing reason is asked again by itself, after a
    /// second; a refusal waits for Retry, and a failed month off screen waits for the grid.
    func testFailedVisibleMonthRetriesAfterATransientError() async throws {
        let months = Self.months(6)
        let api = FeedLibrary(months: months)
        // The summary lists them newest first, as made.
        let passing = months[1], refused = months[4], unseen = months[5]
        await api.fail(passing, times: 1, with: URLError(.timedOut))
        await api.fail(refused, times: 10, with: ServerFailure.http(404, nil))
        await api.fail(unseen, times: 10, with: URLError(.timedOut))
        let store = LibraryStore(source: api)
        defer { store.stop() }
        await store.reload()
        XCTAssertEqual(store.buckets.map(\.id), months)
        store.visibleSections([1])
        try await until("The passing failure was not reported.") { store.bucketErrors[passing] != nil }
        XCTAssertNil(store.loaded[passing])
        try await until("The month on screen was not asked for again.", within: .seconds(4)) { store.loaded[passing] != nil }
        XCTAssertNil(store.bucketErrors[passing], "A month that loaded on retry has no error.")
        var calls = await api.calls
        XCTAssertEqual(calls[passing], 2)

        store.visibleSections([4])
        try await until("The refusal was not reported.") { store.bucketErrors[refused] != nil }
        store.requestBucket(5)
        try await until("The unseen month's failure was not reported.") { store.bucketErrors[unseen] != nil }
        try await Task.sleep(for: .milliseconds(1_600))
        calls = await api.calls
        XCTAssertEqual(calls[refused], 1, "A refusal is not retried by itself.")
        XCTAssertEqual(calls[unseen], 1, "A month off screen is not retried by itself.")

        store.retryFailedBuckets()
        XCTAssertEqual(store.bucketErrors, [:])
        try await until("Retry did not ask for the refused month on screen.") { await api.calls[refused] == 2 }
        try await until("The refusal was not reported again.") { store.bucketErrors[refused] != nil }
    }

    /// The library saved behind a filter comes back with at most twelve months, those nearest where
    /// it was left, and a month it kept is not read again: neither by the check against the source
    /// that follows a clear (F4), whose counts agree with it, nor for a selection.
    func testRestoredMonthsStayWithinTheResidentBound() async throws {
        let api = FeedLibrary(months: Self.months(20))
        let store = LibraryStore(source: api)
        defer { store.stop() }
        await store.reload()
        store.loaded = Dictionary(uniqueKeysWithValues: store.buckets.map { ($0.id, [Asset(id: $0.id + "#saved")]) })
        let anchor = store.buckets[10].id
        store.position = GridPosition(section: anchor, item: 0, offset: 0)

        store.setFeed(.favorites, title: "Favorites")
        try await until("Favorites did not replace the library.") { !store.isReplacingFeed && store.filterTitle == "Favorites" }
        let summaries = await api.summaries
        store.clearFilters()
        XCTAssertLessThanOrEqual(store.loaded.count, TimelineFeed.residentLimit)
        XCTAssertEqual(Set(store.loaded.keys), Set(store.buckets[4...15].map(\.id)), "The months nearest the anchor are kept.")
        XCTAssertEqual(store.restorePosition?.section, anchor)
        try await until("The restored library was not counted again.") { await api.summaries > summaries && !store.isLoading }

        let before = await api.calls
        store.navigation.section = 10; store.isSelecting = true
        store.selectMonth(true)
        try await until("The month was not selected.") { !store.isSelectingGroup }
        XCTAssertEqual(store.selected, [anchor + "#saved"], "A kept month serves selection as it was.")
        let after = await api.calls
        XCTAssertEqual(after[anchor], before[anchor], "A kept month is not read again.")
        XCTAssertNil(after[anchor], "The kept month's rows are the saved ones; the source was never asked for it.")
    }

    /// Show in timeline for a photo whose month is already loading joins that load: no second
    /// request, and the scroll request follows as soon as it lands.
    func testShowInTimelineJoinsInFlightWithoutPolling() async throws {
        let months = Self.months(6)
        let slow = months[3]
        let api = FeedLibrary(months: months, slow: [slow: .milliseconds(600)])
        let store = LibraryStore(source: api)
        defer { store.stop() }
        await store.reload()
        let section = try XCTUnwrap(store.buckets.firstIndex { $0.id == slow })
        store.requestBucket(section)
        try await until("The month did not start loading.") { await api.calls[slow] == 1 }
        let date = try XCTUnwrap(APIDate.parse(String(slow.prefix(8)) + "15T12:00:00Z"))
        store.showInTimeline(Asset(id: slow + "#1", localDateTime: date))
        try await until("The navigation never published.", within: .seconds(3)) { store.scrollRequest != nil }
        XCTAssertEqual(store.scrollRequest?.position.assetID, slow + "#1")
        XCTAssertEqual(store.scrollRequest?.position.section, slow)
        let calls = await api.calls, cancelled = await api.cancelled
        XCTAssertEqual(calls[slow], 1, "The navigation joined the load on its way instead of starting another.")
        XCTAssertEqual(cancelled[slow, default: 0], 0)
        XCTAssertNil(store.error)
    }

    /// The whole-snapshot cache is gone: nothing is written under Caches/IlyichTimelines, and the
    /// folder an older build left is deleted at launch.
    func testNoTimelineSnapshotIsKeptAndTheOldFolderIsDeleted() async throws {
        let api = FeedLibrary(months: Self.months(3))
        let store = LibraryStore(source: api)
        defer { store.stop() }
        await store.reload()
        try await until("The months did not load.") { store.loaded.count == 2 }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        XCTAssertFalse(FileManager.default.fileExists(atPath: caches.appendingPathComponent("IlyichTimelines").path))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("IlyichTimelines/0f3a", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: legacy.appendingPathComponent("feed.json"))
        TimelineFeed.deleteLegacySnapshots(cachesDirectory: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("IlyichTimelines").path))
        TimelineFeed.deleteLegacySnapshots(cachesDirectory: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path), "Deleting again is harmless.")
    }

    func testBackoffDoublesFromOneSecondToThirtyAndRefusalsAreNotTransient() {
        XCTAssertEqual((1...7).map { TimelineFeed.backoff(attempts: $0) }, [1, 2, 4, 8, 16, 30, 30].map { Duration.seconds($0) })
        XCTAssertTrue(TimelineFeed.isTransient(URLError(.notConnectedToInternet)))
        XCTAssertTrue(TimelineFeed.isTransient(URLError(.timedOut)))
        XCTAssertTrue(TimelineFeed.isTransient(TransportFailure.unreachable(.cannotConnectToHost)))
        XCTAssertTrue(TimelineFeed.isTransient(ServerFailure.http(503, nil)))
        XCTAssertTrue(TimelineFeed.isTransient(ServerFailure.http(429, nil)))
        XCTAssertFalse(TimelineFeed.isTransient(ServerFailure.http(404, nil)))
        XCTAssertFalse(TimelineFeed.isTransient(ServerFailure.http(400, "bad")))
        XCTAssertFalse(TimelineFeed.isTransient(ServerFailure.sessionExpired(nil)))
        XCTAssertFalse(TimelineFeed.isTransient(CancellationError()))
    }

    // MARK: - Helpers

    /// `count` months of 2025 and before, one a month, newest first as the summary lists them.
    private static func months(_ count: Int) -> [String] {
        (0..<count).map { String(format: "%04d-%02d-01T00:00:00Z", 2025 - $0 / 12, 12 - $0 % 12) }
    }

    private func until(_ message: String, within timeout: Duration = .seconds(5), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(message)
    }
}

/// Takes the feed's deliveries as the store does: a month shown, the months let go, the failures.
@MainActor private final class FeedRecorder: TimelineFeedConsumer {
    var loaded: [MonthKey: [Asset]] = [:]
    var evicted: [MonthKey] = []
    var failed: [MonthKey: String] = [:]
    func monthLoaded(_ ticket: TimelineFeed.Ticket, month: MonthKey, assets: [Asset], fresh: Bool, evicting: [MonthKey]) {
        for gone in evicting { loaded[gone] = nil }
        loaded[month] = assets; evicted += evicting
    }
    func monthFailed(_ ticket: TimelineFeed.Ticket, month: MonthKey, message: String) { failed[month] = message }
}

/// A library of one photo a month, named by the month and the number of the call that read it.
/// Loads take `delay` (or a month's own `slow` time), count their calls and cancellations, and
/// fail as told; a cancelled load ends as a dropped URLSession request does.
private actor FeedLibrary: FakeFeedSource {
    nonisolated let cacheScope = "test-feed-" + UUID().uuidString
    private let months: [String]
    private let delay: Duration
    private let slow: [String: Duration]
    private var failures: [String: (remaining: Int, error: any Error)] = [:]
    private(set) var calls: [String: Int] = [:]
    private(set) var cancelled: [String: Int] = [:]
    private(set) var summaries = 0

    init(months: [String], delay: Duration = .zero, slow: [String: Duration] = [:]) {
        self.months = months; self.delay = delay; self.slow = slow
    }

    /// The next `times` loads of the month throw `error`.
    func fail(_ bucket: String, times: Int, with error: any Error) { failures[bucket] = (times, error) }

    func monthList(_ query: LibraryQuery) async throws -> [TimeBucket] {
        summaries += 1
        return months.sorted(by: >).map { TimeBucket(timeBucket: $0, count: 1) }
    }
    func month(_ bucket: String, of query: LibraryQuery) async throws -> [Asset] {
        calls[bucket, default: 0] += 1
        let call = calls[bucket, default: 0]
        let wait = slow[bucket] ?? delay
        if wait > .zero {
            do { try await Task.sleep(for: wait) } catch { cancelled[bucket, default: 0] += 1; throw URLError(.cancelled) }
        }
        if let failure = failures[bucket], failure.remaining > 0 {
            failures[bucket] = (failure.remaining - 1, failure.error)
            throw failure.error
        }
        return [Asset(id: "\(bucket)#\(call)")]
    }
    func search(_ query: SearchQuery) async throws -> SearchResponse { throw ServerFailure.http(500, nil) }
    func metadataSearch(_ query: MetadataQuery) async throws -> SearchResponse { throw ServerFailure.http(500, nil) }
}
