import SwiftUI

@main struct IlyichApp: App {
    @UIApplicationDelegateAdaptor(BackupAppDelegate.self) private var appDelegate
    @State private var session = SessionStore()
    var body: some Scene {
        WindowGroup {
            Group {
                if session.isRestoring {
                    ProgressView("Opening Ilyich")
                } else if let api = session.api, let pipeline = session.pipeline {
                    LibraryView(api: api, pipeline: pipeline, session: session)
                        .id(api.cacheScope)
                } else {
                    SignInView(session: session)
                }
            }
            .tint(.cyan)
            .task { await session.restore() }
        }
    }
}
