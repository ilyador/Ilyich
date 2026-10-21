import Foundation
import Photos
import Synchronization
import XCTest
@testable import Ilyich

/// Photos for the adapter's tests. Assets live in a table. A change block runs on a serial queue of
/// the fake's own, as Photos runs it, and what it asks for applies only once the change commits. A
/// test can hold a change at iOS's prompt, fail it, or change an asset just before its block runs.
final class FakePhotoKit: PhotoLibraryPerforming, AssetFetching {
    struct Favorite: Equatable, Sendable {
        let ids: [DeviceAssetID]
        let value: Bool
    }

    struct Creation: Equatable, Sendable {
        let id: DeviceAssetID
        let still: URL?
        let video: URL?
        let pairedVideo: URL?
    }

    private struct Requests: Sendable {
        var deletions: [[DeviceAssetID]] = []
        var favorites: [Favorite] = []
        var creations: [Creation] = []
    }

    private struct State: Sendable {
        var status: PHAuthorizationStatus
        var assets: [DeviceAssetID: DeviceAssetState] = [:]
        var registrations = 0
        var onChange: (@Sendable (PhotoLibraryChangeDetails) -> Void)?
        var performed = 0
        /// What the running change block asked for.
        var asked = Requests()
        var committed = Requests()
        var requestsMade = 0
        var requestsOnMainThread = 0
        var readsOnMainThread = 0
        var created = 0
        var nextFailure: (any Error)?
        var prompt: StubServer.Gate?
        var beforeBlock: (@Sendable () async -> Void)?
    }

    private let state: Mutex<State>
    private let queue = DispatchQueue(label: "FakePhotoKit.changes")

    init(status: PHAuthorizationStatus = .authorized) {
        state = Mutex(State(status: status))
    }

    // MARK: - Setting up

    static let revision: Double = 700_000_000

    /// Puts an asset in the library, or replaces it.
    func add(_ id: String, revision: Double = FakePhotoKit.revision, isFavorite: Bool = false, canDelete: Bool = true, canEdit: Bool = true) {
        let asset = DeviceAssetState(id: DeviceAssetID(rawValue: id), revision: AssetRevision(referenceSeconds: revision),
                                     isFavorite: isFavorite, canDelete: canDelete, canEditProperties: canEdit)
        state.withLock { $0.assets[asset.id] = asset }
    }

    /// Edits an asset, which moves its revision.
    func touch(_ id: String, revision: Double) {
        update(id) { DeviceAssetState(id: $0.id, revision: AssetRevision(referenceSeconds: revision), isFavorite: $0.isFavorite,
                                      canDelete: $0.canDelete, canEditProperties: $0.canEditProperties) }
    }

    func setDeletable(_ id: String, _ value: Bool) {
        update(id) { DeviceAssetState(id: $0.id, revision: $0.revision, isFavorite: $0.isFavorite, canDelete: value, canEditProperties: $0.canEditProperties) }
    }

    func remove(_ id: String) { state.withLock { _ = $0.assets.removeValue(forKey: DeviceAssetID(rawValue: id)) } }

    func setStatus(_ status: PHAuthorizationStatus) { state.withLock { $0.status = status } }

    /// The next change fails with `error` once its block has run, as when the person declines
    /// iOS's prompt. Nothing it asked for applies.
    func failNextChange(with error: any Error) { state.withLock { $0.nextFailure = error } }

    /// Every change waits at iOS's prompt, after its block has run, until `gate` opens.
    func holdAtPrompt(_ gate: StubServer.Gate) { state.withLock { $0.prompt = gate } }

    /// The next change runs `hook` first, after the adapter's own checks and before its block, as
    /// when the library changes meanwhile.
    func beforeBlock(_ hook: @escaping @Sendable () async -> Void) { state.withLock { $0.beforeBlock = hook } }

    /// Reports a change to the app's observer, as Photos does.
    func emit(_ details: PhotoLibraryChangeDetails) {
        let observer = state.withLock { $0.onChange }
        observer?(details)
    }

    // MARK: - What happened

    func asset(_ id: String) -> DeviceAssetState? { state.withLock { $0.assets[DeviceAssetID(rawValue: id)] } }
    var registrations: Int { state.withLock { $0.registrations } }
    var performed: Int { state.withLock { $0.performed } }
    /// Requests change blocks made, whether or not their change committed.
    var requestsMade: Int { state.withLock { $0.requestsMade } }
    var requestsOnMainThread: Int { state.withLock { $0.requestsOnMainThread } }
    var readsOnMainThread: Int { state.withLock { $0.readsOnMainThread } }
    var deletions: [[DeviceAssetID]] { state.withLock { $0.committed.deletions } }
    var favorites: [Favorite] { state.withLock { $0.committed.favorites } }
    var creations: [Creation] { state.withLock { $0.committed.creations } }

    // MARK: - PhotoLibraryPerforming and AssetFetching

    func authorizationStatus() -> PHAuthorizationStatus { state.withLock { $0.status } }

    func requestAuthorization() async -> PHAuthorizationStatus { state.withLock { $0.status } }

    func startObserving(_ onChange: @escaping @Sendable (PhotoLibraryChangeDetails) -> Void) {
        state.withLock { state in
            state.registrations += 1
            state.onChange = onChange
        }
    }

    func stopObserving() { state.withLock { $0.onChange = nil } }

    func performChanges(_ block: @escaping @Sendable () -> Void) async throws {
        let hook = state.withLock { state -> (@Sendable () async -> Void)? in
            state.performed += 1
            defer { state.beforeBlock = nil }
            return state.beforeBlock
        }
        if let hook { await hook() }
        // Photos runs the block on a queue of its own.
        let asked = await withCheckedContinuation { (done: CheckedContinuation<Requests, Never>) in
            queue.async {
                block()
                done.resume(returning: self.state.withLock { state in
                    defer { state.asked = Requests() }
                    return state.asked
                })
            }
        }
        let prompt = state.withLock { $0.prompt }
        if let prompt { await prompt.wait() }
        let failure = state.withLock { state -> (any Error)? in
            if let failure = state.nextFailure {
                state.nextFailure = nil
                return failure
            }
            for ids in asked.deletions { for id in ids { state.assets[id] = nil } }
            for favorite in asked.favorites {
                for id in favorite.ids {
                    guard let asset = state.assets[id] else { continue }
                    state.assets[id] = DeviceAssetState(id: id, revision: asset.revision, isFavorite: favorite.value,
                                                        canDelete: asset.canDelete, canEditProperties: asset.canEditProperties)
                }
            }
            for creation in asked.creations {
                state.assets[creation.id] = DeviceAssetState(id: creation.id, revision: AssetRevision(referenceSeconds: Self.revision), isFavorite: false,
                                                             canDelete: true, canEditProperties: true)
            }
            state.committed.deletions += asked.deletions
            state.committed.favorites += asked.favorites
            state.committed.creations += asked.creations
            return nil
        }
        if let failure { throw failure }
    }

    func requestDeletion(of ids: [DeviceAssetID]) { record { $0.deletions.append(ids) } }

    func requestFavorite(_ isFavorite: Bool, for ids: [DeviceAssetID]) { record { $0.favorites.append(Favorite(ids: ids, value: isFavorite)) } }

    func requestCreation(still: URL?, video: URL?, pairedVideo: URL?) -> DeviceAssetID? {
        let id = DeviceAssetID(rawValue: "created-\(state.withLock { state in state.created += 1; return state.created })")
        record { $0.creations.append(Creation(id: id, still: still, video: video, pairedVideo: pairedVideo)) }
        return id
    }

    func states(of ids: [DeviceAssetID]) -> [DeviceAssetState] {
        let onMain = Thread.isMainThread
        return state.withLock { state in
            if onMain { state.readsOnMainThread += 1 }
            return Set(ids).compactMap { state.assets[$0] }
        }
    }

    private func record(_ request: (inout Requests) -> Void) {
        let onMain = Thread.isMainThread
        state.withLock { state in
            request(&state.asked)
            state.requestsMade += 1
            if onMain { state.requestsOnMainThread += 1 }
        }
    }

    private func update(_ id: String, _ change: (DeviceAssetState) -> DeviceAssetState) {
        state.withLock { state in
            let key = DeviceAssetID(rawValue: id)
            guard let asset = state.assets[key] else { return }
            state.assets[key] = change(asset)
        }
    }
}

extension XCTestCase {
    /// A device database in a folder of its own, removed after the test.
    func deviceDatabaseURL() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("IlyichDevice-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("device.sqlite")
    }

    /// Everything `stream` yields from now on, until the test ends.
    func listen<Element: Sendable>(to stream: AsyncStream<Element>) -> Locked<[Element]> {
        let heard = Locked<[Element]>([])
        let reader = Task { for await element in stream { heard.mutate { $0.append(element) } } }
        addTeardownBlock { reader.cancel() }
        return heard
    }

    /// Waits until `condition` holds, failing the test after five seconds. On the main actor, as
    /// the tests that wait are.
    @MainActor func waitFor(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out.", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
