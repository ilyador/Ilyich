import Foundation
import IlyichPlatform
import XCTest
@testable import Ilyich

/// The staging area's sweep and sign-out removal (rebuild milestone B6), in a throwaway App Group.
final class StagingTests: XCTestCase {
    private typealias G = LegacyGoldens
    private static let backup = "Backup/\(G.digest)"

    private var group: TemporaryAppGroup!
    override func setUpWithError() throws { group = try TemporaryAppGroup() }
    override func tearDown() { group?.remove() }

    private var area: StagingArea { StagingArea(layout: group.layout, account: G.account) }
    /// An hour from now: what the test wrote is past the grace period.
    private let now = Date().addingTimeInterval(3_600)

    /// Only stage folders nothing refers to go, and in the folders that stay, only the bodies and
    /// outcomes of attempts nobody waits for. state.json, other folders, other accounts, the share
    /// inbox and anything changed within the grace period stay.
    func testSweepRemovesOnlyUnreferencedFolders() throws {
        let referenced = Self.backup + "/" + UUID().uuidString
        let bound = Self.backup + "/" + UUID().uuidString
        let orphan = Self.backup + "/" + UUID().uuidString
        let recent = Self.backup + "/" + UUID().uuidString
        let otherAccount = "Backup/\(String(repeating: "0", count: 64))/\(UUID().uuidString)"
        let share = "ShareInbox/\(UUID().uuidString)"
        let waiting = UUID().uuidString, answered = UUID().uuidString
        try group.write("{}", to: Self.backup + "/state.json")
        try group.write("still", to: referenced + "/original")
        try group.write("body", to: referenced + "/\(waiting).multipart")
        try group.write("body", to: referenced + "/\(answered).multipart")
        try group.write("{}", to: referenced + "/\(answered).receipt")
        try group.write("body", to: bound + "/task.multipart")
        try group.write("0123456789", to: orphan + "/original")
        try group.write("{}", to: orphan + "/old.receipt")
        try group.write("still", to: recent + "/original")
        try group.write("notes", to: Self.backup + "/notes/file")
        try group.write("theirs", to: otherAccount + "/original")
        try group.write("{}", to: share + "/manifest.json")
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: group.url(recent + "/original").path)

        // A state.json no import read keeps its build's stages until it is imported (LegacyBackupImporter).
        let before = area.sweep(keeping: StagingReferences(), legacyImported: false, now: now)
        XCTAssertEqual(before, StagingArea.Sweep(skipped: .legacyState))
        XCTAssertTrue(group.exists(orphan))

        let references = StagingReferences(folders: [referenced, bound], attempts: [waiting, "task"])
        let sweep = area.sweep(keeping: references, legacyImported: true, now: now)
        XCTAssertEqual(sweep.folders, 1)
        XCTAssertEqual(sweep.files, 4, "The orphan's two files, and the answered attempt's body and outcome.")
        XCTAssertEqual(sweep.bytes, 10 + 2 + 4 + 2)
        XCTAssertNil(sweep.skipped)
        XCTAssertFalse(group.exists(orphan))
        XCTAssertFalse(group.exists(referenced + "/\(answered).multipart"))
        XCTAssertFalse(group.exists(referenced + "/\(answered).receipt"))
        for kept in [referenced + "/original", referenced + "/\(waiting).multipart", bound + "/task.multipart", recent + "/original",
                     Self.backup + "/state.json", Self.backup + "/notes/file", otherAccount + "/original", share + "/manifest.json"] {
            XCTAssertTrue(group.exists(kept), kept)
        }

        // Once the grace period has passed, the recent folder goes too.
        let later = area.sweep(keeping: references, legacyImported: true, now: now.addingTimeInterval(StagingArea.grace))
        XCTAssertEqual(later.folders, 1)
        XCTAssertFalse(group.exists(recent))

        // A state.json moved aside as unreadable holds nothing an import could read: the engine
        // takes the database over without it, and the sweep runs.
        try FileManager.default.moveItem(at: group.url(Self.backup + "/state.json"), to: group.url(Self.backup + "/state.json.unreadable-1"))
        let stray = Self.backup + "/" + UUID().uuidString
        try group.write("still", to: stray + "/original")
        let aside = area.sweep(keeping: references, legacyImported: false, now: now.addingTimeInterval(StagingArea.grace))
        XCTAssertNil(aside.skipped)
        XCTAssertFalse(group.exists(stray))
        XCTAssertTrue(group.exists(Self.backup + "/state.json.unreadable-1"))
    }

    /// Signing out removes every stage folder of the account and nothing else; the database keeps
    /// the jobs, which stage again. A state.json no import read keeps its build's stages.
    func testSignOutRemovesScopeStaging() throws {
        let stages = (0..<3).map { _ in Self.backup + "/" + UUID().uuidString }
        for stage in stages { try group.write("still", to: stage + "/original") }
        try group.write("{}", to: Self.backup + "/state.json")
        let otherAccount = "Backup/\(String(repeating: "1", count: 64))/\(UUID().uuidString)"
        try group.write("theirs", to: otherAccount + "/original")
        try group.write("{}", to: "ShareInbox/\(UUID().uuidString)/manifest.json")

        XCTAssertEqual(area.removeAll(legacyImported: false).skipped, .legacyState)
        XCTAssertTrue(stages.allSatisfy { group.exists($0) })

        let removed = area.removeAll(legacyImported: true)
        XCTAssertEqual(removed.folders, 3)
        XCTAssertEqual(removed.files, 3)
        XCTAssertTrue(stages.allSatisfy { !group.exists($0) })
        XCTAssertTrue(group.exists(Self.backup + "/state.json"), "state.json survives sign-out.")
        XCTAssertTrue(group.exists(otherAccount + "/original"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: group.url("ShareInbox").path).count, 1)

        // An account without a Backup folder has nothing to remove.
        let bare = try TemporaryAppGroup()
        defer { bare.remove() }
        XCTAssertEqual(StagingArea(layout: bare.layout, account: G.account).removeAll(legacyImported: false), StagingArea.Sweep())
    }

    /// A body counts as written only when it ends with its closing boundary and has the size
    /// recorded after the write.
    func testBodyIsCompleteOnlyToItsClosingBoundary() throws {
        let source = group.url("source")
        try Data("photo".utf8).write(to: source)
        let body = group.url("body.multipart")
        try UploadBody.write(to: body, boundary: "Ilyich-a", fields: ["isFavorite": "false"],
                             asset: UploadFile(url: source, filename: "a.HEIC", contentType: "image/heic"))
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: body.path)[.size] as? NSNumber).int64Value
        XCTAssertEqual(UploadBody.isComplete(body, boundary: "Ilyich-a", bytes: nil), true)
        XCTAssertEqual(UploadBody.isComplete(body, boundary: "Ilyich-a", bytes: size), true)
        XCTAssertEqual(UploadBody.isComplete(body, boundary: "Ilyich-a", bytes: size + 1), false)
        XCTAssertEqual(UploadBody.isComplete(body, boundary: "Ilyich-b", bytes: nil), false, "Another attempt's boundary.")
        let data = try Data(contentsOf: body)
        try data.prefix(data.count - 3).write(to: body)
        XCTAssertEqual(UploadBody.isComplete(body, boundary: "Ilyich-a", bytes: nil), false)
        XCTAssertEqual(UploadBody.isComplete(group.url("missing"), boundary: "Ilyich-a", bytes: nil), false)
    }
}
