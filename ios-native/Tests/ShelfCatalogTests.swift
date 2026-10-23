import Foundation
import XCTest
@testable import Ilyich

/// N4: the shelves' rows come from one catalog with typed actions instead of closures. The rows,
/// their IDs, titles, symbols, counts, faces and covers, which one is marked, and what each does,
/// are those the shelves showed before.
@MainActor final class ShelfCatalogTests: XCTestCase {
    private let maya = Person(id: "maya", name: "Maya", birthDate: nil, thumbnailPath: nil, updatedAt: nil, isHidden: false, isFavorite: true)
    private let unnamed = Person(id: "p2", name: "", birthDate: nil, thumbnailPath: nil, updatedAt: nil, isHidden: false, isFavorite: nil)
    private let coast = Album(id: "coast", albumName: "Coast", albumThumbnailAssetId: "cover", assetCount: 1200, shared: false)
    private let harbor = Album(id: "harbor", albumName: "Harbor", albumThumbnailAssetId: nil, assetCount: 12, shared: true)

    func testTheTopLevelOffersWhatTheServerDoes() {
        var catalog = ShelfCatalog(people: [maya, unnamed], albums: [coast, harbor])
        let top = catalog.rows(.root)
        XCTAssertEqual(top.map(\.id), ["people", "places", "albums", "more", "settings"])
        XCTAssertEqual(top.map(\.title), ["People", "Places", "Albums", "More", "Settings"])
        XCTAssertEqual(top.map(\.symbol), ["person.2", "globe.europe.africa", "rectangle.stack", "ellipsis", "gearshape"])
        XCTAssertEqual(top.map(\.detail), [2.formatted(), nil, 2.formatted(), nil, nil])
        XCTAssertEqual(top.map(\.action), [.open(.people), .places, .open(.albums), .open(.more), .open(.settings)])
        XCTAssertTrue(top.allSatisfy { !$0.isSelected && $0.person == nil && $0.assetID == nil })

        catalog.people = []; catalog.albums = []
        XCTAssertEqual(catalog.rows(.root).map(\.detail), [nil, nil, nil, nil, nil], "No count before any are known.")
        catalog.features = features(faces: false, map: false, trash: true)
        XCTAssertEqual(catalog.rows(.root).map(\.id), ["albums", "more", "settings"], "People and Places only where the server offers them.")
        catalog.features = features(faces: true, map: true, trash: true)
        XCTAssertEqual(catalog.rows(.root).map(\.id), ["people", "places", "albums", "more", "settings"])
    }

    func testPeopleAndAlbumsListTheOwnersOrderThenTheirScreens() {
        var catalog = ShelfCatalog(people: [unnamed, maya], albums: [harbor, coast])
        let people = catalog.rows(.people)
        XCTAssertEqual(people.map(\.id), ["person-p2", "person-maya", "all-people"])
        XCTAssertEqual(people.map(\.title), ["Unnamed person", "Maya", "Manage people"])
        XCTAssertEqual(people.map(\.symbol), ["person.crop.circle", "person.crop.circle", "person.2"])
        XCTAssertEqual(people.map(\.person), [unnamed, maya, nil])
        XCTAssertEqual(people.map(\.action), [.show(.person(unnamed)), .show(.person(maya)), .present(.people)])

        let albums = catalog.rows(.albums)
        XCTAssertEqual(albums.map(\.id), ["album-harbor", "album-coast", "new-album", "all-albums"])
        XCTAssertEqual(albums.map(\.title), ["Harbor", "Coast", "New album", "Manage albums"])
        XCTAssertEqual(albums.map(\.symbol), ["rectangle.stack", "rectangle.stack", "plus", "square.grid.2x2"])
        XCTAssertEqual(albums.map(\.detail), [12.formatted(), 1200.formatted(), nil, nil])
        XCTAssertEqual(albums.map(\.assetID), [nil, "cover", nil, nil])
        XCTAssertEqual(albums.map(\.action), [.show(.album(harbor)), .show(.album(coast)), .present(.newAlbum), .present(.albums)])

        XCTAssertEqual(catalog.rows(.people).filter(\.isSelected).map(\.id), [])
        catalog.selection.person = "maya"; catalog.selection.album = "coast"
        XCTAssertEqual(catalog.rows(.people).filter(\.isSelected).map(\.id), ["person-maya"], "The person the feed shows is marked.")
        XCTAssertEqual(catalog.rows(.albums).filter(\.isSelected).map(\.id), ["album-coast"], "And the album.")
    }

    func testMoreListsItsCollectionsThenBrowsingAndSharedFiles() {
        var catalog = ShelfCatalog()
        let more = catalog.rows(.more)
        XCTAssertEqual(more.map(\.id), ["recent-taken", "recent-added", "videos", "motion", "lightroom", "favorites", "archive", "trash", "browse-more"])
        XCTAssertEqual(more.map(\.title), ["Recently taken", "Recently added", "Videos", "Motion", "Lightroom", "Favorites", "Archive", "Trash", "Browse more"])
        XCTAssertEqual(more.map(\.symbol), ["camera", "clock.badge.checkmark", "video", "livephoto", "slider.horizontal.3", "heart", "archivebox", "trash",
                                           "square.grid.2x2"])
        XCTAssertEqual(more.map(\.action), LibraryCollection.more.map { ShelfAction.show($0) } + [ShelfAction.present(.more)])
        XCTAssertFalse(more.contains(where: \.isSelected))

        catalog.sharedFiles = true
        XCTAssertEqual(catalog.rows(.more).last?.id, "shared-files")
        XCTAssertEqual(catalog.rows(.more).last?.action, .present(.sharedFiles))
        catalog.features = features(faces: true, map: true, trash: false)
        XCTAssertFalse(catalog.rows(.more).contains { $0.id == "trash" }, "Trash only where the server keeps one.")
    }

    func testSettingsListEveryScreenThenSignOut() {
        let settings = ShelfCatalog().rows(.settings)
        XCTAssertEqual(settings.map(\.id), ["settings-account", "settings-backup", "settings-readOnly", "settings-appearance", "settings-grid",
                                            "settings-viewer", "settings-network", "settings-notifications", "settings-server",
                                            "settings-diagnostics", "settings-about", "sign-out"])
        XCTAssertEqual(settings.map(\.title), ["Account", "Backup", "Read-only mode", "Appearance", "Grid", "Photo and video viewer", "Network",
                                               "Notifications", "Server", "Diagnostics", "About", "Sign out"])
        XCTAssertEqual(settings.last?.symbol, "rectangle.portrait.and.arrow.right")
        XCTAssertEqual(settings.last?.action, .confirm(.signOut))
        XCTAssertEqual(settings.first?.action, .present(.settings(.account)))
        XCTAssertEqual(settings.dropLast().map(\.action), SettingsRoute.allCases.dropFirst().map { .present(.settings($0)) })
    }

    /// Each of More's collections, shown from the shelves, is the one the shelves then mark, as
    /// the feed has it; and a person or an album the feed already shows stays as it is.
    func testEachCollectionShownIsTheOneMarked() async throws {
        let store = LibraryFeedStore(source: ShelfLibrary())
        defer { store.stop() }
        await store.reload()
        for collection in LibraryCollection.more {
            store.show(collection)
            let marked = ShelfCatalog(selection: store.shelfSelection).rows(.more).filter(\.isSelected).map(\.id)
            XCTAssertEqual(marked, [collection.rowID], "\(collection.title) shown marks only its row.")
            XCTAssertEqual(store.filterTitle, collection.title)
        }
        store.show(.person(maya))
        XCTAssertEqual(store.shelfSelection.person, "maya")
        XCTAssertEqual(store.filterTitle, "Maya")
        store.show(.album(coast))
        XCTAssertEqual(store.shelfSelection.album, "coast")
        XCTAssertNil(store.shelfSelection.person)
        let feed = store.feedQuery
        store.show(.album(coast))
        XCTAssertEqual(store.feedQuery, feed, "The album shown stays as it is.")
        store.clearFilters()
        XCTAssertEqual(store.shelfSelection, ShelfSelection(), "The library marks nothing.")
    }

    private func features(faces: Bool, map: Bool, trash: Bool) -> ServerFeatures {
        ServerFeatures(passwordLogin: true, oauth: false, smartSearch: true, searchVerification: nil, ocr: false, facialRecognition: faces,
                       map: map, trash: trash, sidecar: true, realtimeTranscoding: false)
    }
}

private extension Album {
    init(id: String, albumName: String, albumThumbnailAssetId: String?, assetCount: Int, shared: Bool) {
        self.init(id: id, albumName: albumName, description: nil, albumThumbnailAssetId: albumThumbnailAssetId, assetCount: assetCount,
                  shared: shared, albumUsers: nil, startDate: nil, endDate: nil, updatedAt: nil, order: nil)
    }
}

/// A library with one photo in every feed, which every search finds.
private actor ShelfLibrary: FakeFeedSource {
    nonisolated let cacheScope = "test-shelf-catalog-" + UUID().uuidString

    func monthList(_ query: LibraryQuery) async throws -> [TimeBucket] { [TimeBucket(timeBucket: "2026-03-01T00:00:00Z", count: 1)] }
    func month(_ bucket: String, of query: LibraryQuery) async throws -> [Asset] { [Asset(id: "photo", localDateTime: APIDate.parse("2026-03-10T12:00:00Z"))] }
    func search(_ query: SearchQuery) async throws -> SearchResponse { Self.found }
    func metadataSearch(_ query: MetadataQuery) async throws -> SearchResponse { Self.found }

    private static var found: SearchResponse {
        let assets = [Asset(id: "photo", localDateTime: APIDate.parse("2026-03-10T12:00:00Z"))]
        return SearchResponse(assets: .init(items: assets, count: 1, nextCursor: nil, nextPage: nil), verification: nil)
    }
}
