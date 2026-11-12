import Foundation
import StoreKitTest
import XCTest

/// Run this class serially with the bundled configuration. Apple documents one local StoreKit test
/// environment, so these tests must not overlap PurchaseStoreKitTests on the same simulator.
/// The configuration is a test-bundle resource; there is no production entitlement override.
final class PurchaseAccessUITests: XCTestCase {
    private static let monthly = "io.ilyador.ilyich.access.monthly"
    private static let yearly = "io.ilyador.ilyich.access.yearly"
    private static let lifetime = "io.ilyador.ilyich.access.lifetime"
    private static let identifiers = [monthly, yearly, lifetime]

    @MainActor func testLockedPaywallUsesStoreKitPricesAndKeepsRecoveryAndLegalControlsAvailable() async throws {
        let fixture = try canonicalFixture()
        let session = try configuredSession(fixture)
        let app = application()
        defer { app.terminate(); session.clearTransactions(); session.resetToDefaultState() }
        app.launch()
        XCTAssertTrue(app.staticTexts["Your own photo server is required"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.textFields["signIn.serverURL"].exists, "A server account must not open before verified app access.")
        XCTAssertFalse(app.collectionViews["library.grid"].exists, "The paywall must not masquerade as an empty library.")

        for identifier in Self.identifiers {
            let plan = try XCTUnwrap(fixture.catalog.plans.first { $0.productID == identifier })
            let purchase = app.buttons["purchase." + identifier]
            reveal(purchase, in: app)
            requireEnabled(purchase, in: app)
            try assertPrice(for: plan, fixture: fixture.catalog, purchase: purchase, in: app)
            if identifier == Self.lifetime {
                XCTAssertEqual(plan.type, "NonConsumable")
                XCTAssertNil(plan.introductoryOffer)
                XCTAssertNil(plan.recurringSubscriptionPeriod)
                XCTAssertEqual(purchase.label, "Buy lifetime access")
                XCTAssertTrue(app.staticTexts["One-time purchase. No renewal and no free trial."].exists)
                capture(app, "IAP review - lifetime access")
            } else {
                XCTAssertEqual(plan.type, "RecurringSubscription")
                XCTAssertEqual(plan.recurringSubscriptionPeriod, identifier == Self.monthly ? "P1M" : "P1Y")
                let offer = try XCTUnwrap(plan.introductoryOffer)
                XCTAssertEqual(offer.paymentMode, "free")
                XCTAssertEqual(offer.subscriptionPeriod, "P1W")
                // The fixture has a fresh account and a one-week offer. StoreKit may express
                // that same period as either one week or seven days in the app's Product data.
                let trialReady = XCTNSPredicateExpectation(predicate: NSPredicate(
                    format: "label == %@ OR label == %@", "Try free for 1 week", "Try free for 7 days"
                ), object: purchase)
                XCTAssertEqual(XCTWaiter.wait(for: [trialReady], timeout: 15), .completed)
                capture(app, identifier == Self.monthly ? "IAP review - monthly access" : "IAP review - yearly access")
            }
        }

        let restore = app.buttons["purchase.restore"]
        reveal(restore, in: app); requireEnabled(restore, in: app)
        restore.tap()
        requireEnabled(restore, in: app)
        XCTAssertTrue(app.staticTexts["purchase.message"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.textFields["signIn.serverURL"].exists, "Restoring an empty test account must not grant access.")
        XCTAssertFalse(app.collectionViews["library.grid"].exists)

        let manage = app.buttons["purchase.manage"]
        reveal(manage, in: app); requireEnabled(manage, in: app)
        let account = app.buttons["purchase.serverAccount"]
        reveal(account, in: app); requireEnabled(account, in: app)
        account.tap()
        XCTAssertTrue(app.navigationBars["Server account"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No server account is saved on this iPhone."].waitForExistence(timeout: 5))
        let back = app.navigationBars["Server account"].buttons.firstMatch
        XCTAssertTrue(back.isHittable)
        back.tap()
        XCTAssertTrue(app.navigationBars["Server account"].waitForNonExistence(timeout: 5))

        for title in ["Privacy Policy", "Terms of Use (Apple Standard EULA)", "Help and support"] {
            let link = legalControl(title, in: app)
            reveal(link, in: app); requireEnabled(link, in: app)
        }
        capture(app, "Paywall - restore and legal controls")
        XCTAssertTrue(session.allTransactions().isEmpty, "Inspecting the paywall and restoring must not create a purchase.")
    }

    @MainActor func testLifetimePurchaseOpensNativeSignInAndSurvivesRelaunch() async throws {
        let fixture = try canonicalFixture()
        let session = try configuredSession(fixture)
        let app = application()
        defer { app.terminate(); session.clearTransactions(); session.resetToDefaultState() }
        let plan = try XCTUnwrap(fixture.catalog.plans.first { $0.productID == Self.lifetime })
        XCTAssertEqual(plan.type, "NonConsumable")
        app.launch()
        let lifetime = app.buttons["purchase." + Self.lifetime]
        reveal(lifetime, in: app); requireEnabled(lifetime, in: app)
        try assertPrice(for: plan, fixture: fixture.catalog, purchase: lifetime, in: app)
        // This calls Product.purchase() in the real app. SKTestSession controls only Apple's
        // local test environment; no purchase-state launch argument or fake app UI is involved.
        lifetime.tap()
        XCTAssertTrue(app.textFields["signIn.serverURL"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.collectionViews["library.grid"].exists, "The next step is signing in to the user's server.")
        let transaction = try XCTUnwrap(session.allTransactions().first {
            $0.productIdentifier == Self.lifetime
        })
        capture(app, "Lifetime purchase - native server sign-in")

        app.terminate()
        app.launch()
        XCTAssertTrue(app.textFields["signIn.serverURL"].waitForExistence(timeout: 20),
                      "A new app process must restore Apple's local signed lifetime entitlement.")
        XCTAssertFalse(app.buttons["purchase." + Self.lifetime].exists)

        try session.refundTransaction(identifier: transaction.identifier)
        XCTAssertTrue(app.staticTexts["Your own photo server is required"].waitForExistence(timeout: 20),
                      "A live refund update must return the app to the paywall.")
        XCTAssertFalse(app.textFields["signIn.serverURL"].exists,
                       "A revoked lifetime entitlement must close server sign-in.")

        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Your own photo server is required"].waitForExistence(timeout: 20),
                      "A refunded lifetime transaction must return the app to the paywall.")
        XCTAssertFalse(app.textFields["signIn.serverURL"].exists)
        XCTAssertTrue(app.buttons["purchase." + Self.lifetime].exists)

        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Your own photo server is required"].waitForExistence(timeout: 20),
                      "A later launch must remain locked after the refund.")
        XCTAssertFalse(app.textFields["signIn.serverURL"].exists)
    }

    @MainActor func testMonthlyTrialPurchaseOpensNativeSignInWithSevenDayExpiration() async throws {
        let fixture = try canonicalFixture()
        let session = try configuredSession(fixture)
        let app = application()
        defer { app.terminate(); session.clearTransactions(); session.resetToDefaultState() }
        let plan = try XCTUnwrap(fixture.catalog.plans.first { $0.productID == Self.monthly })
        XCTAssertEqual(plan.type, "RecurringSubscription")
        XCTAssertEqual(plan.recurringSubscriptionPeriod, "P1M")
        let trial = try XCTUnwrap(plan.introductoryOffer)
        XCTAssertEqual(trial.paymentMode, "free")
        XCTAssertEqual(trial.subscriptionPeriod, "P1W")

        app.launch()
        let monthly = app.buttons["purchase." + Self.monthly]
        reveal(monthly, in: app); requireEnabled(monthly, in: app)
        try assertPrice(for: plan, fixture: fixture.catalog, purchase: monthly, in: app)
        let trialReady = XCTNSPredicateExpectation(predicate: NSPredicate(
            format: "label == %@ OR label == %@", "Try free for 1 week", "Try free for 7 days"
        ), object: monthly)
        XCTAssertEqual(XCTWaiter.wait(for: [trialReady], timeout: 15), .completed)

        // This exercises Product.purchase() in the app against a fresh local StoreKit session.
        monthly.tap()
        let signInOpened = app.textFields["signIn.serverURL"].waitForExistence(timeout: 30)
        let observedTransactions = session.allTransactions().map { transaction in
            "product=\(transaction.productIdentifier) id=\(transaction.identifier) " +
            "purchased=\(transaction.purchaseDate) expires=\(String(describing: transaction.expirationDate))"
        }.joined(separator: "\n")
        let diagnostic = XCTAttachment(string: "timeRate=\(String(describing: session.timeRate))\n" +
                                       "signInOpened=\(signInOpened)\n" + observedTransactions)
        diagnostic.name = "Monthly trial StoreKit session diagnostic"
        diagnostic.lifetime = .keepAlways
        add(diagnostic)
        XCTAssertTrue(signInOpened)
        XCTAssertFalse(app.collectionViews["library.grid"].exists,
                       "The next step is signing in to the user's server.")
        let transaction = try XCTUnwrap(session.allTransactions().first {
            $0.productIdentifier == Self.monthly
        })
        let expiration = try XCTUnwrap(transaction.expirationDate,
                                       "The introductory subscription must have a signed expiration.")
        XCTAssertEqual(expiration.timeIntervalSince(transaction.purchaseDate), 7 * 24 * 60 * 60,
                       accuracy: 120, "The fixture's P1W introductory offer should grant one week.")
        capture(app, "Monthly trial purchase - native server sign-in")
    }

    @MainActor func testMonthlyTrialExpiresNaturallyAfterAutoRenewIsDisabled() async throws {
        let fixture = try canonicalFixture()
        let session = try configuredSession(fixture)
        session.timeRate = .oneRenewalEveryMinute
        let app = application()
        defer { app.terminate(); session.clearTransactions(); session.resetToDefaultState() }
        let plan = try XCTUnwrap(fixture.catalog.plans.first { $0.productID == Self.monthly })
        XCTAssertEqual(plan.type, "RecurringSubscription")
        XCTAssertEqual(plan.recurringSubscriptionPeriod, "P1M")
        XCTAssertEqual(try XCTUnwrap(plan.introductoryOffer).subscriptionPeriod, "P1W")

        app.launch()
        let monthly = app.buttons["purchase." + Self.monthly]
        reveal(monthly, in: app); requireEnabled(monthly, in: app)
        try assertPrice(for: plan, fixture: fixture.catalog, purchase: monthly, in: app)
        monthly.tap()
        XCTAssertTrue(app.textFields["signIn.serverURL"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.collectionViews["library.grid"].exists,
                       "The next step is signing in to the user's server.")
        let transaction = try XCTUnwrap(session.allTransactions().first {
            $0.productIdentifier == Self.monthly
        })
        let expiration = try XCTUnwrap(transaction.expirationDate)
        let timeRemaining = expiration.timeIntervalSinceNow
        XCTAssertGreaterThan(timeRemaining, 0, "The accelerated trial should still be active after checkout.")
        XCTAssertLessThanOrEqual(timeRemaining, 120,
                                 "One renewal per minute should make the natural-expiry check bounded.")

        try session.disableAutoRenewForTransaction(identifier: transaction.identifier)
        XCTAssertTrue(app.textFields["signIn.serverURL"].exists,
                      "Disabling renewal must preserve access until the signed expiration.")
        XCTAssertFalse(app.buttons["purchase." + Self.monthly].exists)

        guard timeRemaining > 0 else { return }
        let waitBudget = min(120, max(1, timeRemaining + 30))
        XCTAssertTrue(app.staticTexts["Your own photo server is required"].waitForExistence(timeout: waitBudget),
                      "The paywall should return when the signed trial deadline passes.")
        XCTAssertGreaterThanOrEqual(Date(), expiration)
        XCTAssertFalse(app.textFields["signIn.serverURL"].exists)

        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Your own photo server is required"].waitForExistence(timeout: 20),
                      "A later launch must remain locked after natural trial expiry.")
        XCTAssertFalse(app.textFields["signIn.serverURL"].exists)
    }

    @MainActor private func canonicalFixture() throws -> (url: URL, catalog: StoreKitFixture) {
        continueAfterFailure = false
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Ilyich", withExtension: "storekit"),
                                "Run with the test-only StoreKit configuration bundled in IlyichUITests.")
        let catalog = try JSONDecoder().decode(StoreKitFixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(Set(catalog.plans.map(\.productID)), Set(Self.identifiers))
        XCTAssertEqual(catalog.plans.count, Self.identifiers.count)
        XCTAssertEqual(catalog.settings.locale, "en_US")
        XCTAssertEqual(catalog.settings.storefront, "PRT")
        return (url, catalog)
    }

    @MainActor private func configuredSession(_ fixture: (url: URL, catalog: StoreKitFixture)) throws -> SKTestSession {
        let session = try SKTestSession(contentsOf: fixture.url)
        // The runner controls the target app's local test environment. Product lookups belong
        // in the real app, whose bundle/context differs from this XCTest runner.
        session.clearTransactions()
        session.disableDialogs = true
        session.locale = Locale(identifier: fixture.catalog.settings.locale)
        session.storefront = fixture.catalog.settings.storefront
        session.timeRate = .realTime
        XCTAssertTrue(session.allTransactions().isEmpty)
        return session
    }

    @MainActor private func assertPrice(for plan: StoreKitFixture.Plan, fixture: StoreKitFixture,
                                        purchase: XCUIElement, in app: XCUIApplication) throws {
        let amount = try XCTUnwrap(Decimal(string: plan.displayPrice, locale: Locale(identifier: "en_US_POSIX")))
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: fixture.settings.locale)
        formatter.numberStyle = .currency
        // The canonical fixture explicitly selects Portugal, whose currency is EUR.
        formatter.currencyCode = "EUR"
        let expectedPrice = try XCTUnwrap(formatter.string(from: NSDecimalNumber(decimal: amount)))
        let name = try XCTUnwrap(plan.localizations.first { $0.locale == fixture.settings.locale }?.displayName)
        let title = app.staticTexts[name]
        let price = app.staticTexts[expectedPrice]
        reveal(price, in: app)
        XCTAssertTrue(title.isHittable, "The configured plan name must be visible with its price.")
        XCTAssertTrue(price.isHittable, "The app must show the fixture amount formatted in its StoreKit storefront currency.")
        XCTAssertTrue(purchase.isHittable, "The price and its purchase action should fit together on screen.")
        XCTAssertLessThanOrEqual(abs(price.frame.midY - title.frame.midY), max(price.frame.height, title.frame.height),
                                 "The expected price must belong to this plan's heading, not another plan.")
        XCTAssertLessThan(price.frame.maxY, purchase.frame.minY,
                          "The plan's price must appear above its purchase action.")
    }

    @MainActor private func application() -> XCUIApplication {
        let app = XCUIApplication()
        // Existing account isolation only: no Keychain restoration, local Photos or backup.
        // The production StoreKit purchase gate still runs without an entitlement override.
        app.launchArguments = ["--ui-testing", "-appearance", "dark"]
        return app
    }

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let scroll = app.scrollViews.firstMatch
        guard scroll.waitForExistence(timeout: 20) else {
            capture(app, "Paywall control missing")
            XCTFail("The paywall control did not load.", file: file, line: line)
            return
        }
        if !element.waitForExistence(timeout: 3) {
            let reload = app.buttons["Reload prices"]
            if reload.exists && reload.isEnabled && reload.isHittable {
                reload.tap()
                guard element.waitForExistence(timeout: 20) else {
                    capture(app, "Paywall control missing after price reload")
                    XCTFail("The paywall control did not load after one real price reload.", file: file, line: line)
                    return
                }
            } else {
                capture(app, "Paywall control missing")
                XCTFail("The paywall control did not load and no enabled Reload prices control was available.",
                        file: file, line: line)
                return
            }
        }
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            // Short drags keep a plan's price and button together rather than flinging past it.
            let up = element.frame.midY >= scroll.frame.midY
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: up ? 0.75 : 0.25))
                .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        }
        capture(app, "Paywall control not visible")
        XCTFail("The paywall control did not become visible.", file: file, line: line)
    }

    @MainActor private func requireEnabled(_ element: XCUIElement, in app: XCUIApplication,
                                           file: StaticString = #filePath, line: UInt = #line) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: element)
        let result = XCTWaiter.wait(for: [ready], timeout: 20)
        if result != .completed { capture(app, "Paywall control did not become ready") }
        XCTAssertEqual(result, .completed, file: file, line: line)
    }

    @MainActor private func legalControl(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ AND (elementType == %ld OR elementType == %ld)", title,
            Int(XCUIElement.ElementType.button.rawValue), Int(XCUIElement.ElementType.link.rawValue)
        )).firstMatch
    }

    @MainActor private func capture(_ app: XCUIApplication, _ title: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = title; image.lifetime = .keepAlways; add(image)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = title + " - accessibility hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    }
}

/// Independent expectations come from the same test-only catalog used by StoreKitTest,
/// rather than querying Product from the UI runner or copying labels from the app code.
private struct StoreKitFixture: Decodable {
    struct Settings: Decodable {
        let locale: String
        let storefront: String
        enum CodingKeys: String, CodingKey {
            case locale = "_locale"
            case storefront = "_storefront"
        }
    }
    struct Plan: Decodable {
        struct Localization: Decodable {
            let locale: String
            let displayName: String
        }
        struct Offer: Decodable {
            let paymentMode: String
            let subscriptionPeriod: String
        }
        let productID: String
        let displayPrice: String
        let type: String
        let localizations: [Localization]
        let introductoryOffer: Offer?
        let recurringSubscriptionPeriod: String?
    }
    struct SubscriptionGroup: Decodable {
        let subscriptions: [Plan]
    }
    let settings: Settings
    let products: [Plan]
    let subscriptionGroups: [SubscriptionGroup]
    var plans: [Plan] { products + subscriptionGroups.flatMap(\.subscriptions) }
}
