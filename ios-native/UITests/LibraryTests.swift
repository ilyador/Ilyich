import XCTest

final class LibraryTests: XCTestCase {
    @MainActor private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-library"]
        app.launch()
        XCTAssertTrue(app.collectionViews["library.grid"].waitForExistence(timeout: 15))
        return app
    }
    @MainActor private func capture(_ app: XCUIApplication, _ title: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = title; image.lifetime = .keepAlways; add(image)
    }
    @MainActor func testLibrarySelectAndShelvesReturnToInteractiveGrid() {
        let app = launch()
        let grid = app.collectionViews["library.grid"]
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15))
        capture(app, "Library — 24,000 synthetic assets")
        app.buttons["library.select"].tap()
        grid.cells.element(boundBy: 1).tap()
        XCTAssertTrue(app.staticTexts["1 selected"].waitForExistence(timeout: 5))
        app.buttons["library.select"].tap()
        app.buttons["library.shelves"].tap()
        XCTAssertTrue(app.buttons["People"].waitForExistence(timeout: 5))
        capture(app, "Shelves — native glass")
        app.buttons["Close"].tap()
        grid.swipeUp()
        XCTAssertTrue(app.buttons["library.select"].isHittable)
    }
    @MainActor func testSearchContinuesAnEmptyVerifiedPageAndCanClear() {
        let app = launch()
        let search = app.textFields["library.search"]
        search.tap(); search.typeText("me wearing a red hat in Amsterdam\n")
        XCTAssertTrue(app.staticTexts["9 matches"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Visually checked"].exists)
        capture(app, "Search — verified continuation")
        app.buttons["Clear filters"].tap()
        XCTAssertTrue(app.staticTexts["December 2026"].waitForExistence(timeout: 10))
    }
    @MainActor func testGlobeOpensAndReturnsToLibrary() {
        let app = launch()
        app.buttons["library.shelves"].tap(); app.buttons["Places"].tap()
        XCTAssertTrue(app.otherElements["Interactive Earth"].waitForExistence(timeout: 15))
        capture(app, "Places — native Earth")
        app.buttons["Close globe"].tap()
        XCTAssertTrue(app.textFields["library.search"].isHittable)
    }
    @MainActor func testLargeLibraryScrollingMetrics() {
        let app = launch(); let grid = app.collectionViews["library.grid"]
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15))
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric(), XCTCPUMetric(), XCTOSSignpostMetric.scrollDecelerationMetric]) {
            grid.swipeUp(velocity: .fast); grid.swipeDown(velocity: .fast)
        }
    }
}
