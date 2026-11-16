import Foundation
import IlyichPlatform
import Photos
import XCTest
@testable import Ilyich

/// Opt-in on an unlocked real phone: matches saved backups only. The hosted test app is inert;
/// this test never constructs an upload engine or changes Photos. Run with
/// TEST_RUNNER_ILYICH_ARCHIVE_MATCH_ACCEPTANCE=1 after checking the saved account and pause state.
@MainActor final class ArchiveMatchingDeviceAcceptanceTests: XCTestCase {
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
