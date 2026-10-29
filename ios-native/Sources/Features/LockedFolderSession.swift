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

/// One account's Locked Folder (REBUILD_ROADMAP.md N5): unlocking by PIN or biometrics, the
/// server's elevation running out, reading the folder's months as its grid scrolls, and
/// relocking. AccountSession makes one per account, ends it with the account and hands it the
/// app's scene changes, so the folder relocks the moment the app goes to the background, whatever
/// is on screen. Immich unlocks only with the PIN: the account's password resets the PIN, in
/// Settings, and never unlocks.
///
/// Relocking is synchronous: when it returns the folder shows nothing, its viewer is closed, what
/// was typed is gone, the account's private epoch has moved and the pipeline holds no locked
/// photo's image. Only telling the server waits. Everything the folder asks of the server runs
/// under the private epoch of the moment, so an answer that comes after a relock is dropped, and
/// an unlock that lands after one has the server lock again. An unlock waits for the locks asked
/// for before it, so none lands after it, and a lock the server may not have heard is asked for
/// again.
@MainActor @Observable final class LockedFolderSession {
    enum Phase: Equatable, Sendable {
        case locked
        /// An unlock is under way: biometrics are being asked for the PIN, a lock asked for before
        /// is being waited for, or the unlock was sent.
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
        /// Keep the PIN on this phone, behind biometrics.
        var remember = false
    }

    private(set) var phase = Phase.locked
    /// How the folder unlocks, as the server says: whether a PIN is set, and when an unlock runs out.
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
    /// The account's bus: its mutations' results and its sync's changes.
    @ObservationIgnored private let follower = LibraryFollower()
    /// The private epoch the folder is open under; nil while it is locked.
    @ObservationIgnored private var openEpoch: UInt64?
    @ObservationIgnored private var months: [TimeBucket] = []
    @ObservationIgnored private var nextMonth = 0
    /// The last unlock sent. A relock never cancels it, so the server always hears an unlock
    /// before the lock that follows it; it finds itself stale instead.
    @ObservationIgnored private(set) var unlocking: Task<Void, Never>?
    /// The read of the folder's months under way, which a relock cancels.
    @ObservationIgnored private var reading: Task<Void, Never>?
    /// The quiet read a sync's change asked for (G1); another is owed when a change came in while
    /// it ran. A relock cancels it.
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    @ObservationIgnored private var refreshOwed = false
    /// Moves with each change applied to the photos shown, so a quiet read begun before it is
    /// read again rather than shown.
    @ObservationIgnored private var changesApplied = 0
    @ObservationIgnored private var expiry: Task<Void, Never>?
    /// The last request that the server lock the folder, after the ones before it. An unlock waits
    /// for it before it is sent.
    @ObservationIgnored private(set) var serverLock: Task<Void, Never>?
    /// The server may hold the folder unlocked though it is locked here: an unlock was sent, or the
    /// server said its session is elevated, and no lock asked for since was heard. Such a lock is
    /// asked for again (`lockIfOwed`), as Immich extends an elevation while requests keep coming.
    @ObservationIgnored private var serverMayBeUnlocked = false
    /// How many unlocks were sent, and how many of them are on their way. A lock heard clears
    /// `serverMayBeUnlocked` only if no unlock was on its way when it was asked for, which the
    /// server may have heard after it, and none was sent since.
    @ObservationIgnored private var unlocksSent = 0
    @ObservationIgnored private var unlocksUnanswered = 0
    /// Locks asked for and not answered yet.
    @ObservationIgnored private var locksPending = 0
    @ObservationIgnored private var ended = false

    /// The folder has its own query; no library query reaches it.
    private static let timeline = ServerTimelineRequest(LockedFolderQuery())
    /// Months are read until the grid has this many photos to scroll through.
    static let firstPage = 60
    /// The next month is read once one of the last this many photos comes on screen.
    static let readAhead = 30

    /// `mutations` are the account's: a photo moved to the timeline or put in Trash leaves the
    /// folder in place, from the grid's actions or its viewer, and the sync's changes on their bus
    /// reach the folder while it is open.
    init(api: APIClient, pipeline: MediaPipeline, authorization: AuthorizationState, mutations: LibraryMutationService?) {
        self.api = api
        self.pipeline = pipeline
        self.authorization = authorization
        follower.follow(mutations?.bus) { [weak self] event in self?.handle(event) }
        // A photo the viewer finds gone, as when the server relocked, has the folder read again.
        photos.onLoss = { [weak self] in self?.photoLost() }
    }

    // MARK: What the screen reads

    var isUnlocked: Bool { phase == .unlocked }
    /// No PIN is set yet: the form sets one, then unlocks with it.
    var settingUp: Bool { status?.pinCode == false }
    /// Whether what is typed can be sent: a 6-digit PIN, twice to set one.
    var canUnlock: Bool {
        guard phase == .locked, !ended, let status else { return false }
        return Self.isPIN(entry.pin) && (status.pinCode || entry.pin == entry.confirmation)
    }

    private static func isPIN(_ text: String) -> Bool { text.count == 6 && text.allSatisfy { "0123456789".contains($0) } }

    // MARK: Commands

    /// The folder's screen appeared: reads how the folder unlocks, each time, as the PIN may have
    /// been set or changed elsewhere. A server that says the folder is unlocked while it is locked
    /// here, as when a lock was lost or the app was killed with the folder open, is locked.
    func appear() async {
        guard !ended else { return }
        var error: NSError?
        biometricAvailable = LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        do {
            let status = try await api.authStatus()
            guard !ended, phase == .locked else { return }
            self.status = status
            if status.isElevated {
                serverMayBeUnlocked = true
                lockIfOwed(keepingAppAwake: false)
            }
        } catch is CancellationError {
        } catch {
            if !ended { failure = FeatureFailure(error) }
        }
    }

    /// The folder's screen went away: it locks.
    func disappear() { relock(.left) }

    /// The Lock button.
    func lock() { relock(.user) }

    /// The app's scene changed, as AccountSession hears it: going to the background relocks at
    /// once, and coming back asks again for a lock the server may not have heard.
    func sceneChanged(_ scene: ScenePhase) {
        switch scene {
        case .background: relock(.background)
        case .active: lockIfOwed(keepingAppAwake: false)
        default: break
        }
    }

    /// Unlocks with the PIN typed. With no PIN set yet, the PIN typed is set first, which
    /// read-only mode refuses as it refuses any change.
    func unlock() {
        guard canUnlock, let status else { return }
        let pin = entry.pin
        begin(.pin(pin), settingPIN: !status.pinCode, keeping: entry.remember && biometricAvailable ? pin : nil)
    }

    /// Unlocks with the PIN kept on this phone, which Face ID or Touch ID hands over.
    func unlockBiometrically() {
        guard phase == .locked, !ended, biometricAvailable, status?.pinCode == true else { return }
        begin(.biometrics, settingPIN: false, keeping: nil)
    }

    /// A photo of the grid came on screen. Near the end of what is read, the next month is read,
    /// so the folder pages as it scrolls, with no Load more button (the owner's decision).
    func photoAppeared(_ id: String) {
        guard phase == .unlocked, hasMore, !isLoading, refreshing == nil, let epoch = openEpoch,
              photos.assets.suffix(Self.readAhead).contains(where: { $0.id == id }) else { return }
        isLoading = true
        reading = Task { [weak self] in await self?.readMore(epoch: epoch) }
    }

    /// Locks the folder at once, as the type's notes say. The server is told afterwards, unless
    /// the account is closing; going to the background keeps the app running until it has been.
    /// With the folder locked here already, a lock the server may not have heard is asked for again.
    func relock(_ reason: Relock) {
        let wasOpen = phase != .locked || authorization.snapshot.lockedFolderUnlocked
        if entry != Entry() { entry = Entry() }
        guard wasOpen else {
            if reason != .signedOut { lockIfOwed(keepingAppAwake: reason == .background) }
            return
        }
        expiry?.cancel(); expiry = nil
        reading?.cancel(); reading = nil
        refreshing?.cancel(); refreshing = nil; refreshOwed = false
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

    /// Whether the read under way may still show what it read: the folder is open under `epoch`,
    /// and no newer read took the read's place, which cancels it.
    private func isReading(_ epoch: UInt64) -> Bool { isOpen(epoch) && !Task.isCancelled }

    private func unlock(_ credential: Credential, settingPIN: Bool, keeping kept: String?, attempt: UInt64) async {
        let api = api
        // Once the server may have been asked to unlock, a relock that came first must reach it after.
        var sent = false
        let status: AuthStatus
        do {
            let pin: String
            switch credential {
            case .pin(let typed): pin = typed
            case .biometrics:
                // The Keychain asks Face ID or Touch ID for the PIN, off the main actor.
                pin = try await Task.detached(priority: .userInitiated) { try LockedPINStore.read(for: api) }.value
            }
            guard isUnlocking(attempt) else { return }
            if settingPIN {
                try await api.requestVoid(.post, path: "auth/pin-code", body: ["pinCode": pin])
                guard isUnlocking(attempt) else { return }
            }
            // The locks asked for before reach the server first: one landing after the unlock
            // would lock the folder again under it.
            await serverLock?.value
            guard isUnlocking(attempt) else { return }
            sent = true
            try await sendUnlock(pin)
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

    /// Sends the unlock. From now on the server may hold the folder unlocked, and a lock asked for
    /// before the answer comes may reach the server before the unlock does.
    private func sendUnlock(_ pin: String) async throws {
        unlocksSent += 1
        unlocksUnanswered += 1
        serverMayBeUnlocked = true
        defer { unlocksUnanswered -= 1 }
        try await api.unlock(pin: pin)
    }

    /// An unlock the server may have made landed after the folder relocked: the server locks
    /// again, after it. Not when a newer unlock is under way or open, which the server then
    /// serves, nor once the account has closed.
    private func landedAfterRelock() {
        guard !ended, phase == .locked else { return }
        lockServer(keepingAppAwake: UIApplication.shared.applicationState == .background)
    }

    /// A failed unlock, in the server's own words where it gave any, as for a wrong PIN.
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
    /// meanwhile stays out. What is shown, the months it was read from and what is left to read
    /// change together, so a read that fails part-way leaves them in step: what was shown stays
    /// until the newest month arrives, and the grid then reads on from where the read stopped,
    /// never a month twice.
    private func readMonths(epoch: UInt64, relockingOnFailure: Bool) async {
        isLoading = true
        do {
            let months = try await api.timeBuckets(Self.timeline)
            guard isReading(epoch) else { return }
            var newest: [Asset] = []
            if let first = months.first {
                newest = try await month(first)
                guard isReading(epoch) else { return }
            }
            self.months = months
            if photos.assets != newest { photos.assets = newest }
            nextMonth = months.isEmpty ? 0 : 1
            hasMore = nextMonth < months.count
            while hasMore, photos.assets.count < Self.firstPage {
                let page = try await month(months[nextMonth])
                guard isReading(epoch) else { return }
                photos.assets += page
                nextMonth += 1
                hasMore = nextMonth < months.count
            }
            isLoading = false
        } catch is CancellationError {
        } catch {
            guard isReading(epoch) else { return }
            isLoading = false
            if relockingOnFailure {
                // An unlock that can't show the folder is undone, as before.
                relock(.failed)
                refreshStatus()
            }
            failure = FeatureFailure(error)
        }
    }

    /// Reads the next month and adds its photos, unless the folder relocked or was read again
    /// meanwhile. A failure leaves the month to read when the grid next reaches its end.
    private func readMore(epoch: UInt64) async {
        guard nextMonth < months.count else { hasMore = false; isLoading = false; return }
        do {
            let page = try await month(months[nextMonth])
            guard isReading(epoch) else { return }
            photos.assets += page
            nextMonth += 1
            hasMore = nextMonth < months.count
            isLoading = false
        } catch is CancellationError {
        } catch {
            guard isReading(epoch) else { return }
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
            guard isReading(epoch) else { return }
            guard status.isElevated else { return relock(.expired) }
            self.status = status
            watchExpiry(status, epoch: epoch)
        } catch is CancellationError {
            return
        } catch {
            if isReading(epoch) { isLoading = false; failure = FeatureFailure(error) }
            return
        }
        await readMonths(epoch: epoch, relockingOnFailure: false)
    }

    private func handle(_ event: LibraryEvent) {
        switch event {
        case .mutation(.applied(let result)): apply(result)
        case .changed(let change, _): apply(change)
        default: break
        }
    }

    /// A change the account made, here or in the folder's viewer: a photo moved to the timeline or
    /// put in Trash leaves the folder in place, and nothing is read again. A change ending after
    /// the folder relocked finds no photos to change.
    private func apply(_ result: MutationResult) {
        guard phase == .unlocked, !photos.assets.isEmpty, result.changedPhotos else { return }
        changesApplied += 1
        let shown = result.applied(to: photos.assets, keeping: CollectionMembership.lockedFolder)
        if shown != photos.assets { photos.assets = shown }
    }

    /// A sync's change while the folder is open (plan line 78, G1). The offline library lets every
    /// locked photo go, so a photo of the folder that the change upserts is out of it, moved to the
    /// timeline elsewhere: it leaves in place. A locked photo changed, put in Trash or deleted
    /// elsewhere, and a photo locked elsewhere, reach the offline library only as a removal, which
    /// can't tell them apart: the months shown are read again quietly.
    private func apply(_ change: LibraryChange) {
        guard phase == .unlocked, let epoch = openEpoch else { return }
        let out = Set(change.upserted.keys)
        if !out.isEmpty, photos.assets.contains(where: { out.contains($0.id) }) {
            changesApplied += 1
            photos.assets.removeAll { out.contains($0.id) }
        }
        if !change.removed.isEmpty || !change.accessLost.isEmpty || change.reset || change.overflow { refresh(epoch: epoch) }
    }

    /// Reads the months shown again, and any newer month, quietly: the photos read replace those
    /// shown in one go, and the grid reads on from there. One read at a time; a change that comes
    /// in meanwhile has it read once more when it ends, and one the account made here meanwhile has
    /// it read again rather than undo it. A relock drops it.
    private func refresh(epoch: UInt64) {
        guard refreshing == nil else { refreshOwed = true; return }
        refreshing = Task { [weak self] in await self?.refreshShown(epoch: epoch) }
    }

    private func refreshShown(epoch: UInt64) async {
        defer { if openEpoch == epoch { refreshing = nil } }
        repeat {
            refreshOwed = false
            let started = changesApplied
            // The oldest month shown; the folder's months are newest first.
            let reach = nextMonth > 0 && months.indices.contains(nextMonth - 1) ? months[nextMonth - 1].timeBucket : nil
            do {
                let summary = try await api.timeBuckets(Self.timeline)
                let shown = reach.map { reach in Array(summary.prefix { $0.timeBucket >= reach }) } ?? Array(summary.prefix(1))
                var found: [Asset] = []
                for month in shown { found += try await self.month(month) }
                guard isOpen(epoch), !Task.isCancelled else { return }
                // A change was applied here while this read ran: it reads again rather than undo it.
                guard changesApplied == started else { refreshOwed = true; continue }
                // A month the grid asked for meanwhile is read again from where this read stops.
                if let reading { reading.cancel(); self.reading = nil; isLoading = false }
                months = summary
                if photos.assets != found { photos.assets = found }
                nextMonth = shown.count
                hasMore = nextMonth < summary.count
            } catch {
                // A quiet read that fails changes nothing; the next change reads again.
                return
            }
        } while refreshOwed && isOpen(epoch)
    }

    // MARK: The server

    /// Asks the server to lock the folder, after any lock asked for before. Heard, with no unlock on
    /// its way when it was asked for and none sent since, the server holds the folder locked;
    /// otherwise a lock is still owed.
    private func lockServer(keepingAppAwake: Bool) {
        let api = api, previous = serverLock
        let unlocksBefore = unlocksUnanswered == 0 ? unlocksSent : nil
        locksPending += 1
        let lock = Task { [weak self] in
            await previous?.value
            let heard = (try? await api.lock()) != nil
            guard let self else { return }
            self.locksPending -= 1
            if heard, self.unlocksSent == unlocksBefore { self.serverMayBeUnlocked = false }
        }
        serverLock = lock
        if keepingAppAwake { BackgroundTime.hold("Lock the Locked Folder", until: lock) }
    }

    /// Asks the server again for a lock it may not have heard, as one the network lost, while the
    /// folder is locked here and no lock is on its way. The folder's screen coming and going and
    /// the app coming back or leaving ask, so a lost lock costs one request each time, never a loop.
    private func lockIfOwed(keepingAppAwake: Bool) {
        guard serverMayBeUnlocked, locksPending == 0, phase == .locked, !ended else { return }
        lockServer(keepingAppAwake: keepingAppAwake)
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
