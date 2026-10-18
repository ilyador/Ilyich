import SwiftUI
import UIKit
import UserNotifications

struct NotificationSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var status: UNAuthorizationStatus = .notDetermined
    @State private var asking = false
    @State private var error: String?

    private var enabled: Bool { [.authorized, .provisional, .ephemeral].contains(status) }

    var body: some View {
        Form {
            Section {
                LabeledContent("Transfer notifications", value: enabled ? "Enabled" : "Off")
                if status == .notDetermined {
                    Button("Enable notifications") { Task { await enable() } }
                        .disabled(asking).frame(minHeight: 44)
                } else {
                    Button("Open Settings", systemImage: "gear") { openSettings() }
                        .frame(minHeight: 44)
                }
            } footer: {
                Text("Show item counts when downloads, photo saves, shared uploads, or backups finish. No photo names are included.")
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("Notifications")
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await refresh() } } }
    }

    private func refresh() async { status = await TransferNotifications.authorizationStatus() }

    private func enable() async {
        asking = true; error = nil
        defer { asking = false }
        do { status = try await TransferNotifications.requestAuthorization() }
        catch { self.error = error.localizedDescription }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
