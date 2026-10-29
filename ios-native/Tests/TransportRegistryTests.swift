import IlyichPlatform
import UIKit
import XCTest
@testable import Ilyich

/// TransportRegistry and the background session configuration (rebuild milestone B5).
final class TransportRegistryTests: XCTestCase {
    private var group: TemporaryAppGroup!

    override func setUpWithError() throws { group = try TemporaryAppGroup() }
    override func tearDown() { group?.remove() }

    func testOneURLSessionPerIdentifierUnderRacingLaunchPaths() {
        let made = Locked<[TransferSessionID]>([])
        let journal = group.journal
        let registry = TransportRegistry { session, emit in
            made.mutate { $0.append(session) }
            // Creating a session takes a moment, which widens the race.
            Thread.sleep(forTimeInterval: 0.005)
            return BackgroundTransport(session: session, journal: journal, emit: emit) { _ in FakeTransportSession() }
        }
        let seen = Locked<[TransferSessionID: Set<ObjectIdentifier>]>([:])
        let backup = TransferSessionID.backup.identifier, share = TransferSessionID.shareUpload.identifier
        // Launch connects every session while iOS delivers background events and the engine submits.
        DispatchQueue.concurrentPerform(iterations: 48) { index in
            let transport: BackgroundTransport?
            switch index % 4 {
            case 0:
                registry.connect()
                transport = registry.transport(.backup)
            case 1: transport = registry.transport(identifier: backup)
            case 2: transport = registry.transport(.shareUpload)
            default: transport = registry.transport(identifier: share)
            }
            if let transport { seen.mutate { $0[transport.session, default: []].insert(ObjectIdentifier(transport)) } }
        }
        XCTAssertEqual(made.value.sorted { $0.rawValue < $1.rawValue }, [.backup, .shareUpload], "Each identifier's session was created once.")
        XCTAssertEqual(seen.value.mapValues(\.count), [.backup: 1, .shareUpload: 1], "Every caller got the same transport.")
        XCTAssertEqual(registry.connected, [.backup, .shareUpload])
    }

    func testEverySessionsEventsArriveOnOneStream() async throws {
        let fakes = Locked<[TransferSessionID: FakeTransportSession]>([:])
        let journal = group.journal
        let registry = TransportRegistry { session, emit in
            let fake = FakeTransportSession()
            fakes.mutate { $0[session] = fake }
            return BackgroundTransport(session: session, journal: journal, emit: emit) { fake.attach($0) }
        }
        registry.connect()
        let backup = try XCTUnwrap(fakes.value[.backup]), share = try XCTUnwrap(fakes.value[.shareUpload])
        let key = AttemptKey(attempt: AttemptID(), scope: LegacyGoldens.digest, folder: "Backup/\(LegacyGoldens.digest)/\(UUID().uuidString)")
        try group.makeFolder(key.folder)

        backup.handler.taskDidComplete(CompletedTask(id: 1, description: key.descriptor.taskDescription, httpStatus: 503, failure: nil))
        share.handler.sessionDidFinishEvents()
        backup.handler.sessionDidFinishEvents()
        backup.handler.sessionDidFinishEvents()

        var events = registry.events.makeAsyncIterator()
        guard case .finished(.backup, let completion)? = await events.next() else { return XCTFail("The backup's task was not reported first.") }
        XCTAssertEqual(completion.attempt, key.attempt)
        XCTAssertEqual(completion.journal, .recorded(OutcomeRecord(error: HTTPURLResponse.localizedString(forStatusCode: 503), httpStatus: 503, v: 2)))
        var drains: [TransportEvent?] = []
        for _ in 0..<3 { drains.append(await events.next()) }
        XCTAssertEqual(drains, [.drained(.shareUpload, drain: 1), .drained(.backup, drain: 1), .drained(.backup, drain: 2)],
                       "Each session numbers its own drains.")
        XCTAssertEqual(registry.drains(identifier: TransferSessionID.backup.identifier), 2)
        XCTAssertEqual(registry.drains(identifier: TransferSessionID.shareUpload.identifier), 1)
    }

    func testIdentifiersMapOnlyToThisBundlesSessions() {
        XCTAssertEqual(TransferSessionID(identifier: TransferSessionID.backup.identifier), .backup)
        XCTAssertEqual(TransferSessionID(identifier: TransferSessionID.shareUpload.identifier), .shareUpload)
        let sideloaded = "app.alextran.immich.H4K2MSF2SG"
        XCTAssertEqual(TransferSessionID(identifier: "app.alextran.immich.H4K2MSF2SG.share-upload", bundleIdentifier: sideloaded), .shareUpload)
        XCTAssertNil(TransferSessionID(identifier: "app.alextran.immich.backup", bundleIdentifier: sideloaded), "A re-signed bundle's sessions are its own.")
        XCTAssertNil(TransferSessionID(identifier: "com.example.downloads"))

        let registry = TransportRegistry { session, emit in
            BackgroundTransport(session: session, journal: FileOutcomeJournal(layout: nil), emit: emit) { _ in FakeTransportSession() }
        }
        XCTAssertNil(registry.transport(identifier: "com.example.downloads"))
        XCTAssertNil(registry.drains(identifier: "com.example.downloads"))
        XCTAssertEqual(registry.drains(identifier: TransferSessionID.backup.identifier), 0, "A session not yet created has not drained.")
        XCTAssertEqual(registry.connected, [], "Asking about an identifier creates nothing.")
    }

    func testBackgroundSessionsAreConfiguredAsToday() {
        let identifier = "app.ilyich.tests.configuration." + UUID().uuidString
        let configuration = TransferSessionConfiguration.make(identifier: identifier)
        XCTAssertEqual(configuration.identifier, identifier)
        XCTAssertEqual(configuration.sharedContainerIdentifier, try? AppGroup.identifier)
        XCTAssertTrue(configuration.sessionSendsLaunchEvents)
        XCTAssertFalse(configuration.isDiscretionary)
        XCTAssertEqual(configuration.httpMaximumConnectionsPerHost, 2)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 7 * 24 * 3600)
        XCTAssertEqual(TransferSessionConfiguration.configurations(of: identifier), 1)
        // A second configuration for one identifier is the bug this guards against, so it is counted.
        _ = TransferSessionConfiguration.make(identifier: identifier)
        XCTAssertEqual(TransferSessionConfiguration.configurations(of: identifier), 2)
    }
}

/// One engine per process (B9, B10): TransferHost starts the transfer engine's sessions once, when
/// the first account's backup starts. Background session events that come before wait for it.
@MainActor final class TransferHostTests: XCTestCase {
    private func host(registries: Locked<Int>, group: TemporaryAppGroup) -> TransferHost {
        let journal = group.journal
        return TransferHost(scheduler: FakeTaskScheduler(), makeRegistry: {
            registries.mutate { $0 += 1 }
            return TransportRegistry { session, emit in
                BackgroundTransport(session: session, journal: journal, emit: emit) { _ in FakeTransportSession() }
            }
        })
    }

    func testEventsWaitForTheEngineWhichStartsOnce() async throws {
        let group = try TemporaryAppGroup()
        defer { group.remove() }
        let registries = Locked(0)
        let host = host(registries: registries, group: group)
        var answered = 0
        host.handleEvents(identifier: TransferSessionID.backup.identifier) { answered += 1 }
        host.handleEvents(identifier: "com.example.downloads") { answered += 10 }
        XCTAssertEqual(answered, 10, "Another app's identifier is answered at once; ours waits for the engine.")
        XCTAssertEqual(registries.value, 0, "No session is made before the engine starts.")
        XCTAssertEqual(host.summary, "Not started")

        host.startEngine()
        XCTAssertEqual(registries.value, 1)
        XCTAssertEqual(host.registry?.connected, [.backup, .shareUpload], "Every session is made, so iOS delivers what it queued.")
        host.startEngine()
        host.handleEvents(identifier: TransferSessionID.shareUpload.identifier) {}
        XCTAssertEqual(registries.value, 1, "The sessions are made once per process.")
        XCTAssertEqual(host.summary, "Transfer engine")
    }

    /// A background task that comes before the engine starts waits for the engine's handler.
    func testBackgroundTasksWaitForTheEnginesHandler() {
        let scheduler = FakeTaskScheduler()
        let router = BackgroundTaskRouter(system: scheduler)
        var restores = 0
        router.registerWithSystem { restores += 1 }
        XCTAssertEqual(scheduler.registeredIdentifiers, Set(BackgroundWindowKind.allCases.map(\.identifier)), "Both identifiers are registered at launch.")
        let task = scheduler.launch(.processing)
        XCTAssertEqual(restores, 1, "The account is restored for it.")
        XCTAssertTrue(task.completions.isEmpty, "It waits.")
        var handled: [String] = []
        XCTAssertTrue(router.register(identifier: BackgroundWindowKind.processing.identifier) { handled.append($0.identifier) })
        XCTAssertEqual(handled, [BackgroundWindowKind.processing.identifier])
    }
}
