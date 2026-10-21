import SwiftUI

struct SignInView: View {
    let session: AccountSession
    @State private var model: SignInModel
    @FocusState private var focused: Field?
    private enum Field { case server, email, password }
    private var features: ServerFeatures? { model.features }
    private var isSigningIn: Bool { model.isSigningIn }

    init(session: AccountSession) {
        self.session = session
        _model = State(initialValue: SignInModel(session: session))
    }

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
                                if let normalized = model.normalizedServer {
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
                                TextField("https://photos.example.com", text: $model.server)
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
                                    TextField("Email", text: $model.email).keyboardType(.emailAddress).textContentType(.username)
                                        .focused($focused, equals: .email).accessibilityIdentifier("signIn.email")
                                        .submitLabel(.next).onSubmit { focused = .password }
                                }
                                Divider().padding(.leading, 50)
                                field(symbol: "lock") {
                                    SecureField("Password", text: $model.password).textContentType(.password)
                                        .focused($focused, equals: .password).accessibilityIdentifier("signIn.password")
                                        .submitLabel(.go).onSubmit { if model.canSubmit { signIn() } }
                                }
                            }
                            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                        }
                        if let error = model.error ?? session.error {
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
                                .disabled(!model.canSubmit).accessibilityIdentifier("signIn.submit")
                            }
                            if features?.oauth == true {
                                Button { focused = nil; model.singleSignOn() } label: {
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
        .onChange(of: model.server) { model.serverChanged() }
        .onDisappear { model.stop() }
    }

    private func field<Content: View>(symbol: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 22).accessibilityHidden(true)
            content().foregroundStyle(.primary).frame(minHeight: 24)
        }
        .padding(.horizontal, 16).padding(.vertical, 15)
    }

    private func signIn() {
        guard model.canSubmit else { return }
        focused = model.signIn() ? nil : .server
    }
}
