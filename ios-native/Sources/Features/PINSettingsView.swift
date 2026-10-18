import SwiftUI

struct PINSettingsView: View {
    let api: APIClient
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
                    Button(configured ? "Change PIN" : "Set PIN") { Task { await save() } }.disabled(!authorized || !newPINValid || busy).requiresWriteAccess(api)
                }
                Section {
                    Button("Disable biometric unlock on this phone") { LockedPINStore.remove(for: api); message = "Use your PIN the next time you unlock your folder." }
                    if configured { Button("Remove PIN", role: .destructive) { confirmReset = true }.disabled(!authorized || busy).requiresWriteAccess(api) }
                } footer: { Text("Changing or removing your PIN clears biometric unlock on this phone. Your locked photos remain in your library.") }
                if let message { Text(message).foregroundStyle(.secondary) }
            }
        }.navigationTitle("Locked folder PIN").disabled(busy)
        .task { do { status = try await api.authStatus() } catch { failure = .init(error) } }
        .onDisappear { clear() }
        .confirmationDialog("Remove your locked folder PIN?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Remove PIN", role: .destructive) { Task { await reset() } }.requiresWriteAccess(api)
        } message: { Text("All elevated sessions will be locked. You can set a new PIN when you next open the locked folder.") }
        .alert("Couldn’t update PIN", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("OK", role: .cancel) { } } message: { Text(failure?.message ?? "") }
    }
    private func save() async {
        busy = true; message = nil; defer { busy = false }
        do {
            if configured {
                try await api.requestVoid(.put, path: "auth/pin-code", body: PINChange(newPinCode: newPIN, pinCode: usePassword ? nil : currentPIN, password: usePassword ? password : nil))
            } else { try await api.requestVoid(.post, path: "auth/pin-code", body: ["pinCode": newPIN]) }
            LockedPINStore.remove(for: api); clear(); status = try await api.authStatus(); message = "Your PIN has been saved."
        } catch { failure = .init(error) }
    }
    private func reset() async {
        busy = true; message = nil; defer { busy = false }
        do {
            try await api.requestVoid(.delete, path: "auth/pin-code", body: PINIdentity(pinCode: usePassword ? nil : currentPIN, password: usePassword ? password : nil))
            LockedPINStore.remove(for: api); clear(); status = try await api.authStatus(); message = "Your PIN has been removed."
        } catch { failure = .init(error) }
    }
    private func clear() { currentPIN = ""; newPIN = ""; confirmation = ""; password = "" }
}
private struct PINIdentity: Encodable, Sendable { let pinCode: String?; let password: String? }
private struct PINChange: Encodable, Sendable { let newPinCode: String; let pinCode: String?; let password: String? }
