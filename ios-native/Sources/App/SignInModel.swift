import AuthenticationServices
import Foundation

/// The sign-in screen's state and work. It asks the server how it signs in once typing pauses,
/// and runs password sign-in and single sign-on; the clients for both are made off the main
/// actor, because they read the server's saved network settings from the Keychain.
@MainActor @Observable final class SignInModel {
    var server = ""
    var email = ""
    var password = ""
    private(set) var isSigningIn = false
    /// How the server lets people sign in, once it has answered.
    private(set) var features: ServerFeatures?
    var error: String?
    @ObservationIgnored private let session: AccountSession
    @ObservationIgnored private let oauth = OAuthSignIn()
    @ObservationIgnored private var probe: Task<Void, Never>?

    init(session: AccountSession) { self.session = session }

    var serverAddress: String { server.trimmingCharacters(in: .whitespacesAndNewlines) }
    var emailAddress: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canSubmit: Bool { !serverAddress.isEmpty && !emailAddress.isEmpty && !password.isEmpty && !isSigningIn }

    /// The server address as the app stores it, when it is a valid one.
    var normalizedServer: URL? { URL(string: serverAddress).flatMap { try? APIClient.normalizedBaseURL($0) } }

    /// The server address changed: asks the server what it offers once typing pauses for half a
    /// second. Validation and connection errors surface on an explicit sign-in attempt instead.
    func serverChanged() {
        probe?.cancel()
        features = nil
        let address = serverAddress, session = session
        probe = Task { [weak self] in
            guard (try? await Task.sleep(for: .milliseconds(500))) != nil, let url = URL(string: address) else { return }
            let latest = await session.serverFeatures(at: url)
            guard !Task.isCancelled, let latest else { return }
            self?.features = latest
        }
    }

    /// Stops asking the server, when the screen goes.
    func stop() {
        probe?.cancel()
        probe = nil
    }

    /// Signs in with the email and password. Returns false, starting nothing, when the server
    /// address is not a valid one.
    @discardableResult
    func signIn() -> Bool {
        guard canSubmit else { return true }
        guard normalizedServer != nil else {
            error = APIError.invalidServerURL.localizedDescription
            return false
        }
        isSigningIn = true; error = nil
        let server = serverAddress, email = emailAddress, password = password
        Task {
            defer { isSigningIn = false }
            do { try await session.signIn(server: server, email: email, password: password); self.password = "" }
            catch { self.error = error.localizedDescription }
        }
        return true
    }

    /// Signs in through the server's single sign-on provider, in the system's web sheet.
    func singleSignOn() {
        guard let url = URL(string: serverAddress), normalizedServer != nil else {
            error = APIError.invalidServerURL.localizedDescription
            return
        }
        isSigningIn = true; error = nil
        Task {
            defer { isSigningIn = false }
            let api: APIClient
            do { api = try await session.signInClient(for: url) }
            catch { self.error = error.localizedDescription; return }
            do {
                let login = try await oauth.signIn(api: api)
                try await session.completeSSO(login, server: api.baseURL)
            }
            catch let failure as ASWebAuthenticationSessionError where failure.code == .canceledLogin { }
            catch { self.error = error.localizedDescription }
            await api.shutdown()
        }
    }
}
