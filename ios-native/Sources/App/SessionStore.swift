import SwiftUI
import WidgetKit

@MainActor @Observable final class SessionStore {
    var api: APIClient?
    var pipeline: MediaPipeline?
    var name = ""
    var isRestoring = true
    var error: String?
    let isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")

    func restore() async {
        defer { isRestoring = false }
        guard !isUITesting else {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-library") {
                do { try connect(SavedSession(server: URL(string: "http://127.0.0.1:18091")!, token: "ui-test-session", userID: "00000000-0000-4000-8000-000000000001", name: "Test library")) }
                catch { self.error = error.localizedDescription }
            }
            #endif
            return
        }
        do {
            if let saved = try await Task.detached(priority: .userInitiated, operation: { try SessionKeychain.read() }).value {
                try connect(saved)
            }
        } catch { self.error = error.localizedDescription }
    }

    func signIn(server: String, email: String, password: String) async throws {
        guard let url = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw APIError.invalidServerURL }
        let client = try APIClient(baseURL: url)
        let result = try await client.login(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
        try acceptLogin(result, server: client.baseURL)
    }

    func acceptLogin(_ result: LoginResponse, server: URL) throws {
        let saved = SavedSession(server: server, token: result.accessToken, userID: result.userId, name: result.name)
        if !isUITesting { try SessionKeychain.save(saved) }
        if !isUITesting { WidgetCenter.shared.reloadAllTimelines() }
        try connect(saved)
    }

    private func connect(_ saved: SavedSession) throws {
        let client = try APIClient(baseURL: saved.server, accessToken: saved.token, userID: saved.userID)
        api = client
        pipeline = MediaPipeline(client: client)
        name = saved.name
    }

    func signOut() async {
        do {
            await BackupCoordinator.shared.disconnect()
            if !isUITesting { try SessionKeychain.remove() }
            if !isUITesting { WidgetCenter.shared.reloadAllTimelines() }
            let previous = api
            if let previous { LockedPINStore.remove(for: previous) }
            let previousPipeline = pipeline
            api = nil; pipeline = nil; name = ""
            await previousPipeline?.removeAll()
            try? await previous?.logout()
        } catch { self.error = error.localizedDescription }
    }
}
