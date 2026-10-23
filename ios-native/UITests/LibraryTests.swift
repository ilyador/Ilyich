import XCTest
import UIKit

final class LibraryTests: XCTestCase {
    /// The fixture's Maya, as her filter pill is named (N6).
    private static let mayaPill = "library.pill.person-00000000-0000-4000-8000-000000000002"
    /// Lifting the finger closes the shelves; most tests keep them out so they can tap rows.
    @MainActor private func launch(appearance: String = "light", extraArguments: [String] = [], shelvesStayOpen: Bool = true) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-library", "-appearance", appearance]
            + (shelvesStayOpen ? ["--ui-testing-shelves-stay-open"] : []) + extraArguments
        // A run can try a fixture change on a server of its own (TEST_RUNNER_ILYICH_FIXTURE_PORT).
        if let port = ProcessInfo.processInfo.environment["ILYICH_FIXTURE_PORT"] { app.launchArguments += ["--ui-testing-fixture-port", port] }
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
    /// Whether a cell shows a fixture photo itself. Each carries a yellow sun; the sketch drawn
    /// before the photo arrives is a blue-green blur without one, and chromatic enough that
    /// `hasRenderedPhoto` cannot tell the two apart.
    @MainActor private func showsPhotoPixels(_ cell: XCUIElement) -> Bool {
        guard let image = cell.screenshot().image.cgImage else { return false }
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard rendered else { return false }
        return stride(from: 0, to: pixels.count, by: 4).contains { i in pixels[i] > 215 && pixels[i + 1] > 185 && pixels[i + 2] < 185 }
    }
    /// Whether a photo mid-screen shows its own pixels within `timeout`.
    @MainActor private func waitForPhotoPixels(in grid: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let candidates = grid.cells.allElementsBoundByIndex.filter { $0.frame.minY > 200 && $0.frame.maxY < 640 }
            if candidates.prefix(6).contains(where: showsPhotoPixels) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return false
    }
    /// Drags the rail open and down to `fraction` of the screen, holding until the photos have
    /// followed the finger, then lets go.
    @MainActor private func jumpOnRail(_ app: XCUIApplication, to fraction: Double) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.86, dy: fraction)),
                   withVelocity: .default, thenHoldForDuration: 0.8)
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
    @MainActor func testDraggingSidewaysWhileSelectingSelectsARangeAndAgainDeselectsIt() {
        let app = launch()
        let grid = app.collectionViews["library.grid"]
        XCTAssertTrue(grid.cells.element(boundBy: 1).waitForExistence(timeout: 15))
        pressPhoto(grid.cells.element(boundBy: 1))
        XCTAssertTrue(app.staticTexts["1 selected"].waitForExistence(timeout: 5))
        // Two full rows in the middle of the screen, in reading order.
        let height = app.frame.height
        let cells = grid.cells.allElementsBoundByIndex.map(\.frame)
            .filter { $0.midY > height * 0.35 && $0.midY < height * 0.7 }
        let rows = Dictionary(grouping: cells) { Int($0.minY.rounded()) }.sorted { $0.key < $1.key }.map { $0.value.sorted { $0.minX < $1.minX } }
        guard rows.count >= 2 else { return XCTFail("Two rows of photos should fill the middle of the screen.") }
        let columns = rows[0].count
        XCTAssertGreaterThanOrEqual(columns, 3)
        func point(_ frame: CGRect) -> XCUICoordinate {
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY))
        }
        // From the first photo of one row to the third of the next: mostly sideways, and every
        // photo between is selected, not only those the finger crossed.
        let start = point(rows[0][0]), end = point(rows[1][2])
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(app.staticTexts["\(1 + columns + 3) selected"].waitForExistence(timeout: 5),
                      "A sideways drag selects the range from the first photo to the one under the finger.")
        capture(app, "Selection — dragged across a range")
        // Starting on a selected photo deselects instead.
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(app.staticTexts["1 selected"].waitForExistence(timeout: 5),
                      "A drag that starts on a selected photo deselects the range.")
        // A vertical drag still scrolls and selects nothing.
        let first = grid.cells.allElementsBoundByIndex.first { $0.frame == rows[0][0] }
        let label = first?.label ?? ""
        XCTAssertFalse(label.isEmpty)
        grid.swipeUp()
        XCTAssertTrue(app.staticTexts["1 selected"].exists, "Scrolling while selecting changes nothing.")
        let moved = grid.cells.matching(NSPredicate(format: "label == %@", label)).firstMatch
        XCTAssertTrue(!moved.exists || moved.frame.minY < rows[0][0].minY - 40, "A vertical drag scrolls the grid.")
    }
    /// Selecting the month under the viewport selects every photo of it, read through the feed,
    /// not only the photos the screen holds; deselecting it takes them all out again (F6).
    @MainActor func testSelectingTheMonthSelectsEveryPhotoOfItNotOnlyThoseOnScreen() {
        let app = launch()
        let grid = app.collectionViews["library.grid"]
        XCTAssertTrue(grid.cells.element(boundBy: 1).waitForExistence(timeout: 15))
        pressPhoto(grid.cells.element(boundBy: 1))
        XCTAssertTrue(app.staticTexts["1 selected"].waitForExistence(timeout: 5))
        XCTAssertLessThan(grid.cells.count, 100, "The newest month holds more photos than the screen shows.")
        // A Menu's label holds a button of its own over the same frame, so XCUITest never
        // reports the labelled one hittable; it is tapped once it is there.
        let month = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Selection for")).firstMatch
        XCTAssertTrue(month.waitForExistence(timeout: 5)); month.tap()
        let select = app.buttons["Select this month"]
        XCTAssertTrue(select.waitForExistence(timeout: 5)); select.tap()
        XCTAssertTrue(app.staticTexts["100 selected"].waitForExistence(timeout: 10), "The whole month is selected.")
        capture(app, "Selection — the whole month")
        XCTAssertTrue(month.waitForExistence(timeout: 5)); month.tap()
        let deselect = app.buttons["Deselect this month"]
        XCTAssertTrue(deselect.waitForExistence(timeout: 5)); deselect.tap()
        XCTAssertTrue(app.staticTexts["0 selected"].waitForExistence(timeout: 10), "Deselecting the month takes all of it out.")
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
    /// With the network gone, rail jumps to months looked at before show the thumbnails stored
    /// then, and a month never looked at shows no photo (T3).
    @MainActor func testOfflineRandomRailJumpsShowStoredThumbnails() {
        let app = launch()
        let grid = app.collectionViews["library.grid"]
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15))
        let heading = app.staticTexts["library.heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        // Online, two months along the rail are looked at, so their thumbnails are stored.
        var months: [String] = []
        for fraction in [0.31, 0.68] {
            jumpOnRail(app, to: fraction)
            XCTAssertTrue(waitForPhotoPixels(in: grid, timeout: 15), "Online, the month at \(fraction) shows its photos.")
            months.append(heading.label)
        }
        XCTAssertNotEqual(months[0], months[1], "The two jumps land on different months.")
        capture(app, "Online rail jumps — downloaded thumbnails")
        // The store writes on its own queue; give it a moment before the app goes.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        app.terminate()

        app.launchArguments.append("--ui-testing-offline-media")
        app.launch()
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15))
        for (fraction, month) in [(0.68, months[1]), (0.31, months[0])] {
            jumpOnRail(app, to: fraction)
            XCTAssertTrue(waitForPhotoPixels(in: grid, timeout: 10), "Offline, the month at \(fraction) shows the thumbnails it stored.")
            XCTAssertEqual(heading.label, month, "The jump lands on the month looked at online.")
        }
        capture(app, "Offline rail jumps — stored thumbnails")
        jumpOnRail(app, to: 0.5)
        XCTAssertFalse(waitForPhotoPixels(in: grid, timeout: 3), "Offline, a month never looked at has no photo to show.")
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
        // The viewer zooms back into its cell; the library takes touches again once it has.
        requireHittable(app.textFields["library.search"], in: app)

        let heading = app.staticTexts["library.heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        let initialMonth = heading.label
        let rightEdge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.91, dy: 0.72))
        let scrubTarget = app.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.22))
        // The photos follow the finger once the rail has opened, so the finger stays down until it has.
        rightEdge.press(forDuration: 0.05, thenDragTo: scrubTarget, withVelocity: .default, thenHoldForDuration: 1)
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
        // Twelve rows do not fit; holding near the bottom brings the rest.
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
        // The viewer's settings have their own row rather than sitting under Appearance.
        openShelves(app)
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["Photo and video viewer"].waitForExistence(timeout: 5))
        app.buttons["Photo and video viewer"].tap()
        XCTAssertTrue(app.switches["Play automatically"].waitForExistence(timeout: 5), "Videos can be set to play when they open.")
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
    /// Read-only mode turns the viewer's changes off the moment it comes on, and back on the
    /// moment it goes off. The viewer is presented by UIKit, outside the app's environment.
    @MainActor func testReadOnlyModeTurnsChangesOffAndBackOnAtOnce() {
        let app = launch()
        let grid = app.collectionViews["library.grid"]
        XCTAssertTrue(grid.cells.element(boundBy: 1).waitForExistence(timeout: 15))
        func setReadOnly(_ on: Bool) {
            openShelves(app)
            app.buttons["Settings"].tap()
            XCTAssertTrue(app.buttons["Read-only mode"].waitForExistence(timeout: 5))
            app.buttons["Read-only mode"].tap()
            let toggle = app.switches["Read-only mode"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            // The switch itself sits at the row's trailing end.
            if (toggle.value as? String == "1") != on { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
            let set = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", on ? "1" : "0"), object: toggle)
            XCTAssertEqual(XCTWaiter.wait(for: [set], timeout: 5), .completed, "Read-only mode is \(on ? "on" : "off").")
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: toggle)
            XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed, "The toggle is usable again once uploads have followed.")
            app.buttons["Done"].tap()
        }
        func viewerAllowsDeleting() -> Bool {
            tapPhoto(grid.cells.element(boundBy: 1))
            let delete = app.buttons["Delete"]
            XCTAssertTrue(delete.waitForExistence(timeout: 10))
            let enabled = delete.isEnabled
            app.buttons["Close"].tap()
            XCTAssertTrue(app.textFields["library.search"].waitForExistence(timeout: 5))
            return enabled
        }
        XCTAssertTrue(viewerAllowsDeleting(), "Changes start allowed.")
        setReadOnly(true)
        XCTAssertFalse(viewerAllowsDeleting(), "Read-only mode turns the viewer's changes off at once.")
        setReadOnly(false)
        XCTAssertTrue(viewerAllowsDeleting(), "Turning it off turns them back on at once.")
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
        // Holding at the left edge while its glow builds goes back a level; at the top level the
        // edge folds the shelves away.
        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.4))
        middle.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.4)),
                     withVelocity: .default, thenHoldForDuration: 0.8)
        XCTAssertTrue(app.buttons["People"].waitForExistence(timeout: 5), "Holding at the left edge goes back to the top level.")
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
        let title = app.otherElements["library.filterPills"].staticTexts["Coast"]
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
    /// Leaving an album someone else shared with you, from Sharing over its feed, closes Sharing,
    /// clears the filter back to the library and takes the album off the shelves (N4).
    @MainActor func testLeavingASharedAlbumClosesSharingAndClearsTheFilter() throws {
        let app = launch(extraArguments: ["--ui-testing-mutable-library"])
        openShelves(app); app.buttons["Albums"].tap()
        let lagoon = app.buttons["Lagoon"]
        guard lagoon.waitForExistence(timeout: 10) else {
            throw XCTSkip("Needs the N4 UI fixture, whose mutable sessions have an album shared with the fixture's user: restart scripts/ui-fixture-server.py.")
        }
        lagoon.tap()
        XCTAssertTrue(app.buttons["library.shelves"].waitForExistence(timeout: 5), "Tapping an album puts the shelves away.")
        let tag = app.otherElements["library.filterPills"]
        XCTAssertTrue(tag.staticTexts["Lagoon"].waitForExistence(timeout: 5), "The feed shows the album.")
        let share = app.buttons["library.shareAlbum"]
        XCTAssertTrue(share.waitForExistence(timeout: 5)); share.tap()
        app.buttons["Share with people"].tap()
        let sharing = app.navigationBars["Sharing"]
        XCTAssertTrue(sharing.waitForExistence(timeout: 5))
        let leave = app.buttons["Leave album"]
        XCTAssertTrue(leave.waitForExistence(timeout: 10), "A member who doesn't own the album can leave it.")
        capture(app, "Sharing — an album shared with you")
        leave.tap()
        XCTAssertTrue(app.staticTexts["Leave this shared album?"].waitForExistence(timeout: 5), "Leaving asks first.")
        let confirmations = app.buttons.matching(NSPredicate(format: "label == %@", "Leave album"))
        let asked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count >= 2"), object: confirmations)
        if XCTWaiter.wait(for: [asked], timeout: 5) != .completed { capture(app, "Leave question") }
        // The question's own button follows the list's.
        confirmations.element(boundBy: confirmations.count - 1).tap()

        XCTAssertTrue(sharing.waitForNonExistence(timeout: 10), "Leaving closes Sharing.")
        XCTAssertTrue(tag.waitForNonExistence(timeout: 5), "The filter clears back to the library.")
        XCTAssertTrue(app.textFields["library.search"].waitForExistence(timeout: 5))
        capture(app, "Library — after leaving a shared album")
        openShelves(app); app.buttons["Albums"].tap()
        XCTAssertTrue(app.buttons["Coast"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Lagoon"].exists, "The album left goes from the shelves.")
    }
    /// An album renamed in Manage albums shows its new name on the Albums shelf at once (N4).
    @MainActor func testRenamingAnAlbumShowsOnTheShelfAtOnce() throws {
        let app = launch(extraArguments: ["--ui-testing-mutable-library"])
        openShelves(app); app.buttons["Albums"].tap()
        guard app.buttons["Lagoon"].waitForExistence(timeout: 10) else {
            throw XCTSkip("Needs the N4 UI fixture, which answers an album's details in mutable sessions: restart scripts/ui-fixture-server.py.")
        }
        app.buttons["Manage albums"].tap()
        XCTAssertTrue(app.navigationBars["Albums"].waitForExistence(timeout: 5))
        let coast = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Coast")).firstMatch
        XCTAssertTrue(coast.waitForExistence(timeout: 10))
        coast.press(forDuration: 1.0)
        let details = app.buttons["Album details"]
        XCTAssertTrue(details.waitForExistence(timeout: 5), "An album's menu offers its details.")
        details.tap()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText(" at dusk")
        app.navigationBars["Album details"].buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Album details"].waitForNonExistence(timeout: 10), "Saving closes the details.")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Coast at dusk")).firstMatch.waitForExistence(timeout: 5),
                      "The albums list shows the new name.")
        app.navigationBars["Albums"].buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Albums"].waitForNonExistence(timeout: 5))
        openShelves(app); app.buttons["Albums"].tap()
        XCTAssertTrue(app.buttons["Coast at dusk"].waitForExistence(timeout: 5), "The shelf shows the new name at once.")
        XCTAssertFalse(app.buttons["Coast"].exists)
        capture(app, "Shelf — an album renamed")
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
        // The selection's own Done, also labelled Done, stays under the sheet and is never
        // hittable, so the sheet's Done is found in its navigation bar.
        requireHittable(app.navigationBars["2 selected"].buttons["Done"], in: app)
        capture(app, "Selection — two photos saved to Photos")
    }
    @MainActor func testSearchContinuesAnEmptyVerifiedPageAndCanClear() {
        let app = launch()
        let search = app.textFields["library.search"]
        search.tap()
        // The AI check starts off; this search is the verified one.
        let check = app.switches["search.aiCheck"]
        requireHittable(check, in: app); check.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        search.typeText("me wearing a red hat in Amsterdam\n")
        XCTAssertTrue(app.staticTexts["9 matches"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Visually checked"].waitForExistence(timeout: 5))
        let firstMatch = app.collectionViews["library.grid"].cells.element(boundBy: 0)
        // N6: the search typed is a pill of its own, its X ending it.
        XCTAssertGreaterThanOrEqual(firstMatch.frame.minY, app.buttons["library.pill.search.remove"].frame.maxY,
                                    "The first result must start below the header, not under its blur.")
        capture(app, "Search — verified continuation")
        app.buttons["library.pill.search.remove"].tap()
        XCTAssertTrue(app.staticTexts["December 2026"].waitForExistence(timeout: 10))
    }
    /// F7: under the bar, the AI check and More; More's mode and filters show as chips that
    /// clear one by one, and the mode survives a new search.
    @MainActor func testSearchSwitchMoreAndChipsWorkAsInImmich() {
        let app = launch(appearance: "dark")
        let search = app.textFields["library.search"]
        requireHittable(search, in: app)
        XCTAssertFalse(app.buttons["search.more"].exists, "At rest the library shows only the bar.")
        search.tap()
        let check = app.switches["search.aiCheck"]
        requireHittable(check, in: app)
        XCTAssertEqual(check.value as? String, "0", "The AI check starts off.")
        XCTAssertTrue(app.buttons["search.more"].exists)
        capture(app, "Search — typing, AI check off and More")
        search.typeText("red hat\n")
        XCTAssertTrue(app.staticTexts["9 matches"].waitForExistence(timeout: 20))
        // The fixture reports every search as verified, but the card shows only for one sent with
        // the check; SearchChoicesTests pins the verify field itself, which the fixture ignores.
        XCTAssertFalse(app.staticTexts["Visually checked"].exists, "With the AI check off, nothing is checked.")
        requireHittable(check, in: app); check.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["Visually checked"].waitForExistence(timeout: 20), "Turning it on runs the checked search.")
        capture(app, "Search — AI check on")

        app.buttons["search.more"].tap()
        XCTAssertTrue(app.navigationBars["Search options"].waitForExistence(timeout: 5))
        let mode = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Search mode")).firstMatch
        XCTAssertTrue(mode.waitForExistence(timeout: 10)); mode.tap()
        let filename = app.buttons["Filename"]
        XCTAssertTrue(filename.waitForExistence(timeout: 5)); filename.tap()
        let favorites = app.switches["Favorites only"]
        for _ in 0..<6 where !favorites.isHittable { app.collectionViews.firstMatch.swipeUp() }
        requireHittable(favorites, in: app)
        favorites.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        capture(app, "Search options — Filename, favorites")
        app.navigationBars["Search options"].buttons["Apply"].tap()

        let modeChip = app.buttons["search.chip.mode"], favoritesChip = app.buttons["search.chip.favorites"]
        XCTAssertTrue(modeChip.waitForExistence(timeout: 10), "The mode shows as a chip.")
        XCTAssertTrue(favoritesChip.exists, "So does the filter.")
        XCTAssertFalse(check.exists, "The AI check belongs to Photo content.")
        XCTAssertTrue(app.staticTexts["9 matches"].waitForExistence(timeout: 20))
        capture(app, "Search — Filename and Favorites chips")

        // A new search keeps the mode.
        app.buttons["Clear search"].tap()
        search.tap(); search.typeText("beach\n")
        XCTAssertTrue(app.staticTexts["9 matches"].waitForExistence(timeout: 20))
        XCTAssertTrue(modeChip.exists, "The mode survives a new search.")

        requireHittable(favoritesChip, in: app); favoritesChip.tap()
        XCTAssertTrue(favoritesChip.waitForNonExistence(timeout: 5), "A chip clears on its own.")
        XCTAssertTrue(modeChip.exists)
        requireHittable(modeChip, in: app); modeChip.tap()
        XCTAssertTrue(modeChip.waitForNonExistence(timeout: 5))
        XCTAssertTrue(check.waitForExistence(timeout: 5), "Photo content brings the AI check back.")
        XCTAssertEqual(check.value as? String, "1", "Still on, as it was left.")
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
        let pills = app.otherElements["library.filterPills"]
        XCTAssertTrue(app.buttons["library.shelves"].waitForExistence(timeout: 5), "Tapping a person puts the shelves away.")
        XCTAssertTrue(app.buttons[Self.mayaPill + ".remove"].waitForExistence(timeout: 10), "The chosen person should sit at the top as a pill, with its own X.")
        pills.staticTexts["Maya"].tap()
        XCTAssertTrue(app.buttons["Manage people"].waitForExistence(timeout: 5), "The pill brings back its people.")
        XCTAssertTrue(app.buttons["Maya"].exists)
        tapBesideShelves(app)
        let clearPeople = app.buttons[Self.mayaPill + ".remove"]
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
        XCTAssertFalse(app.buttons[Self.mayaPill + ".remove"].exists, "The person's X removed the person.")
        let clearPlace = app.buttons["library.pill.place.remove"]
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
        XCTAssertTrue(app.buttons["library.pill.lightroom.remove"].waitForExistence(timeout: 10))
        XCTAssertTrue(pills.staticTexts["Lightroom"].exists)
        XCTAssertFalse(app.buttons["library.pill.place.remove"].exists, "The place's X removed the place.")
        XCTAssertTrue(app.descendants(matching: .any)["library.timeRail"].waitForExistence(timeout: 10),
                      "Lightroom is a timeline of every developed photo, with its rail, as a person is.")
        XCTAssertTrue(app.buttons["library.shelves"].waitForExistence(timeout: 5), "Tapping a filter puts the shelves away.")
        XCTAssertEqual(app.collectionViews.matching(identifier: "library.grid").count, 1,
                       "Shelf filters must not open a second photo collection grid.")
    }
    /// N6: a place then a person shows that person's photos in that place, and each pill's X
    /// removes only its own layer.
    @MainActor func testAPlaceThenAPersonShowsTheirIntersectionAndAPillRemovesOnlyItsLayer() throws {
        let app = launch()
        let grid = app.collectionViews["library.grid"]
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15))
        openShelves(app); app.buttons["Places"].tap()
        XCTAssertTrue(app.otherElements["Interactive Earth"].waitForExistence(timeout: 15))
        let allLocations = app.buttons["All locations"]
        requireHittable(allLocations, in: app); allLocations.tap()
        let locations = app.descendants(matching: .any).matching(identifier: "places.list").firstMatch
        let amsterdam = locations.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Amsterdam")).firstMatch
        XCTAssertTrue(amsterdam.waitForExistence(timeout: 10))
        guard amsterdam.label.contains("2 items") else {
            throw XCTSkip("Needs the N6 UI fixture, whose Amsterdam holds a photo and a clip: restart scripts/ui-fixture-server.py.")
        }
        requireHittable(amsterdam, in: app); amsterdam.tap()
        // A pill is found by its X, which spans its height at its trailing end.
        let place = app.buttons["library.pill.place.remove"]
        XCTAssertTrue(place.waitForExistence(timeout: 10), "The place sits at the top as a pill.")
        XCTAssertTrue(waitForCells(grid, count: 2), "Amsterdam holds a photo and a clip.")
        closeGlobe(app)

        openShelves(app); app.buttons["People"].tap()
        let maya = app.buttons["Maya"]
        XCTAssertTrue(maya.waitForExistence(timeout: 10)); maya.tap()
        let person = app.buttons[Self.mayaPill + ".remove"]
        XCTAssertTrue(person.waitForExistence(timeout: 10), "The person joins the place as a second pill.")
        XCTAssertTrue(place.exists, "Choosing a person keeps the place.")
        XCTAssertTrue(waitForCells(grid, count: 1), "A place then a person shows only that person's photos there.")
        XCTAssertEqual(person.frame.midY, place.frame.midY, accuracy: 2, "The pills share a line.")
        XCTAssertGreaterThan(person.frame.minX, place.frame.maxX, "The person's pill follows the place's.")
        capture(app, "Filters — a place then a person")

        requireHittable(place, in: app); place.tap()
        XCTAssertTrue(place.waitForNonExistence(timeout: 5), "The place's X removes only the place.")
        XCTAssertTrue(person.exists, "The person stays.")
        XCTAssertTrue(waitForCells(grid, atLeast: 8), "Maya's photos everywhere show again.")
        requireHittable(person, in: app); person.tap()
        XCTAssertTrue(person.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["library.filterPills"].exists, "With no filter left there are no pills.")
    }

    /// N6: the Clear row at the top of the shelves, above People, removes every filter and lowers
    /// the Earth.
    @MainActor func testClearEmptiesTheFiltersAndLowersTheEarth() {
        let app = launch()
        openShelves(app)
        XCTAssertFalse(app.buttons["Clear"].exists, "With no filter the shelves offer no Clear.")
        app.buttons["More"].tap()
        let favorites = app.buttons["Favorites"]
        XCTAssertTrue(favorites.waitForExistence(timeout: 5)); favorites.tap()
        XCTAssertTrue(app.buttons["library.pill.favorites.remove"].waitForExistence(timeout: 10))
        openShelves(app); app.buttons["Places"].tap()
        let earth = app.otherElements["Interactive Earth"]
        XCTAssertTrue(earth.waitForExistence(timeout: 15))
        let amsterdam = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Amsterdam,")).firstMatch
        XCTAssertTrue(amsterdam.waitForExistence(timeout: 10))
        requireHittable(amsterdam, in: app); amsterdam.tap()
        XCTAssertTrue(app.buttons["library.pill.place.remove"].waitForExistence(timeout: 10), "The place joins Favorites.")
        XCTAssertTrue(app.buttons["library.pill.favorites.remove"].exists)
        openShelves(app)
        let clear = app.buttons["Clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5), "With filters the shelves start with Clear.")
        XCTAssertLessThan(clear.frame.midY, app.buttons["People"].frame.midY, "Clear sits above People.")
        capture(app, "Shelves — Clear above People")
        clear.tap()
        XCTAssertTrue(app.buttons["library.shelves"].waitForExistence(timeout: 5), "Clear puts the shelves away.")
        XCTAssertTrue(app.otherElements["library.filterPills"].waitForNonExistence(timeout: 5), "Clear removes every filter.")
        XCTAssertTrue(earth.waitForNonExistence(timeout: 5), "Clear lowers the Earth.")
        XCTAssertTrue(app.textFields["library.search"].waitForExistence(timeout: 5))
    }

    /// N6: a row chosen on the shelves rises into its pill, in the next place along the pills, and
    /// becomes it. The rise itself is checked on a recording; here, where it lands.
    @MainActor func testAChosenRowRisesIntoTheNextPill() {
        let app = launch(appearance: "dark")
        openShelves(app); app.buttons["People"].tap()
        let maya = app.buttons["Maya"]
        XCTAssertTrue(maya.waitForExistence(timeout: 10)); maya.tap()
        let person = app.buttons[Self.mayaPill + ".remove"]
        XCTAssertTrue(person.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["library.shelves"].waitForExistence(timeout: 5))
        openShelves(app); app.buttons["More"].tap()
        let favorites = app.buttons["Favorites"]
        XCTAssertTrue(favorites.waitForExistence(timeout: 5))
        favorites.tap()
        // Frames while the row rises, beside the recording.
        for step in 0..<5 {
            let frame = XCTAttachment(screenshot: app.screenshot()); frame.name = "Rise \(step)"; frame.lifetime = .keepAlways; add(frame)
        }
        // A pill is found by its X, which spans its height at its trailing end.
        let pill = app.buttons["library.pill.favorites.remove"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "The row becomes its pill.")
        XCTAssertEqual(pill.frame.midY, person.frame.midY, accuracy: 2, "It lands in the next place along the pills.")
        XCTAssertGreaterThan(pill.frame.minX, person.frame.maxX)
        capture(app, "Rise — landed beside the person's pill")
    }

    /// Waits until the grid shows `count` photos, or at least `minimum`.
    @MainActor private func waitForCells(_ grid: XCUIElement, count: Int? = nil, atLeast minimum: Int? = nil, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let cells = grid.cells.count
            if let count, cells == count { return true }
            if let minimum, cells >= minimum { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return false
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
    /// Opens a link the way a widget or another app does: through the system, to the app already
    /// running. (XCUIApplication.open relaunches the app instead.) iOS may ask first.
    @MainActor private func openLink(_ link: String) {
        XCUIDevice.shared.system.open(URL(string: link)!)
        let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if open.waitForExistence(timeout: 2) { open.tap() }
    }
    /// A widget's link opens its photo even with a sheet open: the sheet closes, then the photo
    /// opens over the feed as it was, and the library presents as before once it closes.
    @MainActor func testDeepLinkOpensAssetOverOpenSheet() {
        let app = launch()
        // An album in the feed shows the app was not started again by the link.
        openShelves(app); app.buttons["Albums"].tap()
        let coast = app.buttons["Coast"]
        XCTAssertTrue(coast.waitForExistence(timeout: 5)); coast.tap()
        let filter = app.otherElements["library.filterPills"]
        XCTAssertTrue(filter.staticTexts["Coast"].waitForExistence(timeout: 10))
        // More sits under the search bar while typing.
        app.textFields["library.search"].tap()
        let options = app.buttons["search.more"]
        requireHittable(options, in: app); options.tap()
        XCTAssertTrue(app.navigationBars["Search options"].waitForExistence(timeout: 5))
        let id = "00000000-0000-4000-8000-00000000a5e7"
        openLink("immich://asset?id=\(id)")
        XCTAssertTrue(app.descendants(matching: .any)["viewer.photo.\(id)"].waitForExistence(timeout: 15), "The link's photo opens.")
        XCTAssertFalse(app.navigationBars["Search options"].exists, "The sheet closed first.")
        capture(app, "Link — photo opened over a sheet")
        app.buttons["Close"].tap()
        requireHittable(app.textFields["library.search"], in: app)
        XCTAssertTrue(filter.staticTexts["Coast"].exists, "The feed is as it was: the link opened the photo in the running app.")
        tapPhoto(app.collectionViews["library.grid"].cells.element(boundBy: 1))
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10), "A photo from the grid still opens afterwards.")
    }
    /// Each link replaces whatever is open: the memories, Shared files, an album or a person in
    /// the feed, and an album's comments and likes.
    @MainActor func testLinksOpenMemoriesSharedFilesAlbumsPeopleAndActivity() {
        let app = launch()
        // The shelves' albums and people, which album and person links use, have loaded.
        openShelves(app); app.buttons["Albums"].tap()
        XCTAssertTrue(app.buttons["Coast"].waitForExistence(timeout: 10))
        tapBesideShelves(app)

        openLink("immich://memory")
        XCTAssertTrue(app.navigationBars["On this day"].waitForExistence(timeout: 10), "A memory link opens the memories.")
        openLink("immich://share")
        XCTAssertTrue(app.navigationBars["Shared files"].waitForExistence(timeout: 10), "The share extension's link opens Shared files.")
        XCTAssertFalse(app.navigationBars["On this day"].exists, "Shared files replaced the memories.")
        openLink("immich://album?id=00000000-0000-4000-8000-000000000003")
        let filter = app.otherElements["library.filterPills"]
        XCTAssertTrue(filter.staticTexts["Coast"].waitForExistence(timeout: 10), "An album link shows the album in the feed.")
        XCTAssertFalse(app.navigationBars["Shared files"].exists, "Shared files closed first.")
        openLink("immich://person?id=00000000-0000-4000-8000-000000000002")
        XCTAssertTrue(filter.staticTexts["Maya"].waitForExistence(timeout: 10), "A person link shows the person in the feed.")
        XCTAssertFalse(filter.staticTexts["Coast"].exists, "A link shows its person alone, as before.")
        // A photo linked inside an album keeps the album's actions, though the feed shows a person.
        let linked = "00000000-0000-4000-8000-00000000a1b2"
        openLink("immich://asset?id=\(linked)&albumId=00000000-0000-4000-8000-000000000003")
        let photo = app.descendants(matching: .any)["viewer.photo.\(linked)"]
        XCTAssertTrue(photo.waitForExistence(timeout: 15), "A photo linked in an album opens.")
        let actions = app.buttons["Photo actions"]
        requireHittable(actions, in: app); actions.tap()
        let comments = app.buttons["Comments and likes"]
        XCTAssertTrue(comments.waitForExistence(timeout: 5), "It keeps the album's actions.")
        comments.tap()
        XCTAssertTrue(app.navigationBars["Comments and likes"].waitForExistence(timeout: 10), "The photo's comments open over the viewer.")
        // An activity link closes the photo's comments and the viewer under them, then opens the album's.
        openLink("immich://activity?albumId=00000000-0000-4000-8000-000000000003")
        XCTAssertTrue(photo.waitForNonExistence(timeout: 15), "The viewer closed, with the sheet it had open.")
        XCTAssertTrue(app.navigationBars["Comments and likes"].waitForExistence(timeout: 10), "An activity link opens the album's comments and likes.")
        capture(app, "Link — album activity")
    }
    /// From a memory playing over the memories, Show in timeline closes both and takes the
    /// library to the photo's month; Open photo closes both and opens the photo.
    @MainActor func testMemoryShowInTimelineAndOpenPhotoCloseTheMemoriesFirst() {
        let app = launch()
        let heading = app.staticTexts["library.heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        func playFirstMemory() {
            openLink("immich://memory")
            XCTAssertTrue(app.navigationBars["On this day"].waitForExistence(timeout: 10))
            let play = app.buttons["Play memory"].firstMatch
            requireHittable(play, in: app); play.tap()
            // A Menu's label holds a button of its own over the same frame, so XCUITest never
            // reports the labelled one hittable; it is tapped once it is there.
            let actions = app.buttons["Memory photo actions"]
            XCTAssertTrue(actions.waitForExistence(timeout: 10)); actions.tap()
            XCTAssertTrue(app.buttons["Show in timeline"].waitForExistence(timeout: 5))
        }
        playFirstMemory()
        app.buttons["Show in timeline"].tap()
        let june = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "June 2024"), object: heading)
        XCTAssertEqual(XCTWaiter.wait(for: [june], timeout: 15), .completed, "The library shows the memory photo's month.")
        XCTAssertFalse(app.navigationBars["On this day"].exists, "The memories closed.")
        XCTAssertFalse(app.buttons["Memory photo actions"].exists, "The player closed.")
        requireHittable(app.textFields["library.search"], in: app)
        capture(app, "Memory — shown in the timeline")

        playFirstMemory()
        app.buttons["Open photo"].tap()
        let photo = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'viewer.photo.'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 15), "The memory's photo opens in the viewer.")
        XCTAssertFalse(app.navigationBars["On this day"].exists, "The memories closed first.")
        app.buttons["Close"].tap()
        requireHittable(app.textFields["library.search"], in: app)

        // A widget tap while a memory plays closes the player and the memories, then opens its photo.
        playFirstMemory()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        let id = "00000000-0000-4000-8000-00000000b0b0"
        openLink("immich://asset?id=\(id)")
        XCTAssertTrue(app.descendants(matching: .any)["viewer.photo.\(id)"].waitForExistence(timeout: 15), "The link's photo opens over the memory.")
        XCTAssertFalse(app.buttons["Memory photo actions"].exists, "The player closed.")
        XCTAssertFalse(app.navigationBars["On this day"].exists, "The memories closed.")
    }
    /// A link that starts the app opens its photo once the library is up. XCUIApplication.open
    /// launches the app afresh with the link, as a widget tap does when the app isn't running.
    @MainActor func testALinkThatStartsTheAppOpensItsPhoto() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-library", "-appearance", "light", "--ui-testing-shelves-stay-open"]
        app.terminate()
        let id = "00000000-0000-4000-8000-00000000c01d"
        app.open(URL(string: "immich://asset?id=\(id)")!)
        XCTAssertTrue(app.descendants(matching: .any)["viewer.photo.\(id)"].waitForExistence(timeout: 30), "The link's photo opens on launch.")
        capture(app, "Link — photo opened on launch")
        app.buttons["Close"].tap()
        XCTAssertTrue(app.collectionViews["library.grid"].waitForExistence(timeout: 10))
        requireHittable(app.textFields["library.search"], in: app)
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
        let grid = app.collectionViews["library.grid"]
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15))
        // The fixture's photos were all taken at one time, so they are in ID order and the clip
        // is further down the newest month.
        let video = grid.cells.matching(NSPredicate(format: "label ENDSWITH %@", ", video")).firstMatch
        let height = app.frame.height
        func placed() -> Bool { video.exists && video.frame.midY > height * 0.25 && video.frame.midY < height * 0.7 }
        for _ in 0..<12 where !placed() {
            let down = video.exists && video.frame.midY <= height * 0.25
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.4 : 0.65))
            from.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.6 : 0.4)))
        }
        XCTAssertTrue(placed(), "The newest month has a clip.")
        tapPhoto(video)
        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        // As in Photos, play, the scrubber and mute share one pill above the bottom bar.
        let mute = app.buttons["Mute"]
        XCTAssertTrue(mute.waitForExistence(timeout: 5), "A video has a mute button.")
        let play = app.buttons.matching(NSPredicate(format: "label IN %@", ["Play", "Pause"])).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5), "A video has a play button.")
        XCTAssertTrue(app.descendants(matching: .any)["Playback position"].exists, "A video has a scrubber.")
        // Play automatically is on unless it is turned off in Settings.
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 10), "A video starts playing when it opens.")
        let share = app.buttons["Share"]
        XCTAssertEqual(play.frame.midY, mute.frame.midY, accuracy: 1, "Play and mute sit in one pill.")
        XCTAssertLessThan(play.frame.maxX, mute.frame.minX)
        XCTAssertLessThan(mute.frame.maxY, share.frame.minY, "The pill sits above the bottom bar.")
        capture(app, "Viewer — video")
        // A tap on the video puts the bars and the pill away, and another brings them back.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: share)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed, "A tap hides the bars.")
        capture(app, "Viewer — video, controls hidden")
        XCTAssertFalse(mute.exists, "A tap hides the pill with the bars.")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        XCTAssertTrue(mute.waitForExistence(timeout: 5), "Another tap brings the pill back.")
        // A video can be muted from the viewer, as in Photos, and unmuted again.
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
    /// The viewer's controls sit where Photos puts them: back, the title and the actions menu along
    /// the top; Share, one group of Favorite, Info and Edit, and Delete along the bottom. A tap on
    /// the photo puts them all away and another brings them back.
    @MainActor func testViewerControlsSitWhereThePhotosAppPutsThem() {
        let app = launch()
        let grid = app.collectionViews["library.grid"]
        XCTAssertTrue(grid.cells.element(boundBy: 1).waitForExistence(timeout: 15))
        tapPhoto(grid.cells.element(boundBy: 1))
        let close = app.buttons["Close"], actions = app.buttons["Photo actions"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        let favorite = app.buttons.matching(NSPredicate(format: "label IN %@", ["Favorite", "Remove favorite"])).firstMatch
        let names = ["Share", "Favorite", "Info", "Edit", "Delete"]
        let bottom = names.map { $0 == "Favorite" ? favorite : app.buttons[$0] }
        for (name, button) in zip(names, bottom) { XCTAssertTrue(button.waitForExistence(timeout: 5), "\(name) is in the bottom bar.") }
        let screen = app.windows.firstMatch.frame
        XCTAssertEqual(close.frame.midY, actions.frame.midY, accuracy: 1, "Close and the actions menu share the top bar.")
        XCTAssertLessThan(close.frame.midX, actions.frame.midX)
        XCTAssertLessThan(close.frame.maxY, screen.height * 0.2)
        for (name, button) in zip(names, bottom) {
            XCTAssertEqual(button.frame.midY, bottom[0].frame.midY, accuracy: 1, "\(name) sits in the one bottom bar.")
        }
        XCTAssertGreaterThan(bottom[0].frame.minY, screen.height * 0.8)
        for (left, right) in zip(bottom, bottom.dropFirst()) { XCTAssertLessThan(left.frame.maxX, right.frame.minX) }
        // Favorite, Info and Edit share one capsule; Share and Delete stand apart from it.
        XCTAssertLessThan(bottom[2].frame.minX - bottom[1].frame.maxX, bottom[1].frame.minX - bottom[0].frame.maxX)
        XCTAssertLessThan(bottom[3].frame.minX - bottom[2].frame.maxX, bottom[4].frame.minX - bottom[3].frame.maxX)
        capture(app, "Viewer — photo")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed, "A tap puts the controls away.")
        XCTAssertFalse(app.buttons["Share"].exists, "A tap puts the bottom bar away too.")
        capture(app, "Viewer — photo, controls hidden")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5), "Another tap brings them back.")
    }
    /// As in Photos, a strip of thumbnails runs above the bottom bar. Tapping a thumbnail jumps to
    /// its photo, paging moves the strip along, swiping the strip scrubs through the photos, and a
    /// tap on the photo hides the strip with the bars.
    @MainActor func testThumbnailStripJumpsToPhotosAndFollowsPaging() {
        let app = launch()
        let grid = app.collectionViews["library.grid"]
        XCTAssertTrue(grid.cells.element(boundBy: 9).waitForExistence(timeout: 15))
        tapPhoto(grid.cells.element(boundBy: 9))
        let strip = app.descendants(matching: .any)["viewer.strip"]
        XCTAssertTrue(strip.waitForExistence(timeout: 10), "The viewer has a thumbnail strip.")
        func position() -> Int? { (strip.value as? String)?.split(separator: " ").first.flatMap { Int($0) } }
        func waitForPosition(_ expected: Int, _ message: String) {
            let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in position() == expected }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed, message)
        }
        guard let start = position() else { return XCTFail("The strip says which photo is shown.") }
        let shown = onScreenPhoto(app)
        XCTAssertNotNil(shown)
        XCTAssertLessThan(strip.frame.maxY, app.buttons["Share"].frame.minY, "The strip sits above the bottom bar.")
        capture(app, "Viewer — thumbnail strip")
        // Thumbnails are 21 points wide at 2-point spacing. The current one is drawn 51 points wide
        // with 3-point margins, which moves its neighbors 18 points aside: tap the third to the right.
        let middle = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width / 2, dy: strip.frame.midY))
        middle.withOffset(CGVector(dx: 3 * 23 + 18, dy: 0)).tap()
        waitForPosition(start + 3, "Tapping a thumbnail jumps to its photo.")
        XCTAssertNotEqual(onScreenPhoto(app), shown, "The pager shows the photo picked in the strip.")
        app.swipeRight()
        waitForPosition(start + 2, "Paging moves the strip along.")
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: -4 * 23, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.3)
        let scrubbed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (position() ?? 0) > start + 3 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [scrubbed], timeout: 5), .completed, "Swiping the strip scrubs through the photos.")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: strip)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed, "A tap hides the strip with the bars.")
    }
    /// As in Photos, the viewer closes into the grid cell of the photo it shows, even after paging
    /// far from the photo it opened on: the grid scrolls to that cell first. Dragging a photo down
    /// closes the viewer too.
    @MainActor func testClosingTheViewerLandsOnThePhotoItShows() {
        let app = launch()
        let grid = app.collectionViews["library.grid"]
        XCTAssertTrue(grid.cells.element(boundBy: 1).waitForExistence(timeout: 15))
        tapPhoto(grid.cells.element(boundBy: 1))
        let strip = app.descendants(matching: .any)["viewer.strip"]
        XCTAssertTrue(strip.waitForExistence(timeout: 10))
        func position() -> Int? { (strip.value as? String)?.split(separator: " ").first.flatMap { Int($0) } }
        // Seven thumbnails to the right of the middle (23 points apart, and 18 more past the wide
        // current one), six times over: far past the cells on screen.
        let jump = strip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 7 * 23 + 18, dy: 0))
        for step in 1...6 {
            jump.tap()
            let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in position() == 2 + 7 * step }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed, "The strip jumps seven photos.")
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        // Photo 44 of the newest month sits in the grid's last column, eleven rows down: off screen.
        app.buttons["Close"].tap()
        requireHittable(app.textFields["library.search"], in: app)
        capture(app, "Library — after closing on a photo far from the one opened")
        // Closing scrolled the grid to that photo and centered it: the last column's cell nearest
        // the middle of the screen opens it again.
        let lastColumn = grid.cells.allElementsBoundByIndex.filter { $0.frame.midX > grid.frame.minX + grid.frame.width * 0.75 }
        let centered = lastColumn.min { abs($0.frame.midY - app.frame.height / 2) < abs($1.frame.midY - app.frame.height / 2) }
        guard let centered else { return XCTFail("The grid shows photos after closing.") }
        centered.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(strip.waitForExistence(timeout: 10))
        XCTAssertEqual(position(), 44, "Closing lands on the photo shown, scrolled into view in the grid.")
        // A zoomed-in photo pans under a downward drag instead of closing.
        let photo = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        photo.doubleTap()
        photo.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)), withVelocity: .fast, thenHoldForDuration: 0)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(app.textFields["library.search"].exists, "A zoomed-in photo stays open when dragged down.")
        XCTAssertTrue(app.buttons["Close"].exists)
        photo.doubleTap()
        // A photo dragged down closes the viewer, as in Photos.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)), withVelocity: .fast, thenHoldForDuration: 0)
        let back = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: app.textFields["library.search"])
        XCTAssertEqual(XCTWaiter.wait(for: [back], timeout: 5), .completed, "Dragging a photo down closes the viewer.")
    }
    /// One swipe moves the viewer on by exactly one photo, the one after it in the grid, and one
    /// swipe back by one. So it does across the end of a month, where the photos the viewer pages
    /// through move on to the next month's once it rests there (N3).
    @MainActor func testOneSwipeAdvancesExactlyOnePhoto() {
        let app = launch()
        let grid = app.collectionViews["library.grid"]
        XCTAssertTrue(grid.cells.element(boundBy: 4).waitForExistence(timeout: 15))
        let following = (2...4).compactMap { photoID(at: $0, in: grid, app) }
        XCTAssertEqual(following.count, 3, "The grid's photos open.")
        tapPhoto(grid.cells.element(boundBy: 1))
        let strip = app.descendants(matching: .any)["viewer.strip"]
        XCTAssertTrue(strip.waitForExistence(timeout: 10))
        func position() -> Int? { (strip.value as? String)?.split(separator: " ").first.flatMap { Int($0) } }
        func waitForPosition(_ expected: Int, _ message: String) {
            let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in position() == expected }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed, message)
        }
        guard let start = position() else { return XCTFail("The strip says which photo is shown.") }
        for (step, expected) in following.enumerated() {
            app.swipeLeft()
            waitForPosition(start + step + 1, "One swipe moves on one photo.")
            XCTAssertEqual(onScreenPhoto(app, where: { $0 == expected }), expected, "The photo after it in the grid.")
        }
        app.swipeRight()
        waitForPosition(start + 2, "One swipe back moves back one photo.")
        XCTAssertEqual(onScreenPhoto(app, where: { $0 == following[1] }), following[1])

        // The strip jumps to the newest month's last photo, the hundredth: seven thumbnails right
        // at a time (23 points apart, and 18 more past the wide current one), then the rest.
        let middle = strip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        var reached = start + 2
        while reached < 100 {
            let step = min(7, 100 - reached)
            middle.withOffset(CGVector(dx: CGFloat(step) * 23 + 18, dy: 0)).tap()
            reached += step
            waitForPosition(reached, "The strip jumps \(step) photos.")
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        guard let last = onScreenPhoto(app) else { return XCTFail("The viewer shows the month's last photo.") }
        app.swipeLeft()
        waitForPosition(101, "One swipe crosses into the next month by one photo.")
        guard let first = onScreenPhoto(app, where: { $0 != last }), first != last else { return XCTFail("The next month's first photo shows.") }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(position(), 101, "Resting there keeps it in place.")
        XCTAssertEqual(onScreenPhoto(app), first, "The photo on screen stays as the window moves on.")
        app.swipeRight()
        waitForPosition(100, "One swipe back crosses back by one photo.")
        XCTAssertEqual(onScreenPhoto(app, where: { $0 == last }), last, "Back on the month's last photo.")
        app.swipeLeft()
        waitForPosition(101, "And forward again.")
        XCTAssertEqual(onScreenPhoto(app, where: { $0 == first }), first)
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
        XCTAssertTrue(waitFor { window.frame.width > window.frame.height }, "The viewer turns with the phone.")
        XCTAssertEqual(onScreenPhoto(app, where: { $0 == shown }), shown, "Turning keeps the same photo on screen.")
        capture(app, "Viewer — turned with the phone")
        app.swipeLeft()
        let next = onScreenPhoto(app, where: { $0 != shown })
        XCTAssertNotNil(next); XCTAssertNotEqual(next, shown, "Swiping still pages.")
        app.swipeRight()
        XCTAssertEqual(onScreenPhoto(app, where: { $0 == shown }), shown, "Swiping back returns to the same photo, not one far away.")
        app.buttons["Close"].tap()
        XCTAssertTrue(app.textFields["library.search"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitFor { window.frame.width < window.frame.height }, "Closing the viewer turns the app back upright.")
    }
    /// The photo filling the viewer, by its asset: file names repeat across the fixture's months.
    /// It is found by its identifier whatever it shows, the grid's thumbnail enlarged until its
    /// preview loads or the zoomable photo after, and once it takes touches: nothing in the viewer
    /// does while it zooms out of its cell or turns. Waits for one that meets `condition`, and
    /// returns the last photo seen if none does in time.
    @MainActor private func onScreenPhoto(_ app: XCUIApplication, within timeout: TimeInterval = 5,
                                          where condition: (String) -> Bool = { _ in true }) -> String? {
        let photos = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'viewer.photo.'"))
        var shown: String?
        _ = waitFor(within: timeout) {
            shown = (0..<photos.count).lazy.map { photos.element(boundBy: $0) }.first { $0.isHittable }?.identifier
            return shown.map(condition) ?? false
        }
        return shown
    }
    /// Polls `condition` until it holds or `timeout` passes, and says whether it held.
    @MainActor private func waitFor(within timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return condition()
    }
    /// The photo cell `index` of the grid opens, by its asset; the viewer closes again.
    @MainActor private func photoID(at index: Int, in grid: XCUIElement, _ app: XCUIApplication,
                                    file: StaticString = #filePath, line: UInt = #line) -> String? {
        tapPhoto(grid.cells.element(boundBy: index))
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 10), file: file, line: line)
        let shown = onScreenPhoto(app)
        requireHittable(app.buttons["Close"], in: app, file: file, line: line)
        app.buttons["Close"].tap()
        requireHittable(app.textFields["library.search"], in: app, file: file, line: line)
        return shown
    }
    /// A photo put in Trash from the viewer leaves the feed. The viewer stays, as in Photos, with
    /// the photo after it on screen (N3); once it closes, that photo has taken the deleted one's
    /// place in the grid, and the deleted one stays out once the feed has read its months again
    /// from the server, which remembers the change for this launch's session alone (N2).
    @MainActor func testDeletingFromTheViewerRemovesThePhotoFromTheFeed() {
        let app = launch(extraArguments: ["--ui-testing-mutable-library"])
        let grid = app.collectionViews["library.grid"]
        XCTAssertTrue(grid.cells.element(boundBy: 2).waitForExistence(timeout: 15))
        let next = photoID(at: 2, in: grid, app)
        XCTAssertNotNil(next)
        tapPhoto(grid.cells.element(boundBy: 1))
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10))
        guard let deleted = onScreenPhoto(app) else { return XCTFail("The viewer shows a photo.") }
        XCTAssertNotEqual(deleted, next)
        requireHittable(delete, in: app); delete.tap()
        let confirm = app.buttons["Move to Trash"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Deleting asks first.")
        confirm.tap()
        XCTAssertEqual(onScreenPhoto(app, within: 10, where: { $0 == next }), next, "The viewer stays, on the photo after it.")
        capture(app, "Viewer — after putting a photo in Trash")
        requireHittable(app.buttons["Close"], in: app); app.buttons["Close"].tap()
        requireHittable(app.textFields["library.search"], in: app)
        capture(app, "Library — after putting a photo in Trash from the viewer")
        XCTAssertEqual(photoID(at: 1, in: grid, app), next, "The photo after it takes its place at once.")
        // The feed has read its months again from the server meanwhile; the photo stays out.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertEqual(photoID(at: 1, in: grid, app), next, "It stays out once the feed reads its months again.")
    }
    /// A photo archived from the viewer leaves the library and shows in the Archive. The viewer
    /// stays on it, its menu now offering Unarchive (N2).
    @MainActor func testArchivingFromTheViewerRemovesItFromTheLibrary() {
        let app = launch(extraArguments: ["--ui-testing-mutable-library"])
        let grid = app.collectionViews["library.grid"]
        XCTAssertTrue(grid.cells.element(boundBy: 2).waitForExistence(timeout: 15))
        let next = photoID(at: 2, in: grid, app)
        tapPhoto(grid.cells.element(boundBy: 1))
        let actions = app.buttons["Photo actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        guard let archived = onScreenPhoto(app) else { return XCTFail("The viewer shows a photo.") }
        requireHittable(actions, in: app); actions.tap()
        let archive = app.buttons["Archive"]
        XCTAssertTrue(archive.waitForExistence(timeout: 5))
        archive.tap()
        // The menu shows the record it opened with, so it is opened again until the change is in.
        var offersUnarchive = false
        for _ in 0..<4 where !offersUnarchive {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            requireHittable(actions, in: app); actions.tap()
            offersUnarchive = app.buttons["Unarchive"].waitForExistence(timeout: 2)
            // A tap beside the menu puts it away.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(offersUnarchive, "The viewer shows the photo archived.")
        XCTAssertEqual(onScreenPhoto(app), archived, "The viewer stays on the photo.")
        requireHittable(app.buttons["Close"], in: app); app.buttons["Close"].tap()
        requireHittable(app.textFields["library.search"], in: app)
        XCTAssertEqual(photoID(at: 1, in: grid, app), next, "The photo leaves the library, the next one taking its place.")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertEqual(photoID(at: 1, in: grid, app), next, "It stays out once the library reads its months again.")

        openShelves(app)
        app.buttons["More"].tap()
        let archiveShelf = app.buttons["Archive"]
        XCTAssertTrue(archiveShelf.waitForExistence(timeout: 10))
        requireHittable(archiveShelf, in: app); archiveShelf.tap()
        XCTAssertTrue(app.buttons["library.shelves"].waitForExistence(timeout: 5), "Tapping a filter puts the shelves away.")
        // The library stays, frozen, until the Archive's month is in; then the grid holds its one photo.
        let one = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in grid.cells.count == 1 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [one], timeout: 15), .completed, "The Archive shows one photo.")
        XCTAssertEqual(photoID(at: 0, in: grid, app), archived, "The Archive shows the photo archived.")
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
    /// A locked photo's menu offers only what the Locked Folder allows: no album, shared link, Cast,
    /// similar photos, browser, profile photo or archive, while sharing, downloading, saving and
    /// moving it out of the folder stay. A library photo's menu shows them all first, so their
    /// absence means something.
    @MainActor func testLockedFolderViewerMenuOffersOnlyPermittedActions() throws {
        let hiddenWhenLocked = ["Add to album", "Create shared link", "Cast", "Find similar photos", "Open in browser", "Set profile photo", "Archive"]
        let app = launch()
        let grid = app.collectionViews["library.grid"]
        XCTAssertTrue(grid.cells.element(boundBy: 1).waitForExistence(timeout: 15))
        tapPhoto(grid.cells.element(boundBy: 1))
        let actions = app.buttons["Photo actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        requireHittable(actions, in: app); actions.tap()
        for name in hiddenWhenLocked { XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 5), "A library photo offers \(name).") }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        requireHittable(app.buttons["Close"], in: app); app.buttons["Close"].tap()
        requireHittable(app.textFields["library.search"], in: app)

        try unlockLockedFolder(app)
        // A timeline row carries no file name, so the folder's photos are just "Photo".
        let locked = app.buttons["Photo"].firstMatch
        XCTAssertTrue(locked.waitForExistence(timeout: 10), "The unlocked folder shows its photo.")
        requireHittable(locked, in: app); locked.tap()
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        requireHittable(actions, in: app); actions.tap()
        let moveOut = app.buttons["Move out of Locked Folder"]
        XCTAssertTrue(moveOut.waitForExistence(timeout: 5), "A locked photo can leave the folder.")
        for name in ["Slideshow", "Share displayed version", "Download original", "Save to Photos"] {
            XCTAssertTrue(app.buttons[name].exists, "A locked photo keeps \(name).")
        }
        for name in hiddenWhenLocked { XCTAssertFalse(app.buttons[name].exists, "A locked photo has no \(name).") }
        capture(app, "Locked Folder — viewer menu")
    }
    /// The app going to the background relocks the Locked Folder (N5): back in front it asks for
    /// its PIN again and shows none of its photos, and the PIN opens it again.
    @MainActor func testLockedFolderRelocksWhenTheAppGoesToTheBackground() throws {
        let app = launch()
        try unlockLockedFolder(app)
        XCTAssertTrue(app.buttons["Photo"].firstMatch.waitForExistence(timeout: 10), "The unlocked folder shows its photos.")

        XCUIDevice.shared.press(.home)
        let away = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.state != .runningForeground }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [away], timeout: 10), .completed, "The app went to the background.")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let pin = app.secureTextFields["6-digit PIN"]
        XCTAssertTrue(pin.waitForExistence(timeout: 10), "Back in front, the folder asks for its PIN again.")
        XCTAssertFalse(app.navigationBars["Locked folder"].buttons["Lock"].exists, "The folder relocked in the background.")
        XCTAssertFalse(app.buttons["Photo"].exists, "None of its photos show.")
        capture(app, "Locked Folder — relocked after the background")

        pin.tap(); pin.typeText("123456")
        app.buttons["Unlock"].tap()
        XCTAssertTrue(app.buttons["Photo"].firstMatch.waitForExistence(timeout: 10), "The PIN opens it again.")
    }
    /// Opens More's Locked Folder and unlocks it with the fixture's PIN. Skips while the shared UI
    /// fixture has no Locked Folder; against one that has it, a refusal is the app's.
    @MainActor private func unlockLockedFolder(_ app: XCUIApplication) throws {
        openShelves(app); app.buttons["More"].tap()
        let browse = app.buttons["Browse more"]
        XCTAssertTrue(browse.waitForExistence(timeout: 10))
        requireHittable(browse, in: app); browse.tap()
        XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 10))
        // The folder's row is low in the list, which builds its rows as they scroll in.
        let folder = app.buttons["Locked folder"]
        for _ in 0..<4 where !folder.isHittable { app.swipeUp() }
        requireHittable(folder, in: app); folder.tap()
        let pin = app.secureTextFields["6-digit PIN"], refused = app.alerts["Couldn’t unlock folder"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in pin.exists || refused.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, "The Locked Folder asks for its PIN.")
        if refused.exists {
            try XCTSkipUnless(fixtureServesLockedFolder(),
                              "The shared UI fixture has no Locked Folder until it restarts with N5's scripts/ui-fixture-server.py.")
            return XCTFail("The Locked Folder refused to unlock, though the fixture serves one.")
        }
        pin.tap(); pin.typeText("123456")
        app.buttons["Unlock"].tap()
        XCTAssertTrue(app.navigationBars["Locked folder"].buttons["Lock"].waitForExistence(timeout: 10), "The folder unlocks.")
    }
    /// Whether the shared UI fixture serves a Locked Folder: its auth status says a PIN is set.
    private func fixtureServesLockedFolder() -> Bool {
        let status = (try? Data(contentsOf: URL(string: "http://127.0.0.1:18091/api/auth/status")!))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return status?["pinCode"] as? Bool == true
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
        XCTAssertFalse(app.buttons["library.pill.place.remove"].exists,
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
        let clear = app.buttons["library.pill.place.remove"]
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
