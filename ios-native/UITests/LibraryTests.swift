import XCTest
import UIKit

final class LibraryTests: XCTestCase {
    /// Lifting the finger closes the shelves; most tests keep them out so they can tap rows.
    @MainActor private func launch(appearance: String = "light", extraArguments: [String] = [], shelvesStayOpen: Bool = true) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-library", "-appearance", appearance]
            + (shelvesStayOpen ? ["--ui-testing-shelves-stay-open"] : []) + extraArguments
        app.launch()
        XCTAssertTrue(app.collectionViews["library.grid"].waitForExistence(timeout: 15))
        return app
    }
    @MainActor private func capture(_ app: XCUIApplication, _ title: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = title; image.lifetime = .keepAlways; add(image)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = title + " — accessibility hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    }
    /// Tapping beside the rows puts the shelves away.
    @MainActor private func tapBesideShelves(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.62)).tap()
        XCTAssertTrue(app.buttons["library.shelves"].waitForExistence(timeout: 5), "Tapping beside the rows puts the shelves away.")
    }
    @MainActor private func openShelves(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)))
        XCTAssertTrue(app.buttons["Places"].waitForExistence(timeout: 5))
    }
    /// Photos run under the status bar, where a touch scrolls to the top, so photos are touched
    /// near their lower edge.
    @MainActor private func tapPhoto(_ cell: XCUIElement) {
        cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
    }
    /// Selection starts with a long press on a photo, which selects it.
    @MainActor private func pressPhoto(_ cell: XCUIElement) {
        cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).press(forDuration: 0.6)
    }
    /// The globe closes only by pulling its handle down.
    @MainActor private func closeGlobe(_ app: XCUIApplication) {
        let handle = app.buttons["Close globe"]
        requireHittable(handle, in: app)
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 240)))
        XCTAssertTrue(app.textFields["library.search"].waitForExistence(timeout: 5))
    }
    @MainActor private func hasRenderedPhoto(_ cell: XCUIElement) -> Bool {
        guard let image = cell.screenshot().image.cgImage else { return false }
        var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 16, height: 16,
                bitsPerComponent: 8, bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
            return true
        }
        guard rendered else { return false }
        // Fixture photos are colored landscapes. Empty cells and their white
        // month/storage badges are achromatic, so labels alone cannot pass.
        let colored = stride(from: 0, to: pixels.count, by: 4).filter { i in
            let channels = [pixels[i], pixels[i + 1], pixels[i + 2]]
            return Int(channels.max()!) - Int(channels.min()!) > 35
        }.count
        return colored > 80
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
        XCTAssertFalse(app.buttons["library.doneSelecting"].exists, "At rest the top of the feed carries no buttons.")
        pressPhoto(grid.cells.element(boundBy: 1))
        XCTAssertTrue(app.staticTexts["1 selected"].waitForExistence(timeout: 5))
        app.buttons["library.doneSelecting"].tap()
        openShelves(app)
        XCTAssertTrue(app.buttons["People"].waitForExistence(timeout: 5))
        capture(app, "Shelves — native glass")
        tapBesideShelves(app)
        requireHittable(app.buttons["library.shelves"], in: app)
        grid.swipeUp()
        let photo = grid.cells.element(boundBy: 8)
        requireHittable(photo, in: app)
        pressPhoto(photo)
        XCTAssertTrue(app.staticTexts["1 selected"].waitForExistence(timeout: 5))
    }
    @MainActor func testPinchingChangesDensityWhileTheFingersMove() {
        let app = launch()
        let grid = app.collectionViews["library.grid"]
        let photo = grid.cells.element(boundBy: 5)
        XCTAssertTrue(photo.waitForExistence(timeout: 15))
        let before = photo.frame.width
        // Pinch on a photo mid-screen: a finger starting under the status bar never reaches the grid.
        photo.pinch(withScale: 1.7, velocity: 1.5)
        let larger = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in grid.cells.element(boundBy: 0).frame.width > before + 20 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [larger], timeout: 5), .completed, "Spreading two fingers shows fewer, larger photos.")
        capture(app, "Pinch — spread to fewer columns")
        let spread = grid.cells.element(boundBy: 0).frame.width
        let middle = grid.cells.allElementsBoundByIndex.first { $0.isHittable && $0.frame.midY > app.frame.height * 0.35 && $0.frame.midY < app.frame.height * 0.65 } ?? grid.cells.element(boundBy: 2)
        middle.pinch(withScale: 0.45, velocity: -1.5)
        capture(app, "Pinch — squeezed to more columns")
        let smaller = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in grid.cells.element(boundBy: 0).frame.width < spread - 20 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [smaller], timeout: 5), .completed, "Pinching shows more, smaller photos.")
    }
    @MainActor func testShelfCueRequiresAnInwardSwipe() {
        let app = launch()
        let cue = app.buttons["library.shelves"]
        XCTAssertTrue(cue.waitForExistence(timeout: 5))
        cue.tap()
        XCTAssertFalse(app.buttons["Places"].exists, "A normal tap must not pop the shelf open.")
        XCTAssertFalse(app.buttons["Photo actions"].exists, "Tapping the cue must not open the photo behind it.")
        openShelves(app)
        capture(app, "Shelf — swipe-driven local wave")
    }
    @MainActor func testRapidRightScrubLoadsVisibleThumbnails() {
        let app = launch()
        let grid = app.collectionViews["library.grid"]
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15))
        for destination in [0.30, 0.70, 0.43, 0.61] {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.5))
                .press(forDuration: 0.03, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: destination)))
        }
        let deadline = Date().addingTimeInterval(10)
        var rendered = false
        repeat {
            let candidates = grid.cells.allElementsBoundByIndex.filter {
                $0.frame.minY > 200 && $0.frame.maxY < 640 && $0.frame.midX < 280
            }
            rendered = candidates.prefix(3).contains(where: hasRenderedPhoto)
            if !rendered { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        } while !rendered && Date() < deadline
        capture(app, "Rapid timeline scrubbing — rendered thumbnails")
        XCTAssertTrue(rendered, "Scrubbing must recover actual photo pixels, not just metadata labels on empty cells.")
        XCTAssertFalse(app.staticTexts["Some photos couldn’t load."].exists, "Settled scrub must not leave bucket-loading errors.")
    }
    @MainActor func testLibraryEdgeGesturesOpenShelvesAndScrubTimeline() {
        let app = launch()
        let grid = app.collectionViews["library.grid"]
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15))

        let leftEdge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.36))
        let shelfTarget = app.coordinate(withNormalizedOffset: CGVector(dx: 0.09, dy: 0.36))
        leftEdge.press(forDuration: 0.05, thenDragTo: shelfTarget)
        XCTAssertTrue(app.buttons["Places"].waitForExistence(timeout: 5), "A slight inward swipe anywhere on the edge should pop the shelves out.")
        XCTAssertTrue(app.buttons["People"].exists, "Lifting chooses nothing; the top shelves stay out.")
        XCTAssertFalse(app.buttons["Close shelves"].exists, "The shelves have no close button.")
        tapBesideShelves(app)

        let firstPhoto = grid.cells.firstMatch
        requireHittable(firstPhoto, in: app)
        tapPhoto(firstPhoto)
        let closeViewer = app.buttons["Close"]
        XCTAssertTrue(closeViewer.waitForExistence(timeout: 5), "The grid should receive taps after dismissing the shelves.")
        closeViewer.tap()

        let heading = app.staticTexts["library.heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        let initialMonth = heading.label
        let rightEdge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.91, dy: 0.72))
        let scrubTarget = app.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.22))
        rightEdge.press(forDuration: 0.05, thenDragTo: scrubTarget)
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", initialMonth), object: heading)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 10), .completed,
                       "A trailing inward and vertical drag should scrub to a different timeline month.")
    }
    @MainActor func testEverySettingIsReachableFromTheSettingsShelf() {
        let app = launch()
        openShelves(app)
        app.buttons["Settings"].tap()
        for row in ["Account", "Read-only mode", "Network", "Notifications"] {
            XCTAssertTrue(app.buttons[row].waitForExistence(timeout: 5), "\(row) has its own row on the Settings shelf.")
        }
        // Eleven rows do not fit; holding near the bottom brings the rest.
        let origin = app.coordinate(withNormalizedOffset: .zero), height = app.frame.height
        origin.withOffset(CGVector(dx: 120, dy: height * 0.5))
            .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 120, dy: height - 70)), withVelocity: .slow, thenHoldForDuration: 2)
        for row in ["Diagnostics", "About", "Sign out"] {
            XCTAssertTrue(app.buttons[row].waitForExistence(timeout: 5), "\(row) has its own row on the Settings shelf.")
        }
        tapBesideShelves(app)
        openShelves(app)
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["Read-only mode"].waitForExistence(timeout: 5))
        app.buttons["Read-only mode"].tap()
        XCTAssertTrue(app.switches["Read-only mode"].waitForExistence(timeout: 5), "Read-only mode can be turned on and off.")
        app.buttons["Done"].tap()
        openShelves(app)
        app.buttons["Settings"].tap()
        origin.withOffset(CGVector(dx: 120, dy: height * 0.5))
            .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 120, dy: height - 70)), withVelocity: .slow, thenHoldForDuration: 2)
        let signOut = app.buttons["Sign out"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 5))
        signOut.tap()
        XCTAssertTrue(app.staticTexts["Sign out of Ilyich?"].waitForExistence(timeout: 5), "Signing out asks first.")
        // Dismissing the question, here by tapping away from it, keeps you signed in.
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap() }
        XCTAssertFalse(app.staticTexts["Sign out of Ilyich?"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.collectionViews["library.grid"].exists, "Still signed in.")
    }
    @MainActor func testReorderingPeopleUpdatesTheShelfAtOnce() {
        let app = launch(extraArguments: ["--ui-testing-many-people"])
        openShelves(app)
        app.buttons["People"].tap()
        let maya = app.buttons["Maya"], friend = app.buttons["Friend 03"]
        XCTAssertTrue(maya.waitForExistence(timeout: 10)); XCTAssertTrue(friend.waitForExistence(timeout: 5))
        let origin = app.coordinate(withNormalizedOffset: .zero)
        // Out past Maya's tip onto the reorder button, and lift.
        origin.withOffset(CGVector(dx: 100, dy: maya.frame.midY))
            .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 290, dy: maya.frame.midY)))
        XCTAssertTrue(app.buttons["library.reorderDone"].waitForExistence(timeout: 5), "Lifting over the reorder button reorders people.")
        friend.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 28, dy: 0))
            .press(forDuration: 0.3, thenDragTo: maya.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.1)).withOffset(CGVector(dx: 28, dy: 0)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertLessThan(friend.frame.minY, maya.frame.minY, "The carried person lands where it was dropped, at once.")
        // The left edge finishes reordering and keeps the shelves out.
        let y = app.frame.height * 0.55
        origin.withOffset(CGVector(dx: 160, dy: y)).press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 4, dy: y)))
        XCTAssertFalse(app.buttons["library.reorderDone"].waitForExistence(timeout: 2), "The left edge finished reordering.")
        XCTAssertTrue(maya.exists && friend.exists)
        XCTAssertLessThan(friend.frame.minY, maya.frame.minY, "The new order shows without reopening the shelves.")
    }
    @MainActor func testLiftingTheFingerPutsTheShelvesAway() {
        let app = launch(shelvesStayOpen: false)
        XCTAssertTrue(app.collectionViews["library.grid"].cells.firstMatch.waitForExistence(timeout: 15))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.45))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)),
                   withVelocity: .default, thenHoldForDuration: 0.4)
        XCTAssertTrue(app.buttons["library.shelves"].waitForExistence(timeout: 5), "Lifting the finger anywhere puts the shelves away.")
        XCTAssertFalse(app.buttons["Places"].exists)
    }
    @MainActor func testSwipingAlongAShelfOpensItAndTheEdgeGoesBack() {
        let app = launch()
        XCTAssertTrue(app.collectionViews["library.grid"].cells.firstMatch.waitForExistence(timeout: 15))
        // One stroke: in from the edge, where the shelves open with People one row above the
        // finger, then up onto People and out to its tip, holding there while its glow builds.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.4))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.58, dy: 0.4 - 80 / app.frame.height)),
                    withVelocity: .default, thenHoldForDuration: 1.0)
        XCTAssertTrue(app.buttons["Manage people"].waitForExistence(timeout: 5), "Holding by People's tip opens it without lifting.")
        XCTAssertTrue(app.buttons["Maya"].exists)
        capture(app, "Shelf — People opened by a swipe")
        // Left to the edge goes back a level, then folds the shelves away.
        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.4))
        middle.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.4)))
        XCTAssertTrue(app.buttons["People"].waitForExistence(timeout: 5), "The left edge goes back to the top level.")
        XCTAssertFalse(app.buttons["Manage people"].exists)
        middle.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.003, dy: 0.4)))
        XCTAssertTrue(app.buttons["library.shelves"].waitForExistence(timeout: 5), "At the top level the left edge puts the shelves away.")
    }
    /// The rows stand still under the finger, one row per row height, and a long list scrolls
    /// only while the finger stays near the bottom or the top of the shelves.
    @MainActor func testALongShelfScrollsOnlyWhileTheFingerStaysNearItsEnds() {
        let app = launch(extraArguments: ["--ui-testing-many-people"])
        openShelves(app)
        app.buttons["People"].tap()
        let maya = app.buttons["Maya"], manage = app.buttons["Manage people"]
        XCTAssertTrue(maya.waitForExistence(timeout: 10))
        XCTAssertFalse(manage.exists, "Sixty people do not fit; the end of the list is out of sight.")
        let origin = app.coordinate(withNormalizedOffset: .zero), height = app.frame.height
        func stroke(from start: CGFloat, to end: CGFloat, hold: TimeInterval) {
            origin.withOffset(CGVector(dx: 120, dy: start))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 120, dy: end)), withVelocity: .slow, thenHoldForDuration: hold)
        }
        let resting = maya.frame.midY
        stroke(from: height * 0.35, to: height * 0.6, hold: 1)
        XCTAssertEqual(maya.frame.midY, resting, accuracy: 10, "Away from the ends the rows stand still under the finger.")
        stroke(from: height * 0.5, to: height - 70, hold: 4)
        XCTAssertTrue(manage.waitForExistence(timeout: 5), "Held near the bottom, the list scrolls on to its end.")
        XCTAssertFalse(maya.exists, "Its first rows have scrolled away.")
        capture(app, "Shelf — a long list scrolled to its end")
        stroke(from: height * 0.5, to: height * 0.1, hold: 5)
        XCTAssertTrue(maya.waitForExistence(timeout: 5), "Held near the top, it scrolls back to its first rows.")
    }
    @MainActor func testLiftingOverTheReorderButtonReordersAlbumsInPlace() {
        let app = launch()
        openShelves(app)
        let albums = app.buttons["Albums"]
        XCTAssertTrue(albums.waitForExistence(timeout: 5))
        // Holding by Albums' tip opens it.
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: 100, dy: albums.frame.midY))
            .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: app.frame.width * 0.58, dy: albums.frame.midY)),
                   withVelocity: .default, thenHoldForDuration: 1.0)
        XCTAssertTrue(app.buttons["Manage albums"].waitForExistence(timeout: 5), "Holding by Albums' tip opens it.")
        // Then out past a row's tip onto the reorder button, and lift.
        let first = app.buttons["Coast"]
        origin.withOffset(CGVector(dx: 100, dy: first.frame.midY))
            .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 290, dy: first.frame.midY)))
        let done = app.buttons["library.reorderDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Lifting over the reorder button reorders the albums in place.")
        XCTAssertGreaterThan(done.frame.midX, app.frame.width / 2, "Done sits at the top right.")
        XCTAssertFalse(app.buttons["Close shelves"].exists, "While reordering there is no close button.")
        XCTAssertFalse(app.buttons["New album"].exists, "Only the albums themselves move.")
        let coast = app.buttons["Coast"], harbor = app.buttons["Harbor"]
        XCTAssertLessThan(coast.frame.minY, harbor.frame.minY, "Albums start in the server's order.")
        capture(app, "Shelf — reordering albums in place")
        // The handle sits inside the row, on the edge side.
        harbor.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 28, dy: 0))
            .press(forDuration: 0.3, thenDragTo: coast.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.1)).withOffset(CGVector(dx: 28, dy: 0)),
                   withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertLessThan(harbor.frame.minY, coast.frame.minY, "Dragging a handle moves the album.")
        done.tap()
        XCTAssertTrue(app.buttons["library.shelves"].waitForExistence(timeout: 5), "Done puts the shelves away.")
        openShelves(app); app.buttons["Albums"].tap()
        XCTAssertTrue(app.buttons["Manage albums"].waitForExistence(timeout: 5))
        XCTAssertLessThan(app.buttons["Harbor"].frame.minY, app.buttons["Coast"].frame.minY, "The shelf keeps the new order.")
        let newAlbum = app.buttons["New album"]
        XCTAssertTrue(newAlbum.waitForExistence(timeout: 5))
        XCTAssertLessThan(newAlbum.frame.minY, app.buttons["Manage albums"].frame.minY, "New album sits just above Manage albums.")
        newAlbum.tap()
        XCTAssertTrue(app.navigationBars["New album"].waitForExistence(timeout: 5), "New album opens the album editor.")
        app.buttons["Cancel"].tap()
    }
    @MainActor func testAlbumInTheFeedCanBeSharedFromTheTop() {
        let app = launch()
        openShelves(app); app.buttons["Albums"].tap()
        let coast = app.buttons["Coast"]
        XCTAssertFalse(app.buttons["Close shelves"].exists, "Inside a group there is no close button.")
        XCTAssertTrue(coast.waitForExistence(timeout: 5)); coast.tap()
        XCTAssertTrue(app.buttons["library.shelves"].waitForExistence(timeout: 5), "Tapping an album puts the shelves away.")
        let share = app.buttons["library.shareAlbum"]
        XCTAssertTrue(share.waitForExistence(timeout: 5), "An album in the feed has a share button.")
        let title = app.otherElements["library.filterShelf"].staticTexts["Coast"]
        XCTAssertGreaterThan(share.frame.midX, app.frame.width * 0.75, "Share sits at the top right, across from the album title.")
        XCTAssertEqual(share.frame.midY, title.frame.midY, accuracy: 14)
        share.tap()
        app.buttons["Create link"].tap()
        XCTAssertTrue(app.navigationBars["Share album"].waitForExistence(timeout: 5))
        capture(app, "Album — share link")
    }
    @MainActor func testAnAlbumSharedOnlyByLinkShowsItsLinks() {
        let app = launch()
        openShelves(app); app.buttons["Albums"].tap()
        let harbor = app.buttons["Harbor"]
        XCTAssertTrue(harbor.waitForExistence(timeout: 5)); harbor.tap()
        let share = app.buttons["library.shareAlbum"]
        XCTAssertTrue(share.waitForExistence(timeout: 5)); share.tap()
        app.buttons["Share with people"].tap()
        XCTAssertTrue(app.navigationBars["Sharing"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Harbor for family"].waitForExistence(timeout: 5), "An album shared only by link shows its link.")
        capture(app, "Album — shared by link")
    }
    @MainActor func testScrubbingBackUpTheRailReturnsToTheNewestMonth() {
        let app = launch()
        XCTAssertTrue(app.collectionViews["library.grid"].cells.firstMatch.waitForExistence(timeout: 15))
        let heading = app.staticTexts["library.heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        let newest = heading.label
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.86)))
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", newest), object: heading)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 10), .completed)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.8))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.02)),
                   withVelocity: .fast, thenHoldForDuration: 0.3)
        let back = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", newest), object: heading)
        XCTAssertEqual(XCTWaiter.wait(for: [back], timeout: 5), .completed, "The top of the rail is always the newest month.")
    }
    /// Touching the rail opens it on the month under the finger. The photos move only once it is
    /// open: a quick touch leaves them where they were, and holding on takes them there.
    @MainActor func testTouchingTheRailOpensItBeforeThePhotosMove() {
        let app = launch()
        XCTAssertTrue(app.collectionViews["library.grid"].cells.firstMatch.waitForExistence(timeout: 15))
        let heading = app.staticTexts["library.heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        let newest = heading.label
        let touch = app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.7))
        let nudge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.7))
        touch.press(forDuration: 0.05, thenDragTo: nudge, withVelocity: .default, thenHoldForDuration: 0)
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", newest), object: heading)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 1.5), .timedOut, "Letting go before the rail is open leaves the photos where they were.")
        touch.press(forDuration: 0.05, thenDragTo: nudge, withVelocity: .default, thenHoldForDuration: 2)
        let followed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", newest), object: heading)
        XCTAssertEqual(XCTWaiter.wait(for: [followed], timeout: 5), .completed, "Holding on takes the photos to the month under the finger once the rail is open.")
    }
    @MainActor func testTappingThePhotosWhileTypingOnlyPutsTheKeyboardAway() {
        let app = launch()
        let search = app.textFields["library.search"]
        requireHittable(search, in: app)
        search.tap(); search.typeText("beach")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        tapPhoto(app.collectionViews["library.grid"].cells.element(boundBy: 0))
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["Close"].waitForExistence(timeout: 2), "Tapping out of search must not open a photo.")
    }
    @MainActor func testSelectedPhotosSaveToPhotosWithACompletedCount() {
        let app = launch(extraArguments: ["-shareFileType", "preview"])
        let grid = app.collectionViews["library.grid"]
        XCTAssertTrue(grid.cells.element(boundBy: 1).waitForExistence(timeout: 15))
        pressPhoto(grid.cells.element(boundBy: 0))
        tapPhoto(grid.cells.element(boundBy: 1))
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
        let firstMatch = app.collectionViews["library.grid"].cells.element(boundBy: 0)
        XCTAssertGreaterThanOrEqual(firstMatch.frame.minY, app.buttons["Clear filters"].frame.maxY,
                                    "The first result must start below the header, not under its blur.")
        capture(app, "Search — verified continuation")
        app.buttons["Clear filters"].tap()
        XCTAssertTrue(app.staticTexts["December 2026"].waitForExistence(timeout: 10))
    }
    @MainActor func testGlobeOpensAndReturnsToLibrary() {
        let app = launch()
        openShelves(app); app.buttons["Places"].tap()
        XCTAssertTrue(app.otherElements["Interactive Earth"].waitForExistence(timeout: 15))
        capture(app, "Places — native Earth")
        app.buttons["Close globe"].tap()
        XCTAssertTrue(app.otherElements["Interactive Earth"].exists, "Tapping the handle must not close the globe.")
        closeGlobe(app)
        XCTAssertTrue(app.textFields["library.search"].isHittable)
    }
    @MainActor func testTheRailScrubsWithTheEarthOpen() {
        let app = launch()
        XCTAssertTrue(app.collectionViews["library.grid"].cells.firstMatch.waitForExistence(timeout: 15))
        let heading = app.staticTexts["library.heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        let newest = heading.label
        openShelves(app); app.buttons["Places"].tap()
        let earth = app.otherElements["Interactive Earth"]
        XCTAssertTrue(earth.waitForExistence(timeout: 15))
        // The rail runs down the right edge above the Earth.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.2))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)),
                   withVelocity: .default, thenHoldForDuration: 1)
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", newest), object: heading)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed, "Scrubbing the rail moves the feed while the Earth is open.")
        XCTAssertTrue(earth.exists, "The Earth stays open while the rail scrubs.")
    }
    @MainActor func testPeoplePlacesAndLightroomKeepTheCanonicalLibraryFeed() {
        let app = launch()
        let grid = app.collectionViews["library.grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 15))

        openShelves(app)
        app.buttons["People"].tap()
        let maya = app.buttons["Maya"]
        XCTAssertTrue(maya.waitForExistence(timeout: 10), "The fixture's Maya should be available in the People shelf.")
        requireHittable(maya, in: app)
        maya.tap()
        XCTAssertTrue(grid.exists)
        let filterShelf = app.otherElements["library.filterShelf"]
        XCTAssertTrue(app.buttons["library.shelves"].waitForExistence(timeout: 5), "Tapping a person puts the shelves away.")
        XCTAssertTrue(filterShelf.waitForExistence(timeout: 10), "The chosen person should sit at the top as a shelf.")
        XCTAssertTrue(app.buttons["Clear filters"].exists, "Clearing is its own round button beside the tag.")
        filterShelf.staticTexts["Maya"].tap()
        XCTAssertTrue(app.buttons["Manage people"].waitForExistence(timeout: 5), "The filter shelf brings back its people.")
        XCTAssertTrue(app.buttons["Maya"].exists)
        tapBesideShelves(app)
        let clearPeople = app.buttons["Clear filters"]
        XCTAssertTrue(clearPeople.waitForExistence(timeout: 10))
        requireHittable(clearPeople, in: app)
        clearPeople.tap()

        openShelves(app)
        app.buttons["Places"].tap()
        let earth = app.otherElements["Interactive Earth"]
        XCTAssertTrue(earth.waitForExistence(timeout: 15))
        let allLocations = app.buttons["All locations"]
        requireHittable(allLocations, in: app)
        allLocations.tap()
        let locations = app.descendants(matching: .any).matching(identifier: "places.list").firstMatch
        let amsterdam = locations.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Amsterdam")).firstMatch
        XCTAssertTrue(amsterdam.waitForExistence(timeout: 10), "The locations list should include the fixture's Amsterdam collection.")
        requireHittable(amsterdam, in: app)
        amsterdam.tap()
        XCTAssertTrue(grid.exists)
        XCTAssertTrue(earth.exists, "Choosing a location should filter the feed while keeping the globe open.")
        let clearPlace = app.buttons["Clear filters"]
        XCTAssertTrue(clearPlace.waitForExistence(timeout: 10))
        requireHittable(clearPlace, in: app)
        clearPlace.tap()
        closeGlobe(app)

        openShelves(app)
        app.buttons["More"].tap()
        let lightroom = app.buttons["Lightroom"]
        XCTAssertTrue(lightroom.waitForExistence(timeout: 10))
        requireHittable(lightroom, in: app)
        lightroom.tap()
        XCTAssertTrue(grid.exists)
        XCTAssertTrue(app.buttons["Clear filters"].waitForExistence(timeout: 10))
        XCTAssertTrue(filterShelf.staticTexts["Lightroom"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["library.timeRail"].waitForExistence(timeout: 10),
                      "Lightroom is a timeline of every developed photo, with its rail, as a person is.")
        XCTAssertTrue(app.buttons["library.shelves"].waitForExistence(timeout: 5), "Tapping a filter puts the shelves away.")
        XCTAssertEqual(app.collectionViews.matching(identifier: "library.grid").count, 1,
                       "Shelf filters must not open a second photo collection grid.")
    }
    @MainActor func testPhotoInfoLocationOpensFocusedInteractiveEarth() {
        let app = launch()
        tapPhoto(app.collectionViews["library.grid"].cells.element(boundBy: 0))
        let info = app.buttons["Info"]
        requireHittable(info, in: app); info.tap()
        let location = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Explore this location on the globe")).firstMatch
        let details = app.scrollViews.firstMatch
        for _ in 0..<4 where !location.isHittable {
            if details.exists { details.swipeUp() } else { app.swipeUp() }
        }
        requireHittable(location, in: app); location.tap()
        XCTAssertTrue(app.otherElements["Interactive Earth"].waitForExistence(timeout: 15))
        capture(app, "Photo location — focused interactive Earth")
    }
    @MainActor func testZoomingIntoAPhotoLocationKeepsTheEarthUsable() {
        let app = launch(appearance: "dark")
        tapPhoto(app.collectionViews["library.grid"].cells.element(boundBy: 0))
        let info = app.buttons["Info"]
        requireHittable(info, in: app); info.tap()
        let location = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Explore this location on the globe")).firstMatch
        let details = app.scrollViews.firstMatch
        for _ in 0..<4 where !location.isHittable {
            if details.exists { details.swipeUp() } else { app.swipeUp() }
        }
        requireHittable(location, in: app); location.tap()
        let earth = app.otherElements["Interactive Earth"]
        XCTAssertTrue(earth.waitForExistence(timeout: 15))
        capture(app, "Earth — focused photo location")
        for step in 1...3 {
            earth.pinch(withScale: 2.5, velocity: 2)
            capture(app, "Earth — zoomed in, step \(step)")
        }
        requireHittable(app.buttons["Close globe"], in: app)
        XCTAssertTrue(earth.exists)
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
        let first = app.collectionViews["library.grid"].cells.firstMatch
        XCTAssertEqual(first.frame.minY, first.frame.height / 2, accuracy: 2, "The feed starts half a photo down, below the blur.")
        openShelves(app); app.buttons["Places"].tap()
        let globe = app.otherElements["Interactive Earth"]
        XCTAssertTrue(globe.waitForExistence(timeout: 15))
        XCTAssertGreaterThan(globe.frame.minY, screen.minY + screen.height * 0.5, "The globe belongs in the lower 40% of the library.")
        // Half a point allows for the spring that raises the Earth still settling.
        XCTAssertLessThanOrEqual(globe.frame.maxY, screen.maxY + 0.5)
        XCTAssertLessThan(globe.frame.height, screen.height * 0.45)
    }
    @MainActor func testVideosCloseWithASwipeDownLikePhotos() {
        let app = launch()
        let video = app.collectionViews["library.grid"].cells.element(boundBy: 5)
        XCTAssertTrue(video.waitForExistence(timeout: 15))
        tapPhoto(video)
        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        // A video can be muted from the viewer, as in Photos, and unmuted again.
        let mute = app.buttons["Mute"]
        XCTAssertTrue(mute.waitForExistence(timeout: 5), "A video has a mute button.")
        capture(app, "Viewer — video")
        // Every round button in the viewer is the same circle as the actions menu.
        let circle = app.buttons["Photo actions"].frame.size
        for name in ["Close", "Share", "Info", "Mute", "Delete"] {
            let size = app.buttons[name].frame.size
            XCTAssertEqual(size.width, circle.width, accuracy: 0.5, "\(name) is the same size as the actions menu.")
            XCTAssertEqual(size.height, circle.height, accuracy: 0.5, "\(name) is the same size as the actions menu.")
        }
        mute.tap()
        XCTAssertTrue(app.buttons["Unmute"].waitForExistence(timeout: 5))
        app.buttons["Unmute"].tap()
        XCTAssertTrue(app.buttons["Mute"].waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)), withVelocity: .fast, thenHoldForDuration: 0)
        // The viewer's own buttons can hide over a video, so check the library is back instead.
        let back = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: app.textFields["library.search"])
        XCTAssertEqual(XCTWaiter.wait(for: [back], timeout: 5), .completed, "A swipe down closes a video, as it does a photo.")
    }
    /// The library stays upright when the phone turns. The viewer turns with it, keeps its photo,
    /// still swipes to the photo beside it, and closing it turns the app back upright.
    @MainActor func testOnlyTheViewerTurnsWithThePhoneAndKeepsItsPhoto() {
        let app = launch()
        let grid = app.collectionViews["library.grid"]
        XCTAssertTrue(grid.cells.element(boundBy: 9).waitForExistence(timeout: 15))
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
        let window = app.windows.firstMatch
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(1)
        XCTAssertLessThan(window.frame.width, window.frame.height, "The library stays upright.")
        XCUIDevice.shared.orientation = .portrait
        sleep(1)
        tapPhoto(grid.cells.element(boundBy: 9))
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10))
        let shown = onScreenPhoto(app)
        XCTAssertNotNil(shown)
        capture(app, "Viewer — upright")
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        XCTAssertGreaterThan(window.frame.width, window.frame.height, "The viewer turns with the phone.")
        XCTAssertEqual(onScreenPhoto(app), shown, "Turning keeps the same photo on screen.")
        capture(app, "Viewer — turned with the phone")
        app.swipeLeft()
        sleep(1)
        let next = onScreenPhoto(app)
        XCTAssertNotNil(next); XCTAssertNotEqual(next, shown, "Swiping still pages.")
        app.swipeRight()
        sleep(1)
        XCTAssertEqual(onScreenPhoto(app), shown, "Swiping back returns to the same photo, not one far away.")
        app.buttons["Close"].tap()
        XCTAssertTrue(app.textFields["library.search"].waitForExistence(timeout: 5))
        sleep(1)
        XCTAssertLessThan(window.frame.width, window.frame.height, "Closing the viewer turns the app back upright.")
    }
    /// The photo filling the viewer, by its asset: file names repeat across the fixture's months.
    @MainActor private func onScreenPhoto(_ app: XCUIApplication) -> String? {
        let photos = app.scrollViews.matching(NSPredicate(format: "identifier BEGINSWITH 'viewer.photo.'"))
        return (0..<photos.count).map { photos.element(boundBy: $0) }.first { $0.isHittable }?.identifier
    }
    @MainActor func testViewerCloseAllowsOpeningAnotherPhoto() {
        let app = launch()
        let grid = app.collectionViews["library.grid"]
        XCTAssertTrue(grid.cells.element(boundBy: 1).waitForExistence(timeout: 15))
        for index in [0, 1] {
            // The first row extends behind system chrome. Tap the photo's
            // exposed lower edge rather than the Dynamic Island at its center.
            grid.cells.element(boundBy: index).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88)).tap()
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
        tapPhoto(grid.cells.firstMatch)
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
        tapPhoto(grid.cells.element(boundBy: 1))
        XCTAssertTrue(app.buttons["Photo actions"].waitForExistence(timeout: 10))
    }
    @MainActor func testDarkGlobeSupportsDragAndPinchWithoutBlockingLibrary() {
        let app = launch(appearance: "dark")
        capture(app, "Library — dark native glass")
        openShelves(app); app.buttons["Places"].tap()
        let globe = app.otherElements["Interactive Earth"]
        XCTAssertTrue(globe.waitForExistence(timeout: 15))
        globe.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: globe.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.55)))
        globe.pinch(withScale: 1.3, velocity: 0.6)
        XCTAssertFalse(app.buttons["Clear filters"].exists,
                       "Rotating and zooming the Earth must not accidentally select a location pin.")
        capture(app, "Places — dark Earth after drag and pinch")
        closeGlobe(app)
        XCTAssertTrue(app.textFields["library.search"].isHittable)
        pressPhoto(app.collectionViews["library.grid"].cells.firstMatch)
        XCTAssertTrue(app.staticTexts["1 selected"].waitForExistence(timeout: 5))
    }
    @MainActor func testGlobePhotoPinFiltersFeedAndDragRotatesEarth() {
        let app = launch()
        openShelves(app); app.buttons["Places"].tap()
        let earth = app.otherElements["Interactive Earth"]
        XCTAssertTrue(earth.waitForExistence(timeout: 15))
        let amsterdam = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Amsterdam,")).firstMatch
        XCTAssertTrue(amsterdam.waitForExistence(timeout: 10), "Photo pins must be accessible controls.")
        requireHittable(amsterdam, in: app)
        amsterdam.tap()
        let clear = app.buttons["Clear filters"]
        XCTAssertTrue(clear.waitForExistence(timeout: 10), "Tapping the pin must filter the existing feed.")
        XCTAssertTrue(app.collectionViews["library.grid"].exists)
        XCTAssertTrue(earth.exists)
        clear.tap()
        requireHittable(amsterdam, in: app)
        let before = amsterdam.frame
        amsterdam.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: earth.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        XCTAssertFalse(clear.exists, "Dragging a pin must rotate the Earth, without selecting its location.")
        if amsterdam.exists {
            XCTAssertGreaterThan(hypot(amsterdam.frame.midX - before.midX, amsterdam.frame.midY - before.midY), 5,
                                 "The Earth must actually move under the gesture.")
        }
        capture(app, "Places — photo pin selection and actual rotation")
    }
    @MainActor func testAccessibilityTextKeepsDayHeadersAndLibraryControlsTappable() {
        let app = launch(extraArguments: ["-timelineGrouping", "day", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        requireHittable(app.buttons["library.shelves"], in: app)
        let grid = app.collectionViews["library.grid"]
        let dayHeader = app.descendants(matching: .any).matching(identifier: "library.dayHeader").firstMatch
        XCTAssertTrue(dayHeader.waitForExistence(timeout: 15))
        XCTAssertTrue(dayHeader.isHittable)
        XCTAssertLessThan(dayHeader.frame.minY, grid.cells.firstMatch.frame.minY)
        tapPhoto(grid.cells.firstMatch)
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10))
        app.buttons["Close"].tap()
        requireHittable(app.buttons["library.shelves"], in: app)
        let heading = app.staticTexts["library.heading"]
        XCTAssertTrue(heading.exists, "The month stays readable to VoiceOver while its stamp is faded out.")
        XCTAssertEqual(heading.label, "December 2026")
        capture(app, "Library — accessibility text")
        openShelves(app)
        let places = app.buttons["Places"]
        requireHittable(places, in: app)
        places.tap()
        XCTAssertTrue(app.otherElements["Interactive Earth"].waitForExistence(timeout: 15))
        requireHittable(app.buttons["Close globe"], in: app)
        capture(app, "Places — accessibility text")
        closeGlobe(app)
        requireHittable(app.textFields["library.search"], in: app)
        pressPhoto(grid.cells.firstMatch)
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
