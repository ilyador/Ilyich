import CoreGraphics
import Foundation
import SQLite3
import UIKit
import XCTest
@testable import Ilyich

/// What scrubbing the time rail leans on: sketches decoded off the main thread in the format Core
/// Animation draws, day groups worked out without the calendar, months loaded one at a time as
/// they arrive, months found through their own index, and a month queue that serves the month a
/// scrub lands on before the ones it passed, keeps loading the months ahead of the grid and asks
/// again for a month it dropped once the grid comes back to it.
@MainActor final class ScrubbingTests: XCTestCase {
    private static let hashes = ["HIcNXIyGh4d/eHh5eIWHcEf3dQ==", "nMcJLBRyB4iHeId4eHhycNgIhw==", "W1eGHQYmgIqAeqinh4R/B4iIB3iHiICJeA=="]

    // MARK: - Sketches

    func testSketchesArePremultipliedInCoreAnimationsOrderAndDrawTheSamePixels() throws {
        for hash in Self.hashes {
            let reference = try XCTUnwrap(ThumbHash.pixels([UInt8](try XCTUnwrap(Data(base64Encoded: hash)))))
            let image = try XCTUnwrap(ThumbHash.image(hash))
            let opaque = stride(from: 3, to: reference.rgba.count, by: 4).allSatisfy { reference.rgba[$0] == 255 }
            XCTAssertEqual(image.alphaInfo, opaque ? .noneSkipFirst : .premultipliedFirst, hash)
            XCTAssertEqual(image.bitmapInfo.intersection(.byteOrderMask), .byteOrder32Little, hash)
            XCTAssertEqual(image.width, reference.width); XCTAssertEqual(image.height, reference.height)

            // The bytes are the reference decode, reordered and premultiplied.
            let bytes = [UInt8](try XCTUnwrap(image.dataProvider?.data) as Data)
            XCTAssertEqual(bytes.count, reference.rgba.count)
            for i in stride(from: 0, to: bytes.count, by: 4) {
                let alpha = Int(reference.rgba[i + 3])
                func premultiplied(_ channel: Int) -> Int { (Int(reference.rgba[i + channel]) * alpha + 127) / 255 }
                XCTAssertEqual([Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]), Int(bytes[i + 3])],
                               [premultiplied(2), premultiplied(1), premultiplied(0), alpha], "\(hash) byte \(i)")
            }

            // Drawn, it looks as the straight-alpha sketch did before.
            let straight = try XCTUnwrap(CGImage(
                width: reference.width, height: reference.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: reference.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: CGDataProvider(data: Data(reference.rgba) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            let before = try draw(straight), after = try draw(image)
            for i in before.indices {
                XCTAssertEqual(Int(before[i]), Int(after[i]), accuracy: 1, "\(hash) drawn byte \(i)")
            }
        }
    }

    /// Both images drawn at their own size into the same premultiplied RGBA bitmap.
    private func draw(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                                  bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    /// Values from the reference `thumbHashToAverageRGBA`; the sketch's own pixels average close to them.
    func testTheAverageColourIsTheReferences() throws {
        let expected: [(Double, Double, Double, Double)] = [(0.2884, 0.5265, 0.5185, 1), (0.3730, 0.4841, 0.4762, 1), (0.4894, 0.3148, 0.4815, 0.4)]
        for (hash, colour) in zip(Self.hashes, expected) {
            let bytes = [UInt8](try XCTUnwrap(Data(base64Encoded: hash)))
            let average = try XCTUnwrap(ThumbHash.averageColor(bytes))
            XCTAssertEqual(average.red, colour.0, accuracy: 0.0001, hash); XCTAssertEqual(average.green, colour.1, accuracy: 0.0001, hash)
            XCTAssertEqual(average.blue, colour.2, accuracy: 0.0001, hash); XCTAssertEqual(average.alpha, colour.3, accuracy: 0.0001, hash)
            let pixels = try XCTUnwrap(ThumbHash.pixels(bytes))
            guard colour.3 == 1 else { continue }
            for (channel, value) in [average.red, average.green, average.blue].enumerated() {
                let mean = stride(from: channel, to: pixels.rgba.count, by: 4).reduce(0.0) { $0 + Double(pixels.rgba[$1]) / 255 } / Double(pixels.width * pixels.height)
                XCTAssertEqual(mean, value, accuracy: 0.08, "\(hash) channel \(channel)")
            }
        }
        XCTAssertNil(ThumbHash.averageColor([0x1c, 0x87]), "A truncated header has no colour.")
        XCTAssertNil(ThumbHash.averageColor("not base64"))
        XCTAssertNotNil(ThumbHash.averageColor(Self.hashes[0]))
    }

    func testASketchDecodesOnceForEveryoneWaitingAndStaysInMemory() async throws {
        let sketches = ThumbHashSketches(countLimit: 10)
        let hash = Self.hashes[0]
        XCTAssertNil(sketches.cached(hash), "Nothing is decoded until asked for.")
        async let first = sketches.sketch(hash)
        async let second = sketches.sketch(hash)
        let (one, two) = await (first, second)
        let image = try XCTUnwrap(one)
        XCTAssertTrue(two === image, "Callers waiting together share one decode.")
        XCTAssertTrue(sketches.cached(hash) === image)
        XCTAssertEqual(image.width, 32)
        let damaged = await sketches.sketch("not base64")
        XCTAssertNil(damaged)
        // Asked from the main thread, as a grid cell asks, the decode still runs off it.
        let fromMain = await MainActor.run { Task { await sketches.sketch(Self.hashes[2]) } }.value
        XCTAssertTrue(sketches.cached(Self.hashes[2]) === fromMain)

        sketches.prefetch([Self.hashes[1], "", Self.hashes[1]])
        let deadline = ContinuousClock.now + .seconds(5)
        while sketches.cached(Self.hashes[1]) == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(sketches.cached(Self.hashes[1]), "A photo about to scroll in has its sketch ready.")
        XCTAssertEqual(sketches.mainThreadDecodes.load(ordering: .relaxed), 0, "A sketch decoded on the main thread.")
    }

    /// A cell's stored thumbnail is read while its sketch decodes: with sketches of photos about to
    /// scroll in still queued ahead of its own, the thumbnail draws without waiting for them.
    func testAStoredThumbnailDoesNotWaitForTheSketch() async throws {
        let api = try APIClient(baseURL: XCTUnwrap(URL(string: "https://media.example")), accessToken: "scrub-session",
                                userID: "scrub-" + UUID().uuidString)
        let pipeline = MediaPipeline(client: api)
        addTeardownBlock { await pipeline.removeAll() }
        // Sketches no test has decoded: the first one's with other AC bytes, fewer than the
        // sketches memory keeps.
        let base = [UInt8](try XCTUnwrap(Data(base64Encoded: Self.hashes[0])))
        let fresh = (0..<2_001).map { index in
            var bytes = base
            bytes[5] = UInt8(index & 0xff); bytes[6] = UInt8(index >> 8 & 0xff)
            return Data(bytes).base64EncodedString()
        }
        let asset = Asset(id: "stored-" + UUID().uuidString, thumbhash: fresh[2_000])
        let png = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        await ThumbnailDiskStore.shared(scope: api.cacheScope).store(png, assetID: asset.id, revision: asset.cacheRevision)
        let ahead = Array(fresh.prefix(2_000))
        ThumbHashSketches.shared.prefetch(ahead)

        let cell = PhotoCell(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        // As in a scrub: the grid moves too fast to decode sketches or download here.
        cell.configure(entry: .remote(asset), pipeline: pipeline, selected: false, selecting: false, month: nil, network: false)
        try await until("The stored thumbnail never drew.", within: .seconds(30)) { cell.showsThumbnail }
        XCTAssertNil(ThumbHashSketches.shared.cached(ahead[ahead.count - 1]), "It drew while the sketches ahead of its own were still decoding.")
    }

    /// When UIKit animates a cell's size, as when the app turns back upright after the viewer, the
    /// photo animates with the cell instead of jumping to its new size.
    func testThePhotoFollowsItsCellsAnimatedResize() throws {
        let cell = PhotoCell(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        cell.layoutIfNeeded()
        UIView.animate(withDuration: 0.3) {
            cell.frame = CGRect(x: 0, y: 0, width: 160, height: 160)
            cell.layoutIfNeeded()
        }
        // The photo's layer is the cell's first, under every overlay.
        let photo = try XCTUnwrap(cell.contentView.layer.sublayers?.first)
        XCTAssertEqual(photo.bounds.size, CGSize(width: 160, height: 160))
        XCTAssertFalse((photo.animationKeys() ?? []).isEmpty, "The photo animates with its cell.")
    }

    // MARK: - Days and months

    func testDaysAreTheCalendarsDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var style = Date.FormatStyle().month(.wide).day().year()
        style.timeZone = calendar.timeZone
        // Several photos a day, across midnight, months and years, before 2001 and before 1970.
        let times = ["2026-03-02T23:59:59Z", "2026-03-02T00:00:00Z", "2026-03-01T23:59:59Z", "2026-03-01T12:00:00Z", "2026-02-28T00:00:01Z",
                     "2001-01-01T00:00:00Z", "2000-12-31T23:59:59Z", "2000-12-31T00:00:00Z", "1969-12-31T23:00:00Z", "1969-12-31T01:00:00Z",
                     "1969-12-30T23:59:59Z", "1901-07-04T10:00:00Z"]
        let entries = try times.enumerated().map { index, time in
            LibraryEntry.remote(Asset(id: "photo-\(index)", localDateTime: try XCTUnwrap(APIDate.parse(time))))
        }
        var expected: [TimelineDayGroup] = []
        var current: Date?
        for (item, entry) in entries.enumerated() {
            let day = calendar.startOfDay(for: entry.date)
            if current == day { expected[expected.count - 1].count += 1 }
            else { expected.append(TimelineDayGroup(startItem: item, count: 1, title: day.formatted(style))); current = day }
        }
        XCTAssertEqual(LibraryStore.dayGroups(entries), expected)
        XCTAssertEqual(expected.count, 8)
        XCTAssertEqual(LibraryStore.dayGroups([]), [])
    }

    /// Each month loaded redoes only its own rows and days; a month let go for room loses them, and
    /// a full redo agrees.
    func testLoadingAMonthRedoesOnlyThatMonthAndForgetsTrimmedOnes() async throws {
        let months = (0..<14).map { String(format: "%04d-%02d-01T00:00:00Z", 2024 + $0 / 12, $0 % 12 + 1) }
        var library: [String: [Asset]] = [:]
        for (index, month) in months.enumerated() {
            let day = String(month.prefix(8))
            let first = try XCTUnwrap(APIDate.parse(day + "20T12:00:00Z")), second = try XCTUnwrap(APIDate.parse(day + "03T12:00:00Z"))
            library[month] = [Asset(id: "a\(index)", localDateTime: first), Asset(id: "b\(index)", localDateTime: first),
                              Asset(id: "c\(index)", localDateTime: second)]
        }
        let api = MonthLibrary(months: library)
        let store = LibraryStore(api: api)
        defer { store.stop() }
        addTeardownBlock { await TimelineCache.shared.removeAll(scope: api.cacheScope) }
        await store.reload()
        for section in store.buckets.indices {
            store.requestBucket(section)
            let id = store.buckets[section].id
            try await until("\(id) did not load.") { store.loaded[id] != nil }
        }
        XCTAssertEqual(store.loaded.count, 12, "Twelve months stay loaded.")
        for section in store.buckets.indices {
            let groups = store.dayGroups(section: section)
            if store.loaded[store.buckets[section].id] == nil {
                XCTAssertEqual(groups, [], "A month let go has no days.")
            } else {
                XCTAssertEqual(groups.map(\.startItem), [0, 2]); XCTAssertEqual(groups.map(\.count), [2, 1])
            }
        }
        let incremental = store.buckets.indices.map { store.dayGroups(section: $0) }
        // update(_:) redoes every month.
        let some = try XCTUnwrap(store.buckets.indices.lazy.compactMap { store.asset(section: $0, item: 0) }.first)
        store.update(some)
        XCTAssertEqual(store.buckets.indices.map { store.dayGroups(section: $0) }, incremental)
    }

    // MARK: - The month queue

    /// The months a scrub passes are still loading when it stops: they give way to the month it
    /// stops on, which loads next, and none of them is kept.
    func testAScrubLoadsTheMonthItStopsOnBeforeTheMonthsItPassed() async throws {
        let (store, api) = await scrubbableLibrary()
        defer { store.stop() }
        // The rail sweeps from the newest month to the 25th, a frame or so at each.
        for section in 0...24 {
            store.visibleSection(section, visible: [section])
            await Task.yield()
        }
        let landed = store.buckets[24].id
        try await until("The month the scrub stopped on never loaded.", within: .seconds(15)) { store.loaded[landed] != nil }
        let passed = Set(store.buckets[0...21].map(\.id))
        // The order the loads finished in, not how long they took: a busy machine slows every load.
        let finished = await api.finished
        XCTAssertFalse(finished.prefix { $0 != landed }.contains(where: passed.contains),
                       "It waited for its own load, not for the months passed: \(finished)")
        XCTAssertEqual(store.buckets[0...21].map(\.id).filter { store.loaded[$0] != nil }, [], "Months the scrub left behind were dropped, not loaded.")
        XCTAssertEqual(store.bucketErrors, [:], "A dropped month is not a month that failed.")
        let concurrent = await api.maximumConcurrent
        XCTAssertLessThanOrEqual(concurrent, 3)
    }

    /// A month the grid leaves while it loads, and comes back to before the dropped load has wound
    /// down, is asked for again once it has: it does not wait on screen for the next scroll.
    func testAMonthTheGridComesBackToLoadsAfterItsDroppedLoadEnds() async throws {
        let (store, _) = await scrubbableLibrary()
        defer { store.stop() }
        store.visibleSection(20, visible: [20])
        await Task.yield()
        // Away and back within a frame or two, before the dropped load has ended.
        store.visibleSection(24, visible: [24])
        store.visibleSection(20, visible: [20])
        let month = store.buckets[20].id
        try await until("The month the grid came back to never loaded.", within: .seconds(15)) { store.loaded[month] != nil }
        XCTAssertEqual(store.bucketErrors, [:], "A dropped month is not a month that failed.")
    }

    /// A month ahead of the grid, which prefetch asked for, keeps loading while the grid moves toward
    /// it; only months the grid leaves behind are dropped.
    func testAMonthAheadOfTheGridKeepsLoadingAsTheGridMovesTowardIt() async throws {
        let (store, _) = await scrubbableLibrary()
        defer { store.stop() }
        store.visibleSection(0, visible: [0])
        // The two newest months are loading; prefetch takes the last slot for a month further down.
        store.requestBucket(6)
        await Task.yield()
        for section in 1...3 {
            store.visibleSection(section, visible: [section])
            await Task.yield()
        }
        let ahead = store.buckets[6].id
        try await until("A month ahead of the grid was dropped.", within: .seconds(15)) { store.loaded[ahead] != nil }
        XCTAssertEqual(store.bucketErrors, [:])
    }

    // MARK: - Helpers

    /// Thirty months, one a year, whose loads take a second; a dropped load ends as a dropped
    /// URLSession request does.
    private func scrubbableLibrary() async -> (LibraryStore, MonthLibrary) {
        let months = (0..<30).map { String(format: "%04d-06-01T00:00:00Z", 2000 + $0) }
        let api = MonthLibrary(months: Dictionary(uniqueKeysWithValues: months.map { ($0, [Asset(id: "photo-\($0)")]) }),
                               delay: .seconds(1), cancelled: URLError(.cancelled))
        addTeardownBlock { await TimelineCache.shared.removeAll(scope: api.cacheScope) }
        let store = LibraryStore(api: api)
        await store.reload()
        return (store, api)
    }

    private func until(_ message: String, within timeout: Duration = .seconds(5), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail(message)
    }
}

/// Month loads through the local index read asset_index (Q3): a month is a range of its index,
/// newest first by the time taken (or added), read in order without sorting and without reading
/// any other photo's record.
final class MonthIndexTests: XCTestCase {
    func testMonthsAreReadInOrderFromTheirIndex() async throws {
        let root = temporaryDirectory()
        let store = try EntityStore(scope: "server|month-index", userID: "alice", directory: root)
        // 24,000 photos over 240 months, as in the UI test library.
        try await Self.addPhotos(24_000, to: store)
        let clock = ContinuousClock()
        let month = "2015-06-01T00:00:00Z"
        let filters = [TimelineFilter(), TimelineFilter(isFavorite: true), TimelineFilter(visibility: .archive),
                       TimelineFilter(withPartners: true), TimelineFilter(orderBy: "createdAt")]

        var loaded: [[String]] = []
        var elapsed = Duration.zero
        for filter in filters {
            let plan = try await store.timeBucketPlan(month, filter: filter)
            let index = filter.orderBy == "createdAt" ? "asset_index_added" : "asset_index_taken"
            XCTAssertTrue(plan.contains { $0.contains("USING INDEX \(index)") || $0.contains("USING COVERING INDEX \(index)") }, "\(filter): \(plan)")
            XCTAssertFalse(plan.contains { $0.contains("TEMP B-TREE") }, "A month is read in order, not sorted: \(filter): \(plan)")
            elapsed += try await clock.measure { loaded.append(try await store.timeBucket(month, filter: filter).map(\.id)) }
        }
        XCTAssertEqual(loaded[0].count, (11_300..<11_400).count { $0 % 50 != 0 && $0 % 40 != 0 }, "Archived and Bob's photos stay out.")
        let expected = (11_300..<11_400).filter { $0 % 50 != 0 && $0 % 40 != 0 }
            .sorted { ($0 % 28, $0 % 24) > ($1 % 28, $1 % 24) }.map { String(format: "photo-%05d", $0) }
        XCTAssertEqual(loaded[0], expected, "Newest first by the time taken.")
        XCTAssertTrue(loaded[4].allSatisfy { Int($0.dropFirst(6))! / 100 == 112 }, "Added in June 2015, taken the month before.")
        let months = try await store.timeBuckets()
        XCTAssertEqual(months.count, 240)
        let all = try await clock.measure { _ = try await store.timeBuckets() }
        print("MONTH INDEX 24,000 photos: \(filters.count) month loads took \(elapsed.formatted(.units(allowed: [.milliseconds]))), the month list \(all.formatted(.units(allowed: [.milliseconds])))")
    }

    /// A library synced before Q3 has month indexes over the entities, which a second read-write
    /// connection built. Opening it drops them: nothing reads them, and every write paid for them.
    func testOpeningDropsTheOldMonthIndexes() async throws {
        let root = temporaryDirectory()
        let scope = "server|month-index-old"
        var store: EntityStore? = try EntityStore(scope: scope, userID: "alice", directory: root)
        try await Self.addPhotos(200, to: store!)
        store = nil
        let file = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "sqlite" })
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &database), SQLITE_OK)
        for date in ["localDateTime", "createdAt"] {
            XCTAssertEqual(sqlite3_exec(database, "CREATE INDEX asset_month_\(date) ON entities(kind,strftime('%Y-%m',json_extract(payload,'$.\(date)'))) WHERE kind='asset'", nil, nil, nil), SQLITE_OK)
        }
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA user_version=1", nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)

        store = try EntityStore(scope: scope, userID: "alice", directory: root)
        let month = try await store!.timeBucket("2006-01-01T00:00:00Z").map(\.id)
        XCTAssertEqual(month.count, 96)
        XCTAssertEqual(sqlite3_open(file.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "SELECT count(*) FROM sqlite_master WHERE name LIKE 'asset_month_%'", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 0)
        sqlite3_finalize(statement)
    }

    private func temporaryDirectory() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// Photos a hundred a month from January 2006, each with its EXIF, a few of them favorites,
    /// archived, a partner's or added in another month than taken.
    private static func addPhotos(_ count: Int, to store: EntityStore) async throws {
        let epoch = await store.epoch()
        _ = try await store.prepare(sessionFingerprint: "session")
        let decoder = JSONDecoder()
        for batch in stride(from: 0, to: count, by: 2_000) {
            var events: [EntitySyncEvent] = []
            for index in batch..<min(count, batch + 2_000) {
                let month = index / 100, day = index % 28 + 1
                let taken = String(format: "%04d-%02d-%02dT%02d:00:00Z", 2006 + month / 12, month % 12 + 1, day, index % 24)
                let added = String(format: "%04d-%02d-15T00:00:00Z", 2006 + (month + 1) / 12, (month + 1) % 12 + 1)
                let id = String(format: "photo-%05d", index)
                let asset = """
                {"id":"\(id)","ownerId":"\(index % 50 == 0 ? "bob" : "alice")","type":"IMAGE","originalFileName":"\(id).HEIC","checksum":"AQIDBA==","width":4032,"height":3024,"fileCreatedAt":"\(taken)","localDateTime":"\(taken)","createdAt":"\(added)","visibility":"\(index % 40 == 0 ? "archive" : "timeline")","isFavorite":\(index % 7 == 0),"deletedAt":null,"stackId":null,"isEdited":false,"isDeveloped":false,"mediaRevision":"r\(index)","thumbhash":"HIcNXIyGh4d/eHh5eIWHcEf3dQ=="}
                """
                let exif = """
                {"assetId":"\(id)","city":"\(index % 3 == 0 ? "Lisbon" : "Porto")","country":"Portugal","make":"Apple","model":"iPhone","exposureTime":"1/120","fNumber":1.8,"iso":64,"description":"","fileSizeInByte":2400000}
                """
                events.append(.init(type: "AssetV2", data: try decoder.decode([String: EntityJSON].self, from: Data(asset.utf8)), ack: "AssetV2|\(id)"))
                events.append(.init(type: "AssetExifV1", data: try decoder.decode([String: EntityJSON].self, from: Data(exif.utf8)), ack: "AssetExifV1|\(id)"))
            }
            _ = try await store.apply(events, epoch: epoch)
        }
    }
}

/// A library of months whose loads take `delay`, counting how many run at once.
private actor MonthLibrary: LibraryAPI {
    nonisolated let cacheScope = "test-scrubbing-" + UUID().uuidString
    private let months: [String: [Asset]]
    private let delay: Duration
    private let cancelled: (any Error)?
    private var running = 0
    private(set) var maximumConcurrent = 0
    /// The months whose loads finished, in the order they did.
    private(set) var finished: [String] = []

    /// `cancelled` is what a cancelled load throws, CancellationError unless given.
    init(months: [String: [Asset]], delay: Duration = .zero, cancelled: (any Error)? = nil) {
        self.months = months; self.delay = delay; self.cancelled = cancelled
    }

    func timeBuckets(filter: TimelineFilter) async throws -> [TimeBucket] {
        months.keys.sorted(by: >).map { TimeBucket(timeBucket: $0, count: months[$0]?.count ?? 0) }
    }
    func timeBucket(_ bucket: String, filter: TimelineFilter) async throws -> [Asset] {
        running += 1; maximumConcurrent = max(maximumConcurrent, running)
        defer { running -= 1 }
        if delay > .zero {
            do { try await Task.sleep(for: delay) } catch { throw cancelled ?? error }
        }
        finished.append(bucket)
        return months[bucket] ?? []
    }
    func search(_ query: SearchQuery) async throws -> SearchResponse { throw ServerFailure.http(500, nil) }
    func metadataSearch(_ query: MetadataQuery) async throws -> SearchResponse { throw ServerFailure.http(500, nil) }
}
