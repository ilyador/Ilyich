import XCTest
@testable import Ilyich

final class ShelfOrderTests: XCTestCase {
    func testSavedOrderLeadsAndNewItemsFollowInServerOrder() {
        let server = ["maya", "leo", "ana", "new"]
        XCTAssertEqual(ShelfOrder.apply(["ana", "maya", "gone", "leo"], to: server, id: { $0 }), ["ana", "maya", "leo", "new"])
        XCTAssertEqual(ShelfOrder.apply([], to: server, id: { $0 }), server, "Without a saved order the server's stays.")
    }

    func testOrderIsKeptPerAccountAndKind() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ShelfOrderTests"))
        defer { defaults.removePersistentDomain(forName: "ShelfOrderTests") }
        let mine = ShelfOrder(scope: "https://photos.example|me", defaults: defaults)
        let theirs = ShelfOrder(scope: "https://photos.example|them", defaults: defaults)
        mine.save(["b", "a"], for: .albums)
        XCTAssertEqual(mine.ids(.albums), ["b", "a"])
        XCTAssertEqual(mine.ids(.people), [])
        XCTAssertEqual(theirs.ids(.albums), [])
    }
}
