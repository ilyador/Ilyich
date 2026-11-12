import Foundation
import StoreKit

enum PurchaseClientResult: Sendable {
    case verified(PurchaseTransaction)
    case unverified
    case cancelled
    case pending
}

enum PurchaseUpdate: Sendable {
    case verified(PurchaseTransaction)
    case unverified
}

struct PurchaseEntitlementRead: Sendable {
    var transactions: [PurchaseTransaction]
    var hasUnverifiedPurchase = false
}

/// Dependency injection belongs at the transaction boundary, so tests never need a paid-state
/// launch argument and production always uses Apple's signed on-device StoreKit history.
protocol PurchaseClient: Sendable {
    func products() async throws -> [Product]
    func introductoryOfferEligible(_ products: [Product]) async -> Set<String>
    func entitlements() async throws -> PurchaseEntitlementRead
    func purchase(productID: String) async throws -> PurchaseClientResult
    func sync() async throws
    func updates() async -> AsyncStream<PurchaseUpdate>
    func finish(transactionID: UInt64) async
}

actor StoreKitPurchaseClient: PurchaseClient {
    private var catalog: [String: Product] = [:]
    private var unfinished: [UInt64: StoreKit.Transaction] = [:]

    func products() async throws -> [Product] {
        let products = try await Product.products(for: AccessProductID.allCases.map(\.rawValue))
        catalog = Dictionary(uniqueKeysWithValues: products.filter(Self.isSupported).map { ($0.id, $0) })
        return AccessProductID.allCases.compactMap { catalog[$0.rawValue] }
    }

    func introductoryOfferEligible(_ products: [Product]) async -> Set<String> {
        var eligible = Set<String>()
        for product in products {
            if let subscription = product.subscription,
               subscription.introductoryOffer != nil,
               await subscription.isEligibleForIntroOffer {
                eligible.insert(product.id)
            }
        }
        return eligible
    }

    func entitlements() async throws -> PurchaseEntitlementRead {
        var read = PurchaseEntitlementRead(transactions: [])
        for await result in StoreKit.Transaction.currentEntitlements {
            switch result {
            case .verified(let transaction):
                guard AccessProductID(rawValue: transaction.productID) != nil else { continue }
                read.transactions.append(Self.record(transaction))
            case .unverified(let transaction, _):
                if AccessProductID(rawValue: transaction.productID) != nil { read.hasUnverifiedPurchase = true }
            }
        }
        // currentEntitlements works from Apple's signed local history while offline. A grace
        // period additionally needs verified renewal information; never invent a local extension.
        let date = Date()
        let groups = Set(read.transactions.filter {
            $0.kind == .subscription && !$0.isRevoked && ($0.expirationDate ?? .distantPast) <= date
        }.compactMap(\.subscriptionGroupID))
        for group in groups {
            let statuses: [Product.SubscriptionInfo.Status]
            do { statuses = try await Product.SubscriptionInfo.status(for: group) }
            catch {
                // An unrelated status outage cannot hide a valid signed lifetime/other grant.
                if PurchaseTransaction.best(in: read.transactions, at: date) != nil { continue }
                throw error
            }
            for status in statuses where status.state == .inGracePeriod {
                guard case .verified(let transaction) = status.transaction,
                      case .verified(let renewal) = status.renewalInfo,
                      let deadline = renewal.gracePeriodExpirationDate,
                      let index = read.transactions.firstIndex(where: { $0.transactionID == transaction.id }) else { continue }
                read.transactions[index].gracePeriodExpirationDate = deadline
            }
        }
        return read
    }

    func purchase(productID: String) async throws -> PurchaseClientResult {
        guard AccessProductID(rawValue: productID) != nil else { throw PurchaseClientError.unsupportedProduct }
        if catalog[productID] == nil { _ = try await products() }
        guard let product = catalog[productID], Self.isSupported(product) else { throw PurchaseClientError.unsupportedProduct }
        switch try await product.purchase() {
        case .success(let verification): return receive(verification)
        case .userCancelled: return .cancelled
        case .pending: return .pending
        @unknown default: throw PurchaseClientError.unknownResult
        }
    }

    func sync() async throws { try await AppStore.sync() }

    func updates() async -> AsyncStream<PurchaseUpdate> {
        let (stream, continuation) = AsyncStream<PurchaseUpdate>.makeStream(bufferingPolicy: .unbounded)
        let listener = Task { [weak self] in
            for await verification in StoreKit.Transaction.updates {
                guard !Task.isCancelled, let self else { break }
                switch await self.receive(verification) {
                case .verified(let record): continuation.yield(.verified(record))
                case .unverified: continuation.yield(.unverified)
                case .cancelled, .pending: break
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in listener.cancel() }
        return stream
    }

    func finish(transactionID: UInt64) async {
        guard let transaction = unfinished.removeValue(forKey: transactionID) else { return }
        await transaction.finish()
    }

    private func receive(_ result: VerificationResult<StoreKit.Transaction>) -> PurchaseClientResult {
        switch result {
        case .verified(let transaction):
            if AccessProductID(rawValue: transaction.productID) != nil { unfinished[transaction.id] = transaction }
            return .verified(Self.record(transaction))
        case .unverified: return .unverified
        }
    }

    private static func isSupported(_ product: Product) -> Bool {
        switch AccessProductID(rawValue: product.id) {
        case .monthly, .yearly: product.type == .autoRenewable
        case .lifetime: product.type == .nonConsumable
        case nil: false
        }
    }

    private static func record(_ transaction: StoreKit.Transaction) -> PurchaseTransaction {
        PurchaseTransaction(productID: transaction.productID,
                            kind: transaction.productType == .autoRenewable ? .subscription :
                                transaction.productType == .nonConsumable ? .lifetime : .unsupported,
                            transactionID: transaction.id, originalTransactionID: transaction.originalID,
                            purchaseDate: transaction.purchaseDate, signedDate: transaction.signedDate,
                            expirationDate: transaction.expirationDate, revocationDate: transaction.revocationDate,
                            isUpgraded: transaction.isUpgraded, subscriptionGroupID: transaction.subscriptionGroupID)
    }
}

private enum PurchaseClientError: LocalizedError {
    case unsupportedProduct, unknownResult
    var errorDescription: String? {
        switch self {
        case .unsupportedProduct: "This access plan is unavailable in the App Store. Reload prices and try again."
        case .unknownResult: "The App Store returned an unknown purchase result. Check access before trying again."
        }
    }
}
