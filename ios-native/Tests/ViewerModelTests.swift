import Foundation
import IlyichPlatform
import SwiftUI
import XCTest
@testable import Ilyich

/// N3: the viewer's model and its asset windows. The photos the viewer pages through are the
/// source's window around the photo on screen, never around the one it opened on: a reload of
/// the source keeps that photo, and a swipe or a scrub on its way finishes over the photos it
/// started on. Deleting goes through the account's mutations and removes the photo on screen.
@MainActor final class ViewerModelTests: XCTestCase {
    private static let features = #"{"passwordLogin":true,"oauth":false,"smartSearch":true,"ocr":true,"facialRecognition":true,"map":true,"trash":true,"sidecar":true,"realtimeTranscoding":true}"#
    private static let march = "2026-03-01T00:00:00Z", february = "2026-02-01T00:00:00Z"

    // MARK: - Deleting

    /// The owner opens a photo, swipes to the next and deletes it: the photo swiped to goes to
    /// Trash, not the one opened, the viewer closes as it always has, and the feed loses that photo.
    func testDeletingTheSwipedToPhotoRemovesThatPhoto() async throws {
        let library = ViewerLibrary([try photo("a", "2026-03-20"), try photo("b", "2026-03-15"), try photo("c", "2026-03-10")])
        let store = try await loadedStore(library, months: [Self.march])
        defer { store.stop() }
        let server = makeStubServer()
        server.route("GET", "server/features", .json(Self.features))
        server.route("DELETE", "assets", .empty(204))
        let (api, mutations) = try makeAccount(server)
        follow(mutations, in: store)
        var closed = false
        let model = ViewerModel(api: api, route: route(store, "a"), window: .feed(store), settleDelay: .zero)
        model.start(mutations: mutations, close: { closed = true })
        XCTAssertEqual(model.assets.map(\.id), ["a", "b", "c"])

        swipe(model, to: "b")
        XCTAssertEqual(model.current.id, "b")
        await model.loadFeatures()
        model.requestDeletion()
        try await until("The viewer did not ask before deleting.") { model.confirmation != nil }
        XCTAssertEqual(model.confirmation, .delete(model.current, permanently: false), "It asks about the photo on screen.")
        // The dialog goes as its button runs.
        model.confirmation = nil
        model.confirmDeletion()
        try await until("The viewer did not close.") { closed }

        let body = try XCTUnwrap(server.requests("DELETE", "assets").first?.body)
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(sent["ids"] as? [String], ["b"], "The photo swiped to goes, not the one opened.")
        XCTAssertEqual(sent["force"] as? Bool, false, "To Trash.")
        try await until("The feed still shows the photo.") { store.availableAssets(around: "a").map(\.id) == ["a", "c"] }
    }

    // MARK: - The window

    /// A sync reloads the feed while the viewer is up: the photo on screen stays on screen, though a
    /// photo arrives before it, and the pages move with the photos. While a swipe is on its way the
    /// photos it moves over stay as they were, and the new ones show once the pages rest. A photo
    /// deleted on the web stays put on screen until reading it again closes the viewer.
    func testAFeedReloadKeepsTheCurrentPhoto() async throws {
        let library = ViewerLibrary([try photo("m1", "2026-03-20"), try photo("m2", "2026-03-15"), try photo("m3", "2026-03-10"),
                                     try photo("f1", "2026-02-20")])
        let store = try await loadedStore(library, months: [Self.march, Self.february])
        defer { store.stop() }
        let (api, mutations) = try makeAccount(makeStubServer())
        let model = ViewerModel(api: api, route: route(store, "m1"), window: .feed(store), settleDelay: .zero)
        model.start(mutations: mutations, close: {})
        swipe(model, to: "m2")
        swipe(model, to: "m3")
        XCTAssertEqual(model.assets.map(\.id), ["m1", "m2", "m3", "f1"])

        model.setPagerMoving(true)
        await library.set(try photo("m0", "2026-03-25"))
        await store.reload(preservingPosition: true)
        try await until("March was not read again.") { store.loaded[Self.march]?.first?.id == "m0" }
        XCTAssertEqual(model.assets.map(\.id), ["m1", "m2", "m3", "f1"], "Nothing moves under a swipe on its way.")
        model.setPagerMoving(false)
        XCTAssertEqual(model.assets.map(\.id), ["m0", "m1", "m2", "m3", "f1"], "At rest the viewer takes the photo that arrived.")
        XCTAssertEqual(model.selectedID, "m3")
        XCTAssertEqual(model.current.id, "m3", "The photo on screen stays, though another came before it.")
        XCTAssertEqual(model.index, 3)
        XCTAssertEqual(model.pagePosition.viewID(type: String.self), "m3", "The pages moved with the photos.")
        XCTAssertEqual(model.windowShifts, 1, "The strip is laid out afresh around the photo, now one further along.")

        await library.delete("m3")
        await library.set(try photo("f2", "2026-02-10"))
        await store.reload(preservingPosition: true)
        try await until("The viewer did not take the reload at rest.") { model.assets.contains { $0.id == "f2" } }
        XCTAssertEqual(model.assets.map(\.id), ["m0", "m1", "m2", "m3", "f1", "f2"], "The photo gone from the feed stays where it was on screen.")
        XCTAssertEqual(model.current.id, "m3")
        XCTAssertEqual(model.pagePosition.viewID(type: String.self), "m3")
        XCTAssertEqual(model.windowShifts, 1, "A photo added after it leaves the strip where it was.")
    }

    /// The window is asked about the photo on screen, not the one the viewer opened on: once a
    /// swipe has moved on to the next month, the viewer pages through that month's neighbors.
    func testTheWindowFollowsThePhotoOnScreen() async throws {
        let library = ViewerLibrary([try photo("may", "2026-05-10"), try photo("april", "2026-04-10"), try photo("m1", "2026-03-20"),
                                     try photo("m2", "2026-03-10"), try photo("february", "2026-02-10"), try photo("january", "2026-01-10")])
        let store = try await loadedStore(library, months: ["2026-05-01T00:00:00Z", "2026-04-01T00:00:00Z", Self.march, Self.february,
                                                            "2026-01-01T00:00:00Z"])
        defer { store.stop() }
        let (api, mutations) = try makeAccount(makeStubServer())
        let model = ViewerModel(api: api, route: route(store, "april"), window: .feed(store), settleDelay: .zero)
        model.start(mutations: mutations, close: {})
        XCTAssertEqual(model.assets.map(\.id), ["may", "april", "m1", "m2"], "The photo's month and the months beside it.")

        swipe(model, to: "m1")
        XCTAssertEqual(model.assets.map(\.id), ["april", "m1", "m2", "february"], "The months beside the photo on screen.")
        XCTAssertEqual(model.index, 1)
        XCTAssertEqual(model.pagePosition.viewID(type: String.self), "m1")

        // A swipe that passes two photos before resting moves the window once, at rest.
        model.setPagerMoving(true)
        model.select("m2")
        model.select("february")
        XCTAssertEqual(model.assets.map(\.id), ["april", "m1", "m2", "february"])
        model.setPagerMoving(false)
        XCTAssertEqual(model.assets.map(\.id), ["m1", "m2", "february", "january"])
        XCTAssertEqual(model.current.id, "february")

        // The strip scrubbed back holds the window as the pages do.
        model.setStripScrubbing(true)
        model.jump(to: "m1")
        XCTAssertNil(model.settledID, "Only the photo a scrub stops on is read again.")
        XCTAssertEqual(model.assets.map(\.id), ["m1", "m2", "february", "january"])
        model.setStripScrubbing(false)
        XCTAssertEqual(model.assets.map(\.id), ["april", "m1", "m2", "february"])
        XCTAssertEqual(model.settledID, "m1")
    }

    /// The window moves on once the photos have rested a moment, the time the strip takes to follow
    /// the photo, so the strip laid out afresh looks as the old one did; a swipe begun meanwhile
    /// holds it until the photos rest again.
    func testTheWindowMovesOnOnceThePhotosHaveRested() async throws {
        let library = ViewerLibrary([try photo("may", "2026-05-10"), try photo("april", "2026-04-10"), try photo("m1", "2026-03-20"),
                                     try photo("february", "2026-02-10")])
        let store = try await loadedStore(library, months: ["2026-05-01T00:00:00Z", "2026-04-01T00:00:00Z", Self.march, Self.february])
        defer { store.stop() }
        let (api, mutations) = try makeAccount(makeStubServer())
        let model = ViewerModel(api: api, route: route(store, "april"), window: .feed(store), settleDelay: .milliseconds(150))
        model.start(mutations: mutations, close: {})
        swipe(model, to: "m1")
        XCTAssertEqual(model.assets.map(\.id), ["may", "april", "m1"], "Not while the strip follows the photo.")
        model.setPagerMoving(true)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.assets.map(\.id), ["may", "april", "m1"], "Nor while the photos move again.")
        model.setPagerMoving(false)
        try await until("The window did not move on once the photos rested.") { model.assets.map(\.id) == ["april", "m1", "february"] }
        XCTAssertEqual(model.windowShifts, 1)
    }

    /// A photo archived from the viewer leaves the feed, but the viewer stays on it, its new
    /// record on screen. Once a swipe has moved on, it is gone from the photos paged through too,
    /// as from the feed.
    func testArchivingKeepsThePhotoOnScreenUntilTheViewerMovesOn() async throws {
        let library = ViewerLibrary([try photo("a", "2026-03-20"), try photo("b", "2026-03-15"), try photo("c", "2026-03-10")])
        let store = try await loadedStore(library, months: [Self.march])
        defer { store.stop() }
        let server = makeStubServer()
        server.route("PUT", "assets", .empty(204))
        let (api, mutations) = try makeAccount(server)
        follow(mutations, in: store)
        let model = ViewerModel(api: api, route: route(store, "a"), window: .feed(store), settleDelay: .zero)
        model.start(mutations: mutations, close: { XCTFail("Archiving keeps the viewer open.") })
        swipe(model, to: "b")

        model.changeVisibility(.archive)
        try await until("The feed did not lose the photo.") { store.availableAssets(around: "a").map(\.id) == ["a", "c"] }
        try await until("The viewer did not take the archived record.") { model.current.visibility == .archive }
        XCTAssertEqual(model.assets.map(\.id), ["a", "b", "c"], "The archived photo stays where it was on screen.")
        XCTAssertEqual(model.current.id, "b")

        swipe(model, to: "c")
        XCTAssertEqual(model.assets.map(\.id), ["a", "c"], "Once left, it is paged through no more.")
        XCTAssertEqual(model.current.id, "c")
        XCTAssertEqual(model.pagePosition.viewID(type: String.self), "c")
    }

    /// The window of a screen's own list (an Info collection here) is the list as it stands: the
    /// viewer pages through photos the screen finds after it opened, and a photo the viewer finds
    /// gone leaves the list, which hears of the loss, and the viewer closes.
    func testACollectionsViewerPagesThroughItsListAsItChanges() async throws {
        let list = AssetList([try photo("a", "2026-03-20"), try photo("b", "2026-03-15")], keeps: CollectionMembership.searched)
        let server = makeStubServer()
        server.route("GET", "assets/b", .immichError(404, message: "Not found"))
        let (api, mutations) = try makeAccount(server)
        var closed = false
        let model = ViewerModel(api: api, route: ViewerRoute(asset: list.assets[0], source: .collection("maya"), albumContext: nil),
                                window: .collection(list), settleDelay: .zero)
        model.start(mutations: mutations, close: { closed = true })
        XCTAssertEqual(model.assets.map(\.id), ["a", "b"])

        list.assets += [try photo("c", "2026-03-10")]
        try await until("The viewer did not take the photo the list found.") { model.assets.map(\.id) == ["a", "b", "c"] }

        swipe(model, to: "b")
        await model.refreshCurrentAsset()
        XCTAssertTrue(closed, "The viewer closes on a photo gone from the server.")
        XCTAssertEqual(list.assets.map(\.id), ["a", "c"], "The photo that left is the one swiped to.")
        XCTAssertEqual(list.losses, 1, "The screen hears of the loss.")
    }

    // MARK: - Fresher records

    /// Reading the photo on screen again writes its details into the viewer only. The feed hears
    /// of a record only when it changes what the feed shows: the media's revision, the visibility,
    /// the Trash or the favorite. A detailed record differs from a timeline row in much else, and
    /// the feed would lay the month out again at every photo opened.
    func testARefreshTellsTheFeedOnlyWhatChangesWhatItShows() async throws {
        let library = ViewerLibrary([try photo("a", "2026-03-20"), try photo("b", "2026-03-10")])
        let store = try await loadedStore(library, months: [Self.march])
        defer { store.stop() }
        let server = makeStubServer()
        var detailed = try photo("a", "2026-03-20")
        detailed.exifInfo = ExifInfo(exifImageWidth: 600, exifImageHeight: 400, orientation: nil, projectionType: nil, timeZone: nil,
                                     description: "Harbor", city: nil, state: nil, country: nil, latitude: nil, longitude: nil, make: nil,
                                     model: nil, lensModel: nil, fNumber: nil, exposureTime: nil, iso: nil, focalLength: nil, fileSizeInByte: nil, rating: nil)
        detailed.hasKnownEditState = true
        server.route("GET", "assets/a", try record(detailed))
        let (api, mutations) = try makeAccount(server)
        let model = ViewerModel(api: api, route: route(store, "a"), window: .feed(store), settleDelay: .zero)
        model.start(mutations: mutations, close: {})
        let revision = store.revision

        await model.refreshCurrentAsset()
        XCTAssertEqual(model.current.exifInfo?.description, "Harbor", "The viewer shows the details.")
        XCTAssertNil(store.loaded[Self.march]?.first?.exifInfo, "The feed keeps its row.")
        XCTAssertEqual(store.revision, revision, "Nothing in the feed changed.")

        detailed.isFavorite = true
        server.route("GET", "assets/a", try record(detailed))
        model.libraryChanged(accessChanged: false)
        await model.refreshCurrentAsset()
        XCTAssertTrue(model.current.isFavorite)
        XCTAssertEqual(store.loaded[Self.march]?.first?.isFavorite, true, "A favorite made elsewhere reaches the feed.")

        detailed.mediaRevision = "r2"
        server.route("GET", "assets/a", try record(detailed))
        model.libraryChanged(accessChanged: false)
        await model.refreshCurrentAsset()
        XCTAssertEqual(store.loaded[Self.march]?.first?.mediaRevision, "r2", "So does an edit made elsewhere, for the thumbnail.")
    }

    /// Whether a record changes what a list shows of a photo.
    func testWhatChangesAListing() throws {
        let row = try photo("a", "2026-03-20")
        var detailed = row
        detailed.people = [Person(id: "maya", name: "Maya", birthDate: nil, thumbnailPath: nil, updatedAt: nil, isHidden: nil, isFavorite: nil)]
        detailed.hasKnownEditState = true
        detailed.width = 4032
        XCTAssertFalse(detailed.changesListing(from: row), "Details no list shows.")
        var favorite = row; favorite.isFavorite = true
        var archived = row; archived.visibility = .archive
        var trashed = row; trashed.isTrashed = true
        var edited = row; edited.mediaRevision = "r2"
        for changed in [favorite, archived, trashed, edited] { XCTAssertTrue(changed.changesListing(from: row)) }
        // A timeline row may carry only a thumbhash; the revision is compared on what both carry.
        var hashed = row; hashed.mediaRevision = nil; hashed.thumbhash = "hash"
        var hashedDetail = row; hashedDetail.thumbhash = "hash"
        XCTAssertFalse(hashedDetail.changesListing(from: hashed))
        hashedDetail.thumbhash = "other"
        XCTAssertTrue(hashedDetail.changesListing(from: hashed))
    }

    /// The window a source offers, with the photo on screen kept in it.
    func testTheMergedWindowKeepsThePhotoOnScreen() throws {
        let shown = try ["a", "b", "c", "d"].map { try photo($0, "2026-03-20") }
        let offered = try ["a", "c", "d", "e"].map { try photo($0, "2026-03-20") }
        func ids(_ assets: [Asset]) -> [String] { assets.map(\.id) }
        XCTAssertEqual(ids(AssetWindow.merged(shown: shown, offered: offered, selected: "c")), ["a", "c", "d", "e"], "The source's window holds it.")
        XCTAssertEqual(ids(AssetWindow.merged(shown: shown, offered: offered, selected: "b")), ["a", "b", "c", "d", "e"], "Kept after the photo before it.")
        XCTAssertEqual(ids(AssetWindow.merged(shown: shown, offered: Array(offered.dropFirst()), selected: "b")), ["b", "c", "d", "e"],
                       "Or before the photo after it.")
        let elsewhere = try ["x", "y"].map { try photo($0, "2026-01-20") }
        XCTAssertEqual(ids(AssetWindow.merged(shown: shown, offered: elsewhere, selected: "b")), ["a", "b", "c", "d"],
                       "A window with none of the photos shown leaves the window as it was.")
        XCTAssertEqual(ids(AssetWindow.merged(shown: shown, offered: [], selected: "b")), ["a", "b", "c", "d"])
        XCTAssertEqual(ids(AssetWindow.merged(shown: shown, offered: offered + [offered[1]], selected: "c")), ["a", "c", "d", "e"],
                       "A photo listed twice shows once.")
    }

    // MARK: - Places

    /// Exploring a place from the library's viewer is an intent: from its details, the sheet goes
    /// first, then the viewer, and then the Earth rises. Any other viewer shows the place itself.
    func testExploringAPlaceIsAnIntentForTheLibrarysViewer() throws {
        let navigator = LibraryNavigator()
        var performed: [NavigationIntent] = []
        navigator.perform = { performed.append($0) }
        let asset = try photo("a", "2026-03-20")
        navigator.present(.viewer(ViewerRoute(asset: asset, source: .feed, albumContext: nil)))
        let (api, _) = try makeAccount(makeStubServer())
        let model = ViewerModel(api: api, route: ViewerRoute(asset: asset, source: .feed, albumContext: nil), window: .single(asset),
                                navigator: navigator)
        XCTAssertTrue(model.exploresOnTheEarth)
        let focus = PlaceFocus(latitude: 52.37, longitude: 4.9, assetID: "a")

        model.sheet = .info
        model.exploreLocation(focus)
        XCTAssertNil(model.sheet, "The details close first.")
        XCTAssertNotNil(navigator.shown(at: 0, style: .zoom), "The viewer waits for them.")
        model.sheetDidDismiss()
        XCTAssertNil(navigator.shown(at: 0, style: .zoom), "Then the viewer closes.")
        XCTAssertEqual(performed, [])
        navigator.layerDidDismiss(level: 0)
        XCTAssertEqual(performed, [.exploreLocation(focus)], "And the Earth rises, turned to the place.")
        model.sheetDidDismiss()
        XCTAssertEqual(performed, [.exploreLocation(focus)], "Once.")

        let nested = ViewerModel(api: api, route: ViewerRoute(asset: asset, source: .collection("maya"), albumContext: nil), window: .single(asset))
        XCTAssertFalse(nested.exploresOnTheEarth)
        nested.exploreLocation(focus)
        XCTAssertEqual(nested.sheet?.id, ViewerSheet.location(focus).id, "A viewer over another screen shows the place over itself.")
    }

    // MARK: - Support

    private func photo(_ id: String, _ day: String) throws -> Asset {
        Asset(id: id, originalFileName: id + ".jpg", ownerId: "me", localDateTime: try XCTUnwrap(APIDate.parse(day + "T12:00:00Z")),
              mediaRevision: "r1")
    }

    private func route(_ store: LibraryFeedStore, _ id: String) -> ViewerRoute {
        ViewerRoute(asset: store.availableAssets(around: id).first { $0.id == id } ?? Asset(id: id), source: .feed, albumContext: nil)
    }

    /// The feed with `months` loaded.
    private func loadedStore(_ library: ViewerLibrary, months: [String]) async throws -> LibraryFeedStore {
        let store = LibraryFeedStore(source: library)
        await store.reload()
        for section in store.sections.indices { store.requestBucket(section) }
        try await until("The months did not load.") { months.allSatisfy { store.loaded[$0] != nil } }
        return store
    }

    /// An account on `server`: its client, and its mutations with no sync to follow them.
    private func makeAccount(_ server: StubServer) throws -> (api: APIClient, mutations: LibraryMutationService) {
        let api = try APIClient(baseURL: server.baseURL, accessToken: "viewer", userID: "me", sessionConfiguration: server.configuration(),
                                networkConfiguration: NetworkConfiguration())
        let mutations = LibraryMutationService(client: api, pipeline: nil, authorization: nil, refresh: nil)
        addTeardownBlock { await mutations.shutdown(); await api.shutdown() }
        return (api, mutations)
    }

    /// The feed takes the account's mutations, as the library's follower has it do.
    private func follow(_ mutations: LibraryMutationService, in store: LibraryFeedStore) {
        let follower = MutationFollower()
        follower.follow(mutations) { await FeedMutationApplier.apply($0, to: store, refreshes: false) }
        addTeardownBlock { @MainActor in follower.stop() }
    }

    /// A swipe, as the pager reports one: the pages move, pass to the photo, and come to rest.
    private func swipe(_ model: ViewerModel, to id: String) {
        model.setPagerMoving(true)
        model.select(id)
        model.setPagerMoving(false)
    }

    /// The server's answer with a photo's detailed record.
    private func record(_ asset: Asset) throws -> StubServer.Response {
        StubServer.Response(status: 200, headers: ["Content-Type": "application/json"], body: try APIJSON.encoder().encode(asset))
    }

    private func until(_ message: String, within timeout: Duration = .seconds(5), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(message)
        throw CancellationError()
    }
}

/// A library whose photos change under the feed: timeline photos by month, newest first.
private actor ViewerLibrary: FakeFeedSource {
    nonisolated let cacheScope = "test-viewer-model-" + UUID().uuidString
    nonisolated var userID: String? { "me" }
    private var photos: [String: Asset] = [:]

    init(_ photos: [Asset]) { for photo in photos { self.photos[photo.id] = photo } }

    func set(_ asset: Asset) { photos[asset.id] = asset }
    func delete(_ id: String) { photos[id] = nil }

    func monthList(_ query: LibraryQuery) async throws -> [TimeBucket] {
        var counts: [String: Int] = [:]
        for asset in photos.values where belongs(asset, to: query) { counts[Self.bucket(of: asset), default: 0] += 1 }
        return counts.keys.sorted(by: >).map { TimeBucket(timeBucket: $0, count: counts[$0] ?? 0) }
    }

    func month(_ bucket: String, of query: LibraryQuery) async throws -> [Asset] {
        photos.values.filter { belongs($0, to: query) && Self.bucket(of: $0) == bucket }.sorted { a, b in
            let left = a.localDateTime ?? .distantPast, right = b.localDateTime ?? .distantPast
            return left == right ? a.id < b.id : left > right
        }
    }

    func search(_ query: SearchQuery) async throws -> SearchResponse { throw ServerFailure.http(500, nil) }
    func metadataSearch(_ query: MetadataQuery) async throws -> SearchResponse { throw ServerFailure.http(500, nil) }

    /// What the server keeps in a feed: its visibility and its trash.
    private func belongs(_ asset: Asset, to query: LibraryQuery) -> Bool {
        switch asset.visibility {
        case .timeline: guard query.visibility.contains(.timeline) else { return false }
        case .archive: guard query.visibility.contains(.archive) else { return false }
        case .hidden, .locked: return false
        }
        return asset.isTrashed == (query.trash == .trashed)
    }

    private static func bucket(of asset: Asset) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month], from: asset.localDateTime ?? .distantPast)
        return String(format: "%04d-%02d-01T00:00:00Z", parts.year ?? 1970, parts.month ?? 1)
    }
}
