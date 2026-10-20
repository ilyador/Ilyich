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
    private var serverAddress: String { server.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var emailAddress: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSubmit: Bool { !serverAddress.isEmpty && !emailAddress.isEmpty && !password.isEmpty && !isSigningIn }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HStack(spacing: 14) {
                        Image("IlyichLogo").resizable().scaledToFit().frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 14)).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Ilyich").font(.largeTitle.bold()).accessibilityIdentifier("signIn.title")
                            Text("Sign in to your library").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Server address").font(.subheadline.weight(.medium))
                                Spacer()
                                if let url = URL(string: serverAddress), let normalized = try? APIClient.normalizedBaseURL(url) {
                                    NavigationLink {
                                        NetworkSettingsView(server: normalized)
                                            .toolbar(.visible, for: .navigationBar)
                                    } label: {
                                        Label("Network settings", systemImage: "network")
                                            .font(.footnote)
                                            .frame(minHeight: 44)
                                    }
                                }
                            }.frame(minHeight: 44)
                            field(symbol: "server.rack") {
                                TextField("https://photos.example.com", text: $server)
                                    .keyboardType(.URL).textContentType(.URL).focused($focused, equals: .server)
                                    .accessibilityIdentifier("signIn.serverURL")
                                    .accessibilityLabel("Server address")
                                    .submitLabel(.next).onSubmit { focused = features?.passwordLogin == false ? nil : .email }
                            }
                            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                        }
                        if features?.passwordLogin != false {
                            VStack(spacing: 0) {
                                field(symbol: "envelope") {
                                    TextField("Email", text: $email).keyboardType(.emailAddress).textContentType(.username)
                                        .focused($focused, equals: .email).accessibilityIdentifier("signIn.email")
                                        .submitLabel(.next).onSubmit { focused = .password }
                                }
                                Divider().padding(.leading, 50)
                                field(symbol: "lock") {
                                    SecureField("Password", text: $password).textContentType(.password)
                                        .focused($focused, equals: .password).accessibilityIdentifier("signIn.password")
                                        .submitLabel(.go).onSubmit { if canSubmit { signIn() } }
                                }
                            }
                            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                        }
                        if let error = error ?? session.error {
                            Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.callout)
                                .accessibilityIdentifier("signIn.error").accessibilityAddTraits(.updatesFrequently)
                        }
                    }.textInputAutocapitalization(.never).autocorrectionDisabled().disabled(isSigningIn)
                    GlassEffectContainer(spacing: 12) {
                        VStack(spacing: 12) {
                            if features?.passwordLogin != false {
                                Button(action: signIn) {
                                    HStack(spacing: 8) {
                                        if isSigningIn { ProgressView().tint(Color(uiColor: .systemBackground)) }
                                        Text(isSigningIn ? "Connecting…" : "Sign in").fontWeight(.semibold)
                                    }
                                    .foregroundStyle(Color(uiColor: .systemBackground))
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.glassProminent).controlSize(.large).tint(.primary)
                                .disabled(!canSubmit).accessibilityIdentifier("signIn.submit")
                            }
                            if features?.oauth == true {
                                Button { singleSignOn() } label: {
                                    Text("Continue with single sign-on").frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.glass).controlSize(.large).disabled(isSigningIn)
                            }
                        }
                    }
                }.padding(24).frame(maxWidth: 440).frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemBackground))
            .scrollDismissesKeyboard(.interactively).scrollIndicators(.hidden)
            .toolbar(.hidden, for: .navigationBar)
        }
        .task(id: serverAddress) {
            features = nil
            guard let url = URL(string: serverAddress), let api = try? APIClient(baseURL: url) else { return }
            do { try await Task.sleep(for: .milliseconds(500)); features = try await api.serverFeatures() }
            catch { /* Validation and connection errors surface on an explicit sign-in attempt. */ }
        }
    }

    private func field<Content: View>(symbol: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 22).accessibilityHidden(true)
            content().foregroundStyle(.primary).frame(minHeight: 24)
        }
        .padding(.horizontal, 16).padding(.vertical, 15)
    }

    private func signIn() {
        guard canSubmit else { return }
        guard let url = URL(string: serverAddress), (try? APIClient.normalizedBaseURL(url)) != nil else {
            error = APIError.invalidServerURL.localizedDescription; focused = .server; return
        }
        isSigningIn = true; error = nil; focused = nil
        Task {
            defer { isSigningIn = false }
            do { try await session.signIn(server: serverAddress, email: emailAddress, password: password); password = "" }
            catch { self.error = error.localizedDescription }
        }
    }

    private func singleSignOn() {
        guard let url = URL(string: serverAddress), let api = try? APIClient(baseURL: url) else { error = APIError.invalidServerURL.localizedDescription; return }
        isSigningIn = true; error = nil; focused = nil
        Task {
            defer { isSigningIn = false }
            do { let login = try await oauth.signIn(api: api); try session.acceptLogin(login, server: api.baseURL) }
            catch let failure as ASWebAuthenticationSessionError where failure.code == .canceledLogin { }
            catch { self.error = error.localizedDescription }
        }
    }
}
