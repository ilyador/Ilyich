import Foundation

/// The signed-in account's own settings on the server (the critic's correction, C7 or N4): its
/// name, password, Locked Folder PIN and profile photo. Each change is refused in read-only mode
/// before it is sent and runs as the service's own work, so it ends the same whether the screen
/// that asked waits, closes or is gone. The PIN kept on this phone for biometric unlock stays the
/// Locked Folder's (LockedPINStore). AccountRuntime owns the service and shuts it down at sign-out.
actor AccountSettingsService {
    private nonisolated let client: APIClient
    private nonisolated let requests: OwnedRequests

    /// `authorization` says whether read-only mode is on; without it, the client's account flag does.
    init(client: APIClient, authorization: AuthorizationState?) {
        self.client = client
        requests = OwnedRequests { authorization?.snapshot.readOnly ?? client.isReadOnly }
    }

    func shutdown() async { await requests.shutdown() }

    /// How many changes are on their way.
    nonisolated var runningCount: Int { requests.runningCount }

    // MARK: Profile

    nonisolated func currentUser() async throws -> User {
        try await requests.read { [client] in try await client.currentUser() }
    }

    /// Renames the account.
    nonisolated func rename(to name: String) async throws -> User {
        try await requests.change { [client] in try await client.request(.put, path: "users/me", body: ["name": name]) }
    }

    nonisolated func changePassword(from current: String, to new: String, signingOutOtherDevices: Bool) async throws {
        try await requests.change { [client] in
            try await client.requestVoid(.post, path: "auth/change-password",
                                         body: PasswordChange(password: current, newPassword: new, invalidateSessions: signingOutOtherDevices))
        }
    }

    nonisolated func uploadProfilePhoto(jpeg: Data) async throws {
        try await requests.change { [client] in try await client.uploadProfileImage(jpeg: jpeg) }
    }

    nonisolated func removeProfilePhoto() async throws {
        try await requests.change { [client] in try await client.requestVoid(.delete, path: "users/profile-image") }
    }

    // MARK: Locked Folder PIN

    /// Whether the account has a password and a PIN, and whether this session is unlocked.
    nonisolated func authStatus() async throws -> AuthStatus {
        try await requests.read { [client] in try await client.authStatus() }
    }

    nonisolated func setPIN(_ pin: String) async throws {
        try await requests.change { [client] in try await client.requestVoid(.post, path: "auth/pin-code", body: ["pinCode": pin]) }
    }

    /// Changes the PIN, confirmed by the current PIN or the account's password.
    nonisolated func changePIN(to pin: String, currentPIN: String?, password: String?) async throws {
        try await requests.change { [client] in
            try await client.requestVoid(.put, path: "auth/pin-code", body: PINChange(newPinCode: pin, pinCode: currentPIN, password: password))
        }
    }

    /// Removes the PIN, confirmed by the current PIN or the account's password.
    nonisolated func removePIN(currentPIN: String?, password: String?) async throws {
        try await requests.change { [client] in
            try await client.requestVoid(.delete, path: "auth/pin-code", body: PINIdentity(pinCode: currentPIN, password: password))
        }
    }
}

private struct PasswordChange: Encodable, Sendable { let password: String; let newPassword: String; let invalidateSessions: Bool }
private struct PINIdentity: Encodable, Sendable { let pinCode: String?; let password: String? }
private struct PINChange: Encodable, Sendable { let newPinCode: String; let pinCode: String?; let password: String? }
