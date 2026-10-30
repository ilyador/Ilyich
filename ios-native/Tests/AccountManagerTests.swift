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

    // MARK: - Server version

    /// Sign-in refuses a server older than the app needs, before the password goes out: an older
    /// release, a release candidate of the oldest one, and one too old to say its version. The
    /// oldest release itself, and a newer one, sign in.
    func testSignInRefusesAServerOlderThanTheAppNeeds() async throws {
        let refused: [(String, StubServer.Response, ServerVersion?)] = [
            ("older", .json(#"{"major":3,"minor":2,"patch":4,"prerelease":null}"#), ServerVersion(major: 3, minor: 2, patch: 4)),
            ("candidate", .json(#"{"major":3,"minor":3,"patch":0,"prerelease":2}"#), ServerVersion(major: 3, minor: 3, patch: 0, prerelease: 2)),
            ("unversioned", .immichError(404, message: "Cannot GET /api/server/version"), nil),
        ]
        for (name, answer, version) in refused {
            let server = makeStubServer()
            server.route("GET", "server/version", answer)
            server.route("POST", "auth/login", .json(Self.loginJSON("carol"), status: 201))
            let harness = makeHarness(nil, server: server)
            await harness.manager.restore()
            do {
                try await harness.manager.signIn(server: server.baseURL.absoluteString, email: "carol@example.test", password: "secret")
                XCTFail("\(name): an older server was signed in to.")
            } catch let error as UnsupportedServer {
                XCTAssertEqual(error, UnsupportedServer(version: version), name)
                XCTAssertTrue(error.localizedDescription.contains("needs version 3.3.0 or later"), name)
            }
            do {
                _ = try await harness.manager.signInClient(for: server.baseURL)
                XCTFail("\(name): single sign-on started on an older server.")
            } catch is UnsupportedServer {}
            XCTAssertTrue(server.requests("POST", "auth/login").isEmpty, "\(name): the password never goes out.")
            XCTAssertNil(harness.credentials.credential, name)
            let phase = await harness.manager.phase
            XCTAssertEqual(phase, .signedOut(nil), name)
        }
        for (name, answer) in [("oldest", #"{"major":3,"minor":3,"patch":0,"prerelease":null}"#), ("old server's shape", #"{"major":4,"minor":0,"patch":0}"#)] {
            let server = makeStubServer()
            server.route("GET", "server/version", .json(answer))
            server.route("POST", "auth/login", .json(Self.loginJSON("carol"), status: 201))
            server.route("POST", "auth/validateToken", .json(#"{"authStatus":true}"#))
            let harness = makeHarness(nil, server: server)
            await harness.manager.restore()
            let client = try await harness.manager.signInClient(for: server.baseURL)
            await client.shutdown()
            try await harness.manager.signIn(server: server.baseURL.absoluteString, email: "carol@example.test", password: "secret")
            let phase = await harness.manager.phase
            XCTAssertEqual(phase, .active, name)
            await signOutAfterwards(harness)
        }
    }

    /// A saved session whose server now runs an older release is refused when its check reaches
    /// the server: the account closes with the sign-in screen naming the release needed, and
    /// keeps its saved session and everything else for the next launch. Nothing signs out.
    func testAReconnectingSessionRefusesAnOlderServerAndKeepsEverything() async throws {
        let server = makeStubServer()
        server.route("POST", "auth/validateToken", .json(#"{"authStatus":true}"#))
        server.route("GET", "server/version", .json(#"{"major":3,"minor":2,"patch":4,"prerelease":null}"#))
        let saved = credential("alice", on: server)
        let harness = makeHarness(saved, server: server)

        await harness.manager.restore()
        try await until("The older server was not refused.") { await harness.manager.phase == .signedOut(nil) }

        let message = harness.recorder.states.last?.message
        XCTAssertEqual(message, "This server runs version 3.2.4. Ilyich needs version 3.3.0 or later.")
        XCTAssertFalse(message?.contains("Immich") ?? true)
        XCTAssertNil(harness.recorder.states.last?.runtime)
        XCTAssertEqual(harness.credentials.credential, saved, "The saved session stays for the next launch.")
        XCTAssertTrue(server.requests("POST", "auth/logout").isEmpty, "Nothing signs out.")
        XCTAssertTrue(harness.log.all.isEmpty, "Nothing of the account is removed: \(harness.log.all)")
    }

    /// A session whose server can't say its version, or can't be asked, is let be.
    func testAReconnectingSessionKeepsAServerThatCantSayItsVersion() async throws {
        for (name, answer) in [("unversioned", StubServer.Response.immichError(404, message: "Not found")),
                               ("offline", .transportFailure(.notConnectedToInternet))] {
            let server = makeStubServer()
            server.route("POST", "auth/validateToken", .json(#"{"authStatus":true}"#))
            server.route("GET", "server/version", answer)
            let harness = makeHarness(credential("alice", on: server), server: server)
            await harness.manager.restore()
            try await until("\(name): the version was not asked.") { !server.requests("GET", "server/version").isEmpty }
            try await Task.sleep(for: .milliseconds(200))
            let phase = await harness.manager.phase
            XCTAssertEqual(phase, .active, name)
            await signOutAfterwards(harness)
        }
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
    /// the device-wide services hold for it. Not on the list, for either reason: the transfers
    /// database with its receipts (BootTests pins what the engine does to it at sign-out), the
    /// read-only flag and the shelf order.
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
            turnOnReadOnlyAndOrderShelves(for: saved)
            let environment = keepingTransfers(self.environment(library: true))
            let harness = makeHarness(saved, server: server, environment: environment, mirror: mirror)
            await harness.manager.restore()
            let runtime = try await XCTUnwrapAsync(await harness.manager.runtime)
            _ = await runtime.prepareTransfers()
            let transfers = TransferStore.url(for: saved.account, in: environment.transfersDirectory)
            XCTAssertTrue(FileManager.default.fileExists(atPath: transfers.path), name)
            let library = try XCTUnwrap(runtime.library)
            try await library.entities.persistCachedServerFeatures(ServerFeatures(passwordLogin: true, oauth: false, smartSearch: true, searchVerification: nil,
                                                                                  ocr: true, facialRecognition: true, map: true, trash: true, sidecar: true,
                                                                                  realtimeTranscoding: false))
            XCTAssertEqual(mirror.read()?.digest, saved.account.digest, name)
            // The account's grid thumbnails, in Application Support since T8.
            let thumbnails = runtime.pipeline.thumbnails
            await thumbnails.store(Data(name.utf8), assetID: "asset", revision: "1")
            let thumbnail = thumbnails.url(assetID: "asset", revision: "1")
            XCTAssertTrue(thumbnail.path.contains("/Library/Application Support/IlyichThumbnails/"), "\(name): \(thumbnail.path)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnail.path), name)

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
            XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnails.directory.path), "\(name): the account's thumbnails are removed.")
            XCTAssertTrue(FileManager.default.fileExists(atPath: transfers.path), "\(name): the transfers database stays.")
            XCTAssertTrue(ReadOnlyPolicy.isEnabled(server: saved.server, userID: saved.userID), "\(name): the read-only flag stays.")
            XCTAssertEqual(ShelfOrder(scope: saved.account.cacheScope).ids(.albums), ["b", "a"], "\(name): the shelf order stays.")
        }
    }

    /// Clear browsing cache (Settings, Diagnostics) keeps the account's thumbnails in Application
    /// Support, with coverage's position and counts, so coverage downloads nothing again (G2).
    /// Diagnostics shows them against their cap. The account stays signed in, and signing out
    /// still removes them.
    func testClearingTheBrowsingCacheKeepsTheThumbnails() async throws {
        let server = makeStubServer()
        server.route("POST", "auth/validateToken", .json(#"{"authStatus":true}"#))
        server.route("POST", "auth/logout", .json(#"{"successful":true}"#))
        let harness = makeHarness(credential("alice", on: server), server: server)
        await harness.manager.restore()
        let runtime = try await XCTUnwrapAsync(await harness.manager.runtime)
        let thumbnails = runtime.pipeline.thumbnails
        await thumbnails.store(Data("thumbnail".utf8), assetID: "asset", revision: "1")
        let thumbnail = thumbnails.url(assetID: "asset", revision: "1")
        XCTAssertTrue(thumbnail.path.contains("/Library/Application Support/IlyichThumbnails/"), thumbnail.path)
        let position = CoverageState(mark: 7, policyHash: "policy", total: 1, stored: 1)
        let saved = await thumbnails.saveCoverageState(position, token: thumbnails.fence.token())
        XCTAssertTrue(saved)
        let stored = await thumbnails.currentUsage()
        XCTAssertGreaterThan(stored, 0)
        let shown = await runtime.pipeline.cacheUsage()
        XCTAssertEqual(shown.thumbnailBytes, stored, "Diagnostics shows the thumbnails.")
        XCTAssertEqual(shown.thumbnailLimit, ThumbnailDiskStore.defaultLimit, "Against their cap.")

        await harness.manager.clearBrowsingCache()

        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnail.path), "The thumbnail stays on disk.")
        XCTAssertTrue(thumbnails.contains(assetID: "asset", revision: "1"))
        let kept = await thumbnails.currentUsage()
        XCTAssertEqual(kept, stored)
        let coverage = await thumbnails.coverageState()
        XCTAssertEqual(coverage, position, "Coverage's position and counts stay.")
        let phase = await harness.manager.phase
        XCTAssertEqual(phase, .active, "The account stays signed in.")
        await signOutAfterwards(harness)
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnails.directory.path), "Signing out removes them.")
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

    /// The address the logout goes to is chosen while the account's work ends, before casting
    /// stops, so the budget goes to the logout rather than to checking every address, which can
    /// take longer than the budget.
    func testSignOutChoosesTheServersAddressWhileTheAccountsWorkEnds() async throws {
        let server = answeringAddressChecks(makeStubServer()), away = makeStubServer()
        let unreachable = StubServer.Gate(), stopping = StubServer.Gate()
        addTeardownBlock { unreachable.open(); stopping.open() }
        away.route("GET", "server/ping", StubServer.Response.transportFailure(.cannotConnectToHost).waiting(for: unreachable))
        server.route("POST", "auth/logout", .json(#"{"successful":true}"#))
        let harness = makeHarness(credential("alice", on: server), server: server, environment: environment(validatesSession: false),
                                  holdingCastingStop: stopping,
                                  network: NetworkConfiguration(alternateEndpoints: [away.baseURL], automaticallySwitchEndpoints: true))
        await harness.manager.restore()

        let signingOut = Task { await harness.manager.signOut(.user) }
        try await until("The address was not checked before casting stopped.") {
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
        let aliceEvents = alice.bus.events()
        let listening = Task { for await _ in aliceEvents { aliceChanges.withLock { $0 += 1 } } }
        defer { listening.cancel() }

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
        XCTAssertFalse(alice.bus.isOpen, "Alice's bus closed with her account.")
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
    /// at once; the transfer engine follows the account's authorization itself.
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
        XCTAssertEqual(session.runtime?.authorization.snapshot.readOnly, true, "So does the account's authorization, which the engine follows.")
        XCTAssertTrue(log.all.isEmpty, "Nothing device-wide is asked.")
        session.setReadOnly(false)
        XCTAssertEqual(session.authorization?.readOnly, false)

        session.pendingLink = .album("00000000-0000-4000-8000-000000000003")
        await session.signOut()
        XCTAssertEqual(session.phase, .signedOut(.user))
        XCTAssertNil(session.runtime)
        XCTAssertNil(session.authorization)
        XCTAssertNil(session.pendingLink, "A link for the account that signed out is dropped.")
    }

    /// The account's transfers database is readied for the engine once, when its backup starts
    /// (TransferHost.activate), never on the app coming forward. A new account's is claimed as it
    /// is. A copy B1 made of an account's state.json, which no import handed over, is claimed with
    /// its records, automatic backup off and paused, since it never saw how that account's last
    /// session ended. The database stays at sign-out.
    func testTheTransfersDatabaseIsTheEnginesOnceBackupStartsAndStaysAtSignOut() async throws {
        enum Earlier: CaseIterable { case newAccount, copy }
        for earlier in Earlier.allCases {
            let name = "\(earlier)"
            let server = makeStubServer()
            server.route("POST", "auth/validateToken", .json(#"{"authStatus":true}"#))
            server.route("POST", "auth/logout", .json(#"{"successful":true}"#))
            let saved = credential("alice", on: server)
            let environment = keepingTransfers(self.environment())
            let database = TransferStore.url(for: saved.account, in: environment.transfersDirectory)
            if earlier == .copy {
                // The copy is as old as the account's last time in front: automatic backup on, a run under way.
                let copy = TransferStore(url: database)
                var seed = TransferSeed()
                seed.preferences.automatic = true
                seed.intent = .automatic
                seed.confirmations = [("photo", Date(timeIntervalSinceReferenceDate: 700_000_000.5))]
                try await copy.seedForTest(seed, mode: .shadow, engine: .legacy)
                await copy.close()
            }
            let dependencies = self.dependencies(saved, server: server, log: AccountEventLog())
            let session = AccountSession(environment: environment, dependencies: dependencies, presence: AppPresence(isForeground: false))

            await session.restore()
            XCTAssertEqual(session.phase, .active)
            let runtime = try XCTUnwrap(session.runtime)
            session.sceneChanged(.active)
            let store = try XCTUnwrap(runtime.transfers).store
            let before = try await store.meta()
            XCTAssertEqual(before.engine, .legacy, "\(name): nothing is claimed or imported until backup starts.")

            let decision = await runtime.prepareTransfers()
            XCTAssertEqual(decision, .engine, name)
            let meta = try await store.meta()
            XCTAssertEqual(meta.engine, .transfer, name)
            let preferences = try await store.preferences()
            let state = try await store.engineState()
            let history = try await store.historyPage(offset: 0, limit: 10)
            let confirmed = Set(history.map(\.localID.rawValue))
            switch earlier {
            case .newAccount:
                XCTAssertNil(meta.legacyImportMode, "A new account's database is claimed as it is.")
                XCTAssertTrue(confirmed.isEmpty)
            case .copy:
                XCTAssertEqual(meta.legacyImportMode, .shadow, "Its record says no import handed it over.")
                XCTAssertEqual(confirmed, ["photo"], "The copy's records stay.")
                XCTAssertEqual(preferences?.automatic, false, "Automatic backup goes off: the copy never saw the sign-out.")
                XCTAssertEqual(state?.intent, .paused)
            }
            let again = await runtime.prepareTransfers()
            XCTAssertEqual(again, .engine, name)

            await session.signOut()
            XCTAssertTrue(FileManager.default.fileExists(atPath: database.path), name)
        }
    }

    /// The sign-in screen asks the server how it signs in only once typing pauses, and signs in
    /// through the manager.
    func testSignInAsksTheServerOnceTypingPausesAndSignsIn() async throws {
        let server = makeStubServer()
        server.route("GET", "server/features", .json(#"{"passwordLogin":true,"oauth":true,"smartSearch":true,"ocr":true,"facialRecognition":true,"map":true,"trash":true,"sidecar":true,"realtimeTranscoding":false}"#))
        server.route("POST", "auth/login", .json(#"{"accessToken":"carol-session","userId":"carol","userEmail":"carol@example.test","name":"Carol","isAdmin":false,"shouldChangePassword":false,"profileImagePath":"","isOnboarded":true}"#, status: 201))
        server.route("POST", "auth/validateToken", .json(#"{"authStatus":true}"#))
        server.route("POST", "auth/logout", .json(#"{"successful":true}"#))
        server.route("GET", "server/version", .json(#"{"major":3,"minor":3,"patch":5,"prerelease":null}"#))
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

        // The browsing cache is cleared through the account, and the feed hears of it on the bus,
        // recorded as the bus takes it.
        let cleared = Recorded<Bool>()
        _ = try XCTUnwrap(session.bus).subscribe { event -> Bool? in
            if case .cachesCleared = event { cleared.append(true) }
            return nil
        }
        await session.clearBrowsingCache()
        XCTAssertEqual(cleared.count, 1, "The feed hears the cache was cleared.")
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
        XCTAssertEqual(library?.keepsTransfers, false, "Nor its backup records.")
        XCTAssertTrue(AccountEnvironment.live.keepsTransfers)
        XCTAssertNil(AccountEnvironment.live.transfersDirectory)
        XCTAssertEqual(try library?.credentialStore().load()?.userID, AccountEnvironment.fixtureUserID)
        XCTAssertEqual(library?.fixtureCredential?.server, AccountEnvironment.fixtureServer)
        let elsewhere = AccountEnvironment.uiTest(arguments: ["--ui-testing", "--ui-testing-library", "--ui-testing-fixture-port", "18191"])
        XCTAssertEqual(elsewhere?.fixtureCredential?.server, URL(string: "http://127.0.0.1:18191/api"), "A run can name a fixture server of its own.")
        XCTAssertEqual(elsewhere?.fixtureAccount?.server, URL(string: "http://127.0.0.1:18191/api"))
        let people = AccountEnvironment.uiTest(arguments: ["--ui-testing", "--ui-testing-library", "--ui-testing-many-people"])
        XCTAssertEqual(people?.fixtureCredential?.token, "ui-test-many-people")
        let pages = AccountEnvironment.uiTest(arguments: ["--ui-testing", "--ui-testing-library", "--ui-testing-paged-people"])
        XCTAssertEqual(pages?.fixtureCredential?.token, "ui-test-paged-people")
        // A Trash already holding photos is a library of the launch's own, which the fixture changes for it alone.
        let trashed = AccountEnvironment.uiTest(arguments: ["--ui-testing", "--ui-testing-library", "--ui-testing-trashed-library"])
        XCTAssertEqual(trashed?.fixtureCredential?.token.hasPrefix("ui-test-mutable-trash-"), true)
        XCTAssertNotEqual(trashed?.fixtureCredential?.token,
                          AccountEnvironment.uiTest(arguments: ["--ui-testing", "--ui-testing-library", "--ui-testing-trashed-library"])?.fixtureCredential?.token)
    }

    /// An account's backup is taken up each time the account becomes active, not only at launch
    /// (REBUILD_ROADMAP.md, Critic's corrections, B8): signing out and in as someone else without
    /// relaunching starts the new account's backup, with no screen asking. The screens follow
    /// (BackupBackendRouterTests.testTheScreensFollowEachAccountsEngineAcrossASignIn).
    func testSigningOutAndBackInStartsTheNewAccountsBackup() async throws {
        let server = makeStubServer()
        server.route("POST", "auth/validateToken", .json(#"{"authStatus":true}"#))
        server.route("POST", "auth/logout", .json(#"{"successful":true}"#))
        let alice = credential("alice", on: server)
        var environment = self.environment()
        environment.usesDevicePhotos = true
        let harness = makeHarness(alice, server: server, environment: environment)

        await harness.manager.restore()
        try await until("Alice's backup did not start.") { harness.log.all.contains("activateBackup(alice)") }
        await harness.manager.signOut(.user)
        try await harness.manager.completeSSO(login("bob"), server: server.baseURL)
        try await until("Bob's backup did not start.") { harness.log.all.contains("activateBackup(bob)") }
        XCTAssertEqual(harness.log.all.filter { $0.hasPrefix("activateBackup") }, ["activateBackup(alice)", "activateBackup(bob)"])
        await signOutAfterwards(harness)
    }

    // MARK: - Support

    /// What an ordinary sign-out records, in order.
    private static let signOutSteps = ["endCasting", "removeCredential", "clearNotifications", "removeLockedPIN",
                                       "removeNetworkSettings", "clearDiagnostics"]

    private static let completeStream = #"{"type":"SyncCompleteV1","data":{},"ack":"SyncCompleteV1|done"}"# + "\n"

    private static func albums(_ name: String) -> String {
        #"[{"id":"00000000-0000-4000-8000-000000000003","albumName":"\#(name)","assetCount":1,"shared":false,"albumUsers":[],"updatedAt":"2026-12-01T12:00:00Z"}]"#
    }

    private func credential(_ user: String, on server: StubServer) -> StoredCredential {
        StoredCredential(server: server.baseURL, token: user + "-session", userID: user, name: user.capitalized)
    }

    private static func loginJSON(_ user: String) -> String {
        #"{"accessToken":"\#(user)-session","userId":"\#(user)","userEmail":"\#(user)@example.test","name":"\#(user.capitalized)","isAdmin":false,"shouldChangePassword":false,"profileImagePath":"","isOnboarded":true}"#
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
        environment.keepsTransfers = false
        if library { environment.libraryDirectory = temporaryDirectory() }
        return environment
    }

    /// `environment`, with the account's transfers database in a folder of the test's.
    private func keepingTransfers(_ environment: AccountEnvironment) -> AccountEnvironment {
        var environment = environment
        environment.keepsTransfers = true
        environment.transfersDirectory = temporaryDirectory()
        return environment
    }

    /// `castingStop` holds ending casting back until the test opens it.
    private func dependencies(_ credential: StoredCredential?, server: StubServer, log: AccountEventLog, locked: Bool = false,
                              mirror: AuthorizationMirror? = nil, unlockEvents: AsyncStream<Void> = AsyncStream { $0.finish() },
                              castingStop: StubServer.Gate? = nil,
                              network: NetworkConfiguration = NetworkConfiguration(), serverSignOutBudget: Duration = .seconds(3)) -> AccountDependencies {
        let store = TestCredentialStore(credential, log: log, locked: locked)
        let clients = AccountClients { address, credential, purpose in
            let authorization: AuthorizationState? = if case .session(let state) = purpose { state } else { nil }
            return try APIClient(baseURL: address, accessToken: credential?.token, userID: credential?.userID, sessionConfiguration: server.configuration(),
                                 networkConfiguration: network, wifiName: NoWiFi(), authorization: authorization)
        }
        return AccountDependencies(credentials: store, mirror: mirror, device: FakeAccountDevice(log: log, castingStop: castingStop),
                                   clients: clients, unlockEvents: { unlockEvents }, expiryRecheckDelay: .milliseconds(20),
                                   serverSignOutBudget: serverSignOutBudget)
    }

    private func makeHarness(_ credential: StoredCredential?, server: StubServer, environment: AccountEnvironment? = nil,
                             locked: Bool = false, foreground: Bool = false, mirror: AuthorizationMirror? = nil,
                             holdingCastingStop castingStop: StubServer.Gate? = nil,
                             network: NetworkConfiguration = NetworkConfiguration(), serverSignOutBudget: Duration = .seconds(3)) -> AccountHarness {
        let log = AccountEventLog()
        let (events, unlock) = AsyncStream.makeStream(of: Void.self)
        let dependencies = dependencies(credential, server: server, log: log, locked: locked, mirror: mirror, unlockEvents: events,
                                        castingStop: castingStop, network: network, serverSignOutBudget: serverSignOutBudget)
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

/// The device-wide services, recording what they are asked. With `castingStop`, casting ends
/// only once the test opens it.
final class FakeAccountDevice: AccountDevice {
    let log: AccountEventLog
    private let castingStop: StubServer.Gate?

    init(log: AccountEventLog, castingStop: StubServer.Gate? = nil) {
        self.log = log
        self.castingStop = castingStop
    }

    func activateBackup(_ runtime: AccountRuntime) async { log.append("activateBackup(\(runtime.credential.userID))") }
    func endCasting() async {
        log.append("endCasting")
        await castingStop?.wait()
    }
    func clearNotifications() async { log.append("clearNotifications") }
    func removeLockedPIN(scope: String) async { log.append("removeLockedPIN") }
    func removeNetworkSettings(server: URL) async throws { log.append("removeNetworkSettings") }
    func clearDiagnostics() async { log.append("clearDiagnostics") }
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
