import XCTest

final class LibraryTests: XCTestCase {
    @MainActor private func launch(appearance: String = "light", extraArguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-library", "-appearance", appearance] + extraArguments
        app.launch()
        XCTAssertTrue(app.collectionViews["library.grid"].waitForExistence(timeout: 15))
        return app
    }
    @MainActor private func capture(_ app: XCUIApplication, _ title: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = title; image.lifetime = .keepAlways; add(image)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = title + " — accessibility hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    }
    @MainActor private func requireHittable(_ element: XCUIElement, in app: XCUIApplication,
                                          file: StaticString = #filePath, line: UInt = #line) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element)
        let result = XCTWaiter.wait(for: [ready], timeout: 5)
        if result != .completed {
            capture(app, "Interaction timeout")
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
        requireHittable(app.buttons["library.shelves"], in: app)
        grid.swipeUp()
        let select = app.buttons["library.select"]
        requireHittable(select, in: app)
        select.tap()
        grid.cells.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["1 selected"].waitForExistence(timeout: 5))
    }
    @MainActor func testSelectedPhotosSaveToPhotosWithACompletedCount() {
        let app = launch(extraArguments: ["-shareFileType", "preview"])
        let grid = app.collectionViews["library.grid"]
        requireHittable(app.buttons["library.select"], in: app)
        app.buttons["library.select"].tap()
        grid.cells.element(boundBy: 0).tap()
        grid.cells.element(boundBy: 1).tap()
        XCTAssertTrue(app.staticTexts["2 selected"].waitForExistence(timeout: 5))
        app.buttons["Selection actions"].tap()
        let save = app.buttons["Save to Photos"]
        requireHittable(save, in: app); save.tap()
        XCTAssertTrue(app.staticTexts["Saved 2 of 2 to Photos."].waitForExistence(timeout: 20))
        requireHittable(app.buttons["Done"], in: app)
        capture(app, "Selection — two photos saved to Photos")
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
    @MainActor func testCancellingOriginalExportLeavesTheViewerUsable() {
        let app = launch()
        let grid = app.collectionViews["library.grid"]
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15))
        grid.cells.firstMatch.tap()
        let actions = app.buttons["Photo actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10)); actions.tap()
        app.buttons["Download original"].tap()
        let cancel = app.buttons["viewer.cancelTransfer"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        requireHittable(cancel, in: app); cancel.tap()
        XCTAssertFalse(cancel.exists)
        requireHittable(actions, in: app)
        app.buttons["Close"].tap()
        XCTAssertTrue(grid.cells.element(boundBy: 1).waitForExistence(timeout: 5))
        grid.cells.element(boundBy: 1).tap()
        XCTAssertTrue(app.buttons["Photo actions"].waitForExistence(timeout: 10))
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
    @MainActor func testAccessibilityTextKeepsLibraryAndGlobeControlsTappable() {
        let app = launch(extraArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        for identifier in ["library.select", "library.shelves"] { requireHittable(app.buttons[identifier], in: app) }
        let heading = app.staticTexts["library.heading"]
        XCTAssertTrue(heading.exists)
        XCTAssertEqual(heading.label, "December 2026")
        XCTAssertLessThanOrEqual(heading.frame.maxY, app.buttons["library.select"].frame.minY,
                                 "At accessibility text sizes, the date needs its own full-width row.")
        capture(app, "Library — accessibility text")
        app.buttons["library.shelves"].tap()
        let places = app.buttons["Places"]
        requireHittable(places, in: app)
        places.tap()
        XCTAssertTrue(app.otherElements["Interactive Earth"].waitForExistence(timeout: 15))
        let close = app.buttons["Close globe"]
        requireHittable(close, in: app)
        capture(app, "Places — accessibility text")
        close.tap()
        requireHittable(app.textFields["library.search"], in: app)
    }
    @MainActor func testLargeLibraryScrollingMetrics() {
        let app = launch(); let grid = app.collectionViews["library.grid"]
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15))
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric(), XCTCPUMetric(), XCTOSSignpostMetric.scrollDecelerationMetric]) {
            grid.swipeUp(velocity: .fast); grid.swipeDown(velocity: .fast)
        }
    }
}
