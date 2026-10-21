import Foundation

struct ServerEventConnection: Sendable {
    let events: AsyncThrowingStream<ServerInvalidation, any Error>
    let close: @Sendable () -> Void
}

struct ServerInvalidation: Sendable {
    var assetIDs: Set<String> = []
    var configurationChanged = false
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
        if packet.hasPrefix("40") { return .invalidation(.init(configurationChanged: true)) }
        guard packet.hasPrefix("42"), let values = try? JSONDecoder().decode([EntityJSON].self, from: Data(packet.dropFirst(2).utf8)), let name = values.first?.string else { return .ignore }
        if name == "error" {
            // Immich's own socket says the session is gone; the session check confirms it.
            if values.dropFirst().first?.string == "unauthorized" { throw ServerFailure.sessionExpired(nil) }
            throw APIError.invalidResponse("The server rejected the live connection. The library will reconnect.")
        }
        let recognized = ["AssetUploadReadyV2", "AssetEditReadyV2", "on_upload_success", "on_asset_update", "on_asset_delete", "on_asset_trash", "on_asset_restore", "on_asset_hidden", "on_asset_stack_update", "on_album_update", "on_person_thumbnail", "on_config_update", "on_user_delete", "on_session_delete", "AppRestartV1"]
        guard recognized.contains(name) else { return .ignore }
        var result = ServerInvalidation(configurationChanged: ["on_config_update", "AppRestartV1", "on_session_delete"].contains(name))
        if let body = values.dropFirst().first {
            if name.hasPrefix("Asset"), let id = body.object?["asset"]?.object?["id"]?.string { result.assetIDs.insert(id) }
            else if name == "on_asset_update" || name == "on_upload_success", let id = body.object?["id"]?.string { result.assetIDs.insert(id) }
            else if ["on_asset_delete", "on_asset_hidden"].contains(name), let id = body.string { result.assetIDs.insert(id) }
            else if ["on_asset_trash", "on_asset_restore", "on_asset_stack_update"].contains(name), case .array(let ids) = body { result.assetIDs.formUnion(ids.compactMap(\.string)) }
        }
        return .invalidation(result)
    }
}

actor NativeSync {
    nonisolated let store: EntityStore
    private let api: APIClient
    private var synchronization: Task<SyncChangeSummary, any Error>?
    private var eventTask: Task<Void, Never>?
    private var generation = UUID()
    private var resyncRequested = false

    init(api: APIClient, store: EntityStore) { self.api = api; self.store = store }

    /// Concurrent triggers share a stream; a trigger during that stream schedules
    /// one follow-up pass so a late server mutation cannot fall between cursors.
    func synchronize() async throws -> SyncChangeSummary {
        if let synchronization {
            resyncRequested = true
            return try await synchronization.value
        }
        let current = generation
        let task = Task { try await SyncPassProbe.measure { try await self.run(epoch: current) } }
        synchronization = task
        do {
            let value = try await task.value
            if current == generation { synchronization = nil }
            return value
        } catch {
            if current == generation { synchronization = nil }
            throw error
        }
    }

    func startEvents(onChange: @escaping @Sendable (SyncChangeSummary) async -> Void,
                     onError: @escaping @Sendable (any Error) async -> Void = { _ in }) {
        guard eventTask == nil else { return }
        let current = generation
        eventTask = Task {
            var retry: Double = 1
            while !Task.isCancelled {
                do {
                    let connection = try await api.serverEvents()
                    defer { connection.close() }
                    for try await event in connection.events {
                        try Task.checkCancellation()
                        // Bursts coalesce in the stream's single latest invalidation.
                        try await Task.sleep(for: .milliseconds(350))
                        var summary = try await synchronize()
                        summary.assetIDs.formUnion(event.assetIDs)
                        summary.changed = summary.changed || !event.assetIDs.isEmpty
                        summary.configurationChanged = event.configurationChanged
                        summary.collectionsChanged = summary.collectionsChanged || event.configurationChanged
                        try Task.checkCancellation()
                        await onChange(summary)
                        retry = 1
                    }
                } catch is CancellationError { break }
                catch {
                    guard !Task.isCancelled else { break }
                    // An expired session the session check confirms ends this loop through
                    // sign-out, which stops sync. Any other refusal is tried again: Immich's socket
                    // says unauthorized whenever its connection handler fails, for any reason.
                    await onError(error)
                }
                do { try await Task.sleep(for: .seconds(retry)) } catch { break }
                retry = min(retry * 2, 30)
            }
            if current == generation { eventTask = nil }
        }
    }
    func stop() async {
        generation = UUID()
        let events = eventTask, sync = synchronization
        eventTask = nil
        synchronization = nil
        resyncRequested = false
        events?.cancel()
        sync?.cancel()
        // An event callback can call signOut(), which calls stop() again; joining
        // the event task here would make that callback wait for itself.
        if let sync { _ = try? await sync.value }
    }
    private func run(epoch: UUID) async throws -> SyncChangeSummary {
        let fingerprint = try await api.syncSessionFingerprint()
        try Task.checkCancellation()
        guard epoch == generation else { throw CancellationError() }
        var reset = try await store.prepare(sessionFingerprint: fingerprint)
        let storeEpoch = await store.epoch()
        var result = SyncChangeSummary()
        var resets = 0
        repeat {
            resyncRequested = false
            try Task.checkCancellation()
            guard epoch == generation else { throw CancellationError() }
            // Replay acknowledgements after a crash between the durable commit and
            // its HTTP response. Replaying the same ack is explicitly idempotent.
            try await flushAcknowledgements()
            let pass = SyncPass()
            let didRequestReset = reset
            try await api.consumeSyncStream(reset: reset) { [store, api] events in
                // Receiving a batch proves the reset reached the server. Persist
                // that fact before applying data so interrupted initial sync resumes.
                if didRequestReset { try await store.markResetRequested() }
                let summary = try await store.apply(events, epoch: storeEpoch)
                await pass.merge(summary)
                let pending = try await store.pendingAcknowledgements()
                if !pending.isEmpty {
                    try await api.acknowledgeSync(pending)
                    try await store.acknowledged(pending)
                }
            }
            try Task.checkCancellation()
            let summary = await pass.summary
            result.merge(summary)
            reset = false
            if summary.reset {
                resets += 1
                guard resets <= 2 else { throw APIError.invalidResponse("The server repeatedly requested a fresh library sync. Try again after the server finishes restarting.") }
                resyncRequested = true
            }
        } while resyncRequested
        return result
    }
    private func flushAcknowledgements() async throws {
        let pending = try await store.pendingAcknowledgements()
        if !pending.isEmpty { try await api.acknowledgeSync(pending); try await store.acknowledged(pending) }
    }
}

private actor SyncPass {
    var summary = SyncChangeSummary()
    func merge(_ other: SyncChangeSummary) { summary.merge(other) }
}
