import XCTest

final class SignInTests: XCTestCase {
    /// The sign-in tests that reach the library keep the shelves out after a stroke, so their rows
    /// can be tapped.
    @MainActor
    private func launch(shelvesStayOpen: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + (shelvesStayOpen ? ["--ui-testing-shelves-stay-open"] : [])
        app.launch()
        return app
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ title: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = title; image.lifetime = .keepAlways; add(image)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = title + " — accessibility hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    }

    /// Signs in to the UI fixture, which takes any password. An email starting with "expired"
    /// gets a session the fixture then says has expired.
    @MainActor
    private func signIn(_ app: XCUIApplication, email: String) {
        let server = app.textFields["signIn.serverURL"]
        XCTAssertTrue(server.waitForExistence(timeout: 10))
        server.tap()
        server.typeText("http://127.0.0.1:18091")
        let address = app.textFields["signIn.email"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap()
        address.typeText(email)
        let password = app.secureTextFields["signIn.password"]
        password.tap()
        password.typeText("fixture-password")
        let submit = app.buttons["signIn.submit"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: submit)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed, "A filled-in form can be sent.")
        submit.tap()
    }

    /// iOS offers to save the password after a sign-in, over the app.
    @MainActor
    private func declineSavingThePassword(_ app: XCUIApplication) {
        let notNow = app.buttons["Not Now"]
        guard notNow.waitForExistence(timeout: 5) else { return }
        notNow.tap()
        XCTAssertTrue(notNow.waitForNonExistence(timeout: 5), "The offer goes away.")
    }

    /// An inward swipe from the left edge brings the shelves; a swipe that lands while the
    /// library is still settling is tried once more.
    @MainActor
    private func openShelves(_ app: XCUIApplication) {
        for _ in 0..<2 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)))
            if app.buttons["Settings"].waitForExistence(timeout: 3) { return }
        }
        capture(app, "Shelves")
        XCTFail("The shelves did not open.")
    }

    @MainActor
    func testSignedOutLaunchShowsNativeSignIn() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["signIn.title"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["signIn.serverURL"].exists)
        XCTAssertTrue(app.textFields["signIn.email"].exists)
        XCTAssertTrue(app.secureTextFields["signIn.password"].exists)
        XCTAssertTrue(app.buttons["signIn.submit"].exists)
        XCTAssertFalse(app.otherElements["library.grid"].exists)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Signed out — native sign in"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testEmptyCredentialsCannotSubmit() {
        let app = launch()
        let submit = app.buttons["signIn.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 10))
        XCTAssertFalse(submit.isEnabled, "An empty form must not send a login request.")
    }

    /// Signing in opens the library, and signing out from the Settings shelf returns to sign-in
    /// with nothing to explain.
    @MainActor
    func testSignInThenSignOutReturnsToSignIn() {
        let app = launch(shelvesStayOpen: true)
        signIn(app, email: "fixture@example.test")
        let grid = app.collectionViews["library.grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 15), "Signing in opens the library.")
        XCTAssertTrue(grid.cells.firstMatch.waitForExistence(timeout: 15), "The library shows its photos.")
        declineSavingThePassword(app)

        // The Settings shelf ends with Sign out; holding near the bottom brings it.
        openShelves(app)
        app.buttons["Settings"].tap()
        let origin = app.coordinate(withNormalizedOffset: .zero), height = app.frame.height
        origin.withOffset(CGVector(dx: 120, dy: height * 0.5))
            .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 120, dy: height - 70)), withVelocity: .slow, thenHoldForDuration: 2)
        let signOut = app.buttons["Sign out"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 5))
        signOut.tap()
        XCTAssertTrue(app.staticTexts["Sign out of Ilyich?"].waitForExistence(timeout: 5), "Signing out asks first.")
        let confirmations = app.buttons.matching(NSPredicate(format: "label == %@", "Sign out"))
        let asked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count >= 2"), object: confirmations)
        if XCTWaiter.wait(for: [asked], timeout: 5) != .completed { capture(app, "Sign-out question") }
        // The question's own button follows the shelf row.
        confirmations.element(boundBy: confirmations.count - 1).tap()

        XCTAssertTrue(app.staticTexts["signIn.title"].waitForExistence(timeout: 15), "Signing out returns to sign-in.")
        XCTAssertFalse(grid.exists)
        XCTAssertFalse(app.descendants(matching: .any)["signIn.error"].exists, "An explicit sign-out has nothing to explain.")
        capture(app, "Signed out")
    }

    /// When the server says the session expired, and says so again when asked, the app returns to
    /// sign-in and says why.
    @MainActor
    func testExpiredSessionReturnsToSignInWithExplanation() {
        let app = launch()
        signIn(app, email: "expired@example.test")
        let explanation = app.descendants(matching: .any)["signIn.error"]
        let explained = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "session has expired"), object: explanation)
        let result = XCTWaiter.wait(for: [explained], timeout: 30)
        if result != .completed { capture(app, "Expired session") }
        XCTAssertEqual(result, .completed, "The sign-in screen explains that the session expired.")
        XCTAssertTrue(app.staticTexts["signIn.title"].exists)
        XCTAssertFalse(app.collectionViews["library.grid"].exists)
    }
}
