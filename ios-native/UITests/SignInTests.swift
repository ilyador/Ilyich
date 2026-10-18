import XCTest

final class SignInTests: XCTestCase {
    @MainActor
    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        return app
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
}
