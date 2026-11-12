import Foundation
import Observation
import StoreKit

enum PurchaseOutcome: Equatable, Sendable {
    case purchased
    case cancelled
    case pending
    case failed(String)
}

/// App-scoped StoreKit owner. Catalog requests never decide access and never delay an already
/// verified offline entitlement. Restoring is the only operation that calls AppStore.sync().
@MainActor @Observable final class PurchaseStore {
    nonisolated let access: PurchaseAccess
    private(set) var state: PurchaseAccessState = .checking
    private(set) var products: [Product] = []
    private(set) var introductoryOfferEligible = Set<String>()
    private(set) var isLoadingProducts = false
    private(set) var isPurchasing = false
    private(set) var isRestoring = false
    private(set) var message: String?

    @ObservationIgnored private let client: any PurchaseClient
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var transactions: [UInt64: PurchaseTransaction] = [:]
    @ObservationIgnored private var observedEvents: [UInt64: PurchaseTransaction] = [:]
    @ObservationIgnored private var eventRevision: UInt64 = 0
    @ObservationIgnored private var readRevision: UInt64 = 0
    @ObservationIgnored private var lifecycle: UInt64 = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var initialRead: Task<Void, Never>?
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var accessListener: Task<Void, Never>?
    @ObservationIgnored private var catalogTask: Task<Void, Never>?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var eligibilityTask: Task<Void, Never>?
    @ObservationIgnored private var eventRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var acknowledgements: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var eligibilityRevision: UInt64 = 0

    init(client: any PurchaseClient = StoreKitPurchaseClient(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.now = now
        access = PurchaseAccess(now: now)
    }

    deinit {
        initialRead?.cancel()
        listener?.cancel()
        accessListener?.cancel()
        catalogTask?.cancel()
        expiryTask?.cancel()
        eligibilityTask?.cancel()
        eventRefreshTask?.cancel()
        for task in acknowledgements.values { task.cancel() }
    }

    var hasAccess: Bool {
        _ = state // Participate in Observation; the access listener publishes deadline changes.
        return access.hasAccess
    }

    /// Returns after the first entitlement read, not after the long-lived update listener.
    func start() async {
        if let initialRead { await initialRead.value; return }
        if started { return }
        started = true
        lifecycle &+= 1
        let epoch = lifecycle
        // Install the shared startup task before the first suspension. Foreground and background
        // callers arriving together must both await the same initial ownership check.
        let task = Task { [weak self] in
            guard let self else { return }
            await self.initialize(epoch: epoch)
        }
        initialRead = task
        await task.value
        if lifecycle == epoch { initialRead = nil }
    }

    private func initialize(epoch: UInt64) async {
        guard lifecycle == epoch, !Task.isCancelled else { return }
        let changes = access.changes()
        accessListener = Task { [weak self] in
            for await _ in changes {
                guard !Task.isCancelled, let self, self.lifecycle == epoch else { break }
                self.state = self.access.snapshot.state
                self.scheduleExpiry()
            }
        }
        // Install the StoreKit listener before reading currentEntitlements to avoid losing a
        // purchase completed by another device between initial read and listener registration.
        let updates = await client.updates()
        guard lifecycle == epoch, !Task.isCancelled else { return }
        listener = Task { [weak self] in
            for await update in updates {
                guard !Task.isCancelled, let self, self.lifecycle == epoch else { break }
                self.receive(update)
            }
        }
        catalogTask = Task { [weak self] in
            guard let self else { return }
            await self.loadProducts()
        }
        await refreshAccess()
    }

    func stop() {
        lifecycle &+= 1
        started = false
        initialRead?.cancel(); initialRead = nil
        listener?.cancel(); listener = nil
        accessListener?.cancel(); accessListener = nil
        catalogTask?.cancel(); catalogTask = nil
        expiryTask?.cancel(); expiryTask = nil
        eligibilityTask?.cancel(); eligibilityTask = nil
        eventRefreshTask?.cancel(); eventRefreshTask = nil
        for task in acknowledgements.values { task.cancel() }
        acknowledgements = [:]
    }

    func loadProducts() async {
        guard !isLoadingProducts else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            let result = try await client.products()
            guard !Task.isCancelled else { return }
            products = AccessProductID.allCases.compactMap { id in result.first { $0.id == id.rawValue } }
            await scheduleEligibilityRefresh()?.value
        } catch {
            guard !Task.isCancelled else { return }
            // Keep a previously loaded catalog and all signed access during an App Store outage.
            if products.isEmpty { message = "App Store prices could not be loaded. You can retry or restore an existing purchase." }
        }
    }

    func refreshAccess() async {
        readRevision &+= 1
        let request = readRevision, revision = eventRevision, epoch = lifecycle
        _ = access.snapshot // Enforce a known deadline before any asynchronous StoreKit request.
        do {
            let result = try await client.entitlements()
            guard !Task.isCancelled, request == readRevision, revision == eventRevision, epoch == lifecycle else { return }
            var next = Dictionary(result.transactions.map { ($0.transactionID, $0) },
                                  uniquingKeysWith: PurchaseTransaction.newest)
            for (id, observed) in observedEvents {
                if let current = next[id] {
                    let newest = PurchaseTransaction.newest(observed, current)
                    next[id] = newest
                    observedEvents[id] = newest
                }
            }
            transactions = next
            if let entitlement = bestEntitlement() { publish(.unlocked(entitlement)) }
            else if result.hasUnverifiedPurchase {
                publish(.unavailable("The App Store purchase could not be verified. Connect to the App Store and check access again."))
            } else { publish(.locked) }
            scheduleEligibilityRefresh()
        } catch {
            guard !Task.isCancelled, request == readRevision, revision == eventRevision, epoch == lifecycle else { return }
            let current = access.snapshot
            if current.hasAccess { publish(current.state) }
            else { publish(.unavailable("Access could not be checked. Connect to the App Store and try again, or restore your purchase.")) }
        }
    }

    func purchase(_ product: Product) async -> PurchaseOutcome {
        await purchase(productID: product.id)
    }

    /// Also used by domain tests; this still purchases through the injected StoreKit boundary.
    func purchase(productID: String) async -> PurchaseOutcome {
        guard !isPurchasing, !isRestoring else { return .failed("A purchase operation is already in progress.") }
        guard AccessProductID(rawValue: productID) != nil else { return .failed("This is not an Ilyich access plan.") }
        isPurchasing = true
        message = nil
        defer { isPurchasing = false }
        do {
            let result = try await client.purchase(productID: productID)
            switch result {
            case .verified(let transaction):
                accept(transaction, explicitPurchase: true)
                acknowledge(transaction.transactionID)
                if transaction.entitlement(at: now()) == nil { await refreshAccess() }
                scheduleEligibilityRefresh()
                if hasAccess { return .purchased }
                return failure("The purchase completed but no active access could be verified. Check access or restore purchases.")
            case .unverified: return failure("The App Store purchase could not be verified. No access was granted. Try restoring your purchase.")
            case .cancelled: return .cancelled
            case .pending:
                message = "Your purchase is awaiting approval. Access will update when Apple completes it."
                return .pending
            }
        } catch { return failure(error.localizedDescription) }
    }

    func restore() async -> PurchaseOutcome {
        guard !isPurchasing, !isRestoring else { return .failed("A purchase operation is already in progress.") }
        isRestoring = true
        message = nil
        defer { isRestoring = false }
        do {
            try await client.sync()
            await refreshAccess()
            if hasAccess { message = "Your App Store access has been restored."; return .purchased }
            if case .unavailable(let reason) = state { return failure(reason) }
            return failure("No active Ilyich purchase was found for this Apple Account.")
        } catch {
            // A failed explicit restore must not remove an otherwise valid signed grant.
            let current = access.snapshot
            if current.hasAccess { publish(current.state) }
            else { publish(.unavailable("The App Store could not restore access. Connect and try again.")) }
            return failure("Purchases could not be restored. \(error.localizedDescription)")
        }
    }

    private func receive(_ update: PurchaseUpdate) {
        switch update {
        case .verified(let transaction):
            let current = bestEntitlement()?.transactionID
            let accepted = accept(transaction)
            acknowledge(transaction.transactionID)
            if accepted, transaction.entitlement(at: now()) == nil,
               current == transaction.transactionID || !hasAccess { reconcileAfterEvent() }
            scheduleEligibilityRefresh()
        case .unverified:
            message = "An App Store update could not be verified. Check access again when connected."
        }
    }

    @discardableResult private func accept(_ transaction: PurchaseTransaction, explicitPurchase: Bool = false) -> Bool {
        guard AccessProductID(rawValue: transaction.productID) != nil else { return false }
        let latest = observedEvents[transaction.transactionID] ?? transactions[transaction.transactionID]
        let newest = latest.map { PurchaseTransaction.newest($0, transaction) } ?? transaction
        observedEvents[transaction.transactionID] = newest
        // After an authoritative empty history, a duplicate queued event cannot replay access.
        // A new signed event or an explicit successful Apple purchase can deliver it again.
        let hasNewProof = latest.map { $0 != newest } ?? true
        guard explicitPurchase || hasNewProof else { return false }
        // Duplicate/stale delivery must not cancel an authoritative check already in flight.
        eventRefreshTask?.cancel()
        eventRefreshTask = nil
        eventRevision &+= 1
        message = nil
        transactions[transaction.transactionID] = newest
        if let entitlement = bestEntitlement() { publish(.unlocked(entitlement)) }
        else { publish(.locked) }
        return true
    }

    private func acknowledge(_ transactionID: UInt64) {
        // A slow/outage-bound finish must never stop consumption of a later expiry or refund.
        // Proof is already delivered; these owned acknowledgements cannot grant access.
        let id = UUID(), client = client
        acknowledgements[id] = Task { [weak self] in
            await client.finish(transactionID: transactionID)
            self?.acknowledgements[id] = nil
        }
    }

    private func reconcileAfterEvent() {
        eventRefreshTask?.cancel()
        eventRefreshTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.refreshAccess()
        }
    }

    private func bestEntitlement() -> PurchaseEntitlement? {
        PurchaseTransaction.best(in: Array(transactions.values), at: now())
    }

    private func publish(_ next: PurchaseAccessState) {
        access.update(next)
        state = access.snapshot.state
        scheduleExpiry()
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = nil
        guard case .unlocked(let entitlement) = state, let deadline = entitlement.expirationDate else { return }
        let seconds = max(0, deadline.timeIntervalSince(now()))
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.expiryTask = nil
            self.state = self.access.snapshot.state
            await self.refreshAccess()
        }
    }

    private func failure(_ reason: String) -> PurchaseOutcome { message = reason; return .failed(reason) }

    @discardableResult private func scheduleEligibilityRefresh() -> Task<Void, Never>? {
        eligibilityTask?.cancel()
        eligibilityTask = nil
        eligibilityRevision &+= 1
        let revision = eligibilityRevision
        let epoch = lifecycle
        introductoryOfferEligible = []
        guard !products.isEmpty else { return nil }
        let products = products, client = client
        let task = Task { [weak self] in
            let eligible = await client.introductoryOfferEligible(products)
            guard let self, revision == self.eligibilityRevision, epoch == self.lifecycle, !Task.isCancelled else { return }
            self.introductoryOfferEligible = eligible
        }
        eligibilityTask = task
        return task
    }
}
