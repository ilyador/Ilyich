import XCTest

final class LibraryTests: XCTestCase {
    @MainActor private func launch(appearance: String = "light") -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-library", "-appearance", appearance]
        app.launch()
        XCTAssertTrue(app.collectionViews["library.grid"].waitForExistence(timeout: 15))
        return app
    }
    @MainActor private func capture(_ app: XCUIApplication, _ title: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = title; image.lifetime = .keepAlways; add(image)
    }
    @MainActor private func requireHittable(_ element: XCUIElement, in app: XCUIApplication,
                                          file: StaticString = #filePath, line: UInt = #line) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element)
        let result = XCTWaiter.wait(for: [ready], timeout: 5)
        if result != .completed {
            capture(app, "Interaction timeout")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Interaction timeout — accessibility hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        }
        XCTAssertEqual(result, .completed, "The control must become interactive after scrolling settles.", file: file, line: line)
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
        let select = app.buttons["library.select"]
        requireHittable(select, in: app)
        select.tap()
        grid.cells.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["1 selected"].waitForExistence(timeout: 5))
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
    @MainActor func testFloatingControlsStayAtTheirScreenEdges() {
        let app = launch()
        let screen = app.frame
        let search = app.textFields["library.search"]
        let shelves = app.buttons["library.shelves"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(search.frame.minY, screen.minY + screen.height * 0.8, "Search must stay near the bottom, not in the middle of the photo grid.")
        XCTAssertLessThanOrEqual(search.frame.maxY, screen.maxY)
        XCTAssertLessThan(shelves.frame.midX, screen.minX + screen.width * 0.15)
        XCTAssertGreaterThan(shelves.frame.midY, screen.minY + screen.height * 0.3)
        XCTAssertLessThan(shelves.frame.midY, screen.minY + screen.height * 0.7)
        shelves.tap(); app.buttons["Places"].tap()
        let globe = app.otherElements["Interactive Earth"]
        XCTAssertTrue(globe.waitForExistence(timeout: 15))
        XCTAssertGreaterThan(globe.frame.minY, screen.minY + screen.height * 0.5, "The globe belongs in the lower 40% of the library.")
        XCTAssertLessThanOrEqual(globe.frame.maxY, screen.maxY)
        XCTAssertLessThan(globe.frame.height, screen.height * 0.45)
    }
    @MainActor func testViewerCloseAllowsOpeningAnotherPhoto() {
        let app = launch()
        let grid = app.collectionViews["library.grid"]
        XCTAssertTrue(grid.cells.element(boundBy: 1).waitForExistence(timeout: 15))
        for index in [0, 1] {
            grid.cells.element(boundBy: index).tap()
            let close = app.buttons["Close"]
            XCTAssertTrue(close.waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["Photo actions"].exists)
            close.tap()
            let interactive = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: app.textFields["library.search"])
            XCTAssertEqual(XCTWaiter.wait(for: [interactive], timeout: 5), .completed)
        }
    }
    @MainActor func testDarkGlobeSupportsDragAndPinchWithoutBlockingLibrary() {
        let app = launch(appearance: "dark")
        capture(app, "Library — dark native glass")
        app.buttons["library.shelves"].tap(); app.buttons["Places"].tap()
        let globe = app.otherElements["Interactive Earth"]
        XCTAssertTrue(globe.waitForExistence(timeout: 15))
        globe.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: globe.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.55)))
        globe.pinch(withScale: 1.3, velocity: 0.6)
        capture(app, "Places — dark Earth after drag and pinch")
        app.buttons["Close globe"].tap()
        XCTAssertTrue(app.textFields["library.search"].isHittable)
        app.buttons["library.select"].tap()
        app.collectionViews["library.grid"].cells.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["1 selected"].waitForExistence(timeout: 5))
    }
    @MainActor func testLargeLibraryScrollingMetrics() {
        let app = launch(); let grid = app.collectionViews["library.grid"]
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15))
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric(), XCTCPUMetric(), XCTOSSignpostMetric.scrollDecelerationMetric]) {
            grid.swipeUp(velocity: .fast); grid.swipeDown(velocity: .fast)
        }
    }
}
