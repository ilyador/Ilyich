import Foundation
import IlyichShareInbox
import UniformTypeIdentifiers
import XCTest
@testable import Ilyich

/// The share inbox on disk: manifests, path confinement, damaged batches, the rewrite after an
/// upload, upload identities and staging leftovers. Each test gets its own container.
final class SharedInboxTests: XCTestCase {
    private typealias G = LegacyGoldens
    private var container: URL!
    private var root: URL { container.appendingPathComponent(ShareInboxRepository.folderName, isDirectory: true) }

    override func setUpWithError() throws {
        container = FileManager.default.temporaryDirectory.appendingPathComponent("SharedInboxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: container)
    }

    /// A batch folder holding a few bytes under each name.
    private func makeFolder(_ id: UUID = G.batchID, names: [String] = G.sharedFiles) throws -> URL {
        let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, name) in names.enumerated() { try Data("file \(index)".utf8).write(to: folder.appendingPathComponent(name)) }
        return folder
    }

    private func photo(_ name: String, in folder: URL) -> SharedAttachment {
        SharedAttachment(original: SharedFile(name: name, filename: "IMG_\(name).JPG", contentType: "image/jpeg", folder: folder))
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func testManifestOnlyReferencesFilesInsideItsOwnBatch() async throws {
        let id = UUID()
        let folder = try makeFolder(id, names: ["photo"])
        let other = try makeFolder(UUID(), names: ["photo"])
        let outside = container.appendingPathComponent("private-photo")
        try Data([4, 5, 6]).write(to: outside)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("symlink"), withDestinationURL: outside)
        let repository = ShareInboxRepository(root: root)
        let manifest = folder.appendingPathComponent(ShareManifest.fileName)
        func state() async throws -> ShareBatchState? { try await repository.load().first { $0.id == id } }
        func write(name: String) throws {
            let json = #"{"v":2,"id":"\#(id.uuidString)","createdAt":0,"attachments":[{"original":{"name":"\#(name)","filename":"a.jpg","contentType":"image/jpeg"}}]}"#
            try Data(json.utf8).write(to: manifest)
        }

        try write(name: "photo")
        let inside = try await state()
        XCTAssertEqual(inside?.batch?.attachments.map(\.original.url), [folder.appendingPathComponent("photo", isDirectory: false)])
        // A name can't leave the folder, stand for the manifest, or be a link to a file outside.
        for name in ["../private-photo", "../\(other.lastPathComponent)/photo", "..", "manifest.json", "", "symlink"] {
            try write(name: name)
            let refused = try await state()
            XCTAssertEqual(refused, .damaged(id: id, reason: .invalid), name)
        }
        // Nor is a link saved.
        do {
            try await repository.save(SharedBatch(id: id, createdAt: Date(), attachments: [photo("symlink", in: folder)]))
            XCTFail("A link to a file outside the batch is never saved.")
        } catch {}
    }

    func testLivePhotoAndSidecarSurviveManifestRoundTrip() throws {
        let folder = URL(fileURLWithPath: "/test/ShareInbox/\(G.batchID.uuidString)", isDirectory: true)
        let batch = SharedBatch(id: G.batchID, createdAt: Date(), attachments: [SharedAttachment(
            original: SharedFile(name: "still", filename: "photo.heic", contentType: "image/heic", folder: folder),
            motion: SharedFile(name: "motion", filename: "photo.mov", contentType: "video/quicktime", folder: folder),
            sidecar: SharedFile(name: "sidecar", filename: "photo.xmp", contentType: "application/rdf+xml", folder: folder))])
        let data = try ShareManifest.encode(batch)
        XCTAssertEqual(try ShareManifest.decode(data, batch: batch.id, folder: folder), batch)
        let moved = URL(fileURLWithPath: "/moved/ShareInbox/\(G.batchID.uuidString)", isDirectory: true)
        let restored = try ShareManifest.decode(data, batch: batch.id, folder: moved)
        XCTAssertEqual(restored.attachments.first?.motion?.url.path, moved.path + "/motion", "Files are found in the folder the manifest is read from.")
        XCTAssertEqual(restored.attachments.first?.sidecar?.filename, "photo.xmp")
        // Files are written by name alone: no URL, which only builds before W3 read.
        XCTAssertNil(String(decoding: data, as: UTF8.self).range(of: "url"), "No URL is written.")
        let named = #"{"v":2,"id":"\#(G.batchID.uuidString)","createdAt":0,"attachments":[{"original":{"name":"still","filename":"photo.heic","contentType":"image/heic"}}]}"#
        XCTAssertEqual(try ShareManifest.decode(Data(named.utf8), batch: G.batchID, folder: moved).attachments.map(\.original.url.path), [moved.path + "/still"])
        // A manifest without a version is a version 1 manifest, which no build since C8 reads.
        let unversioned = #"{"id":"\#(G.batchID.uuidString)","createdAt":0,"attachments":[{"original":{"name":"still","url":"file:///test/ShareInbox/\#(G.batchID.uuidString)/still","filename":"photo.heic","contentType":"image/heic"}}]}"#
        XCTAssertThrowsError(try ShareManifest.decode(Data(unversioned.utf8), batch: G.batchID, folder: moved)) { error in
            XCTAssertEqual(error as? ShareBatchDamage, .undecodable)
        }
    }

    func testDamagedBatchDoesNotHideHealthyBatches() async throws {
        let repository = ShareInboxRepository(root: root)
        let healthyID = UUID(), otherHealthyID = UUID()
        let healthy = SharedBatch(id: healthyID, createdAt: Date(timeIntervalSinceReferenceDate: 20),
                                  attachments: [photo("still", in: try makeFolder(healthyID, names: ["still"]))])
        let otherHealthy = SharedBatch(id: otherHealthyID, createdAt: Date(timeIntervalSinceReferenceDate: 10),
                                       attachments: [photo("clip", in: try makeFolder(otherHealthyID, names: ["clip"]))])
        try await repository.save(healthy)
        try await repository.save(otherHealthy)

        let corrupt = UUID(), newer = UUID(), missing = UUID(), elsewhere = UUID()
        try Data("{".utf8).write(to: try makeFolder(corrupt, names: ["a"]).appendingPathComponent(ShareManifest.fileName))
        try Data(#"{"v":3,"id":"\#(newer.uuidString)","createdAt":0,"attachments":[]}"#.utf8)
            .write(to: try makeFolder(newer, names: ["a"]).appendingPathComponent(ShareManifest.fileName))
        let missingFolder = try makeFolder(missing, names: ["a"])
        try ShareManifest.encode(SharedBatch(id: missing, createdAt: Date(), attachments: [photo("a", in: missingFolder), photo("gone", in: missingFolder)]))
            .write(to: missingFolder.appendingPathComponent(ShareManifest.fileName))
        try ShareManifest.encode(otherHealthy).write(to: try makeFolder(elsewhere, names: ["clip"]).appendingPathComponent(ShareManifest.fileName))

        let states = try await repository.load()
        XCTAssertEqual(states.compactMap(\.batch), [otherHealthy, healthy], "Healthy batches load, oldest first.")
        XCTAssertEqual(Set(states.filter { $0.batch == nil }), [.damaged(id: corrupt, reason: .undecodable), .damaged(id: newer, reason: .newerVersion(3)),
                                                                 .damaged(id: missing, reason: .invalid), .damaged(id: elsewhere, reason: .wrongBatch)])
        for id in [corrupt, newer, missing, elsewhere] {
            XCTAssertTrue(exists(repository.folder(for: id).appendingPathComponent(ShareManifest.fileName)), "A damaged batch is kept for a later read.")
        }
        // The store lists the healthy batches and counts the rest.
        let store = await ShareInboxStore(repository: repository)
        await store.refresh()
        let listed = await store.batches.map(\.id)
        let unreadable = await store.unreadableBatches
        XCTAssertEqual(listed, [otherHealthyID, healthyID])
        XCTAssertEqual(unreadable, 4)
        let error = await store.error
        XCTAssertNil(error)
        // Healthy batches still upload and go once consumed.
        try await repository.consume("still", from: healthyID)
        let after = try await repository.load()
        XCTAssertEqual(after.compactMap(\.batch), [otherHealthy])
        XCTAssertEqual(after.count, 5)
        XCTAssertFalse(exists(repository.folder(for: healthyID)))
    }

    /// Screens read `batches` straight after `await refresh()`: Shared files selects every file
    /// in it, and the immich://share link marks its batches seen. So a refresh returns with the
    /// read it made, even while another refresh, from coming forward or the upload worker, is
    /// still reading.
    @MainActor func testRefreshReturnsWithItsReadWhileAnotherOverlaps() async throws {
        let repository = ShareInboxRepository(root: root)
        let store = ShareInboxStore(repository: repository)
        let id = UUID()
        try await repository.save(SharedBatch(id: id, createdAt: Date(), attachments: [photo("photo", in: try makeFolder(id, names: ["photo"]))]))
        // It starts reading once this test waits for its own read, which it then follows.
        let overlapping = Task { await store.refresh() }
        await store.refresh()
        XCTAssertEqual(store.batches.map(\.id), [id], "The batch shared before this refresh is listed when it returns.")
        await overlapping.value
        XCTAssertEqual(store.batches.map(\.id), [id])
    }

    /// The manifests builds from W3 to 3040093 wrote, with each file's URL beside its name, load as
    /// any other and are never rewritten by a read. Consuming an attachment rewrites the manifest
    /// with names alone and deletes only its files; the last one takes the batch with it. A
    /// version 1 manifest is no longer read: its batch is damaged and stays on disk.
    func testAManifestWithURLsLoadsAndIsRewrittenWithNamesOnly() async throws {
        // The golden manifest, written on a phone whose container had another path.
        let folder = try makeFolder()
        try FixtureLoader.data("share/manifest-v2-with-urls.json").write(to: folder.appendingPathComponent(ShareManifest.fileName))
        let repository = ShareInboxRepository(root: root)
        let loaded = try await repository.load()
        let batch = try XCTUnwrap(loaded.first?.batch)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(batch.id, G.batchID)
        XCTAssertEqual(batch.createdAt.timeIntervalSinceReferenceDate.bitPattern, G.Bits.manifest)
        XCTAssertEqual(batch.attachments.map(\.id), [0, 1, 3].map { G.sharedFiles[$0] })
        XCTAssertEqual(batch.attachments.map(\.original.filename), ["IMG_2001.JPG", "IMG_2002.HEIC", "DSC_0042.NEF"])
        XCTAssertEqual(batch.attachments[1].motion?.url.path, folder.appendingPathComponent(G.sharedFiles[2]).path, "Files resolve into this container.")
        XCTAssertEqual(batch.attachments[2].sidecar?.contentType, "application/rdf+xml")
        let unchanged = try Data(contentsOf: folder.appendingPathComponent(ShareManifest.fileName))
        XCTAssertEqual(unchanged, try FixtureLoader.data("share/manifest-v2-with-urls.json"), "Reading never rewrites a manifest.")

        // Consuming the first attachment rewrites the manifest with names alone and deletes only its file.
        try await repository.consume(G.sharedFiles[0], from: G.batchID)
        let data = try Data(contentsOf: folder.appendingPathComponent(ShareManifest.fileName))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["v"] as? Int, 2)
        let attachments = try XCTUnwrap(json["attachments"] as? [[String: Any]])
        XCTAssertEqual(attachments.compactMap { ($0["original"] as? [String: Any])?["name"] as? String }, [G.sharedFiles[1], G.sharedFiles[3]])
        XCTAssertEqual(attachments.flatMap { $0.values.compactMap { ($0 as? [String: Any]).map { Set($0.keys) } } },
                       Array(repeating: Set(["contentType", "filename", "name"]), count: 4), "No URL is written.")
        XCTAssertFalse(exists(folder.appendingPathComponent(G.sharedFiles[0])))
        for name in G.sharedFiles.dropFirst() { XCTAssertTrue(exists(folder.appendingPathComponent(name)), name) }
        let reloaded = try await repository.load()
        XCTAssertEqual(reloaded, [.ready(SharedBatch(id: batch.id, createdAt: batch.createdAt, attachments: Array(batch.attachments.dropFirst())))])

        // Consuming again is harmless, and the last attachment takes the batch with it.
        try await repository.consume(G.sharedFiles[0], from: G.batchID)
        try await repository.consume(G.sharedFiles[1], from: G.batchID)
        try await repository.consume(G.sharedFiles[3], from: G.batchID)
        XCTAssertFalse(exists(folder))
        try await repository.consume(G.sharedFiles[3], from: G.batchID)
        let empty = try await repository.load()
        XCTAssertEqual(empty, [])

        // A version 1 manifest, without a version and with URLs alone, is a damaged batch, kept.
        let old = try makeFolder()
        let unversioned = #"{"createdAt":0,"id":"\#(G.batchID.uuidString)","attachments":[{"original":{"url":"file:///private/var/mobile/Containers/Shared/AppGroup/x/ShareInbox/\#(G.batchID.uuidString)/\#(G.sharedFiles[0])","filename":"IMG_2001.JPG","contentType":"image/jpeg"}}]}"#
        try Data(unversioned.utf8).write(to: old.appendingPathComponent(ShareManifest.fileName))
        let refused = try await repository.load()
        XCTAssertEqual(refused, [.damaged(id: G.batchID, reason: .undecodable)])
        XCTAssertTrue(exists(old.appendingPathComponent(G.sharedFiles[0])), "Its files stay.")
    }

    func testManifestlessFolderCollectedAfter24Hours() async throws {
        let abandoned = UUID(), staged = UUID()
        let abandonedFolder = try makeFolder(abandoned, names: ["half-copied"])
        let stagedFolder = try makeFolder(staged, names: ["photo"])
        try await ShareInboxRepository(root: root).save(SharedBatch(id: staged, createdAt: Date(), attachments: [photo("photo", in: stagedFolder)]))
        let stranger = root.appendingPathComponent("not-a-batch", isDirectory: true)
        try FileManager.default.createDirectory(at: stranger, withIntermediateDirectories: true)
        let made = Date()

        let early = try await ShareInboxRepository(root: root, now: { made.addingTimeInterval(23 * 3600) }).load()
        XCTAssertEqual(early.map(\.id), [staged])
        XCTAssertTrue(exists(abandonedFolder), "A staging may still be running.")
        let late = ShareInboxRepository(root: root, now: { made.addingTimeInterval(24 * 3600 + 60) })
        let states = try await late.load()
        XCTAssertEqual(states.map(\.id), [staged])
        XCTAssertFalse(exists(abandonedFolder), "Left without a manifest for a day.")
        XCTAssertTrue(exists(stagedFolder), "A batch with a manifest stays, however old.")
        XCTAssertTrue(exists(stranger), "Only batch folders are collected.")
        let another = UUID()
        let anotherFolder = try makeFolder(another, names: [])
        let removed = await late.collectGarbage()
        XCTAssertEqual(removed, [another])
        XCTAssertFalse(exists(anotherFolder))
        XCTAssertTrue(exists(stagedFolder))
    }

    func testSidecarsPairWithTheirPhotosByStem() throws {
        let folder = URL(fileURLWithPath: "/inbox/ShareInbox/batch", isDirectory: true)
        func item(_ filename: String) -> SharedAttachment {
            SharedAttachment(original: SharedFile(name: UUID().uuidString, filename: filename, contentType: "application/octet-stream", folder: folder))
        }
        let paired = try ShareStaging.pairSidecars([item("IMG_1.CR3"), item("img_1.xmp"), item("DSC_2.NEF"), item("DSC_2.NEF.XMP"), item("clip.mov")])
        XCTAssertEqual(paired.map(\.original.filename), ["IMG_1.CR3", "DSC_2.NEF", "clip.mov"])
        XCTAssertEqual(paired.map { $0.sidecar?.filename }, ["img_1.xmp", "DSC_2.NEF.XMP", nil])
        XCTAssertThrowsError(try ShareStaging.pairSidecars([item("IMG_1.CR3"), item("IMG_1.xmp"), item("IMG_1.CR3.xmp")]), "Two sidecars for one photo.")
        XCTAssertThrowsError(try ShareStaging.pairSidecars([item("IMG_1.CR3"), item("IMG_2.xmp")]), "A sidecar without its photo.") { error in
            XCTAssertEqual(error.localizedDescription, "Include the matching original photo for IMG_2.xmp.")
        }
    }

    @MainActor func testStagingCopiesSharedFilesIntoASavedBatch() async throws {
        let source = container.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        func provider(_ name: String) throws -> NSItemProvider {
            let url = source.appendingPathComponent(name)
            try Data(name.utf8).write(to: url)
            return NSItemProvider(item: url as NSURL, typeIdentifier: UTType.fileURL.identifier)
        }
        let repository = ShareInboxRepository(root: root)
        let staging = ShareStaging(repository: repository)
        var reported: [String] = []
        let batch = try await staging.stage([try provider("IMG_0001.JPG"), try provider("DSC_0042.NEF"), try provider("DSC_0042.xmp")]) { index, count in
            reported.append("\(index + 1) of \(count)")
        }
        XCTAssertEqual(reported, ["1 of 3", "2 of 3", "3 of 3"])
        XCTAssertEqual(staging.batchID, batch.id)
        XCTAssertEqual(batch.attachments.map(\.original.filename), ["IMG_0001.JPG", "DSC_0042.NEF"])
        XCTAssertEqual(batch.attachments.map { $0.sidecar?.filename }, [nil, "DSC_0042.xmp"])
        XCTAssertEqual(batch.attachments[0].original.contentType, "image/jpeg")
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(batch.attachments[1].sidecar).url), Data("DSC_0042.xmp".utf8))
        XCTAssertTrue(exists(source.appendingPathComponent("IMG_0001.JPG")), "The source app's file is copied, not moved.")
        let loaded = try await repository.load()
        XCTAssertEqual(loaded, [.ready(batch)])
        let manifest = try Data(contentsOf: repository.folder(for: batch.id).appendingPathComponent(ShareManifest.fileName))
        XCTAssertEqual(manifest, try ShareManifest.encode(batch), "The extension writes what the app reads: version 2, by name.")
        XCTAssertEqual(try XCTUnwrap(JSONSerialization.jsonObject(with: manifest) as? [String: Any])["v"] as? Int, 2, "New batches are version 2.")
        XCTAssertNil(String(decoding: manifest, as: UTF8.self).range(of: "url"), "No URL is written.")
        await staging.discard()
        XCTAssertTrue(exists(repository.folder(for: batch.id)), "A saved batch stays when the share sheet closes.")

        // A share that fails leaves nothing behind.
        do {
            _ = try await staging.stage([try provider("IMG_0009.xmp")]) { _, _ in }
            XCTFail("A sidecar without its photo is refused.")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Include the matching original photo for IMG_0009.xmp.")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [batch.id.uuidString])
        do {
            _ = try await staging.stage([]) { _, _ in }
            XCTFail("An empty share is refused.")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Share between 1 and 100 files at a time.")
        }
    }
}
