import Foundation
import Synchronization

struct ServerEventConnection: Sendable {
    /// The server's hints. Hints that arrive while nobody reads wait merged into one.
    let events: AsyncThrowingStream<ServerInvalidation, any Error>
    let close: @Sendable () -> Void
}

/// What the live connection says changed on the server. Durable data always comes from the
/// sync stream; a hint says that a pass is due, and carries what the stream may not.
struct ServerInvalidation: Sendable, Equatable {
    var assetIDs: Set<String> = []
    /// Assets' new media revisions, from hints that carry the asset. A preview made again after an
    /// edit changes the revision, and the stream reports that only if the asset's record changed too.
    var mediaRevisions: [String: String] = [:]
    var configurationChanged = false

    /// Hints merge: the assets of both, the later revision of each, and either's flag.
    mutating func merge(_ later: ServerInvalidation) {
        assetIDs.formUnion(later.assetIDs)
        mediaRevisions.merge(later.mediaRevisions) { _, newer in newer }
        configurationChanged = configurationChanged || later.configurationChanged
    }
}

/// The server deliberately enables only Engine.IO v4 WebSocket transport and the
/// default Socket.IO namespace. This client receives invalidations; durable data
/// always comes from the resumable sync stream, including after reconnection.
enum SocketEventPacket: Sendable {
    case open, ping(String), invalidation(ServerInvalidation), ignore
    static func parse(_ packet: String) throws -> Self {
        if packet.hasPrefix("0") { return .open }
        if packet.hasPrefix("2") { return .ping(String(packet.dropFirst())) }
        if packet == "1" || packet.hasPrefix("41") { throw URLError(.networkConnectionLost) }
        if packet.hasPrefix("44") { throw APIError.invalidResponse("The server rejected the live connection. The library will reconnect.") }
        // The namespace connected. Whatever happened while it was down was never hinted, so a pass
        // is due; the server's configuration did not change.
        if packet.hasPrefix("40") { return .invalidation(ServerInvalidation()) }
        guard packet.hasPrefix("42"), let values = try? JSONDecoder().decode([EntityJSON].self, from: Data(packet.dropFirst(2).utf8)), let name = values.first?.string else { return .ignore }
        if name == "error" {
            // Immich's own socket says the session is gone; the session check confirms it.
            if values.dropFirst().first?.string == "unauthorized" { throw ServerFailure.sessionExpired(nil) }
            throw APIError.invalidResponse("The server rejected the live connection. The library will reconnect.")
        }
        let recognized = ["AssetUploadReadyV2", "AssetEditReadyV2", "on_upload_success", "on_asset_update", "on_asset_delete", "on_asset_trash", "on_asset_restore", "on_asset_hidden", "on_asset_stack_update", "on_album_update", "on_person_thumbnail", "on_config_update", "on_user_delete", "on_session_delete", "AppRestartV1"]
        guard recognized.contains(name) else { return .ignore }
        var result = ServerInvalidation(configurationChanged: ["on_config_update", "AppRestartV1", "on_session_delete"].contains(name))
        let arguments = Array(values.dropFirst())
        if let body = arguments.first {
            // These carry the asset, with its media revision: AssetUploadReadyV2 and AssetEditReadyV2
            // inside "asset", on_asset_update and on_upload_success as the whole argument.
            let asset = name.hasPrefix("Asset") ? body.object?["asset"]?.object
                : (name == "on_asset_update" || name == "on_upload_success") ? body.object : nil
            if let asset, let id = asset["id"]?.string {
                result.assetIDs.insert(id)
                if let revision = asset["mediaRevision"]?.string { result.mediaRevisions[id] = revision }
            } else if ["on_asset_delete", "on_asset_hidden"].contains(name), let id = body.string {
                result.assetIDs.insert(id)
            } else if ["on_asset_trash", "on_asset_restore", "on_asset_stack_update"].contains(name) {
                // Trash and restore send one array; a stack update spreads its IDs as arguments.
                for argument in arguments {
                    if case .array(let ids) = argument { result.assetIDs.formUnion(ids.compactMap(\.string)) }
                    else if let id = argument.string { result.assetIDs.insert(id) }
                }
            }
        }
        return .invalidation(result)
    }
}

/// The live connection's hints that nobody has read yet, merged into one, so a reader that falls
/// behind loses none of them. The connection's end, or its failure, comes after the last hint.
final class ServerHintMailbox: Sendable {
    private struct State {
        var pending: ServerInvalidation?
        var end: Result<Void, any Error>?
        var reader: CheckedContinuation<ServerInvalidation?, any Error>?
    }
    private let state = Mutex(State())

    func post(_ hint: ServerInvalidation) {
        let reader = state.withLock { state -> CheckedContinuation<ServerInvalidation?, any Error>? in
            guard state.end == nil else { return nil }
            if let reader = state.reader {
                state.reader = nil
                return reader
            }
            if state.pending == nil { state.pending = hint } else { state.pending?.merge(hint) }
            return nil
        }
        reader?.resume(returning: hint)
    }

    /// The connection ended, with `error` if it failed. Hints still waiting are read first.
    func finish(throwing error: (any Error)? = nil) {
        let reader = state.withLock { state -> CheckedContinuation<ServerInvalidation?, any Error>? in
            guard state.end == nil else { return nil }
            state.end = error.map { .failure($0) } ?? .success(())
            guard state.pending == nil else { return nil }
            defer { state.reader = nil }
            return state.reader
        }
        guard let reader else { return }
        if let error { reader.resume(throwing: error) } else { reader.resume(returning: nil) }
    }

    /// The hints that arrived since the last read, merged, waiting for one if there are none. Nil
    /// once the connection has ended.
    func next() async throws -> ServerInvalidation? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ServerInvalidation?, any Error>) in
                let now = state.withLock { state -> Result<ServerInvalidation?, any Error>? in
                    if let pending = state.pending {
                        state.pending = nil
                        return .success(pending)
                    }
                    if let end = state.end { return end.map { _ -> ServerInvalidation? in nil } }
                    if Task.isCancelled { return .failure(CancellationError()) }
                    state.reader = continuation
                    return nil
                }
                if let now { continuation.resume(with: now) }
            }
        } onCancel: {
            let reader = state.withLock { state -> CheckedContinuation<ServerInvalidation?, any Error>? in
                defer { state.reader = nil }
                return state.reader
            }
            reader?.resume(throwing: CancellationError())
        }
    }
}

/// When a pass posts the acknowledgements it has committed: once `interval` has passed since it
/// last posted, once `events` events arrived since, and at the end of the stream. Until then they
/// wait in the index, committed with their data, and the next pass replays any that never went.
struct AckPolicy: Sendable {
    var interval: Duration = .seconds(1)
    var events = 2_000
}

/// One sync pass: the server's stream into the offline index, a batch at a time, each batch
/// committed together with its acknowledgements. In the app only SyncEngine runs passes, one at a
/// time, and it decides when; tests also run them directly.
struct NativeSync: Sendable {
    let store: LibraryIndex
    private let api: APIClient
    private let acks: AckPolicy

    init(api: APIClient, store: LibraryIndex, acks: AckPolicy = AckPolicy()) {
        self.api = api
        self.store = store
        self.acks = acks
    }

    /// Runs one pass and returns what it changed. `committed` hears each batch's change as soon as
    /// it is in the index, so a pass that fails later still says what it changed. A reset the server
    /// asks for is followed at once, at most twice.
    func pass(committed: @escaping @Sendable (IndexChange) async -> Void = { _ in }) async throws -> IndexChange {
        let fingerprint = try await api.syncSessionFingerprint()
        try Task.checkCancellation()
        var reset = try await store.prepare(sessionFingerprint: fingerprint)
        let storeEpoch = await store.epoch()
        var result = IndexChange()
        if reset {
            // Emptied for a new session, or its first sync never finished: the index fills from scratch.
            result.localReset = true
            result.revision = await store.revision
            await committed(result)
        }
        var resets = 0
        while true {
            try Task.checkCancellation()
            // Replay acknowledgements after a crash between the durable commit and
            // its HTTP response. Replaying the same ack is explicitly idempotent.
            try await flushAcknowledgements()
            let progress = StreamProgress(policy: acks)
            let requestedReset = reset
            try await api.consumeSyncStream(reset: reset) { [store, api] events in
                // Receiving a batch proves the reset reached the server. Persist
                // that fact before applying data so interrupted initial sync resumes.
                if requestedReset { try await store.markResetRequested() }
                let change = try await store.apply(events, epoch: storeEpoch)
                await committed(change)
                let terminal = events.last.map { ["SyncCompleteV1", "SyncResetV1"].contains($0.type) } ?? false
                guard await progress.record(change, events: events.count, terminal: terminal) else { return }
                let pending = try await store.pendingAcknowledgements()
                if !pending.isEmpty {
                    try await api.acknowledgeSync(pending)
                    try await store.acknowledged(pending)
                }
                await progress.posted()
            }
            try Task.checkCancellation()
            let change = await progress.change
            result.merge(change)
            reset = false
            guard change.serverReset else { return result }
            resets += 1
            guard resets <= 2 else { throw APIError.invalidResponse("The server repeatedly requested a fresh library sync. Try again after the server finishes restarting.") }
        }
    }

    private func flushAcknowledgements() async throws {
        let pending = try await store.pendingAcknowledgements()
        if !pending.isEmpty { try await api.acknowledgeSync(pending); try await store.acknowledged(pending) }
    }
}

/// One stream's progress: what its batches changed, and when it last posted acknowledgements.
private actor StreamProgress {
    private(set) var change = IndexChange()
    private let policy: AckPolicy
    private var eventsSincePost = 0
    private var lastPost = ContinuousClock.now

    init(policy: AckPolicy) { self.policy = policy }

    /// Records a committed batch, and says whether the acknowledgements go now.
    func record(_ batch: IndexChange, events: Int, terminal: Bool) -> Bool {
        change.merge(batch)
        eventsSincePost += events
        return terminal || eventsSincePost >= policy.events || ContinuousClock.now - lastPost >= policy.interval
    }

    func posted() {
        eventsSincePost = 0
        lastPost = .now
    }
}
