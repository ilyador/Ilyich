import CoreGraphics
import Foundation
import UIKit
import XCTest
@testable import Ilyich

/// What scrubbing the time rail leans on: sketches decoded off the main thread in the format Core
/// Animation draws, day groups worked out without the calendar, months loaded one at a time as
/// they arrive, months found through their own index, and a month queue that serves the month a
/// scrub lands on before the ones it passed.
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
        // A grid moving slowly decodes in place.
        let now = try XCTUnwrap(sketches.decodeNow(Self.hashes[2]))
        XCTAssertTrue(sketches.cached(Self.hashes[2]) === now)
        XCTAssertNil(sketches.decodeNow("not base64"))

        sketches.prefetch([Self.hashes[1], "", Self.hashes[1]])
        let deadline = ContinuousClock.now + .seconds(5)
        while sketches.cached(Self.hashes[1]) == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(sketches.cached(Self.hashes[1]), "A photo about to scroll in has its sketch ready.")
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
        let months = (0..<30).map { String(format: "%04d-06-01T00:00:00Z", 2000 + $0) }
        // Dropped loads end as a dropped URLSession request does.
        let api = MonthLibrary(months: Dictionary(uniqueKeysWithValues: months.map { ($0, [Asset(id: "photo-\($0)")]) }),
                               delay: .milliseconds(500), cancelled: URLError(.cancelled))
        let store = LibraryStore(api: api)
        defer { store.stop() }
        addTeardownBlock { await TimelineCache.shared.removeAll(scope: api.cacheScope) }
        await store.reload()
        // The rail sweeps from the newest month to the 25th, a frame or so at each.
        for section in 0...24 {
            store.visibleSection(section, visible: [section])
            await Task.yield()
        }
        let landed = store.buckets[24].id
        let started = ContinuousClock.now
        try await until("The month the scrub stopped on never loaded.") { store.loaded[landed] != nil }
        let waited = ContinuousClock.now - started
        let passed = store.buckets[0...21].map(\.id).filter { store.loaded[$0] != nil }
        XCTAssertEqual(passed, [], "Months the scrub left behind were dropped, not loaded.")
        XCTAssertEqual(store.bucketErrors, [:], "A dropped month is not a month that failed.")
        XCTAssertLessThan(waited, .milliseconds(900), "It waited for its own load, not for the months passed.")
        let concurrent = await api.maximumConcurrent
        XCTAssertLessThanOrEqual(concurrent, 3)
        print("SCRUB QUEUE landed month loaded \(waited.formatted(.units(allowed: [.milliseconds]))) after the scrub stopped (one load takes 500 ms)")
    }

    // MARK: - Helpers

    private func until(_ message: String, within timeout: Duration = .seconds(5), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail(message)
    }
}

/// Month loads through the local index: until its index is built a month is found by reading
/// every photo; afterwards through the index, with the same photos in the same order.
final class MonthIndexTests: XCTestCase {
    func testMonthsAreFoundThroughTheirIndexOnceBuiltWithTheSamePhotos() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EntityStore(scope: "server|month-index", userID: "alice", directory: root)
        let epoch = await store.epoch()
        _ = try await store.prepare(sessionFingerprint: "session")
        // 24,000 photos over 240 months, as in the UI test library, each with its EXIF, a few of
        // them favorites, archived, a partner's or added in another month than taken.
        let decoder = JSONDecoder()
        for batch in stride(from: 0, to: 24_000, by: 2_000) {
            var events: [EntitySyncEvent] = []
            for index in batch..<(batch + 2_000) {
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
        let clock = ContinuousClock()
        let month = "2015-06-01T00:00:00Z"
        let filters = [TimelineFilter(), TimelineFilter(isFavorite: true), TimelineFilter(visibility: .archive),
                       TimelineFilter(withPartners: true), TimelineFilter(orderBy: "createdAt")]

        // Before the index: every photo is read.
        var before: [[String]] = []
        var unindexed = Duration.zero
        for filter in filters {
            let plan = try await store.timeBucketPlan(month, filter: filter)
            XCTAssertFalse(plan.contains { $0.contains("asset_month") }, "\(filter): \(plan)")
            unindexed += try await clock.measure { before.append(try await store.timeBucket(month, filter: filter).map(\.id)) }
        }
        let build = await clock.measure {
            await store.buildMonthIndex(for: TimelineFilter())
            await store.buildMonthIndex(for: TimelineFilter(orderBy: "createdAt"))
        }

        var after: [[String]] = []
        var indexed = Duration.zero
        for filter in filters {
            let plan = try await store.timeBucketPlan(month, filter: filter)
            let index = filter.orderBy == "createdAt" ? "asset_month_createdAt" : "asset_month_localDateTime"
            XCTAssertTrue(plan.contains { $0.contains("USING INDEX \(index)") }, "\(filter): \(plan)")
            indexed += try await clock.measure { after.append(try await store.timeBucket(month, filter: filter).map(\.id)) }
        }
        XCTAssertEqual(after, before, "The index finds the same photos in the same order.")
        XCTAssertEqual(before[0].count, (11_300..<11_400).count { $0 % 50 != 0 && $0 % 40 != 0 }, "Archived and Bob's photos stay out.")
        XCTAssertTrue(before[4].allSatisfy { Int($0.dropFirst(6))! / 100 == 112 }, "Added in June 2015, taken the month before.")
        let months = try await store.timeBuckets()
        XCTAssertEqual(months.count, 240)
        print("MONTH INDEX 24,000 photos: \(filters.count) month loads took \(unindexed.formatted(.units(allowed: [.milliseconds]))) reading every photo, "
              + "\(indexed.formatted(.units(allowed: [.milliseconds]))) through the index; building both indexes took \(build.formatted(.units(allowed: [.milliseconds])))")
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
        return months[bucket] ?? []
    }
    func search(_ query: SearchQuery) async throws -> SearchResponse { throw APIError.http(500) }
    func metadataSearch(_ query: MetadataQuery) async throws -> SearchResponse { throw APIError.http(500) }
}
