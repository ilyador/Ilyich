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
    /// The backup state import's report joins the exported log as counts only, stays when the
    /// request log is cleared, and goes at sign-out.
    func testTransferImportReportIsCountsOnlyAndGoesAtSignOut() async {
        let store = DiagnosticsStore(level: .errors)
        let comparison = LegacyImportComparison(compared: [.receipts: 21_345, .confirmations: 59_877], mismatches: [.receipts: 0, .confirmations: 2])
        let report = LegacyImportReport(mode: .shadow, outcome: .imported, date: Date(timeIntervalSinceReferenceDate: 800_000_000), milliseconds: 420,
                                        comparison: comparison)
        await store.recordTransferImport(report)
        let exported = DiagnosticsStore.report(events: [], transferImport: await store.transferImportReport())
        XCTAssertTrue(exported.contains("Backup state import (shadow): imported in 420 ms; 2 mismatches; receipts 0/21345, confirmations 2/59877"), exported)
        await store.clearRequests()
        let kept = await store.transferImportReport()
        XCTAssertEqual(kept, report)
        await store.clear()
        let cleared = await store.transferImportReport()
        XCTAssertNil(cleared)
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
