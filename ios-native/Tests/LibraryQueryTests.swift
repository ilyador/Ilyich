import XCTest
@testable import Ilyich

final class LibraryQueryTests: XCTestCase {
    private let partner = "3f2e1d0c-9b8a-4f7e-8d6c-5b4a39281706"
    private let album = "d4c3b2a1-0f9e-4d8c-b7a6-958473625140"
    private let person = "7c6b5a49-3827-4165-9f8e-7d6c5b4a3928"
    private let lisbon = PlaceMembership(placeID: "Lisbon", assetIDs: ["a", "b"], markerQuery: "withPartners=false&withSharedAlbums=false")

    private var presets: [LibraryQuery] {
        [.library, .favorites, .archive, .trash, .recentlyTaken, .recentlyAdded, .lightroom, .videos, .motion,
         .partner(partner), .album(album), .album(album, ascending: true), .person(person), .place(lisbon)]
    }

    func testTodaysTimelineFeedsKeepTheirCacheKeys() {
        XCTAssertEqual(LibraryQuery.library.stableKey, "order=desc&orderBy=takenAt&withStacked=true&visibility=timeline")
        XCTAssertEqual(LibraryQuery.library.stableKey, TimelineFilter().cacheKey)
        XCTAssertEqual(LibraryQuery.favorites.stableKey, TimelineFilter(isFavorite: true).cacheKey)
        XCTAssertEqual(LibraryQuery.archive.stableKey, TimelineFilter(visibility: .archive).cacheKey)
        XCTAssertEqual(LibraryQuery.trash.stableKey, TimelineFilter(visibility: nil, isTrashed: true).cacheKey)
        XCTAssertEqual(LibraryQuery.lightroom.stableKey, TimelineFilter(isDeveloped: true).cacheKey)
        var partnerFeed = TimelineFilter(); partnerFeed.userID = partner; partnerFeed.visibility = nil
        XCTAssertEqual(LibraryQuery.partner(partner).stableKey, partnerFeed.cacheKey)
        XCTAssertEqual(LibraryQuery.album(album).stableKey, TimelineFilter(albumID: album).cacheKey)
        var oldestFirst = TimelineFilter(albumID: album); oldestFirst.order = "asc"
        XCTAssertEqual(LibraryQuery.album(album, ascending: true).stableKey, oldestFirst.cacheKey)
        XCTAssertEqual(LibraryQuery.person(person).stableKey, TimelineFilter(personID: person).cacheKey)
        // Own-photo feeds name the user "me"; otherwise they are written as TimelineFilter wrote them.
        var recentlyTaken = TimelineFilter(); recentlyTaken.userID = "me"; recentlyTaken.isTrashed = false
        XCTAssertEqual(LibraryQuery.recentlyTaken.stableKey, recentlyTaken.cacheKey)
        var recentlyAdded = TimelineFilter(); recentlyAdded.userID = "me"; recentlyAdded.visibility = nil; recentlyAdded.isTrashed = false
        recentlyAdded.orderBy = "createdAt"
        XCTAssertEqual(LibraryQuery.recentlyAdded.stableKey, recentlyAdded.cacheKey)
        // Every preset names its own feed.
        XCTAssertEqual(Set(presets.map(\.stableKey)).count, presets.count)
    }

    func testPresetsDescribeTodaysFeeds() {
        XCTAssertEqual(LibraryQuery.library, LibraryQuery(scope: .library, trash: .active, visibility: .timeline,
                                                          ranking: .chronological(.takenAt, ascending: false), stacks: .primaryOnly))
        XCTAssertEqual(LibraryQuery.trash.trash, .trashed)
        XCTAssertEqual(LibraryQuery.trash.visibility, [.timeline, .archive])
        XCTAssertEqual(LibraryQuery.archive.visibility, .archive)
        XCTAssertEqual(LibraryQuery.recentlyTaken.scope, .mine)
        XCTAssertEqual(LibraryQuery.recentlyAdded.ranking, .chronological(.createdAt, ascending: false))
        XCTAssertEqual(LibraryQuery.recentlyAdded.visibility, [.timeline, .archive])
        XCTAssertEqual(LibraryQuery.lightroom.predicates.developed, true)
        XCTAssertEqual(LibraryQuery.favorites.predicates.favorite, true)
        XCTAssertEqual(LibraryQuery.videos.predicates.kind, .video)
        XCTAssertEqual(LibraryQuery.motion.predicates.motion, true)
        XCTAssertEqual(LibraryQuery.partner(partner).visibility, [.timeline, .archive])
        XCTAssertEqual(LibraryQuery.album(album, ascending: true).ranking, .chronological(.takenAt, ascending: true))
        // Hidden and locked can't be expressed: other visibility bits are dropped.
        XCTAssertEqual(LibraryQuery.Visibility(rawValue: 0xFF), [.timeline, .archive])
        XCTAssertEqual(LibraryQuery.Visibility(rawValue: 4), [])
    }

    func testRefinedKeepsScopeTrashVisibilityStacksAndFilters() {
        for preset in presets {
            for mode in SearchMode.allCases {
                let refined = preset.refined(text: "  beach ", mode: mode, language: "en")
                XCTAssertEqual(refined.scope, preset.scope, "\(preset.stableKey) \(mode)")
                XCTAssertEqual(refined.trash, preset.trash)
                XCTAssertEqual(refined.visibility, preset.visibility)
                XCTAssertEqual(refined.stacks, preset.stacks)
                XCTAssertEqual(refined.predicates.developed, preset.predicates.developed)
                XCTAssertEqual(refined.predicates.favorite, preset.predicates.favorite, "Searching inside Favorites stays in Favorites.")
                XCTAssertEqual(refined.predicates.kind, preset.predicates.kind)
                XCTAssertNotEqual(refined.stableKey, preset.stableKey)
                switch mode {
                case .context:
                    XCTAssertEqual(refined.ranking, .relevance(.text("beach", language: "en")))
                    XCTAssertEqual(refined.predicates, preset.predicates)
                case .filename, .description, .ocr:
                    XCTAssertEqual(refined.ranking, preset.ranking, "A field search keeps the feed's order.")
                    let field: LibraryQuery.TextMatch.Field = mode == .filename ? .filename : mode == .description ? .description : .textInPhoto
                    XCTAssertEqual(refined.predicates.text, LibraryQuery.TextMatch(field: field, value: "beach"))
                }
                XCTAssertEqual(preset.refined(text: "   ", mode: mode), preset, "Empty text leaves the feed as it is.")
            }
        }
        // A refinement replaces an earlier one.
        let twice = LibraryQuery.favorites.refined(text: "IMG_", mode: .filename).refined(text: "sunset", mode: .description)
        XCTAssertEqual(twice.predicates.text, LibraryQuery.TextMatch(field: .description, value: "sunset"))
        XCTAssertEqual(LibraryQuery.trash.refined(text: "beach", mode: .context).refined(text: "IMG_", mode: .filename).ranking,
                       LibraryQuery.trash.ranking)
    }

    func testSimilarKeepsScopeTrashVisibilityStacksAndDevelopedOnly() {
        for preset in presets {
            let similar = preset.similar(to: "asset")
            XCTAssertEqual(similar.scope, preset.scope, preset.stableKey)
            XCTAssertEqual(similar.trash, preset.trash)
            XCTAssertEqual(similar.visibility, preset.visibility)
            XCTAssertEqual(similar.stacks, preset.stacks)
            XCTAssertEqual(similar.predicates, LibraryQuery.Predicates(developed: preset.predicates.developed))
            XCTAssertEqual(similar.ranking, .relevance(.similar(to: "asset")))
            XCTAssertTrue(similar.stableKey.contains("&similar=asset"), similar.stableKey)
        }
        XCTAssertEqual(LibraryQuery.library.similar(to: "asset").stableKey, "order=relevance&withStacked=true&visibility=timeline&similar=asset")
    }

    func testPlaceIsKnownByItsMembershipNotItsCount() {
        let reordered = PlaceMembership(placeID: "Lisbon", assetIDs: ["b", "a"], markerQuery: "withPartners=false&withSharedAlbums=false")
        let sameCount = PlaceMembership(placeID: "Lisbon", assetIDs: ["a", "c"], markerQuery: "withPartners=false&withSharedAlbums=false")
        let otherMarkers = PlaceMembership(placeID: "Lisbon", assetIDs: ["a", "b"], markerQuery: "withPartners=true&withSharedAlbums=false")
        XCTAssertEqual(lisbon, reordered)
        XCTAssertEqual(lisbon.hashValue, reordered.hashValue)
        XCTAssertNotEqual(lisbon, sameCount)
        XCTAssertNotEqual(lisbon, otherMarkers)
        XCTAssertNotEqual(LibraryQuery.place(lisbon).stableKey, LibraryQuery.place(sameCount).stableKey)
        XCTAssertEqual(LibraryQuery.place(lisbon).stableKey, TimelineFilter().cacheKey + "&place=Lisbon#" + lisbon.revision)
        // Free text can't pose as another item.
        let tricky = PlaceMembership(placeID: "São Paulo&isFavorite=true", assetIDs: ["a"], markerQuery: "")
        XCTAssertTrue(LibraryQuery.place(tricky).stableKey.contains("&place=S%C3%A3o%20Paulo%26isFavorite%3Dtrue#"))
        XCTAssertTrue(LibraryQuery.library.refined(text: "a&b=c", mode: .context).stableKey.hasSuffix("&query=a%26b%3Dc"))
    }
}
