import SwiftUI

@main struct IlyichApp: App {
    @UIApplicationDelegateAdaptor(BackupAppDelegate.self) private var appDelegate
    @State private var session: SessionStore
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppearanceAccent.storageKey) private var accentName = AppearanceAccent.design.rawValue
    init() {
        // Inert unless launched with -IlyichPerfScenario; then it measures from the first frame.
        PerfScenarioDriver.arm()
        let session = SessionStore()
        _session = State(initialValue: session)
        BackupLifecycle.shared.setBackgroundPreparation { await session.prepareForBackgroundBackup() }
        _ = CastController.shared
    }
    var body: some Scene {
        WindowGroup {
            Group {
                if session.isRestoring {
                    ProgressView("Opening Ilyich")
                } else if session.isSigningOut {
                    ProgressView("Signing out")
                } else if let api = session.api, let pipeline = session.pipeline {
                    if session.requiresPasswordChange {
                        NavigationStack {
                            RequiredPasswordChange(api: api, session: session, onChanged: { Task { await session.signOut() } })
                                .toolbar { ToolbarItem(placement: .cancellationAction) {
                                    Button("Sign out") { Task { await session.signOut() } }
                                } }
                        }
                    } else {
                        LibraryView(api: api, pipeline: pipeline, session: session).id(api.cacheScope)
                    }
                } else {
                    SignInView(session: session)
                }
            }
            // Every control that changes something reads what the account may do from here.
            .environment(\.authorization, session.authorization)
            .tint((AppearanceAccent(rawValue: accentName) ?? .design).tint)
            .task { await session.restore() }
            .onOpenURL { session.open($0) }
            .onChange(of: scenePhase, initial: true) { _, phase in session.sceneChanged(phase) }
        }
    }
}

private struct RequiredPasswordChange: View {
    let api: APIClient
    let session: SessionStore
    let onChanged: () -> Void
    @Environment(\.authorization) private var authorization

    var body: some View {
        ChangePasswordView(api: api, onChanged: onChanged)
            .safeAreaInset(edge: .top) {
                if authorization?.readOnly == true {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Your server requires a new password. Turn off Read-only mode to save it.")
                            .font(.subheadline)
                        Button("Turn off Read-only mode") { session.setReadOnly(false) }.buttonStyle(.bordered)
                    }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial)
                }
            }
    }
}
