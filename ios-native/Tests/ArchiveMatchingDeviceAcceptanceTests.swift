import Foundation
import IlyichPlatform
import Photos
import UIKit
import XCTest
@testable import Ilyich

/// Opt-in on an unlocked real phone: matches saved backups only. The hosted test app is inert;
/// this test never constructs an upload engine or changes Photos. Run with
/// TEST_RUNNER_ILYICH_ARCHIVE_MATCH_ACCEPTANCE=1 after checking the saved account and pause state.
@MainActor final class ArchiveMatchingDeviceAcceptanceTests: XCTestCase {
    /// Exercises only the automatic post-upload worker. Existing receipts seed the durable
    /// matching queue; this must not require the manual reconciliation action or an uploader.
    func testRetryArchivedOriginalLinksWithoutUploading() async throws {
        guard ProcessInfo.processInfo.environment["ILYICH_ARCHIVE_MATCH_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Live archive matching was not requested.")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Archive matching acceptance requires the owner's real Photos library.")
        #else
        executionTimeAllowance = 600
        let credential = try XCTUnwrap(KeychainCredentialStore().load())
        guard credential.requiresPasswordChange != true,
              !ReadOnlyPolicy.isEnabled(server: credential.server, userID: credential.userID),
              PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw XCTSkip("Existing writable account and full Photos access are required; no prompts are requested.")
        }
        guard TransferHost.shared.current == nil else {
            throw APIError.invalidResponse("Stop the live upload engine before archive matching acceptance.")
        }
        let store = TransferStore(url: TransferStore.url(for: credential.account))
        addTeardownBlock { await store.close() }
        let before = try await store.contents()
        guard before.engine?.intent == .paused, before.preferences?.automatic == false else {
            throw XCTSkip("Backup must already be paused and automatic backup off.")
        }
        guard before.receipts.count <= 100 else { throw XCTSkip("This live acceptance check is limited to 100 saved receipts.") }
        let idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        addTeardownBlock { await MainActor.run { UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled } }
        let initialTasks = try await store.sourceMatchTasks()
        let authorization = AuthorizationState(account: credential.account, token: credential.token, readOnly: false,
                                               requiresPasswordChange: false, mirror: nil)
        let api = try APIClient(baseURL: credential.server, accessToken: credential.token, userID: credential.userID,
                                authorization: authorization)
        addTeardownBlock { await api.shutdown() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveRetry-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let system = SystemPhotoKit()
        let journal = DeviceDatabase(url: folder.appendingPathComponent("device.sqlite"))
        let photos = PhotoKitAdapter(library: system, assets: system, journal: journal, staging: system)
        await photos.start()
        addTeardownBlock {
            system.stopObserving()
            try? FileManager.default.removeItem(at: folder)
        }
        let worker = PostUploadWorker(store: store, server: APITransferServer(client: api), photos: photos,
                                      authorization: authorization)
        addTeardownBlock { await worker.stop() }
        // Use the same startup wake as the app. The worker owns its retry timer and batching.
        await worker.request(.started)
        let deadline = Date().addingTimeInterval(240)
        while true {
            await worker.idle()
            let tasks = try await store.sourceMatchTasks()
            if !tasks.contains(where: { $0.state == "pending" }) || Date() >= deadline { break }
            try await Task.sleep(for: .seconds(1))
        }
        await worker.stop()
        let after = try await store.contents()
        XCTAssertEqual(after.engine, before.engine)
        XCTAssertEqual(after.preferences, before.preferences)
        XCTAssertEqual(after.jobs, before.jobs)
        XCTAssertEqual(after.attempts, before.attempts)
        XCTAssertEqual(after.stages, before.stages)
        XCTAssertEqual(after.confirmations, before.confirmations)
        XCTAssertEqual(after.receipts, before.receipts)
        XCTAssertNil(TransferHost.shared.current)
        let tasks = try await store.sourceMatchTasks()
        let stacks = try await store.stackTasks()
        var links: [[String: String]] = []
        for receipt in after.receipts.compactMap(\.receipt) {
            if let source = try await store.sourceOriginal(for: receipt.localID, revision: receipt.revision),
               let remoteID = source.remoteID {
                links.append(["currentID": receipt.original.id, "sourceID": remoteID, "sourceChecksum": source.checksum])
            }
        }
        let result: [String: Any] = [
            "initialSourceTasks": initialTasks.count, "confirmations": after.confirmations.count,
            "remainingSourceTasks": tasks.map { ["currentID": $0.currentID, "state": $0.state,
                "attempts": $0.attempts, "reason": $0.reason as Any? ?? NSNull()] as [String: Any] },
            "sourceLinks": links, "unfinishedProofStacks": stacks.filter { $0.sourceChecksum != nil }.count,
            "newUploadAttempts": 0,
        ]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
                                       uniformTypeIdentifier: "public.json")
        attachment.name = "Automatic archive matching result"; attachment.lifetime = .keepAlways; add(attachment)
        let pendingCount = tasks.filter { $0.state == "pending" }.count
        print("AUTOMATIC ARCHIVE MATCH: \(initialTasks.count) initial tasks, \(links.count) source links, \(pendingCount) pending, 0 new upload attempts")
        #endif
    }

    /// Reads only saved receipt/cache rows and PhotoKit resource metadata. It never requests
    /// resource bytes, constructs an engine/API client, or changes confirmations or Photos.
    func testInspectSavedBackupSourceMetadataWithoutHashing() async throws {
        guard ProcessInfo.processInfo.environment["ILYICH_ARCHIVE_MATCH_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Live archive matching diagnostics were not requested.")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Source metadata diagnostics require the owner's real Photos library.")
        #else
        executionTimeAllowance = 60
        let credential = try XCTUnwrap(KeychainCredentialStore().load())
        guard credential.requiresPasswordChange != true,
              !ReadOnlyPolicy.isEnabled(server: credential.server, userID: credential.userID) else {
            throw XCTSkip("The saved account does not permit archive matching diagnostics.")
        }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw XCTSkip("Photos full access must already be granted; this test does not request it.")
        }
        guard TransferHost.shared.current == nil else {
            throw APIError.invalidResponse("Stop the live upload engine before source metadata diagnostics.")
        }
        let store = TransferStore(url: TransferStore.url(for: credential.account))
        addTeardownBlock { await store.close() }
        let before = try await store.contents()
        guard before.engine?.intent == .paused, before.preferences?.automatic == false else {
            throw XCTSkip("Backup must already be paused and automatic backup off.")
        }
        guard before.receipts.count <= 100, before.confirmations.count <= 100 else {
            throw XCTSkip("Source metadata diagnostics are limited to 100 saved backups.")
        }
        let receipts = try await store.confirmedReceiptsForSourceMatching(after: nil, limit: 100)
        var result: [[String: Any]] = []
        for receipt in receipts {
            try Task.checkCancellation()
            let cached = try await store.sourceOriginal(for: receipt.localID, revision: receipt.revision)
            let asset = PHAsset.fetchAssets(withLocalIdentifiers: [receipt.localID], options: SystemPhotoKit.readableMediaOptions()).firstObject
            let resources = asset.map { PHAssetResource.assetResources(for: $0) } ?? []
            let described = resources.map {
                StagingResource(type: $0.type, contentType: $0.contentType.identifier, filename: $0.originalFilename)
            }
            let currentRevision = asset?.modificationDate.map(AssetRevision.init)
            let sourceIndex = asset.flatMap { StagingRules.sourceOriginal(described, isVideo: $0.mediaType == .video) }
            let reason: String
            if asset == nil { reason = "asset-unavailable" }
            else if currentRevision != receipt.revision { reason = "receipt-revision-mismatch" }
            else if sourceIndex == nil { reason = "no-unique-original-with-rendered-edit" }
            else { reason = "source-selection-eligible" }
            result.append([
                "remoteOriginalID": receipt.original.id,
                "assetExists": asset != nil,
                "isVideo": asset?.mediaType == .video,
                "receiptRevisionBits": String(receipt.revision.referenceSeconds.bitPattern, radix: 16),
                "currentRevisionBits": currentRevision.map { String($0.referenceSeconds.bitPattern, radix: 16) } as Any? ?? NSNull(),
                "revisionMatches": currentRevision == receipt.revision,
                "resources": described.map { ["type": String(describing: $0.type), "rawType": $0.type.rawValue,
                                                "filename": $0.filename, "uti": $0.contentType] as [String: Any] },
                "sourceOriginalIndex": sourceIndex as Any? ?? NSNull(),
                "cachedSourceChecksum": cached?.checksum as Any? ?? NSNull(),
                "cachedSourceRemoteID": cached?.remoteID as Any? ?? NSNull(),
                "reason": reason,
            ])
            print("ARCHIVE SOURCE METADATA: \(receipt.original.id) reason=\(reason) types=\(described.map { $0.type.rawValue })")
        }
        let after = try await store.contents()
        XCTAssertEqual(after, before)
        XCTAssertNil(TransferHost.shared.current)
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
                                       uniformTypeIdentifier: "public.json")
        attachment.name = "Archive source metadata diagnostics"; attachment.lifetime = .keepAlways; add(attachment)
        #endif
    }

    func testMatchSavedBackupsWithoutUploading() async throws {
        guard ProcessInfo.processInfo.environment["ILYICH_ARCHIVE_MATCH_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Live archive matching was not requested.")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Archive matching acceptance requires the owner's real Photos library.")
        #else
        executionTimeAllowance = 600
        let credential = try XCTUnwrap(KeychainCredentialStore().load())
        guard credential.requiresPasswordChange != true,
              !ReadOnlyPolicy.isEnabled(server: credential.server, userID: credential.userID) else {
            throw XCTSkip("The saved account does not permit linking originals.")
        }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw XCTSkip("Photos full access must already be granted; this test does not request it.")
        }
        let store = TransferStore(url: TransferStore.url(for: credential.account))
        addTeardownBlock { await store.close() }
        let before = try await store.contents()
        guard before.engine?.intent == .paused, before.preferences?.automatic == false else {
            throw XCTSkip("Backup must already be paused and automatic backup off.")
        }
        guard before.receipts.count <= 100 else { throw XCTSkip("Use the paged matching screen for larger backup histories.") }
        guard TransferHost.shared.current == nil else {
            throw APIError.invalidResponse("Stop the live upload engine before archive matching acceptance.")
        }
        let authorization = AuthorizationState(account: credential.account, token: credential.token, readOnly: false,
                                               requiresPasswordChange: false, mirror: nil)
        let api = try APIClient(baseURL: credential.server, accessToken: credential.token, userID: credential.userID,
                                authorization: authorization)
        addTeardownBlock { await api.shutdown() }
        let server = APITransferServer(client: api)
        // Refresh stale saved confirmations with exact reads before inspecting originals.
        let ids = try await store.confirmationRemoteIDs()
        var rows: [LocalAssetMatch] = []
        for id in ids.sorted() {
            let remote = try await server.remoteAsset(id: id)
            XCTAssertEqual(remote.ownerId, credential.userID)
            guard remote.id == id, remote.ownerId == credential.userID else { throw APIError.invalidResponse("Unexpected backup owner.") }
            rows.append(LocalAssetMatch(assetID: id, checksum: remote.checksum, cloudID: nil, createdAt: nil, adjustmentTime: nil,
                latitude: nil, longitude: nil, visible: remote.visibility == "timeline", checksumAlgorithm: remote.checksumAlgorithm,
                contentChecksum: remote.contentChecksum, isExternal: remote.isExternal,
                backupAvailable: !remote.isTrashed && remote.isOffline != true && remote.visibility != "locked"))
        }
        let removed = try await store.reconcileConfirmations(with: rows, checkedRemoteIDs: ids)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveMatch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let system = SystemPhotoKit()
        let journal = DeviceDatabase(url: folder.appendingPathComponent("device.sqlite"))
        let staging = PhotoKitAdapter(library: system, assets: system, journal: journal, staging: system)
        await staging.start()
        addTeardownBlock {
            system.stopObserving()
            try? FileManager.default.removeItem(at: folder)
        }
        let preferences = try XCTUnwrap(before.preferences)
        let matcher = SourceOriginalArchiveReconciler(account: credential.account, store: store, staging: staging, server: server)
        let report = try await matcher.reconcile(limit: 100,
            policy: StagingPolicy(allowCloud: preferences.downloadCloudOriginals, cellularPhotos: preferences.cellularPhotos,
                                  cellularVideos: preferences.cellularVideos))
        let worker = PostUploadWorker(store: store, server: server, photos: staging, authorization: authorization)
        await worker.request(.committed(.library))
        await worker.idle()
        await worker.stop()
        let after = try await store.contents()
        XCTAssertEqual(after.engine, before.engine)
        XCTAssertEqual(after.preferences, before.preferences)
        XCTAssertEqual(after.jobs, before.jobs)
        XCTAssertEqual(after.attempts, before.attempts)
        XCTAssertEqual(after.stages, before.stages)
        XCTAssertEqual(after.confirmations.count, before.confirmations.count - removed)
        XCTAssertNil(TransferHost.shared.current)
        let tasks = try await store.stackTasks()
        let result: [String: Int] = ["checked": report.scanned, "matched": report.matched, "scheduled": report.scheduled,
            "staleConfirmationsRemoved": removed, "confirmations": after.confirmations.count,
            "unfinishedProofStacks": tasks.filter { $0.sourceChecksum != nil }.count, "newUploadAttempts": 0]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
                                       uniformTypeIdentifier: "public.json")
        attachment.name = "Archive matching result"; attachment.lifetime = .keepAlways; add(attachment)
        print("ARCHIVE MATCH RESULT: \(result)")
        #endif
    }
}
