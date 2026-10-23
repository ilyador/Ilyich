import SwiftUI

@main struct IlyichApp: App {
    @UIApplicationDelegateAdaptor(BackupAppDelegate.self) private var appDelegate
    @State private var session: AccountSession
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppearanceAccent.storageKey) private var accentName = AppearanceAccent.design.rawValue
    init() {
        // Inert unless launched with -IlyichPerfScenario; then it measures from the first frame.
        PerfScenarioDriver.arm()
        let session = AccountSession(environment: .current)
        _session = State(initialValue: session)
        // A launch for background work opens the saved account; today's backup, the way back,
        // also syncs before its windows.
        TransferHost.shared.setRestore { await session.restore() }
        BackupLifecycle.shared.setBackgroundPreparation { await session.prepareForBackgroundBackup() }
        _ = CastSessionService.shared
        // The feed's whole-snapshot cache went in F2 (the index is the cache); its folder goes with it.
        Task.detached(priority: .utility) { TimelineFeed.deleteLegacySnapshots() }
    }
    var body: some Scene {
        WindowGroup {
            Group {
                if session.isRestoring {
                    ProgressView("Opening Ilyich")
                } else if session.isSigningOut {
                    ProgressView("Signing out")
                } else if let runtime = session.runtime {
                    if session.requiresPasswordChange {
                        NavigationStack {
                            RequiredPasswordChange(api: runtime.api, session: session, onChanged: { Task { await session.signOut() } })
                                .toolbar { ToolbarItem(placement: .cancellationAction) {
                                    Button("Sign out") { Task { await session.signOut() } }
                                } }
                        }
                    } else {
                        // A new runtime, even for the same account, starts the library afresh.
                        LibraryView(api: runtime.api, pipeline: runtime.pipeline, session: session).id(runtime.id)
                    }
                } else {
                    SignInView(session: session)
                }
            }
            // Every control that changes something reads what the account may do from here, and
            // every screen that changes or shows photos reaches the account's mutations, its bus,
            // its collections and its own settings.
            .environment(\.authorization, session.authorization)
            .environment(\.mutations, session.mutations)
            .environment(\.libraryBus, session.bus)
            .environment(\.collectionsService, session.collections)
            .environment(\.accountSettings, session.settings)
            .environment(\.freeUpSpace, session.freeUpSpace)
            .environment(\.lockedFolder, session.lockedFolder)
            .tint((AppearanceAccent(rawValue: accentName) ?? .design).tint)
            .task { await session.restore() }
            .onOpenURL { session.open($0) }
            // Cast works for the signed-in account; another account, or none, stops it.
            .onChange(of: session.runtime?.id, initial: true) { CastSessionService.shared.attach(session.runtime?.cast) }
            .onChange(of: scenePhase, initial: true) { _, phase in session.sceneChanged(phase) }
        }
    }
}

private struct RequiredPasswordChange: View {
    let api: APIClient
    let session: AccountSession
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
