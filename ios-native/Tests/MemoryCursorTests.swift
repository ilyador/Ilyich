import XCTest
@testable import Ilyich

final class MemoryCursorTests: XCTestCase {
    func testPhotoNavigationCrossesMemoriesAndStopsAtEpilogue() {
        var cursor = MemoryCursor()
        let counts = [2, 1]
        cursor.previous(counts: counts)
        XCTAssertEqual(cursor, .init())
        cursor.next(counts: counts)
        XCTAssertEqual(cursor, .init(memory: 0, asset: 1))
        cursor.next(counts: counts)
        XCTAssertEqual(cursor, .init(memory: 1, asset: 0))
        cursor.previous(counts: counts)
        XCTAssertEqual(cursor, .init(memory: 0, asset: 1))
        cursor.nextMemory(counts: counts)
        cursor.next(counts: counts)
        XCTAssertEqual(cursor, .init(memory: 2, asset: 0))
        cursor.next(counts: counts)
        XCTAssertEqual(cursor, .init(memory: 2, asset: 0))
        cursor.previousMemory(counts: counts)
        XCTAssertEqual(cursor, .init(memory: 1, asset: 0))
    }
    func testEmptyMemoryListRemainsSafe() {
        var cursor = MemoryCursor()
        cursor.next(counts: []); cursor.previous(counts: [])
        cursor.nextMemory(counts: []); cursor.previousMemory(counts: [])
        XCTAssertEqual(cursor, .init())
    }
}
