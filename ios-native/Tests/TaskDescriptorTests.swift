import IlyichPlatform
import XCTest
@testable import Ilyich

final class TaskDescriptorTests: XCTestCase {
    private typealias G = LegacyGoldens

    /// What builds before B9 wrote, under either container path, is told apart from another app's
    /// task, and nothing more is read from it (B10): no attempt, no outcome file, no account, and
    /// nothing is ever written in that shape again.
    func testOlderBuildsDescriptorsAreRecognizedAndNeverRead() throws {
        for path in ["backup/descriptor-backup.json", "share/descriptor-share-var.json", "share/descriptor-share-private-var.json"] {
            let descriptor = TaskDescriptor(taskDescription: String(decoding: try FixtureLoader.data(path), as: UTF8.self))
            XCTAssertEqual(descriptor, .legacy, path)
            XCTAssertNil(descriptor.attempt, path)
            XCTAssertNil(descriptor.outcomePath, path)
            XCTAssertNil(descriptor.scope, path)
            XCTAssertNil(descriptor.taskDescription, path)
        }
        let outside = TaskDescriptor(taskDescription: #"{"id":"stage","receipt":"file:\/\/\/tmp\/stage.receipt"}"#)
        XCTAssertEqual(outside, .legacy, "Wherever its outcome file was.")
    }

    func testVersion2RoundTripsAndIsWrittenTheSameWayEveryTime() {
        let outcome = "Backup/\(G.digest)/\(G.currentFolder)/0F1E2D3C-4B5A-4697-8877-665544332211.receipt"
        let descriptor = TaskDescriptor.v2(attempt: AttemptID(legacy: "0F1E2D3C-4B5A-4697-8877-665544332211"), scope: G.digest, outcome: outcome)
        XCTAssertEqual(descriptor.taskDescription,
                       #"{"attempt":"0F1E2D3C-4B5A-4697-8877-665544332211","outcome":"\#(outcome)","scope":"\#(G.digest)","v":2}"#)
        XCTAssertEqual(TaskDescriptor(taskDescription: descriptor.taskDescription), descriptor)
        XCTAssertEqual(descriptor.outcomePath, outcome)
        XCTAssertEqual(descriptor.attempt?.rawValue, "0F1E2D3C-4B5A-4697-8877-665544332211")
        // Any key order and escaped slashes read the same.
        XCTAssertEqual(TaskDescriptor(taskDescription: #"{"v":2,"scope":"s","outcome":"ShareInbox\/b\/i.receipt","attempt":"i"}"#),
                       .v2(attempt: AttemptID(legacy: "i"), scope: "s", outcome: "ShareInbox/b/i.receipt"))
        XCTAssertNotNil(UUID(uuidString: AttemptID().rawValue), "A new attempt is a UUID.")
        XCTAssertNotEqual(AttemptID(), AttemptID())
    }

    func testAnythingElseIsForeign() {
        let texts: [String?] = [
            nil, "", "upload", "[]", "{}", "2",
            #"{"id":"stage"}"#,
            #"{"receipt":"file:\/\/\/private\/var\/x.receipt"}"#,
            #"{"v":3,"attempt":"a","scope":"s","outcome":"Backup/a.receipt"}"#,
            #"{"v":"2","id":"stage","receipt":"file:\/\/\/private\/var\/x.receipt"}"#,
            #"{"v":2,"attempt":"","scope":"s","outcome":"Backup/a.receipt"}"#,
            #"{"v":2,"attempt":"a","scope":"s","outcome":"/private/var/mobile/Backup/a.receipt"}"#,
            #"{"v":2,"attempt":"a","scope":"s","outcome":"Backup/../../a.receipt"}"#,
            #"{"v":2,"attempt":"a","scope":"s","outcome":"file:///Backup/a.receipt"}"#,
            #"{"v":2,"attempt":"a","scope":"s"}"#,
        ]
        for text in texts {
            let descriptor = TaskDescriptor(taskDescription: text)
            XCTAssertEqual(descriptor, .foreign, text ?? "nil")
            XCTAssertNil(descriptor.attempt)
            XCTAssertNil(descriptor.outcomePath)
        }
        XCTAssertNil(TaskDescriptor.foreign.taskDescription)
    }

    func testSessionIdentifiersFollowTheBundleIdentifier() {
        // The identifiers every build used, so iOS hands over the sessions earlier builds left.
        let bundle = Bundle.main.bundleIdentifier ?? "app.alextran.immich"
        XCTAssertEqual(TransferSessionID.backup.identifier, bundle + ".backup")
        XCTAssertEqual(TransferSessionID.shareUpload.identifier, bundle + ".share-upload")
        XCTAssertEqual(TransferSessionID.backup.identifier(bundleIdentifier: "app.alextran.immich.H4K2MSF2SG"), "app.alextran.immich.H4K2MSF2SG.backup")
        XCTAssertEqual(TransferSessionID.shareUpload.identifier(bundleIdentifier: "app.alextran.immich.H4K2MSF2SG"), "app.alextran.immich.H4K2MSF2SG.share-upload")
        XCTAssertEqual(TransferSessionID.backup.identifier(bundleIdentifier: nil), "app.alextran.immich.backup")
    }
}
