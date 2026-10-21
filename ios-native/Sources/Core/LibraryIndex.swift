import CryptoKit
import Foundation
import os
import Synchronization

/// Until Q5 the library index keeps the offline library's old name and method surface.
typealias EntityStore = LibraryIndex

/// The offline library (architecture section 1, LibraryIndex): durable server entities, their
/// checkpoint journal, and the tables derived from them, in one file per account scope.
///
/// - IndexWriter, on queue ilyich.index.writer at utility priority, owns the only read-write
///   connection. It commits each sync batch with its acknowledgements and derived rows.
/// - IndexReader `viewport` (user-initiated) and `aggregate` (utility) each own a read-only
///   connection, so reading never waits for a batch being written.
/// - The backfill fills the derived tables of a library synced before they existed, in batches
///   with a cursor that survives a kill. Until it finishes the index is not queryable, and the
///   feeds, map and offline lists come from the server (`isReadable`).
final class LibraryIndex: Sendable {
    let scope: String
    let userID: String
    let writer: IndexWriter
    let viewport: IndexReader
    let aggregate: IndexReader
    private let backfill = Mutex(Backfill())
    private struct Backfill {
        var task: Task<Void, Never>?
        /// Whether the app started the backfill and has not stopped it, so a restart runs it again.
        var enabled = false
        /// A restart came while a pass was running; it makes one more pass before ending.
        var rerun = false
        var pause: Duration = .milliseconds(15)
    }
    private static let log = Logger(subsystem: PerfSignpost.subsystem, category: PerfSignpost.Category.index)

    init(scope: String, userID: String, directory: URL? = nil, backfillBatchSize: Int = 5_000) throws {
        self.scope = scope; self.userID = userID
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("IlyichEntities", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var protectedRoot = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protectedRoot.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
        #endif
        let name = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        let url = root.appendingPathComponent(name + ".sqlite")
        writer = try IndexWriter(url: url, userID: userID, backfillBatchSize: backfillBatchSize)
        viewport = IndexReader(path: url.path, userID: userID, label: "ilyich.index.viewport", qos: .userInitiated)
        aggregate = IndexReader(path: url.path, userID: userID, label: "ilyich.index.aggregate", qos: .utility)
    }

    deinit { backfill.withLock { $0.task?.cancel() } }

    // MARK: Backfill

    /// Starts filling the derived tables, once, if they are not complete: after `delay`, at
    /// utility priority, a batch at a time with a pause between batches so sync and reading go on.
    /// A kill resumes from the last batch committed.
    func startBackfill(after delay: Duration = .seconds(2), pause: Duration = .milliseconds(15)) {
        backfill.withLock { state in
            guard state.task == nil else { return }
            state.enabled = true; state.pause = pause
            state.task = makeBackfillTask(after: delay, pause: pause)
        }
    }

    /// Stops the backfill and waits for the batch under way to commit or roll back.
    func stopBackfill() async {
        let task = backfill.withLock { state in
            defer { state.task = nil; state.enabled = false; state.rerun = false }
            return state.task
        }
        task?.cancel()
        await task?.value
    }

    /// Waits for a backfill started earlier to end, for tests.
    func backfillFinished() async { await backfill.withLock { $0.task }?.value }

    /// A pass, again while a restart asked for one during it. The task clears itself when it ends.
    private func makeBackfillTask(after delay: Duration, pause: Duration) -> Task<Void, Never> {
        Task(priority: .utility) { [weak self, writer] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            repeat { await Self.runBackfill(writer, pause: pause) } while !Task.isCancelled && self?.backfillPassEnded() == true
        }
    }

    private func backfillPassEnded() -> Bool {
        backfill.withLock { state in
            if state.rerun { state.rerun = false; return true }
            state.task = nil
            return false
        }
    }

    /// A sync batch whose derived rows failed restarted the backfill: run it again this session,
    /// if the app runs it at all, rather than leave the index unqueryable until the next launch.
    private func resumeBackfillIfRestarted() {
        guard writer.backfillRestarted.exchange(false, ordering: .acquiringAndReleasing) else { return }
        backfill.withLock { state in
            guard state.enabled else { return }
            if state.task != nil { state.rerun = true } else { state.task = makeBackfillTask(after: .zero, pause: state.pause) }
        }
    }

    private static func runBackfill(_ writer: IndexWriter, pause: Duration) async {
        guard let state = try? await writer.backfillState(), state.kind != nil else { return }
        let signposter = PerfSignpost.index
        let interval = signposter.isEnabled ? signposter.beginInterval(PerfSignpost.indexBackfill, id: signposter.makeSignpostID()) : nil
        let clock = ContinuousClock(), start = clock.now
        var batches = 0
        var outcome = "completed"
        do {
            while try await writer.backfillStep() {
                batches += 1
                try await Task.sleep(for: pause)
            }
            batches += 1
        } catch {
            outcome = error is CancellationError ? "cancelled" : "failed"
        }
        let elapsed = clock.now - start
        if let interval { signposter.endInterval(PerfSignpost.indexBackfill, interval, "outcome=\(outcome, privacy: .public) batches=\(batches)") }
        log.notice("index.backfill \(outcome, privacy: .public) after \(batches) batches in \(elapsed.formatted(.units(allowed: [.seconds, .milliseconds])), privacy: .public), resumed=\(state.kind != LibraryIndexSchema.backfillKinds[0] || state.cursor != nil)")
    }

    // MARK: Writer

    func epoch() async -> UUID { await writer.epoch() }
    var revision: UInt64 { get async { await writer.revision } }
    func isQueryable() async throws -> Bool { try await mapped { try await writer.isQueryable() } }
    func persistCachedServerFeatures(_ features: ServerFeatures) async throws { try await mapped { try await writer.persistCachedServerFeatures(features) } }
    func cachedServerFeatures() async throws -> ServerFeatures? { try await mapped { try await writer.cachedServerFeatures() } }
    func takeAccessInvalidation() async throws -> Bool { try await mapped { try await writer.takeAccessInvalidation() } }
    func pendingMediaPurges(limit: Int = 5_000) async throws -> [MediaPurge] { try await mapped { try await writer.pendingMediaPurges(limit: limit) } }
    func finishMediaPurges(_ purges: [MediaPurge]) async throws { try await mapped { try await writer.finishMediaPurges(purges) } }
    func prepare(sessionFingerprint: String) async throws -> Bool { try await mapped { try await writer.prepare(sessionFingerprint: sessionFingerprint) } }
    func markResetRequested() async throws { try await mapped { try await writer.markResetRequested() } }
    func pendingAcknowledgements() async throws -> [String] { try await mapped { try await writer.pendingAcknowledgements() } }
    func acknowledged(_ acks: [String]) async throws { try await mapped { try await writer.acknowledged(acks) } }
    func clear() async throws { try await mapped { try await writer.clear() } }
    func apply(_ events: [EntitySyncEvent], epoch: UUID) async throws -> IndexChange {
        defer { resumeBackfillIfRestarted() }
        return try await mapped { try await writer.apply(events, epoch: epoch) }
    }
    func mediaRevisions(of ids: [String]) async throws -> [String: String] { try await mapped { try await writer.mediaRevisions(of: ids) } }
    func dueRepairs(limit: Int, now: Date = Date()) async throws -> [String] { try await mapped { try await writer.dueRepairs(limit: limit, now: now) } }
    func applyRepair(assetID: String, _ events: [EntitySyncEvent]) async throws -> IndexChange {
        defer { resumeBackfillIfRestarted() }
        return try await mapped { try await writer.applyRepair(assetID: assetID, events) }
    }
    func beginRepair(assetID: String) async throws { try await mapped { await writer.beginRepair(assetID: assetID) } }
    func failRepair(assetID: String, retryAt: Date?) async throws { try await mapped { try await writer.failRepair(assetID: assetID, retryAt: retryAt) } }

    // MARK: Viewport reads

    /// Read on the viewport's connection, not the writer's, since every month the feed loads asks
    /// first: it never queues behind a backfill batch or a sync batch.
    func isComplete() async throws -> Bool { try await mapped { try await viewport.isComplete() } }
    /// Whether feeds, map markers, albums and the other lists can be read from the index: the
    /// first sync is complete and the derived tables hold every entity.
    func isReadable() async throws -> Bool { try await mapped { try await viewport.isReadable() } }
    func lastSyncDate() async throws -> Date? { try await mapped { try await viewport.lastSyncDate() } }

    func entityData(kind: String, id: String) async throws -> Data? { try await mapped { try await viewport.entityData(kind: kind, id: id) } }
    func asset(id: String) async throws -> Asset? { try await mapped { try await viewport.asset(id: id) } }
    func timelineAssets(filter: TimelineFilter = .init(), offset: Int = 0, limit: Int = 200) async throws -> [Asset] {
        try await mapped { try await viewport.timelineAssets(filter: filter, offset: offset, limit: limit) }
    }
    func timeBuckets(filter: TimelineFilter = .init()) async throws -> [TimeBucket] { try await mapped { try await viewport.timeBuckets(filter: filter) } }
    /// One month of a feed, in the server's order.
    func timeBucket(_ bucket: String, filter: TimelineFilter = .init()) async throws -> [Asset] {
        try await mapped { try await viewport.timeBucket(bucket, filter: filter) }
    }
    /// What SQLite plans for a month's query, for tests and diagnostics.
    func timeBucketPlan(_ bucket: String, filter: TimelineFilter = .init()) async throws -> [String] {
        try await mapped { try await viewport.timeBucketPlan(bucket, filter: filter) }
    }
    func album(id: String) async throws -> Album? { try await mapped { try await viewport.album(id: id) } }
    func person(id: String) async throws -> Person? { try await mapped { try await viewport.person(id: id) } }
    func assetOCR(id: String) async throws -> [RecognizedText] { try await mapped { try await viewport.assetOCR(id: id) } }

    // MARK: Aggregate reads

    func statistics() async throws -> EntityStoreStatistics { try await mapped { try await aggregate.statistics() } }
    func entityData(kind: String, offset: Int = 0, limit: Int = 200) async throws -> [Data] {
        try await mapped { try await aggregate.entityData(kind: kind, offset: offset, limit: limit) }
    }
    func memories(onCivilDate day: String) async throws -> [Memory] { try await mapped { try await aggregate.memories(onCivilDate: day) } }
    /// Located photos per month and place, for naming months and marking trips on the time rail.
    func monthPlaces(filter: TimelineFilter = .init()) async throws -> [MonthPlaceCount] { try await mapped { try await aggregate.monthPlaces(filter: filter) } }
    func localAssetMatches(offset: Int = 0, limit: Int = 1_000) async throws -> [LocalAssetMatch] {
        try await mapped { try await aggregate.localAssetMatches(offset: offset, limit: limit) }
    }
    func albums() async throws -> [Album] { try await mapped { try await aggregate.albums() } }
    func people() async throws -> [Person] { try await mapped { try await aggregate.people() } }
    func mapMarkers(_ query: MapMarkerQuery) async throws -> [MapMarker] { try await mapped { try await aggregate.mapMarkers(query) } }
    func partners(direction: String) async throws -> [Partner] { try await mapped { try await aggregate.partners(direction: direction) } }

    /// SQLite failures read as they did before Q2: the offline library could not be saved.
    private func mapped<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch { throw IndexWriter.failure(error) }
    }
}
