import Foundation
import StoreKit
import Synchronization
import XCTest
@testable import Ilyich

@MainActor final class PurchaseStoreTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    func testCachedSignedEntitlementWorksWithoutCatalogOrImplicitRestore() async throws {
        let client = PurchaseFakeClient(read: [record()])
        await client.failCatalog(true)
        let date = self.date
        let store = PurchaseStore(client: client, now: { date })
        defer { store.stop() }
        await store.start()
        XCTAssertTrue(store.hasAccess)
        let generation = store.access.snapshot.generation
        await client.failReads(true)
        await store.refreshAccess()
        XCTAssertTrue(store.hasAccess, "An App Store outage cannot revoke a still-valid signed grant.")
        XCTAssertEqual(store.access.snapshot.generation, generation)
        let syncs = await client.syncCount
        XCTAssertEqual(syncs, 0, "Launch and foreground refresh must not prompt an App Store restore.")
    }

    func testUnknownAccessNeverUnlocksDuringOutageAndRestoreIsExplicit() async {
        let client = PurchaseFakeClient(read: [])
        await client.failReads(true)
        let store = PurchaseStore(client: client)
        defer { store.stop() }
        await store.start()
        XCTAssertFalse(store.hasAccess)
        if case .unavailable = store.state { } else { XCTFail("Expected an unavailable, fail-closed state.") }
        await client.failReads(false)
        await client.setRead([record(lifetime: true)])
        let outcome = await store.restore()
        XCTAssertEqual(outcome, .purchased)
        XCTAssertTrue(store.hasAccess)
        let syncs = await client.syncCount
        XCTAssertEqual(syncs, 1)
    }

    func testCancelledAndPendingPurchaseDoNotRemoveExistingAccess() async {
        let client = PurchaseFakeClient(read: [record(lifetime: true)])
        let store = PurchaseStore(client: client)
        defer { store.stop() }
        await store.start()
        let generation = store.access.snapshot.generation
        await client.setPurchase(.cancelled)
        let cancelled = await store.purchase(productID: AccessProductID.monthly.rawValue)
        XCTAssertEqual(cancelled, .cancelled)
        XCTAssertNil(store.message)
        await client.setPurchase(.pending)
        let pending = await store.purchase(productID: AccessProductID.yearly.rawValue)
        XCTAssertEqual(pending, .pending)
        XCTAssertNotNil(store.message)
        XCTAssertTrue(store.hasAccess)
        XCTAssertEqual(store.access.snapshot.generation, generation)
        let finished = await client.finished
        XCTAssertTrue(finished.isEmpty)
    }

    func testInitiallyLockedPendingPurchaseUnlocksOnlyAfterVerifiedApproval() async throws {
        let client = PurchaseFakeClient(read: [])
        let date = self.date
        let store = PurchaseStore(client: client, now: { date })
        defer { store.stop() }
        await store.start()
        XCTAssertEqual(store.state, .locked)
        let lockedGeneration = store.access.snapshot.generation
        await client.setPurchase(.pending)
        let result = await store.purchase(productID: AccessProductID.monthly.rawValue)
        XCTAssertEqual(result, .pending)
        XCTAssertFalse(store.hasAccess)
        XCTAssertEqual(store.state, .locked)
        XCTAssertEqual(store.access.snapshot.generation, lockedGeneration)
        let beforeApproval = await client.finished
        XCTAssertTrue(beforeApproval.isEmpty)

        await client.send(.verified(record()))
        try await until { store.hasAccess }
        try await until { await client.finished.count == 1 }
        if case .unlocked(let grant) = store.state { XCTAssertEqual(grant.productID, AccessProductID.monthly.rawValue) }
        else { XCTFail("Only the verified approval may unlock the pending purchase.") }
        XCTAssertNil(store.message)
    }

    func testVerifiedPurchaseDeliversBeforeFinishAndUnverifiedNeverFinishes() async throws {
        let client = PurchaseFakeClient(read: [])
        let date = self.date
        let store = PurchaseStore(client: client, now: { date })
        defer { store.stop() }
        await store.start()
        await client.setPurchase(.unverified)
        let unverified = await store.purchase(productID: AccessProductID.monthly.rawValue)
        if case .failed = unverified { } else { XCTFail("Unverified purchase must fail.") }
        XCTAssertFalse(store.hasAccess)
        var finished = await client.finished
        XCTAssertTrue(finished.isEmpty)
        let accessAtFinish = Mutex(false)
        let access = store.access
        await client.onFinish { accessAtFinish.withLock { $0 = access.hasAccess } }
        await client.setPurchase(.verified(record()))
        let purchased = await store.purchase(productID: AccessProductID.monthly.rawValue)
        XCTAssertEqual(purchased, .purchased)
        XCTAssertTrue(store.hasAccess, "The verified purchase must not be overwritten by a lagging empty initial history.")
        try await until { await client.finished.count == 1 }
        XCTAssertTrue(accessAtFinish.withLock { $0 })
        finished = await client.finished
        XCTAssertEqual(finished, [1])
        await store.refreshAccess()
        XCTAssertFalse(store.hasAccess, "A later authoritative empty history, such as an Apple Account change, must reconcile ownership.")
        await client.send(.verified(record()))
        try await until { await client.finished.count == 2 }
        XCTAssertFalse(store.hasAccess, "A queued duplicate cannot replay access after ownership reconciliation.")
    }

    func testRefundFencesImmediatelyAndLateReadCannotResurrectIt() async throws {
        let client = PurchaseFakeClient(read: [record()])
        let date = self.date
        let store = PurchaseStore(client: client, now: { date })
        defer { store.stop() }
        await store.start()
        let generation = store.access.snapshot.generation
        await client.holdNextRead()
        let staleRefresh = Task { await store.refreshAccess() }
        try await until { await client.isReadHeld }
        await client.setRead([])
        await client.send(.verified(record(revoked: date)))
        try await until { !store.hasAccess }
        XCTAssertFalse(store.access.permits(generation: generation))
        await client.releaseRead()
        await staleRefresh.value
        XCTAssertFalse(store.hasAccess)
        // Even a subsequent stale StoreKit snapshot cannot resurrect the exact refunded proof.
        await client.setRead([record()])
        await store.refreshAccess()
        XCTAssertFalse(store.hasAccess)
        await client.send(.verified(record(id: 2)))
        try await until { store.hasAccess }
        XCTAssertFalse(store.access.permits(generation: generation), "A genuine new purchase requires a new work generation.")
    }

    func testSignedTrialExpiresWithoutResetOnRefreshAndRenewalKeepsWorkAlive() async throws {
        let clock = PurchaseTestClock(date)
        let client = PurchaseFakeClient(read: [record(expiration: date.addingTimeInterval(10))])
        let store = PurchaseStore(client: client, now: { clock.now })
        defer { store.stop() }
        await store.start()
        let generation = store.access.snapshot.generation
        let renewal = record(id: 2, expiration: date.addingTimeInterval(100))
        await client.setRead([renewal])
        await store.refreshAccess()
        XCTAssertTrue(store.access.permits(generation: generation))
        clock.advance(100)
        XCTAssertFalse(store.hasAccess)
        await store.refreshAccess()
        XCTAssertFalse(store.hasAccess, "Re-reading an expired Apple trial must not start a new local trial.")
    }

    func testOldRefundOrUpgradeCannotRemoveAValidLaterRenewal() async throws {
        let old = record()
        let current = record(id: 2, expiration: date.addingTimeInterval(1_000))
        let client = PurchaseFakeClient(read: [old, current])
        let date = self.date
        let store = PurchaseStore(client: client, now: { date })
        defer { store.stop() }
        await store.start()
        let generation = store.access.snapshot.generation
        await client.setRead([current])
        await client.send(.verified(record(revoked: date, signedOffset: 10)))
        try await until { await client.finished.count == 1 }
        XCTAssertTrue(store.access.permits(generation: generation))
        if case .unlocked(let grant) = store.state { XCTAssertEqual(grant.transactionID, 2) }
        else { XCTFail("An old-period refund must preserve the later signed renewal.") }
        await client.send(.verified(record(upgraded: true, signedOffset: 20)))
        try await until { await client.finished.count == 2 }
        XCTAssertTrue(store.access.permits(generation: generation))
    }

    func testNewerSignedRefundReversalSupersedesRevocation() async throws {
        let client = PurchaseFakeClient(read: [record()])
        let date = self.date
        let store = PurchaseStore(client: client, now: { date })
        defer { store.stop() }
        await store.start()
        let oldGeneration = store.access.snapshot.generation
        await client.setRead([])
        await client.send(.verified(record(revoked: date, signedOffset: 10)))
        try await until { !store.hasAccess }
        await client.send(.verified(record(signedOffset: 1)))
        try await until { await client.finished.count == 2 }
        XCTAssertFalse(store.hasAccess, "An older signed event cannot reverse a newer refund.")
        await client.send(.verified(record(signedOffset: 20)))
        try await until { store.hasAccess }
        XCTAssertFalse(store.access.permits(generation: oldGeneration))
    }

    func testRestoreReadFailureReportsUnavailableInsteadOfNoPurchase() async {
        let client = PurchaseFakeClient(read: [])
        let store = PurchaseStore(client: client)
        defer { store.stop() }
        await store.start()
        await client.failReads(true)
        let result = await store.restore()
        guard case .unavailable(let reason) = store.state else { XCTFail("Restore must preserve the verification failure."); return }
        XCTAssertEqual(result, .failed(reason))
        XCTAssertFalse(reason.contains("No active"))
    }

    func testFailedRestorePreservesValidSignedAccess() async {
        let client = PurchaseFakeClient(read: [record(lifetime: true)])
        let store = PurchaseStore(client: client)
        defer { store.stop() }
        await store.start()
        let generation = store.access.snapshot.generation
        await client.failSync(true)
        let result = await store.restore()
        if case .failed = result { } else { XCTFail("The failed explicit restore must be reported.") }
        XCTAssertTrue(store.access.permits(generation: generation))
    }

    func testExpiryPublishesToUIWithoutForegroundRefresh() async throws {
        let now = Date()
        let proof = PurchaseTransaction(productID: AccessProductID.monthly.rawValue, kind: .subscription,
                                        transactionID: 1, originalTransactionID: 1, purchaseDate: now, signedDate: now,
                                        expirationDate: now.addingTimeInterval(2), revocationDate: nil, isUpgraded: false)
        let store = PurchaseStore(client: PurchaseFakeClient(read: [proof]))
        defer { store.stop() }
        await store.start()
        XCTAssertTrue(store.hasAccess)
        try await until { store.state == .locked }
        XCTAssertFalse(store.hasAccess)
    }

    func testSignedExpiryEndsAccessAndNewPositiveProofSurvivesLaggingHistory() async throws {
        let client = PurchaseFakeClient(read: [record()])
        let date = self.date
        let store = PurchaseStore(client: client, now: { date })
        defer { store.stop() }
        await store.start()
        let generation = store.access.snapshot.generation
        // A newer verified transaction shortens the signed expiry. A stale ownership snapshot
        // still contains the old longer transaction for the same ID.
        let expired = record(expiration: date.addingTimeInterval(-1), signedOffset: 10)
        await client.send(.verified(expired))
        try await until {
            let reads = await client.readCount
            return !store.hasAccess && reads >= 2
        }
        XCTAssertFalse(store.access.permits(generation: generation))
        let before = await client.readCount
        await client.setRead([])
        await client.send(.verified(record(signedOffset: 20)))
        try await until { store.hasAccess }
        let after = await client.readCount
        XCTAssertEqual(after, before, "New positive proof must not trigger an immediate, lagging empty-history overwrite.")
        try await until { await client.finished.count == 2 }
        await store.refreshAccess()
        XCTAssertFalse(store.hasAccess, "A later explicit ownership reconciliation remains authoritative.")
    }

    func testSlowTransactionFinishCannotDelaySubscriptionExpiry() async throws {
        let client = PurchaseFakeClient(read: [])
        let date = self.date
        let store = PurchaseStore(client: client, now: { date })
        defer { store.stop(); Task { await client.releaseFinish() } }
        await store.start()
        await client.holdNextFinish()
        await client.setPurchase(.verified(record()))
        let result = await store.purchase(productID: AccessProductID.monthly.rawValue)
        XCTAssertEqual(result, .purchased)
        try await until { await client.isFinishHeld }
        let generation = store.access.snapshot.generation
        await client.send(.verified(record(expiration: date.addingTimeInterval(-1), signedOffset: 10)))
        try await until { !store.hasAccess }
        let stillFinishing = await client.isFinishHeld
        XCTAssertTrue(stillFinishing, "Expiry must be consumed while the preceding acknowledgement is still waiting.")
        XCTAssertFalse(store.access.permits(generation: generation))
        await client.releaseFinish()
        try await until { await client.finished.count == 2 }
    }

    func testDuplicatePositiveTransactionCannotInvalidateAuthoritativeReconciliation() async throws {
        let proof = record()
        let client = PurchaseFakeClient(read: [proof])
        let date = self.date
        let store = PurchaseStore(client: client, now: { date })
        defer { store.stop(); Task { await client.releaseRead() } }
        await store.start()
        let generation = store.access.snapshot.generation
        // The foreground ownership read must finish even if an unchanged future-dated
        // transaction is redelivered while it waits.
        await client.setRead([])
        await client.holdNextRead()
        let reconciliation = Task { await store.refreshAccess() }
        try await until { await client.isReadHeld }
        await client.send(.verified(proof))
        try await until { await client.finished.count == 1 }
        await client.releaseRead()
        await reconciliation.value
        try await until { !store.hasAccess }
        XCTAssertFalse(store.access.permits(generation: generation))
        // Neither a queued duplicate nor a later duplicate can replay that reconciled proof.
        await client.send(.verified(proof))
        try await until { await client.finished.count == 2 }
        XCTAssertFalse(store.hasAccess)
    }

    func testStaleSameIDRevocationCannotReconcileAwayANewerRefundReversal() async throws {
        let client = PurchaseFakeClient(read: [record(revoked: date, signedOffset: 10)])
        let date = self.date
        let store = PurchaseStore(client: client, now: { date })
        defer { store.stop() }
        await store.start()
        XCTAssertFalse(store.hasAccess)
        await client.setRead([]) // History has not caught up with the verified reversal.
        await client.send(.verified(record(signedOffset: 20)))
        try await until { store.hasAccess }
        try await until { await client.finished.count == 1 }
        let generation = store.access.snapshot.generation
        let reads = await client.readCount
        await client.send(.verified(record(revoked: date, signedOffset: 10)))
        try await until { await client.finished.count == 2 }
        let laterReads = await client.readCount
        XCTAssertEqual(laterReads, reads, "An ignored stale revocation must not trigger an empty-history reconciliation.")
        XCTAssertTrue(store.access.permits(generation: generation))
        if case .unlocked(let grant) = store.state { XCTAssertEqual(grant.transactionID, 1) }
        else { XCTFail("The newer verified refund reversal must remain active.") }
    }

    private func record(id: UInt64 = 1, lifetime: Bool = false, expiration: Date? = nil,
                        revoked: Date? = nil, upgraded: Bool = false, signedOffset: TimeInterval? = nil) -> PurchaseTransaction {
        PurchaseTransaction(productID: lifetime ? AccessProductID.lifetime.rawValue : AccessProductID.monthly.rawValue,
                            kind: lifetime ? .lifetime : .subscription, transactionID: id, originalTransactionID: 1,
                            purchaseDate: date, signedDate: date.addingTimeInterval(signedOffset ?? Double(id)),
                            expirationDate: lifetime ? nil : expiration ?? date.addingTimeInterval(500),
                            revocationDate: revoked, isUpgraded: upgraded)
    }

    private func until(_ predicate: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { XCTFail("Purchase event did not arrive."); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor PurchaseFakeClient: PurchaseClient {
    private var read: PurchaseEntitlementRead
    private var readsFail = false
    private var catalogFails = false
    private var syncFails = false
    private var purchaseResult: PurchaseClientResult = .cancelled
    private var continuation: AsyncStream<PurchaseUpdate>.Continuation?
    private var holdRead = false
    private var held: CheckedContinuation<PurchaseEntitlementRead, Never>?
    private var heldValue: PurchaseEntitlementRead?
    private var finishCallback: (@Sendable () -> Void)?
    private var holdFinish = false
    private var heldFinish: CheckedContinuation<Void, Never>?
    private(set) var syncCount = 0
    private(set) var finished: [UInt64] = []
    private(set) var readCount = 0

    init(read: [PurchaseTransaction]) { self.read = PurchaseEntitlementRead(transactions: read) }
    func products() async throws -> [Product] {
        if catalogFails { throw URLError(.notConnectedToInternet) }
        return []
    }
    func introductoryOfferEligible(_ products: [Product]) async -> Set<String> { [] }
    func entitlements() async throws -> PurchaseEntitlementRead {
        readCount += 1
        if readsFail { throw URLError(.notConnectedToInternet) }
        if holdRead {
            holdRead = false
            heldValue = read
            return await withCheckedContinuation { held = $0 }
        }
        return read
    }
    func purchase(productID: String) async throws -> PurchaseClientResult { purchaseResult }
    func sync() async throws {
        syncCount += 1
        if syncFails { throw URLError(.notConnectedToInternet) }
    }
    func updates() async -> AsyncStream<PurchaseUpdate> {
        let (stream, continuation) = AsyncStream<PurchaseUpdate>.makeStream()
        self.continuation = continuation
        return stream
    }
    func finish(transactionID: UInt64) async {
        finishCallback?()
        if holdFinish {
            holdFinish = false
            await withCheckedContinuation { heldFinish = $0 }
        }
        finished.append(transactionID)
    }
    func onFinish(_ callback: @escaping @Sendable () -> Void) { finishCallback = callback }
    func setPurchase(_ result: PurchaseClientResult) { purchaseResult = result }
    func setRead(_ transactions: [PurchaseTransaction]) { read = PurchaseEntitlementRead(transactions: transactions) }
    func failReads(_ fail: Bool) { readsFail = fail }
    func failCatalog(_ fail: Bool) { catalogFails = fail }
    func failSync(_ fail: Bool) { syncFails = fail }
    func holdNextFinish() { holdFinish = true }
    var isFinishHeld: Bool { heldFinish != nil }
    func releaseFinish() { heldFinish?.resume(); heldFinish = nil }
    func send(_ update: PurchaseUpdate) { continuation?.yield(update) }
    func holdNextRead() { holdRead = true }
    var isReadHeld: Bool { held != nil }
    func releaseRead() {
        if let heldValue { held?.resume(returning: heldValue) }
        held = nil; heldValue = nil
    }
}
