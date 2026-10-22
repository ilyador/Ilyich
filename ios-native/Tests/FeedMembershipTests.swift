import XCTest
@testable import Ilyich

/// F4: whether a photo's record keeps it in a feed. The record decides visibility, trash,
/// favorite, owner and developed; the feeds it can't decide reconcile their months instead.
final class FeedMembershipTests: XCTestCase {
    private static let me = "alice"

    func testTable() {
        let place = PlaceMembership(placeID: "lisbon", assetIDs: ["photo"], markerQuery: "")
        let rows: [(String, LibraryQuery, Asset, FeedMembership)] = [
            ("library, a photo of mine", .library, photo(), .member),
            ("library, archived", .library, photo(visibility: .archive), .excluded),
            ("library, locked", .library, photo(visibility: .locked), .excluded),
            ("library, hidden", .library, photo(visibility: .hidden), .excluded),
            ("library, in Trash", .library, photo(trashed: true), .excluded),
            ("library, favorited", .library, photo(favorite: true), .member),
            ("library, a partner's photo", .library, photo(owner: "bob"), .reconcile),
            ("library, owner unknown", .library, photo(owner: nil), .reconcile),
            ("favorites, unfavorited", .favorites, photo(), .excluded),
            ("favorites, favorited", .favorites, photo(favorite: true), .member),
            ("favorites, favorited and archived", .favorites, photo(favorite: true, visibility: .archive), .excluded),
            ("archive, unarchived", .archive, photo(), .excluded),
            ("archive, archived", .archive, photo(visibility: .archive), .member),
            ("trash, restored", .trash, photo(), .excluded),
            ("trash, in Trash", .trash, photo(trashed: true), .member),
            ("trash, archived in Trash", .trash, photo(trashed: true, visibility: .archive), .member),
            ("trash, locked", .trash, photo(trashed: true, visibility: .locked), .excluded),
            ("recently taken, mine", .recentlyTaken, photo(), .member),
            ("recently taken, someone else's", .recentlyTaken, photo(owner: "bob"), .excluded),
            ("recently taken, owner unknown", .recentlyTaken, photo(owner: nil), .reconcile),
            ("recently added, archived", .recentlyAdded, photo(visibility: .archive), .member),
            ("Lightroom, developed", .lightroom, photo(developed: true), .member),
            ("Lightroom, no longer developed", .lightroom, photo(), .excluded),
            ("partner, theirs", .partner("bob"), photo(owner: "bob"), .reconcile),
            ("partner, mine", .partner("bob"), photo(), .excluded),
            ("album, in it as far as the record says", .album("coast"), photo(), .reconcile),
            ("album, archived", .album("coast"), photo(visibility: .archive), .excluded),
            ("person, as far as the record says", .person("maya"), photo(), .reconcile),
            ("person, in Trash", .person("maya"), photo(trashed: true), .excluded),
            ("place", .place(place), photo(), .reconcile),
            ("place, locked", .place(place), photo(visibility: .locked), .excluded),
            ("search, matched as far as the record says", LibraryQuery.library.refined(text: "beach", mode: .context), photo(), .reconcile),
            ("search across the archive, archived", Self.searchAcrossArchive, photo(visibility: .archive), .reconcile),
            ("videos: the kind is the source's to say", .videos, photo(), .reconcile),
        ]
        for (name, query, asset, expected) in rows {
            XCTAssertEqual(FeedMembership.of(asset, in: query, userID: Self.me), expected, name)
        }
    }

    /// Without the account's user, nothing says a photo is the account's own.
    func testAnUnknownUserLeavesOwnershipToTheSource() {
        XCTAssertEqual(FeedMembership.of(photo(), in: .library, userID: nil), .reconcile)
        XCTAssertEqual(FeedMembership.of(photo(), in: .recentlyTaken, userID: nil), .reconcile)
        XCTAssertEqual(FeedMembership.of(photo(visibility: .archive), in: .library, userID: nil), .excluded,
                       "What the record decides does not need the user.")
    }

    /// A pending feed replaces the one shown once its first months have loaded or are only on
    /// the phone; a failed month keeps the one shown; a feed with no month is ready at once.
    func testAPendingFeedIsReadyWhenItsFirstMonthsAreLoadedOrOnlyOnThePhone() {
        XCTAssertEqual(FeedSession.readiness([]), .ready)
        XCTAssertEqual(FeedSession.readiness([.loaded, .loaded]), .ready)
        XCTAssertEqual(FeedSession.readiness([.phoneOnly, .loaded]), .ready, "FEED-2: a month only the phone has is ready.")
        XCTAssertEqual(FeedSession.readiness([.phoneOnly]), .ready)
        XCTAssertEqual(FeedSession.readiness([.loaded, .loading]), .waiting, "A slow month is waited for.")
        XCTAssertEqual(FeedSession.readiness([.loading, .failed("offline")]), .failed("offline"),
                       "A failed month keeps the feed shown, for Retry and Clear.")
        XCTAssertEqual(FeedSession.readiness([.loaded, .failed("refused")]), .failed("refused"))
    }

    // MARK: - Support

    private static var searchAcrossArchive: LibraryQuery {
        var query = LibraryQuery.library.refined(text: "beach", mode: .context)
        query.visibility = [.timeline, .archive]
        return query
    }

    private func photo(owner: String? = FeedMembershipTests.me, favorite: Bool = false, developed: Bool = false,
                       trashed: Bool = false, visibility: AssetVisibility = .timeline) -> Asset {
        var asset = Asset(id: "photo", ownerId: owner, isFavorite: favorite, isDeveloped: developed)
        asset.isTrashed = trashed
        asset.visibility = visibility
        return asset
    }
}
