import SwiftUI
import AuthenticationServices

struct SignInView: View {
    @Bindable var session: SessionStore
    @State private var server = ""
    @State private var email = ""
    @State private var password = ""
    @State private var isSigningIn = false
    @State private var error: String?
    @State private var features: ServerFeatures?
    @State private var oauth = OAuthSignIn()
    @FocusState private var focused: Field?
    private enum Field { case server, email, password }
    private var canSubmit: Bool { !server.isEmpty && !email.isEmpty && !password.isEmpty && !isSigningIn }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    VStack(alignment: .leading, spacing: 14) {
                        Image("IlyichLogo").resizable().scaledToFit().frame(width: 76, height: 76)
                            .clipShape(RoundedRectangle(cornerRadius: 18)).accessibilityHidden(true)
                        Text("Your moments.\nIn Ilyich.").font(.largeTitle.bold()).accessibilityIdentifier("signIn.title")
                        Text("Connect to your photo library.").foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        field("Server address") {
                            TextField("https://photos.example.com", text: $server)
                                .keyboardType(.URL).textContentType(.URL).focused($focused, equals: .server)
                                .accessibilityIdentifier("signIn.serverURL")
                        }
                        if features?.passwordLogin != false {
                        field("Email") {
                            TextField("Email", text: $email).keyboardType(.emailAddress).textContentType(.username)
                                .focused($focused, equals: .email).accessibilityIdentifier("signIn.email")
                        }
                        field("Password") {
                            SecureField("Password", text: $password).textContentType(.password)
                                .focused($focused, equals: .password).accessibilityIdentifier("signIn.password")
                                .submitLabel(.go).onSubmit { if canSubmit { signIn() } }
                        }
                        }
                        if let error = error ?? session.error {
                            Text(error).foregroundStyle(.red).font(.callout)
                                .accessibilityIdentifier("signIn.error").accessibilityAddTraits(.updatesFrequently)
                        }
                    }.textInputAutocapitalization(.never).autocorrectionDisabled()
                    if features?.passwordLogin != false {
                    Button(action: signIn) {
                        HStack {
                            if isSigningIn { ProgressView().tint(.primary) }
                            Text(isSigningIn ? "Connecting…" : "Sign in").fontWeight(.semibold)
                        }.frame(maxWidth: .infinity).frame(minHeight: 44)
                    }
                    .buttonStyle(.glassProminent).disabled(!canSubmit).accessibilityIdentifier("signIn.submit")
                    }
                    if features?.oauth == true {
                        Button("Continue with single sign-on") { singleSignOn() }
                            .buttonStyle(.glass).disabled(isSigningIn)
                    }
                }.padding(28).frame(maxWidth: 480).frame(maxWidth: .infinity)
            }.scrollDismissesKeyboard(.interactively).navigationTitle("Ilyich").navigationBarTitleDisplayMode(.inline)
        }
        .task(id: server) {
            features = nil
            guard let url = URL(string: server), let api = try? APIClient(baseURL: url) else { return }
            do { try await Task.sleep(for: .milliseconds(500)); features = try await api.serverFeatures() }
            catch { /* Validation and connection errors surface on an explicit sign-in attempt. */ }
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.medium))
            content().padding(14).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func signIn() {
        guard canSubmit else { return }
        guard let url = URL(string: server), (try? APIClient.normalizedBaseURL(url)) != nil else {
            error = APIError.invalidServerURL.localizedDescription; focused = .server; return
        }
        isSigningIn = true; error = nil; focused = nil
        Task {
            defer { isSigningIn = false }
            do { try await session.signIn(server: server, email: email, password: password); password = "" }
            catch { self.error = error.localizedDescription }
        }
    }

    private func singleSignOn() {
        guard let url = URL(string: server), let api = try? APIClient(baseURL: url) else { error = APIError.invalidServerURL.localizedDescription; return }
        isSigningIn = true; error = nil; focused = nil
        Task {
            defer { isSigningIn = false }
            do { let login = try await oauth.signIn(api: api); try session.acceptLogin(login, server: api.baseURL) }
            catch let failure as ASWebAuthenticationSessionError where failure.code == .canceledLogin { }
            catch { self.error = error.localizedDescription }
        }
    }
}
