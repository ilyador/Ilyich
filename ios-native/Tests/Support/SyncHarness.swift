import Foundation
import IlyichPlatform
import Synchronization
import XCTest
@testable import Ilyich

/// A SyncEngine over a stub server and a fresh offline index, with a live connection the test
/// plays. The stub answers sync/ack, and sync/stream with only its completion marker, until the
/// test routes them otherwise.
@MainActor final class SyncHarness {
    let server: StubServer
    let api: APIClient
    let entities: EntityStore
    let engine: SyncEngine
    let status: SyncStatusBoard
    let presence: AppPresence
    let authorization: AuthorizationState
    let live: FakeLiveConnection
    /// The failures the engine took to the session check.
    let expiries: Recorded<String>
    /// Library notifications the engine posted for this account.
    let notifications: Recorded<[String: Bool]>
    let warmer: ThumbnailWarmer
    let pipeline: MediaPipeline

    fileprivate init(server: StubServer, api: APIClient, entities: EntityStore, engine: SyncEngine, status: SyncStatusBoard,
                     presence: AppPresence, authorization: AuthorizationState, live: FakeLiveConnection, expiries: Recorded<String>,
                     notifications: Recorded<[String: Bool]>, warmer: ThumbnailWarmer, pipeline: MediaPipeline) {
        self.server = server; self.api = api; self.entities = entities; self.engine = engine; self.status = status
        self.presence = presence; self.authorization = authorization; self.live = live; self.expiries = expiries
        self.notifications = notifications; self.warmer = warmer; self.pipeline = pipeline
    }

    static let completeStream = SyncEvents.stream([SyncEvents.complete()])

    /// Leaves the index as a build that had synced this session leaves it: the session's
    /// fingerprint, the first sync done and complete, every acknowledgement posted.
    func primeIndex(_ events: [EntitySyncEvent] = []) async throws {
        _ = try await entities.prepare(sessionFingerprint: api.syncSessionFingerprint())
        try await entities.markResetRequested()
        _ = try await entities.apply(events + [SyncEvents.complete(id: "primed")], epoch: entities.epoch())
        try await entities.acknowledged(entities.pendingAcknowledgements())
        _ = try await entities.takeAccessInvalidation()
        try await entities.finishMediaPurges(entities.pendingMediaPurges())
    }

    /// The sync streams the server has been asked for.
    var streamRequests: [StubServer.Request] { server.requests("POST", "sync/stream") }
}

extension XCTestCase {
    /// `connect` replaces the fake live connection; `sessionEnds` is what the session check
    /// answers about an expired session.
    @MainActor func makeSyncHarness(foreground: Bool = false, acks: AckPolicy = AckPolicy(), sessionEnds: Bool = false,
                                    debounce: Duration = .milliseconds(20),
                                    connect: (@Sendable () async throws -> ServerEventConnection)? = nil) throws -> SyncHarness {
        let server = makeStubServer()
        server.route("POST", "sync/stream", SyncHarness.completeStream)
        server.route("POST", "sync/ack", .empty(204))
        let api = try APIClient(baseURL: server.baseURL, accessToken: "harness-session", userID: "alice",
                                sessionConfiguration: server.configuration(), networkConfiguration: NetworkConfiguration())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SyncHarness-" + UUID().uuidString, isDirectory: true)
        let entities = try EntityStore(scope: api.cacheScope, userID: "alice", directory: directory)
        let account = AccountID(server: server.baseURL, userID: "alice")
        let authorization = AuthorizationState(account: account, token: "harness-session", readOnly: false, requiresPasswordChange: false, mirror: nil)
        let expiries = Recorded<String>()
        let check = SessionCheck(api: api, work: OwnedWork(), enabled: false) { error in
            expiries.append("\(error)")
            return sessionEnds
        }
        let live = FakeLiveConnection()
        let presence = AppPresence(isForeground: foreground)
        let status = SyncStatusBoard()
        let warmer = ThumbnailWarmer(session: authorization)
        let pipeline = MediaPipeline(client: api)
        let engine = SyncEngine(client: api, entities: entities, native: NativeSync(api: api, store: entities, acks: acks),
                                pipeline: pipeline, warmer: warmer, presence: presence, check: check,
                                authorization: authorization, device: FakeAccountDevice(log: AccountEventLog()), status: status,
                                connect: connect ?? { live.connect() }, debounce: debounce)
        let notifications = Recorded<[String: Bool]>()
        let scope = api.cacheScope
        let observer = NotificationCenter.default.addObserver(forName: .ilyichLibraryChanged, object: nil, queue: nil) { note in
            guard note.userInfo?["scope"] as? String == scope else { return }
            notifications.append(["collections": note.userInfo?["collections"] as? Bool ?? false,
                                  "accessChanged": note.userInfo?["accessChanged"] as? Bool ?? false])
        }
        let registration = ObserverToken(observer)
        addTeardownBlock { @MainActor in
            registration.remove()
            warmer.stop()
            await engine.shutdown()
            await pipeline.removeAll()
            await api.shutdown()
            await TimelineCache.shared.removeAll(scope: scope)
            await TimelinePlacesCache.shared.removeAll(scope: scope)
            try? FileManager.default.removeItem(at: directory)
        }
        return SyncHarness(server: server, api: api, entities: entities, engine: engine, status: status, presence: presence,
                           authorization: authorization, live: live, expiries: expiries, notifications: notifications, warmer: warmer,
                           pipeline: pipeline)
    }
}

/// Sync events as the server streams them.
enum SyncEvents {
    static func event(_ type: String, _ json: String, ack: String? = nil) -> EntitySyncEvent {
        // The JSON is the test's own and always valid.
        let data = (try? JSONDecoder().decode([String: EntityJSON].self, from: Data(json.utf8))) ?? [:]
        return EntitySyncEvent(type: type, data: data, ack: ack ?? type + "|1")
    }

    static func asset(_ id: String, owner: String = "alice", taken: String = "2026-02-01T05:00:00Z", visibility: String = "timeline",
                      revision: String = "r1", type: String = "AssetV2") -> EntitySyncEvent {
        event(type, """
        {"id":"\(id)","ownerId":"\(owner)","type":"IMAGE","originalFileName":"\(id).jpg","checksum":"AQIDBA==","fileCreatedAt":"\(taken)","localDateTime":"\(taken)","createdAt":"2026-03-01T00:00:00Z","visibility":"\(visibility)","isFavorite":false,"deletedAt":null,"stackId":null,"isEdited":false,"isDeveloped":false,"mediaRevision":"\(revision)"}
        """, ack: "\(type)|\(id)")
    }

    static func complete(id: String = "done") -> EntitySyncEvent { event("SyncCompleteV1", "{}", ack: "SyncCompleteV1|\(id)") }

    /// A sync stream holding `events`, one JSON line each.
    static func stream(_ events: [EntitySyncEvent]) -> StubServer.Response {
        var body = Data()
        for event in events { body += ((try? JSONEncoder().encode(event)) ?? Data()) + Data("\n".utf8) }
        return StubServer.Response(status: 200, headers: ["Content-Type": "application/jsonlines+json"], body: body)
    }
}

/// A live connection the test plays: each connect opens a stream the test sends hints into.
final class FakeLiveConnection: Sendable {
    private struct State {
        var connects = 0
        var current: Int?
        var stream: AsyncThrowingStream<ServerInvalidation, any Error>.Continuation?
    }
    private let state = Mutex(State())

    /// How many times the engine connected.
    var connects: Int { state.withLock { $0.connects } }
    /// A connection is open now.
    var isOpen: Bool { state.withLock { $0.stream != nil } }

    func connect() -> ServerEventConnection {
        let (events, continuation) = AsyncThrowingStream.makeStream(of: ServerInvalidation.self, throwing: (any Error).self)
        let id = state.withLock { state -> Int in
            state.connects += 1
            state.current = state.connects
            state.stream = continuation
            return state.connects
        }
        return ServerEventConnection(events: events, close: { [weak self] in
            continuation.finish()
            self?.state.withLock { state in
                guard state.current == id else { return }
                state.current = nil
                state.stream = nil
            }
        })
    }

    /// Sends a hint on the open connection.
    func send(_ hint: ServerInvalidation) {
        state.withLock { $0.stream }?.yield(hint)
    }
}

/// What happened, in order, from any thread.
final class Recorded<Value: Sendable>: Sendable {
    private let values = Mutex<[Value]>([])

    func append(_ value: Value) { values.withLock { $0.append(value) } }
    var all: [Value] { values.withLock { $0 } }
    var count: Int { values.withLock { $0.count } }
}

/// A notification observer to remove when the test ends.
private final class ObserverToken: @unchecked Sendable {
    private let observer: any NSObjectProtocol

    init(_ observer: any NSObjectProtocol) { self.observer = observer }

    func remove() { NotificationCenter.default.removeObserver(observer) }
}

/// Polls until the condition holds or the time runs out, and says whether it held. It runs where
/// its caller runs, so the condition may read what the caller may.
func becomesTrue(within timeout: Duration = .seconds(5), isolation: isolated (any Actor)? = #isolation,
                 _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while true {
        if await condition() { return true }
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
}
