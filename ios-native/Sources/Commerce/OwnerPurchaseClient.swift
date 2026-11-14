#if ILYICH_OWNER_BUILD
import Foundation
import StoreKit

/// The owner's own builds, installed from the Mac, open without a purchase: this client reports one
/// lifetime record through the same transaction boundary as StoreKit. It is compiled only when a
/// build sets ILYICH_OWNER_BUILD, which an App Store archive never does (scripts/app-store.sh
/// refuses an archive that contains it).
struct OwnerPurchaseClient: PurchaseClient {
    func products() async throws -> [Product] { [] }
    func introductoryOfferEligible(_ products: [Product]) async -> Set<String> { [] }

    func entitlements() async throws -> PurchaseEntitlementRead {
        let date = Date(timeIntervalSince1970: 0)
        return PurchaseEntitlementRead(transactions: [
            PurchaseTransaction(productID: AccessProductID.lifetime.rawValue, kind: .lifetime, transactionID: 1,
                                originalTransactionID: 1, purchaseDate: date, signedDate: date,
                                expirationDate: nil, revocationDate: nil, isUpgraded: false),
        ])
    }

    func purchase(productID: String) async throws -> PurchaseClientResult { .cancelled }
    func sync() async throws {}
    func updates() async -> AsyncStream<PurchaseUpdate> { AsyncStream { _ in } }
    func finish(transactionID: UInt64) async {}
}
#endif
