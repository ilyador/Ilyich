import Foundation
import IlyichPlatform
import XCTest
@testable import Ilyich

/// The account's own settings go through one service (the critic's correction to N4): each change
/// is one call that the service sees through even when the screen that asked has gone, read-only
/// mode refuses a change before it is sent, and nothing starts once the account has closed.
@MainActor final class AccountSettingsServiceTests: XCTestCase {
    func testEachChangeIsOneCallThatOutlivesTheScreen() async throws {
        let server = makeStubServer()
        server.route("PUT", "users/me", .json(#"{"id":"alice","name":"Alice R.","email":"alice@example.test","profileImagePath":""}"#))
        server.route("POST", "auth/change-password", .empty(200))
        server.route("PUT", "auth/pin-code", .empty(204))
        server.route("DELETE", "users/profile-image", .empty(204))
        let gate = StubServer.Gate()
        addTeardownBlock { gate.open() }
        server.route("POST", "auth/pin-code", StubServer.Response.empty(201).waiting(for: gate))
        let (_, service) = try makeService(server)

        let renamed = try await service.rename(to: "Alice R.")
        XCTAssertEqual(renamed.name, "Alice R.")
        try await service.changePassword(from: "old", to: "new-password", signingOutOtherDevices: true)
        let change = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(server.requests("POST", "auth/change-password").first?.body)) as? [String: Any])
        XCTAssertEqual(change["newPassword"] as? String, "new-password")
        XCTAssertEqual(change["invalidateSessions"] as? Bool, true)
        try await service.changePIN(to: "123456", currentPIN: nil, password: "secret")
        let pin = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(server.requests("PUT", "auth/pin-code").first?.body)) as? [String: Any])
        XCTAssertEqual(pin["newPinCode"] as? String, "123456")
        XCTAssertEqual(pin["password"] as? String, "secret")
        try await service.removeProfilePhoto()

        // The screen goes while the server is still answering: the change is still made, once.
        let screen = Task { try await service.setPIN("654321") }
        let sent = await becomesTrue { gate.waiting == 1 }
        XCTAssertTrue(sent)
        screen.cancel()
        gate.open()
        let finished = await becomesTrue { service.runningCount == 0 }
        XCTAssertTrue(finished, "The change ran to its end.")
        XCTAssertEqual(server.requests("POST", "auth/pin-code").count, 1)
        XCTAssertEqual(server.requests.count, 5, "One call each.")
    }

    func testReadOnlyModeAndSignOutRefuseAChange() async throws {
        let server = makeStubServer()
        let (api, _) = try makeService(server)
        let readOnly = AccountSettingsService(client: api, authorization: AuthorizationState(account: AccountID(server: api.baseURL, userID: "alice"),
                                                                                             token: "session", readOnly: true,
                                                                                             requiresPasswordChange: false, mirror: nil))
        do {
            _ = try await readOnly.rename(to: "Alice R.")
            XCTFail("Read-only mode refuses the change.")
        } catch {
            XCTAssertTrue(error is ReadOnlyPolicy.ReadOnlyError, "\(error)")
        }
        await readOnly.shutdown()

        let (_, closed) = try makeService(server)
        await closed.shutdown()
        do {
            try await closed.removeProfilePhoto()
            XCTFail("A closed account changes nothing.")
        } catch {
            XCTAssertEqual(error as? MutationError, .closed)
        }
        XCTAssertTrue(server.requests.isEmpty, "Nothing is sent.")
    }

    private func makeService(_ server: StubServer) throws -> (APIClient, AccountSettingsService) {
        let api = try APIClient(baseURL: server.baseURL, accessToken: "session", userID: "alice", sessionConfiguration: server.configuration(),
                                networkConfiguration: NetworkConfiguration())
        let service = AccountSettingsService(client: api, authorization: nil)
        addTeardownBlock { await service.shutdown(); await api.shutdown() }
        return (api, service)
    }
}
