import SwiftUI

/// The Locked Folder's screen. What it shows and does is the account's LockedFolderSession
/// (REBUILD_ROADMAP.md N5), which the app puts in the environment: the screen renders it and sends
/// it commands, and the session relocks when the screen goes or the app leaves the foreground.
struct LockedFolderView: View {
    let api: APIClient
    let pipeline: MediaPipeline
    /// The folder opens its photos in a viewer of its own, over its photos alone.
    let onOpenAsset: (Asset) -> Void
    @Environment(\.lockedFolder) private var session

    var body: some View {
        if let session {
            LockedFolderScreen(api: api, pipeline: pipeline, session: session)
        } else {
            ProgressView().navigationTitle("Locked folder")
        }
    }
}

private struct LockedFolderScreen: View {
    let api: APIClient
    let pipeline: MediaPipeline
    @Bindable var session: LockedFolderSession
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            // Not even while the app is only inactive, as under the app switcher.
            if session.isUnlocked && scenePhase == .active {
                ScrollView {
                    SelectableFeatureAssetGrid(api: api, pipeline: pipeline, assets: session.photos.assets, onOpenAsset: {
                        session.viewing = ViewerRoute(asset: $0, source: .locked, albumContext: nil)
                    }, onAssetAppear: { session.photoAppeared($0.id) })
                    if !session.isLoading && session.photos.assets.isEmpty {
                        FeatureEmpty(title: "Your locked folder is empty", symbol: "lock", description: "Move private photos here from your library.")
                    }
                    if session.isLoading { ProgressView().padding(24) }
                }
            } else {
                unlockForm
            }
        }.navigationTitle("Locked folder")
        .toolbar {
            if session.isUnlocked { ToolbarItem(placement: .topBarTrailing) { Button("Lock", systemImage: "lock") { session.lock() } } }
        }
        .task { await session.appear() }
        .onDisappear { session.disappear() }
        // The viewer pages through the folder's photos. One moved out of the folder leaves it; one
        // found gone, as when the folder relocked on the server, has the folder read again.
        .sheet(item: $session.viewing) { route in
            AssetViewer(api: api, pipeline: pipeline, route: route, window: .locked(session.photos))
        }
        .alert("Couldn’t unlock folder", isPresented: Binding(get: { session.failure != nil }, set: { if !$0 { session.failure = nil } })) {
            Button("OK", role: .cancel) { }
        } message: { Text(session.failure?.message ?? "") }
    }

    private var unlockForm: some View {
        Form {
            Section {
                Label("Locked folder", systemImage: "lock.shield").font(.title2.bold()).padding(.vertical, 14)
                Text("Unlock to view your private photos.").foregroundStyle(.secondary)
            }
            if let status = session.status {
                let settingUp = session.settingUp
                Section(settingUp ? "Set a 6-digit PIN" : "Unlock") {
                    if !settingUp && session.entry.usePassword {
                        SecureField("Account password", text: $session.entry.password).textContentType(.password)
                    } else {
                        SecureField("6-digit PIN", text: $session.entry.pin).keyboardType(.numberPad).textContentType(.oneTimeCode)
                        if settingUp { SecureField("Confirm PIN", text: $session.entry.confirmation).keyboardType(.numberPad) }
                    }
                    if session.biometricAvailable && !session.entry.usePassword { Toggle("Enable biometric unlock", isOn: $session.entry.remember) }
                    Button(settingUp ? "Set PIN and unlock" : "Unlock") { session.unlock() }
                        .disabled(!session.canUnlock).requiresWriteAccess(when: settingUp)
                }
                if !settingUp {
                    if session.biometricAvailable {
                        Button("Unlock with biometrics", systemImage: "faceid") { session.unlockBiometrically() }.disabled(session.phase != .locked)
                    }
                    if status.password { Button(session.entry.usePassword ? "Use PIN" : "Use account password") { session.entry.usePassword.toggle() } }
                }
            } else { ProgressView() }
        }
    }
}
