import Foundation
import IlyichPlatform
import Photos
import XCTest
@testable import Ilyich

/// CleanupService against fakes (REBUILD_ROADMAP.md P4, DS1 to DS12). Photos is FakePhotoKit
/// behind the real adapter and journal: nothing here can reach the phone's library.
@MainActor final class CleanupServiceTests: XCTestCase {

    // MARK: - Exclusion and abort

    /// A missing server copy excludes only that photo; the others stay candidates.
    func testAMissingServerCopyExcludesOnlyThatCandidate() async throws {
        let h = CleanupHarness(self)
        for id in ["a", "b", "c"] { h.addBackedUp(id) }
        h.remote.set("server-b", .failure(ServerFailure.notFound))

        let result = try await h.scan()

        XCTAssertEqual(Set(result.candidates.map(\.localID)), ["a", "c"])
        XCTAssertEqual(result.exclusions, ["b": .notOnServer])
    }

    /// 403s, server errors, timeouts and unreadable answers exclude one photo each; a 401 aborts
    /// the whole check, offering nothing.
    func testForbiddenAndTimeoutsExcludeIndividuallyWhile401Aborts() async throws {
        let h = CleanupHarness(self)
        for id in ["ok", "forbidden", "proxy", "timeout", "error", "garbled"] { h.addBackedUp(id) }
        h.remote.set("server-forbidden", .failure(ServerFailure.forbidden(nil)))
        h.remote.set("server-proxy", .failure(ServerFailure.proxyRejected(403)))
        h.remote.set("server-timeout", .failure(URLError(.timedOut)))
        h.remote.set("server-error", .failure(ServerFailure.http(502, nil)))
        h.remote.set("server-garbled", .failure(ServerFailure.undecodable))

        let result = try await h.scan()
        XCTAssertEqual(result.candidates.map(\.localID), ["ok"])
        XCTAssertEqual(result.exclusions, ["forbidden": .serverRefused, "proxy": .serverRefused, "timeout": .unreachable,
                                           "error": .serverError, "garbled": .unreadableAnswer])

        for expired in [ServerFailure.sessionExpired(nil), .proxyRejected(401)] {
            h.remote.set("server-timeout", .failure(expired))
            do {
                _ = try await h.scan()
                XCTFail("A 401 must abort the check.")
            } catch { XCTAssertEqual(error as? CleanupAborted, CleanupAborted()) }
            let live = await h.service.liveCandidates
            XCTAssertTrue(live.isEmpty, "An aborted check offers nothing.")
        }
    }

    /// Every phone check, in batches, happens before the first request, and a photo the phone or
    /// the settings keep costs none.
    func testLocalFiltersRunBeforeAnyNetworkRequest() async throws {
        let h = CleanupHarness(self, batchSize: 4)
        for index in 0..<10 { h.addBackedUp("photo-\(index)") }
        h.addBackedUp("recent", created: Date())
        h.addBackedUp("favorite", favorite: true)
        h.addBackedUp("edited")
        h.photos.setFacts("edited", FakePhotoKit.Facts(created: CleanupHarness.old, shape: .edited))
        let reads = Locked<[Int]>([])
        let photos = h.photos
        h.remote.onRequest { _ in reads.mutate { $0.append(photos.cleanupReads) } }

        let result = try await h.scan()

        XCTAssertEqual(result.candidates.count, 10)
        XCTAssertEqual(h.photos.cleanupReads, 4, "13 receipts in batches of 4.")
        XCTAssertEqual(Set(reads.value), [4], "Every batch was read before the first request.")
        XCTAssertFalse(h.remote.requests.contains { ["server-recent", "server-favorite", "server-edited"].contains($0) })
        XCTAssertEqual(result.exclusions, ["recent": .tooRecent, "favorite": .favorite, "edited": .edited])
    }

    func testAtMostSixChecksInFlight() async throws {
        let h = CleanupHarness(self)
        for index in 0..<30 { h.addBackedUp("photo-\(index)") }
        h.remote.delay(.milliseconds(5))

        let result = try await h.scan()

        XCTAssertEqual(result.candidates.count, 30)
        XCTAssertEqual(h.remote.maxInFlight, 6)
    }

    // MARK: - Re-verification at remove

    func testRemovalReverifiesOnlyTheSelection() async throws {
        let h = CleanupHarness(self)
        for id in ["a", "b", "c", "d"] { h.addBackedUp(id) }
        h.addBackedUp("live", live: true)
        _ = try await h.scan()
        h.remote.clearRequests()

        let result = await h.service.remove(["b", "live"])

        XCTAssertEqual(result, .removed(["b", "live"]))
        XCTAssertEqual(Set(h.remote.requests), ["server-b", "server-live", "motion-live"])
        XCTAssertEqual(h.photos.deletions.map(Set.init), [[DeviceAssetID(rawValue: "b"), DeviceAssetID(rawValue: "live")]])
        XCTAssertNotNil(h.photos.asset("a"))
    }

    /// DS5: a server copy trashed after the check stops the removal; nothing is removed.
    func testAServerCopyTrashedAfterTheScanBlocksTheRemoval() async throws {
        let h = CleanupHarness(self)
        let a = h.addBackedUp("a"); h.addBackedUp("b")
        _ = try await h.scan()
        h.remote.set(CleanupHarness.remoteAsset(a.original, trashed: true))

        let result = await h.service.remove(["a", "b"])

        XCTAssertEqual(result, .changed(["a"]))
        XCTAssertEqual(h.photos.performed, 0, "Photos was never asked.")
        XCTAssertTrue(h.photos.deletions.isEmpty)
        let live = await h.service.liveCandidates
        XCTAssertEqual(live, ["b"], "Only the trashed one is dropped.")
    }

    // MARK: - Authorization and invalidation

    /// DS6: a token change, a replaced session or an ended one deletes nothing.
    func testATokenChangeDeletesNothing() async throws {
        let h = CleanupHarness(self)
        h.addBackedUp("a")
        _ = try await h.scan()
        h.credentialCurrent.mutate { $0 = false }
        let replaced = await h.service.remove(["a"])
        XCTAssertEqual(replaced, .blocked(.sessionChanged))

        h.credentialCurrent.mutate { $0 = true }
        _ = try await h.scan()
        // The saved token changes while the selection is re-verified.
        let credential = h.credentialCurrent
        h.remote.onRequest { _ in credential.mutate { $0 = false } }
        let duringVerification = await h.service.remove(["a"])
        XCTAssertEqual(duringVerification, .blocked(.sessionChanged))

        h.remote.onRequest(nil); h.credentialCurrent.mutate { $0 = true }
        _ = try await h.scan()
        h.authorization.end()
        let ended = await h.service.remove(["a"])
        // Ending the session also invalidates the check as it is heard, whichever comes first.
        XCTAssertTrue([.blocked(.sessionChanged), .blocked(.checkAgain)].contains(ended), "\(ended)")
        XCTAssertEqual(h.photos.performed, 0)
        XCTAssertNotNil(h.photos.asset("a"))
    }

    /// DS6: read-only mode blocks removal, turned on before Remove or during re-verification.
    func testReadOnlyBlocksRemoval() async throws {
        let h = CleanupHarness(self)
        h.addBackedUp("a")
        _ = try await h.scan()
        h.authorization.setReadOnly(true)
        let before = await h.service.remove(["a"])
        XCTAssertEqual(before, .blocked(.readOnly))

        h.authorization.setReadOnly(false)
        let authorization = h.authorization
        h.remote.onRequest { _ in authorization.setReadOnly(true) }
        let during = await h.service.remove(["a"])
        XCTAssertEqual(during, .blocked(.readOnly))
        XCTAssertEqual(h.photos.performed, 0)

        // Turning it off again leaves the check standing.
        h.remote.onRequest(nil); h.authorization.setReadOnly(false)
        let after = await h.service.remove(["a"])
        XCTAssertEqual(after, .removed(["a"]))
    }

    /// DS11: settings, Photos access and a full library reload invalidate the check as a whole.
    func testSettingsAccessOrLibraryChangesInvalidateTheScan() async throws {
        let h = CleanupHarness(self)
        h.addBackedUp("a")

        _ = try await h.scan()
        h.settings.setKeepMediaType("videos")
        let settings = await h.service.remove(["a"])
        XCTAssertEqual(settings, .blocked(.checkAgain))

        _ = try await h.scan()
        h.photos.setStatus(.limited)
        let access = await h.service.remove(["a"])
        XCTAssertEqual(access, .blocked(.checkAgain))

        _ = try await h.scan()
        let events = listen(to: await h.service.events())
        h.photos.emit(PhotoLibraryChangeDetails(requiresFullReload: true))
        try await waitFor { events.value.contains(.invalidated(.library)) }
        let library = await h.service.remove(["a"])
        XCTAssertEqual(library, .blocked(.checkAgain))

        // An access epoch change, as when photos become unavailable to the account.
        _ = try await h.scan()
        h.authorization.accessChanged()
        try await waitFor { events.value.contains(.invalidated(.account)) }
        let epoch = await h.service.remove(["a"])
        XCTAssertEqual(epoch, .blocked(.checkAgain))
        XCTAssertEqual(h.photos.performed, 0)
    }

    /// DS11: a change Photos reports drops only the candidates it names.
    func testADeviceChangeDropsOnlyTheAffectedCandidates() async throws {
        let h = CleanupHarness(self)
        h.addBackedUp("a"); h.addBackedUp("b")
        _ = try await h.scan()
        let events = listen(to: await h.service.events())

        h.photos.emit(PhotoLibraryChangeDetails(changed: [DeviceAssetID(rawValue: "a")]))
        try await waitFor { events.value.contains(.dropped(["a"])) }

        let live = await h.service.liveCandidates
        XCTAssertEqual(live, ["b"])
        let result = await h.service.remove(["b"])
        XCTAssertEqual(result, .removed(["b"]))
    }

    /// A receipt change drops only that candidate; a server change only those it names.
    func testReceiptAndServerChangesDropOnlyTheirCandidates() async throws {
        let server = AsyncStream.makeStream(of: LibraryChange.self)
        let h = CleanupHarness(self, serverChanges: { server.stream })
        let a = h.addBackedUp("a"); h.addBackedUp("b"); h.addBackedUp("c")
        _ = try await h.scan()
        let events = listen(to: await h.service.events())

        h.receipts.put(CleanupReceipt(localID: "a", revision: a.revision, original: .init(id: "replacement", checksum: "x"), motion: nil))
        try await waitFor { events.value.contains(.dropped(["a"])) }

        var change = LibraryChange(account: h.authorization.account, authorization: h.authorization.snapshot.epoch, indexRevision: 1, origin: .sync)
        change.upserted = ["server-b": .init(from: nil, to: nil), "unrelated": .init(from: nil, to: nil)]
        server.continuation.yield(change)
        try await waitFor { events.value.contains(.dropped(["b"])) }

        let live = await h.service.liveCandidates
        XCTAssertEqual(live, ["c"])
    }

    /// Backup keeps writing receipts while a check runs: a new receipt for a photo outside the
    /// check, and a rewrite that changes none (as pausing backup makes), leave it standing.
    func testAnUploadFinishingMidScanDoesNotBlockRemove() async throws {
        let h = CleanupHarness(self)
        h.addBackedUp("a"); h.addBackedUp("b")
        let gate = StubServer.Gate()
        h.remote.hold(gate)
        let scan = Task { try await h.scan() }
        try await waitFor { h.remote.requests.count >= 2 }

        // An upload finishes: a new receipt for a photo the check doesn't hold.
        h.photos.add("new")
        h.receipts.put(CleanupReceipt(localID: "new", revision: AssetRevision(referenceSeconds: CleanupHarness.revision),
                                      original: .init(id: "server-new", checksum: "sha-new"), motion: nil))
        // Backup pauses: the state is written again, every receipt the same.
        h.receipts.notify()
        gate.open()

        let result = try await scan.value
        XCTAssertEqual(Set(result.candidates.map(\.localID)), ["a", "b"], "Pausing backup doesn't cancel a check.")
        h.receipts.notify()
        let removal = await h.service.remove(["a", "b"])
        XCTAssertEqual(removal, .removed(["a", "b"]))
    }

    // MARK: - Shape and deletability

    func testLivePhotoWithoutAMotionReceiptNeverQualifies() async throws {
        let h = CleanupHarness(self)
        h.addBackedUp("live")
        h.photos.setFacts("live", FakePhotoKit.Facts(created: CleanupHarness.old, shape: .livePhoto))
        let result = try await h.scan()
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.exclusions, ["live": .livePhotoWithoutVideoBackup])
        XCTAssertTrue(h.remote.requests.isEmpty)
    }

    func testALivePairOrChecksumMismatchExcludes() async throws {
        let h = CleanupHarness(self)
        let pair = h.addBackedUp("pair", live: true)
        let video = h.addBackedUp("video", live: true)
        let sum = h.addBackedUp("sum")
        h.remote.set(CleanupHarness.remoteAsset(pair.original, motion: "someone-else"))
        h.remote.set(CleanupHarness.remoteAsset(video.motion!, checksum: "different"))
        h.remote.set(CleanupHarness.remoteAsset(sum.original, checksum: "different"))

        let result = try await h.scan()

        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.exclusions, ["pair": .livePairMismatch, "video": .livePairMismatch, "sum": .checksumMismatch])
    }

    func testAnUndeletableOrEditedAssetIsExcluded() async throws {
        let h = CleanupHarness(self)
        h.addBackedUp("shared", canDelete: false)
        h.addBackedUp("raw")
        h.photos.setFacts("raw", FakePhotoKit.Facts(created: CleanupHarness.old, shape: .multipleOriginals))
        h.addBackedUp("changed")
        h.photos.touch("changed", revision: CleanupHarness.revision.nextUp)
        let result = try await h.scan()
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.exclusions, ["shared": .notDeletable, "raw": .multipleOriginals, "changed": .changedSinceBackup])
    }

    /// The critic's DS4 correction: with the Locked Folder unlocked the server shows its photos,
    /// but a copy there is not a backup cleanup relies on. Archived copies are.
    func testACopyInTheLockedFolderIsExcluded() async throws {
        let h = CleanupHarness(self)
        let locked = h.addBackedUp("locked"), archived = h.addBackedUp("archived")
        let trashed = h.addBackedUp("trashed"), other = h.addBackedUp("other"), offline = h.addBackedUp("offline")
        h.remote.set(CleanupHarness.remoteAsset(locked.original, visibility: "locked"))
        h.remote.set(CleanupHarness.remoteAsset(archived.original, visibility: "archive"))
        h.remote.set(CleanupHarness.remoteAsset(trashed.original, trashed: true))
        h.remote.set(CleanupHarness.remoteAsset(other.original, owner: "partner"))
        h.remote.set(CleanupHarness.remoteAsset(offline.original, offline: true))

        let result = try await h.scan()

        XCTAssertEqual(result.candidates.map(\.localID), ["archived"])
        XCTAssertEqual(result.exclusions, ["locked": .inLockedFolder, "trashed": .inServerTrash, "other": .otherOwner, "offline": .serverCopyOffline])
    }

    // MARK: - Removal outcomes and the gate

    /// DS10: a declined prompt removes nothing and marks no receipt; DS9: a commit is journaled
    /// with the check's origin and marks exactly the selection.
    func testDeclinedRemovesNothingAndACommitMarksTheSelection() async throws {
        let h = CleanupHarness(self)
        h.addBackedUp("a"); h.addBackedUp("b")
        _ = try await h.scan()
        h.photos.failNextChange(with: NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.userCancelled.rawValue))

        let declined = await h.service.remove(["a"])
        XCTAssertEqual(declined, .declined)
        XCTAssertNotNil(h.photos.asset("a"))
        XCTAssertTrue(h.receipts.marked.isEmpty)

        let removed = await h.service.remove(["a"])
        XCTAssertEqual(removed, .removed(["a"]))
        XCTAssertEqual(h.receipts.marked, [["a"]])
        XCTAssertNil(h.photos.asset("a"))
        XCTAssertNotNil(h.photos.asset("b"))
        let records = try await h.journal.records()
        XCTAssertEqual(records.map(\.outcome), [.declined, .committed(affected: [DeviceAssetID(rawValue: "a")], created: [])])
        guard case .delete(_, let expected, .cleanup(_, let account)) = records.last?.entry.mutation else { return XCTFail("Not a cleanup deletion.") }
        XCTAssertEqual(account, h.account)
        XCTAssertEqual(expected, [DeviceAssetID(rawValue: "a"): AssetRevision(referenceSeconds: CleanupHarness.revision)])
    }

    /// An asset edited after the check but before Remove: Photos is never asked to delete.
    func testAPhotoEditedAfterTheScanReturnsChangedWithNoDeletion() async throws {
        let h = CleanupHarness(self)
        h.addBackedUp("a"); h.addBackedUp("b")
        _ = try await h.scan()
        h.photos.touch("a", revision: CleanupHarness.revision.nextUp)

        let result = await h.service.remove(["a", "b"])

        XCTAssertEqual(result, .changed(["a"]))
        XCTAssertEqual(h.photos.requestsMade, 0)
    }

    /// Only what the current check offers can be removed (DS1).
    func testOnlyLiveCandidatesCanBeRemoved() async throws {
        let h = CleanupHarness(self)
        h.addBackedUp("a"); h.addBackedUp("kept", favorite: true)
        let none = await h.service.remove(["a"])
        XCTAssertEqual(none, .blocked(.checkAgain), "No check yet.")
        _ = try await h.scan()
        let outside = await h.service.remove(["a", "kept"])
        XCTAssertEqual(outside, .blocked(.checkAgain))
        XCTAssertEqual(h.photos.performed, 0)
    }

    /// The shipped gate: closed, a removal asks Photos for nothing, while checking still finds
    /// the real candidates.
    func testAClosedGateNeverAsksPhotos() async throws {
        let h = CleanupHarness(self, removalAllowed: CleanupRemovalGate.isOpen)
        h.addBackedUp("a")
        let result = try await h.scan()
        XCTAssertEqual(result.candidates.map(\.localID), ["a"])
        if !CleanupRemovalGate.isOpen {
            let removal = await h.service.remove(["a"])
            XCTAssertEqual(removal, .blocked(.unavailable))
            XCTAssertEqual(h.photos.performed, 0)
            XCTAssertNotNil(h.photos.asset("a"))
        }
    }

    // MARK: - Bookkeeping

    func testSizesAreRecordedForTheCandidatesOnly() async throws {
        let h = CleanupHarness(self)
        h.addBackedUp("a"); h.addBackedUp("live", live: true); h.addBackedUp("kept", favorite: true)
        let result = try await h.scan()
        XCTAssertEqual(Set(result.candidates.map(\.localID)), ["a", "live"])
        XCTAssertEqual(result.candidates.first { $0.localID == "live" }?.originalBytes, 1_500)
        XCTAssertEqual(h.receipts.recordedSizes.count, 1)
        XCTAssertEqual(Set(h.receipts.recordedSizes[0].keys), ["a", "live"])
        XCTAssertEqual(h.receipts.recordedSizes[0]["live"]?.motion, 500)
    }

    /// LegacyStateReceipts over today's backup state: receipts only for the account taken up,
    /// and sizes kept only where the receipt is still the one verified.
    func testByteCountsAreRecordedOnlyForUnchangedReceipts() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CleanupReceipts-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let date = Date(timeIntervalSinceReferenceDate: 700_000_000.125)
        var state = BackupState()
        state.receipts = [
            "same": BackupReceipt(modificationDate: date, original: BackupRemoteFile(id: "s1", checksum: "c1")),
            "replaced": BackupReceipt(modificationDate: date, original: BackupRemoteFile(id: "r2", checksum: "c2")),
        ]
        try JSONEncoder().encode(state).write(to: folder.appendingPathComponent("state.json"))
        let credential = StoredCredential(server: URL(string: "https://photos.example/api")!, token: "t", userID: "user", name: "User")
        let coordinator = BackupCoordinator()
        try coordinator.load(credential, folder: folder)
        let repository = LegacyStateReceipts(coordinator: { coordinator })

        let other = await repository.receipts(account: "someone-else")
        XCTAssertNil(other, "Another account's receipts are never read.")
        let maybeRead = await repository.receipts(account: credential.scope)
        let read = try XCTUnwrap(maybeRead)
        XCTAssertEqual(read["same"]?.revision, AssetRevision(date))
        let replacedBefore = try XCTUnwrap(read["replaced"])
        let stale = CleanupReceipt(localID: "replaced", revision: replacedBefore.revision, original: .init(id: "older", checksum: "c2"), motion: nil)

        await repository.recordSizes(["same": VerifiedSize(receipt: try XCTUnwrap(read["same"]), original: 42, motion: nil),
                                      "replaced": VerifiedSize(receipt: stale, original: 99, motion: nil)], account: credential.scope)

        XCTAssertEqual(coordinator.associations["same"]?.original.byteCount, 42)
        XCTAssertNil(coordinator.associations["replaced"]?.original.byteCount, "A receipt replaced meanwhile keeps what it has.")
        let saved = try JSONDecoder().decode(BackupState.self, from: Data(contentsOf: folder.appendingPathComponent("state.json")))
        XCTAssertEqual(saved.receipts?["same"]?.original.byteCount, 42)
    }

    /// The settings keys and defaults @AppStorage used, read as they were, and the messaging-album
    /// default applied once.
    func testCleanupSettingsStoreReadsTheExistingKeys() throws {
        let suite = "CleanupSettings-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let store = CleanupSettingsStore(defaults: defaults)

        XCTAssertEqual(store.load(), CleanupSettings(keepFavorites: true, keepMediaType: "none", keptAlbumIDs: [], cutoffDaysAgo: -1))

        defaults.set(false, forKey: "cleanupKeepFavorites")
        defaults.set("videos", forKey: "cleanupKeepMediaType")
        defaults.set(try JSONEncoder().encode(Set(["album-1"])), forKey: "cleanupKeepAlbumIDs")
        defaults.set(45, forKey: "cleanupCutoffDaysAgo")
        XCTAssertEqual(store.load(), CleanupSettings(keepFavorites: false, keepMediaType: "videos", keptAlbumIDs: ["album-1"], cutoffDaysAgo: 45))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(store.load().cutoff(now: now), Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: -45, to: now)!))

        let albums = [DeviceAlbum(id: "wa", title: "WhatsApp", count: 3, isShared: false), DeviceAlbum(id: "trip", title: "Trip", count: 9, isShared: false)]
        XCTAssertEqual(store.applyMessagingDefaults(albums: albums), ["album-1", "wa"])
        XCTAssertTrue(defaults.bool(forKey: "cleanupDefaultsInitialized"))
        store.setKeptAlbumIDs([])
        XCTAssertNil(store.applyMessagingDefaults(albums: albums), "Applied once only.")
        XCTAssertEqual(store.load().keptAlbumIDs, [])

        // Unreadable values keep everything.
        defaults.set(Data("not json".utf8), forKey: "cleanupKeepAlbumIDs")
        defaults.set("everything", forKey: "cleanupKeepMediaType")
        XCTAssertNil(store.load().keptAlbumIDs)
        XCTAssertEqual(store.load().policy(cutoff: .distantFuture).exclusion(date: .distantPast, favorite: false, video: false, inKeptAlbum: false),
                       .settingsUnreadable)
    }

    func testUnreadableKeptAlbumsKeepEveryPhoto() async throws {
        let h = CleanupHarness(self)
        h.addBackedUp("a")
        h.defaults.set(Data("{".utf8), forKey: CleanupSettingsStore.keepAlbumIDsKey)
        let result = try await h.scan()
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.exclusions, ["a": .settingsUnreadable])
    }

    func testKeptAlbumsAreReadAgainAtRemove() async throws {
        let h = CleanupHarness(self)
        h.addBackedUp("a")
        h.photos.addAlbum("kept", title: "Kept", members: [])
        h.settings.setKeptAlbumIDs(["kept"])
        _ = try await h.scan()
        h.photos.addAlbum("kept", title: "Kept", members: ["a"])
        let result = await h.service.remove(["a"])
        XCTAssertEqual(result, .changed(["a"]), "DS7: membership is fresh at remove.")
        XCTAssertEqual(h.photos.performed, 0)
    }

    // MARK: - Property test

    /// Randomized receipts, assets and server states, with a random change between check and
    /// removal. Asserts DS1 to DS8: a check offers exactly the photos an independent oracle calls
    /// safe; a removal deletes only selected live candidates still safe at removal, all or none;
    /// and Photos is asked only when every check holds.
    func testRandomizedReceiptsAssetsAndServerStatesKeepDS1ToDS8() async throws {
        var random = SplitMix64(seed: 0x1C1EA4)
        var removals = 0, refusals = 0, abortedChecks = 0
        for round in 0..<60 {
            let h = CleanupHarness(self, batchSize: 3)
            var world: [String: PropertyItem] = [:]
            for index in 0..<Int(random.next() % 9 + 2) {
                let item = PropertyItem.random(id: "r\(round)-\(index)", &random)
                world[item.id] = item
                item.install(in: h)
            }
            let aborts = world.values.contains { $0.passesLocally && $0.server == .expired }
            let safe = Set(world.values.filter(\.isSafe).map(\.id))

            let scanned: Set<String>
            do {
                scanned = Set(try await h.scan().candidates.map(\.localID))
                XCTAssertFalse(aborts, "Round \(round): a 401 must abort.")
            } catch {
                XCTAssertTrue(aborts, "Round \(round): unexpected \(error).")
                XCTAssertEqual(h.photos.performed, 0)
                abortedChecks += 1
                continue
            }
            XCTAssertEqual(scanned, safe, "Round \(round): DS2-DS4, DS7.")

            // A random selection, possibly beyond the candidates, and a random change before Remove.
            // Mostly among the candidates, as the screen offers only them; sometimes beyond.
            let pool = !scanned.isEmpty && random.next() % 10 < 7 ? scanned.sorted() : world.keys.sorted()
            var selection = Set(pool.filter { _ in random.next() % 2 == 0 })
            if selection.isEmpty, let first = pool.first { selection = [first] }
            let change = PropertyChange.random(&random)
            let target = selection.sorted().first.flatMap { world[$0] }
            if let target { change.apply(to: target, in: h) }
            let declines = random.next() % 5 == 0
            if declines { h.photos.failNextChange(with: NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.userCancelled.rawValue)) }

            let result = await h.service.remove(selection)
            let deleted = Set(h.photos.deletions.flatMap { $0 }.map(\.rawValue))

            // DS1: only selected live candidates; all or nothing.
            XCTAssertTrue(deleted.isSubset(of: selection.intersection(scanned)), "Round \(round): DS1.")
            XCTAssertTrue(deleted.isEmpty || deleted == selection, "Round \(round): all or nothing.")
            let mayRemove = selection.isSubset(of: scanned) && change == .none && !declines
            if mayRemove {
                removals += 1
                XCTAssertEqual(result, .removed(selection.sorted()), "Round \(round)")
                XCTAssertEqual(deleted, selection)
            } else {
                refusals += 1
                XCTAssertTrue(deleted.isEmpty, "Round \(round): \(change), declined \(declines), result \(result).")
                // DS8: the block asks for nothing unless every check holds; declining is iOS's answer after asking.
                XCTAssertEqual(h.photos.requestsMade, declines && selection.isSubset(of: scanned) && change == .none ? 1 : 0, "Round \(round)")
            }
            await h.service.shutdown()
        }
        // The rounds reach every branch.
        XCTAssertGreaterThan(removals, 3)
        XCTAssertGreaterThan(refusals, 10)
        XCTAssertGreaterThan(abortedChecks, 0)
    }
}

// MARK: - Property test support

/// A small seeded generator, so a failing round can be replayed.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// What the server holds for a photo's copy in a round.
enum PropertyServer: CaseIterable {
    case ok, missing, forbidden, failing, unreachable, trashed, locked, offline, otherOwner, checksum, livePair, expired
}

/// One backed-up photo in a randomized round, and the oracle for whether it is safe to remove.
struct PropertyItem {
    let id: String
    let onPhone: Bool
    let revisionMatches: Bool
    let shape: ResourceShape
    let motionReceipt: Bool
    let canDelete: Bool
    let favorite: Bool
    let recent: Bool
    let video: Bool
    let server: PropertyServer

    static func random(id: String, _ random: inout SplitMix64) -> PropertyItem {
        func chance(_ percent: UInt64) -> Bool { random.next() % 100 < percent }
        let shapes: [ResourceShape] = [.singleOriginal, .singleOriginal, .singleOriginal, .livePhoto, .livePhoto, .edited, .multipleOriginals, .other]
        let shape = shapes[Int(random.next() % UInt64(shapes.count))]
        let servers = PropertyServer.allCases
        // Mostly fine, so that rounds reach removal.
        let server: PropertyServer = chance(55) ? .ok : servers[Int(random.next() % UInt64(servers.count))]
        return PropertyItem(id: id, onPhone: chance(92), revisionMatches: chance(85), shape: shape,
                            motionReceipt: shape == .livePhoto ? chance(80) : chance(10), canDelete: chance(90),
                            favorite: chance(15), recent: chance(15), video: shape == .singleOriginal && chance(20), server: server)
    }

    /// Everything on the phone allows asking the server (default settings: keep favorites, keep
    /// neither media type, 30 days).
    var passesLocally: Bool {
        guard onPhone, revisionMatches, canDelete, !favorite, !recent else { return false }
        switch shape {
        case .singleOriginal: return !motionReceipt
        case .livePhoto: return motionReceipt
        default: return false
        }
    }

    /// A still-only receipt doesn't care what the server pairs its copy with.
    var isSafe: Bool { passesLocally && (server == .ok || (server == .livePair && !motionReceipt)) }

    @MainActor func install(in h: CleanupHarness) {
        let live = motionReceipt
        let receipt = CleanupReceipt(localID: id, revision: AssetRevision(referenceSeconds: CleanupHarness.revision),
                                     original: .init(id: "server-\(id)", checksum: "sha-\(id)"),
                                     motion: live ? .init(id: "motion-\(id)", checksum: "sha-motion-\(id)") : nil)
        h.receipts.put(receipt, notify: false)
        if onPhone {
            h.photos.add(id, revision: revisionMatches ? CleanupHarness.revision : CleanupHarness.revision + 1, isFavorite: favorite, canDelete: canDelete)
            h.photos.setFacts(id, FakePhotoKit.Facts(created: recent ? Date() : CleanupHarness.old, isVideo: video, shape: shape))
        }
        var original = CleanupHarness.remoteAsset(receipt.original, motion: receipt.motion?.id)
        var motion = receipt.motion.map { CleanupHarness.remoteAsset($0) }
        // The state applies to the still, or for a Live Photo randomly to its video.
        let onVideo = motion != nil && id.unicodeScalars.last!.value % 2 == 0
        func failure(_ error: any Error) -> FakeRemote.Answer { .failure(error) }
        var answer: FakeRemote.Answer?
        switch server {
        case .ok: break
        case .missing: answer = failure(ServerFailure.notFound)
        case .forbidden: answer = failure(ServerFailure.forbidden(nil))
        case .failing: answer = failure(ServerFailure.http(500, nil))
        case .unreachable: answer = failure(URLError(.timedOut))
        case .expired: answer = failure(ServerFailure.sessionExpired(nil))
        case .trashed, .locked, .offline, .otherOwner, .checksum:
            let copy = onVideo ? receipt.motion! : receipt.original
            let changed = CleanupHarness.remoteAsset(copy, motion: onVideo ? nil : receipt.motion?.id,
                                                     owner: server == .otherOwner ? "partner" : CleanupHarness.owner,
                                                     checksum: server == .checksum ? "other" : nil, trashed: server == .trashed,
                                                     visibility: server == .locked ? "locked" : "timeline", offline: server == .offline)
            if onVideo { motion = changed } else { original = changed }
        case .livePair:
            original = CleanupHarness.remoteAsset(receipt.original, motion: receipt.motion == nil ? "unexpected" : "another")
        }
        if let answer {
            h.remote.set(onVideo ? receipt.motion!.id : receipt.original.id, answer)
            if onVideo { h.remote.set(original) } else if let motion { h.remote.set(motion) }
        } else {
            h.remote.set(original)
            if let motion { h.remote.set(motion) }
        }
    }
}

/// What changes between a check and its removal in a randomized round.
enum PropertyChange: CaseIterable, CustomStringConvertible {
    case none, edited, trashed, readOnly, token, settings, gone, undeletable, favorited, access

    static func random(_ random: inout SplitMix64) -> PropertyChange {
        // Half the rounds change nothing, so removals happen.
        random.next() % 2 == 0 ? .none : allCases[Int(random.next() % UInt64(allCases.count))]
    }

    var description: String { "\(self)" as String }

    @MainActor func apply(to item: PropertyItem, in h: CleanupHarness) {
        switch self {
        case .none: break
        case .edited: h.photos.touch(item.id, revision: CleanupHarness.revision + 2)
        case .trashed:
            h.remote.set(CleanupHarness.remoteAsset(.init(id: "server-\(item.id)", checksum: "sha-\(item.id)"),
                                                    motion: item.motionReceipt ? "motion-\(item.id)" : nil, trashed: true))
        case .readOnly: h.authorization.setReadOnly(true)
        case .token: h.credentialCurrent.mutate { $0 = false }
        case .settings: h.settings.setKeepMediaType(item.video ? "videos" : "photos")
        case .gone: h.photos.remove(item.id)
        case .undeletable: h.photos.setDeletable(item.id, false)
        case .favorited: h.photos.setFavorite(item.id, true)
        case .access: h.photos.setStatus(.limited)
        }
    }
}
