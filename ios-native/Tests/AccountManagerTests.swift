import Foundation
import IlyichPlatform
import Synchronization
import XCTest
@testable import Ilyich

/// The account runtime: restoring the saved session, the session checks that may and may not
/// end it, the order sign-out works in, and sign-in after sign-out. Nothing here touches the
/// Keychain, the App Group or the device-wide services: they are fakes that record what they
/// are asked.
@MainActor final class AccountManagerTests: XCTestCase {
    // MARK: - Restore

    /// Earlier native builds saved the server's password-change flag without the administrator
    /// exemption. Restoring repairs the flag and keeps the session: same token, no sign-in.
    func testRestoreRepairsAnAdministratorsPasswordChangeFlag() async throws {
        let server = makeStubServer()
        server.route("GET", "users/me", .json(#"{"id":"admin","name":"Admin","email":"admin@example.test","isAdmin":true}"#))
        server.route("POST", "auth/validateToken", .json(#"{"authStatus":true}"#))
        var saved = credential("admin", on: server)
        saved.requiresPasswordChange = true
        let harness = makeHarness(saved, server: server)

        await harness.manager.restore()

        let phase = await harness.manager.phase
        XCTAssertEqual(phase, .active)
        XCTAssertEqual(harness.credentials.credential?.requiresPasswordChange, false, "The flag is repaired.")
        XCTAssertEqual(harness.credentials.credential?.token, saved.token, "The session is the same one: nothing re-syncs.")
        XCTAssertTrue(server.requests("POST", "auth/login").isEmpty)
        let runtime = try await XCTUnwrapAsync(await harness.manager.runtime)
        XCTAssertFalse(runtime.requiresPasswordChange)
        await signOutAfterwards(harness)
    }

    /// Someone who isn't an administrator stays at the password change, and the flag is kept.
    func testRestoreKeepsOthersAtThePasswordChange() async throws {
        let server = makeStubServer()
        server.route("GET", "users/me", .json(#"{"id":"member","name":"Member","email":"member@example.test","isAdmin":false}"#))
        server.route("POST", "auth/validateToken", .json(#"{"authStatus":true}"#))
        var saved = credential("member", on: server)
        saved.requiresPasswordChange = true
        let harness = makeHarness(saved, server: server, environment: environment(library: true))

        await harness.manager.restore()

        let phase = await harness.manager.phase
        XCTAssertEqual(phase, .passwordChangeRequired)
        XCTAssertEqual(harness.credentials.credential, saved, "The saved session is untouched.")
        let runtime = try await XCTUnwrapAsync(await harness.manager.runtime)
        XCTAssertNil(runtime.library, "Nothing syncs until the password is changed.")
        XCTAssertTrue(harness.log.all.isEmpty, "Restoring signs nobody out: \(harness.log.all)")
        await signOutAfterwards(harness)
    }

    /// Before the phone's first unlock the Keychain is closed. Restoring waits, removes nothing,
    /// and opens the session once the phone is unlocked.
    func testRestoreWaitsForTheKeychainToUnlock() async throws {
        let server = makeStubServer()
        server.route("POST", "auth/validateToken", .json(#"{"authStatus":true}"#))
        let saved = credential("alice", on: server)
        let harness = makeHarness(saved, server: server, locked: true)

        await harness.manager.restore()
        var phase = await harness.manager.phase
        XCTAssertEqual(phase, .waitingForUnlock)
        let waiting = await harness.manager.runtime
        XCTAssertNil(waiting)
        await harness.manager.restore()
        phase = await harness.manager.phase
        XCTAssertEqual(phase, .waitingForUnlock, "Restoring again while locked still waits.")

        harness.credentials.unlock()
        harness.unlock.yield()
        try await until("The session did not open after the unlock.") { await harness.manager.phase == .active }
        let runtime = try await XCTUnwrapAsync(await harness.manager.runtime)
        XCTAssertEqual(runtime.credential, saved)
        XCTAssertEqual(harness.credentials.credential, saved)
        XCTAssertTrue(harness.log.all.isEmpty, "Nothing was removed while waiting: \(harness.log.all)")
        XCTAssertEqual(harness.recorder.phases.first, .waitingForUnlock)
        await signOutAfterwards(harness)
    }

    // MARK: - Session checks

    /// A check that can't reach the server keeps the session, and with it the offline library.
    func testOfflineValidationKeepsTheSession() async throws {
        let server = makeStubServer()
        server.route("POST", "auth/validateToken", .transportFailure(.notConnectedToInternet))
        let harness = makeHarness(credential("alice", on: server), server: server)

        await harness.manager.restore()
        try await until("The session was not checked.") { server.requests("POST", "auth/validateToken").count >= 1 }
        let session = try await XCTUnwrapAsync(await harness.manager.runtime)
        session.check.validate()
        try await until("The session was not checked again.") { server.requests("POST", "auth/validateToken").count >= 2 }
        try await Task.sleep(for: .milliseconds(200))

        let phase = await harness.manager.phase
        XCTAssertEqual(phase, .active)
        XCTAssertNotNil(harness.credentials.credential)
        XCTAssertTrue(server.requests("POST", "auth/logout").isEmpty)
        XCTAssertTrue(harness.log.all.isEmpty, "\(harness.log.all)")
        await signOutAfterwards(harness)
    }

    /// Forbidden, a proxy's refusal, and an expiry the second check doesn't confirm never sign out.
    func testForbiddenAndUnconfirmedRefusalsNeverSignOut() async throws {
        let answers: [(String, [StubServer.Response])] = [
            ("forbidden", [.immichError(403, message: "Forbidden")]),
            ("proxy", [.proxyError(401)]),
            ("expired once", [.immichError(401, message: "Invalid user token"), .json(#"{"authStatus":true}"#)]),
        ]
        for (name, responses) in answers {
            let server = makeStubServer()
            server.route("POST", "auth/validateToken", responses: responses)
            let harness = makeHarness(credential("alice", on: server), server: server)
            await harness.manager.restore()
            try await until("\(name): the session was not checked.") { server.requests("POST", "auth/validateToken").count >= responses.count }
            try await Task.sleep(for: .milliseconds(200))

            let phase = await harness.manager.phase
            XCTAssertEqual(phase, .active, name)
            XCTAssertNotNil(harness.credentials.credential, name)
            XCTAssertTrue(harness.log.all.isEmpty, "\(name): \(harness.log.all)")
            await signOutAfterwards(harness)
        }
    }

    /// Immich says the session is gone and the second check agrees: sign-out runs to the end,
    /// though it cancels and waits for the very check that started it, and the sign-in screen
    /// says why.
    func testAnExpiredSessionSignsOutWithoutCancellingItself() async throws {
        let server = makeStubServer()
        server.route("POST", "auth/validateToken", .immichError(401, message: "Invalid user token"))
        server.route("POST", "auth/logout", .json(#"{"successful":true}"#))
        let harness = makeHarness(credential("alice", on: server), server: server)

        await harness.manager.restore()
        try await until("The expired session was not signed out.") { await harness.manager.phase == .signedOut(.sessionExpired) }

        XCTAssertEqual(server.requests("POST", "auth/validateToken").count, 2, "Once, then the second check.")
        XCTAssertEqual(server.requests("POST", "auth/logout").count, 1, "Sign-out reached the server, so nothing cancelled it.")
        XCTAssertNil(harness.credentials.credential)
        XCTAssertEqual(harness.log.all, Self.signOutSteps)
        XCTAssertEqual(harness.recorder.states.last?.message, ServerFailure.sessionExpired(nil).localizedDescription)
        XCTAssertNil(harness.recorder.states.last?.runtime)
    }

    // MARK: - Sign-out

    /// The cast session is revoked and the session logged out while the token still works, before
    /// the credential goes.
    func testSignOutRevokesCastAndLogsOutBeforeTheCredentialIsRemoved() async throws {
        let server = makeStubServer()
        server.route("POST", "auth/validateToken", .json(#"{"authStatus":true}"#))
        server.route("POST", "sessions", .json(#"{"id":"cast-1","token":"cast-token","expiresAt":"2099-01-01T00:00:00.000Z"}"#))
        server.route("DELETE", "sessions/cast-1", .empty())
        server.route("POST", "auth/logout", .json(#"{"successful":true}"#))
        let harness = makeHarness(credential("alice", on: server), server: server)
        let seenAtRemoval = Mutex<[String]>([])
        harness.credentials.onRemove { seenAtRemoval.withLock { $0 = server.requests.map { $0.method + " " + $0.path } } }
        await harness.manager.restore()
        let runtime = try await XCTUnwrapAsync(await harness.manager.runtime)
        _ = try await runtime.castGrants.grant(covering: 0)

        await harness.manager.signOut(.user)

        let seen = seenAtRemoval.withLock { $0 }
        let revoke = try XCTUnwrap(seen.firstIndex(of: "DELETE sessions/cast-1"), "The cast session was revoked before the credential went: \(seen)")
        let logout = try XCTUnwrap(seen.firstIndex(of: "POST auth/logout"), "The session was logged out before the credential went: \(seen)")
        XCTAssertLessThan(revoke, logout, "The revoke needs the token, so it goes first.")
        let log = harness.log.all
        XCTAssertLessThan(try XCTUnwrap(log.firstIndex(of: "endCasting")), try XCTUnwrap(log.firstIndex(of: "removeCredential")))
        XCTAssertTrue(runtime.api.transport.isShutDown)
    }

    /// Sign-out, for either reason, removes exactly its list, in order: what the account kept and
    /// the device-wide services hold for it. Uploads stop as the app stops them, over the
    /// account's backup in the middle of a run. Not on the list, for either reason: the backup
    /// state with its receipts, in which automatic backup is switched off as every earlier build
    /// did; the read-only flag; and the shelf order.
    func testSignOutRemovesExactlyItsCleanupListForEitherReason() async throws {
        // Owner question: keeping thumbnails and network settings after a session expiry. Until it
        // is answered, an expiry removes what an explicit sign-out does.
        XCTAssertEqual(SignOutPolicy(reason: .sessionExpired), SignOutPolicy(reason: .user))
        for reason in [SignOutReason.user, .sessionExpired] {
            let name = "\(reason)"
            let server = makeStubServer()
            // An expiry is answered once the test has filled the offline library.
            let expiry = StubServer.Gate()
            let check: StubServer.Response = reason == .user ? .json(#"{"authStatus":true}"#)
                : StubServer.Response.immichError(401, message: "Invalid user token").waiting(for: expiry)
            server.route("POST", "auth/validateToken", check)
            server.route("POST", "auth/logout", .json(#"{"successful":true}"#))
            let mirror = makeMirror()
            let saved = credential("alice", on: server)
            let backup = try goldenBackup(for: saved)
            turnOnReadOnlyAndOrderShelves(for: saved)
            let environment = copyingBackupState(self.environment(library: true))
            let harness = makeHarness(saved, server: server, environment: environment, mirror: mirror,
                                      uploads: LiveAccountDevice(backup: { backup.coordinator }))
            await harness.manager.restore()
            let runtime = try await XCTUnwrapAsync(await harness.manager.runtime)
            await runtime.importBackupStateInShadow()?.value
            let transfers = TransferStore.url(for: saved.account, in: environment.transfersDirectory)
            XCTAssertTrue(FileManager.default.fileExists(atPath: transfers.path), name)
            let library = try XCTUnwrap(runtime.library)
            try await library.entities.persistCachedServerFeatures(ServerFeatures(passwordLogin: true, oauth: false, smartSearch: true, searchVerification: nil,
                                                                                  ocr: true, facialRecognition: true, map: true, trash: true, sidecar: true,
                                                                                  realtimeTranscoding: false))
            XCTAssertEqual(mirror.read()?.digest, saved.account.digest, name)

            if reason == .user {
                await harness.manager.signOut(.user)
            } else {
                expiry.open()
                try await until("The expired session was not signed out.") { harness.recorder.phases.last == .signedOut(.sessionExpired) }
            }

            XCTAssertEqual(harness.log.all, Self.signOutSteps, name)
            let phase = await harness.manager.phase
            XCTAssertEqual(phase, .signedOut(reason), name)
            let message: String? = reason == .user ? nil : ServerFailure.sessionExpired(nil).localizedDescription
            XCTAssertEqual(harness.recorder.states.last?.message, message, name)
            XCTAssertEqual(harness.recorder.phases.suffix(2), [.signingOut, .signedOut(reason)], name)
            XCTAssertNil(harness.credentials.credential, name)
            XCTAssertEqual(mirror.read()?.digest, "", "\(name): the extensions see nobody signed in.")
            XCTAssertTrue(runtime.authorization.hasEnded, name)
            XCTAssertTrue(runtime.api.transport.isShutDown, name)
            let features = try await library.entities.cachedServerFeatures()
            XCTAssertNil(features, "\(name): the offline library is emptied.")
            let syncOpen = await library.sync.isOpen
            XCTAssertFalse(syncOpen, name)
            XCTAssertEqual(try backup.state(), try Self.backupStateAfterSignOut(keepingAutomaticBackup: false),
                           "\(name): the backup state stays with its receipts, paused, and with automatic backup off.")
            XCTAssertTrue(FileManager.default.fileExists(atPath: transfers.path), "\(name): the transfers database stays, as the backup state does.")
            XCTAssertTrue(ReadOnlyPolicy.isEnabled(server: saved.server, userID: saved.userID), "\(name): the read-only flag stays.")
            XCTAssertEqual(ShelfOrder(scope: saved.account.cacheScope).ids(.albums), ["b", "a"], "\(name): the shelf order stays.")
        }
    }

    /// Uploads stop as the app stops them at sign-out: backup pauses, its batch of transfer
    /// notifications ends and nobody is left signed in to it, while its state stays on disk with
    /// its receipts. Automatic backup is switched off in that state, as every earlier build did,
    /// unless sign-out keeps it, the roadmap's default that waits for the owner's answer: then
    /// signing in to the account again carries on with it.
    func testStoppingUploadsSwitchesAutomaticBackupOffUnlessKept() async throws {
        XCTAssertFalse(SignOutPolicy(reason: .user).keepsAutomaticBackup, "Owner question: until it is answered, sign-out switches it off.")
        XCTAssertFalse(SignOutPolicy(reason: .sessionExpired).keepsAutomaticBackup)
        for keeping in [false, true] {
            let saved = LegacyGoldens.credential
            let backup = try goldenBackup(for: saved)

            await LiveAccountDevice(backup: { backup.coordinator }).stopUploads(keepingAutomaticBackup: keeping)

            XCTAssertFalse(backup.coordinator.preferences.automatic, "Nobody is signed in, so nothing backs up.")
            XCTAssertTrue(backup.coordinator.associations.isEmpty)
            XCTAssertEqual(backup.coordinator.remaining, 0)
            XCTAssertEqual(try backup.state(), try Self.backupStateAfterSignOut(keepingAutomaticBackup: keeping), "keeping: \(keeping)")
            let again = BackupCoordinator()
            try again.load(saved, folder: backup.folder)
            XCTAssertEqual(again.preferences.automatic, keeping, "Signing in again carries on as sign-out left it.")
            XCTAssertEqual(again.associations.count, 2, "The receipts are kept.")
        }
    }

    /// A server the logout can't reach within the budget doesn't hold sign-out up. Here the
    /// preferred address never answers its check, so the logout never gets an address: once the
    /// budget is spent, sign-out goes on, removes everything as usual and sends nothing more.
    func testSignOutGoesOnWithoutTheServerOnceItsBudgetIsSpent() async throws {
        let server = answeringAddressChecks(makeStubServer()), away = makeStubServer()
        let unanswered = StubServer.Gate()
        addTeardownBlock { unanswered.open() }
        away.route("GET", "server/ping", StubServer.Response.json(#"{"res":"pong"}"#).waiting(for: unanswered))
        server.route("POST", "auth/logout", .json(#"{"successful":true}"#))
        let harness = makeHarness(credential("alice", on: server), server: server, environment: environment(validatesSession: false),
                                  network: NetworkConfiguration(alternateEndpoints: [away.baseURL], automaticallySwitchEndpoints: true),
                                  serverSignOutBudget: .milliseconds(300))
        await harness.manager.restore()
        let runtime = try await XCTUnwrapAsync(await harness.manager.runtime)

        let started = ContinuousClock.now
        let signingOut = Task { await harness.manager.signOut(.user) }
        try await until("Sign-out waited for the server past its budget.", timeout: .seconds(3)) {
            harness.recorder.phases.last == .signedOut(.user)
        }
        // A sign-out still waiting for the address waits until the test ends and the check is
        // answered, so it isn't waited for here.
        guard harness.recorder.phases.last == .signedOut(.user) else { return }
        await signingOut.value

        XCTAssertLessThan(ContinuousClock.now - started, .seconds(3))
        XCTAssertEqual(away.requests("GET", "server/ping").count, 1, "The preferred address was still being checked.")
        XCTAssertEqual(harness.log.all, Self.signOutSteps)
        XCTAssertNil(harness.credentials.credential)
        XCTAssertTrue(runtime.api.transport.isShutDown)
        XCTAssertTrue(server.requests("POST", "auth/logout").isEmpty, "Nothing is sent once the budget is spent.")
    }

    /// The address the logout goes to is chosen while uploads stop, so the budget goes to the
    /// logout rather than to checking every address, which can take longer than the budget.
    func testSignOutChoosesTheServersAddressWhileUploadsStop() async throws {
        let server = answeringAddressChecks(makeStubServer()), away = makeStubServer()
        let unreachable = StubServer.Gate(), stopping = StubServer.Gate()
        addTeardownBlock { unreachable.open(); stopping.open() }
        away.route("GET", "server/ping", StubServer.Response.transportFailure(.cannotConnectToHost).waiting(for: unreachable))
        server.route("POST", "auth/logout", .json(#"{"successful":true}"#))
        let harness = makeHarness(credential("alice", on: server), server: server, environment: environment(validatesSession: false),
                                  holdingUploadsStop: stopping,
                                  network: NetworkConfiguration(alternateEndpoints: [away.baseURL], automaticallySwitchEndpoints: true))
        await harness.manager.restore()

        let signingOut = Task { await harness.manager.signOut(.user) }
        try await until("The address was not checked while uploads stopped.") {
            stopping.waiting == 1 && away.requests("GET", "server/ping").count == 1
        }
        unreachable.open()
        stopping.open()
        await signingOut.value

        XCTAssertEqual(server.requests("POST", "auth/logout").count, 1, "The logout reached the server's own address.")
        XCTAssertEqual(harness.log.all, Self.signOutSteps)
    }

    /// A sign-in during sign-out waits for it to finish: the old session is gone, credential
    /// included, before the new one opens.
    func testSignInWaitsForSignOut() async throws {
        let first = makeStubServer(), second = makeStubServer()
        let logout = StubServer.Gate()
        first.route("POST", "auth/validateToken", .json(#"{"authStatus":true}"#))
        first.route("POST", "auth/logout", StubServer.Response.json(#"{"successful":true}"#).waiting(for: logout))
        second.route("POST", "auth/validateToken", .json(#"{"authStatus":true}"#))
        let harness = makeHarness(credential("alice", on: first), server: first)
        await harness.manager.restore()

        let signingOut = Task { await harness.manager.signOut(.user) }
        try await until("Sign-out did not reach the server.") { logout.waiting == 1 }
        let bob = login("bob")
        let signingIn = Task { try await harness.manager.completeSSO(bob, server: second.baseURL) }
        try await Task.sleep(for: .milliseconds(200))
        var phase = await harness.manager.phase
        XCTAssertEqual(phase, .signingOut, "The new session waits.")
        XCTAssertEqual(harness.credentials.credential?.userID, "alice", "Bob's session isn't saved yet.")

        logout.open()
        await signingOut.value
        try await signingIn.value
        phase = await harness.manager.phase
        XCTAssertEqual(phase, .active)
        let runtime = try await XCTUnwrapAsync(await harness.manager.runtime)
        XCTAssertEqual(runtime.credential.userID, bob.userId)
        XCTAssertEqual(harness.recorder.phases.suffix(3), [.signingOut, .signedOut(.user), .active])
        let log = harness.log.all
        XCTAssertLessThan(try XCTUnwrap(log.firstIndex(of: "clearDiagnostics")), try XCTUnwrap(log.firstIndex(of: "save(\(bob.userId))")),
                          "The new credential is saved after sign-out has finished: \(log)")
        await signOutAfterwards(harness)
    }

    /// Signing out and straight back in to the same account opens a new runtime only once the
    /// old one has shut down, and the new one works.
    func testTheSameAccountReopensOnlyAfterItsRuntimeShutDown() async throws {
        let server = makeStubServer()
        let logout = StubServer.Gate()
        server.route("POST", "auth/validateToken", .json(#"{"authStatus":true}"#))
        server.route("POST", "auth/logout", StubServer.Response.json(#"{"successful":true}"#).waiting(for: logout))
        server.route("GET", "users/me", .json(#"{"id":"alice","name":"Alice","email":"alice@example.test"}"#))
        let saved = credential("alice", on: server)
        let harness = makeHarness(saved, server: server, environment: environment(library: true))
        await harness.manager.restore()
        let old = try await XCTUnwrapAsync(await harness.manager.runtime)
        let shutDownWhenReopened = Mutex<(transport: Bool, authorization: Bool)?>(nil)
        harness.recorder.observe = { state in
            guard let runtime = state.runtime, runtime.id != old.id else { return }
            shutDownWhenReopened.withLock { $0 = (old.api.transport.isShutDown, old.authorization.hasEnded) }
        }

        let signingOut = Task { await harness.manager.signOut(.user) }
        try await until("Sign-out did not reach the server.") { logout.waiting == 1 }
        let again = LoginResponse(accessToken: "alice-second-session", userId: saved.userID, userEmail: "alice@example.test", name: "Alice",
                                  isAdmin: false, shouldChangePassword: false, profileImagePath: nil, isOnboarded: true)
        let signingIn = Task { try await harness.manager.completeSSO(again, server: server.baseURL) }
        logout.open()
        await signingOut.value
        try await signingIn.value

        let reopened = try XCTUnwrap(shutDownWhenReopened.withLock { $0 }, "The account reopened.")
        XCTAssertTrue(reopened.transport, "The old transport had shut down.")
        XCTAssertTrue(reopened.authorization, "The old authorization had ended.")
        let new = try await XCTUnwrapAsync(await harness.manager.runtime)
        XCTAssertNotEqual(new.id, old.id)
        XCTAssertEqual(new.credential.account, old.credential.account)
        XCTAssertFalse(new.api.transport.isShutDown)
        XCTAssertFalse(new.authorization.hasEnded)
        XCTAssertNotNil(new.library)
        let user = try await new.api.currentUser()
        XCTAssertEqual(user.id, "alice", "The reopened account works.")
        let reopenedRequest = try XCTUnwrap(server.requests("GET", "users/me").last)
        XCTAssertEqual(reopenedRequest.headers["Authorization"], "Bearer alice-second-session")
        await signOutAfterwards(harness)
    }

    /// Switching accounts never lets the previous account's results reach the next: its requests
    /// in flight end without an answer, its sync tells no screen anything, and nothing made under
    /// its authorization is current for the next account.
    func testAccountSwitchNeverServesThePreviousAccountsResults() async throws {
        let first = makeStubServer(), second = makeStubServer()
        let albums = StubServer.Gate(), stream = StubServer.Gate()
        first.route("POST", "auth/validateToken", .json(#"{"authStatus":true}"#))
        first.route("POST", "auth/logout", .json(#"{"successful":true}"#))
        first.route("GET", "albums", StubServer.Response.json(Self.albums("Alice's trip")).waiting(for: albums))
        first.route("POST", "sync/stream", StubServer.Response(status: 200, headers: ["Content-Type": "application/jsonlines+json"],
                                                             body: Data(Self.completeStream.utf8)).waiting(for: stream))
        second.route("POST", "auth/validateToken", .json(#"{"authStatus":true}"#))
        second.route("GET", "albums", .json(Self.albums("Bob's garden")))
        let harness = makeHarness(credential("alice", on: first), server: first, environment: environment(library: true), foreground: true)
        await harness.manager.restore()
        let alice = try await XCTUnwrapAsync(await harness.manager.runtime)
        let aliceEpoch = alice.authorization.snapshot.epoch
        let late = Task { try await alice.api.albums() }
        try await until("Alice's requests did not start.") { albums.waiting == 1 && stream.waiting == 1 }
        let aliceChanges = Mutex(0)
        let observer = NotificationCenter.default.addObserver(forName: .ilyichLibraryChanged, object: nil, queue: nil) { note in
            if note.userInfo?["scope"] as? String == alice.api.cacheScope { aliceChanges.withLock { $0 += 1 } }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        await harness.manager.signOut(.user)
        try await harness.manager.completeSSO(login("bob"), server: second.baseURL)
        albums.open()
        stream.open()

        do {
            let served = try await late.value
            XCTFail("Alice's albums arrived after the switch: \(served.map(\.albumName))")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled, "\(error)")
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(aliceChanges.withLock { $0 }, 0, "Alice's sync told no screen anything.")
        let bob = try await XCTUnwrapAsync(await harness.manager.runtime)
        XCTAssertEqual(bob.credential.userID, "bob")
        XCTAssertFalse(bob.api === alice.api)
        XCTAssertFalse(bob.pipeline === alice.pipeline)
        XCTAssertNotEqual(bob.api.cacheScope, alice.api.cacheScope)
        let served = try await bob.api.albums()
        XCTAssertEqual(served.map(\.albumName), ["Bob's garden"])
        let aliceSyncOpen = await alice.library?.sync.isOpen
        XCTAssertEqual(aliceSyncOpen, false)
        XCTAssertFalse(alice.authorization.isCurrent(aliceEpoch))
        let counted = Fenced<[String]>(epoch: aliceEpoch, value: ["Alice's trip"])
        XCTAssertNil(counted.value(ifCurrent: bob.authorization.snapshot.epoch), "Nothing made under Alice's authorization is current for Bob.")
        XCTAssertFalse(bob.authorization.isCurrent(aliceEpoch))
        await signOutAfterwards(harness)
    }

    // MARK: - Session

    /// The session shows what the manager publishes, and a read-only toggle changes the controls
    /// at once while uploads follow afterwards.
    func testTheSessionShowsTheAccountAndReadOnlyChangesAtOnce() async throws {
        let server = makeStubServer()
        server.route("POST", "auth/validateToken", .json(#"{"authStatus":true}"#))
        server.route("POST", "auth/logout", .json(#"{"successful":true}"#))
        let log = AccountEventLog()
        let saved = credential("alice", on: server)
        let session = AccountSession(environment: environment(), dependencies: dependencies(saved, server: server, log: log),
                                     presence: AppPresence(isForeground: false))
        addTeardownBlock {
            let key = AccountStoragePaths(AccountID(server: saved.server, userID: saved.userID)).readOnlyKey
            (AppGroup.defaults ?? .standard).removeObject(forKey: key)
        }
        XCTAssertTrue(session.isRestoring)

        await session.restore()
        XCTAssertEqual(session.phase, .active)
        XCTAssertEqual(session.api?.userID, saved.userID)
        XCTAssertEqual(session.authorization?.readOnly, false)

        session.setReadOnly(true)
        XCTAssertEqual(session.authorization?.readOnly, true, "The controls follow at once.")
        XCTAssertTrue(session.isApplyingReadOnly)
        try await until("Uploads did not follow.") { !session.isApplyingReadOnly }
        XCTAssertEqual(log.all, ["readOnly(true)"])
        session.setReadOnly(false)
        try await until("Uploads did not follow.") { !session.isApplyingReadOnly }

        session.pendingLink = .album("00000000-0000-4000-8000-000000000003")
        await session.signOut()
        XCTAssertEqual(session.phase, .signedOut(.user))
        XCTAssertNil(session.runtime)
        XCTAssertNil(session.authorization)
        XCTAssertNil(session.pendingLink, "A link for the account that signed out is dropped.")
    }

    /// The account's backup state is copied into its transfers database when the account opens in
    /// front and each time the app comes out of the background, and compared again when Diagnostics
    /// asks; never when state.json is written, which BackupCoordinator does several times per photo.
    /// A background launch, for a backup window or a finished upload, leaves it for the foreground.
    func testBackupStateIsCopiedWhenTheAppComesForwardNeverOnWrites() async throws {
        let server = makeStubServer()
        server.route("POST", "auth/validateToken", .json(#"{"authStatus":true}"#))
        server.route("POST", "auth/logout", .json(#"{"successful":true}"#))
        let saved = credential("alice", on: server)
        let environment = copyingBackupState(self.environment())
        let folder = try XCTUnwrap(environment.backupContainer).appendingPathComponent(AccountStoragePaths(saved.account).backup, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stateFile = folder.appendingPathComponent("state.json")
        try FixtureLoader.data("backup/state-current.json").write(to: stateFile)
        let dependencies = self.dependencies(saved, server: server, log: AccountEventLog())
        let device = try XCTUnwrap(dependencies.device as? FakeAccountDevice)
        let session = AccountSession(environment: environment, dependencies: dependencies, presence: AppPresence(isForeground: false))

        await session.restore()
        XCTAssertEqual(session.phase, .active)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(device.transferImports.isEmpty, "Opened in the background, nothing is copied.")

        session.sceneChanged(.active)
        try await until("Coming forward didn't copy the backup state.") { device.transferImports.count == 1 }
        XCTAssertEqual(device.transferImports.last?.outcome, .imported)
        XCTAssertEqual(device.transferImports.last?.comparison?.total, 0)
        let database = TransferStore.url(for: saved.account, in: environment.transfersDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.path))

        // BackupCoordinator writes state.json, and Control Center comes and goes: nothing is copied.
        try FixtureLoader.data("backup/state-9780e9625.json").write(to: stateFile, options: .atomic)
        session.sceneChanged(.inactive)
        session.sceneChanged(.active)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(device.transferImports.count, 1)
        session.sceneChanged(.background)
        session.sceneChanged(.active)
        try await until("Coming forward again didn't copy the changed state.") { device.transferImports.count == 2 }
        XCTAssertEqual(device.transferImports.last?.outcome, .imported)
        XCTAssertEqual(device.transferImports.last?.comparison?.total, 0)

        await session.compareBackupRecords()
        XCTAssertEqual(device.transferImports.count, 3, "Diagnostics compares again.")
        XCTAssertEqual(device.transferImports.last?.outcome, .unchanged)
        XCTAssertEqual(device.transferImports.last?.comparison?.total, 0)

        await session.signOut()
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.path))
        XCTAssertEqual(try Data(contentsOf: stateFile), try FixtureLoader.data("backup/state-9780e9625.json"), "state.json is only ever read.")
    }

    /// The sign-in screen asks the server how it signs in only once typing pauses, and signs in
    /// through the manager.
    func testSignInAsksTheServerOnceTypingPausesAndSignsIn() async throws {
        let server = makeStubServer()
        server.route("GET", "server/features", .json(#"{"passwordLogin":true,"oauth":true,"smartSearch":true,"ocr":true,"facialRecognition":true,"map":true,"trash":true,"sidecar":true,"realtimeTranscoding":false}"#))
        server.route("POST", "auth/login", .json(#"{"accessToken":"carol-session","userId":"carol","userEmail":"carol@example.test","name":"Carol","isAdmin":false,"shouldChangePassword":false,"profileImagePath":"","isOnboarded":true}"#, status: 201))
        server.route("POST", "auth/validateToken", .json(#"{"authStatus":true}"#))
        server.route("POST", "auth/logout", .json(#"{"successful":true}"#))
        let session = AccountSession(environment: environment(), dependencies: dependencies(nil, server: server, log: AccountEventLog()),
                                     presence: AppPresence(isForeground: false))
        await session.restore()
        XCTAssertEqual(session.phase, .signedOut(nil))
        let model = SignInModel(session: session)
        let address = server.baseURL.absoluteString
        model.server = String(address.dropLast(4))
        model.serverChanged()
        model.server = address
        model.serverChanged()
        try await until("The server was not asked.") { model.features != nil }
        XCTAssertEqual(server.requests("GET", "server/features").count, 1, "Only the address typing paused on is asked.")
        XCTAssertEqual(model.features?.oauth, true)

        model.email = " carol@example.test "
        model.password = "secret"
        XCTAssertTrue(model.signIn())
        try await until("Signing in did not open the account.") { session.phase == .active }
        XCTAssertEqual(session.api?.userID, "carol")
        let body = try XCTUnwrap(server.requests("POST", "auth/login").first?.body)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: String], ["email": "carol@example.test", "password": "secret"])
        try await until("The password was kept.") { model.password.isEmpty }

        // The browsing cache is cleared through the account, and the feed hears of it.
        let scope = try XCTUnwrap(session.api?.cacheScope)
        let reset = expectation(forNotification: .ilyichCachesReset, object: nil) { $0.userInfo?["scope"] as? String == scope }
        await session.clearBrowsingCache()
        await fulfillment(of: [reset], timeout: 2)
        await session.signOut()
    }

    /// Only a UI test launch runs against the fixture, and it never reaches the device's storage.
    func testOnlyAUITestLaunchUsesTheFixture() {
        XCTAssertNil(AccountEnvironment.uiTest(arguments: ["Ilyich"]))
        XCTAssertTrue(AccountEnvironment.live.usesDeviceStorage)
        XCTAssertTrue(AccountEnvironment.live.syncsLibrary)
        XCTAssertNil(AccountEnvironment.live.fixtureCredential)

        let signedOut = try? XCTUnwrap(AccountEnvironment.uiTest(arguments: ["Ilyich", "--ui-testing"]))
        XCTAssertEqual(signedOut?.usesDeviceStorage, false)
        XCTAssertNil(signedOut?.fixtureCredential)
        XCTAssertTrue(signedOut?.credentialStore() is EphemeralCredentialStore)

        let library = AccountEnvironment.uiTest(arguments: ["--ui-testing", "--ui-testing-library", "--ui-testing-shelves-stay-open"])
        XCTAssertEqual(library?.fixtureCredential?.token, "ui-test-session")
        XCTAssertEqual(library?.keepsShelvesOpen, true)
        XCTAssertEqual(library?.syncsLibrary, false)
        XCTAssertEqual(library?.usesDevicePhotos, false)
        XCTAssertEqual(library?.importsBackupState, false, "Nor its backup state.")
        XCTAssertTrue(AccountEnvironment.live.importsBackupState)
        XCTAssertNil(AccountEnvironment.live.transfersDirectory)
        XCTAssertNil(AccountEnvironment.live.backupContainer)
        XCTAssertEqual(try library?.credentialStore().load()?.userID, AccountEnvironment.fixtureUserID)
        let people = AccountEnvironment.uiTest(arguments: ["--ui-testing", "--ui-testing-library", "--ui-testing-many-people"])
        XCTAssertEqual(people?.fixtureCredential?.token, "ui-test-many-people")
    }

    /// An account's backup is taken up each time the account becomes active, not only at launch
    /// (REBUILD_ROADMAP.md, Critic's corrections, B8): signing out and in as someone else without
    /// relaunching shows the new account's backup, with no screen calling activate().
    func testSigningOutAndBackInShowsTheNewAccountsBackupState() async throws {
        let server = makeStubServer()
        server.route("POST", "auth/validateToken", .json(#"{"authStatus":true}"#))
        server.route("POST", "auth/logout", .json(#"{"successful":true}"#))
        let alice = credential("alice", on: server), bob = credential("bob", on: server)
        let container = temporaryDirectory()
        var aliceState = LegacyGoldens.backupState()
        aliceState.paused = true
        aliceState.transferNotification = nil
        try writeBackupState(aliceState, for: alice, in: container)
        var bobState = BackupState()
        bobState.confirmed = ["B0B00000-0000-4000-8000-000000000001/L0/001": Date(timeIntervalSinceReferenceDate: 700_000_000)]
        bobState.preferences.triggerDelay = 300
        try writeBackupState(bobState, for: bob, in: container)
        var environment = self.environment()
        environment.usesDevicePhotos = true
        environment.backupContainer = container
        let coordinator = BackupCoordinator()
        let harness = makeHarness(alice, server: server, environment: environment, uploads: LiveAccountDevice(backup: { coordinator }))
        let store = BackupStore(backend: LegacyCoordinatorBackend(coordinator: coordinator), photos: .unavailable, debounce: .zero)

        await harness.manager.restore()
        try await until("The backup screens did not show Alice's backup.") { store.confirmed == 3 && store.preferences.triggerDelay == 120 }
        XCTAssertEqual(coordinator.activeScope, alice.account.digest)
        XCTAssertEqual(store.failures.count, 1)

        await harness.manager.signOut(.user)
        try await until("Signing out did not empty the backup screens.") { store.confirmed == 0 && store.failures.isEmpty }
        try await harness.manager.completeSSO(login("bob"), server: server.baseURL)

        try await until("The backup screens did not show Bob's backup.") { store.confirmed == 1 && store.preferences.triggerDelay == 300 }
        XCTAssertEqual(coordinator.activeScope, bob.account.digest)
        XCTAssertEqual(harness.log.all.filter { $0.hasPrefix("activateBackup") }, ["activateBackup(alice)", "activateBackup(bob)"])
        await signOutAfterwards(harness)
    }

    // MARK: - Support

    private func writeBackupState(_ state: BackupState, for credential: StoredCredential, in container: URL) throws {
        let folder = container.appendingPathComponent(AccountStoragePaths(credential.account).backup, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: folder.appendingPathComponent("state.json"))
    }

    /// What an ordinary sign-out records, in order.
    private static let signOutSteps = ["stopUploads", "endCasting", "removeCredential", "reloadWidgets", "clearNotifications",
                                       "removeLockedPIN", "clearTimelineCaches", "removeNetworkSettings", "clearDiagnostics"]

    private static let completeStream = #"{"type":"SyncCompleteV1","data":{},"ack":"SyncCompleteV1|done"}"# + "\n"

    private static func albums(_ name: String) -> String {
        #"[{"id":"00000000-0000-4000-8000-000000000003","albumName":"\#(name)","assetCount":1,"shared":false,"albumUsers":[],"updatedAt":"2026-12-01T12:00:00Z"}]"#
    }

    private func credential(_ user: String, on server: StubServer) -> StoredCredential {
        StoredCredential(server: server.baseURL, token: user + "-session", userID: user, name: user.capitalized)
    }

    private func login(_ user: String) -> LoginResponse {
        LoginResponse(accessToken: user + "-session", userId: user, userEmail: user + "@example.test", name: user.capitalized,
                      isAdmin: false, shouldChangePassword: false, profileImagePath: nil, isOnboarded: true)
    }

    private func environment(library: Bool = false, validatesSession: Bool = true) -> AccountEnvironment {
        var environment = AccountEnvironment()
        environment.usesDevicePhotos = false
        environment.syncsLibrary = library
        environment.validatesSession = validatesSession
        environment.importsBackupState = false
        if library { environment.libraryDirectory = temporaryDirectory() }
        return environment
    }

    /// `environment`, copying the backup state into a transfers database, both in folders of the test's.
    private func copyingBackupState(_ environment: AccountEnvironment) -> AccountEnvironment {
        var environment = environment
        environment.importsBackupState = true
        environment.transfersDirectory = temporaryDirectory()
        environment.backupContainer = temporaryDirectory()
        return environment
    }

    /// `uploads` stops uploads as the app does; `uploadsStop` holds stopping them back until the
    /// test opens it.
    private func dependencies(_ credential: StoredCredential?, server: StubServer, log: AccountEventLog, locked: Bool = false,
                              mirror: AuthorizationMirror? = nil, unlockEvents: AsyncStream<Void> = AsyncStream { $0.finish() },
                              uploads: LiveAccountDevice? = nil, uploadsStop: StubServer.Gate? = nil,
                              network: NetworkConfiguration = NetworkConfiguration(), serverSignOutBudget: Duration = .seconds(3)) -> AccountDependencies {
        let store = TestCredentialStore(credential, log: log, locked: locked)
        let clients = AccountClients { address, credential, purpose in
            let authorization: AuthorizationState? = if case .session(let state) = purpose { state } else { nil }
            return try APIClient(baseURL: address, accessToken: credential?.token, userID: credential?.userID, sessionConfiguration: server.configuration(),
                                 networkConfiguration: network, wifiName: NoWiFi(), authorization: authorization)
        }
        return AccountDependencies(credentials: store, mirror: mirror, device: FakeAccountDevice(log: log, uploads: uploads, uploadsStop: uploadsStop),
                                   clients: clients, unlockEvents: { unlockEvents }, expiryRecheckDelay: .milliseconds(20),
                                   serverSignOutBudget: serverSignOutBudget, backupStateCopyDelay: .milliseconds(20))
    }

    private func makeHarness(_ credential: StoredCredential?, server: StubServer, environment: AccountEnvironment? = nil,
                             locked: Bool = false, foreground: Bool = false, mirror: AuthorizationMirror? = nil,
                             uploads: LiveAccountDevice? = nil, holdingUploadsStop uploadsStop: StubServer.Gate? = nil,
                             network: NetworkConfiguration = NetworkConfiguration(), serverSignOutBudget: Duration = .seconds(3)) -> AccountHarness {
        let log = AccountEventLog()
        let (events, unlock) = AsyncStream.makeStream(of: Void.self)
        let dependencies = dependencies(credential, server: server, log: log, locked: locked, mirror: mirror, unlockEvents: events,
                                        uploads: uploads, uploadsStop: uploadsStop, network: network, serverSignOutBudget: serverSignOutBudget)
        let harness = AccountHarness(log: log, credentials: dependencies.credentials as! TestCredentialStore, unlock: unlock)
        harness.presence.isForeground = foreground
        let recorder = harness.recorder
        harness.manager = AccountManager(environment: environment ?? self.environment(), dependencies: dependencies,
                                         presence: harness.presence) { recorder.record($0) }
        return harness
    }

    /// Ends a test's session, so its media and caches go with it.
    private func signOutAfterwards(_ harness: AccountHarness) async {
        await harness.manager.signOut(.user)
    }

    /// `server`, answering the check of which address answers as Immich does.
    private func answeringAddressChecks(_ server: StubServer) -> StubServer {
        server.route("GET", "server/ping", .json(#"{"res":"pong"}"#))
        server.route("GET", "users/me", .immichError(401, message: "Authentication required"))
        return server
    }

    /// `saved`'s backup, loaded as the app loads it, from the golden state of a backup in the
    /// middle of a run: a queue, a stage in flight, receipts, failures and a notification batch.
    private func goldenBackup(for saved: StoredCredential) throws -> GoldenBackup {
        let folder = temporaryDirectory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FixtureLoader.data("backup/state-current.json").write(to: folder.appendingPathComponent("state.json"))
        let coordinator = BackupCoordinator()
        try coordinator.load(saved, folder: folder)
        XCTAssertTrue(coordinator.preferences.automatic)
        XCTAssertEqual(coordinator.associations.count, 2)
        return GoldenBackup(coordinator: coordinator, folder: folder)
    }

    /// The golden backup state as sign-out leaves it: paused, its notification batch ended, and
    /// automatic backup off unless kept. Everything else, receipts included, is as it was.
    private static func backupStateAfterSignOut(keepingAutomaticBackup: Bool) throws -> String {
        var state = LegacyGoldens.backupState()
        state.paused = true
        state.transferNotification = nil
        state.preferences.automatic = keepingAutomaticBackup
        return try FixtureLoader.canonicalJSON(JSONEncoder().encode(state), unorderedArrays: LegacyGoldens.stateSets)
    }

    /// Turns `saved`'s read-only flag on and orders its album shelf, until the test ends.
    private func turnOnReadOnlyAndOrderShelves(for saved: StoredCredential) {
        ReadOnlyPolicy.setEnabled(true, server: saved.server, userID: saved.userID)
        ShelfOrder(scope: saved.account.cacheScope).save(["b", "a"], for: .albums)
        addTeardownBlock {
            (AppGroup.defaults ?? .standard).removeObject(forKey: AccountStoragePaths(saved.account).readOnlyKey)
            for key in UserDefaults.standard.dictionaryRepresentation().keys
            where key.hasPrefix("shelfOrder.") && key.hasSuffix(saved.account.cacheScope) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    private func makeMirror() -> AuthorizationMirror {
        let suite = "ilyich.tests.account." + UUID().uuidString
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return AuthorizationMirror(appGroup: suite)
    }

    private func temporaryDirectory() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AccountManagerTests-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func until(_ message: String, timeout: Duration = .seconds(5), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { return XCTFail(message) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }
}

/// A manager over fakes, and what it published.
@MainActor final class AccountHarness {
    let log: AccountEventLog
    let credentials: TestCredentialStore
    let unlock: AsyncStream<Void>.Continuation
    let presence = AppPresence(isForeground: false)
    let recorder = StateRecorder()
    var manager: AccountManager!

    init(log: AccountEventLog, credentials: TestCredentialStore, unlock: AsyncStream<Void>.Continuation) {
        self.log = log
        self.credentials = credentials
        self.unlock = unlock
    }
}

/// The states a manager published, in order.
@MainActor final class StateRecorder {
    private(set) var states: [AccountState] = []
    var observe: ((AccountState) -> Void)?

    var phases: [AccountPhase] { states.map(\.phase) }

    func record(_ state: AccountState) {
        states.append(state)
        observe?(state)
    }
}

/// What the account layer did, in order, across the fake device and the credential store.
final class AccountEventLog: Sendable {
    private let events = Mutex<[String]>([])

    func append(_ event: String) { events.withLock { $0.append(event) } }
    var all: [String] { events.withLock { $0 } }
}

/// An account's backup in a folder of the test's, and its state.json as it is now.
struct GoldenBackup {
    let coordinator: BackupCoordinator
    let folder: URL

    /// state.json, canonical.
    func state() throws -> String {
        try FixtureLoader.canonicalJSON(Data(contentsOf: folder.appendingPathComponent("state.json")), unorderedArrays: LegacyGoldens.stateSets)
    }
}

/// The device-wide services, recording what they are asked. With `uploads`, uploads stop as the
/// app stops them; with `uploadsStop`, only once the test opens it.
final class FakeAccountDevice: AccountDevice {
    let log: AccountEventLog
    private let uploads: LiveAccountDevice?
    private let uploadsStop: StubServer.Gate?

    init(log: AccountEventLog, uploads: LiveAccountDevice? = nil, uploadsStop: StubServer.Gate? = nil) {
        self.log = log
        self.uploads = uploads
        self.uploadsStop = uploadsStop
    }

    func activateBackup(for credential: StoredCredential, container: URL?) async {
        log.append("activateBackup(\(credential.userID))")
        await uploads?.activateBackup(for: credential, container: container)
    }
    func stopUploads(keepingAutomaticBackup: Bool) async {
        log.append(keepingAutomaticBackup ? "stopUploads(keepingAutomaticBackup)" : "stopUploads")
        await uploadsStop?.wait()
        await uploads?.stopUploads(keepingAutomaticBackup: keepingAutomaticBackup)
    }
    func endCasting() async { log.append("endCasting") }
    func reloadWidgets() async { log.append("reloadWidgets") }
    func clearNotifications() async { log.append("clearNotifications") }
    func removeLockedPIN(scope: String) async { log.append("removeLockedPIN") }
    func removeNetworkSettings(server: URL) async throws { log.append("removeNetworkSettings") }
    func clearTimelineCaches(scope: String) async { log.append("clearTimelineCaches") }
    func clearDiagnostics() async { log.append("clearDiagnostics") }
    func readOnlyChanged(_ enabled: Bool) async { log.append("readOnly(\(enabled))") }

    /// The backup state imports reported, in order. They stay out of the event log.
    private let imports = Mutex<[LegacyImportReport]>([])
    var transferImports: [LegacyImportReport] { imports.withLock { $0 } }
    func recordTransferImport(_ report: LegacyImportReport) async { imports.withLock { $0.append(report) } }
}

/// A credential kept in memory that records saves and removals, and can stand for a Keychain
/// that is still locked.
final class TestCredentialStore: CredentialStore {
    private let state: Mutex<(credential: StoredCredential?, locked: Bool)>
    private let removal = Mutex<(@Sendable () -> Void)?>(nil)
    private let log: AccountEventLog

    init(_ credential: StoredCredential?, log: AccountEventLog, locked: Bool = false) {
        state = Mutex((credential, locked))
        self.log = log
    }

    var credential: StoredCredential? { state.withLock { $0.credential } }
    func unlock() { state.withLock { $0.locked = false } }
    /// Runs `action` as the credential is removed.
    func onRemove(_ action: @escaping @Sendable () -> Void) { removal.withLock { $0 = action } }

    func load() throws(CredentialError) -> StoredCredential? {
        let (credential, locked) = state.withLock { ($0.credential, $0.locked) }
        if locked { throw .locked }
        return credential
    }

    func save(_ credential: StoredCredential) throws(CredentialError) {
        state.withLock { $0.credential = credential }
        log.append("save(\(credential.userID))")
    }

    func remove() throws(CredentialError) {
        removal.withLock { $0 }?()
        state.withLock { $0.credential = nil }
        log.append("removeCredential")
    }
}
