import Foundation
import IlyichPlatform
import Photos
import Synchronization
import UIKit
import XCTest
@testable import Ilyich

/// Opt-in, real-phone acceptance for establishing the future-only boundary. This test reads
/// PhotoKit metadata only; it never starts the engine, creates a network client, or changes Photos.
@MainActor final class NewPhotosBackupDeviceAcceptanceTests: XCTestCase {
    func testEnableNewPhotosBackupCapturesMetadataBaselineWithoutUploading() async throws {
        guard ProcessInfo.processInfo.environment["ILYICH_NEW_PHOTOS_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Future-only backup activation was not requested.")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Future-only backup acceptance requires the owner's real Photos library.")
        #else
        executionTimeAllowance = 600
        let credential = try XCTUnwrap(KeychainCredentialStore().load())
        guard credential.requiresPasswordChange != true,
              !ReadOnlyPolicy.isEnabled(server: credential.server, userID: credential.userID),
              PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw XCTSkip("A saved writable account and existing Full Photos access are required; this test requests no permissions.")
        }
        guard TransferHost.shared.current == nil else {
            throw APIError.invalidResponse("Stop the live transfer engine before future-only backup acceptance.")
        }

        let store = TransferStore(url: TransferStore.url(for: credential.account))
        addTeardownBlock { await store.close() }
        let before = try await store.contents()
        let beforePreferences = before.preferences ?? TransferPreferences()
        let alreadyEnabled = beforePreferences.newPhotosOnly
            && beforePreferences.automatic
            && beforePreferences.newPhotosBaselineStartedAt != nil
            && before.engine?.intent == .automatic
        guard alreadyEnabled || (before.engine?.intent == .paused && !beforePreferences.automatic) else {
            throw XCTSkip("Backup must already be paused with automatic backup off, or already be in future-only mode.")
        }
        guard try await store.meta().engine == .transfer else {
            throw XCTSkip("The signed-in account's transfer database is not owned by the current engine.")
        }

        let previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        addTeardownBlock { await MainActor.run { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer } }

        let systemPhotoKit = SystemPhotoKit()
        let photoKit = GuardedDevicePhotoKit(base: systemPhotoKit)
        let journalFolder = FileManager.default.temporaryDirectory.appendingPathComponent("NewPhotosBaseline-" + UUID().uuidString,
                                                                                          isDirectory: true)
        try FileManager.default.createDirectory(at: journalFolder, withIntermediateDirectories: true)
        let adapter = PhotoKitAdapter(library: photoKit, assets: photoKit,
                                      journal: DeviceDatabase(url: journalFolder.appendingPathComponent("device.sqlite")),
                                      staging: photoKit)
        let staging = MetadataOnlyPhotoStaging(base: adapter)
        await adapter.start()
        addTeardownBlock {
            photoKit.stopObserving()
            try? FileManager.default.removeItem(at: journalFolder)
        }

        let registry = TransferHost.shared.registry ?? TransportRegistry.live()
        let backupTransport = registry.transport(.backup)
        let accountScope = credential.account.digest
        let initialTransport = await backupTransport.inventory()
        let initialScopedAttemptIDs = Set(initialTransport.tasks(scope: accountScope).compactMap(\.attempt))

        let authorization = AuthorizationState(account: credential.account, token: credential.token, readOnly: false,
                                               requiresPasswordChange: false, mirror: nil)
        let executor = NeverExecutingJobExecutor()
        let engine = TransferEngine(store: store, executor: executor, authorization: authorization, clock: ContinuousClock())
        addTeardownBlock { await engine.stop() }
        // No engine.start(): activation is a metadata-only command and must not lease jobs.
        try await engine.enableNewPhotosBackup(staging: staging, cancelAttempts: { attempts in
            let wanted = Set(attempts)
            let inventory = await backupTransport.inventory()
            let references = try await store.stagingReferences()
            let taskIDs = inventory.tasks(scope: accountScope).compactMap { task -> Int? in
                guard task.isLive, let attempt = task.attempt else { return nil }
                guard wanted.contains(attempt) || !references.attempts.contains(attempt.rawValue) else { return nil }
                return task.taskID
            }
            await backupTransport.cancel(tasks: taskIDs)
        })

        let afterFirst = try await store.contents()
        let firstPreferences = try XCTUnwrap(afterFirst.preferences)
        let firstBaselineDate = try XCTUnwrap(firstPreferences.newPhotosBaselineStartedAt)
        let storedBaselineIDs = try await store.newPhotosBaselineIDs()
        let baselineIDs = try XCTUnwrap(storedBaselineIDs)
        XCTAssertTrue(firstPreferences.newPhotosOnly)
        XCTAssertTrue(firstPreferences.automatic)
        XCTAssertEqual(firstPreferences.scope, .entireLibrary)
        XCTAssertEqual(afterFirst.engine?.intent, .automatic)
        if !alreadyEnabled {
            XCTAssertGreaterThan(staging.candidateBatchCount, 0, "The cutoff must come from Photos metadata enumeration.")
        }
        XCTAssertFalse(baselineIDs.isEmpty, "Full Photos access should produce an existing-ID baseline.")
        if let sample = baselineIDs.sorted().first {
            let isExcluded = try await store.isExcludedFromNewPhotosBackup(sample)
            let automaticIDs = try await store.automaticFollowUpLocalIDs([sample])
            XCTAssertTrue(isExcluded, "An ID captured at activation must remain outside automatic discovery.")
            XCTAssertFalse(automaticIDs.contains(sample))
        }

        // Re-enabling is idempotent: it keeps the original cutoff and does not enumerate again.
        let batchesAfterFirstActivation = staging.candidateBatchCount
        try await engine.enableNewPhotosBackup(staging: staging, cancelAttempts: { attempts in
            let wanted = Set(attempts)
            let inventory = await backupTransport.inventory()
            let references = try await store.stagingReferences()
            let taskIDs = inventory.tasks(scope: accountScope).compactMap { task -> Int? in
                guard task.isLive, let attempt = task.attempt else { return nil }
                guard wanted.contains(attempt) || !references.attempts.contains(attempt.rawValue) else { return nil }
                return task.taskID
            }
            await backupTransport.cancel(tasks: taskIDs)
        })

        let after = try await store.contents()
        let afterBaselineDate = try XCTUnwrap(after.preferences?.newPhotosBaselineStartedAt)
        XCTAssertEqual(afterBaselineDate, firstBaselineDate)
        XCTAssertEqual(staging.candidateBatchCount, batchesAfterFirstActivation, "Idempotent enable must reuse the saved baseline.")
        XCTAssertEqual(after.confirmations, before.confirmations)
        XCTAssertEqual(after.receipts, before.receipts)
        XCTAssertEqual(after.confirmations.count, before.confirmations.count)
        let preexistingBaselineJobs = before.jobs.filter { baselineIDs.contains($0.sourceKey) }
        let remainingBaselineJobs = after.jobs.filter { baselineIDs.contains($0.sourceKey) }
        if !alreadyEnabled {
            XCTAssertTrue(remainingBaselineJobs.isEmpty, "First activation removes every queued library job for the pre-existing baseline.")
            XCTAssertTrue(after.jobs.isEmpty, "First activation also removes old jobs whose Photos item no longer exists.")
        }
        XCTAssertTrue(Set(after.attempts.map(\.id)).isSubset(of: Set(before.attempts.map(\.id))), "Activation created no upload attempts.")
        XCTAssertEqual(executor.callCount, 0)
        XCTAssertEqual(staging.stageCallCount, 0)
        XCTAssertEqual(staging.sourceOriginalCallCount, 0)
        XCTAssertEqual(photoKit.authorizationRequestCount, 0, "The test must not request Photos permission.")
        XCTAssertEqual(photoKit.mutationCallCount, 0, "Activation must not change Photos.")
        XCTAssertNil(TransferHost.shared.current)

        let pastVerificationCalls = Locked(0)
        let discovery = LibraryDiscovery(store: store, staging: staging, revalidateConfirmations: {
            pastVerificationCalls.mutate { $0 += 1 }
            throw BackupError.message("Future-only discovery must not verify past backups.")
        })
        let discovered = try await discovery.run()
        let discoveredIDs = Set(discovered.inventory?.revisions.keys.map { $0 } ?? [])
        XCTAssertTrue(discoveredIDs.isDisjoint(with: baselineIDs))
        XCTAssertEqual(pastVerificationCalls.value, 0)
        XCTAssertEqual(staging.stageCallCount, 0)
        XCTAssertEqual(staging.sourceOriginalCallCount, 0)

        let finalTransport = await backupTransport.inventory()
        let finalScopedAttemptIDs = Set(finalTransport.tasks(scope: accountScope).compactMap(\.attempt))
        XCTAssertTrue(finalScopedAttemptIDs.isSubset(of: initialScopedAttemptIDs), "Activation left no newly submitted backup tasks.")
        let removedAttempts = Set(before.attempts.map(\.id)).subtracting(after.attempts.map(\.id))
        let remainingOldTasks = finalTransport.tasks(scope: accountScope).filter {
            $0.isLive && $0.attempt.map { removedAttempts.contains($0.rawValue) } == true
        }
        XCTAssertTrue(remainingOldTasks.isEmpty, "Cancelled library jobs must not keep uploading through an OS-owned task.")

        await engine.stop()
        await store.close()
        let reopenedStore = TransferStore(url: TransferStore.url(for: credential.account))
        addTeardownBlock { await reopenedStore.close() }
        let savedPreferences = try await reopenedStore.preferences()
        let savedBaselineDate = try await reopenedStore.newPhotosBaselineStartedAt()
        let savedBaselineIDs = try await reopenedStore.newPhotosBaselineIDs()
        let persistedPreferences = try XCTUnwrap(savedPreferences)
        let persistedBaselineDate = try XCTUnwrap(savedBaselineDate)
        let persistedBaselineIDs = try XCTUnwrap(savedBaselineIDs)
        XCTAssertTrue(persistedPreferences.newPhotosOnly)
        XCTAssertEqual(persistedPreferences.newPhotosBaselineStartedAt, firstBaselineDate)
        XCTAssertEqual(persistedBaselineDate, firstBaselineDate)
        XCTAssertEqual(persistedBaselineIDs, baselineIDs)

        // Aggregate-only diagnostics: no local identifiers, credentials, asset names, or paths.
        let result: [String: Any] = [
            "alreadyEnabledAtStart": alreadyEnabled,
            "baselineItemCount": baselineIDs.count,
            "baselineStartedAt": firstBaselineDate.timeIntervalSince1970,
            "metadataBatchesRead": staging.candidateBatchCount,
            "baselineDateStableOnReenable": afterBaselineDate == firstBaselineDate,
            "confirmationsPreserved": after.confirmations == before.confirmations,
            "confirmationCountPreserved": after.confirmations.count == before.confirmations.count,
            "confirmationCount": after.confirmations.count,
            "receiptsPreserved": after.receipts == before.receipts,
            "oldQueuedLibraryJobsRemoved": alreadyEnabled ? preexistingBaselineJobs.count - remainingBaselineJobs.count : before.jobs.count - after.jobs.count,
            "remainingPreexistingLibraryJobs": remainingBaselineJobs.count,
            "automaticBackupEnabled": persistedPreferences.automatic,
            "newItemsDiscovered": discoveredIDs.count,
            "pastVerificationCalls": pastVerificationCalls.value,
            "remainingOldUploadTasks": remainingOldTasks.count,
            "newAttemptCount": Set(after.attempts.map(\.id)).subtracting(before.attempts.map(\.id)).count,
            "executorCalls": executor.callCount,
            "stageCalls": staging.stageCallCount,
            "sourceOriginalCalls": staging.sourceOriginalCallCount,
            "photosAuthorizationRequests": photoKit.authorizationRequestCount,
            "photosMutationCalls": photoKit.mutationCallCount,
            "newBackupTaskCount": finalScopedAttemptIDs.subtracting(initialScopedAttemptIDs).count,
            "persistedBaselineVerified": persistedBaselineIDs == baselineIDs && persistedBaselineDate == firstBaselineDate,
        ]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
                                       uniformTypeIdentifier: "public.json")
        attachment.name = "Future-only backup activation"; attachment.lifetime = .keepAlways; add(attachment)
        print("NEW-PHOTOS BACKUP ACCEPTANCE: \(result)")
        #endif
    }
}

/// Allows ordinary PhotoKit metadata queries, while turning accidental prompts or library writes
/// into a visible acceptance failure instead of performing them.
private final class GuardedDevicePhotoKit: PhotoLibraryPerforming, AssetFetching, PhotoStagingReading, Sendable {
    let base: SystemPhotoKit
    private let authorizationRequests = Mutex(0)
    private let mutations = Mutex(0)

    init(base: SystemPhotoKit) { self.base = base }

    var authorizationRequestCount: Int { authorizationRequests.withLock { $0 } }
    var mutationCallCount: Int { mutations.withLock { $0 } }

    func authorizationStatus() -> PHAuthorizationStatus { base.authorizationStatus() }
    func requestAuthorization() async -> PHAuthorizationStatus {
        authorizationRequests.withLock { $0 += 1 }
        return base.authorizationStatus()
    }
    func startObserving(_ onChange: @escaping @Sendable (PhotoLibraryChangeDetails) -> Void) { base.startObserving(onChange) }
    func stopObserving() { base.stopObserving() }
    func performChanges(_ block: @escaping @Sendable () -> Void) async throws {
        mutations.withLock { $0 += 1 }
        throw BackupError.message("This acceptance test forbids Photos changes.")
    }
    func requestDeletion(of ids: [DeviceAssetID]) { mutations.withLock { $0 += 1 } }
    func requestFavorite(_ isFavorite: Bool, for ids: [DeviceAssetID]) { mutations.withLock { $0 += 1 } }
    func requestCreation(still: URL?, video: URL?, pairedVideo: URL?) -> DeviceAssetID? {
        mutations.withLock { $0 += 1 }
        return nil
    }

    func states(of ids: [DeviceAssetID]) -> [DeviceAssetState] { base.states(of: ids) }
    func albums() -> [DeviceAlbum] { base.albums() }
    func allAssetIDs() -> Set<String> { base.allAssetIDs() }
    func members(of albumIDs: Set<String>, scope: PhotoSelectionScope) -> Set<String> { base.members(of: albumIDs, scope: scope) }
    func candidates(_ ids: [String]) -> [DeviceCandidate] { base.candidates(ids) }
}

/// A guardrail executor: any attempted job execution fails the acceptance run and is counted.
private final class NeverExecutingJobExecutor: JobExecuting {
    private let calls = Mutex(0)
    var callCount: Int { calls.withLock { $0 } }

    func execute(_ job: LeasedJob, context: JobContext) async throws -> JobResult {
        calls.withLock { $0 += 1 }
        throw BackupError.message("The acceptance test must never execute a transfer job.")
    }
}

/// Delegates only the real metadata enumeration to PhotoKit. Byte reads and source fingerprints
/// are trap methods, so this test cannot stage, hash, or download an original accidentally.
private final class MetadataOnlyPhotoStaging: PhotoLibraryStaging, NewPhotosBaselineAccessReading {
    let base: PhotoKitAdapter
    private let batches = Mutex(0)
    private let stageCalls = Mutex(0)
    private let sourceCalls = Mutex(0)

    init(base: PhotoKitAdapter) { self.base = base }

    var authorization: PHAuthorizationStatus { base.authorization }
    var candidateBatchCount: Int { batches.withLock { $0 } }
    var stageCallCount: Int { stageCalls.withLock { $0 } }
    var sourceOriginalCallCount: Int { sourceCalls.withLock { $0 } }

    func newPhotosBaselineAccess() async -> DeviceAccess { await base.refreshAccess() }
    func albums() async -> [DeviceAlbum] { await base.albums() }

    func candidates(scope: PhotoSelectionScope, included: Set<String>, excluded: Set<String>) -> AsyncThrowingStream<[DeviceCandidate], any Error> {
        let upstream = base.candidates(scope: scope, included: included, excluded: excluded)
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: [DeviceCandidate].self)
        let worker = Task {
            do {
                for try await batch in upstream {
                    batches.withLock { $0 += 1 }
                    continuation.yield(batch)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in worker.cancel() }
        return stream
    }

    func stage(_ localID: String, into directory: URL, stageID: String, policy: StagingPolicy,
               progress: @escaping @Sendable (Double) -> Void) async throws -> PreparedPhoto {
        stageCalls.withLock { $0 += 1 }
        throw BackupError.message("Metadata-only acceptance forbids staging Photos resources.")
    }

    func albumMembers(_ albumID: String, excluded: Set<String>, scope: PhotoSelectionScope) async -> [String] {
        await base.albumMembers(albumID, excluded: excluded, scope: scope)
    }

    func existing(_ localIDs: [String]) async throws -> Set<String> { try await base.existing(localIDs) }

    func sourceOriginal(_ localID: String, revision: AssetRevision, policy: StagingPolicy) async throws -> SourceOriginalFingerprint? {
        sourceCalls.withLock { $0 += 1 }
        throw BackupError.message("Metadata-only acceptance forbids source-original reads or hashes.")
    }

    func sourceOriginalIsCurrent(_ localID: String, fingerprint: SourceOriginalFingerprint,
                                 policy: StagingPolicy) async throws -> Bool {
        sourceCalls.withLock { $0 += 1 }
        throw BackupError.message("Metadata-only acceptance forbids source-original reads or hashes.")
    }
}
