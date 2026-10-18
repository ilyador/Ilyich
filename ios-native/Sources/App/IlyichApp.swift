import SwiftUI

@main struct IlyichApp: App {
    @UIApplicationDelegateAdaptor(BackupAppDelegate.self) private var appDelegate
    @State private var session = SessionStore()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            Group {
                if session.isRestoring {
                    ProgressView("Opening Ilyich")
                } else if let api = session.api, let pipeline = session.pipeline {
                    if session.requiresPasswordChange {
                        NavigationStack {
                            ChangePasswordView(api: api, onChanged: { Task { await session.signOut() } })
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
            .tint(.cyan)
            .task { await session.restore() }
            .onOpenURL { session.open($0) }
            .onChange(of: scenePhase) { _, phase in if phase == .active { session.validateSession() } }
        }
    }
}
