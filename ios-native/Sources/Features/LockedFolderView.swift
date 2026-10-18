import SwiftUI
import Security
import LocalAuthentication
import CryptoKit

/// Only the PIN is persisted here, scoped to server/account and protected by the current biometric set.
/// An unlocked local key never substitutes for successful server-side session elevation.
enum LockedPINStore {
    private static let service = "Ilyich.LockedFolder.PIN"
    private static func account(_ api: APIClient) -> String { SHA256.hash(data: Data(api.cacheScope.utf8)).map { String(format: "%02x", $0) }.joined() }
    private static func query(_ api: APIClient) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account(api)]
    }
    static func save(_ pin: String, for api: APIClient) throws {
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, &error) else {
            throw APIError.invalidResponse("Biometric protection is unavailable. You can continue using your PIN.")
        }
        remove(for: api)
        var item = query(api)
        item[kSecValueData as String] = Data(pin.utf8)
        item[kSecAttrAccessControl as String] = control
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw APIError.invalidResponse("The PIN could not be secured on this phone. You can continue using your PIN.") }
    }
    static func read(for api: APIClient) throws -> String {
        let context = LAContext()
        context.localizedReason = "Unlock your Ilyich locked folder"
        var item = query(api)
        item[kSecUseAuthenticationContext as String] = context
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let pin = String(data: data, encoding: .utf8) else {
            throw APIError.invalidResponse(status == errSecUserCanceled ? "Unlock was cancelled." : "Use your PIN to unlock. Biometrics may need to be enabled again.")
        }
        return pin
    }
    static func remove(for api: APIClient) { SecItemDelete(query(api) as CFDictionary) }
}

struct LockedFolderView: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let onOpenAsset: (Asset) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var status: AuthStatus?
    @State private var pin = ""
    @State private var confirmation = ""
    @State private var password = ""
    @State private var usePassword = false
    @State private var remember = false
    @State private var unlocked = false
    @State private var busy = false
    @State private var assets: [Asset] = []
    @State private var buckets: [TimeBucket] = []
    @State private var nextBucket = 0
    @State private var failure: FeatureFailure?
    @State private var viewing: Asset?
    @State private var generation = UUID()
    @State private var biometricAvailable = false
    private var settingUp: Bool { status?.pinCode == false }
    private var validPIN: Bool { pin.count == 6 && pin.allSatisfy { "0123456789".contains($0) } }
    var body: some View {
        Group {
            if unlocked && scenePhase == .active {
                ScrollView {
                    FeatureAssetGrid(pipeline: pipeline, assets: assets) { viewing = $0 }
                    if !busy && assets.isEmpty { FeatureEmpty(title: "Your locked folder is empty", symbol: "lock", description: "Move private photos here from your library.") }
                    if busy { ProgressView().padding(24) }
                    if nextBucket < buckets.count { Button("Load more") { Task { await loadNext() } }.padding() }
                }
            } else {
                Form {
                    Section {
                        Label("Locked folder", systemImage: "lock.shield").font(.title2.bold()).padding(.vertical, 14)
                        Text("Unlock to view your private photos.").foregroundStyle(.secondary)
                    }
                    if status != nil {
                        Section(settingUp ? "Set a 6-digit PIN" : "Unlock") {
                            if !settingUp && usePassword { SecureField("Account password", text: $password).textContentType(.password) }
                            else {
                                SecureField("6-digit PIN", text: $pin).keyboardType(.numberPad).textContentType(.oneTimeCode)
                                if settingUp { SecureField("Confirm PIN", text: $confirmation).keyboardType(.numberPad) }
                            }
                            if biometricAvailable && !usePassword { Toggle("Enable biometric unlock", isOn: $remember) }
                            Button(settingUp ? "Set PIN and unlock" : "Unlock") { Task { await unlock() } }
                                .disabled(busy || (usePassword ? password.isEmpty : !validPIN || (settingUp && pin != confirmation))).requiresWriteAccess(api, when: settingUp)
                        }
                        if !settingUp {
                            if biometricAvailable { Button("Unlock with biometrics", systemImage: "faceid") { Task { await unlockBiometrically() } }.disabled(busy) }
                            if status?.password == true { Button(usePassword ? "Use PIN" : "Use account password") { usePassword.toggle() } }
                        }
                    } else { ProgressView() }
                }
            }
        }.navigationTitle("Locked folder")
        .toolbar { if unlocked { ToolbarItem(placement: .topBarTrailing) { Button("Lock", systemImage: "lock") { Task { await relock() } } } } }
        .task {
            var error: NSError?
            biometricAvailable = LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
            do { status = try await api.authStatus() } catch { failure = .init(error) }
        }
        .sheet(item: $viewing) { asset in
            AssetViewer(api: api, pipeline: pipeline, assets: assets, initial: asset, onUpdated: { updated in
                if updated.visibility != .locked { assets.removeAll { $0.id == updated.id } }
                else if let index = assets.firstIndex(where: { $0.id == updated.id }) { assets[index] = updated }
            }, onDeleted: { viewing = nil; Task { do { try await loadUnlocked() } catch { failure = .init(error) } } })
        }
        .task(id: unlocked) {
            guard unlocked, let expires = status?.pinExpiresAt ?? status?.expiresAt else { return }
            do { try await Task.sleep(for: .seconds(max(0, expires.timeIntervalSinceNow))); await relock() } catch { }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { viewing = nil; unlocked = false; assets = []; generation = UUID(); Task { await relock() } }
        }
        .onDisappear { generation = UUID(); Task { await relock() } }
        .alert("Couldn’t unlock folder", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("OK", role: .cancel) { } } message: { Text(failure?.message ?? "") }
    }
    private var filter: TimelineFilter { var filter = TimelineFilter(); filter.visibility = .locked; filter.withStacked = false; return filter }
    private func unlock() async {
        let requestGeneration = generation
        busy = true; defer { if requestGeneration == generation { busy = false } }
        do {
            if settingUp { try await api.requestVoid(.post, path: "auth/pin-code", body: ["pinCode": pin]) }
            if usePassword { try await api.requestVoid(.post, path: "auth/session/unlock", body: ["password": password]) }
            else { try await api.unlock(pin: pin) }
            guard requestGeneration == generation else { try? await api.lock(); return }
            if remember && !usePassword { try LockedPINStore.save(pin, for: api) }
            pin = ""; confirmation = ""; password = ""
            try await loadUnlocked()
        } catch { await relock(); status = try? await api.authStatus(); failure = .init(error) }
    }
    private func unlockBiometrically() async {
        let requestGeneration = generation
        busy = true; defer { if requestGeneration == generation { busy = false } }
        do {
            let client = api
            let securedPIN = try await Task.detached(priority: .userInitiated) { try LockedPINStore.read(for: client) }.value
            try await api.unlock(pin: securedPIN)
            guard requestGeneration == generation else { try? await api.lock(); return }
            try await loadUnlocked()
        } catch { await relock(); failure = .init(error) }
    }
    private func loadUnlocked() async throws {
        let requestGeneration = generation
        let status = try await api.authStatus()
        guard status.isElevated else { throw APIError.forbidden }
        let result = try await api.timeBuckets(filter: filter)
        guard requestGeneration == generation else { return }
        self.status = status; buckets = result; nextBucket = 0; assets = []; unlocked = true
        if !buckets.isEmpty {
            let page = try await api.timeBucket(buckets[0].timeBucket, filter: filter)
            guard requestGeneration == generation else { return }
            assets = page; nextBucket = 1
        }
    }
    private func loadNext() async {
        guard !busy, unlocked, nextBucket < buckets.count else { return }
        let requestGeneration = generation
        busy = true; defer { if requestGeneration == generation { busy = false } }
        do {
            let page = try await api.timeBucket(buckets[nextBucket].timeBucket, filter: filter)
            guard requestGeneration == generation else { return }
            assets += page; nextBucket += 1
        } catch { failure = .init(error) }
    }
    private func relock() async {
        let token = UUID(); generation = token
        busy = true; viewing = nil; unlocked = false; assets = []; buckets = []; pin = ""; confirmation = ""; password = ""
        defer { if generation == token { busy = false } }
        try? await api.lock()
        await pipeline.removePrivate()
    }
}
