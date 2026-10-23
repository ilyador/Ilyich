import Foundation
import IlyichPlatform
import Synchronization

/// What a library mutation did, in the order every screen showing photos hears it
/// (REBUILD_ROADMAP.md N2).
enum MutationEvent: Sendable {
    /// The server answered: what succeeded, what failed and why, and the photos as the change left
    /// them. Screens apply it in place.
    case applied(MutationResult)
    /// The sync pass asked for afterwards has run, and its change is merged into the result: nil
    /// when the account has no offline library to sync, or when the pass failed.
    case followedUp(MutationResult)

    var result: MutationResult {
        switch self { case .applied(let result), .followedUp(let result): result }
    }
}

/// A mutation the service runs. The screen that started it may wait for the server's answer or
/// go: the service finishes the mutation either way and publishes its result.
struct MutationHandle: Sendable {
    let operation: OperationID
    let request: MutationRequest
    fileprivate let answer: Task<MutationResult, any Error>

    /// The server's answer, already applied to media and published, or the error that kept the
    /// change from being made. Waiting for it neither keeps the mutation running nor stops it.
    var result: MutationResult {
        get async throws { try await answer.value }
    }
}

/// Why the service made no change at all.
enum MutationError: LocalizedError, Equatable {
    /// None of the photos the request names may be changed this way; the reason says why.
    case notAllowed(String)
    /// The account closed before the change was sent.
    case closed

    var errorDescription: String? {
        switch self {
        case .notAllowed(let reason): reason
        case .closed: APIError.signedOut.localizedDescription
        }
    }
}

/// One account's changes to its library on the server (REBUILD_ROADMAP.md N2). A screen starts a
/// request and gets a handle; the work belongs to the service, so it ends the same whether the
/// screen waits, closes or is gone. Each request is refused in read-only mode and for photos the
/// account may not change that way, makes one HTTP call, reads what a bulk call says of each
/// photo, invalidates exactly the media the change makes stale, publishes the result, and then
/// asks the account's sync for a pass and publishes the result again with that pass's change
/// merged in. AccountRuntime owns it and shuts it down first at sign-out.
actor LibraryMutationService {
    /// How a saved edit's new preview is waited for: the server renders it after the edit is saved.
    struct EditPolling: Sendable {
        var interval: Duration = .milliseconds(500)
        var attempts = 20
    }

    /// Whether a sync pass follows every mutation. Its change reaches the feeds as every pass's
    /// does, so a feed reads its months again itself only when none follows.
    nonisolated let followsUp: Bool

    private let client: APIClient
    private let pipeline: MediaPipeline?
    private let authorization: AuthorizationState?
    private let refresh: (@Sendable () async throws -> LibraryChange?)?
    private let polling: EditPolling
    private nonisolated let state = Mutex(State())

    private struct State {
        var open = true
        /// Every mutation until its follow-up has been published.
        var running: [UUID: Running] = [:]
        var subscribers: [UUID: AsyncStream<MutationEvent>.Continuation] = [:]
    }

    private struct Running {
        let answer: Task<MutationResult, any Error>
        let followUp: Task<Void, Never>
    }

    /// `refresh` runs a sync pass that starts after it is called and returns what it changed: the
    /// account's SyncEngine, or nil where nothing syncs. `authorization` says whether read-only
    /// mode is on; without it, the client's account flag does.
    init(client: APIClient, pipeline: MediaPipeline?, authorization: AuthorizationState?,
         refresh: (@Sendable () async throws -> LibraryChange?)?, polling: EditPolling = EditPolling()) {
        self.client = client
        self.pipeline = pipeline
        self.authorization = authorization
        self.refresh = refresh
        self.polling = polling
        followsUp = refresh != nil
    }

    // MARK: Commands

    /// Starts `request`. `records` are the screen's own records of the photos it names: they say
    /// whose each photo is, and what a bulk change the server answers with nothing leaves of it.
    /// A photo without a record is left to the server to allow. Requests that name no photo,
    /// such as emptying the Trash, take the photos the screen shows as those they change.
    nonisolated func start(_ request: MutationRequest, on records: [Asset] = []) -> MutationHandle {
        let operation = OperationID(), key = UUID()
        let answer = state.withLock { state -> Task<MutationResult, any Error> in
            let answer = Task { try await self.perform(operation, request, records: records) }
            let followUp = Task { await self.followUp(after: answer, key: key) }
            if state.open {
                state.running[key] = Running(answer: answer, followUp: followUp)
            } else {
                answer.cancel(); followUp.cancel()
            }
            return answer
        }
        return MutationHandle(operation: operation, request: request, answer: answer)
    }

    /// Every result from now on, until the account closes, in the order the service publishes
    /// them: each mutation's `applied` comes before its `followedUp`.
    nonisolated func events() -> AsyncStream<MutationEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: MutationEvent.self)
        let id = UUID()
        continuation.onTermination = { [weak self] _ in self?.unsubscribe(id) }
        let subscribed = state.withLock { state -> Bool in
            guard state.open else { return false }
            state.subscribers[id] = continuation
            return true
        }
        if !subscribed { continuation.finish() }
        return stream
    }

    /// Sign-out: nothing begun here changes anything any more. Mutations still running are
    /// cancelled and waited for, and every subscriber's stream ends.
    func shutdown() async {
        let (running, subscribers) = state.withLock { state -> ([Running], [AsyncStream<MutationEvent>.Continuation]) in
            state.open = false
            defer { state.running = [:]; state.subscribers = [:] }
            return (Array(state.running.values), Array(state.subscribers.values))
        }
        for work in running { work.answer.cancel(); work.followUp.cancel() }
        for work in running { await work.followUp.value }
        for subscriber in subscribers { subscriber.finish() }
    }

    /// How many mutations are running, their follow-ups included.
    nonisolated var runningCount: Int { state.withLock { $0.running.count } }

    // MARK: A mutation

    private nonisolated var isOpen: Bool { state.withLock { $0.open } }

    private func perform(_ operation: OperationID, _ request: MutationRequest, records: [Asset]) async throws -> MutationResult {
        guard isOpen else { throw MutationError.closed }
        try Task.checkCancellation()
        // Read-only mode refuses a change before it is sent; the transport refuses it again should
        // read-only mode come on while it waits to be sent.
        if authorization?.snapshot.readOnly ?? client.isReadOnly { throw ReadOnlyPolicy.ReadOnlyError() }
        let plan = try MutationPlan(request, records: records, userID: client.userID)
        let result = try await send(plan, operation: operation)
        await invalidateMedia(for: result, plan: plan)
        publish(.applied(result))
        return result
    }

    /// One HTTP call, read for what it says of each photo.
    private func send(_ plan: MutationPlan, operation: OperationID) async throws -> MutationResult {
        var outcome = Outcome(plan: plan)
        switch plan.request {
        case .favorite(let ids, let value):
            if ids.count == 1, let id = ids.first {
                outcome.succeed(ids, fresh: [try await client.updateFavorite(assetID: id, value: value)])
            } else {
                try await client.updateAssets(AssetBulkUpdate(ids: ids, isFavorite: value))
                outcome.succeed(ids)
            }
        case .visibility(let ids, let visibility):
            // The bulk endpoint, as Immich's own apps use: locking there also takes the photo out
            // of every album.
            try await client.updateAssets(AssetBulkUpdate(ids: ids, visibility: visibility))
            outcome.succeed(ids)
        case .trash(let ids):
            try await client.trashAssets(ids: ids, permanently: false)
            outcome.succeed(ids)
        case .deletePermanently(let ids):
            try await client.trashAssets(ids: ids, permanently: true)
            outcome.succeed(ids)
        case .restore(let ids):
            outcome.affected = try await client.restoreAssets(ids: ids).count
            outcome.succeed(ids)
        case .restoreAllTrash:
            outcome.affected = try await client.restoreTrash().count
            outcome.succeed(plan.known)
        case .emptyTrash:
            outcome.affected = try await client.emptyTrash().count
            outcome.succeed(plan.known)
        case .addToAlbum(let album, let ids):
            // A photo already in the album counts as added.
            outcome.read(try await client.addToAlbum(id: album, assetIDs: ids), accepting: ["duplicate"])
        case .removeFromAlbum(let album, let ids):
            outcome.read(try await client.removeFromAlbum(id: album, assetIDs: ids))
        case .setAlbumCover(let album, let asset):
            outcome.album = try await client.setAlbumCover(id: album, assetID: asset)
            outcome.succeed([asset])
        case .createAlbum(let name, let ids):
            outcome.album = try await client.createAlbum(name: name, assetIDs: ids)
            outcome.succeed(ids)
        case .stack(let ids):
            _ = try await client.createStack(assetIDs: ids)
            outcome.succeed(ids)
        case .unstack(let stack):
            try await client.deleteStack(id: stack)
            outcome.succeed(plan.known)
        case .removeFromStack(let stack, let ids):
            // The server takes a stack's photos out one at a time.
            for id in ids {
                try Task.checkCancellation()
                try await client.removeFromStack(id: stack, assetID: id)
                outcome.succeed([id])
            }
        case .setStackCover(let stack, let asset):
            _ = try await client.setStackCover(id: stack, assetID: asset)
            outcome.succeed([asset])
        case .update(let id, let fields):
            let update = AssetUpdate(description: fields.description, dateTimeOriginal: fields.dateTimeOriginal,
                                     latitude: fields.latitude, longitude: fields.longitude)
            outcome.succeed([id], fresh: [try await client.updateAsset(id: id, update: update)])
        case .rating(let ids, let rating):
            if ids.count == 1, let id = ids.first {
                outcome.succeed(ids, fresh: [try await client.updateRating(id: id, rating: rating)])
            } else {
                guard let rating else { throw MutationError.notAllowed("Clear the rating one photo at a time.") }
                try await client.updateAssets(AssetBulkUpdate(ids: ids, rating: rating))
                outcome.succeed(ids)
            }
        case .tag(let ids, let tags):
            _ = try await client.tagAssets(ids: ids, tagIDs: tags)
            outcome.succeed(ids)
        case .reassignFace(let face, let person):
            _ = try await client.reassignFace(face, to: person)
        case .removeFace(let face):
            try await client.removeFace(face)
        case .edits(let id, let edits):
            if edits.isEmpty { try await client.removeEdits(id: id) } else { _ = try await client.saveEdits(id: id, edits: edits) }
            outcome.succeed([id], fresh: [await waitForNewPreview(of: id, before: plan.records[id])].compactMap { $0 })
        case .resolveDuplicate(let group, let keep, let trash):
            // Without a Trash the server deletes the others for good, which this never asks for.
            guard try await client.serverFeatures().trash else {
                throw APIError.invalidResponse("Trash is turned off on this server. No photos were removed.")
            }
            let results = try await client.resolveDuplicates([DuplicateResolution(duplicateId: group, keepAssetIds: keep, trashAssetIds: trash)])
            guard let answer = results.first(where: { $0.id == group }) ?? results.first, answer.success else {
                throw APIError.invalidResponse(results.first?.errorMessage ?? "Some items could not be moved. Refresh this collection and try again.")
            }
            outcome.succeed(trash)
        case .dismissDuplicate(let group):
            try await client.dismissDuplicate(id: group)
        }
        return outcome.result(operation: operation)
    }

    /// The server renders an edited photo's previews after the edit is saved: its record is read
    /// until its media revision moves, which proves the new preview exists. A read that fails ends
    /// the wait, since the edit itself was saved. Nil when no record could be read.
    private func waitForNewPreview(of id: String, before: Asset?) async -> Asset? {
        var latest = before
        for attempt in 0..<max(1, polling.attempts) {
            if attempt > 0 {
                do { try await Task.sleep(for: polling.interval) } catch { break }
            }
            guard let asset = try? await client.asset(id: id) else { break }
            latest = asset
            guard let before, asset.cacheRevision == before.cacheRevision else { break }
        }
        return latest
    }

    /// Only what the change makes stale: a locked photo's media, everywhere and at once; a photo
    /// deleted for good loses its files; an edited photo's old revision leaves. Photos put in
    /// Trash, restored, resolved as duplicates or changed otherwise keep their thumbnails, so the
    /// offline library needs nothing downloaded again.
    private func invalidateMedia(for result: MutationResult, plan: MutationPlan) async {
        guard let pipeline, !result.succeeded.isEmpty else { return }
        switch result.request {
        case .visibility(_, .locked):
            await pipeline.forget(assetIDs: Set(result.succeeded), revoked: true)
        case .deletePermanently, .emptyTrash:
            await pipeline.forget(assetIDs: Set(result.succeeded))
        case .edits(let id, _):
            guard let edited = result.fresh[id], let before = plan.records[id], edited.cacheRevision != before.cacheRevision else { return }
            let account = authorization?.account ?? AccountID(server: client.baseURL, userID: client.userID ?? "")
            var change = LibraryChange(account: account, authorization: authorization?.snapshot.epoch ?? AuthorizationEpoch(account: account, value: 0),
                                       indexRevision: 0, origin: .mutation(result.operation))
            change.mediaRevisions = [id: edited.cacheRevision]
            await pipeline.apply(change)
        default:
            break
        }
    }

    /// Asks the account's sync for a pass once the server has answered, and publishes the result
    /// again with that pass's change. A mutation the server refused has nothing to follow.
    private nonisolated func followUp(after answer: Task<MutationResult, any Error>, key: UUID) async {
        defer { _ = state.withLock { $0.running.removeValue(forKey: key) } }
        guard var result = try? await answer.value, !Task.isCancelled else { return }
        if let refresh { result.followUp = try? await refresh() }
        guard !Task.isCancelled else { return }
        publish(.followedUp(result))
    }

    // MARK: Subscribers

    /// Every subscriber hears every event in one order: they are handed over under the lock.
    private nonisolated func publish(_ event: MutationEvent) {
        state.withLock { state in
            guard state.open else { return }
            for subscriber in state.subscribers.values { subscriber.yield(event) }
        }
    }

    private nonisolated func unsubscribe(_ id: UUID) {
        _ = state.withLock { $0.subscribers.removeValue(forKey: id) }
    }
}

/// What a request may send once ownership has had its say: the photos the account may change this
/// way, and why each of the others was refused.
struct MutationPlan: Sendable {
    /// What the screen asked for.
    let original: MutationRequest
    /// What is sent: the original, narrowed to the photos allowed.
    let request: MutationRequest
    let refused: [String: String]
    /// The screen's records, by ID.
    let records: [String: Asset]
    /// The photos the screen named or showed, in its order: those a request naming no photo changes.
    let known: [String]

    static let ownersOnly = "Only its owner can change this photo."
    static let notInLockedFolder = "Photos in the Locked Folder can’t be added to albums."

    /// What the account may do with each photo: change the details of its own photos, and put any
    /// photo but a locked one in an album. Photos without a record are left to the server. Bulk
    /// requests send the photos allowed; a request that must change all of them, or names one,
    /// is refused whole.
    init(_ request: MutationRequest, records: [Asset], userID: String?) throws(MutationError) {
        var byID: [String: Asset] = [:], order: [String] = []
        for record in records where byID[record.id] == nil {
            byID[record.id] = record
            order.append(record.id)
        }
        let named = request.assetIDs
        original = request
        self.records = byID
        known = named.isEmpty ? order : named
        let checked: [String], reason: String, disallows: (Asset) -> Bool
        switch request.requirement {
        case .none:
            (checked, reason, disallows) = ([], "", { _ in false })
        case .owner(let ids):
            // Someone else's photo, as far as its record and the account say.
            (checked, reason, disallows) = (ids, Self.ownersOnly, { record in
                guard let userID, let owner = record.ownerId else { return false }
                return owner != userID
            })
        case .notLocked(let ids):
            (checked, reason, disallows) = (ids, Self.notInLockedFolder, { $0.visibility == .locked })
        }
        let disallowed = Set(checked.filter { id in byID[id].map(disallows) ?? false })
        guard !disallowed.isEmpty else {
            refused = [:]
            self.request = request
            return
        }
        let allowed = named.filter { !disallowed.contains($0) }
        guard request.isBulk, !allowed.isEmpty else { throw .notAllowed(reason) }
        refused = Dictionary(disallowed.map { ($0, reason) }, uniquingKeysWith: { first, _ in first })
        self.request = request.narrowed(to: allowed)
    }
}

/// The photos a call changed, as it is being read.
private struct Outcome {
    let plan: MutationPlan
    var succeeded: [String] = []
    var failed: [String: String] = [:]
    var fresh: [String: Asset] = [:]
    var album: Album?
    var affected: Int?

    init(plan: MutationPlan) { self.plan = plan }

    /// `ids` changed. `records` are the server's own after the change; any other photo with a
    /// record from the screen keeps it, changed as the server changed it.
    mutating func succeed(_ ids: [String], fresh records: [Asset] = []) {
        succeeded += ids
        for record in records { fresh[record.id] = record }
        for id in ids where fresh[id] == nil {
            if let record = plan.records[id], let changed = plan.original.applied(to: record) { fresh[id] = changed }
        }
    }

    /// A bulk answer: each photo succeeded or failed with the server's reason.
    mutating func read(_ results: [BulkResult], accepting: Set<String> = []) {
        let answered = Dictionary(results.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changed: [String] = []
        for id in plan.request.assetIDs {
            guard let answer = answered[id] else { failed[id] = "The server didn’t say whether this photo changed."; continue }
            if answer.success || answer.error.map(accepting.contains) == true { changed.append(id) }
            else { failed[id] = answer.errorMessage ?? answer.error ?? "unknown" }
        }
        succeed(changed)
    }

    func result(operation: OperationID) -> MutationResult {
        MutationResult(operation: operation, request: plan.original, succeeded: succeeded, failed: plan.refused.merging(failed) { refused, _ in refused },
                       fresh: fresh, followUp: nil, album: album, affected: affected)
    }
}

extension MutationRequest {
    /// Whose say a request needs, for which of the photos it names.
    fileprivate enum Requirement {
        case none
        /// Only the photo's owner may change it this way.
        case owner([String])
        /// A locked photo may not go in an album.
        case notLocked([String])
    }

    fileprivate var requirement: Requirement {
        switch self {
        case .favorite(let ids, _), .visibility(let ids, _), .trash(let ids), .deletePermanently(let ids), .restore(let ids),
             .rating(let ids, _), .tag(let ids, _), .stack(let ids), .removeFromStack(_, let ids):
            .owner(ids)
        case .setStackCover(_, let id), .update(let id, _), .edits(let id, _): .owner([id])
        case .resolveDuplicate(_, _, let trash): .owner(trash)
        case .addToAlbum(_, let ids), .removeFromAlbum(_, let ids), .createAlbum(_, let ids): .notLocked(ids)
        case .setAlbumCover(_, let id): .notLocked([id])
        case .restoreAllTrash, .emptyTrash, .unstack, .reassignFace, .removeFace, .dismissDuplicate: .none
        }
    }

    /// Whether the server changes each photo of the request on its own, so the others may go
    /// when some are refused.
    fileprivate var isBulk: Bool {
        switch self {
        case .favorite, .visibility, .trash, .deletePermanently, .restore, .rating, .tag, .addToAlbum, .removeFromAlbum: true
        default: false
        }
    }

    /// The request for only `ids`.
    fileprivate func narrowed(to ids: [String]) -> MutationRequest {
        switch self {
        case .favorite(_, let value): .favorite(ids, value)
        case .visibility(_, let visibility): .visibility(ids, visibility)
        case .trash: .trash(ids)
        case .deletePermanently: .deletePermanently(ids)
        case .restore: .restore(ids)
        case .rating(_, let rating): .rating(ids, rating)
        case .tag(_, let tags): .tag(ids, tags: tags)
        case .addToAlbum(let album, _): .addToAlbum(album: album, assets: ids)
        case .removeFromAlbum(let album, _): .removeFromAlbum(album: album, assets: ids)
        default: self
        }
    }
}

/// The fields one call changes for many photos; nil leaves a field as it is.
struct AssetBulkUpdate: Encodable, Sendable {
    let ids: [String]
    var isFavorite: Bool?
    var visibility: AssetVisibility?
    var rating: Int?
}

/// One duplicate group resolved: the photos kept and those put in Trash.
struct DuplicateResolution: Encodable, Sendable {
    let duplicateId: String
    let keepAssetIds: [String]
    let trashAssetIds: [String]
}
