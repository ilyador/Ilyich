import IlyichPlatform
import SwiftUI

@main struct IlyichApp: App {
    @UIApplicationDelegateAdaptor(BackupAppDelegate.self) private var appDelegate
    @State private var session: AccountSession
    @State private var purchases: PurchaseStore
    @State private var purchasesStarted = false
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppearanceAccent.storageKey) private var accentName = AppearanceAccent.design.rawValue
    init() {
        // Inert unless launched with -IlyichPerfScenario; then it measures from the first frame.
        if !Self.isHostedUnitTest { PerfScenarioDriver.arm() }
        let purchases = PurchaseStore()
        let session = AccountSession(environment: .current, purchaseAccess: purchases.access)
        _session = State(initialValue: session)
        _purchases = State(initialValue: purchases)
        // Hosted unit tests own their StoreKit session and activate it after the app launches.
        // Do not let the host query StoreKit or start launch work before that configuration exists.
        guard !Self.isHostedUnitTest else { return }
        // Background launches check App Store access before opening an account or starting work.
        TransferHost.shared.setRestore {
            await purchases.start()
            await purchases.refreshAccess()
            await session.purchaseAccessChanged()
        }
        // The feed's whole-snapshot cache went in F2 (the index is the cache); its folder goes with it.
        Task.detached(priority: .utility) { TimelineFeed.deleteLegacySnapshots() }
        // The widget went in A1; the photos it kept in the App Group go with it, and so do the keys
        // the Flutter app left there for its widget.
        Task.detached(priority: .utility) {
            if let layout = try? AppGroupLayout.current() { IlyichApp.deleteWidgetSnapshots(in: layout.container) }
            if let defaults = AppGroup.defaults { IlyichApp.removeFlutterWidgetKeys(from: defaults) }
        }
    }
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if Self.isHostedUnitTest {
                Color.clear
            } else {
                appContent
            }
            #else
            appContent
            #endif
        }
    }

    private static let isHostedUnitTest: Bool = {
        #if DEBUG
        // UI testing injects XCTest into its separate runner, not the app's unit-test bundle.
        guard let bundlePath = ProcessInfo.processInfo.environment["XCTestBundlePath"] else { return false }
        return URL(fileURLWithPath: bundlePath).lastPathComponent == "IlyichTests.xctest"
        #else
        return false
        #endif
    }()

    private var appContent: some View {
        Group {
            if !purchases.hasAccess {
                NavigationStack { PurchaseAccessView(store: purchases, session: session) }
            } else if session.isRestoring || session.phase == .purchaseRequired {
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
        .environment(\.placeDirectory, session.places).environment(\.placeNaming, session.placeNaming)
        .environment(\.accountSettings, session.settings)
        .environment(\.freeUpSpace, session.freeUpSpace)
        .environment(\.lockedFolder, session.lockedFolder)
        .environment(\.purchaseStore, purchases)
        .tint((AppearanceAccent(rawValue: accentName) ?? .design).tint)
        .task {
            await purchases.start()
            purchasesStarted = true
            await reconcilePurchaseAccess()
        }
        .onOpenURL { session.open($0) }
        .onChange(of: purchases.hasAccess) { _, _ in
            Task { await reconcilePurchaseAccess() }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                guard purchasesStarted else { return }
                Task {
                    await purchases.refreshAccess()
                    await reconcilePurchaseAccess()
                }
            } else {
                // Locked Folder and active work hear backgrounding immediately.
                session.sceneChanged(phase)
            }
        }
    }

    private func reconcilePurchaseAccess() async {
        await session.purchaseAccessChanged()
        if purchases.hasAccess, scenePhase == .active { session.sceneChanged(.active) }
    }

    /// The folders the widget kept its photos in until A1 removed it: WidgetCache2, and WidgetCache
    /// from builds before 3040055. They go at launch; deleting them again finds nothing.
    nonisolated static func deleteWidgetSnapshots(in container: URL) {
        for folder in ["WidgetCache", "WidgetCache2"] {
            try? FileManager.default.removeItem(at: container.appendingPathComponent(folder, isDirectory: true))
        }
    }

    /// The keys the Flutter app left in the App Group's preferences for its widget, which may hold
    /// an old session token and which nothing reads. They go at launch; removing them again finds
    /// nothing.
    nonisolated static func removeFlutterWidgetKeys(from defaults: UserDefaults) {
        for key in ["widget_server_url", "widget_auth_token", "widget_custom_headers"] { defaults.removeObject(forKey: key) }
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
