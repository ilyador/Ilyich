import IlyichPlatform
import IlyichShareInbox
import UIKit
import XCTest
@testable import Ilyich

/// Pins every format a later milestone imports. Each fixture in Tests/Fixtures was written by
/// the production encoder of its day; the oldest backup state by commit 9780e9625's own types.
/// JSONEncoder orders keys differently from one process to the next, so encodings are compared as
/// JSON. Outcome files without a version and task descriptions an older build wrote were retired
/// in B10: their fixtures stay for the task descriptions recovery still recognizes, to cancel.
/// state.json stays readable for an account whose file no import read (LegacyBackupImporter).
final class LegacyFormatsTests: XCTestCase {
    private typealias G = LegacyGoldens
    private func bits(_ date: Date?) -> UInt64? { date?.timeIntervalSinceReferenceDate.bitPattern }
    private var widgetFolder: String { "widget/" + AccountStoragePaths(G.account).widgetCache }

    func testEveryFixtureDecodes() throws {
        let files = try FixtureLoader.files(in: "")
        XCTAssertEqual(files.count, 23, "Every fixture reached the test bundle.")
        for path in files {
            let data = try FixtureLoader.data(path)
            let name = (path as NSString).lastPathComponent
            switch path {
            case _ where path.hasPrefix("backup/state-"): _ = try Legacy.decoder().decode(Legacy.BackupState.self, from: data)
            case _ where name.hasPrefix("descriptor-"): XCTAssertEqual(TaskDescriptor(taskDescription: String(decoding: data, as: UTF8.self)), .legacy, path)
            case "share/manifest-v1.json": _ = try Legacy.decoder().decode(Legacy.SharedBatch.self, from: data)
            case "share/manifest-v2.json": _ = try ShareManifest.decode(data, batch: G.batchID, folder: G.sharedFolder)
            case _ where path.hasPrefix("widget/") && name.hasSuffix("_metadata.json"): _ = try Legacy.decoder().decode(Legacy.WidgetMetadata.self, from: data)
            case _ where path.hasPrefix("widget/") && name.hasSuffix(".png"): XCTAssertNotNil(UIImage(data: data), path)
            case "widget/flutter/defaults.json": _ = try JSONDecoder().decode([String: String].self, from: data)
            case "session/network-config-v1.json": _ = try JSONDecoder().decode(NetworkConfiguration.self, from: data)
            case "session/saved-session-v1.json": _ = try JSONDecoder().decode(StoredCredential.self, from: data)
            case _ where path.hasPrefix("caches/IlyichFingerprints/"): _ = try Legacy.decoder().decode([String: Legacy.Fingerprint].self, from: data)
            case _ where path.hasPrefix("caches/IlyichTimelinePlaces/"): _ = try Legacy.decoder().decode(Legacy.TimelinePlaces.self, from: data)
            case _ where path.hasPrefix("caches/IlyichThumbnails/"): XCTAssertNotNil(UIImage(data: data), path)
            default: XCTFail("\(path) has no reader; every fixture must be decoded here.")
            }
        }
    }

    func testCurrentBackupStateHasEveryKey() throws {
        let data = try FixtureLoader.data("backup/state-current.json")
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        XCTAssertEqual(Set(keys), ["preferences", "queue", "current", "confirmed", "receipts", "linkedAlbums", "pendingAlbumAdds",
                                   "suspended", "failures", "transferNotification", "paused", "error"])
        let state = try Legacy.decoder().decode(Legacy.BackupState.self, from: data)
        var preferences = Legacy.BackupPreferences()
        preferences.includedAlbums = G.includedAlbums; preferences.excludedAlbums = [G.excludedAlbum]
        preferences.cellularPhotos = true; preferences.downloadCloudOriginals = true; preferences.automatic = true
        preferences.requireCharging = true; preferences.triggerDelay = 120; preferences.syncAlbums = true
        XCTAssertEqual(state.preferences, preferences)
        XCTAssertEqual(state.queue, [G.l1, G.l3, G.l6], "Queue order is kept, the current stage first.")
        let current = try XCTUnwrap(state.current)
        XCTAssertEqual(current.localID, G.l1)
        XCTAssertEqual(current.stageID, G.currentStage)
        XCTAssertEqual(current.livePhotoID, G.motionAsset)
        XCTAssertEqual(current.motionChecksum, "q83vEjRWeJq83vEjRWeJq83vEjQ=")
        XCTAssertEqual(current.original.url.path, "\(G.container)/Backup/\(G.digest)/\(G.currentFolder)/original")
        XCTAssertEqual(current.sidecar?.filename, "IMG_0001.xmp")
        XCTAssertEqual(current.fields, G.currentFields)
        XCTAssertEqual(state.confirmed.map { Set($0.keys) }, [G.l2, G.l4, G.l5])
        let receipt = try XCTUnwrap(state.receipts?[G.l2])
        XCTAssertEqual(receipt.original.id, G.originalAsset)
        XCTAssertEqual(receipt.original.byteCount, 3_145_728)
        XCTAssertEqual(receipt.motion?.id, G.pairedMotionAsset)
        let older = try XCTUnwrap(state.receipts?[G.l4])
        XCTAssertNil(older.motion); XCTAssertNil(older.confirmedAt); XCTAssertNil(older.original.byteCount)
        XCTAssertEqual(state.linkedAlbums, ["B7E2D9A0-55C1-4E3F-8A6B-1C2D3E4F5A6B/L0/040": G.serverAlbum])
        XCTAssertEqual(state.pendingAlbumAdds, [G.l3: [G.serverAlbum, G.otherServerAlbum]])
        XCTAssertEqual(state.suspended?[G.l6]?.stageID, G.suspendedStage)
        XCTAssertNil(state.suspended?[G.l6]?.livePhotoID)
        XCTAssertEqual(state.failures?[G.l3]?.filename, "IMG_0003.HEIC")
        XCTAssertEqual(state.transferNotification?.id, G.notificationID)
        XCTAssertEqual(state.transferNotification?.completed, 9)
        XCTAssertEqual(state.transferNotification?.terminalFailures, 2)
        XCTAssertEqual(state.paused, false)
        XCTAssertEqual(state.error, ServerFailure.sessionExpired(nil).localizedDescription)
    }

    func testOldestBackupStateShapeDecodes() throws {
        let data = try FixtureLoader.data("backup/state-9780e9625.json")
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        XCTAssertEqual(Set(keys), ["preferences", "queue", "current", "confirmed", "paused", "error"])
        let state = try Legacy.decoder().decode(Legacy.BackupState.self, from: data)
        XCTAssertEqual(state.queue, [G.l1, G.l3])
        XCTAssertEqual(state.paused, true)
        XCTAssertNil(state.receipts); XCTAssertNil(state.linkedAlbums); XCTAssertNil(state.pendingAlbumAdds)
        XCTAssertNil(state.suspended); XCTAssertNil(state.failures); XCTAssertNil(state.transferNotification)
        let preferences = try XCTUnwrap(state.preferences)
        XCTAssertEqual(preferences.includedAlbums, ["3B1A8F4C-1D5E-4F7A-9C2B-6E8D0A1B2C3D/L0/040"])
        XCTAssertFalse(preferences.automatic, "Keys added later take today's defaults.")
        XCTAssertEqual(preferences.triggerDelay, 30)
        XCTAssertEqual(state.current?.livePhotoID, G.motionAsset)
        XCTAssertNil(state.current?.motionChecksum, "The oldest stages record no video checksum.")
        XCTAssertNil(state.current?.sidecar)
    }

    func testDatesMatchByBitPattern() throws {
        let state = try FixtureLoader.decode(Legacy.BackupState.self, from: "backup/state-current.json")
        XCTAssertEqual(bits(state.current?.modificationDate), G.Bits.current)
        XCTAssertEqual(bits(state.confirmed?[G.l2]), G.Bits.l2)
        XCTAssertEqual(bits(state.confirmed?[G.l4]), G.Bits.l4)
        XCTAssertEqual(bits(state.confirmed?[G.l5]), G.Bits.l5, "A whole number of seconds, written without a decimal point.")
        XCTAssertEqual(bits(state.receipts?[G.l2]?.modificationDate), G.Bits.l2)
        XCTAssertEqual(bits(state.receipts?[G.l2]?.confirmedAt), G.Bits.l2ConfirmedAt)
        XCTAssertEqual(bits(state.receipts?[G.l4]?.modificationDate), G.Bits.l4)
        XCTAssertEqual(bits(state.suspended?[G.l6]?.modificationDate), G.Bits.l6)
        XCTAssertEqual(bits(state.failures?[G.l3]?.date), G.Bits.failure)
        XCTAssertEqual(AssetRevision(try XCTUnwrap(state.confirmed?[G.l2])), AssetRevision(referenceSeconds: Double(bitPattern: G.Bits.l2)))
        // The rows B9's import wrote from it hold the same bits (LegacyGoldens.importedSeed).
        let seed = G.importedSeed()
        XCTAssertEqual(seed.confirmations.map { bits($0.1) }, [G.Bits.l2, G.Bits.l4, G.Bits.l5])
        XCTAssertEqual(bits(seed.receipts.first?.confirmedAt), G.Bits.l2ConfirmedAt)
        XCTAssertEqual(seed.stages.map { bits($0.modified) }, [G.Bits.current, G.Bits.l6])

        let manifest = try FixtureLoader.decode(Legacy.SharedBatch.self, from: "share/manifest-v1.json")
        XCTAssertEqual(bits(manifest.createdAt), G.Bits.manifest)
        let manifestV2 = try ShareManifest.decode(FixtureLoader.data("share/manifest-v2.json"), batch: G.batchID, folder: G.sharedFolder)
        XCTAssertEqual(bits(manifestV2.createdAt), G.Bits.manifest)
        let fingerprints = try FixtureLoader.decode([String: Legacy.Fingerprint].self, from: "caches/" + Legacy.fingerprintsPath(scope: G.account.cacheScope))
        XCTAssertEqual(bits(fingerprints[G.l4]?.modified), G.Bits.l4)
        XCTAssertEqual(bits(fingerprints[G.l5]?.modified), G.Bits.l5)
        let old = try FixtureLoader.decode(Legacy.BackupState.self, from: "backup/state-9780e9625.json")
        XCTAssertEqual(bits(old.current?.modificationDate), G.Bits.current)
        XCTAssertEqual(bits(old.confirmed?[G.l2]), G.Bits.l2)
        // The goldens' literals are those bits.
        for (date, pinned) in [(G.Dates.current, G.Bits.current), (G.Dates.l2, G.Bits.l2), (G.Dates.l4, G.Bits.l4), (G.Dates.l5, G.Bits.l5),
                               (G.Dates.l6, G.Bits.l6), (G.Dates.l2ConfirmedAt, G.Bits.l2ConfirmedAt), (G.Dates.failure, G.Bits.failure),
                               (G.Dates.manifest, G.Bits.manifest)] {
            XCTAssertEqual(bits(date), pinned)
        }
    }

    func testProductionEncodersWriteTheFixtures() throws {
        let encoder = JSONEncoder()
        var table: [(path: String, produced: Data, sets: Set<String>)] = [
            // Builds since W3 write version 2 manifests; the verbatim mirror stands in for the version 1 writer.
            ("share/manifest-v1.json", try encoder.encode(G.manifest), []),
            ("share/manifest-v2.json", try ShareManifest.encode(G.manifestV2), []),
            ("session/network-config-v1.json", try encoder.encode(G.networkConfiguration.validated()), []),
            ("session/saved-session-v1.json", try encoder.encode(G.credential), []),
            // The widget's writer is compiled only into the Swift 5 widget extension; its verbatim mirror stands in.
            ("widget/flutter/random_NONE_0_metadata.json", try encoder.encode(G.flutterMetadata), []),
        ]
        for (key, metadata) in G.widgetMetadata { table.append(("\(widgetFolder)/\(key)_metadata.json", try encoder.encode(metadata), [])) }
        for entry in table {
            XCTAssertEqual(try FixtureLoader.canonicalJSON(entry.produced, unorderedArrays: entry.sets),
                           try FixtureLoader.canonicalJSON(FixtureLoader.data(entry.path), unorderedArrays: entry.sets), entry.path)
        }
        // A version 2 manifest is written with sorted keys, so the fixture is its exact bytes.
        XCTAssertEqual(String(decoding: try ShareManifest.encode(G.manifestV2), as: UTF8.self),
                       String(decoding: try FixtureLoader.data("share/manifest-v2.json"), as: UTF8.self))
    }

    func testShareManifestV1() throws {
        let manifest = try FixtureLoader.decode(Legacy.SharedBatch.self, from: "share/manifest-v1.json")
        XCTAssertEqual(manifest.id, G.batchID)
        XCTAssertEqual(manifest.attachments.map(\.original.filename), ["IMG_2001.JPG", "IMG_2002.HEIC", "DSC_0042.NEF"])
        XCTAssertEqual(manifest.attachments.map(\.original.url.lastPathComponent), [G.sharedFiles[0], G.sharedFiles[1], G.sharedFiles[3]],
                       "An attachment is known by its original's file name.")
        XCTAssertEqual(manifest.attachments[1].motion?.filename, "IMG_2002.MOV")
        XCTAssertEqual(manifest.attachments[2].sidecar?.filename, "DSC_0042.xmp")
        XCTAssertEqual(manifest.attachments.compactMap { AppGroupLayout.relativePath(of: $0.original.url) },
                       [0, 1, 3].map { "ShareInbox/\(G.batchID.uuidString)/\(G.sharedFiles[$0])" })
        // The app reads it with today's reader, into the batch the version 2 fixture holds.
        let production = try ShareManifest.decode(FixtureLoader.data("share/manifest-v1.json"), batch: G.batchID, folder: G.sharedFolder)
        XCTAssertEqual(production.attachments.map(\.id), [G.sharedFiles[0], G.sharedFiles[1], G.sharedFiles[3]])
        XCTAssertEqual(production, G.manifestV2)
        XCTAssertEqual(production.attachments.flatMap(\.files).map(\.url.path),
                       manifest.attachments.flatMap { [$0.original, $0.motion, $0.sidecar].compactMap { $0?.url.path } },
                       "On the phone that wrote it, every file resolves to the path it recorded.")
    }

    func testShareManifestV2() throws {
        let data = try FixtureLoader.data("share/manifest-v2.json")
        XCTAssertEqual(try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])["v"] as? Int, 2)
        XCTAssertEqual(try ShareManifest.decode(data, batch: G.batchID, folder: G.sharedFolder), G.manifestV2)
        // Files are found by name: the URLs a version 2 manifest also records are ignored, so the
        // batch survives a moved container.
        let moved = URL(fileURLWithPath: "/private/var/mobile/Containers/Shared/AppGroup/11111111-2222-4333-8444-555555555555/ShareInbox/\(G.batchID.uuidString)",
                        isDirectory: true)
        XCTAssertEqual(try ShareManifest.decode(data, batch: G.batchID, folder: moved).attachments.first?.original.url.path,
                       moved.path + "/" + G.sharedFiles[0])
        // A build before W3 reads it as version 1, so a rollback keeps every shared file.
        let old = try Legacy.decoder().decode(Legacy.SharedBatch.self, from: data)
        let v1 = try FixtureLoader.decode(Legacy.SharedBatch.self, from: "share/manifest-v1.json")
        XCTAssertEqual(old.id, v1.id)
        XCTAssertEqual(bits(old.createdAt), bits(v1.createdAt))
        func files(_ batch: Legacy.SharedBatch) -> [[String?]] {
            batch.attachments.map { [$0.original, $0.motion, $0.sidecar].map { $0.map { "\($0.url.absoluteString) \($0.filename) \($0.contentType)" } } }
        }
        XCTAssertEqual(files(old), files(v1))
        XCTAssertThrowsError(try ShareManifest.decode(data, batch: UUID(), folder: G.sharedFolder), "A manifest belongs to its own folder.")
    }

    func testWidgetCacheV1AndFlutterWidgetKeys() throws {
        XCTAssertEqual(try FixtureLoader.files(in: widgetFolder),
                       ["memory_1_image.png", "memory_1_metadata.json", "random_NONE_0_image.png", "random_NONE_0_metadata.json"])
        XCTAssertEqual(widgetFolder, "widget/WidgetCache2/\(G.digest)")
        let random = try FixtureLoader.decode(Legacy.WidgetMetadata.self, from: "\(widgetFolder)/random_NONE_0_metadata.json")
        XCTAssertEqual(random.accountScope, G.digest, "A snapshot is shown only to the account that cached it.")
        XCTAssertEqual(random.deepLink?.absoluteString, "immich://asset?id=\(G.widgetAsset)")
        XCTAssertFalse(random.forceFullColor)
        XCTAssertNil(random.subtitle); XCTAssertNil(random.error)
        let memory = try FixtureLoader.decode(Legacy.WidgetMetadata.self, from: "\(widgetFolder)/memory_1_metadata.json")
        XCTAssertEqual(memory.subtitle, "3 years ago")
        XCTAssertEqual(memory.deepLink?.absoluteString, "immich://memory?id=\(G.memoryID)")
        XCTAssertTrue(memory.forceFullColor)
        for path in ["\(widgetFolder)/random_NONE_0_image.png", "\(widgetFolder)/memory_1_image.png", "widget/flutter/random_NONE_0_image.png"] {
            let png = try FixtureLoader.data(path)
            XCTAssertEqual(Array(png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], path)
            XCTAssertNil(png.range(of: Data("CgBI".utf8)), "\(path) was copied into the bundle unchanged.")
        }
        // An error encodes as Swift encodes a case without values.
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(Legacy.WidgetError.fetchFailed), as: UTF8.self), #"{"fetchFailed":{}}"#)
        XCTAssertEqual(try JSONDecoder().decode(Legacy.WidgetMetadata.self, from: Data(#"{"error":{"noLogin":{}}}"#.utf8)).error, .noLogin)

        // The Flutter app's widget: its credentials in the App Group's preferences and a snapshot
        // at the container's root, without an account.
        let flutter = try FixtureLoader.decode(Legacy.WidgetMetadata.self, from: "widget/flutter/random_NONE_0_metadata.json")
        XCTAssertNil(flutter.accountScope)
        XCTAssertTrue(flutter.forceFullColor)
        XCTAssertEqual(flutter.deepLink?.absoluteString, "immich://asset?id=\(G.widgetAsset)")
        let values = try JSONDecoder().decode([String: String].self, from: FixtureLoader.data("widget/flutter/defaults.json"))
        XCTAssertEqual(Set(values.keys), Set(Legacy.FlutterWidgetCredentials.keys))
        let suite = "LegacyFormatsTests.flutter"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        for (key, value) in values { defaults.set(value, forKey: key) }
        let credentials = try XCTUnwrap(Legacy.FlutterWidgetCredentials(defaults: defaults))
        XCTAssertEqual(credentials.serverURL, "https://photos.example.org/api")
        XCTAssertEqual(credentials.token, "flutter-session-token")
        XCTAssertEqual(credentials.customHeaders, ["CF-Access-Client-Id": "client.access", "CF-Access-Client-Secret": "access-secret"])
        // Flutter's sign-out wrote empty strings.
        defaults.set("", forKey: Legacy.FlutterWidgetCredentials.tokenKey)
        XCTAssertNil(Legacy.FlutterWidgetCredentials(defaults: defaults))
    }

    /// The places an earlier build kept are found by hashing each feed's key, moved into the
    /// index's month_places rows and shown at the next launch before anything is counted, and the
    /// account's folder is deleted. The library's file is found under its pre-Q5 key, byte for
    /// byte; a person's under the key the index's people give.
    @MainActor func testPlacesFilesAreImportedByHashingTheFeedKey() async throws {
        let scope = G.account.cacheScope
        XCTAssertEqual(Legacy.placesPath(scope: scope, feedKey: LibraryQuery.library.stableKey),
                       "IlyichTimelinePlaces/\(G.digest)/ff9bafac0eb80c2674bfcaaa3acc714c710245186a78a84fce9c2cc4fe4df897.json")
        XCTAssertEqual(LibraryQuery.library.stableKey, "order=desc&orderBy=takenAt&withStacked=true&visibility=timeline",
                       "The library's places are found under the key they had before Q5.")
        XCTAssertEqual(try FixtureLoader.files(in: "caches/IlyichTimelinePlaces"),
                       G.places.map { String(Legacy.placesPath(scope: scope, feedKey: $0.query.stableKey).dropFirst("IlyichTimelinePlaces/".count)) }.sorted())

        // The files as the earlier build left them, below a Caches of this test's own.
        let caches = FileManager.default.temporaryDirectory.appendingPathComponent("LegacyFormatsTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: caches) }
        let root = caches.appendingPathComponent("IlyichTimelinePlaces", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: FixtureLoader.url("caches/IlyichTimelinePlaces/\(G.digest)"), to: root.appendingPathComponent(G.digest, isDirectory: true))
        try Data("{}".utf8).write(to: root.appendingPathComponent(G.digest, isDirectory: true).appendingPathComponent("not-a-feed.json"))
        let index = try LibraryIndex(scope: scope, userID: G.account.userID, directory: caches.appendingPathComponent("index", isDirectory: true))
        _ = try await index.apply([SyncEvents.event("PersonV1", #"{"id":"\#(G.person)","name":"Pat","isHidden":false}"#, ack: "PersonV1|pat")],
                                  epoch: await index.epoch())

        let importer = LegacyPlacesImport(scope: scope, root: root, index: index)
        let candidates = await importer.candidates()
        XCTAssertEqual(candidates[Legacy.sha256(LibraryQuery.person(G.person).stableKey)], LibraryQuery.person(G.person), "A person's file is found through the index's people.")
        await importer.run(ifCurrent: { true })
        for (query, places) in G.places {
            let rows = try await index.monthPlaces(forKey: query.stableKey)
            XCTAssertEqual(rows, LegacyPlacesImport.rows(places), "\(query.stableKey)")
            let shown = FeedPlaces(counts: rows ?? [])
            XCTAssertEqual(shown.months.mapValues { $0.map(\.name) }, places.months.mapValues { $0.map(\.name) }, "The months keep their places and ranks.")
            XCTAssertEqual(shown.months.mapValues { $0.map(\.count) }, places.months.mapValues { $0.map(\.count) })
            XCTAssertTrue(shown.trips.isEmpty, "A file's trips are left out; the first count brings them back.")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "The folder is deleted once imported.")

        // At the next launch the imported places show before the feed is counted.
        let counter = PlacesCounter(holding: true)
        let service = MonthPlacesService(source: counter, store: index, delay: .zero, legacy: LegacyPlacesImport(scope: scope, root: root, index: index))
        service.show(.library, plan: try QueryPlanner.plan(.library, context: PlannerContext(indexReadable: true)))
        let shown = await becomesTrue { service.places(of: .library)?.months["2025-10-01"]?.map(\.name) == ["Lisbon", "Sintra"] }
        XCTAssertTrue(shown, "The kept places show straight after launch.")
        XCTAssertEqual(service.places(of: .library)?.years[2025], "Lisbon · London")
        await counter.release()
    }

    /// The files hold places counted under the access the account had before. An import that an
    /// access change or sign-out overtakes keeps none of them, and the account's folder goes all
    /// the same; an access change or sign-out deletes it unread, leaving other accounts' alone.
    @MainActor func testPlacesFilesAreKeptOnlyUnderTheAccessTheyWereCountedUnder() async throws {
        let scope = G.account.cacheScope
        let caches = FileManager.default.temporaryDirectory.appendingPathComponent("LegacyFormatsTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: caches) }
        let root = caches.appendingPathComponent("IlyichTimelinePlaces", isDirectory: true)
        let folder = root.appendingPathComponent(G.digest, isDirectory: true)
        func plant() throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: FixtureLoader.url("caches/IlyichTimelinePlaces/\(G.digest)"), to: folder)
        }
        let index = try LibraryIndex(scope: scope, userID: G.account.userID, directory: caches.appendingPathComponent("index", isDirectory: true))
        _ = try await index.apply([SyncEvents.event("PersonV1", #"{"id":"\#(G.person)","name":"Pat","isHidden":false}"#, ack: "PersonV1|pat")],
                                  epoch: await index.epoch())
        func keptFeeds() async throws -> [String] {
            var keys: [String] = []
            for (query, _) in G.places {
                if try await index.monthPlaces(forKey: query.stableKey) != nil { keys.append(query.stableKey) }
            }
            return keys
        }
        let authorization = AuthorizationState(account: G.account, token: "session", readOnly: false, requiresPasswordChange: false, mirror: nil)

        // Access changes while the import runs.
        try plant()
        let before = authorization.snapshot.epoch
        authorization.accessChanged()
        await LegacyPlacesImport(scope: scope, root: root, index: index).run(ifCurrent: { authorization.isCurrent(before) })
        let afterAccessChange = try await keptFeeds()
        XCTAssertEqual(afterAccessChange, [], "Places counted under access the account no longer has are not kept.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "The files go all the same.")

        // The service imports under the access it starts with: an import running on past sign-out keeps nothing.
        try plant()
        authorization.end()
        let counter = PlacesCounter(holding: true)
        let service = MonthPlacesService(source: counter, store: index, authorization: authorization, delay: .zero,
                                         legacy: LegacyPlacesImport(scope: scope, root: root, index: index))
        service.show(.library, plan: try QueryPlanner.plan(.library, context: PlannerContext(indexReadable: true)))
        let imported = await becomesTrue { !FileManager.default.fileExists(atPath: root.path) }
        XCTAssertTrue(imported, "The import did not run.")
        let afterSignOut = try await keptFeeds()
        XCTAssertEqual(afterSignOut, [], "Nothing is kept past sign-out.")
        service.cancel()
        await counter.release()

        // Deleted unread: an account's folder goes, another account's stays, and the cache folder
        // goes with the last account's.
        try plant()
        let other = root.appendingPathComponent(Legacy.sha256("https://other.example.test/api|bob"), isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        LegacyPlacesImport.discard(scope: scope, root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path), "Another account's places stay.")
        LegacyPlacesImport.discard(scope: "https://other.example.test/api|bob", root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    /// The fingerprint file LocalFingerprintCache wrote under its hashed name moves into
    /// device.sqlite bit for bit, revisions as doubles and a missing one as NULL, and is deleted.
    func testFingerprintFileIsImportedIntoTheDeviceDatabase() async throws {
        let scope = G.account.cacheScope
        let path = Legacy.fingerprintsPath(scope: scope)
        XCTAssertEqual(path, "IlyichFingerprints/\(G.digest).json")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LegacyFormatsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FixtureLoader.data("caches/" + path).write(to: file)

        let database = DeviceDatabase(url: root.appendingPathComponent("device.sqlite"))
        let imported = try await database.importLegacyFingerprints(from: file.deletingLastPathComponent())
        XCTAssertEqual(imported, G.fingerprints.count)
        let rows = try await database.fingerprints()
        XCTAssertEqual(rows, G.fingerprints.mapValues { DeviceFingerprint(modified: $0.modified, checksum: $0.checksum) })
        XCTAssertEqual(rows[G.l4]?.revision?.bitPattern, G.Bits.l4)
        XCTAssertEqual(rows[G.l5]?.revision?.bitPattern, G.Bits.l5)
        XCTAssertNil(rows["7B6A5948-3726-4150-8F6E-5D4C3B2A1908/L0/001"]?.revision, "A photo without a modification date keeps none.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path), "The file and its folder are gone.")
        let again = try await database.importLegacyFingerprints(from: file.deletingLastPathComponent())
        XCTAssertEqual(again, 0)
    }

    func testThumbnailTreeV1IsTheStoreLayout() async throws {
        let scope = G.account.cacheScope
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LegacyFormatsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ThumbnailDiskStore.shared(scope: scope, root: root)
        let fixture = try FixtureLoader.files(in: "caches/IlyichThumbnails")
        XCTAssertEqual(Set(fixture.map { $0.split(separator: "/")[0] }), [Substring(G.digest.prefix(32))])
        XCTAssertEqual(AccountStoragePaths(G.account).thumbnails, "IlyichThumbnails/" + G.digest.prefix(32))
        var expected: [String] = []
        for (assetID, revision) in G.thumbnails {
            let path = Legacy.thumbnailPath(scope: scope, assetID: assetID, revision: revision)
            XCTAssertEqual(store.url(assetID: assetID, revision: revision).path, root.appendingPathComponent(path).path, assetID)
            let bytes = try FixtureLoader.data("caches/" + path)
            await store.store(bytes, assetID: assetID, revision: revision)
            XCTAssertEqual(store.data(assetID: assetID, revision: revision), bytes, assetID)
            expected.append(String(path.dropFirst("IlyichThumbnails/".count)))
        }
        XCTAssertEqual(fixture, expected.sorted())
        let written = FileManager.default.enumerator(at: root.appendingPathComponent("IlyichThumbnails"), includingPropertiesForKeys: [.isRegularFileKey])?
            .compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
            // T1's index sits beside the folders; the thumbnails themselves keep the v1 layout.
            .filter { !$0.lastPathComponent.hasPrefix(ThumbnailDiskStore.indexName) }
        XCTAssertEqual(written?.count, fixture.count, "The store wrote nothing else.")
        // An ID with characters other than letters, digits and hyphens is hashed; others are lowercased.
        XCTAssertTrue(expected.contains { $0.contains("/6f1c2a40-0000-4000-8000-000000000001.") })
        XCTAssertFalse(expected.contains { $0.contains("local") })
    }

    func testNetworkConfigurationAndSavedSessionV1() throws {
        let data = try FixtureLoader.data("session/network-config-v1.json")
        let network = try JSONDecoder().decode(NetworkConfiguration.self, from: data)
        XCTAssertEqual(network, try G.networkConfiguration.validated())
        XCTAssertEqual(try network.validated(), network, "Loading validates without changing what was stored.")
        XCTAssertEqual(Set(try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys),
                       ["customHeaders", "alternateEndpoints", "automaticallySwitchEndpoints", "preferredWifiName", "localEndpoint"])
        let session = try FixtureLoader.data("session/saved-session-v1.json")
        let credential = try JSONDecoder().decode(StoredCredential.self, from: session)
        XCTAssertEqual(credential, G.credential)
        XCTAssertEqual(credential.scope, G.digest)
        XCTAssertEqual(Set(try XCTUnwrap(JSONSerialization.jsonObject(with: session) as? [String: Any]).keys),
                       ["server", "token", "userID", "name", "requiresPasswordChange"])
    }
}
