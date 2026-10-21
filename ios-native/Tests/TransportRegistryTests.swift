import IlyichPlatform
import UIKit
import XCTest
@testable import Ilyich

/// TransportRegistry and the session configuration it shares with today's BackgroundUploads
/// (rebuild milestone B5).
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

/// Rebuild milestone B5 ships the new transport dormant. If the app created it before B9, iOS
/// would see two sessions for one identifier beside BackgroundUploads, with undefined delivery.
@MainActor final class TransferDormancyTests: XCTestCase {
    func testTransportRegistryIsNeverInstantiatedInTheAppBeforeB9() async throws {
        XCTAssertEqual(URLSessionTransportSession.created, 0, "Launching the app created no session of the new transport.")
        let delegate = BackupAppDelegate()
        let sessions = [(BackgroundUploads.identifier, BackgroundUploads.shared), (BackgroundUploads.shareIdentifier, BackgroundUploads.sharing)]
        for (identifier, uploads) in sessions {
            let answered = expectation(description: identifier)
            delegate.application(UIApplication.shared, handleEventsForBackgroundURLSession: identifier) { answered.fulfill() }
            // Today's session reports its events delivered, and iOS gets its completion, as before.
            uploads.urlSessionDidFinishEvents(forBackgroundURLSession: URLSession.shared)
            await fulfillment(of: [answered], timeout: 5)
            XCTAssertEqual(TransferSessionConfiguration.configurations(of: identifier), 1, "\(identifier) has one session in the process.")
        }
        let unknown = expectation(description: "another app's identifier")
        delegate.application(UIApplication.shared, handleEventsForBackgroundURLSession: "com.example.downloads") { unknown.fulfill() }
        await fulfillment(of: [unknown], timeout: 1)
        XCTAssertEqual(URLSessionTransportSession.created, 0, "Background events created no session of the new transport.")
    }
}
