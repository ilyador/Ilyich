import XCTest

/// A2: the app as it ships, against a stock server. Opt-in: every test is skipped unless the
/// runner's environment names the server and an account on it (TEST_RUNNER_ILYICH_STOCK_SERVER,
/// _EMAIL, _PASSWORD and _PIN, the account's Locked Folder PIN), so the normal regression never
/// runs it. The app runs live, as on a phone: the Keychain, sync and the offline library, the
/// simulator's photos and backup. The tests run in order: the first signs in through the sign-in
/// screen, the last signs out. The server holds, from the API: photos with faces (one person) and
/// places, a video, a Live Photo, a memory for today and a photo in the Locked Folder.
final class StockServerLiveTests: XCTestCase {
    private struct Account {
        let server: String, email: String, password: String, pin: String
    }

    private var account: Account!

    // MARK: Steps

    /// Signs in through the sign-in screen and waits for the first sync: the server's photos show
    /// by name, which only the offline library knows.
    @MainActor func test01SignInAndFirstSync() throws {
        let app = try launch()
        let server = app.textFields["signIn.serverURL"]
        if server.waitForExistence(timeout: 15) {
            capture(app, "Sign-in")
            server.tap(); server.typeText(account.server)
            let email = app.textFields["signIn.email"]
            XCTAssertTrue(email.waitForExistence(timeout: 5))
            email.tap(); email.typeText(account.email)
            let password = app.secureTextFields["signIn.password"]
            password.tap(); password.typeText(account.password)
            app.buttons["signIn.submit"].tap()
        }
        let grid = app.collectionViews["library.grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 30), "Signing in opens the library.")
        declineSavingThePassword(app, within: 20)
        capture(app, "Library — first sync")
        let synced = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in grid.cells.count >= 6 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [synced], timeout: 90), .completed, "The server's six photos and videos show.")

        // Opened again, the saved session reconnects and the offline library names every photo.
        app.terminate()
        app.launch()
        for name in ["obama-1.jpg", "live-still.jpg", "video.mp4, video"] {
            XCTAssertNotNil(cell(name, in: app, timeout: 60), "\(name) shows by its name once the library synced.")
        }
        XCTAssertNil(cell("obama-2.jpg", in: app, timeout: 3), "The Locked Folder's photo stays out of the library.")
        capture(app, "Library — synced")
    }

    /// The viewer shows a photo, a video and a Live Photo; Info shows the photo's place, camera
    /// and person, and Fix faces cuts each face from the preview. Favorite and archive go and come
    /// back.
    @MainActor func test02ViewerInfoFavoriteAndArchive() throws {
        let app = try launch()
        try open("obama-1.jpg", in: app)
        capture(app, "Viewer — photo")

        let favorite = app.buttons["Favorite"]
        requireHittable(favorite, in: app); favorite.tap()
        let unfavorite = app.buttons["Remove favorite"]
        XCTAssertTrue(unfavorite.waitForExistence(timeout: 10), "The photo becomes a favorite.")
        capture(app, "Viewer — favorite")
        unfavorite.tap()
        XCTAssertTrue(favorite.waitForExistence(timeout: 10), "And stops being one.")

        app.buttons["Info"].tap()
        XCTAssertTrue(text("Wellington", in: app).waitForExistence(timeout: 15), "Info shows the photo's place.")
        let fixFaces = app.buttons["Fix faces"]
        for _ in 0..<3 where !fixFaces.isHittable { app.swipeUp() }
        XCTAssertTrue(text("Canon EOS 5D Mark II", in: app).waitForExistence(timeout: 5), "Info shows the camera.")
        XCTAssertTrue(app.staticTexts["Barack Obama"].exists || app.buttons["Barack Obama"].exists, "Info names the person.")
        capture(app, "Info")
        requireHittable(fixFaces, in: app); fixFaces.tap()
        XCTAssertTrue(app.navigationBars["Fix faces"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Barack Obama")).firstMatch.waitForExistence(timeout: 15),
                      "Fix faces lists the photo's faces.")
        // Each face is cut from the preview, as the screenshot shows.
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        capture(app, "Fix faces")
        app.navigationBars["Fix faces"].buttons["Done"].tap()
        let infoDone = app.buttons["Done"]
        if infoDone.waitForExistence(timeout: 5) { infoDone.tap() }

        let actions = app.buttons["Photo actions"]
        requireHittable(actions, in: app); actions.tap()
        app.buttons["Archive"].tap()
        var archived = false
        for _ in 0..<6 where !archived {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            requireHittable(actions, in: app); actions.tap()
            archived = app.buttons["Unarchive"].waitForExistence(timeout: 2)
            if archived { capture(app, "Viewer — archived"); app.buttons["Unarchive"].tap() }
            else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        }
        XCTAssertTrue(archived, "The photo is archived, then back in the library.")
        close(app)

        let video = try XCTUnwrap(cell("video.mp4, video", in: app), "The video isn't in the library.")
        video.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
        let position = app.otherElements["Playback position"]
        XCTAssertTrue(position.waitForExistence(timeout: 15), "The video opens in its player.")
        let plays = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", "0:00 of 0:08"), object: position)
        XCTAssertEqual(XCTWaiter.wait(for: [plays], timeout: 20), .completed, "The video plays.")
        capture(app, "Viewer — video")
        close(app)

        let still = try XCTUnwrap(cell("live-still.jpg", in: app), "The Live Photo isn't in the library.")
        still.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
        XCTAssertTrue(text("August 15, 2025", in: app).waitForExistence(timeout: 15), "The viewer shows the Live Photo.")
        XCTAssertTrue(app.staticTexts["LIVE"].exists, "It is marked LIVE.")
        let live = app.buttons["Play Live Photo"]
        XCTAssertTrue(live.waitForExistence(timeout: 10), "The Live Photo offers its motion.")
        if live.exists { live.tap(); RunLoop.current.run(until: Date().addingTimeInterval(1)) }
        capture(app, "Viewer — Live Photo")
        close(app)
    }

    /// Albums: a new album, a photo added from the viewer, then removed in the album's details.
    @MainActor func test03Albums() throws {
        let app = try launch()
        openShelves(app)
        app.buttons["Albums"].tap()
        let newAlbum = app.buttons["New album"]
        requireHittable(newAlbum, in: app); newAlbum.tap()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap(); name.typeText("Stock trip")
        app.buttons["Save"].tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 10), "The album is created.")
        closeShelves(app)

        try open("obama-3.jpg", in: app)
        app.buttons["Photo actions"].tap()
        app.buttons["Add to album"].tap()
        let album = app.buttons["Stock trip"]
        XCTAssertTrue(album.waitForExistence(timeout: 10), "The new album is offered.")
        capture(app, "Add to album")
        album.tap()
        XCTAssertTrue(album.waitForNonExistence(timeout: 10), "The photo is added.")
        close(app)

        openShelves(app)
        app.buttons["Albums"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Stock trip")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        closeShelves(app)
        XCTAssertNotNil(cell("obama-3.jpg", in: app, timeout: 15), "The album's feed shows its photo.")
        capture(app, "Album feed")

        openShelves(app)
        app.buttons["Albums"].tap()
        app.buttons["Manage albums"].tap()
        let listed = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Stock trip,")).firstMatch
        XCTAssertTrue(listed.waitForExistence(timeout: 10))
        let details = app.buttons["Album details"]
        for _ in 0..<2 where !details.exists {
            listed.press(forDuration: 1.5)
            _ = details.waitForExistence(timeout: 5)
        }
        details.tap()
        let remove = app.buttons["Remove photos"]
        requireHittable(remove, in: app); remove.tap()
        // The album's timeline names no photo.
        let photo = app.buttons["Photo"]
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        capture(app, "Album — remove photos")
        photo.tap()
        app.navigationBars.buttons["Remove"].tap()
        app.buttons["Remove from album"].tap()
        let empty = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == false"), object: remove)
        XCTAssertEqual(XCTWaiter.wait(for: [empty], timeout: 10), .completed, "The album is empty: nothing left to remove.")
        capture(app, "Album details — photo removed")
    }

    /// People, the person's feed and the people list; Places with the Earth and the list of
    /// locations, and a photo's place from its Info: the Earth turned to it over its photos.
    @MainActor func test04PeopleAndPlaces() throws {
        let app = try launch()
        openShelves(app)
        app.buttons["People"].tap()
        let person = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Barack Obama")).firstMatch
        XCTAssertTrue(person.waitForExistence(timeout: 15), "The person shows on the People shelf.")
        capture(app, "People shelf")
        person.tap()
        closeShelves(app)
        XCTAssertNotNil(cell("obama-1.jpg", in: app, timeout: 15), "The person's feed shows their photos.")
        XCTAssertNil(cell("video.mp4, video", in: app, timeout: 3), "And only theirs.")
        capture(app, "Person feed")

        openShelves(app)
        app.buttons["Clear"].tap()
        openShelves(app)
        app.buttons["People"].tap()
        app.buttons["Manage people"].tap()
        XCTAssertTrue(app.staticTexts["Barack Obama"].waitForExistence(timeout: 15) || app.buttons["Barack Obama"].exists)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        capture(app, "People list")
        app.buttons["Done"].firstMatch.tap()

        openShelves(app)
        app.buttons["Places"].tap()
        XCTAssertTrue(app.otherElements["Interactive Earth"].waitForExistence(timeout: 20), "The Earth opens.")
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        capture(app, "Places — Earth")
        let all = app.buttons["All locations"]
        requireHittable(all, in: app); all.tap()
        let find = app.searchFields["Find a location"]
        XCTAssertTrue(find.waitForExistence(timeout: 15), "The photos' places are listed.")
        find.tap(); find.typeText("Wellington")
        let wellington = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Wellington")).firstMatch
        XCTAssertTrue(wellington.waitForExistence(timeout: 10), "Wellington is among them.")
        capture(app, "Places — locations")

        // A photo's place, from its Info: the Earth turned to it, over the place's photos.
        app.terminate(); app.launch()
        try open("obama-1.jpg", in: app)
        app.buttons["Info"].tap()
        let explore = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Explore this location on the globe")).firstMatch
        XCTAssertTrue(explore.waitForExistence(timeout: 15))
        requireHittable(explore, in: app); explore.tap()
        XCTAssertTrue(app.otherElements["Interactive Earth"].waitForExistence(timeout: 20), "The photo's place opens on the Earth.")
        XCTAssertTrue(app.buttons["library.pill.place.remove"].waitForExistence(timeout: 10), "The feed keeps to the place.")
        XCTAssertNotNil(cell("obama-1.jpg", in: app, timeout: 10), "Its photo shows.")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        capture(app, "Places — Wellington from Info")
    }

    /// On this day: today's memory from the API's photo taken on this date in 2021.
    @MainActor func test05Memories() throws {
        let app = try launch()
        browseMore(app)
        app.buttons["On this day"].tap()
        XCTAssertTrue(app.navigationBars["On this day"].waitForExistence(timeout: 10))
        let play = app.buttons["Play memory"]
        XCTAssertTrue(play.waitForExistence(timeout: 15), "Today's memory shows.")
        capture(app, "On this day")
        play.firstMatch.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        capture(app, "Memory playing")
    }

    /// Search: smart search answers once, without the AI check, which stock lacks; a filename
    /// search finds the photos by name; Lightroom, which stock can't filter, is offered nowhere.
    @MainActor func test06SearchAndNoLightroom() throws {
        let app = try launch()
        let search = app.textFields["library.search"]
        requireHittable(search, in: app); search.tap()
        XCTAssertTrue(app.buttons["search.more"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["search.aiCheck"].exists, "Stock has no AI check.")
        search.typeText("two men in suits\n")
        let matches = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", " matches")).firstMatch
        XCTAssertTrue(matches.waitForExistence(timeout: 30), "Smart search finds photos.")
        capture(app, "Search — smart")
        app.buttons["library.pill.search.remove"].tap()

        search.tap()
        app.buttons["search.more"].tap()
        XCTAssertTrue(app.navigationBars["Search options"].waitForExistence(timeout: 5))
        let mode = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Search mode")).firstMatch
        XCTAssertTrue(mode.waitForExistence(timeout: 10)); mode.tap()
        app.buttons["Filename"].tap()
        app.navigationBars["Search options"].buttons["Apply"].tap()
        search.tap(); search.typeText("obama\n")
        XCTAssertTrue(matches.waitForExistence(timeout: 30), "A filename search finds the photos.")
        XCTAssertNotNil(cell("obama-5.jpg", in: app, timeout: 10))
        capture(app, "Search — filename")
        let modeChip = app.buttons["search.chip.mode"]
        if modeChip.exists { modeChip.tap() }
        app.buttons["library.pill.search.remove"].tap()

        openShelves(app)
        app.buttons["More"].tap()
        XCTAssertTrue(app.buttons["Favorites"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Lightroom"].exists, "No Lightroom on the More shelf.")
        capture(app, "More shelf")
        let browse = app.buttons["Browse more"]
        requireHittable(browse, in: app); browse.tap()
        XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Lightroom"].exists, "Nor in Browse more.")
        capture(app, "Browse more")
    }

    /// The editor turns a photo a quarter and saves; the viewer then shows the new preview.
    @MainActor func test07EditPhoto() throws {
        let app = try launch()
        try open("obama-3.jpg", in: app)
        let edit = app.buttons["Edit"]
        requireHittable(edit, in: app); edit.tap()
        XCTAssertTrue(app.navigationBars["Edit photo"].waitForExistence(timeout: 15), "The editor opens.")
        capture(app, "Editor")
        app.buttons["Rotate & flip"].tap()
        app.buttons["Rotate right"].tap()
        capture(app, "Editor — turned")
        app.navigationBars["Edit photo"].buttons["Save"].tap()
        let pending = app.alerts["Edits saved"]
        if pending.waitForExistence(timeout: 15) { capture(app, "Edits saved"); pending.buttons["Done"].tap() }
        XCTAssertTrue(app.navigationBars["Edit photo"].waitForNonExistence(timeout: 20), "The editor closes.")
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        capture(app, "Viewer — edited")
        close(app)
    }

    /// A photo put in Trash from the viewer is restored from the Trash.
    @MainActor func test08TrashAndRestore() throws {
        let app = try launch()
        try open("obama-5.jpg", in: app)
        app.buttons["Delete"].tap()
        let confirm = app.buttons["Move to Trash"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        close(app)
        XCTAssertNil(cell("obama-5.jpg", in: app, timeout: 5), "The photo left the library.")

        browseMore(app)
        let trash = scrolledTo(app.buttons["Trash"], in: app)
        requireHittable(trash, in: app); trash.tap()
        XCTAssertTrue(app.navigationBars["Trash"].waitForExistence(timeout: 10))
        let photo = app.buttons["Select Photo"]
        XCTAssertTrue(photo.waitForExistence(timeout: 15), "The photo is in the Trash, unnamed as a timeline row is.")
        capture(app, "Trash")
        photo.tap()
        app.buttons["Restore"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Restored 1 ")).firstMatch.waitForExistence(timeout: 15),
                      "The photo is restored.")
        capture(app, "Trash — restored")
    }

    /// The Locked Folder opens with the account's PIN and shows the photo locked through the API.
    @MainActor func test09LockedFolder() throws {
        let app = try launch()
        try XCTSkipIf(account.pin.isEmpty, "No PIN named (TEST_RUNNER_ILYICH_STOCK_PIN).")
        browseMore(app)
        let locked = scrolledTo(app.buttons["Locked folder"], in: app)
        requireHittable(locked, in: app); locked.tap()
        let pin = app.secureTextFields["6-digit PIN"]
        XCTAssertTrue(pin.waitForExistence(timeout: 10), "The folder asks for the PIN.")
        pin.tap(); pin.typeText(account.pin)
        app.buttons["Unlock"].tap()
        let photo = app.buttons["Photo"]
        XCTAssertTrue(photo.waitForExistence(timeout: 15), "The locked photo shows.")
        capture(app, "Locked folder")
        photo.tap()
        let shown = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'viewer.photo.' AND label == %@", "obama-2.jpg"))
        XCTAssertTrue(shown.firstMatch.waitForExistence(timeout: 15), "It opens: the photo locked through the API.")
        capture(app, "Locked folder — photo")
    }

    /// Backup of the simulator's photos, checked on the server.
    @MainActor func test10Backup() async throws {
        let app = try launch()
        let token = try await serverToken()
        openShelves(app)
        app.buttons["Settings"].tap()
        app.buttons["Backup"].tap()
        XCTAssertTrue(app.navigationBars["Device backup"].waitForExistence(timeout: 15))
        let recents = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Recents")).firstMatch
        XCTAssertTrue(scrolledTo(recents, in: app).waitForExistence(timeout: 15), "The simulator's photos are offered.")
        recents.tap()
        app.buttons["Back up"].tap()
        capture(app, "Backup — Recents chosen")
        let start = app.buttons["Back up now"]
        for _ in 0..<6 where !(start.exists && start.isHittable) { app.swipeDown() }
        requireHittable(start, in: app); start.tap()
        var found = 0
        let deadline = Date().addingTimeInterval(180)
        while found == 0 && Date() < deadline {
            try await Task.sleep(for: .seconds(5))
            found = (try? await serverCount(named: "IMG_0001.JPG", token: token)) ?? 0
        }
        capture(app, "Backup — running")
        XCTAssertEqual(found, 1, "The server has the simulator's photo.")
    }

    /// Diagnostics: the request log, which the run reads for 4xx and 5xx answers.
    @MainActor func test11Diagnostics() throws {
        let app = try launch()
        openShelves(app)
        app.buttons["Settings"].tap()
        app.buttons["Diagnostics"].tap()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        capture(app, "Diagnostics")
        for index in 1...6 { app.swipeUp(); capture(app, "Diagnostics \(index)") }
    }

    /// Shares a photo from Photos to the app: the share extension stages it, the app opens on
    /// Shared files, and uploads it.
    @MainActor func test12ShareExtension() throws {
        let app = try launch()
        XCTAssertTrue(app.collectionViews["library.grid"].waitForExistence(timeout: 20))
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.launch()
        // Photos' own grid: images, the first rows partly under its header. Photos may reopen on
        // the photo it showed last.
        let first = photos.images.matching(identifier: "PXGGridLayout-Info").element(boundBy: 3)
        let share = photos.buttons["Share"]
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<4 where !first.waitForExistence(timeout: 5) && !share.exists {
            for title in ["Continue", "Not Now", "OK"] where photos.buttons[title].exists { photos.buttons[title].tap() }
        }
        // Photos asks about notifications at its first launch.
        let refuse = springboard.alerts.buttons["Don’t Allow"]
        if refuse.waitForExistence(timeout: 3) { refuse.tap() }
        capture(photos, "Photos")
        if !share.exists {
            XCTAssertTrue(first.waitForExistence(timeout: 15), "Photos shows the simulator's photos.")
            first.tap()
        }
        XCTAssertTrue(share.waitForExistence(timeout: 10)); share.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        capture(photos, "Share sheet")
        let target = photos.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Ilyich")).firstMatch
        if !target.waitForExistence(timeout: 5) {
            photos.buttons["More"].firstMatch.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            capture(photos, "Share sheet — more")
        }
        XCTAssertTrue(target.waitForExistence(timeout: 10), "The share sheet offers Ilyich.")
        target.tap()
        let proceed = photos.buttons["Continue in Ilyich"]
        XCTAssertTrue(proceed.waitForExistence(timeout: 15), "The extension's page shows.")
        capture(photos, "Share extension")
        proceed.tap()
        let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if open.waitForExistence(timeout: 3) { open.tap() }
        // A share extension can't bring the app forward: it says the files are saved, and the app
        // shows them when it opens.
        if !app.navigationBars["Shared files"].waitForExistence(timeout: 10) {
            capture(photos, "Share extension — saved")
            app.activate()
        }
        XCTAssertTrue(app.navigationBars["Shared files"].waitForExistence(timeout: 20), "The app shows the shared files.")
        capture(app, "Shared files")
        let item = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@",
                                                    ".jpg", ".png", ".heic")).firstMatch
        let upload = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Upload")).firstMatch
        if upload.waitForExistence(timeout: 10) && !upload.isEnabled, item.exists { item.tap() }
        requireHittable(upload, in: app); upload.tap()
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        capture(app, "Shared files — upload asked")
        let done = text("uploaded", in: app), empty = text("No pending shares", in: app)
        let uploaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in done.exists || empty.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [uploaded], timeout: 60), .completed, "The shared photo uploads.")
        capture(app, "Shared files — uploaded")
        app.navigationBars["Shared files"].buttons["Done"].tap()
    }

    /// Signs out through the Settings shelf.
    @MainActor func test99SignOut() throws {
        let app = try launch()
        openShelves(app)
        app.buttons["Settings"].tap()
        let origin = app.coordinate(withNormalizedOffset: .zero), height = app.frame.height
        origin.withOffset(CGVector(dx: 120, dy: height * 0.5))
            .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 120, dy: height - 70)), withVelocity: .slow, thenHoldForDuration: 2)
        let signOut = app.buttons["Sign out"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 5)); signOut.tap()
        let confirmations = app.buttons.matching(NSPredicate(format: "label == %@", "Sign out"))
        let asked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count >= 2"), object: confirmations)
        _ = XCTWaiter.wait(for: [asked], timeout: 5)
        confirmations.element(boundBy: confirmations.count - 1).tap()
        XCTAssertTrue(app.staticTexts["signIn.title"].waitForExistence(timeout: 20), "Signing out returns to sign-in.")
        capture(app, "Signed out")
    }

    // MARK: Helpers

    /// The live app, with the shelves kept out after a stroke so their rows can be tapped. Skips
    /// the test unless the runner names the server and the account.
    @MainActor private func launch() throws -> XCUIApplication {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["ILYICH_STOCK_SERVER"], !server.isEmpty, let email = environment["ILYICH_STOCK_EMAIL"],
              let password = environment["ILYICH_STOCK_PASSWORD"] else {
            throw XCTSkip("No stock server named (TEST_RUNNER_ILYICH_STOCK_SERVER).")
        }
        account = Account(server: server, email: email, password: password, pin: environment["ILYICH_STOCK_PIN"] ?? "")
        continueAfterFailure = true
        // The system asks for notifications and the local network once.
        addUIInterruptionMonitor(withDescription: "System alerts") { alert in
            for title in ["Allow", "Allow Full Access", "Allow While Using App", "OK"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            return false
        }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-shelves-stay-open"]
        app.launch()
        closeSharedFiles(app)
        return app
    }

    /// An inward swipe from the left edge brings the shelves; one that lands while the library
    /// settles is tried again.
    @MainActor private func openShelves(_ app: XCUIApplication) {
        XCTAssertTrue(app.collectionViews["library.grid"].waitForExistence(timeout: 20))
        for _ in 0..<3 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)))
            if app.buttons["Settings"].waitForExistence(timeout: 3) { return }
        }
        capture(app, "Shelves")
        XCTFail("The shelves did not open.")
    }

    /// Tapping beside the rows puts the shelves away.
    @MainActor private func closeShelves(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.62)).tap()
    }

    /// Opens More's Browse more screen from the shelves.
    @MainActor private func browseMore(_ app: XCUIApplication) {
        openShelves(app)
        app.buttons["More"].tap()
        let browse = app.buttons["Browse more"]
        requireHittable(browse, in: app); browse.tap()
        XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 10))
    }

    /// A row of a list, scrolled to.
    @MainActor private func scrolledTo(_ element: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        for _ in 0..<6 where !(element.exists && element.isHittable) { app.swipeUp() }
        return element
    }

    /// Signs in to the server as the test account, for checks the screens can't show.
    @MainActor private func serverToken() async throws -> String {
        var request = URLRequest(url: URL(string: account.server + "/api/auth/login")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["email": account.email, "password": account.password])
        let (data, _) = try await URLSession.shared.data(for: request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(object?["accessToken"] as? String)
    }

    /// How many of the test account's photos and videos the server holds under `name`.
    @MainActor private func serverCount(named name: String, token: String) async throws -> Int {
        var request = URLRequest(url: URL(string: account.server + "/api/search/metadata")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["filter": ["originalFileName": ["like": name]], "size": 10])
        let (data, _) = try await URLSession.shared.data(for: request)
        let assets = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["assets"] as? [String: Any]
        return try XCTUnwrap(assets?["count"] as? Int)
    }

    @MainActor private func capture(_ app: XCUIApplication, _ title: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = title; image.lifetime = .keepAlways; add(image)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = title + " — accessibility hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    }

    /// iOS offers to save the password after a sign-in, over the app, some seconds later.
    @MainActor private func declineSavingThePassword(_ app: XCUIApplication, within timeout: TimeInterval = 0) {
        let notNow = app.buttons["Not Now"]
        guard notNow.waitForExistence(timeout: timeout) else { return }
        notNow.tap()
    }

    /// Shared files waiting from an earlier run show at launch, over the library.
    @MainActor private func closeSharedFiles(_ app: XCUIApplication) {
        let shared = app.navigationBars["Shared files"]
        if shared.waitForExistence(timeout: 3) { shared.buttons["Done"].tap() }
    }

    /// Text whose label contains `value`.
    @MainActor private func text(_ value: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
    }

    @MainActor private func requireHittable(_ element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element)
        if XCTWaiter.wait(for: [ready], timeout: 10) != .completed {
            capture(app, "Not interactive")
            XCTFail("\(element) never became interactive.", file: file, line: line)
        }
    }

    /// The grid cell of the photo `label` names, scrolling the library to it.
    @MainActor private func cell(_ label: String, in app: XCUIApplication, timeout: TimeInterval = 20) -> XCUIElement? {
        let grid = app.collectionViews["library.grid"]
        guard grid.waitForExistence(timeout: 15) else { return nil }
        let match = grid.cells.matching(NSPredicate(format: "label == %@", label)).firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        var step = 0
        repeat {
            declineSavingThePassword(app)
            if match.exists && match.isHittable { return match }
            // Down a few screens, then back up, away from the edges' gestures.
            let start = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: step % 8 < 4 ? 0.75 : 0.3))
            start.press(forDuration: 0.05, thenDragTo: grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: step % 8 < 4 ? 0.3 : 0.75)))
            step += 1
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        } while Date() < deadline
        return match.exists && match.isHittable ? match : nil
    }

    /// Opens the photo whose grid cell `cellLabel` names, and waits for the viewer to show it.
    @MainActor private func open(_ cellLabel: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) throws {
        let found = try XCTUnwrap(cell(cellLabel, in: app), "\(cellLabel) isn't in the library.", file: file, line: line)
        // Photos run under the status bar, where a touch scrolls to the top: touch near the lower edge.
        found.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
        let shown = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'viewer.photo.' AND label == %@", cellLabel))
        XCTAssertTrue(shown.firstMatch.waitForExistence(timeout: 15), "The viewer shows \(cellLabel).", file: file, line: line)
    }

    @MainActor private func close(_ app: XCUIApplication) {
        let close = app.buttons["Close"]
        guard close.waitForExistence(timeout: 5) else { return }
        requireHittable(close, in: app); close.tap()
        XCTAssertTrue(app.collectionViews["library.grid"].waitForExistence(timeout: 10))
    }
}
