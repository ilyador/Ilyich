import IlyichPlatform
import XCTest
@testable import Ilyich

final class TaskDescriptorTests: XCTestCase {
    private typealias G = LegacyGoldens

    /// What builds before B9 wrote, {id, receipt}, is foreign since C8, like any description this
    /// build didn't write: no attempt, no outcome file, no account, and nothing is ever written in
    /// that shape again.
    func testOlderBuildsDescriptorsAreForeign() throws {
        let backup = #"{"id":"7F3E2D1C-0B9A-4876-A5B4-C3D2E1F0A9B8","receipt":"file:\/\/\/private\/var\/mobile\/Containers\/Shared\/AppGroup\/0E4C1B7A-9D2F-4A63-8B5E-7C1D2E3F4A5B\/Backup\/\#(G.digest)\/2B7D4E91-6A3C-4F08-9E15-3C4D5E6F7A8B\/7F3E2D1C-0B9A-4876-A5B4-C3D2E1F0A9B8.receipt"}"#
        let share = #"{"id":"84190c3b90652749141de444753379393b8c4e800494669c7739f3e01b790b8a","receipt":"file:\/\/\/var\/mobile\/Containers\/Shared\/AppGroup\/0E4C1B7A-9D2F-4A63-8B5E-7C1D2E3F4A5B\/ShareInbox\/A9B8C7D6-E5F4-4321-9876-543210FEDCBA\/84190c3b90652749141de444753379393b8c4e800494669c7739f3e01b790b8a.receipt"}"#
        for text in [backup, share] {
            let descriptor = TaskDescriptor(taskDescription: text)
            XCTAssertEqual(descriptor, .foreign, text)
            XCTAssertNil(descriptor.attempt, text)
            XCTAssertNil(descriptor.outcomePath, text)
            XCTAssertNil(descriptor.scope, text)
            XCTAssertNil(descriptor.taskDescription, text)
        }
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
        let bundle = Bundle.main.bundleIdentifier ?? "io.ilyador.ilyich"
        XCTAssertEqual(TransferSessionID.backup.identifier, bundle + ".backup")
        XCTAssertEqual(TransferSessionID.shareUpload.identifier, bundle + ".share-upload")
        XCTAssertEqual(TransferSessionID.backup.identifier(bundleIdentifier: "io.ilyador.ilyich.H4K2MSF2SG"), "io.ilyador.ilyich.H4K2MSF2SG.backup")
        XCTAssertEqual(TransferSessionID.shareUpload.identifier(bundleIdentifier: "io.ilyador.ilyich.H4K2MSF2SG"), "io.ilyador.ilyich.H4K2MSF2SG.share-upload")
        XCTAssertEqual(TransferSessionID.backup.identifier(bundleIdentifier: nil), "io.ilyador.ilyich.backup")
    }
}
