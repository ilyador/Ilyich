import SwiftUI

/// The Locked Folder PIN, set, changed and removed through the account's settings (the critic's
/// correction to N4). The PIN kept on this phone for biometric unlock is the Locked Folder's.
struct PINSettingsView: View {
    let api: APIClient
    @Environment(\.accountSettings) private var settings
    @State private var status: AuthStatus?
    @State private var currentPIN = ""
    @State private var password = ""
    @State private var newPIN = ""
    @State private var confirmation = ""
    @State private var usePassword = false
    @State private var busy = false
    @State private var failure: FeatureFailure?
    @State private var message: String?
    @State private var confirmReset = false
    private var configured: Bool { status?.pinCode == true }
    private var newPINValid: Bool { newPIN.count == 6 && newPIN.allSatisfy { "0123456789".contains($0) } && newPIN == confirmation }
    private var authorized: Bool { !configured || (usePassword ? !password.isEmpty : currentPIN.count == 6 && currentPIN.allSatisfy { "0123456789".contains($0) }) }
    var body: some View {
        Form {
            if status == nil { ProgressView() }
            else {
                if configured {
                    Section("Confirm your identity") {
                        if status?.password == true { Toggle("Use account password", isOn: $usePassword) }
                        if usePassword { SecureField("Account password", text: $password).textContentType(.password) }
                        else { SecureField("Current PIN", text: $currentPIN).keyboardType(.numberPad) }
                    }
                }
                Section(configured ? "New PIN" : "Set a PIN") {
                    SecureField("6-digit PIN", text: $newPIN).keyboardType(.numberPad)
                    SecureField("Confirm PIN", text: $confirmation).keyboardType(.numberPad)
                    Button(configured ? "Change PIN" : "Set PIN") { Task { await save() } }.disabled(!authorized || !newPINValid || busy).requiresWriteAccess()
                }
                Section {
                    Button("Disable biometric unlock on this phone") { LockedPINStore.remove(for: api); message = "Use your PIN the next time you unlock your folder." }
                    if configured { Button("Remove PIN", role: .destructive) { confirmReset = true }.disabled(!authorized || busy).requiresWriteAccess() }
                } footer: { Text("Changing or removing your PIN clears biometric unlock on this phone. Your locked photos remain in your library.") }
                if let message { Text(message).foregroundStyle(.secondary) }
            }
        }.navigationTitle("Locked folder PIN").disabled(busy)
        .task {
            guard let settings else { failure = .init(APIError.signedOut); return }
            do { status = try await settings.authStatus() } catch { failure = .init(error) }
        }
        .onDisappear { clear() }
        .confirmationDialog("Remove your locked folder PIN?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Remove PIN", role: .destructive) { Task { await reset() } }.requiresWriteAccess()
        } message: { Text("All elevated sessions will be locked. You can set a new PIN when you next open the locked folder.") }
        .alert("Couldn’t update PIN", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("OK", role: .cancel) { } } message: { Text(failure?.message ?? "") }
    }
    private func save() async {
        guard let settings else { failure = .init(APIError.signedOut); return }
        busy = true; message = nil; defer { busy = false }
        do {
            if configured { try await settings.changePIN(to: newPIN, currentPIN: usePassword ? nil : currentPIN, password: usePassword ? password : nil) }
            else { try await settings.setPIN(newPIN) }
            LockedPINStore.remove(for: api); clear(); status = try await settings.authStatus(); message = "Your PIN has been saved."
        } catch { failure = .init(error) }
    }
    private func reset() async {
        guard let settings else { failure = .init(APIError.signedOut); return }
        busy = true; message = nil; defer { busy = false }
        do {
            try await settings.removePIN(currentPIN: usePassword ? nil : currentPIN, password: usePassword ? password : nil)
            LockedPINStore.remove(for: api); clear(); status = try await settings.authStatus(); message = "Your PIN has been removed."
        } catch { failure = .init(error) }
    }
    private func clear() { currentPIN = ""; newPIN = ""; confirmation = ""; password = "" }
}
