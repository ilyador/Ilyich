import Foundation
import Photos
import XCTest
@testable import Ilyich

/// The Photos adapter, with a fake Photos: change blocks run off the main thread, all-or-nothing
/// checks inside them, a declined prompt, access with a generation, and one observer for every
/// reader.
@MainActor final class PhotoKitAdapterTests: XCTestCase {
    private let a = DeviceAssetID(rawValue: "A/L0/001")
    private let b = DeviceAssetID(rawValue: "B/L0/001")
    private let c = DeviceAssetID(rawValue: "C/L0/001")
    private let revision = AssetRevision(referenceSeconds: FakePhotoKit.revision)

    /// Screens ask from the main thread, and Photos runs a change block on a queue of its own. Each
    /// block is built outside any actor, so it runs there without Swift 6's isolation trap, and
    /// neither its reads nor its requests touch the main thread.
    func testChangeBlocksRunOffMainWithoutIsolationTrap() async throws {
        let photos = FakePhotoKit()
        photos.add(a.rawValue); photos.add(b.rawValue)
        let adapter = makeAdapter(photos)
        let still = FileManager.default.temporaryDirectory.appendingPathComponent("IMG_0001.HEIC")

        let favorited = await adapter.perform(.setFavorite([a], true, expected: [:]))
        let saved = await adapter.perform(.create(still: still, video: nil, pairedVideo: nil, origin: .saveFromServer(asset: "server-1", account: "digest")))
        let removed = await adapter.perform(.delete([b], expected: [b: revision], origin: .user))

        XCTAssertEqual(favorited.outcome, .committed(affected: [a], created: []))
        XCTAssertEqual(saved.outcome, .committed(affected: [], created: [DeviceAssetID(rawValue: "created-1")]))
        XCTAssertEqual(removed.outcome, .committed(affected: [b], created: []))
        XCTAssertEqual(photos.asset(a.rawValue)?.isFavorite, true)
        XCTAssertEqual(photos.creations.map(\.still), [still])
        XCTAssertNil(photos.asset(b.rawValue))
        XCTAssertEqual(photos.requestsMade, 3)

        // Blocks built right here, on the main actor, run on Photos' queue just the same.
        let report = ChangeReport()
        try await photos.performChanges(PhotoChanges.block(for: .setFavorite([a], false, expected: [:]), library: photos, assets: photos, report: report))
        XCTAssertEqual(report.value, ChangeReport.Value(verdict: .allowed, requested: true, created: []))
        XCTAssertEqual(photos.asset(a.rawValue)?.isFavorite, false)

        XCTAssertEqual(photos.requestsMade, 4)
        XCTAssertEqual(photos.requestsOnMainThread, 0, "Photos is asked for changes only on its own queue.")
        XCTAssertEqual(photos.readsOnMainThread, 0, "No asset is read on the main thread.")
    }

    /// DS8: a deletion asks Photos for nothing unless every photo still has the revision it was
    /// reviewed at. That is checked before Photos is asked, and again inside the change block.
    func testDeleteBlockIssuesNoRequestWhenAnyRevisionChanged() async throws {
        let photos = FakePhotoKit()
        for id in [a, b, c] { photos.add(id.rawValue) }
        let (adapter, journal) = makeAdapterAndJournal(photos)
        let removal = DeviceMutation.delete([a, b, c], expected: [a: revision, b: revision, c: revision], origin: .user)

        // Edited after the review: caught before Photos is asked, so no prompt shows.
        photos.touch(c.rawValue, revision: FakePhotoKit.revision.nextUp)
        let early = await adapter.perform(removal)
        XCTAssertEqual(early.outcome, .revisionChanged)
        XCTAssertEqual(photos.performed, 0)

        // Edited after that check, as the change begins: the block itself asks for nothing.
        let edited = c.rawValue, gone = b.rawValue
        photos.touch(edited, revision: FakePhotoKit.revision)
        photos.beforeBlock { photos.touch(edited, revision: FakePhotoKit.revision.nextUp) }
        let late = await adapter.perform(removal)
        XCTAssertEqual(late.outcome, .revisionChanged)
        XCTAssertEqual(photos.performed, 1)

        // Gone as the change begins: the same.
        photos.touch(edited, revision: FakePhotoKit.revision)
        photos.beforeBlock { photos.remove(gone) }
        let vanished = await adapter.perform(removal)
        XCTAssertEqual(vanished.outcome, .revisionChanged)
        XCTAssertEqual(photos.performed, 2)

        XCTAssertEqual(photos.requestsMade, 0, "No deletion was asked for.")
        XCTAssertNotNil(photos.asset(a.rawValue))
        XCTAssertNotNil(photos.asset(c.rawValue))
        let outcomes = try await journal.records().map(\.outcome)
        XCTAssertEqual(outcomes, [.revisionChanged, .revisionChanged], "Each change Photos was asked for is journaled and finished.")

        // An asset with no expected revision is never deleted.
        photos.add(b.rawValue)
        let unchecked = await adapter.perform(.delete([a, b], expected: [a: revision], origin: .user))
        XCTAssertEqual(unchecked.outcome, .revisionChanged)
        XCTAssertEqual(photos.requestsMade, 0)
    }

    /// An asset Photos won't let the app delete, such as one in a shared album, stops the whole
    /// deletion, before Photos is asked and inside the change if it became so meanwhile.
    func testNotDeletableAssetMakesNoRequest() async throws {
        let photos = FakePhotoKit()
        photos.add(a.rawValue); photos.add(b.rawValue, canDelete: false)
        let adapter = makeAdapter(photos)
        let removal = DeviceMutation.delete([a, b], expected: [a: revision, b: revision], origin: .user)

        let early = await adapter.perform(removal)
        XCTAssertEqual(early.outcome, .notPermitted)
        XCTAssertEqual(photos.performed, 0)

        let shared = b.rawValue
        photos.setDeletable(shared, true)
        photos.beforeBlock { photos.setDeletable(shared, false) }
        let late = await adapter.perform(removal)
        XCTAssertEqual(late.outcome, .notPermitted)
        XCTAssertEqual(photos.performed, 1)
        XCTAssertEqual(photos.requestsMade, 0)
        XCTAssertNotNil(photos.asset(a.rawValue), "One asset stops the whole deletion.")

        // Favoriting needs every asset to be editable the same way.
        photos.add(c.rawValue, canEdit: false)
        let favorite = await adapter.perform(.setFavorite([a, c], true, expected: [:]))
        XCTAssertEqual(favorite.outcome, .notPermitted)
        XCTAssertEqual(photos.requestsMade, 0)
    }

    /// DS10: declining iOS's prompt is the person's answer, never an error. The photos stay, the
    /// journal says declined, and readers of the results hear it.
    func testDeclinedSystemPromptIsNotAFailure() async throws {
        let photos = FakePhotoKit()
        photos.add(a.rawValue)
        let (adapter, journal) = makeAdapterAndJournal(photos)
        let heard = listen(to: adapter.mutations())
        photos.failNextChange(with: NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.userCancelled.rawValue))

        let declined = await adapter.perform(.delete([a], expected: [a: revision], origin: .cleanup(scan: UUID(), account: "digest")))

        XCTAssertEqual(declined.outcome, .declined)
        XCTAssertEqual(photos.requestsMade, 1, "The block asked; the person said no.")
        XCTAssertNotNil(photos.asset(a.rawValue))
        let outcomes = try await journal.records().map(\.outcome)
        XCTAssertEqual(outcomes, [.declined])
        try await waitFor { heard.value.map(\.outcome) == [.declined] }

        // The Cocoa error iOS has also used for it reads the same; other errors are failures.
        XCTAssertTrue(PhotoKitAdapter.isDeclined(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError), deleting: false))
        XCTAssertTrue(PhotoKitAdapter.isDeclined(NSError(domain: NSCocoaErrorDomain, code: -1), deleting: true))
        XCTAssertFalse(PhotoKitAdapter.isDeclined(NSError(domain: NSCocoaErrorDomain, code: -1), deleting: false))
        XCTAssertFalse(PhotoKitAdapter.isDeclined(NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.accessUserDenied.rawValue), deleting: true))
        photos.failNextChange(with: NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.invalidResource.rawValue,
                                            userInfo: [NSLocalizedDescriptionKey: "The photo’s file is damaged."]))
        let failed = await adapter.perform(.delete([a], expected: [a: revision], origin: .user))
        XCTAssertEqual(failed.outcome, .failed("The photo’s file is damaged."))
        XCTAssertNotNil(photos.asset(a.rawValue))
    }

    /// A photo is never removed twice at once: while iOS's prompt for one removal is up, another
    /// removal of the same photo is refused without asking Photos.
    func testSecondRemovalOfAPhotoBeingRemovedIsRefused() async throws {
        let photos = FakePhotoKit()
        photos.add(a.rawValue)
        let prompt = StubServer.Gate()
        addTeardownBlock { prompt.open() }
        photos.holdAtPrompt(prompt)
        let adapter = makeAdapter(photos)
        let removal = DeviceMutation.delete([a], expected: [a: revision], origin: .user)

        let first = Task { await adapter.perform(removal) }
        try await waitFor { prompt.waiting == 1 }
        let second = await adapter.perform(removal)
        guard case .failed = second.outcome else { return XCTFail("The second removal is refused, not \(second.outcome).") }
        XCTAssertEqual(photos.performed, 1, "Photos was asked once.")

        prompt.open()
        let outcome = await first.value.outcome
        XCTAssertEqual(outcome, .committed(affected: [a], created: []))
        XCTAssertEqual(photos.deletions, [[a]], "Removed once.")
    }

    /// Access has a generation that moves whenever access changes. Without read access nothing is
    /// observed or changed; once granted, the one observer starts, and it stays one.
    func testAccessGenerationMovesAndTheObserverFollowsAccess() async throws {
        let photos = FakePhotoKit(status: .notDetermined)
        photos.add(a.rawValue)
        let adapter = makeAdapter(photos)

        XCTAssertEqual(adapter.access.generation, 0, "Not read yet.")
        let unknown = await adapter.refreshAccess()
        XCTAssertEqual(unknown, DeviceAccess(status: .notDetermined, generation: 1))
        XCTAssertEqual(photos.registrations, 0, "No observer without access.")
        let refused = await adapter.perform(.setFavorite([a], true, expected: [:]))
        XCTAssertEqual(refused.outcome, .notPermitted)
        XCTAssertEqual(photos.performed, 0)

        photos.setStatus(.limited)
        let limited = await adapter.requestAccess()
        XCTAssertEqual(limited, DeviceAccess(status: .limited, generation: 2))
        XCTAssertEqual(photos.registrations, 1)
        photos.setStatus(.authorized)
        let full = await adapter.refreshAccess()
        XCTAssertEqual(full, DeviceAccess(status: .authorized, generation: 3))
        let same = await adapter.refreshAccess()
        XCTAssertEqual(same, full, "Reading the same access again moves nothing.")
        XCTAssertEqual(photos.registrations, 1, "Still the one observer.")
        XCTAssertEqual(adapter.access, full)
    }

    /// One observer for every reader. On this phone, the merged timeline and automatic backup each
    /// subscribe, and Photos still has one observer. A burst of changes reaches each of them once,
    /// merged, a quarter second after it began; the next burst is a change of its own, and so is a
    /// change of access, which needs a full reload.
    func testOneObserverCoalescesBursts() async throws {
        let photos = FakePhotoKit()
        let clock = TestClock()
        let adapter = PhotoKitAdapter(library: photos, assets: photos, journal: DeviceDatabase(url: deviceDatabaseURL()),
                                      sleep: { try await clock.sleep(for: $0) })
        let readers = (0..<3).map { _ in listen(to: adapter.changes()) }

        await adapter.refreshAccess()
        await adapter.refreshAccess()
        XCTAssertEqual(photos.registrations, 1)
        XCTAssertEqual(clock.sleeperCount, 0, "Learning access at launch is no change to report.")
        let access = DeviceAccess(status: .authorized, generation: 1)

        let x = DeviceAssetID(rawValue: "X"), y = DeviceAssetID(rawValue: "Y"), z = DeviceAssetID(rawValue: "Z"), w = DeviceAssetID(rawValue: "W")
        photos.emit(PhotoLibraryChangeDetails(inserted: [x]))
        photos.emit(PhotoLibraryChangeDetails(changed: [y]))
        photos.emit(PhotoLibraryChangeDetails(removed: [z]))
        photos.emit(PhotoLibraryChangeDetails(changed: [x, w]))
        photos.emit(PhotoLibraryChangeDetails(albumsChanged: true))
        try await clock.waitForSleepers(1)
        XCTAssertEqual(clock.sleeperCount, 1, "One window for the whole burst.")
        clock.advance(by: .milliseconds(249))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(readers.allSatisfy { $0.value.isEmpty }, "Nothing goes out before the window ends.")
        clock.advance(by: .milliseconds(1))
        try await waitFor { readers.allSatisfy { $0.value.count == 1 } }
        let burst = DeviceLibraryChange(access: access, inserted: [x], removed: [z], changed: [x, y, w], albumsChanged: true)
        for reader in readers { XCTAssertEqual(reader.value, [burst], "Each reader hears the burst once, merged.") }

        photos.emit(PhotoLibraryChangeDetails(removed: [w]))
        try await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(250))
        try await waitFor { readers.allSatisfy { $0.value.count == 2 } }
        XCTAssertEqual(readers[1].value.last, DeviceLibraryChange(access: access, removed: [w]))

        photos.setStatus(.limited)
        await adapter.refreshAccess()
        try await clock.waitForSleepers(1)
        clock.advance(by: .milliseconds(250))
        try await waitFor { readers.allSatisfy { $0.value.count == 3 } }
        XCTAssertEqual(readers[2].value.last, DeviceLibraryChange(access: DeviceAccess(status: .limited, generation: 2), requiresFullReload: true))
        XCTAssertEqual(photos.registrations, 1, "Still one observer.")
    }

    // MARK: - Support

    private func makeAdapter(_ photos: FakePhotoKit) -> PhotoKitAdapter { makeAdapterAndJournal(photos).0 }

    private func makeAdapterAndJournal(_ photos: FakePhotoKit) -> (PhotoKitAdapter, DeviceDatabase) {
        let journal = DeviceDatabase(url: deviceDatabaseURL())
        return (PhotoKitAdapter(library: photos, assets: photos, journal: journal), journal)
    }
}
