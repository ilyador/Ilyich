import IlyichPlatform
import XCTest
@testable import Ilyich

final class TaskDescriptorTests: XCTestCase {
    private typealias G = LegacyGoldens

    func testLegacyDescriptorsAreAdoptedByTheirIDUnderEitherContainerPath() throws {
        for path in ["backup/descriptor-backup.json", "share/descriptor-share-var.json", "share/descriptor-share-private-var.json"] {
            let text = String(decoding: try FixtureLoader.data(path), as: UTF8.self)
            let legacy = try FixtureLoader.decode(Legacy.Descriptor.self, from: path)
            let descriptor = TaskDescriptor(taskDescription: text)
            XCTAssertEqual(descriptor, .legacy(id: legacy.id, receipt: legacy.receipt), path)
            XCTAssertEqual(descriptor.attempt, AttemptID(legacy: legacy.id), "A legacy stage ID or share identity is kept verbatim.")
            XCTAssertEqual(TaskDescriptor(taskDescription: descriptor.taskDescription), descriptor, path)
            // Today's uploader matches its own tasks by decoding the same text.
            let production = try JSONDecoder().decode(BackgroundUploads.Descriptor.self, from: Data(text.utf8))
            XCTAssertEqual(production.id, legacy.id)
        }
        let backup = TaskDescriptor(taskDescription: String(decoding: try FixtureLoader.data("backup/descriptor-backup.json"), as: UTF8.self))
        XCTAssertEqual(backup.outcomePath, "Backup/\(G.digest)/\(G.currentFolder)/\(G.currentStage).receipt")
        let plainVar = TaskDescriptor(taskDescription: String(decoding: try FixtureLoader.data("share/descriptor-share-var.json"), as: UTF8.self))
        let privateVar = TaskDescriptor(taskDescription: String(decoding: try FixtureLoader.data("share/descriptor-share-private-var.json"), as: UTF8.self))
        XCTAssertEqual(plainVar.outcomePath, "ShareInbox/\(G.batchID.uuidString)/\(plainVar.attempt!.rawValue).receipt")
        XCTAssertEqual(privateVar.outcomePath, "ShareInbox/\(G.batchID.uuidString)/\(privateVar.attempt!.rawValue).receipt")
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

    func testLegacyDescriptorOutsideTheAppGroupIsKeptButUnresolved() {
        let descriptor = TaskDescriptor(taskDescription: #"{"id":"stage","receipt":"file:\/\/\/tmp\/stage.receipt"}"#)
        XCTAssertEqual(descriptor, .legacy(id: "stage", receipt: URL(fileURLWithPath: "/tmp/stage.receipt")))
        XCTAssertEqual(descriptor.attempt, AttemptID(legacy: "stage"))
        XCTAssertNil(descriptor.outcomePath)
    }

    func testSessionIdentifiersFollowTheBundleIdentifier() {
        XCTAssertEqual(TransferSessionID.backup.identifier, BackgroundUploads.identifier)
        XCTAssertEqual(TransferSessionID.shareUpload.identifier, BackgroundUploads.shareIdentifier)
        XCTAssertEqual(TransferSessionID.backup.identifier(bundleIdentifier: "app.alextran.immich.H4K2MSF2SG"), "app.alextran.immich.H4K2MSF2SG.backup")
        XCTAssertEqual(TransferSessionID.shareUpload.identifier(bundleIdentifier: "app.alextran.immich.H4K2MSF2SG"), "app.alextran.immich.H4K2MSF2SG.share-upload")
        XCTAssertEqual(TransferSessionID.backup.identifier(bundleIdentifier: nil), "app.alextran.immich.backup")
    }
}
