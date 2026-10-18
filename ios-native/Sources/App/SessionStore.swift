import SwiftUI
import WidgetKit

@MainActor @Observable final class SessionStore {
    var api: APIClient?
    var pipeline: MediaPipeline?
    var name = ""
    var isRestoring = true
    var error: String?
    var requiresPasswordChange = false
    var pendingLink: AppLink?
    @ObservationIgnored private var validationTask: Task<Void, Never>?
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
        let saved = SavedSession(server: server, token: result.accessToken, userID: result.userId, name: result.name,
                                 requiresPasswordChange: result.shouldChangePassword)
        if !isUITesting { try SessionKeychain.save(saved) }
        if !isUITesting { WidgetCenter.shared.reloadAllTimelines() }
        try connect(saved)
    }

    private func connect(_ saved: SavedSession) throws {
        let client = try APIClient(baseURL: saved.server, accessToken: saved.token, userID: saved.userID,
                                   networkConfiguration: isUITesting ? NetworkConfiguration() : nil)
        api = client
        pipeline = MediaPipeline(client: client)
        name = saved.name
        requiresPasswordChange = saved.requiresPasswordChange == true
        validateSession()
    }

    func validateSession() {
        guard !isUITesting, let client = api else { return }
        validationTask?.cancel()
        validationTask = Task { [weak self] in
            do { try await client.validateToken() }
            catch APIError.unauthorized {
                guard !Task.isCancelled, let self, self.api === client else { return }
                await self.signOut()
                self.error = APIError.unauthorized.localizedDescription
            } catch { /* A temporary network failure must not discard an offline session. */ }
        }
    }

    func open(_ url: URL) {
        if let link = AppLink(url: url, server: api?.baseURL) { pendingLink = link }
    }

    func signOut() async {
        validationTask?.cancel()
        CastController.shared.signOut()
        do {
            await BackupCoordinator.shared.disconnect()
            if !isUITesting { try SessionKeychain.remove() }
            if !isUITesting { WidgetCenter.shared.reloadAllTimelines() }
            let previous = api
            if let previous { LockedPINStore.remove(for: previous) }
            if let previous, !isUITesting { try NetworkConfigurationStore.remove(server: previous.baseURL) }
            let previousPipeline = pipeline
            api = nil; pipeline = nil; name = ""; requiresPasswordChange = false; pendingLink = nil
            await previousPipeline?.removeAll()
            if let previous { await TimelineCache.shared.removeAll(scope: previous.cacheScope) }
            try? await previous?.logout()
        } catch { self.error = error.localizedDescription }
    }
}
