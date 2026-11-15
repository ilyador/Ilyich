import Foundation
import IlyichPlatform
import Photos
import Synchronization
import XCTest
@testable import Ilyich

/// The device index (REBUILD_ROADMAP.md P5): phone photos are read once and then only as Photos
/// names them, fingerprints live in device.sqlite and are never hashed again for the same
/// revision, and only server photos the timeline shows can claim a phone photo.
final class DeviceIndexServiceTests: XCTestCase {
    private let album = "album"
    private let taken = Date(timeIntervalSinceReferenceDate: 790_000_000)

    func testScopeChangesRefreshTimelineWithoutChangingAlbumSelection() async throws {
        let photos = FakeIndexReader()
        photos.add(item("albumed", offset: 0), in: album)
        photos.add(item("unfiled", offset: 1), in: "elsewhere")
        photos.leave("unfiled", album: "elsewhere")
        photos.add(item("excluded", offset: 2), in: "private")
        let backup = FakeBackupSource(DeviceIndexBackupInputs(included: [album], excluded: ["private"]))
        let service = makeService(photos: photos, server: FakeIndexServer(rows: []), backup: backup)
        let snapshots = listen(await service.snapshots())
        try await until("The album selection did not show.") { Set(snapshots.last?.items.keys.map { $0 } ?? []) == ["albumed"] }
        backup.inputs.scope = .entireLibrary
        try await until("The unfiled photo did not join the timeline.") { Set(snapshots.last?.items.keys.map { $0 } ?? []) == ["albumed", "unfiled"] }
        backup.inputs.scope = .selectedAlbums
        try await until("Returning to albums did not remove the unfiled photo.") { Set(snapshots.last?.items.keys.map { $0 } ?? []) == ["albumed"] }
        await service.shutdown()
    }

    func testSingleAssetChangeRereadsOnlyThatAsset() async throws {
        let photos = FakeIndexReader()
        for (offset, id) in ["a", "b", "c"].enumerated() { photos.add(item(id, offset: offset), in: album) }
        let service = makeService(photos: photos, server: FakeIndexServer(rows: []))
        let snapshots = listen(await service.snapshots())

        try await until("The phone photos did not show.") { snapshots.last?.items.count == 3 }
        XCTAssertEqual(photos.reads.sorted(), ["a", "b", "c"])
        XCTAssertEqual(snapshots.last?.timeline.localOnly.values.joined().count, 3)

        photos.reads = []
        photos.add(item("b", offset: 1, favorite: true), in: album)
        photos.emit(changed: ["b"], albumsChanged: true)
        try await until("The favorite did not show.") { snapshots.last?.items["b"]?.photo.isFavorite == true }
        XCTAssertEqual(photos.reads, ["b"], "Only the asset Photos named is read again.")

        photos.reads = []
        photos.add(item("d", offset: 3), in: album)
        photos.emit(inserted: ["d"])
        try await until("The new photo did not show.") { snapshots.last?.items["d"] != nil }
        XCTAssertEqual(photos.reads, ["d"])

        photos.reads = []
        photos.remove("a")
        photos.emit(removed: ["a"])
        try await until("The removed photo stayed.") { snapshots.last?.items["a"] == nil }
        XCTAssertEqual(photos.reads, ["a"], "A removal is checked with Photos, nothing else is read.")
        await service.shutdown()
    }

    /// Fingerprints kept in device.sqlite are used as they are: only a photo without one for its
    /// revision is hashed, and the next launch hashes nothing.
    func testKeptFingerprintsAreNotRehashed() async throws {
        let a = item("a", offset: 0), b = item("b", offset: 1), c = item("c", offset: 2)
        let database = DeviceDatabase(url: temporaryDirectory().appendingPathComponent("device.sqlite"))
        try await database.saveFingerprints(["a": DeviceFingerprint(modified: a.photo.modified, checksum: "hash-a"),
                                             "c": DeviceFingerprint(modified: c.photo.modified, checksum: "hash-c")])

        let photos = FakeIndexReader()
        for value in [a, b, c] { photos.add(value, in: album) }
        photos.checksums = ["a": "hash-a", "b": "hash-b", "c": "hash-c"]
        let server = FakeIndexServer(rows: [match("server-a", checksum: "hash-a"), match("server-b", checksum: "hash-b")])
        let service = makeService(photos: photos, server: server, database: database)
        let snapshots = listen(await service.snapshots())

        try await until("The phone photos were not matched.") {
            snapshots.last?.associations == ["a": "server-a", "b": "server-b"]
        }
        XCTAssertEqual(photos.hashed, ["b"], "Only the photo without a fingerprint is hashed.")
        XCTAssertEqual(snapshots.last?.timeline.localOnly.values.joined().map(\.id), ["c"])
        await service.shutdown()
        let kept = try await database.fingerprints()
        XCTAssertEqual(kept.mapValues(\.checksum), ["a": "hash-a", "b": "hash-b", "c": "hash-c"])

        // The next launch hashes nothing.
        let next = FakeIndexReader()
        for value in [a, b, c] { next.add(value, in: album) }
        next.checksums = photos.checksums
        let relaunched = makeService(photos: next, server: server, database: database)
        let again = listen(await relaunched.snapshots())
        try await until("The relaunch did not match.") { again.last?.associations == ["a": "server-a", "b": "server-b"] }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(next.hashed, [])
        await relaunched.shutdown()
    }

    func testPhoneCopyOfTrashedServerAssetStaysVisibleAsLocal() async throws {
        let entities = try LibraryIndex(scope: "server|alice", userID: "alice", directory: temporaryDirectory())
        _ = try await entities.prepare(sessionFingerprint: "session")
        _ = try await entities.apply([
            serverAsset("kept", checksum: "hash-kept"),
            serverAsset("trashed", checksum: "hash-trashed", deleted: true),
            serverAsset("archived", checksum: "hash-archived", visibility: "archive"),
            SyncEvents.complete(),
        ], epoch: entities.epoch())

        let photos = FakeIndexReader()
        for (offset, id) in ["kept", "trashed", "archived"].enumerated() { photos.add(item("phone-" + id, offset: offset), in: album) }
        photos.checksums = ["phone-kept": "hash-kept", "phone-trashed": "hash-trashed", "phone-archived": "hash-archived"]
        let server = LibraryIndexIdentities(entities: entities, libraryChanges: { AsyncStream { _ in } })
        let service = makeService(photos: photos, server: server)
        let snapshots = listen(await service.snapshots())

        try await until("The phone photos were not hashed.") { photos.hashed.count == 3 && snapshots.last?.associations.isEmpty == false }
        try await Task.sleep(for: .milliseconds(100))
        let snapshot = try XCTUnwrap(snapshots.last)
        XCTAssertEqual(snapshot.associations, ["phone-kept": "kept"])
        XCTAssertEqual(Set(snapshot.timeline.localOnly.values.joined().map(\.id)), ["phone-trashed", "phone-archived"],
                       "A phone copy of a trashed or archived photo shows as a phone photo.")
        XCTAssertEqual(Set(snapshot.device().months.values.flatMap(\.assets).map(\.id.rawValue)), ["phone-trashed", "phone-archived"])
        await service.shutdown()
    }

    /// Receipts match first, then cloud identity for an unedited photo, as DeviceTimelineIndex did;
    /// a receipt for an older revision doesn't.
    func testReceiptsAndCloudIdentityMatchAsBefore() async throws {
        let photos = FakeIndexReader()
        let uploaded = item("uploaded", offset: 0), edited = item("edited", offset: 1)
        let cloud = DeviceTimelineItem(photo: LocalPhoto(id: "cloud", date: taken, modified: taken, latitude: 1, longitude: 2),
                                       cloudID: "cloud-1", unadjusted: true)
        for value in [uploaded, edited, cloud] { photos.add(value, in: album) }
        let server = FakeIndexServer(rows: [match("server-uploaded", checksum: "u"), match("server-edited", checksum: "e"),
                                            match("server-cloud", checksum: "c", cloudID: "cloud-1", createdAt: taken, latitude: 1, longitude: 2)])
        func receipt(_ value: DeviceTimelineItem, _ remote: String, _ checksum: String, revision: Double) -> CleanupReceipt {
            CleanupReceipt(localID: value.photo.id, revision: AssetRevision(referenceSeconds: revision),
                           original: .init(id: remote, checksum: checksum), motion: nil)
        }
        let backup = FakeBackupSource(DeviceIndexBackupInputs(included: [album], receipts: [
            "uploaded": receipt(uploaded, "server-uploaded", "u", revision: uploaded.photo.modified!.timeIntervalSinceReferenceDate),
            "edited": receipt(edited, "server-edited", "e", revision: 1),
        ]))
        photos.failing = true
        let service = makeService(photos: photos, server: server, backup: backup)
        let snapshots = listen(await service.snapshots())
        try await until("Nothing was matched.") { snapshots.last?.associations == ["uploaded": "server-uploaded", "cloud": "server-cloud"] }
        XCTAssertEqual(snapshots.last?.timeline.remoteToLocal["server-uploaded"]?.id, "uploaded")
        XCTAssertEqual(snapshots.last?.timeline.localOnly.values.joined().map(\.id), ["edited"])

        // Backup's albums changing drops what left them.
        backup.inputs = DeviceIndexBackupInputs(included: [], receipts: [:])
        try await until("Leaving every album did not empty the phone's photos.") { snapshots.last?.items.isEmpty == true }
        await service.shutdown()
    }

    /// A favorite moves a photo in or out of the Favorites smart album, which Photos reports only
    /// as a change to the photo.
    func testAFavoriteMovesAPhotoInAndOutOfAFavoritesBackupAlbum() async throws {
        let photos = FakeIndexReader()
        photos.add(item("a", offset: 0), in: album)
        photos.add(item("x", offset: 1), in: "elsewhere")
        let backup = FakeBackupSource(DeviceIndexBackupInputs(included: [album, "favorites"]))
        let service = makeService(photos: photos, server: FakeIndexServer(rows: []), backup: backup)
        let snapshots = listen(await service.snapshots())
        try await until("The phone photos did not show.") { snapshots.last?.items.count == 1 }

        photos.add(item("x", offset: 1, favorite: true), in: "favorites")
        photos.emit(changed: ["x"])
        try await until("The new favorite did not join the library.") { snapshots.last?.items["x"]?.photo.isFavorite == true }

        photos.add(item("x", offset: 1), in: "elsewhere")
        photos.leave("x", album: "favorites")
        photos.emit(changed: ["x"])
        try await until("The photo no longer a favorite stayed.") { snapshots.last?.items["x"] == nil }
        XCTAssertNotNil(snapshots.last?.items["a"])
        await service.shutdown()
    }

    /// A phone photo uploaded as a server photo the timeline doesn't show stays a phone photo and
    /// is never hashed: the server keeps one checksum per owner, so no fingerprint could match.
    func testPhonePhotoUploadedAsAHiddenServerPhotoIsNotHashed() async throws {
        let photos = FakeIndexReader()
        let uploaded = item("uploaded", offset: 0), other = item("other", offset: 2)
        let cloud = DeviceTimelineItem(photo: LocalPhoto(id: "cloud", date: taken, modified: taken, latitude: 1, longitude: 2),
                                       cloudID: "cloud-1", unadjusted: true)
        for value in [uploaded, cloud, other] { photos.add(value, in: album) }
        photos.checksums = ["uploaded": "a", "cloud": "c", "other": "k"]
        let server = FakeIndexServer(rows: [
            match("server-archived", checksum: "a", visible: false),
            match("server-cloud", checksum: "c", cloudID: "cloud-1", createdAt: taken, latitude: 1, longitude: 2, visible: false),
            match("server-kept", checksum: "k"),
        ])
        let backup = FakeBackupSource(DeviceIndexBackupInputs(included: [album], receipts: [
            "uploaded": CleanupReceipt(localID: "uploaded", revision: AssetRevision(referenceSeconds: uploaded.photo.modified!.timeIntervalSinceReferenceDate),
                                       original: .init(id: "server-archived", checksum: "a"), motion: nil),
        ]))
        let service = makeService(photos: photos, server: server, backup: backup)
        let snapshots = listen(await service.snapshots())
        try await until("The other photo was not matched.") { snapshots.last?.associations == ["other": "server-kept"] }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(photos.hashed, ["other"], "Photos uploaded as hidden server photos are not hashed.")
        XCTAssertEqual(Set(snapshots.last?.timeline.localOnly.values.joined().map(\.id) ?? []), ["uploaded", "cloud"])
        await service.shutdown()
    }

    func testNothingIsReadInTheBackground() async throws {
        let photos = FakeIndexReader()
        photos.add(item("a", offset: 0), in: album)
        let presence = AppPresence(isForeground: false)
        let service = makeService(photos: photos, server: nil, presence: presence)
        let snapshots = listen(await service.snapshots())
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(photos.reads, [])
        presence.isForeground = true
        await service.presenceChanged()
        try await until("The phone photos did not show once in front.") { snapshots.last?.items.count == 1 }
        await service.shutdown()
    }

    func testAJournalOnlyDatabaseGainsFingerprintsAndKeepsItsEntries() async throws {
        let url = temporaryDirectory().appendingPathComponent("device.sqlite")
        do {
            let old = try DeviceSQLite(url: url)
            try old.execute("""
                CREATE TABLE device_mutation(id TEXT PRIMARY KEY,account_digest TEXT,kind TEXT NOT NULL,origin TEXT NOT NULL,\
                asset_ids TEXT NOT NULL,expected_revisions TEXT NOT NULL,created_at REAL NOT NULL,finished_at REAL,outcome TEXT,detail TEXT)
                """)
            try old.execute(#"INSERT INTO device_mutation(id,kind,origin,asset_ids,expected_revisions,created_at) VALUES('0E9A1F3C-5B7D-4E2F-8A6C-1B3D5F7A9C2E','favorite','{"kind":"user"}','["A"]','{}',1)"#)
            try old.execute("PRAGMA user_version=1")
        }
        let database = DeviceDatabase(url: url)
        try await database.saveFingerprints(["A": DeviceFingerprint(revision: 2.5, checksum: "x")])
        let records = try await database.records()
        XCTAssertEqual(records.count, 1)
        let fingerprints = try await database.fingerprints()
        XCTAssertEqual(fingerprints, ["A": DeviceFingerprint(revision: 2.5, checksum: "x")])
        XCTAssertEqual(try DeviceSQLite(url: url).query("PRAGMA user_version").first?.first, .real(2))
    }

    func testWholeLibraryKeepsUnresolvedCopiesOutOfTheServerTimelineWithoutDroppingBackupItems() async throws {
        let photos = FakeIndexReader()
        photos.add(item("unknown-copy", offset: 0), in: album)
        photos.add(item("distinct-local", offset: 1), in: album)
        photos.checksums = ["distinct-local": "new-local-checksum"]
        let server = FakeIndexServer(rows: [match("already-on-server", checksum: "server-checksum")])
        let backup = FakeBackupSource(DeviceIndexBackupInputs(scope: .entireLibrary))
        let service = makeService(photos: photos, server: server, backup: backup)
        let snapshots = listen(await service.snapshots())
        try await until("The locally readable distinct photo did not become visible.") {
            snapshots.last?.timeline.localOnly.values.joined().map(\.id) == ["distinct-local"]
        }
        let snapshot = try XCTUnwrap(snapshots.last)
        XCTAssertEqual(Set(snapshot.items.keys), ["unknown-copy", "distinct-local"], "Backup still indexes the full selection.")
        XCTAssertNil(snapshot.associations["unknown-copy"], "An unavailable original is unknown, not a guessed match or a proven cloud-only file.")
        let remote = Asset(id: "already-on-server")
        let rows = MonthProjector.entries(remote: [remote], phoneOnly: Array(snapshot.timeline.localOnly.values.joined()), matches: [:])
        XCTAssertEqual(Set(rows.map(\.id)), ["already-on-server", "local:distinct-local"])
        await service.shutdown()
    }

    func testWholeLibraryWaitsForCompleteServerIdentitiesAndUsesLaterExactMatches() async throws {
        let photos = FakeIndexReader()
        let local = item("phone", offset: 0)
        photos.add(local, in: album)
        let database = DeviceDatabase(url: temporaryDirectory().appendingPathComponent("device.sqlite"))
        try await database.saveFingerprints(["phone": DeviceFingerprint(modified: local.photo.modified, checksum: "same")])
        let server = ResolvingIndexServer(rows: nil)
        let backup = FakeBackupSource(DeviceIndexBackupInputs(scope: .entireLibrary))
        let service = makeService(photos: photos, server: server, backup: backup, database: database)
        let snapshots = listen(await service.snapshots())
        try await until("The unresolved phone item was not indexed.") { snapshots.last?.items.count == 1 }
        XCTAssertTrue(snapshots.last?.timeline.localOnly.isEmpty == true, "A partial server index cannot prove a local copy is distinct.")
        server.rows = [match("server", checksum: "same")]
        // A server change wakes a fresh identity read, without hashing the original again.
        try await until("The server change stream did not subscribe.") { server.listenerCount > 0 }
        server.changed()
        try await until("The completed server identity did not replace the unresolved local row.") {
            snapshots.last?.associations == ["phone": "server"]
        }
        XCTAssertTrue(snapshots.last?.timeline.localOnly.isEmpty == true)
        XCTAssertEqual(photos.hashed, [])
        await service.shutdown()
    }

    func testKnownServerCopyResolvesBeforeAnyOriginalRequestEvenWithoutAnInitialIndexPass() async throws {
        let photos = FakeIndexReader()
        let local = item("phone", offset: 0)
        photos.add(local, in: album)
        photos.failing = true
        let account = AccountID(server: URL(string: "https://photos.example/api")!, userID: "alice")
        let authorization = AuthorizationState(account: account, token: "token", readOnly: true, requiresPasswordChange: false, mirror: nil)
        let receipt = CleanupReceipt(localID: "phone", revision: AssetRevision(local.photo.modified!),
                                     original: .init(id: "server", checksum: "exact"), motion: nil)
        let backup = FakeBackupSource(DeviceIndexBackupInputs(receipts: ["phone": receipt]))
        let copy = DeviceServerCopy(identity: match("server", checksum: "exact"), asset: Asset(id: "server", ownerId: "alice"))
        let server = ResolvingIndexServer(rows: nil, lookup: { _ in copy })
        let service = DeviceIndexService(account: account.digest, reader: photos, server: server, backup: backup,
                                        database: DeviceDatabase(url: temporaryDirectory().appendingPathComponent("device.sqlite")),
                                        presence: AppPresence(isForeground: true), authorization: authorization)
        let resolved = await service.resolveSource(of: local.photo)
        XCTAssertEqual(resolved, .server(copy.asset), "Read-only browsing may open an exact owned server copy.")
        XCTAssertEqual(photos.hashed, [], "Resolving a known server copy never asks for the unavailable original.")
        XCTAssertEqual(server.lookedUp, ["server"])
        photos.setAccess(.denied)
        let denied = await service.resolveSource(of: local.photo)
        if case .unavailable = denied {} else { XCTFail("Denied Photos access must not open either source.") }
        photos.setAccess(.authorized)
        authorization.end()
        let signedOut = await service.resolveSource(of: local.photo)
        if case .unavailable = signedOut {} else { XCTFail("An ended account cannot open a source.") }
        await service.shutdown()
    }

    func testServerResolutionRechecksAuthorizationAndLocalRevisionAfterTheLookup() async throws {
        for revokeAccess in [false, true] {
            let photos = FakeIndexReader()
            let local = item("phone", offset: 0)
            photos.add(local, in: album)
            let account = AccountID(server: URL(string: "https://photos.example/api")!, userID: "alice")
            let authorization = AuthorizationState(account: account, token: "token", readOnly: false, requiresPasswordChange: false, mirror: nil)
            let receipt = CleanupReceipt(localID: "phone", revision: AssetRevision(local.photo.modified!),
                                         original: .init(id: "server", checksum: "exact"), motion: nil)
            let backup = FakeBackupSource(DeviceIndexBackupInputs(receipts: ["phone": receipt]))
            let gate = TransferGate()
            let copy = DeviceServerCopy(identity: match("server", checksum: "exact"), asset: Asset(id: "server", ownerId: "alice"))
            let server = ResolvingIndexServer(rows: [], lookup: { _ in await gate.wait(); return copy })
            let service = DeviceIndexService(account: account.digest, reader: photos, server: server, backup: backup,
                                            database: DeviceDatabase(url: temporaryDirectory().appendingPathComponent("device.sqlite")),
                                            presence: AppPresence(isForeground: true), authorization: authorization)
            let lookup = Task { await service.resolveSource(of: local.photo) }
            try await until("The exact server lookup did not start.") { gate.waiting == 1 }
            if revokeAccess { authorization.accessChanged() }
            else { photos.add(item("phone", offset: 1), in: album) }
            gate.open()
            let resolved = await lookup.value
            if case .unavailable = resolved {} else { XCTFail("An earlier local revision or access epoch cannot authorize a viewer after its lookup finishes.") }
            await service.shutdown()
        }
    }

    func testServerResolutionRejectsMissingForeignHiddenAndStaleReceiptsWithoutGuessing() async throws {
        let photos = FakeIndexReader()
        let local = item("phone", offset: 0)
        photos.add(local, in: album)
        let account = AccountID(server: URL(string: "https://photos.example/api")!, userID: "alice")
        let authorization = AuthorizationState(account: account, token: "token", readOnly: false, requiresPasswordChange: false, mirror: nil)
        let receipt = CleanupReceipt(localID: "phone", revision: AssetRevision(local.photo.modified!),
                                     original: .init(id: "server", checksum: "exact"), motion: nil)
        let backup = FakeBackupSource(DeviceIndexBackupInputs(receipts: ["phone": receipt]))
        var hidden = Asset(id: "server", ownerId: "alice")
        hidden.visibility = .locked
        let replies = [DeviceServerCopy(identity: match("server", checksum: "exact"), asset: Asset(id: "server", ownerId: "someone-else")),
                       DeviceServerCopy(identity: match("server", checksum: "exact"), asset: hidden),
                       DeviceServerCopy(identity: match("server", checksum: "changed"), asset: Asset(id: "server", ownerId: "alice"))]
        for reply in replies {
            let server = ResolvingIndexServer(rows: [], lookup: { _ in reply })
            let service = DeviceIndexService(account: account.digest, reader: photos, server: server, backup: backup,
                                            database: DeviceDatabase(url: temporaryDirectory().appendingPathComponent("device.sqlite")),
                                            presence: AppPresence(isForeground: true), authorization: authorization)
            let resolved = await service.resolveSource(of: local.photo)
            XCTAssertEqual(resolved, .device(local.photo))
            await service.shutdown()
        }
        let missing = ResolvingIndexServer(rows: [], lookup: { _ in throw ServerFailure.notFound })
        let service = makeService(photos: photos, server: missing, backup: backup)
        let removed = await service.resolveSource(of: local.photo)
        XCTAssertEqual(removed, .device(local.photo), "A 404 must fall back to the local route rather than a stale offline record.")
        backup.inputs.receipts = [:]
        let unknown = await service.resolveSource(of: local.photo)
        XCTAssertEqual(unknown, .device(local.photo))
        XCTAssertEqual(missing.lookedUp, ["server"], "No known identity means no filename, date or unrelated ID search.")
        XCTAssertEqual(photos.hashed, [])
        await service.shutdown()
    }

    func testKnownServerOutagesStayDistinctFromDeviceSourcesAndAccessRefusals() async throws {
        let photos = FakeIndexReader()
        let local = item("phone", offset: 0)
        photos.add(local, in: album)
        let receipt = CleanupReceipt(localID: "phone", revision: AssetRevision(local.photo.modified!),
                                     original: .init(id: "known-server", checksum: "exact"), motion: nil)
        let backup = FakeBackupSource(DeviceIndexBackupInputs(receipts: ["phone": receipt]))
        let failures: [any Error] = [URLError(.notConnectedToInternet), ServerFailure.http(500, "Unavailable"), ServerFailure.forbidden(nil)]
        for (index, failure) in failures.enumerated() {
            let server = ResolvingIndexServer(rows: [], lookup: { _ in throw failure })
            let service = makeService(photos: photos, server: server, backup: backup)
            let resolved = await service.resolveSource(of: local.photo)
            if index == 2 {
                if case .unavailable = resolved {} else { XCTFail("A refusal cannot authorize a server or device fallback.") }
            } else if case .serverUnavailable(let photo, let serverID, let message) = resolved {
                XCTAssertEqual(photo, local.photo)
                XCTAssertEqual(serverID, "known-server")
                XCTAssertFalse(message.isEmpty)
            } else { XCTFail("A known server outage must not become an unmatched device source or iCloud prompt.") }
            await service.shutdown()
        }
        XCTAssertEqual(photos.hashed, [])
    }

    func testAPersistedExactMatchWithoutAnIlyichReceiptResolvesBeforeTheTimelineIndexStarts() async throws {
        let photos = FakeIndexReader()
        let local = item("phone", offset: 0)
        photos.add(local, in: album)
        let database = DeviceDatabase(url: temporaryDirectory().appendingPathComponent("device.sqlite"))
        try await database.saveFingerprints(["phone": DeviceFingerprint(modified: local.photo.modified, checksum: "exact")])
        photos.failing = true
        let copy = DeviceServerCopy(identity: match("known-server", checksum: "exact"), asset: Asset(id: "known-server", ownerId: "alice"))
        let server = ResolvingIndexServer(rows: [copy.identity], lookup: { _ in copy })
        let backup = FakeBackupSource(DeviceIndexBackupInputs(scope: .entireLibrary))
        let service = makeService(photos: photos, server: server, backup: backup, database: database)
        let resolved = await service.resolveSource(of: local.photo)
        XCTAssertEqual(resolved, .server(copy.asset))
        let snapshot = await service.snapshot
        XCTAssertNil(snapshot, "Opening the phone browser does not need a full timeline/index pass first.")
        XCTAssertEqual(photos.hashed, [], "Receipt-less resolution reuses exact known identity and never downloads or rehashes the original.")
        await service.shutdown()
    }

    func testTargetedServerIdentitiesAreExactOwnerScopedAndAvailableDuringInitialSync() async throws {
        let entities = try LibraryIndex(scope: "server|alice", userID: "alice", directory: temporaryDirectory())
        _ = try await entities.prepare(sessionFingerprint: "session")
        _ = try await entities.apply([
            serverAsset("own", checksum: "exact"), serverAsset("other", checksum: "different"),
            serverAsset("foreign", checksum: "exact", owner: "bob"),
        ], epoch: entities.epoch())
        let ready = try await entities.isComplete()
        XCTAssertFalse(ready)
        let matches = try await entities.identities(checksum: "exact", cloudID: nil)
        XCTAssertEqual(matches.map(\.assetID), ["own"])
        let absent = try await entities.identities(checksum: "not-present", cloudID: nil)
        XCTAssertTrue(absent.isEmpty)
        let foreign = try await entities.identity(id: "foreign")
        XCTAssertNil(foreign)
    }

    // MARK: - Support

    private func makeService(photos: FakeIndexReader, server: (any DeviceIndexServer)?, backup: FakeBackupSource? = nil,
                             database: DeviceDatabase? = nil,
                             presence: AppPresence = AppPresence(isForeground: true)) -> DeviceIndexService {
        DeviceIndexService(account: "digest", reader: photos, server: server,
                           backup: backup ?? FakeBackupSource(DeviceIndexBackupInputs(included: [album])),
                           database: database ?? DeviceDatabase(url: temporaryDirectory().appendingPathComponent("device.sqlite")),
                           presence: presence, pause: .zero, coalescing: .zero, powerAllowsHashing: { true })
    }

    private func item(_ id: String, offset: Int, favorite: Bool = false) -> DeviceTimelineItem {
        let date = taken.addingTimeInterval(Double(offset) * 60)
        return DeviceTimelineItem(photo: LocalPhoto(id: id, date: date, modified: date.addingTimeInterval(0.25), isFavorite: favorite),
                                  cloudID: nil, unadjusted: false, shape: .singleOriginal, canDelete: true, canEditProperties: true)
    }

    private func match(_ id: String, checksum: String, cloudID: String? = nil, createdAt: Date? = nil,
                       latitude: Double? = nil, longitude: Double? = nil, visible: Bool = true) -> LocalAssetMatch {
        LocalAssetMatch(assetID: id, checksum: checksum, cloudID: cloudID, createdAt: createdAt, adjustmentTime: nil,
                        latitude: latitude, longitude: longitude, visible: visible)
    }

    private func serverAsset(_ id: String, checksum: String, visibility: String = "timeline", deleted: Bool = false, owner: String = "alice") -> EntitySyncEvent {
        SyncEvents.event("AssetV2", """
        {"id":"\(id)","ownerId":"\(owner)","type":"IMAGE","originalFileName":"\(id).jpg","checksum":"\(checksum)","checksumAlgorithm":"sha1","fileCreatedAt":"2026-02-01T05:00:00Z","localDateTime":"2026-02-01T05:00:00Z","createdAt":"2026-03-01T00:00:00Z","visibility":"\(visibility)","isFavorite":false,"deletedAt":\(deleted ? "\"2026-03-04T00:00:00Z\"" : "null"),"stackId":null,"isEdited":false,"isDeveloped":false,"mediaRevision":"r1"}
        """, ack: "AssetV2|\(id)")
    }

    private func listen(_ stream: AsyncStream<DeviceIndexSnapshot>) -> Heard {
        let heard = Heard()
        let task = Task { for await snapshot in stream { heard.append(snapshot) } }
        addTeardownBlock { task.cancel() }
        return heard
    }

    private func temporaryDirectory() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DeviceIndexServiceTests-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func until(_ message: String, within timeout: Duration = .seconds(5), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(message)
        throw CancellationError()
    }
}

/// The snapshots a test heard.
private final class Heard: Sendable {
    private let values = Mutex<[DeviceIndexSnapshot]>([])
    func append(_ value: DeviceIndexSnapshot) { values.withLock { $0.append(value) } }
    var last: DeviceIndexSnapshot? { values.withLock { $0.last } }
}

/// Photos as the device index reads it.
private final class FakeIndexReader: DeviceIndexReading {
    private struct State {
        var items: [String: DeviceTimelineItem] = [:]
        var albums: [String: Set<String>] = [:]
        var checksums: [String: String] = [:]
        var reads: [String] = []
        var hashed: [String] = []
        var failing = false
        var access = DeviceAccess(status: .authorized, generation: 1)
        var continuations: [AsyncStream<DeviceLibraryChange>.Continuation] = []
    }
    private let state = Mutex(State())
    private var accessValue: DeviceAccess { state.withLock { $0.access } }
    func setAccess(_ status: PHAuthorizationStatus) {
        state.withLock { $0.access = DeviceAccess(status: status, generation: $0.access.generation + 1) }
    }

    func add(_ item: DeviceTimelineItem, in album: String) {
        state.withLock { $0.items[item.photo.id] = item; $0.albums[album, default: []].insert(item.photo.id) }
    }
    func remove(_ id: String) {
        state.withLock { state in
            state.items[id] = nil
            for key in state.albums.keys { state.albums[key]?.remove(id) }
        }
    }
    func leave(_ id: String, album: String) { state.withLock { _ = $0.albums[album]?.remove(id) } }
    var reads: [String] {
        get { state.withLock { $0.reads } }
        set { state.withLock { $0.reads = newValue } }
    }
    var hashed: [String] { state.withLock { $0.hashed } }
    var checksums: [String: String] {
        get { state.withLock { $0.checksums } }
        set { state.withLock { $0.checksums = newValue } }
    }
    /// Hashing fails, as for a photo only in iCloud.
    var failing: Bool {
        get { state.withLock { $0.failing } }
        set { state.withLock { $0.failing = newValue } }
    }

    func emit(inserted: Set<String> = [], removed: Set<String> = [], changed: Set<String> = [], albumsChanged: Bool = false) {
        var change = DeviceLibraryChange(access: accessValue)
        change.inserted = Set(inserted.map(DeviceAssetID.init(rawValue:)))
        change.removed = Set(removed.map(DeviceAssetID.init(rawValue:)))
        change.changed = Set(changed.map(DeviceAssetID.init(rawValue:)))
        change.albumsChanged = albumsChanged
        for continuation in state.withLock({ $0.continuations }) { continuation.yield(change) }
    }

    func access() async -> DeviceAccess { accessValue }
    func changes() -> AsyncStream<DeviceLibraryChange> {
        let (stream, continuation) = AsyncStream.makeStream(of: DeviceLibraryChange.self)
        state.withLock { $0.continuations.append(continuation) }
        return stream
    }
    func members(scope: PhotoSelectionScope, included: Set<String>, excluded: Set<String>) async throws -> Set<String> {
        state.withLock { state in
            (scope == .entireLibrary ? Set(state.items.keys) : included.reduce(into: Set<String>()) { $0.formUnion(state.albums[$1] ?? []) })
                .subtracting(excluded.reduce(into: Set<String>()) { $0.formUnion(state.albums[$1] ?? []) })
        }
    }
    func items(_ ids: [String]) async throws -> [DeviceTimelineItem] {
        state.withLock { state in
            state.reads += ids
            return ids.compactMap { state.items[$0] }
        }
    }
    func fingerprint(of id: String) async throws -> String {
        try state.withLock { state in
            state.hashed.append(id)
            guard !state.failing, let checksum = state.checksums[id] else { throw CocoaError(.fileReadNoSuchFile) }
            return checksum
        }
    }
    func revision(of id: String) async -> Date? { state.withLock { $0.items[id]?.photo.modified } }
}

private struct FakeIndexServer: DeviceIndexServer {
    let rows: [LocalAssetMatch]
    func identities() async throws -> [LocalAssetMatch]? { rows }
    func changes() async -> AsyncStream<LibraryChange> { AsyncStream { _ in } }
}

private final class ResolvingIndexServer: DeviceIndexServer {
    private struct State {
        var rows: [LocalAssetMatch]?
        var lookedUp: [String] = []
        var listeners: [AsyncStream<LibraryChange>.Continuation] = []
    }
    private let state: Mutex<State>
    private let lookup: @Sendable (String) async throws -> DeviceServerCopy?

    init(rows: [LocalAssetMatch]?, lookup: @escaping @Sendable (String) async throws -> DeviceServerCopy? = { _ in nil }) {
        state = Mutex(State(rows: rows))
        self.lookup = lookup
    }
    var rows: [LocalAssetMatch]? {
        get { state.withLock { $0.rows } }
        set { state.withLock { $0.rows = newValue } }
    }
    var lookedUp: [String] { state.withLock { $0.lookedUp } }
    var listenerCount: Int { state.withLock { $0.listeners.count } }
    func identities() async throws -> [LocalAssetMatch]? { rows }
    func copy(id: String) async throws -> DeviceServerCopy? {
        state.withLock { $0.lookedUp.append(id) }
        return try await lookup(id)
    }
    func changes() async -> AsyncStream<LibraryChange> {
        let (stream, continuation) = AsyncStream.makeStream(of: LibraryChange.self)
        state.withLock { $0.listeners.append(continuation) }
        return stream
    }
    func changed() {
        // A minimal account change is enough to invalidate the identity rows.
        let account = AccountID(server: URL(string: "https://photos.example/api")!, userID: "alice")
        let change = LibraryChange(account: account, authorization: AuthorizationEpoch(account: account, value: 1), indexRevision: 1, origin: .sync)
        for listener in state.withLock({ $0.listeners }) { listener.yield(change) }
    }
}

private final class FakeBackupSource: DeviceIndexBackupSource {
    private let state: Mutex<(inputs: DeviceIndexBackupInputs, continuations: [AsyncStream<Void>.Continuation])>

    init(_ inputs: DeviceIndexBackupInputs) { state = Mutex((inputs, [])) }

    var inputs: DeviceIndexBackupInputs {
        get { state.withLock { $0.inputs } }
        set {
            let continuations = state.withLock { state in
                state.inputs = newValue
                return state.continuations
            }
            for continuation in continuations { continuation.yield() }
        }
    }

    func inputs(account: String) async -> DeviceIndexBackupInputs? { inputs }
    func changes() async -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        state.withLock { $0.continuations.append(continuation) }
        return stream
    }
}
