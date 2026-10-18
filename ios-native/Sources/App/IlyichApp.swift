import SwiftUI

@main struct IlyichApp: App {
    @UIApplicationDelegateAdaptor(BackupAppDelegate.self) private var appDelegate
    @State private var session: SessionStore
    @Environment(\.scenePhase) private var scenePhase
    init() {
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
                            RequiredPasswordChange(api: api, onChanged: { Task { await session.signOut() } })
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
            .tint(.primary)
            .task { await session.restore() }
            .onOpenURL { session.open($0) }
            .onChange(of: scenePhase, initial: true) { _, phase in session.sceneChanged(phase) }
        }
    }
}

private struct RequiredPasswordChange: View {
    let api: APIClient
    let onChanged: () -> Void
    @State private var readOnly = false

    var body: some View {
        ChangePasswordView(api: api, onChanged: onChanged)
            .safeAreaInset(edge: .top) {
                if readOnly {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Your server requires a new password. Turn off Read-only mode to save it.")
                            .font(.subheadline)
                        Button("Turn off Read-only mode") {
                            api.setReadOnly(false)
                            readOnly = false
                        }.buttonStyle(.bordered)
                    }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial)
                }
            }
            .onAppear { readOnly = api.isReadOnly }
    }
}
