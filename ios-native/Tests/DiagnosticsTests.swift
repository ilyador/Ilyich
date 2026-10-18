import XCTest
@testable import Ilyich

final class DiagnosticsTests: XCTestCase {
    func testCategoriesNeverRetainIDsQueryOrUnknownPath() {
        XCTAssertEqual(DiagnosticsStore.category(path: "assets/private-asset-id/thumbnail?token=secret"), "assets")
        XCTAssertEqual(DiagnosticsStore.category(path: "https://private-server.example/api/assets/one"), "other")
        XCTAssertEqual(DiagnosticsStore.category(path: "search?query=personal"), "other")
        XCTAssertEqual(DiagnosticsStore.category(path: "/albums/private-album-id"), "albums")
    }
    func testBoundedSanitizedReport() async {
        let store = DiagnosticsStore(level: .requests)
        for _ in 0..<350 {
            await store.record(method: "secret-method", path: "assets/private-asset-id", statusCode: 9999, startedAt: Date(), outcome: .failed)
        }
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.count, 300)
        let report = DiagnosticsStore.report(events: snapshot)
        XCTAssertFalse(report.contains("private-asset-id"))
        XCTAssertFalse(report.contains("secret-method"))
        XCTAssertFalse(report.contains("9999"))
        XCTAssertTrue(snapshot.allSatisfy { $0.method == "OTHER" && $0.statusCode == nil && $0.category == "assets" })
        await store.clear()
        let empty = await store.snapshot()
        XCTAssertTrue(empty.isEmpty)
    }
    func testErrorsOnlyAndOffLevels() async {
        let errors = DiagnosticsStore(level: .errors)
        await errors.record(method: "GET", path: "assets", statusCode: 200, startedAt: Date(), outcome: .success)
        await errors.record(method: "GET", path: "assets", statusCode: nil, startedAt: Date(), outcome: .cancelled)
        await errors.record(method: "POST", path: "albums", statusCode: nil, startedAt: Date(), outcome: .blocked)
        let snapshot = await errors.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.first?.outcome, .blocked)
        let off = DiagnosticsStore(level: .off)
        await off.record(method: "GET", path: "assets", statusCode: 500, startedAt: Date(), outcome: .failed)
        let disabled = await off.snapshot()
        XCTAssertTrue(disabled.isEmpty)
    }
}
