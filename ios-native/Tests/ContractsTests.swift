import IlyichPlatform
import Photos
import XCTest
@testable import Ilyich

/// The small rules the contract types carry.
final class ContractsTests: XCTestCase {
    private let account = LegacyGoldens.account

    private func snapshot(readOnly: Bool = false, passwordChange: Bool = false, unlocked: Bool = false) -> AuthorizationSnapshot {
        AuthorizationSnapshot(epoch: AuthorizationEpoch(account: account, value: 1), writeGeneration: 1, privateEpoch: 1, tokenDigest: "token",
                              readOnly: readOnly, requiresPasswordChange: passwordChange, lockedFolderUnlocked: unlocked)
    }

    func testAuthorizationFollowsTodaysRules() {
        let all: [AuthorizationSnapshot.Operation] = [.read, .write, .upload, .lockedMedia]
        func allowed(_ snapshot: AuthorizationSnapshot) -> [AuthorizationSnapshot.Operation] { all.filter(snapshot.allows) }
        XCTAssertEqual(allowed(snapshot()), [.read, .write, .upload])
        XCTAssertEqual(allowed(snapshot(unlocked: true)), [.read, .write, .upload, .lockedMedia])
        XCTAssertEqual(allowed(snapshot(readOnly: true)), [.read], "Read-only blocks writes and uploads, never reads.")
        XCTAssertEqual(allowed(snapshot(readOnly: true, unlocked: true)), [.read, .lockedMedia])
        XCTAssertEqual(allowed(snapshot(passwordChange: true, unlocked: true)), [], "Nothing until the password is changed.")
    }

    func testFencedValueIsUsedOnlyUnderItsEpoch() {
        let first = AuthorizationEpoch(account: account, value: 1)
        let fenced = Fenced(epoch: first, value: ["month"])
        XCTAssertEqual(fenced.value(ifCurrent: first), ["month"])
        XCTAssertNil(fenced.value(ifCurrent: AuthorizationEpoch(account: account, value: 2)))
        XCTAssertNil(fenced.value(ifCurrent: AuthorizationEpoch(account: AccountID(server: account.server, userID: "someone-else"), value: 1)))
    }

    func testMergedChangesKeepEveryEffect() throws {
        let march = try XCTUnwrap(MonthKey(year: 2025, month: 3)), april = try XCTUnwrap(MonthKey(year: 2025, month: 4))
        var change = LibraryChange(account: account, authorization: AuthorizationEpoch(account: account, value: 1), indexRevision: 10, origin: .sync)
        change.upserted = ["moved": .init(from: march, to: april), "removed-later": .init(from: nil, to: march)]
        change.removed = ["back"]
        change.accessLost = ["locked"]
        change.albums = ["album-1"]
        let made = Album(id: "album-1", albumName: "Coast", assetCount: 2, shared: false, albumUsers: nil, startDate: nil, endDate: nil,
                         updatedAt: nil, order: nil)
        change.collections = [.albumCreated(made)]
        var later = LibraryChange(account: account, authorization: AuthorizationEpoch(account: account, value: 1), indexRevision: 11,
                                  origin: .mutation(OperationID()))
        later.upserted = ["moved": .init(from: april, to: march), "back": .init(from: nil, to: april), "locked": .init(from: nil, to: april)]
        later.removed = ["removed-later"]
        later.mediaRevisions = ["moved": "r2"]
        later.albums = ["album-2"]
        later.collections = [.albumDeleted("album-2")]
        later.partnersChanged = true
        change.merge(later)
        XCTAssertEqual(change.indexRevision, 11)
        XCTAssertEqual(change.origin, later.origin)
        XCTAssertEqual(change.upserted["moved"], .init(from: march, to: march), "Left the first month it was in, joined the last.")
        XCTAssertEqual(change.upserted["back"], .init(from: nil, to: april))
        XCTAssertNil(change.upserted["removed-later"])
        XCTAssertEqual(change.removed, ["removed-later"])
        XCTAssertEqual(change.accessLost, ["locked"], "Lost access is never forgotten.")
        XCTAssertEqual(change.mediaRevisions, ["moved": "r2"])
        XCTAssertEqual(change.albums, ["album-1", "album-2"])
        XCTAssertEqual(change.collections, [.albumCreated(made), .albumDeleted("album-2")])
        XCTAssertTrue(change.partnersChanged)
        XCTAssertFalse(change.reset)

        // The index holds what the newest full pass read; a change that doesn't say keeps it.
        let began = ContinuousClock.now
        change.syncedThrough = began
        var unstamped = later; unstamped.syncedThrough = nil
        change.merge(unstamped)
        XCTAssertEqual(change.syncedThrough, began)
        var newer = later; newer.syncedThrough = began + .seconds(1)
        change.merge(newer)
        XCTAssertEqual(change.syncedThrough, began + .seconds(1))

        let elsewhere = AccountID(server: account.server, userID: "someone-else")
        change.merge(LibraryChange(account: elsewhere, authorization: AuthorizationEpoch(account: elsewhere, value: 1), indexRevision: 1, origin: .sync))
        XCTAssertEqual(change.account, elsewhere)
        XCTAssertTrue(change.reset, "Another account's change replaces everything.")
        XCTAssertTrue(change.upserted.isEmpty)
    }

    func testDeviceSnapshotReportsOnlyChangedMonths() throws {
        let march = try XCTUnwrap(MonthKey(year: 2025, month: 3)), april = try XCTUnwrap(MonthKey(year: 2025, month: 4))
        let may = try XCTUnwrap(MonthKey(year: 2025, month: 5))
        func asset(_ id: String, favorite: Bool = false, revision: Double = 1) -> DeviceAsset {
            DeviceAsset(id: DeviceAssetID(rawValue: id), revision: AssetRevision(referenceSeconds: revision), created: nil, isVideo: false,
                        isLive: false, isFavorite: favorite, location: nil, shape: .singleOriginal, canDelete: true, canEditProperties: true)
        }
        let access = DeviceAccess(status: .authorized, generation: 1)
        let before = DeviceSnapshot(access: access, months: [march: .init(assets: [asset("a")]), april: .init(assets: [asset("b")])], matches: [:])
        let after = DeviceSnapshot(access: access, months: [march: .init(assets: [asset("a")]), april: .init(assets: [asset("b", favorite: true)]),
                                                            may: .init(assets: [asset("c")])], matches: [:])
        XCTAssertEqual(after.changedMonths(since: before), [april, may])
        XCTAssertEqual(before.changedMonths(since: after), [april, may])
        XCTAssertEqual(after.changedMonths(since: after), [])
        let edited = DeviceSnapshot(access: access, months: [march: .init(assets: [asset("a", revision: 2)])], matches: [:])
        XCTAssertEqual(edited.changedMonths(since: before), [march, april])
    }

    func testAssetRevisionsCompareBits() {
        let date = Date(timeIntervalSinceReferenceDate: 782_481_234.567_891)
        XCTAssertEqual(AssetRevision(date), AssetRevision(referenceSeconds: Double(bitPattern: LegacyGoldens.Bits.current)))
        XCTAssertEqual(AssetRevision(date).date, date)
        XCTAssertNotEqual(AssetRevision(referenceSeconds: 0), AssetRevision(referenceSeconds: -0.0), "Equal dates, different bits.")
        XCTAssertNotEqual(AssetRevision(referenceSeconds: 782_481_234.567_891), AssetRevision(referenceSeconds: 782_481_234.567_891.nextUp))
        XCTAssertEqual(Set([AssetRevision(date), AssetRevision(date)]).count, 1)
    }

    func testBackgroundTaskLeaseCompletesOnce() {
        let results = Results()
        let lease = BGTaskLease(identifier: "app.ilyich.native.backup.processing") { results.append($0) }
        XCTAssertFalse(lease.isCompleted)
        lease.expire()
        lease.finish(success: true)
        lease.expire()
        XCTAssertTrue(lease.isCompleted)
        XCTAssertEqual(results.values, [false], "Expiry completes synchronously, and only once.")
    }

    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Bool] = []
        func append(_ value: Bool) { lock.withLock { stored.append(value) } }
        var values: [Bool] { lock.withLock { stored } }
    }
}
