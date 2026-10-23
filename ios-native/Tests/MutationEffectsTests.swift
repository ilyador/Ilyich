import Foundation
import XCTest
@testable import Ilyich

/// N2: what a mutation's result does to the photos each screen shows. Every collection screen
/// with a list of its own applies it in place (the critic's correction): one test per kind,
/// the folder grid's delete, the Locked Folder's Move to Timeline, the Trash's restore and the
/// Duplicates' resolve. The feed applies it through its own commands.
@MainActor final class MutationEffectsTests: XCTestCase {
    private func photo(_ id: String, visibility: AssetVisibility = .timeline, trashed: Bool = false, favorite: Bool = false) -> Asset {
        var asset = Asset(id: id, originalFileName: id + ".jpg", ownerId: "me", isFavorite: favorite)
        asset.visibility = visibility
        asset.isTrashed = trashed
        return asset
    }

    /// The result the service publishes for `request`, made to the photos it names, with their
    /// records as the change left them.
    private func result(_ request: MutationRequest, on records: [Asset], fresh: [Asset]? = nil, failed: [String: String] = [:]) -> MutationResult {
        let succeeded = request.assetIDs.isEmpty ? records.map(\.id) : request.assetIDs.filter { failed[$0] == nil }
        let records = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let changed = fresh ?? succeeded.compactMap { records[$0].flatMap(request.applied) }
        return MutationResult(operation: OperationID(), request: request, succeeded: succeeded, failed: failed,
                              fresh: Dictionary(uniqueKeysWithValues: changed.map { ($0.id, $0) }), followUp: nil)
    }

    // MARK: - Collection screens

    func testFolderGridDeleteRemovesThePhoto() {
        let folder = [photo("a"), photo("b"), photo("c")]
        let trashed = result(.trash(["b"]), on: [photo("b")])
        XCTAssertEqual(trashed.applied(to: folder, keeping: CollectionMembership.folder).map(\.id), ["a", "c"])

        let deleted = result(.deletePermanently(["c"]), on: [photo("c")])
        XCTAssertEqual(deleted.applied(to: folder, keeping: CollectionMembership.folder).map(\.id), ["a", "b"])

        // An archived photo leaves the folder, as the server's folder view holds timeline photos.
        let archived = result(.visibility(["a"], .archive), on: [photo("a")])
        XCTAssertEqual(archived.applied(to: folder, keeping: CollectionMembership.folder).map(\.id), ["b", "c"])

        let favorited = result(.favorite(["a"], true), on: [photo("a")])
        let shown = favorited.applied(to: folder, keeping: CollectionMembership.folder)
        XCTAssertEqual(shown.map(\.id), ["a", "b", "c"], "A favorite stays, in its place.")
        XCTAssertEqual(shown.map(\.isFavorite), [true, false, false])
    }

    func testLockedFolderGridMoveToTimelineRemovesThePhoto() {
        let folder = [photo("a", visibility: .locked), photo("b", visibility: .locked)]
        let moved = result(.visibility(["a"], .timeline), on: [folder[0]])
        XCTAssertEqual(moved.applied(to: folder, keeping: CollectionMembership.lockedFolder).map(\.id), ["b"])

        let trashed = result(.trash(["b"]), on: [folder[1]])
        XCTAssertEqual(trashed.applied(to: folder, keeping: CollectionMembership.lockedFolder).map(\.id), ["a"])

        // A change ending after the folder relocked finds nothing to show.
        XCTAssertEqual(moved.applied(to: [], keeping: CollectionMembership.lockedFolder), [])
    }

    func testTrashRestoreRemovesThePhotoFromTrash() {
        let trash = [photo("a", trashed: true), photo("b", trashed: true), photo("c", trashed: true)]
        let restored = result(.restore(["a", "c"]), on: [trash[0], trash[2]])
        XCTAssertEqual(restored.applied(to: trash, keeping: CollectionMembership.trash).map(\.id), ["b"])

        let deleted = result(.deletePermanently(["b"]), on: [trash[1]])
        XCTAssertEqual(deleted.applied(to: trash, keeping: CollectionMembership.trash).map(\.id), ["a", "c"])

        // A photo put in Trash from another screen isn't added here; the Trash's own read finds it.
        let elsewhere = result(.trash(["d"]), on: [photo("d")])
        XCTAssertEqual(elsewhere.applied(to: trash, keeping: CollectionMembership.trash).map(\.id), ["a", "b", "c"])
    }

    func testDuplicatesResolveRemovesTheGroup() {
        let groups = [DuplicateGroup(duplicateId: "g1", assets: [photo("a"), photo("b")], suggestedKeepAssetIds: ["a"]),
                      DuplicateGroup(duplicateId: "g2", assets: [photo("c"), photo("d"), photo("e")], suggestedKeepAssetIds: ["c"])]
        let resolved = result(.resolveDuplicate(group: "g1", keep: ["a"], trash: ["b"]), on: groups[0].assets, fresh: [photo("b", trashed: true)])
        XCTAssertEqual(DuplicateGroups.applying(resolved, to: groups).map(\.id), ["g2"])

        let dismissed = MutationResult(operation: OperationID(), request: .dismissDuplicate(group: "g2"), succeeded: [], failed: [:], fresh: [:], followUp: nil)
        XCTAssertEqual(DuplicateGroups.applying(dismissed, to: groups).map(\.id), ["g1"])

        // A photo put in Trash from its viewer leaves its group; a group left with one photo goes.
        let trashed = result(.trash(["d", "a"]), on: [photo("d"), photo("a")])
        let left = DuplicateGroups.applying(trashed, to: groups)
        XCTAssertEqual(left.map(\.id), ["g2"])
        XCTAssertEqual(left.first?.assets.map(\.id), ["c", "e"])
        XCTAssertEqual(left.first?.suggestedKeepAssetIds, ["c"])
    }

    /// The viewer's own list, and an Info collection's, take the record a change left; a record
    /// the change has no server copy of is the screen's own, changed as the server changed it.
    func testARecordTheServerDidNotReturnIsTheScreensOwnChanged() {
        var detailed = photo("a")
        detailed.exifInfo = ExifInfo(exifImageWidth: 600, exifImageHeight: 400, orientation: nil, projectionType: nil, timeZone: nil,
                                     description: "Harbor", city: nil, state: nil, country: nil, latitude: nil, longitude: nil, make: nil,
                                     model: nil, lensModel: nil, fNumber: nil, exposureTime: nil, iso: nil, focalLength: nil, fileSizeInByte: nil, rating: nil)
        let bulk = MutationResult(operation: OperationID(), request: .favorite(["a"], true), succeeded: ["a"], failed: [:], fresh: [:], followUp: nil)
        let record = bulk.record(for: detailed)
        XCTAssertEqual(record?.isFavorite, true)
        XCTAssertEqual(record?.exifInfo?.description, "Harbor", "The screen's details are kept.")
        XCTAssertEqual(bulk.record(for: photo("b")), photo("b"), "A photo the change didn't name is left alone.")
    }

    // MARK: - The feed

    /// A photo put in Trash leaves every feed of photos out of it; while the feed shows the Trash,
    /// where the photo isn't, its record goes to the feed instead. A restore is the mirror image.
    func testTheFeedTakesOutWhatLeavesTheTrashStateItShows() {
        let trash = result(.trash(["a"]), on: [photo("a")])
        XCTAssertEqual(FeedMutationEffect.of(trash, showingTrash: false), FeedMutationEffect(removed: ["a"]))
        XCTAssertEqual(FeedMutationEffect.of(trash, showingTrash: true).records.map(\.isTrashed), [true])

        let restore = result(.restore(["a"]), on: [photo("a", trashed: true)])
        XCTAssertEqual(FeedMutationEffect.of(restore, showingTrash: true), FeedMutationEffect(removed: ["a"]))
        XCTAssertEqual(FeedMutationEffect.of(restore, showingTrash: false).records.map(\.isTrashed), [false],
                       "Restored from the Trash screen, the photo's record reaches the library under it.")

        for request in [MutationRequest.deletePermanently(["a"]), .visibility(["a"], .locked)] {
            for showingTrash in [false, true] {
                XCTAssertEqual(FeedMutationEffect.of(result(request, on: [photo("a")]), showingTrash: showingTrash), FeedMutationEffect(removed: ["a"]))
            }
        }

        let resolved = result(.resolveDuplicate(group: "g", keep: ["k"], trash: ["t"]), on: [photo("k"), photo("t")], fresh: [photo("t", trashed: true)])
        XCTAssertEqual(FeedMutationEffect.of(resolved, showingTrash: false), FeedMutationEffect(removed: ["t"]), "The kept photo stays as it is.")
    }

    /// Favorites, archives and details show their new records; albums, stacks and faces wait for
    /// the sync's change; a change the server refused changes nothing.
    func testTheFeedShowsNewRecordsAndLeavesTheRestToTheSync() {
        let favorite = result(.favorite(["a", "b"], true), on: [photo("a"), photo("b")])
        XCTAssertEqual(FeedMutationEffect.of(favorite, showingTrash: false).records.map(\.id), ["a", "b"])
        XCTAssertEqual(FeedMutationEffect.of(favorite, showingTrash: false).records.map(\.isFavorite), [true, true])

        let archive = result(.visibility(["a"], .archive), on: [photo("a")])
        XCTAssertEqual(FeedMutationEffect.of(archive, showingTrash: false).records.map(\.visibility), [.archive])

        for request in [MutationRequest.addToAlbum(album: "x", assets: ["a"]), .stack(["a", "b"]), .removeFromStack(stack: "s", assets: ["a"])] {
            XCTAssertTrue(FeedMutationEffect.of(result(request, on: [photo("a"), photo("b")]), showingTrash: false).isEmpty, "\(request)")
        }
        let refused = result(.trash(["a"]), on: [photo("a")], failed: ["a": "no_permission"])
        XCTAssertTrue(FeedMutationEffect.of(refused, showingTrash: false).isEmpty)
    }

    /// The feed applies the result through its commands. It reads its months again itself only
    /// when no sync follows, and never for the follow-up, which reaches it as every pass does.
    func testTheFeedReadsAgainOnlyWhenNoSyncFollows() async {
        let feed = RecordingFeed()
        let trash = result(.trash(["a"]), on: [photo("a")])
        await FeedMutationApplier.apply(.applied(trash), to: feed, refreshes: false)
        XCTAssertEqual(feed.removed, [["a"]])
        XCTAssertEqual(feed.refreshes, 0)

        await FeedMutationApplier.apply(.followedUp(trash), to: feed, refreshes: true)
        XCTAssertEqual(feed.removed, [["a"]], "The follow-up changes nothing more here.")
        XCTAssertEqual(feed.refreshes, 0)

        let favorite = result(.favorite(["b"], true), on: [photo("b")])
        await FeedMutationApplier.apply(.applied(favorite), to: feed, refreshes: true)
        XCTAssertEqual(feed.updated.map(\.id), ["b"])
        XCTAssertEqual(feed.refreshes, 1, "Without an offline library the feed reads its months again.")

        let dismissed = MutationResult(operation: OperationID(), request: .dismissDuplicate(group: "g"), succeeded: [], failed: [:], fresh: [:], followUp: nil)
        await FeedMutationApplier.apply(.applied(dismissed), to: feed, refreshes: true)
        XCTAssertEqual(feed.refreshes, 1, "A change to no photo reads nothing.")
    }

    /// The acceptance's bulk favorite inside a filter: the photos show their new records in place,
    /// with nothing read again and the grid where it was.
    func testABulkFavoriteInsideAFilterUpdatesInPlace() async throws {
        let march = "2026-03-01T00:00:00Z"
        let taken = try XCTUnwrap(APIDate.parse("2026-03-10T12:00:00Z"))
        let photos = ["a", "b", "c"].map { id in
            var asset = Asset(id: id, originalFileName: id + ".jpg", ownerId: "me", localDateTime: taken)
            asset.people = [Self.maya]
            return asset
        }
        let source = FilterLibrary(month: march, photos: photos)
        let store = LibraryStore(source: source)
        defer { store.stop() }
        await store.reload()
        let library = await becomesTrue { store.loaded[march]?.count == 3 }
        XCTAssertTrue(library, "The library loaded.")
        store.setPerson(Self.maya)
        let filtered = await becomesTrue {
            !store.isReplacingFeed && store.feedQuery.predicates.people == ["maya"] && store.loaded[march]?.count == 3
        }
        XCTAssertTrue(filtered, "Maya's photos replaced the library.")
        await store.settleProjections()
        let position = GridPosition(section: march, item: 2, offset: 30, assetID: "c")
        store.position = position
        let reset = store.resetID, reads = await source.reads

        let favorite = result(.favorite(["a", "b"], true), on: store.loaded[march]?.filter { ["a", "b"].contains($0.id) } ?? [])
        await FeedMutationApplier.apply(.applied(favorite), to: store, refreshes: false)

        XCTAssertEqual(store.loaded[march]?.map(\.isFavorite), [true, true, false], "In place, at once.")
        await store.settleProjections()
        XCTAssertEqual(store.sections.map(\.count), [3])
        XCTAssertEqual(store.resetID, reset, "No jump: the grid keeps where it is.")
        XCTAssertEqual(store.position, position)
        try await Task.sleep(for: .milliseconds(100))
        let after = await source.reads
        XCTAssertEqual(after, reads, "Nothing is read again.")
    }

    /// The owner's report of a deleted photo lingering: a photo put in Trash leaves the feed at
    /// once, and a month read again before the server's change reaches the source (an offline
    /// library not synced yet) doesn't bring it back.
    func testAPhotoPutInTrashLeavesAndNoEarlierReadBringsItBack() async throws {
        let march = "2026-03-01T00:00:00Z"
        let taken = try XCTUnwrap(APIDate.parse("2026-03-10T12:00:00Z"))
        let photos = ["a", "b", "c"].map { Asset(id: $0, originalFileName: $0 + ".jpg", ownerId: "me", localDateTime: taken) }
        let source = FilterLibrary(month: march, photos: photos)
        let store = LibraryStore(source: source)
        defer { store.stop() }
        await store.reload()
        let loaded = await becomesTrue { store.loaded[march]?.count == 3 }
        XCTAssertTrue(loaded, "The library loaded.")

        await FeedMutationApplier.apply(.applied(result(.trash(["b"]), on: [photos[1]])), to: store, refreshes: false)
        XCTAssertEqual(store.loaded[march]?.map(\.id), ["a", "c"], "The photo leaves at once.")

        // The source still has it, as an offline library not synced yet would.
        let reads = await source.reads
        await store.reload(preservingPosition: true)
        let reread = await becomesTrue { await source.reads > reads + 1 && store.loaded[march] != nil }
        XCTAssertTrue(reread, "The library was read again.")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.loaded[march]?.map(\.id), ["a", "c"], "A read from before the server's change doesn't bring it back.")
    }

    private static let maya = Person(id: "maya", name: "Maya", birthDate: nil, thumbnailPath: nil, updatedAt: nil, isHidden: nil, isFavorite: nil)
}

/// A feed that records the commands a result sends it.
@MainActor private final class RecordingFeed: MutationFeed {
    var showsTrash = false
    private(set) var updated: [Asset] = []
    private(set) var removed: [Set<String>] = []
    private(set) var refreshes = 0
    func update(_ asset: Asset) { updated.append(asset) }
    func removeLocally(_ ids: Set<String>) { removed.append(ids) }
    func refreshAfterMutation() async { refreshes += 1 }
}

/// One month of photos, all of them a person's: the library and her feed read the same.
private actor FilterLibrary: FakeFeedSource {
    nonisolated let cacheScope = "test-mutation-effects-" + UUID().uuidString
    nonisolated var userID: String? { "me" }
    private let bucket: String
    private let photos: [Asset]
    private(set) var reads = 0

    init(month: String, photos: [Asset]) { bucket = month; self.photos = photos }

    func monthList(_ query: LibraryQuery) async throws -> [TimeBucket] {
        reads += 1
        return [TimeBucket(timeBucket: bucket, count: photos.count)]
    }
    func month(_ bucket: String, of query: LibraryQuery) async throws -> [Asset] {
        reads += 1
        return bucket == self.bucket ? photos : []
    }
    func search(_ body: SearchQuery) async throws -> SearchResponse { throw ServerFailure.http(500, nil) }
    func metadataSearch(_ body: MetadataQuery) async throws -> SearchResponse { throw ServerFailure.http(500, nil) }
}
