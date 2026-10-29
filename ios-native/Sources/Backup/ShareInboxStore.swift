import Foundation
import Observation
import IlyichShareInbox

/// The share inbox's batches, as the library and the Shared files sheet show them. Uploading them
/// is the transfer engine's share lane (ShareInboxModel); this only reads the inbox and discards a
/// batch the user lets go.
@MainActor @Observable final class ShareInboxStore {
    static let shared = ShareInboxStore()
    /// Batches ready to upload, oldest first.
    private(set) var batches: [SharedBatch] = []
    /// Batches whose manifest or files can't be used. They stay on disk and out of the list.
    private(set) var unreadableBatches = 0
    var error: String?
    @ObservationIgnored private var loads = 0
    @ObservationIgnored private var appliedLoad = 0
    @ObservationIgnored private var inbox: ShareInboxRepository?

    init(repository: ShareInboxRepository? = nil) { inbox = repository }

    /// Reads the inbox off the main actor. Overlapping reads may finish in any order: each is
    /// applied unless a newer one already was, so `batches` never goes back in time, and when a
    /// refresh returns it holds a read made after the call (or `error` says why reading failed).
    /// Callers read `batches` straight after awaiting a refresh.
    func refresh() async {
        loads += 1
        let load = loads
        do {
            let states = try await repository().load()
            guard load > appliedLoad else { return }
            appliedLoad = load
            batches = states.compactMap(\.batch)
            unreadableBatches = states.count - batches.count
        } catch {
            guard load > appliedLoad else { return }
            self.error = "Shared files couldn’t be read: \(error.localizedDescription)"
        }
    }

    func discard(_ batch: SharedBatch) {
        Task {
            do { try await repository().remove(batch.id); await refresh() }
            catch { self.error = error.localizedDescription }
        }
    }

    private func repository() throws -> ShareInboxRepository {
        if let inbox { return inbox }
        let repository = try ShareInboxRepository.appGroup()
        inbox = repository
        return repository
    }
}

extension ShareInboxStore: SharedFilesInbox {
    var batchIDs: Set<UUID> { Set(batches.map(\.id)) }
}
