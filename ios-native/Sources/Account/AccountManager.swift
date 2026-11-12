import Foundation
import IlyichPlatform

/// Where the account is, which decides what the app shows and what each command may do.
enum AccountPhase: Equatable, Sendable {
    /// Reading the saved session at launch.
    case restoring
    /// The phone has not been unlocked since it started, so the Keychain is closed. Restoring
    /// starts again once it opens.
    case waitingForUnlock
    /// Saved sign-in is kept while verified purchase access is unavailable.
    case purchaseRequired
    /// Nobody is signed in. Carries the reason when a session just ended.
    case signedOut(SignOutReason?)
    /// Signed in, but the server requires a new password before anything else.
    case passwordChangeRequired
    case active
    case signingOut
}

enum SignOutReason: Equatable, Sendable {
    /// The user signed out, or changed the password to sign in again.
    case user
    /// Immich said the session is gone, and a second check agreed.
    case sessionExpired
}

/// What the screens show of the account, as AccountManager last published it.
struct AccountState: Sendable {
    var phase: AccountPhase
    /// The open account. Nil while nobody is signed in, and from the moment sign-out begins.
    var runtime: AccountRuntime?
    /// For the sign-in screen: why the session ended, or why it couldn't be restored.
    var message: String?
    var savedAccount: SavedAccountSummary? = nil
}

struct SavedAccountSummary: Equatable, Sendable {
    let name: String
    let server: URL
}

/// What sign-out removes besides the session, by reason. Always kept, for either reason: the
/// account's transfers database with its receipts and the staged copies, the read-only flag,
/// shelf order and the app's preferences. Both reasons switch automatic backup off in that
/// database and remove the rest, as every earlier build did.
/// Keeping automatic backup on, and keeping thumbnails and network settings after a session
/// expiry, are open owner questions, so they stay off until the owner answers.
struct SignOutPolicy: Equatable, Sendable {
    /// The offline library's entities, acknowledgements and metadata.
    var clearsLibraryIndex = true
    /// Thumbnails on disk, the URL cache and decoded images, and the month places an earlier build
    /// kept in Caches; the index's month places go with the library index (F5).
    var clearsMedia = true
    /// The server's custom headers, other addresses and client certificate.
    var removesNetworkSettings = true
    /// Automatic backup stays on in the account's transfers database, so signing in to the
    /// account again carries on with it.
    var keepsAutomaticBackup = false

    init(reason: SignOutReason) {}
}

/// The device-wide services that still hold some of an account's work until later milestones
/// move it into the runtime, and the stores sign-out clears outside it.
protocol AccountDevice: Sendable {
    /// Starts the account's backup on the transfer engine each time the account becomes active:
    /// at launch and after every sign-in, so the backup screens show the account signed in
    /// without a relaunch (TransferHost).
    func activateBackup(_ runtime: AccountRuntime) async
    func clearNotifications() async
    /// Forgets the Locked Folder PIN kept for biometric unlock.
    func removeLockedPIN(scope: String) async
    func removeNetworkSettings(server: URL) async throws
    func clearDiagnostics() async
    func cancelTransfers(of account: AccountID) async
}

extension AccountDevice {
    func cancelTransfers(of account: AccountID) async {}
}

/// Makes every client the account layer uses, so that tests can route them to a stub server.
struct AccountClients: Sendable {
    enum Purpose: Sendable {
        /// The signed-in account's client, which asks the account's authorization before each write.
        case session(AuthorizationState)
        /// A quick check of a saved session, with short timeouts.
        case check
        /// Signing in, and asking a server how it signs in, before there is a session.
        case signIn(PurchaseRequestFence?)

        var purchaseFence: PurchaseRequestFence? {
            if case .signIn(let fence) = self { return fence }
            return nil
        }
    }

    let make: @Sendable (_ server: URL, _ credential: StoredCredential?, _ purpose: Purpose) throws -> APIClient
}

/// What AccountManager works with. The app passes `live`; tests pass fakes.
struct AccountDependencies: Sendable {
    var credentials: any CredentialStore
    var mirror: AuthorizationMirror?
    var device: any AccountDevice
    var clients: AccountClients
    /// Each time the phone's protected data becomes available.
    var unlockEvents: @Sendable () async -> AsyncStream<Void>
    /// How long after an expired answer the session is checked again.
    var expiryRecheckDelay: Duration = .seconds(2)
    /// How long sign-out waits for the server to end the session.
    var serverSignOutBudget: Duration = .seconds(3)
}

/// Owns the signed-in account: restores it at launch, signs in and out, and opens and tears down
/// its AccountRuntime. Transitions run one at a time, in the order asked for, each in a task of
/// its own, so the caller going away never stops one halfway. Every change is published to the
/// screens before the transition goes on.
actor AccountManager {
    private(set) var phase: AccountPhase = .restoring
    private(set) var runtime: AccountRuntime?
    private var message: String?
    nonisolated let environment: AccountEnvironment
    private let dependencies: AccountDependencies
    private let presence: AppPresence
    private let present: @MainActor @Sendable (AccountState) -> Void
    /// The last transition asked for; the next one starts after it.
    private var lastTransition: Task<Void, Never>?
    private var unlockWatch: Task<Void, Never>?
    private var purchaseWatch: Task<Void, Never>?
    private let purchaseAccess: PurchaseAccess?
    private var savedCredential: StoredCredential?

    deinit { purchaseWatch?.cancel(); unlockWatch?.cancel() }

    init(environment: AccountEnvironment, dependencies: AccountDependencies, presence: AppPresence,
         purchaseAccess: PurchaseAccess? = nil,
         present: @escaping @MainActor @Sendable (AccountState) -> Void) {
        self.environment = environment
        self.dependencies = dependencies
        self.presence = presence
        self.present = present
        self.purchaseAccess = purchaseAccess
    }

    // MARK: Restore

    /// Opens the saved session, once; later calls find it open. A closed Keychain waits for the
    /// phone to be unlocked and tries again. Anything else that keeps the session from being read
    /// leaves the app signed out with the reason, and the saved session untouched: nothing here
    /// ever signs out, clears a credential or resets the offline library.
    func restore() async {
        watchPurchases()
        await transition { await $0.performRestore() }
    }

    /// Called by the UI and background restore path, and followed independently
    /// here so a paywall view is never the only thing stopping account work.
    func purchaseAccessChanged() async {
        watchPurchases()
        await transition { await $0.reconcilePurchaseAccess() }
    }

    private func watchPurchases() {
        guard purchaseWatch == nil, let purchaseAccess else { return }
        let changes = purchaseAccess.changes()
        purchaseWatch = Task { [weak self] in
            for await _ in changes {
                guard let self, !Task.isCancelled else { return }
                await self.purchaseAccessChanged()
            }
        }
    }

    private func reconcilePurchaseAccess() async {
        guard let purchaseAccess else { return }
        if !purchaseAccess.hasAccess {
            if let runtime {
                savedCredential = runtime.credential
                self.runtime = nil
                runtime.authorization.end()
                phase = .purchaseRequired
                message = nil
                await publish()
                await runtime.transferRuntime?.suspendForPurchase()
                await runtime.cancelAndJoin()
                await runtime.api.shutdown()
            } else {
                if let saved = try? dependencies.credentials.load() { savedCredential = saved }
                stopWatchingForUnlock()
                phase = .purchaseRequired
                message = nil
                await publish()
            }
            return
        }
        // A new signed grant never revives work admitted under the old one.
        if let runtime, !runtime.authorization.permitsServiceUse {
            savedCredential = runtime.credential
            self.runtime = nil
            runtime.authorization.end()
            await runtime.transferRuntime?.suspendForPurchase()
            await runtime.cancelAndJoin()
            await runtime.api.shutdown()
            phase = .purchaseRequired
        }
        if phase == .purchaseRequired || phase == .restoring || phase == .waitingForUnlock {
            phase = .restoring
            await performRestore()
        }
    }

    /// Tries the restore again if it waits for the phone to be unlocked.
    func retryRestoreIfWaiting() async {
        guard phase == .waitingForUnlock else { return }
        await restore()
    }

    private func performRestore() async {
        guard phase == .restoring || phase == .waitingForUnlock || phase == .purchaseRequired else { return }
        if environment.resetsInterfaceState { resetInterfaceState() }
        let saved: StoredCredential?
        do {
            saved = try dependencies.credentials.load()
        } catch CredentialError.locked {
            phase = .waitingForUnlock
            await publish()
            watchForUnlock()
            return
        } catch {
            stopWatchingForUnlock()
            phase = .signedOut(nil)
            message = error.localizedDescription
            await publish()
            return
        }
        stopWatchingForUnlock()
        guard var saved else {
            savedCredential = nil
            phase = .signedOut(nil)
            message = nil
            await publish()
            return
        }
        savedCredential = saved
        guard purchaseAccess?.hasAccess != false else {
            phase = .purchaseRequired
            message = nil
            await publish()
            return
        }
        // Earlier native builds persisted the server flag without the administrator exemption.
        // It is repaired without changing the credentials, so the session and its sync stay.
        if saved.requiresPasswordChange == true, await isAdministrator(saved) {
            saved.requiresPasswordChange = false
            try? dependencies.credentials.save(saved)
        }
        await open(saved)
    }

    private func isAdministrator(_ saved: StoredCredential) async -> Bool {
        guard let client = try? dependencies.clients.make(saved.server, saved, .check) else { return false }
        let user = try? await client.currentUser()
        await client.shutdown()
        return user?.isAdmin == true
    }

    private func watchForUnlock() {
        guard unlockWatch == nil else { return }
        let events = dependencies.unlockEvents
        unlockWatch = Task { [weak self] in
            for await _ in await events() {
                guard let self else { return }
                await self.retryRestoreIfWaiting()
                guard await self.phase == .waitingForUnlock else { return }
            }
        }
    }

    private func stopWatchingForUnlock() {
        unlockWatch?.cancel()
        unlockWatch = nil
    }

    /// Each UI test starts at the default density and server order: one test's pinch or reordered
    /// shelf must not leak into the next. Nor does a test's read-only mode, kept in the App Group
    /// for the fixture account.
    private func resetInterfaceState() {
        UserDefaults.standard.removeObject(forKey: "gridColumns")
        UserDefaults.standard.removeObject(forKey: ThumbnailLimitSetting.defaultsKey)
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("shelfOrder.") || key.hasPrefix("searchChoices.") {
            UserDefaults.standard.removeObject(forKey: key)
        }
        if let account = environment.fixtureAccount { ReadOnlyPolicy.setEnabled(false, server: account.server, userID: account.userID) }
    }

    // MARK: Sign in

    /// Signs in with a password, to a server no older than the app needs. The login goes out at
    /// once; the session it returns opens only once any sign-out in progress has finished.
    func signIn(server: String, email: String, password: String) async throws {
        let fence = try purchaseAccess.map(PurchaseRequestFence.init)
        guard let url = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw APIError.invalidServerURL }
        let client = try dependencies.clients.make(url, nil, .signIn(fence))
        let login: LoginResponse
        do {
            try await client.requireSupportedVersion()
            try fence?.requireAccess()
            login = try await client.login(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
        } catch { await client.shutdown(); throw error }
        await client.shutdown()
        try fence?.requireAccess()
        try await completeSignIn(login, server: client.baseURL, purchaseFence: fence)
    }

    /// Accepts the login single sign-on returned from `server`.
    func completeSSO(_ login: LoginResponse, server: URL, purchaseFence: PurchaseRequestFence? = nil) async throws {
        try await completeSignIn(login, server: server, purchaseFence: purchaseFence)
    }

    /// A client for signing in to `server`, made off the main actor, once the server proved no
    /// older than the app needs. The caller shuts it down.
    func signInClient(for server: URL) async throws -> APIClient {
        let fence = try purchaseAccess.map(PurchaseRequestFence.init)
        let client = try dependencies.clients.make(server, nil, .signIn(fence))
        do {
            try await client.requireSupportedVersion()
            try fence?.requireAccess()
        } catch { await client.shutdown(); throw error }
        return client
    }

    /// How `server` lets people sign in, or nil when it can't be asked.
    func serverFeatures(at server: URL) async -> ServerFeatures? {
        let fence: PurchaseRequestFence?
        do { fence = try purchaseAccess.map(PurchaseRequestFence.init) } catch { return nil }
        guard let client = try? dependencies.clients.make(server, nil, .signIn(fence)) else { return nil }
        let features = try? await client.serverFeatures()
        await client.shutdown()
        return features
    }

    private func completeSignIn(_ login: LoginResponse, server: URL, purchaseFence: PurchaseRequestFence?) async throws {
        let credential = StoredCredential(server: server, token: login.accessToken, userID: login.userId, name: login.name,
                                          requiresPasswordChange: login.requiresPasswordChange)
        let outcome: Result<Void, any Error> = await transition { await $0.accept(credential, purchaseFence: purchaseFence) }
        try outcome.get()
    }

    private func accept(_ credential: StoredCredential, purchaseFence: PurchaseRequestFence?) async -> Result<Void, any Error> {
        do { try requirePurchase(purchaseFence) } catch { return .failure(error) }
        // Unreachable from the screens, which offer sign-in only while signed out. A session open
        // here still ends first, with none of its data removed.
        if let runtime {
            await close(runtime)
            phase = .signedOut(nil)
            message = nil
            await publish()
        }
        do { try requirePurchase(purchaseFence) } catch { return .failure(error) }
        do { try dependencies.credentials.save(credential) } catch { return .failure(error) }
        savedCredential = credential
        stopWatchingForUnlock()
        await open(credential)
        return .success(())
    }

    private func requirePurchase(_ fence: PurchaseRequestFence?) throws {
        guard let purchaseAccess else { return }
        guard let fence, fence.access === purchaseAccess else { throw PurchaseAccessRequired() }
        try fence.requireAccess()
    }

    /// Opens `credential`'s runtime. Transitions run one at a time and every runtime is shut down
    /// within the transition that ends it, so an account reopens only after its previous runtime
    /// has shut down.
    private func open(_ credential: StoredCredential) async {
        guard purchaseAccess?.hasAccess != false else {
            phase = .purchaseRequired
            await publish()
            return
        }
        do {
            let runtime = try await AccountRuntime.open(credential, environment: environment, dependencies: dependencies,
                                                        presence: presence, purchaseAccess: purchaseAccess,
                                                        refused: { [weak self] id, unsupported in
                await self?.serverRefused(id, unsupported)
            }, expired: { [weak self] id, error in
                await self?.sessionMayHaveExpired(id, after: error) ?? false
            })
            guard runtime.authorization.permitsServiceUse else {
                runtime.authorization.end()
                await runtime.cancelAndJoin()
                await runtime.api.shutdown()
                phase = .purchaseRequired
                await publish()
                return
            }
            self.runtime = runtime
            phase = runtime.requiresPasswordChange ? .passwordChangeRequired : .active
            message = nil
            await publish()
            guard runtime.authorization.permitsServiceUse else { return await reconcilePurchaseAccess() }
            await runtime.start()
            if phase == .active, environment.usesDevicePhotos, runtime.authorization.permitsServiceUse {
                await dependencies.device.activateBackup(runtime)
            }
        } catch {
            phase = .signedOut(nil)
            message = error.localizedDescription
            await publish()
        }
    }

    /// Ends a runtime that another session replaces: its work and transport go, its data stays.
    private func close(_ runtime: AccountRuntime) async {
        self.runtime = nil
        runtime.authorization.end()
        await runtime.cancelAndJoin()
        await runtime.api.shutdown()
    }

    // MARK: Sign out

    /// Signs out, as architecture section 4 orders it. Only an explicit request or a confirmed
    /// expiry leads here.
    func signOut(_ reason: SignOutReason) async {
        await transition { manager in
            if manager.runtime != nil { await manager.performSignOut(reason, runtimeID: nil) }
            else { await manager.forgetSavedAccount() }
        }
    }

    private func performSignOut(_ reason: SignOutReason, runtimeID: UUID?) async {
        guard let runtime, runtimeID == nil || runtime.id == runtimeID else { return }
        self.runtime = nil
        phase = .signingOut
        message = nil
        await publish()
        let device = dependencies.device
        let scope = runtime.api.cacheScope
        let policy = SignOutPolicy(reason: reason)
        // 1. Nothing made under the session is current any more, and the mirror says so.
        runtime.authorization.end()
        // The address step 3's requests go to is chosen now, if it needs choosing, while the
        // account's work ends: checking every address can take longer than step 3's budget.
        let address = Task { _ = try? await runtime.api.activeEndpoint() }
        // 2. The account's work ends, and uploads stop while the session can still answer them:
        //    the transfer engine winds down first, then everything the runtime runs.
        await runtime.prepareForSignOut(keepingAutomaticBackup: policy.keepsAutomaticBackup)
        await runtime.cancelAndJoin()
        // 3. While the token and the network settings still work, the session itself ends. Past
        //    the budget, sign-out goes on without it.
        await Self.within(dependencies.serverSignOutBudget) { try? await runtime.api.logout() }
        // 4. The extensions and upload delegates stop seeing the session: the tombstone first, then
        //    the Keychain item.
        var problem: String?
        do { try dependencies.credentials.remove() } catch { problem = error.localizedDescription }
        await device.clearNotifications()
        await device.removeLockedPIN(scope: scope)
        // 5. What the account kept on the phone, as the policy for the reason says.
        if policy.clearsLibraryIndex { await runtime.clearLibrary() }
        if policy.clearsMedia { await runtime.pipeline.removeAll() }
        if policy.removesNetworkSettings, environment.usesDeviceStorage {
            do { try await device.removeNetworkSettings(server: runtime.api.baseURL) }
            catch { problem = problem ?? error.localizedDescription }
        }
        // 6. The transport, and the request log with it. A request still waiting for an address
        //    ends here, unsent.
        await runtime.api.shutdown()
        address.cancel()
        await device.clearDiagnostics()
        // 7.
        phase = .signedOut(reason)
        savedCredential = nil
        message = reason == .sessionExpired ? ServerFailure.sessionExpired(nil).localizedDescription : problem
        await publish()
    }

    /// Explicit sign-out while the purchase screen owns the app. It never opens
    /// AccountRuntime, starts sync or removes staged originals. Offline cache
    /// files remain account-scoped; credentials and connection secrets are removed.
    private func forgetSavedAccount() async {
        let saved = (try? dependencies.credentials.load()) ?? savedCredential
        guard saved != nil || phase == .purchaseRequired || phase == .waitingForUnlock else { return }
        phase = .signingOut
        await publish()
        stopWatchingForUnlock()
        var problem: String?
        do { try dependencies.credentials.remove() } catch { problem = error.localizedDescription }
        if let mirror = dependencies.mirror {
            let next = max(mirror.read()?.epoch ?? 0, mirror.accessEpoch() ?? 0) &+ 1
            mirror.keepAccessEpoch(next)
            mirror.publish(.init(digest: "", epoch: next))
        }
        if let saved {
            await dependencies.device.cancelTransfers(of: saved.account)
            let url = TransferStore.url(for: saved.account, in: environment.transfersDirectory)
            if environment.keepsTransfers, FileManager.default.fileExists(atPath: url.path) {
                let store = TransferStore(url: url)
                if (try? await store.meta().engine) == .transfer {
                    if var preferences = try? await store.preferences() {
                        preferences.automatic = false
                        try? await store.savePreferences(preferences)
                    }
                    try? await store.saveEngineState(intent: .paused, blocker: nil, lastMessage: nil)
                }
                await store.close()
            }
            if let client = try? dependencies.clients.make(saved.server, saved, .check) {
                await Self.within(dependencies.serverSignOutBudget) { try? await client.logout() }
                await client.shutdown()
            }
            let scope = saved.server.absoluteString + "|" + saved.userID
            await dependencies.device.removeLockedPIN(scope: scope)
            if environment.usesDeviceStorage {
                do { try await dependencies.device.removeNetworkSettings(server: saved.server) }
                catch { problem = problem ?? error.localizedDescription }
            }
        }
        await dependencies.device.clearNotifications()
        await dependencies.device.clearDiagnostics()
        savedCredential = nil
        phase = .signedOut(.user)
        message = problem
        await publish()
    }

    /// Whether `error`, which work of runtime `runtimeID` met, ends the session. Only Immich saying
    /// the session is gone, and a second check agreeing, does; a proxy's refusal, a forbidden
    /// answer and a network failure never do. Sign-out then begins as a transition of its own, so
    /// the work that met the failure, which sign-out cancels and waits for, neither cancels it
    /// nor waits on it.
    func sessionMayHaveExpired(_ runtimeID: UUID, after error: any Error) async -> Bool {
        guard let runtime, runtime.id == runtimeID else { return false }
        let api = runtime.api
        guard await SessionPolicy.confirmsExpiry(after: error, delay: dependencies.expiryRecheckDelay,
                                                 recheck: { try await api.validateToken() }),
              self.runtime?.id == runtimeID else { return false }
        Task { await self.transition { await $0.performSignOut(.sessionExpired, runtimeID: runtimeID) } }
        return true
    }

    /// The server runtime `runtimeID` checks with runs a release older than the app needs: the
    /// runtime closes, its data and the saved session kept, and the sign-in screen says which
    /// release the app needs. The next launch asks the server again. As with an expiry, closing
    /// waits for the check that found it, so it runs as a transition of its own.
    func serverRefused(_ runtimeID: UUID, _ unsupported: UnsupportedServer) async {
        guard runtime?.id == runtimeID else { return }
        Task { await self.transition { await $0.performRefusal(unsupported, runtimeID: runtimeID) } }
    }

    private func performRefusal(_ unsupported: UnsupportedServer, runtimeID: UUID) async {
        guard let runtime, runtime.id == runtimeID else { return }
        await close(runtime)
        phase = .signedOut(nil)
        message = unsupported.localizedDescription
        await publish()
    }

    // MARK: Library

    /// Recreates the offline library from the server.
    func resetLibraryMetadata() async {
        await transition { manager in
            guard manager.phase == .active, let sync = manager.runtime?.library?.sync else { return }
            await sync.resetLibraryMetadata()
        }
    }

    /// Clears the account's downloaded previews, for Diagnostics; the feed hears of it on the
    /// account's bus and reads its months again.
    func clearBrowsingCache() async {
        await transition { manager in
            guard let runtime = manager.runtime else { return }
            await runtime.clearBrowsingCache()
        }
    }

    // MARK: Support

    /// Runs `body` after every transition asked for before it, in a task of its own.
    private func transition<T: Sendable>(_ body: @escaping @Sendable (isolated AccountManager) async -> T) async -> T {
        let previous = lastTransition
        let task = Task<T, Never> {
            await previous?.value
            return await body(self)
        }
        lastTransition = Task { _ = await task.value }
        return await task.value
    }

    private func publish() async {
        let summary = savedCredential.map { SavedAccountSummary(name: $0.name, server: $0.server) }
        await present(AccountState(phase: phase, runtime: runtime, message: message, savedAccount: summary))
    }

    /// Runs `work`, and waits for it at most `budget`. Past the budget `work` is cancelled and no
    /// longer waited for: a task group would still wait for it, and a request waiting for the
    /// server's address doesn't end when it is cancelled, only when the transport shuts down.
    private static func within(_ budget: Duration, _ work: @escaping @Sendable () async -> Void) async {
        let (ended, end) = AsyncStream.makeStream(of: Void.self)
        let job = Task { await work(); end.finish() }
        let deadline = Task { try? await Task.sleep(for: budget); end.finish() }
        for await _ in ended {}
        job.cancel()
        deadline.cancel()
    }
}
