import CryptoKit
import LocalAuthentication
import Security
import SwiftUI
import UIKit

extension EnvironmentValues {
    /// The signed-in account's Locked Folder (REBUILD_ROADMAP.md N5). The app sets it at its root;
    /// nil while nobody is signed in.
    @Entry var lockedFolder: LockedFolderSession? = nil
}

/// One account's Locked Folder (REBUILD_ROADMAP.md N5): unlocking by PIN, account password or
/// biometrics, the server's elevation running out, reading the folder's months as its grid
/// scrolls, and relocking. AccountSession makes one per account, ends it with the account and
/// hands it the app's scene changes, so the folder relocks the moment the app goes to the
/// background, whatever is on screen.
///
/// Relocking is synchronous: when it returns the folder shows nothing, its viewer is closed, what
/// was typed is gone, the account's private epoch has moved and the pipeline holds no locked
/// photo's image. Only telling the server waits. Everything the folder asks of the server runs
/// under the private epoch of the moment, so an answer that comes after a relock is dropped, and
/// an unlock that lands after one has the server lock again.
@MainActor @Observable final class LockedFolderSession {
    enum Phase: Equatable, Sendable {
        case locked
        /// An unlock was sent, or biometrics are being asked for the PIN.
        case unlocking
        case unlocked
    }

    /// Why the folder relocks.
    enum Relock: Equatable, Sendable {
        /// The Lock button.
        case user
        /// The app went to the background.
        case background
        /// The folder's screen went away.
        case left
        /// The server's elevation ran out, or the server says it has.
        case expired
        /// An unlock, or the read that follows it, failed.
        case failed
        /// The account closed. The server isn't told: its session ends with the account.
        case signedOut
    }

    /// What is typed into the unlock form. Kept here, so a relock clears it at once.
    struct Entry: Equatable, Sendable {
        var pin = ""
        var confirmation = ""
        var password = ""
        var usePassword = false
        /// Keep the PIN on this phone, behind biometrics.
        var remember = false
    }

    private(set) var phase = Phase.locked
    /// How the folder unlocks, as the server says: whether a PIN is set, whether the account's
    /// password may stand in for it, and when an unlock runs out.
    private(set) var status: AuthStatus?
    /// The phone has Face ID or Touch ID set up, so the PIN can be kept behind it and unlock with it.
    private(set) var biometricAvailable = false
    var entry = Entry()
    /// The folder's photos, newest first, which its viewer pages through.
    let photos = AssetList(keeps: CollectionMembership.lockedFolder)
    /// Some of the folder's months are not read yet.
    private(set) var hasMore = false
    /// An unlock, or a read of the folder's months, is under way.
    private(set) var isLoading = false
    /// The photo open in the folder's viewer.
    var viewing: ViewerRoute?
    var failure: FeatureFailure?

    let api: APIClient
    let pipeline: MediaPipeline
    @ObservationIgnored private let authorization: AuthorizationState
    @ObservationIgnored private let follower = MutationFollower()
    /// The private epoch the folder is open under; nil while it is locked.
    @ObservationIgnored private var openEpoch: UInt64?
    @ObservationIgnored private var months: [TimeBucket] = []
    @ObservationIgnored private var nextMonth = 0
    /// The last unlock sent. A relock never cancels it, so the server always hears an unlock
    /// before the lock that follows it; it finds itself stale instead.
    @ObservationIgnored private(set) var unlocking: Task<Void, Never>?
    /// The read of the folder's months under way, which a relock cancels.
    @ObservationIgnored private var reading: Task<Void, Never>?
    @ObservationIgnored private var expiry: Task<Void, Never>?
    /// The last request that the server lock the folder, after the ones before it.
    @ObservationIgnored private(set) var serverLock: Task<Void, Never>?
    @ObservationIgnored private var ended = false

    /// The folder has its own query; no library query reaches it.
    private static let timeline = ServerTimelineRequest(LockedFolderQuery())
    /// Months are read until the grid has this many photos to scroll through.
    static let firstPage = 60
    /// The next month is read once one of the last this many photos comes on screen.
    static let readAhead = 30

    /// `mutations` are the account's: a photo moved to the timeline or put in Trash leaves the
    /// folder in place, from the grid's actions or its viewer.
    init(api: APIClient, pipeline: MediaPipeline, authorization: AuthorizationState, mutations: LibraryMutationService?) {
        self.api = api
        self.pipeline = pipeline
        self.authorization = authorization
        follower.follow(mutations, applying: { [weak self] result in self?.apply(result) })
        // A photo the viewer finds gone, as when the server relocked, has the folder read again.
        photos.onLoss = { [weak self] in self?.photoLost() }
    }

    // MARK: What the screen reads

    var isUnlocked: Bool { phase == .unlocked }
    /// No PIN is set yet: the form sets one, then unlocks with it.
    var settingUp: Bool { status?.pinCode == false }
    /// Whether what is typed can be sent: a 6-digit PIN (twice, to set one), or the password.
    var canUnlock: Bool {
        guard phase == .locked, !ended, let status else { return false }
        if !status.pinCode { return Self.isPIN(entry.pin) && entry.pin == entry.confirmation }
        return entry.usePassword ? !entry.password.isEmpty : Self.isPIN(entry.pin)
    }

    private static func isPIN(_ text: String) -> Bool { text.count == 6 && text.allSatisfy { "0123456789".contains($0) } }

    // MARK: Commands

    /// The folder's screen appeared: reads how the folder unlocks, each time, as the PIN may have
    /// been set or changed elsewhere.
    func appear() async {
        guard !ended else { return }
        var error: NSError?
        biometricAvailable = LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        do {
            let status = try await api.authStatus()
            if !ended, phase == .locked { self.status = status }
        } catch is CancellationError {
        } catch {
            if !ended { failure = FeatureFailure(error) }
        }
    }

    /// The folder's screen went away: it locks.
    func disappear() { relock(.left) }

    /// The Lock button.
    func lock() { relock(.user) }

    /// The app's scene changed, as AccountSession hears it: going to the background relocks at once.
    func sceneChanged(_ scene: ScenePhase) {
        if scene == .background { relock(.background) }
    }

    /// Unlocks with what was typed: the PIN, or the account password. With no PIN set yet, the
    /// PIN typed is set first, which read-only mode refuses as it refuses any change.
    func unlock() {
        guard canUnlock, let status else { return }
        let entry = entry
        let kept = entry.remember && !entry.usePassword && biometricAvailable ? entry.pin : nil
        if !status.pinCode { begin(.pin(entry.pin), settingPIN: true, keeping: kept) }
        else if entry.usePassword { begin(.password(entry.password), settingPIN: false, keeping: nil) }
        else { begin(.pin(entry.pin), settingPIN: false, keeping: kept) }
    }

    /// Unlocks with the PIN kept on this phone, which Face ID or Touch ID hands over.
    func unlockBiometrically() {
        guard phase == .locked, !ended, biometricAvailable, status?.pinCode == true else { return }
        begin(.biometrics, settingPIN: false, keeping: nil)
    }

    /// A photo of the grid came on screen. Near the end of what is read, the next month is read,
    /// so the folder pages as it scrolls, with no Load more button (the owner's decision).
    func photoAppeared(_ id: String) {
        guard phase == .unlocked, hasMore, !isLoading, let epoch = openEpoch,
              photos.assets.suffix(Self.readAhead).contains(where: { $0.id == id }) else { return }
        isLoading = true
        reading = Task { [weak self] in await self?.readMore(epoch: epoch) }
    }

    /// Locks the folder at once, as the type's notes say. The server is told afterwards, unless
    /// the account is closing; going to the background keeps the app running until it has been.
    func relock(_ reason: Relock) {
        let wasOpen = phase != .locked || authorization.snapshot.lockedFolderUnlocked
        if entry != Entry() { entry = Entry() }
        guard wasOpen else { return }
        expiry?.cancel(); expiry = nil
        reading?.cancel(); reading = nil
        openEpoch = nil
        viewing = nil
        photos.assets = []
        months = []; nextMonth = 0
        hasMore = false
        isLoading = false
        phase = .locked
        // The private epoch moves first: no image asked for while the folder was open can be
        // kept from now on, and an unlock still on its way finds itself stale. Then every image
        // kept before goes.
        authorization.setLockedFolderUnlocked(false)
        pipeline.purgePrivateMedia()
        if reason != .signedOut { lockServer(keepingAppAwake: reason == .background) }
    }

    /// The account closed: the folder locks for good, without telling the server, whose session
    /// ends with the account.
    func end() {
        guard !ended else { return }
        relock(.signedOut)
        ended = true
        follower.stop()
        photos.onLoss = nil
    }

    // MARK: Unlocking

    private enum Credential: Sendable {
        case pin(String)
        case password(String)
        /// The PIN kept on this phone, which biometrics hand over.
        case biometrics
    }

    /// Sends an unlock under the private epoch of the moment; `kept` is a PIN to keep behind
    /// biometrics once the folder opens.
    private func begin(_ credential: Credential, settingPIN: Bool, keeping kept: String?) {
        phase = .unlocking
        isLoading = true
        failure = nil
        let attempt = authorization.snapshot.privateEpoch
        unlocking = Task { [weak self] in await self?.unlock(credential, settingPIN: settingPIN, keeping: kept, attempt: attempt) }
    }

    /// Whether the unlock sent under `attempt` is still wanted.
    private func isUnlocking(_ attempt: UInt64) -> Bool {
        !ended && phase == .unlocking && authorization.snapshot.privateEpoch == attempt
    }

    /// Whether the folder is still open under `epoch`.
    private func isOpen(_ epoch: UInt64) -> Bool {
        !ended && phase == .unlocked && openEpoch == epoch && authorization.snapshot.privateEpoch == epoch
    }

    private func unlock(_ credential: Credential, settingPIN: Bool, keeping kept: String?, attempt: UInt64) async {
        let api = api
        // Once the server may have been asked to unlock, a relock that came first must reach it after.
        var sent = false
        let status: AuthStatus
        do {
            switch credential {
            case .pin(let pin):
                if settingPIN { try await api.requestVoid(.post, path: "auth/pin-code", body: ["pinCode": pin]) }
                guard isUnlocking(attempt) else { return }
                sent = true
                try await api.unlock(pin: pin)
            case .password(let password):
                sent = true
                try await api.requestVoid(.post, path: "auth/session/unlock", body: ["password": password])
            case .biometrics:
                // The Keychain asks Face ID or Touch ID for the PIN, off the main actor.
                let pin = try await Task.detached(priority: .userInitiated) { try LockedPINStore.read(for: api) }.value
                guard isUnlocking(attempt) else { return }
                sent = true
                try await api.unlock(pin: pin)
            }
            guard isUnlocking(attempt) else { return landedAfterRelock() }
            let answer = try await api.authStatus()
            guard isUnlocking(attempt) else { return landedAfterRelock() }
            guard answer.isElevated else { throw ServerFailure.forbidden(nil) }
            status = answer
        } catch {
            guard isUnlocking(attempt) else {
                if sent { landedAfterRelock() }
                return
            }
            relock(.failed)
            failure = Self.unlockFailure(error)
            refreshStatus()
            return
        }
        await open(status, keeping: kept)
    }

    /// An unlock the server may have made landed after the folder relocked: the server locks
    /// again, after it. Not when a newer unlock is under way or open, which the server then
    /// serves, nor once the account has closed.
    private func landedAfterRelock() {
        guard !ended, phase == .locked else { return }
        lockServer(keepingAppAwake: UIApplication.shared.applicationState == .background)
    }

    /// A failed unlock, in the server's own words where it gave any, as for a wrong PIN or password.
    private static func unlockFailure(_ error: any Error) -> FeatureFailure {
        switch error {
        case ServerFailure.http(400, let message?) where !message.isEmpty: FeatureFailure(APIError.invalidResponse(message))
        case ServerFailure.sessionExpired(let message?) where !message.isEmpty: FeatureFailure(APIError.invalidResponse(message))
        default: FeatureFailure(error)
        }
    }

    /// The server unlocked the folder. It opens under a new private epoch, the end of its
    /// elevation is watched, and its first months are read.
    private func open(_ status: AuthStatus, keeping kept: String?) async {
        self.status = status
        entry = Entry()
        let epoch = authorization.setLockedFolderUnlocked(true).privateEpoch
        openEpoch = epoch
        phase = .unlocked
        watchExpiry(status, epoch: epoch)
        if let kept { await keep(kept, epoch: epoch) }
        guard isOpen(epoch) else { return }
        let first = Task { [weak self] () -> Void in await self?.readMonths(epoch: epoch, relockingOnFailure: true) }
        reading = first
        await first.value
    }

    /// Keeps the PIN behind biometrics on this phone, off the main actor. A failure is shown, and
    /// the folder stays open: the PIN still unlocks it, as the message says.
    private func keep(_ pin: String, epoch: UInt64) async {
        let api = api
        do { try await Task.detached(priority: .userInitiated) { try LockedPINStore.save(pin, for: api) }.value }
        catch { if isOpen(epoch) { failure = FeatureFailure(error) } }
    }

    /// Relocks when the server's elevation runs out.
    private func watchExpiry(_ status: AuthStatus, epoch: UInt64) {
        expiry?.cancel(); expiry = nil
        guard let expires = status.pinExpiresAt ?? status.expiresAt else { return }
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, expires.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self, self.isOpen(epoch) else { return }
            self.relock(.expired)
        }
    }

    /// After a failed unlock: how the folder unlocks may have changed, as when a PIN was just set.
    private func refreshStatus() {
        let api = api
        Task { [weak self] in
            guard let status = try? await api.authStatus(), let self, !self.ended, self.phase == .locked else { return }
            self.status = status
        }
    }

    // MARK: Reading the folder

    /// Every photo read from the folder is locked, whatever its row says, so none ever reaches a
    /// library cache.
    private static func locked(_ asset: Asset) -> Asset {
        guard asset.visibility != .locked else { return asset }
        var locked = asset
        locked.visibility = .locked
        return locked
    }

    private func month(_ month: TimeBucket) async throws -> [Asset] {
        try await api.timeBucket(month.timeBucket, of: Self.timeline).map(Self.locked)
    }

    /// Reads the folder's months, then its newest months until the grid has photos to scroll
    /// through; the rest follow as it scrolls. Each month shows as it comes in: the newest replaces
    /// what was shown before, and the others are added after it, so a photo moved out of the folder
    /// meanwhile stays out.
    private func readMonths(epoch: UInt64, relockingOnFailure: Bool) async {
        isLoading = true
        do {
            let months = try await api.timeBuckets(Self.timeline)
            guard isOpen(epoch) else { return }
            self.months = months
            nextMonth = 0
            var replaced = false
            while nextMonth < months.count, !replaced || photos.assets.count < Self.firstPage {
                let page = try await month(months[nextMonth])
                guard isOpen(epoch) else { return }
                if replaced { photos.assets += page } else { photos.assets = page; replaced = true }
                nextMonth += 1
            }
            // The folder is empty now.
            if !replaced, !photos.assets.isEmpty { photos.assets = [] }
            hasMore = nextMonth < months.count
            isLoading = false
        } catch is CancellationError {
        } catch {
            guard isOpen(epoch) else { return }
            isLoading = false
            if relockingOnFailure {
                // An unlock that can't show the folder is undone, as before.
                relock(.failed)
                refreshStatus()
            }
            failure = FeatureFailure(error)
        }
    }

    /// Reads the next month and adds its photos, unless the folder relocked meanwhile.
    private func readMore(epoch: UInt64) async {
        guard nextMonth < months.count else { isLoading = false; return }
        do {
            let page = try await month(months[nextMonth])
            guard isOpen(epoch) else { return }
            photos.assets += page
            nextMonth += 1
            hasMore = nextMonth < months.count
            isLoading = false
        } catch is CancellationError {
        } catch {
            guard isOpen(epoch) else { return }
            isLoading = false
            failure = FeatureFailure(error)
        }
    }

    /// The viewer found a photo gone or out of reach, as when the server relocked: the viewer
    /// closes and the folder is read again, or relocks if the server says it has.
    private func photoLost() {
        guard phase == .unlocked, let epoch = openEpoch else { return }
        viewing = nil
        reading?.cancel()
        isLoading = true
        reading = Task { [weak self] in await self?.reread(epoch: epoch) }
    }

    private func reread(epoch: UInt64) async {
        do {
            let status = try await api.authStatus()
            guard isOpen(epoch) else { return }
            guard status.isElevated else { return relock(.expired) }
            self.status = status
            watchExpiry(status, epoch: epoch)
        } catch is CancellationError {
            return
        } catch {
            if isOpen(epoch) { isLoading = false; failure = FeatureFailure(error) }
            return
        }
        await readMonths(epoch: epoch, relockingOnFailure: false)
    }

    /// A change the account made, here or in the folder's viewer: a photo moved to the timeline or
    /// put in Trash leaves the folder in place, and nothing is read again. A change ending after
    /// the folder relocked finds no photos to change.
    private func apply(_ result: MutationResult) {
        guard phase == .unlocked, !photos.assets.isEmpty else { return }
        let shown = result.applied(to: photos.assets, keeping: CollectionMembership.lockedFolder)
        if shown != photos.assets { photos.assets = shown }
    }

    // MARK: The server

    /// Asks the server to lock the folder, after any lock asked for before.
    private func lockServer(keepingAppAwake: Bool) {
        let api = api, previous = serverLock
        let lock = Task {
            await previous?.value
            try? await api.lock()
        }
        serverLock = lock
        if keepingAppAwake { BackgroundTime.hold("Lock the Locked Folder", until: lock) }
    }
}

/// Keeps the app running in the background until a task ends, or until iOS takes the time back:
/// the server hears the folder relocked before iOS suspends the app.
@MainActor private final class BackgroundTime {
    private var id = UIBackgroundTaskIdentifier.invalid

    static func hold(_ name: String, until task: Task<Void, Never>) {
        let hold = BackgroundTime()
        hold.id = UIApplication.shared.beginBackgroundTask(withName: name) { MainActor.assumeIsolated { hold.end() } }
        Task { await task.value; hold.end() }
    }

    private func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// Only the PIN is persisted here, scoped to server/account and protected by the current biometric set.
/// An unlocked local key never substitutes for successful server-side session elevation.
enum LockedPINStore {
    static let service = "Ilyich.LockedFolder.PIN"
    static func account(_ cacheScope: String) -> String { SHA256.hash(data: Data(cacheScope.utf8)).map { String(format: "%02x", $0) }.joined() }
    private static func query(_ api: APIClient) -> [String: Any] { query(cacheScope: api.cacheScope) }
    private static func query(cacheScope: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account(cacheScope)]
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
    static func remove(for api: APIClient) { remove(cacheScope: api.cacheScope) }
    /// Forgets the PIN of the account `cacheScope` names, as sign-out does.
    static func remove(cacheScope: String) { SecItemDelete(query(cacheScope: cacheScope) as CFDictionary) }
}
