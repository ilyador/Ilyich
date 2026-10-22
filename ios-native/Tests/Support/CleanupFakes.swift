import Foundation
import IlyichPlatform
import Synchronization
import XCTest
@testable import Ilyich

/// Receipts for cleanup's tests, changed from the test.
final class FakeReceipts: ReceiptRepository {
    private struct State {
        var receipts: [String: CleanupReceipt]? = [:]
        var sizes: [[String: VerifiedSize]] = []
        var marked: [[String]] = []
        var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
    }
    private let state = Mutex(State())

    func put(_ receipt: CleanupReceipt, notify: Bool = true) {
        state.withLock { $0.receipts?[receipt.localID] = receipt }
        if notify { self.notify() }
    }

    /// Tells subscribers the receipts changed, whether or not they did, as a rewrite of the
    /// backup state does.
    func notify() {
        for subscriber in state.withLock({ Array($0.subscribers.values) }) { subscriber.yield() }
    }

    func makeUnavailable() { state.withLock { $0.receipts = nil } }

    var recordedSizes: [[String: VerifiedSize]] { state.withLock { $0.sizes } }
    var marked: [[String]] { state.withLock { $0.marked } }
    func receipt(_ id: String) -> CleanupReceipt? { state.withLock { $0.receipts?[id] } }

    func receipts(account: String) async -> [String: CleanupReceipt]? { state.withLock { $0.receipts } }

    func recordSizes(_ sizes: [String: VerifiedSize], account: String) async { state.withLock { $0.sizes.append(sizes) } }

    func markLocallyDeleted(_ localIDs: [String], account: String) async {
        state.withLock { state in
            state.marked.append(localIDs)
            for id in localIDs { state.receipts?[id]?.locallyDeleted = true }
        }
    }

    func changes() async -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        state.withLock { $0.subscribers[id] = continuation }
        continuation.onTermination = { [weak self] _ in self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) } }
        return stream
    }
}

/// The server's answers to cleanup's strict GETs, with what was asked and how many at once.
final class FakeRemote: Sendable {
    enum Answer: Sendable {
        case asset(BackupRemoteAsset)
        case failure(any Error & Sendable)
    }

    private struct State {
        var answers: [String: Answer] = [:]
        var requests: [String] = []
        var inFlight = 0
        var maxInFlight = 0
        var gate: StubServer.Gate?
        var delay: Duration?
        var onRequest: (@Sendable (String) -> Void)?
    }
    private let state = Mutex(State())

    func set(_ id: String, _ answer: Answer) { state.withLock { $0.answers[id] = answer } }
    func set(_ asset: BackupRemoteAsset) { set(asset.id, .asset(asset)) }
    func answer(_ id: String) -> Answer? { state.withLock { $0.answers[id] } }

    /// Every request waits until `gate` opens.
    func hold(_ gate: StubServer.Gate?) { state.withLock { $0.gate = gate } }
    func delay(_ delay: Duration?) { state.withLock { $0.delay = delay } }
    /// Runs `hook` as each request arrives, before it is answered.
    func onRequest(_ hook: (@Sendable (String) -> Void)?) { state.withLock { $0.onRequest = hook } }

    var requests: [String] { state.withLock { $0.requests } }
    var maxInFlight: Int { state.withLock { $0.maxInFlight } }
    func clearRequests() { state.withLock { $0.requests = []; $0.maxInFlight = 0 } }

    func fetch(_ id: String) async throws -> BackupRemoteAsset {
        let (gate, delay, hook) = state.withLock { state in
            state.requests.append(id)
            state.inFlight += 1
            state.maxInFlight = max(state.maxInFlight, state.inFlight)
            return (state.gate, state.delay, state.onRequest)
        }
        defer { state.withLock { $0.inFlight -= 1 } }
        hook?(id)
        if let gate { await gate.wait() }
        if let delay { try await Task.sleep(for: delay) }
        switch state.withLock({ $0.answers[id] }) {
        case .asset(let asset): return asset
        case .failure(let error): throw error
        case nil: throw ServerFailure.notFound
        }
    }
}

/// A CleanupService over fakes: Photos (through the real adapter and its journal, with a fake
/// PhotoKit that never touches the phone's library), receipts, the server, the account and
/// settings in a defaults suite of its own.
@MainActor final class CleanupHarness {
    static let owner = "user"
    static let revision = FakePhotoKit.revision
    /// Photos taken before this pass the default 30-day cutoff.
    static let old = Date(timeIntervalSince1970: 1_580_000_000)

    let photos = FakePhotoKit()
    let journal: DeviceDatabase
    let adapter: PhotoKitAdapter
    let receipts = FakeReceipts()
    let remote = FakeRemote()
    let authorization: AuthorizationState
    let defaults: UserDefaults
    let settings: CleanupSettingsStore
    let credentialCurrent = Locked(true)
    let service: CleanupService
    var account: String { authorization.account.digest }

    init(_ test: XCTestCase, removalAllowed: Bool = true, verificationLimit: Int = 6, batchSize: Int = 250,
         serverChanges: (@Sendable () async -> AsyncStream<LibraryChange>)? = nil) {
        journal = DeviceDatabase(url: test.deviceDatabaseURL())
        adapter = PhotoKitAdapter(library: photos, assets: photos, journal: journal, staging: photos, coalescing: .milliseconds(1))
        authorization = AuthorizationState(account: AccountID(server: URL(string: "https://photos.example/api")!, userID: Self.owner),
                                           token: "token", readOnly: false, requiresPasswordChange: false, mirror: nil)
        let suite = "CleanupTests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        settings = CleanupSettingsStore(defaults: defaults)
        let adapter = adapter, photos = photos, remote = remote, credential = credentialCurrent
        service = CleanupService(account: authorization.account.digest, ownerID: Self.owner, authorization: authorization, receipts: receipts,
                                 device: { PhotoKitCleanupDevice(adapter: adapter, reader: photos) },
                                 remote: { try await remote.fetch($0) }, settings: settings,
                                 credentialIsCurrent: { credential.value }, serverChanges: serverChanges,
                                 removalAllowed: removalAllowed, verificationLimit: verificationLimit, batchSize: batchSize)
        let service = service
        test.addTeardownBlock {
            await service.shutdown()
            UserDefaults().removePersistentDomain(forName: suite)
        }
    }

    /// A photo on the phone, backed up, with matching server copies: a candidate unless changed.
    @discardableResult
    func addBackedUp(_ id: String, live: Bool = false, created: Date? = CleanupHarness.old, video: Bool = false,
                     favorite: Bool = false, canDelete: Bool = true) -> CleanupReceipt {
        photos.add(id, isFavorite: favorite, canDelete: canDelete)
        photos.setFacts(id, FakePhotoKit.Facts(created: created, isVideo: video, shape: live ? .livePhoto : .singleOriginal))
        let receipt = CleanupReceipt(localID: id, revision: AssetRevision(referenceSeconds: Self.revision),
                                     original: .init(id: "server-\(id)", checksum: "sha-\(id)"),
                                     motion: live ? .init(id: "motion-\(id)", checksum: "sha-motion-\(id)") : nil)
        receipts.put(receipt, notify: false)
        remote.set(Self.remoteAsset(receipt.original, motion: receipt.motion?.id, size: 1_000))
        if let motion = receipt.motion { remote.set(Self.remoteAsset(motion, size: 500)) }
        return receipt
    }

    static func remoteAsset(_ copy: CleanupReceipt.RemoteCopy, motion: String? = nil, owner: String = CleanupHarness.owner,
                            checksum: String? = nil, trashed: Bool = false, visibility: String? = "timeline",
                            offline: Bool? = false, size: Int64? = nil) -> BackupRemoteAsset {
        BackupRemoteAsset(id: copy.id, ownerId: owner, checksum: checksum ?? copy.checksum, isTrashed: trashed, livePhotoVideoId: motion,
                          visibility: visibility, isOffline: offline, knownByteCount: size)
    }

    func scan() async throws -> CleanupScanResult { try await service.scan() }

    func candidateIDs() async throws -> Set<String> { Set(try await scan().candidates.map(\.localID)) }
}
