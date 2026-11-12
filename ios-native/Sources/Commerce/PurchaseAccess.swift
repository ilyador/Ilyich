import Foundation
import Synchronization

enum AccessProductID: String, CaseIterable, Sendable {
    case monthly = "io.ilyador.ilyich.access.monthly"
    case yearly = "io.ilyador.ilyich.access.yearly"
    case lifetime = "io.ilyador.ilyich.access.lifetime"
}

struct PurchaseEntitlement: Equatable, Sendable {
    let productID: String
    let transactionID: UInt64
    let originalTransactionID: UInt64
    let purchaseDate: Date
    /// Apple's signed subscription or billing-grace deadline. Only lifetime has no deadline.
    let expirationDate: Date?
    let isLifetime: Bool

    func isValid(at date: Date) -> Bool {
        if isLifetime { return productID == AccessProductID.lifetime.rawValue && expirationDate == nil }
        guard let product = AccessProductID(rawValue: productID), product != .lifetime,
              let expirationDate else { return false }
        return expirationDate > date
    }
}

enum PurchaseAccessState: Equatable, Sendable {
    case checking
    case unlocked(PurchaseEntitlement)
    case locked
    case unavailable(String)

    var hasAccess: Bool { if case .unlocked = self { return true }; return false }
}

struct PurchaseAccessSnapshot: Equatable, Sendable {
    let state: PurchaseAccessState
    let generation: UInt64
    var hasAccess: Bool { state.hasAccess }
}

/// A process-local fence, never a persisted purchase flag. Every work boundary reads a fresh
/// snapshot or checks its captured generation; a suspended app cannot miss a known expiry.
final class PurchaseAccess: Sendable {
    private struct Value {
        var state: PurchaseAccessState
        var generation: UInt64 = 0
        var listeners: [UUID: AsyncStream<PurchaseAccessSnapshot>.Continuation] = [:]
    }
    private let value: Mutex<Value>
    /// Orders deliveries without calling stream termination handlers while holding `value`.
    private let publication = Mutex(())
    private let now: @Sendable () -> Date

    init(state: PurchaseAccessState = .checking, now: @escaping @Sendable () -> Date = { Date() }) {
        value = Mutex(Value(state: state))
        self.now = now
    }

    var snapshot: PurchaseAccessSnapshot {
        let date = now()
        return publication.withLock { _ in
            let (snapshot, listeners) = value.withLock { value in
                let changed = Self.normalize(&value, at: date)
                return (PurchaseAccessSnapshot(state: value.state, generation: value.generation),
                        changed ? Array(value.listeners.values) : [])
            }
            for listener in listeners { listener.yield(snapshot) }
            return snapshot
        }
    }

    var hasAccess: Bool { snapshot.hasAccess }

    func permits(generation: UInt64) -> Bool {
        let current = snapshot
        return current.hasAccess && current.generation == generation
    }

    func changes() -> AsyncStream<PurchaseAccessSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<PurchaseAccessSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in
            self?.value.withLock { _ = $0.listeners.removeValue(forKey: id) }
        }
        let date = now()
        publication.withLock { _ in
            let (snapshot, listeners) = value.withLock { value in
                let changed = Self.normalize(&value, at: date)
                value.listeners[id] = continuation
                return (PurchaseAccessSnapshot(state: value.state, generation: value.generation),
                        changed ? Array(value.listeners.values) : [continuation])
            }
            for listener in listeners { listener.yield(snapshot) }
        }
        return stream
    }

    /// Called only by the verified-transaction domain (or an injected test fixture).
    func update(_ state: PurchaseAccessState) {
        let date = now()
        publication.withLock { _ in
            let (snapshot, listeners) = value.withLock { value in
                var changed = Self.normalize(&value, at: date)
                let state = Self.normalized(state, at: date)
                if value.state != state {
                    let continuousAccess = value.state.hasAccess && state.hasAccess
                    value.state = state
                    if !continuousAccess { value.generation &+= 1 }
                    changed = true
                }
                return (PurchaseAccessSnapshot(state: value.state, generation: value.generation),
                        changed ? Array(value.listeners.values) : [])
            }
            for listener in listeners { listener.yield(snapshot) }
        }
    }

    private static func normalized(_ state: PurchaseAccessState, at date: Date) -> PurchaseAccessState {
        if case .unlocked(let entitlement) = state, !entitlement.isValid(at: date) { return .locked }
        return state
    }

    private static func normalize(_ value: inout Value, at date: Date) -> Bool {
        let next = normalized(value.state, at: date)
        guard next != value.state else { return false }
        value.state = next
        value.generation &+= 1
        return true
    }
}

/// This record is made only after StoreKit verifies the transaction. It is never decoded from
/// preferences or accepted from the photo server. Tests inject records through PurchaseClient.
struct PurchaseTransaction: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case subscription, lifetime, unsupported }
    let productID: String
    let kind: Kind
    let transactionID: UInt64
    let originalTransactionID: UInt64
    let purchaseDate: Date
    let signedDate: Date
    var expirationDate: Date?
    var gracePeriodExpirationDate: Date? = nil
    let revocationDate: Date?
    let isUpgraded: Bool
    var subscriptionGroupID: String? = nil

    var isRevoked: Bool { revocationDate != nil || isUpgraded }

    static func newest(_ lhs: PurchaseTransaction, _ rhs: PurchaseTransaction) -> PurchaseTransaction {
        if lhs.signedDate != rhs.signedDate { return lhs.signedDate > rhs.signedDate ? lhs : rhs }
        // Equal timestamp conflicts fail closed. A refund reversal must carry newer signed proof.
        if lhs.isRevoked != rhs.isRevoked { return lhs.isRevoked ? lhs : rhs }
        var result = rhs
        if !result.isRevoked, lhs.expirationDate == rhs.expirationDate,
           let grace = lhs.gracePeriodExpirationDate, grace > (rhs.gracePeriodExpirationDate ?? .distantPast) {
            // A raw transaction update has no renewal info; it must not erase previously verified
            // grace metadata for the identical signed transaction.
            result.gracePeriodExpirationDate = grace
        }
        return result
    }

    func entitlement(at date: Date) -> PurchaseEntitlement? {
        guard !isRevoked, let id = AccessProductID(rawValue: productID) else { return nil }
        let deadline: Date?
        switch (id, kind) {
        case (.lifetime, .lifetime): deadline = nil
        case (.monthly, .subscription), (.yearly, .subscription):
            guard let expirationDate else { return nil }
            deadline = max(expirationDate, gracePeriodExpirationDate ?? expirationDate)
        default: return nil
        }
        let result = PurchaseEntitlement(productID: productID, transactionID: transactionID,
                                         originalTransactionID: originalTransactionID, purchaseDate: purchaseDate,
                                         expirationDate: deadline, isLifetime: id == .lifetime)
        return result.isValid(at: date) ? result : nil
    }

    static func best(in records: [PurchaseTransaction], at date: Date) -> PurchaseEntitlement? {
        records.compactMap { $0.entitlement(at: date) }.max { lhs, rhs in
            if lhs.isLifetime != rhs.isLifetime { return !lhs.isLifetime }
            if lhs.expirationDate != rhs.expirationDate {
                return (lhs.expirationDate ?? .distantFuture) < (rhs.expirationDate ?? .distantFuture)
            }
            return lhs.transactionID < rhs.transactionID
        }
    }
}
