import Foundation
import IlyichPlatform
import IlyichShareInbox
import XCTest
@testable import Ilyich

/// The signed-in account's authorization: which generation each change moves, the App Group
/// mirror the extensions and upload delegates read, the updates stream, and what a read-only
/// toggle does to uploads.
final class AuthorizationTests: XCTestCase {
    private let account = LegacyGoldens.account

    /// A mirror in preferences of its own, removed when the test ends.
    private func makeMirror() -> AuthorizationMirror {
        let suite = "ilyich.tests.authorization." + UUID().uuidString
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return AuthorizationMirror(appGroup: suite)
    }

    private func state(_ account: AccountID? = nil, readOnly: Bool = false, mirror: AuthorizationMirror?) -> AuthorizationState {
        AuthorizationState(account: account ?? self.account, token: "opaque-access-token", readOnly: readOnly,
                           requiresPasswordChange: false, mirror: mirror)
    }

    /// Read-only mode moves the write generation, which fences writes and uploads, and the
    /// mirror with it. The access epoch stays, so no library read is thrown away.
    func testReadOnlyToggleBumpsEpochAndMirror() async throws {
        let mirror = makeMirror()
        let state = state(mirror: mirror)
        let before = state.snapshot
        // Opening the session for the saved credential is what writes the mirror's two keys.
        XCTAssertEqual(mirror.read(), .init(digest: LegacyGoldens.credential.scope, epoch: before.writeGeneration))
        XCTAssertEqual(LegacyGoldens.credential.scope, LegacyGoldens.digest)
        var updates = state.updates().makeAsyncIterator()
        let first = await updates.next()
        XCTAssertEqual(first, before, "The stream starts with the snapshot as it is.")

        let on = state.setReadOnly(true)
        XCTAssertTrue(on.readOnly)
        XCTAssertGreaterThan(on.writeGeneration, before.writeGeneration, "Turning read-only mode on moves the write generation.")
        XCTAssertEqual(on.epoch, before.epoch, "A read-only toggle never discards library reads.")
        XCTAssertEqual(on.privateEpoch, before.privateEpoch)
        XCTAssertFalse(on.allows(.write)); XCTAssertFalse(on.allows(.upload)); XCTAssertTrue(on.allows(.read))
        XCTAssertEqual(mirror.read(), .init(digest: account.digest, epoch: on.writeGeneration), "The mirror follows at once.")
        let published = await updates.next()
        XCTAssertEqual(published, on)

        let off = state.setReadOnly(false)
        XCTAssertFalse(off.readOnly)
        XCTAssertGreaterThan(off.writeGeneration, on.writeGeneration, "Turning it off moves it again: nothing goes back to an earlier value.")
        XCTAssertEqual(off.epoch, before.epoch)
        XCTAssertEqual(mirror.read(), .init(digest: account.digest, epoch: off.writeGeneration))
        let republished = await updates.next()
        XCTAssertEqual(republished, off)

        XCTAssertEqual(state.setReadOnly(false), off, "Setting it to what it is changes nothing.")
        XCTAssertEqual(mirror.read()?.epoch, off.writeGeneration)
    }

    /// The generations never repeat on the phone. A relaunch for the same account keeps the
    /// mirrored value, so work begun before it still counts; another account, or a sign-in after
    /// sign-out, starts after it.
    func testTheMirrorGoesOnAcrossLaunchesAndAccounts() {
        let mirror = makeMirror()
        let first = state(mirror: mirror)
        let toggled = first.setReadOnly(true).writeGeneration

        let relaunched = state(readOnly: true, mirror: mirror)
        XCTAssertEqual(relaunched.snapshot.writeGeneration, toggled, "A relaunch changes nothing about what may be written.")
        XCTAssertEqual(mirror.read(), .init(digest: account.digest, epoch: toggled))

        let other = AccountID(server: account.server, userID: "someone-else")
        let switched = state(other, mirror: mirror)
        XCTAssertGreaterThan(switched.snapshot.writeGeneration, toggled)
        XCTAssertEqual(mirror.read(), .init(digest: other.digest, epoch: switched.snapshot.writeGeneration))

        let beforeSignOut = switched.snapshot.writeGeneration
        switched.end()
        let signedOut = mirror.read()
        XCTAssertEqual(signedOut?.digest, "", "After sign-out the mirror names no account.")
        XCTAssertGreaterThan(signedOut?.epoch ?? 0, beforeSignOut)
        XCTAssertEqual(signedOut?.epoch, switched.snapshot.writeGeneration)
        let again = state(other, mirror: mirror)
        XCTAssertGreaterThan(again.snapshot.writeGeneration, signedOut?.epoch ?? .max, "Signing in again starts after sign-out.")

        // Without a mirror the state still works, from the first generation.
        XCTAssertEqual(state(mirror: nil).snapshot.writeGeneration, 1)
    }

    /// The access epoch goes on across launches too. A relaunch keeps it, so what was kept under it
    /// stays current, but never brings back one from before an access change, and the next change
    /// gives out an epoch never given out before.
    func testTheAccessEpochNeverRepeatsAcrossLaunches() {
        let mirror = makeMirror()
        let first = state(mirror: mirror)
        let before = first.snapshot.epoch
        let revoked = first.accessChanged().epoch

        let relaunched = state(mirror: mirror)
        XCTAssertEqual(relaunched.snapshot.epoch, revoked, "A relaunch keeps the epoch from after the change.")
        XCTAssertFalse(relaunched.isCurrent(before), "What was kept before the change stays refused.")
        XCTAssertEqual(relaunched.snapshot.writeGeneration, first.snapshot.writeGeneration, "Writes begun before the relaunch still count.")
        let next = relaunched.accessChanged().epoch
        XCTAssertGreaterThan(next.value, revoked.value, "The next change gives out an epoch never given out before.")

        // A read-only toggle moves only the write generation, and a relaunch keeps both.
        let toggled = relaunched.setReadOnly(true)
        let again = state(readOnly: true, mirror: mirror)
        XCTAssertEqual(again.snapshot.epoch, next)
        XCTAssertEqual(again.snapshot.writeGeneration, toggled.writeGeneration)

        // Another account starts after every generation given out before, access epochs included.
        let other = state(AccountID(server: account.server, userID: "someone-else"), mirror: mirror)
        XCTAssertGreaterThan(other.snapshot.epoch.value, max(next.value, toggled.writeGeneration))
        XCTAssertGreaterThan(other.snapshot.writeGeneration, max(next.value, toggled.writeGeneration))
    }

    /// Turning read-only mode on stops shared uploads and pauses backup, switching automatic
    /// backup off, as the toggle always has; turning it off starts nothing again. Whether it
    /// should carry on with them is an owner question, so neither may change before it is answered.
    @MainActor func testReadOnlyModePausesUploadsAndSwitchesAutomaticBackupOff() async {
        let backup = BackupCoordinator()
        backup.preferences.automatic = true
        let shares = ShareInboxStore(repository: ShareInboxRepository(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("AuthorizationTests-\(UUID().uuidString)", isDirectory: true)))

        await AccountRuntime.uploadsFollow(readOnly: true, backup: backup, shares: shares)
        XCTAssertFalse(backup.preferences.automatic, "Turning read-only mode on switches automatic backup off.")
        XCTAssertEqual(backup.activity, "Backup paused")
        XCTAssertFalse(backup.isRunning)
        XCTAssertFalse(shares.isRunning)

        await AccountRuntime.uploadsFollow(readOnly: false, backup: backup, shares: shares)
        XCTAssertFalse(backup.preferences.automatic, "Turning it off leaves automatic backup off until it is turned on again.")
        XCTAssertEqual(backup.activity, "Backup paused", "Nor does it start backup.")
    }

    /// Losing access to some photos makes what was read and kept stale, but not what may be written.
    func testAnAccessChangeMovesOnlyTheAccessEpoch() {
        let mirror = makeMirror()
        let state = state(mirror: mirror)
        let before = state.snapshot
        let counted = Fenced(epoch: before.epoch, value: ["2026-02-01": "Kyoto"])
        XCTAssertTrue(state.isCurrent(before.epoch))

        let after = state.accessChanged()
        XCTAssertNotEqual(after.epoch, before.epoch)
        XCTAssertEqual(after.epoch.account, account)
        XCTAssertEqual(after.writeGeneration, before.writeGeneration, "Writes and uploads carry on.")
        XCTAssertEqual(mirror.read()?.epoch, before.writeGeneration, "Nor does the mirror move.")
        XCTAssertFalse(state.isCurrent(before.epoch))
        XCTAssertNil(counted.value(ifCurrent: after.epoch), "What was counted before is not kept.")
        XCTAssertTrue(state.isCurrent(after.epoch))
    }

    /// Ending the session fences everything made under it and finishes its updates.
    func testSignOutEndsTheSessionAndItsUpdates() async {
        let state = state(mirror: makeMirror())
        let before = state.snapshot
        var updates = state.updates().makeAsyncIterator()
        _ = await updates.next()

        state.end()
        XCTAssertTrue(state.hasEnded)
        XCTAssertFalse(state.isCurrent(before.epoch))
        XCTAssertFalse(state.isCurrent(state.snapshot.epoch), "Nothing is current after the session ends.")
        XCTAssertGreaterThan(state.snapshot.writeGeneration, before.writeGeneration)
        let next = await updates.next()
        XCTAssertNil(next, "The stream finishes.")
        let ended = state.snapshot
        XCTAssertEqual(state.setReadOnly(true), ended, "An ended session changes no more.")
        XCTAssertEqual(state.accessChanged(), ended)
        var late = state.updates().makeAsyncIterator()
        let last = await late.next()
        XCTAssertEqual(last, ended)
        let finished = await late.next()
        XCTAssertNil(finished, "A stream asked for after the end gives the last snapshot and finishes.")
    }
}
