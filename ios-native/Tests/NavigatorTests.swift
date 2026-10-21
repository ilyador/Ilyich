import Foundation
import XCTest
@testable import Ilyich

/// The navigator, the link resolver and the screen model, without SwiftUI. The tests stand in for
/// the presentation hosts: when a layer is asked to close, they report it closed, as a sheet's
/// onDismiss or the viewer's zoom presenter does once the animation has finished.
@MainActor final class NavigatorTests: XCTestCase {
    private let photo = Asset(id: "00000000-0000-4000-8000-0000000000f1", originalFileName: "photo.jpg")
    private let other = Asset(id: "00000000-0000-4000-8000-0000000000f2", originalFileName: "other.jpg")
    private let coast = Album(id: "00000000-0000-4000-8000-000000000003", albumName: "Coast", assetCount: 100, shared: false,
                              albumUsers: nil, startDate: nil, endDate: nil, updatedAt: nil, order: "desc")
    private let maya = Person(id: "00000000-0000-4000-8000-000000000002", name: "Maya", birthDate: nil, thumbnailPath: nil,
                              updatedAt: nil, isHidden: nil, isFavorite: nil)

    // MARK: Deep links

    func testDeepLinkWhileASheetIsOpenOpensThePhotoOnceTheSheetHasClosed() async throws {
        let gate = StubServer.Gate()
        let lookup = Lookup(assets: [photo], gates: [photo.id: gate])
        let model = LibraryScreenModel(lookup: lookup, inbox: Inbox())
        let navigator = model.navigator
        navigator.present(.settings(.root))
        XCTAssertNotNil(navigator.shown(at: 0, style: .sheet))

        model.follow(.asset(photo.id), albums: [], people: [])
        XCTAssertNil(navigator.shown(at: 0, style: .sheet), "The sheet is asked to close at once, before the photo is looked up.")
        closeEverything(navigator)
        XCTAssertTrue(navigator.layers.isEmpty)
        XCTAssertNil(navigator.viewerRoute, "Nothing opens before the photo has been looked up.")

        gate.open()
        try await until("The photo did not open.") { navigator.viewerRoute != nil }
        XCTAssertEqual(navigator.viewerRoute?.asset, photo)
        XCTAssertNil(navigator.viewerRoute?.albumContext)
        XCTAssertEqual(navigator.layers.count, 1, "Only the viewer is presented.")
        XCTAssertFalse(navigator.isFollowingLink)
    }

    func testDeepLinkLookedUpBeforeTheSheetHasClosedWaitsForIt() async throws {
        let lookup = Lookup(assets: [photo])
        let model = LibraryScreenModel(lookup: lookup, inbox: Inbox())
        let navigator = model.navigator
        navigator.present(.memories(initialID: nil))
        navigator.present(.memoryPlayer(MemoryPlayback(memories: [], initialID: "memory")), from: 1)

        model.follow(.asset(photo.id), albums: [], people: [])
        try await until("The link was not looked up.") { navigator.deferred != nil }
        XCTAssertEqual(navigator.deferred, .openAsset(photo, albumContext: nil))
        XCTAssertNil(navigator.viewerRoute, "The photo waits while the memories close.")
        XCTAssertNil(navigator.shown(at: 1, style: .cover), "The player closes first.")
        XCTAssertNotNil(navigator.shown(at: 0, style: .sheet), "The memories stay until the player has gone.")

        navigator.layerDidDismiss(level: 1)
        XCTAssertNil(navigator.viewerRoute)
        navigator.layerDidDismiss(level: 0)
        XCTAssertEqual(navigator.viewerRoute?.asset, photo, "The photo opens once everything over the library has gone.")
        XCTAssertEqual(navigator.layers.count, 1)
    }

    func testANewerLinkOvertakesTheOlderOne() async throws {
        let gate = StubServer.Gate()
        let lookup = Lookup(assets: [photo, other], gates: [photo.id: gate])
        let model = LibraryScreenModel(lookup: lookup, inbox: Inbox())
        let navigator = model.navigator

        model.follow(.asset(photo.id), albums: [], people: [])
        try await until("The first link was not looked up.") { await lookup.requests.contains("asset/" + self.photo.id) }
        model.follow(.asset(other.id), albums: [], people: [])
        try await until("The newer link did not open its photo.") { navigator.viewerRoute != nil }
        XCTAssertEqual(navigator.viewerRoute?.asset, other)

        gate.open()
        try await until("The older lookup did not finish.") { await lookup.finished.contains("asset/" + self.photo.id) }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(navigator.viewerRoute?.asset, other, "The older link, overtaken, opens nothing.")
        XCTAssertEqual(navigator.layers.count, 1)
        XCTAssertNil(navigator.deferred)
        XCTAssertFalse(navigator.isFollowingLink)
    }

    func testOpeningSomethingWhileALinkIsLookedUpOvertakesTheLink() async throws {
        let gate = StubServer.Gate()
        let lookup = Lookup(assets: [photo], gates: [photo.id: gate])
        let model = LibraryScreenModel(lookup: lookup, inbox: Inbox())
        let navigator = model.navigator

        model.follow(.asset(photo.id), albums: [], people: [])
        navigator.present(.searchOptions)
        gate.open()
        try await until("The lookup did not finish.") { await lookup.finished.contains("asset/" + self.photo.id) }
        try await until("The link was still being followed.") { !navigator.isFollowingLink }
        XCTAssertEqual(navigator.shown(at: 0, style: .sheet)?.route, .searchOptions, "What was opened since stays.")
        XCTAssertNil(navigator.deferred)
    }

    func testALinkThatCantBeFollowedSaysWhyOverTheLibrary() async throws {
        let model = LibraryScreenModel(lookup: Lookup(), inbox: Inbox())
        let navigator = model.navigator
        navigator.present(.people)

        model.follow(.album(coast.id), albums: [], people: [])
        try await until("The failure was not reported.") { navigator.deferred != nil }
        XCTAssertNil(navigator.alert, "The alert waits for the sheet, which would hide it.")
        closeEverything(navigator)
        XCTAssertEqual(navigator.alert, .error(Lookup.Missing().localizedDescription))
    }

    func testALinkClosesTheEarthsOwnSheetBeforeOpeningThePhoto() async throws {
        let model = LibraryScreenModel(lookup: Lookup(assets: [photo]), inbox: Inbox())
        let navigator = model.navigator
        navigator.raiseEarth()
        navigator.earthPresentationChanged(true)
        XCTAssertFalse(navigator.isIdle, "The Earth's list of locations counts as presented.")

        model.follow(.asset(photo.id), albums: [], people: [])
        XCTAssertTrue(navigator.earthPresentationClosing, "The Earth is asked to close its sheet at once.")
        try await until("The link was not looked up.") { navigator.deferred != nil }
        XCTAssertNil(navigator.viewerRoute, "The photo waits while the Earth's sheet is still up.")

        navigator.earthPresentationChanged(false)
        XCTAssertFalse(navigator.earthPresentationClosing)
        XCTAssertEqual(navigator.viewerRoute?.asset, photo, "The photo opens once the Earth's sheet has gone.")
        XCTAssertTrue(navigator.overlay.earth, "The Earth itself stays.")
    }

    func testTheLibraryPresentingOverTheEarthsSheetClosesItFirst() {
        let navigator = LibraryNavigator()
        navigator.raiseEarth()
        navigator.earthPresentationChanged(true)
        navigator.present(.settings(.root))
        XCTAssertTrue(navigator.earthPresentationClosing)
        XCTAssertTrue(navigator.layers.isEmpty, "Nothing presents from the library while the Earth's sheet is up.")
        navigator.earthPresentationChanged(false)
        XCTAssertEqual(navigator.shown(at: 0, style: .sheet)?.route, .settings(.root))
    }

    func testLinksUseWhatTheShelvesHoldBeforeAskingTheServer() async throws {
        let lookup = Lookup(people: [maya])
        let resolver = DeepLinkResolver(lookup: lookup)
        let album = try await resolver.intent(for: .album(coast.id), albums: [coast], people: [])
        XCTAssertEqual(album, .showAlbum(coast))
        let activity = try await resolver.intent(for: .activity(coast.id), albums: [coast], people: [])
        XCTAssertEqual(activity, .present(.activity(album: coast.id, asset: nil)))
        let requests = await lookup.requests
        XCTAssertEqual(requests, [], "An album on the shelves is not fetched with all its photos.")

        let person = try await resolver.intent(for: .person(maya.id), albums: [], people: [])
        XCTAssertEqual(person, .showPerson(maya), "A person the shelves have not loaded is looked up.")
        let memory = try await resolver.intent(for: .memory("00000000-0000-4000-8000-0000000000a1"), albums: [], people: [])
        XCTAssertEqual(memory, .present(.memories(initialID: "00000000-0000-4000-8000-0000000000a1")))
        let share = try await resolver.intent(for: .sharedFiles, albums: [], people: [])
        XCTAssertEqual(share, .present(.sharedFiles))
        let looked = await lookup.requests
        XCTAssertEqual(looked, ["person/" + maya.id])

        // A photo in an album checks that the album can be opened before the photo shows.
        let inAlbum = try await DeepLinkResolver(lookup: Lookup(assets: [photo]))
            .intent(for: .asset(photo.id, albumID: coast.id), albums: [coast], people: [])
        XCTAssertEqual(inAlbum, .openAsset(photo, albumContext: coast.id))
        do {
            _ = try await DeepLinkResolver(lookup: Lookup(assets: [photo])).intent(for: .asset(photo.id, albumID: coast.id), albums: [], people: [])
            XCTFail("A photo in an album that can't be opened is refused.")
        } catch {}
    }

    func testAFilterLinkRunsOnTheLibraryOnceTheViewerHasClosed() async throws {
        let model = LibraryScreenModel(lookup: Lookup(), inbox: Inbox())
        let navigator = model.navigator
        var performed: [NavigationIntent] = []
        navigator.perform = { performed.append($0) }
        navigator.present(.viewer(ViewerRoute(asset: photo, source: .feed, albumContext: nil)))

        model.follow(.person(maya.id), albums: [], people: [maya])
        XCTAssertNil(navigator.shown(at: 0, style: .zoom), "The viewer closes at once.")
        try await until("The link was not looked up.") { navigator.deferred != nil }
        XCTAssertEqual(performed, [])
        navigator.layerDidDismiss(level: 0)
        XCTAssertEqual(performed, [.showPerson(maya)])
    }

    /// Links are taken from the session itself rather than from the screen, which SwiftUI leaves
    /// un-updated while a full-screen viewer covers it.
    func testLinksAreTakenFromTheSessionWithoutTheScreen() async throws {
        let session = signedOutSession()
        session.pendingLink = .memory(nil)
        let model = LibraryScreenModel(lookup: Lookup(), inbox: Inbox())
        let navigator = model.navigator
        model.takeLinks(from: session) { ([], []) }
        XCTAssertNil(session.pendingLink, "A link that arrived before the library was up is taken as it comes up.")
        try await until("The memories did not open.") { navigator.shown(at: 0, style: .sheet)?.route == .memories(initialID: nil) }

        session.pendingLink = .sharedFiles
        try await until("The second link was not taken.") { session.pendingLink == nil && navigator.layers.first?.isClosing == true }
        closeEverything(navigator)
        try await until("Shared files did not open.") { navigator.shown(at: 0, style: .sheet)?.route == .sharedFiles }
    }

    // MARK: Intents

    func testShowInTimelineFromAMemoryUnwindsOnce() {
        let navigator = LibraryNavigator()
        var performed: [NavigationIntent] = []
        navigator.perform = { performed.append($0) }
        navigator.present(.memories(initialID: nil))
        navigator.present(.memoryPlayer(MemoryPlayback(memories: [], initialID: "memory")), from: 1)
        XCTAssertNotNil(navigator.shown(at: 1, style: .cover))

        navigator.send(.showInTimeline(photo))
        XCTAssertNil(navigator.shown(at: 1, style: .cover), "The player closes first.")
        XCTAssertNotNil(navigator.shown(at: 0, style: .sheet), "The memories wait for the player.")
        navigator.layerDidDismiss(level: 1)
        XCTAssertNil(navigator.shown(at: 0, style: .sheet), "Then the memories close.")
        navigator.layerDidDismiss(level: 1)
        XCTAssertEqual(performed, [], "Nothing lands while the memories are still on screen, however often the player reports.")
        navigator.layerDidDismiss(level: 0)
        XCTAssertEqual(performed, [.showInTimeline(photo)])
        navigator.layerDidDismiss(level: 0)
        navigator.layerDidDismiss(level: 1)
        XCTAssertEqual(performed, [.showInTimeline(photo)], "It lands once.")
        XCTAssertTrue(navigator.layers.isEmpty)
        XCTAssertNil(navigator.deferred)
    }

    func testOpeningAPhotoFromMoreClosesMoreThenOpensTheViewer() {
        let navigator = LibraryNavigator()
        navigator.present(.more)
        navigator.send(.openAsset(photo))
        XCTAssertNil(navigator.viewerRoute, "More closes before the viewer opens.")
        XCTAssertNil(navigator.shown(at: 0, style: .sheet))
        navigator.layerDidDismiss(level: 0)
        XCTAssertEqual(navigator.viewerRoute, ViewerRoute(asset: photo, source: .feed, albumContext: nil))
        XCTAssertNotNil(navigator.shown(at: 0, style: .zoom))
    }

    func testExploringAPhotosPlaceRaisesTheEarthOnceTheViewerHasClosed() {
        let navigator = LibraryNavigator()
        var performed: [NavigationIntent] = []
        navigator.perform = { performed.append($0) }
        navigator.present(.viewer(ViewerRoute(asset: photo, source: .feed, albumContext: nil)))
        let focus = PlaceFocus(latitude: 52.37, longitude: 4.9, assetID: photo.id)
        navigator.send(.exploreLocation(focus))
        XCTAssertTrue(navigator.isViewing, "The viewer is still closing.")
        XCTAssertEqual(performed, [])
        navigator.layerDidDismiss(level: 0)
        XCTAssertEqual(performed, [.exploreLocation(focus)])
        XCTAssertFalse(navigator.isViewing)
    }

    func testANewerIntentReplacesTheOneWaiting() {
        let navigator = LibraryNavigator()
        var performed: [NavigationIntent] = []
        navigator.perform = { performed.append($0) }
        navigator.present(.albums)
        navigator.send(.showInTimeline(photo))
        navigator.send(.showAlbum(coast))
        navigator.layerDidDismiss(level: 0)
        XCTAssertEqual(performed, [.showAlbum(coast)], "Only the newest intent runs.")
    }

    func testUnwindingDropsTheIntentWaitingAndTheAlert() {
        let navigator = LibraryNavigator()
        var performed: [NavigationIntent] = []
        navigator.perform = { performed.append($0) }
        navigator.present(.people)
        navigator.send(.showInTimeline(photo))
        let generation = navigator.generation
        XCTAssertGreaterThan(navigator.unwind(), generation)
        XCTAssertNil(navigator.deferred)
        navigator.layerDidDismiss(level: 0)
        XCTAssertEqual(performed, [])
        navigator.show(.error("Couldn’t load."))
        navigator.unwind()
        XCTAssertNil(navigator.alert)
    }

    // MARK: Layers

    func testEachLayerCountsOnce() {
        let navigator = LibraryNavigator()
        navigator.present(.people)
        // A swipe down closes the sheet: SwiftUI empties the binding, then reports the close.
        navigator.dismiss(level: 0)
        navigator.layerDidDismiss(level: 0)
        navigator.present(.albums)
        navigator.layerDidDismiss(level: 0)
        XCTAssertEqual(navigator.shown(at: 0, style: .sheet)?.route, .albums, "A late report for People leaves Albums open.")
        navigator.layerDidDismiss(level: 3)
        XCTAssertEqual(navigator.layers.count, 1, "A report for a level with nothing on it changes nothing.")
    }

    func testTheLibraryPresentingOverAScreenClosesItFirst() {
        let navigator = LibraryNavigator()
        navigator.present(.people)
        navigator.present(.albums)
        XCTAssertEqual(navigator.layers.map(\.route), [.people], "Albums waits for People to close.")
        XCTAssertNil(navigator.shown(at: 0, style: .sheet))
        navigator.layerDidDismiss(level: 0)
        XCTAssertEqual(navigator.shown(at: 0, style: .sheet)?.route, .albums)
    }

    func testAScreenPresentsOnlyWhileItIsOnTopAndStaying() {
        let navigator = LibraryNavigator()
        let playback = MemoryPlayback(memories: [], initialID: "memory")
        navigator.present(.memories(initialID: nil))
        navigator.present(.memoryPlayer(playback), from: 2)
        XCTAssertEqual(navigator.layers.count, 1, "A screen that isn't on screen presents nothing.")
        navigator.dismiss(level: 0)
        navigator.present(.memoryPlayer(playback), from: 1)
        XCTAssertEqual(navigator.layers.count, 1, "A screen on its way out presents nothing.")
        navigator.layerDidDismiss(level: 0)
        navigator.present(.memories(initialID: "memory"))
        navigator.present(.memoryPlayer(playback), from: 1)
        XCTAssertEqual(navigator.shown(at: 1, style: .cover)?.route, .memoryPlayer(playback))
    }

    func testClosingAScreenUnderAnotherClosesTheTopFirst() {
        let navigator = LibraryNavigator()
        navigator.present(.more)
        navigator.present(.memoryPlayer(MemoryPlayback(memories: [], initialID: "memory")), from: 1)
        navigator.dismiss(level: 0)
        XCTAssertNil(navigator.shown(at: 1, style: .cover))
        XCTAssertNotNil(navigator.shown(at: 0, style: .sheet))
        navigator.layerDidDismiss(level: 1)
        XCTAssertNil(navigator.shown(at: 0, style: .sheet))
        navigator.layerDidDismiss(level: 0)
        XCTAssertTrue(navigator.layers.isEmpty)
    }

    // MARK: Shared files

    func testSharedFilesWaitWhileAnyModalOrOverlayIsUp() async throws {
        let inbox = Inbox()
        let model = LibraryScreenModel(lookup: Lookup(), inbox: inbox)
        let navigator = model.navigator
        navigator.present(.people)
        inbox.batchIDs = [UUID()]
        model.refreshSharedFiles()
        try await until("Shared files did not wait.") { navigator.waiting == [.sharedFiles] }

        // People closes while the shelves are out.
        navigator.setShelves(true)
        navigator.dismiss(level: 0)
        navigator.layerDidDismiss(level: 0)
        try await settle()
        XCTAssertTrue(navigator.layers.isEmpty, "Shared files waits while the shelves are out.")
        // The shelves go in while the Earth is up.
        navigator.raiseEarth()
        navigator.setShelves(false)
        try await settle()
        XCTAssertTrue(navigator.layers.isEmpty, "Shared files waits while the Earth is up.")
        // The Earth goes down under an alert.
        navigator.show(.confirm(.signOut))
        navigator.lowerEarth()
        try await settle()
        XCTAssertTrue(navigator.layers.isEmpty, "Shared files waits while a question is asked.")
        navigator.alertDidClose(.confirm(.signOut))
        try await until("Shared files did not show once nothing else was up.") { navigator.shown(at: 0, style: .sheet)?.route == .sharedFiles }
        XCTAssertEqual(navigator.waiting, [])

        // Closing it, the same batches don't bring it back.
        navigator.dismiss(level: 0)
        navigator.layerDidDismiss(level: 0)
        model.refreshSharedFiles()
        try await settle()
        XCTAssertTrue(navigator.layers.isEmpty)
        XCTAssertEqual(navigator.waiting, [])
    }

    func testSharedFilesWaitWhileALinkIsFollowed() async throws {
        let gate = StubServer.Gate()
        let inbox = Inbox()
        let model = LibraryScreenModel(lookup: Lookup(assets: [photo], gates: [photo.id: gate]), inbox: inbox)
        let navigator = model.navigator
        model.follow(.asset(photo.id), albums: [], people: [])
        inbox.batchIDs = [UUID()]
        model.refreshSharedFiles()
        try await until("Shared files did not wait.") { navigator.waiting == [.sharedFiles] }
        gate.open()
        try await until("The photo did not open.") { navigator.viewerRoute != nil }
        try await settle()
        XCTAssertEqual(navigator.waiting, [.sharedFiles], "The link's photo opens first.")
        navigator.dismiss(level: 0)
        navigator.layerDidDismiss(level: 0)
        try await until("Shared files did not show after the photo closed.") { navigator.shown(at: 0, style: .sheet)?.route == .sharedFiles }
    }

    func testTheShareLinkMarksItsBatchesShown() async throws {
        let inbox = Inbox()
        let batch = UUID()
        inbox.onRefresh = { inbox.batchIDs = [batch] }
        let model = LibraryScreenModel(lookup: Lookup(), inbox: inbox)
        let navigator = model.navigator
        model.follow(.sharedFiles, albums: [], people: [])
        try await until("Shared files did not open.") { navigator.shown(at: 0, style: .sheet)?.route == .sharedFiles }
        navigator.dismiss(level: 0)
        navigator.layerDidDismiss(level: 0)
        model.refreshSharedFiles()
        try await settle()
        XCTAssertTrue(navigator.layers.isEmpty, "The batch the extension just shared is not shown a second time.")
        XCTAssertEqual(navigator.waiting, [])
    }

    func testOpeningSharedFilesFromTheShelvesStopsItWaiting() async throws {
        let inbox = Inbox()
        let model = LibraryScreenModel(lookup: Lookup(), inbox: inbox)
        let navigator = model.navigator
        navigator.setShelves(true)
        inbox.batchIDs = [UUID()]
        model.refreshSharedFiles()
        try await until("Shared files did not wait.") { navigator.waiting == [.sharedFiles] }
        navigator.present(.sharedFiles)
        navigator.setShelves(false)
        XCTAssertEqual(navigator.waiting, [])
        navigator.dismiss(level: 0)
        navigator.layerDidDismiss(level: 0)
        try await settle()
        XCTAssertTrue(navigator.layers.isEmpty, "Closing it doesn't bring it back.")
    }

    // MARK: Helpers

    /// A session nobody is signed in to, for its links.
    private func signedOutSession() -> AccountSession {
        var environment = AccountEnvironment()
        environment.usesDeviceStorage = false
        let dependencies = AccountDependencies(credentials: EphemeralCredentialStore(), mirror: nil,
                                               device: FakeAccountDevice(log: AccountEventLog()),
                                               clients: AccountClients { _, _, _ in throw URLError(.notConnectedToInternet) },
                                               unlockEvents: { AsyncStream { $0.finish() } })
        return AccountSession(environment: environment, dependencies: dependencies, presence: AppPresence(isForeground: false))
    }

    /// Reports every layer closed as the navigator asks, top first, as the hosts do.
    private func closeEverything(_ navigator: LibraryNavigator) {
        while let top = navigator.layers.indices.last, navigator.layers[top].isClosing {
            navigator.layerDidDismiss(level: top)
        }
    }

    /// Lets the navigator's next-turn checks run.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(50))
    }

    private func until(_ message: String, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while await !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail(message) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// The server as a link sees it: photos, albums and people it knows, some held back by a gate.
private actor Lookup: LinkLookup {
    struct Missing: LocalizedError {
        var errorDescription: String? { "This item is no longer available." }
    }

    private let assets: [String: Asset]
    private let albums: [String: Album]
    private let people: [String: Person]
    private let gates: [String: StubServer.Gate]
    private(set) var requests: [String] = []
    private(set) var finished: [String] = []

    init(assets: [Asset] = [], albums: [Album] = [], people: [Person] = [], gates: [String: StubServer.Gate] = [:]) {
        self.assets = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        self.albums = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) })
        self.people = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })
        self.gates = gates
    }

    func asset(id: String) async throws -> Asset { try await answer("asset/" + id, id, assets[id]) }
    func album(id: String) async throws -> Album { try await answer("album/" + id, id, albums[id]) }
    func person(id: String) async throws -> Person { try await answer("person/" + id, id, people[id]) }

    private func answer<T: Sendable>(_ request: String, _ id: String, _ value: T?) async throws -> T {
        requests.append(request)
        if let gate = gates[id] { await gate.wait() }
        finished.append(request)
        guard let value else { throw Missing() }
        return value
    }
}

@MainActor private final class Inbox: SharedFilesInbox {
    var batchIDs = Set<UUID>()
    var onRefresh: () -> Void = {}
    func refresh() async { onRefresh() }
}
