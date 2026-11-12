import Foundation
import Synchronization
import XCTest
@testable import Ilyich

@MainActor final class PurchaseAccessTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    func testOnlyExpectedVerifiedProductTypesAndSignedDeadlinesGrant() {
        let subscription = record(expiration: date.addingTimeInterval(10))
        XCTAssertNotNil(subscription.entitlement(at: date))
        XCTAssertNil(record(expiration: date).entitlement(at: date), "Expiry is exclusive, including a trial's signed expiry.")
        XCTAssertNil(record(expiration: nil).entitlement(at: date), "A subscription without a deadline is not lifetime.")
        XCTAssertNil(record(id: "another.product", expiration: .distantFuture).entitlement(at: date))
        XCTAssertNil(record(kind: .lifetime, expiration: .distantFuture).entitlement(at: date))
        XCTAssertNil(record(expiration: .distantFuture, revoked: date).entitlement(at: date))
        XCTAssertNil(record(expiration: .distantFuture, upgraded: true).entitlement(at: date))
    }

    func testGraceRequiresItsSignedDeadlineAndLifetimeWins() throws {
        var grace = record(expiration: date.addingTimeInterval(-1))
        XCTAssertNil(grace.entitlement(at: date))
        grace.gracePeriodExpirationDate = date.addingTimeInterval(20)
        XCTAssertEqual(grace.entitlement(at: date)?.expirationDate, grace.gracePeriodExpirationDate)
        XCTAssertNil(grace.entitlement(at: date.addingTimeInterval(20)))
        let lifetime = record(id: AccessProductID.lifetime.rawValue, kind: .lifetime, expiration: nil)
        XCTAssertTrue(try XCTUnwrap(PurchaseTransaction.best(in: [grace, lifetime], at: date)).isLifetime)
    }

    func testFreshFenceExpiresWithoutTimerAndOldWorkCannotRevive() throws {
        let clock = PurchaseTestClock(date)
        let grant = try XCTUnwrap(record(expiration: date.addingTimeInterval(10)).entitlement(at: date))
        let access = PurchaseAccess(state: .unlocked(grant), now: { clock.now })
        let generation = access.snapshot.generation
        XCTAssertTrue(access.permits(generation: generation))
        clock.advance(10)
        XCTAssertFalse(access.permits(generation: generation), "A suspended app's next work boundary must see expiry.")
        XCTAssertEqual(access.snapshot.state, .locked)
        access.update(.unlocked(try XCTUnwrap(record(expiration: date.addingTimeInterval(100)).entitlement(at: clock.now))))
        XCTAssertTrue(access.hasAccess)
        XCTAssertFalse(access.permits(generation: generation), "Reacquiring access cannot revive an old task.")
    }

    func testContinuousRenewalKeepsGenerationButPublishesNewDeadline() async throws {
        let date = self.date
        let access = PurchaseAccess(now: { date })
        let grant = try XCTUnwrap(record(expiration: date.addingTimeInterval(10)).entitlement(at: date))
        access.update(.unlocked(grant))
        let generation = access.snapshot.generation
        var iterator = access.changes().makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial?.state, .unlocked(grant))
        let renewal = try XCTUnwrap(record(expiration: date.addingTimeInterval(100)).entitlement(at: date))
        access.update(.unlocked(renewal))
        let change = await iterator.next()
        XCTAssertEqual(change?.state, .unlocked(renewal))
        XCTAssertEqual(change?.generation, generation, "Renewal must not restart account work.")
        access.update(.locked)
        access.update(.unlocked(renewal))
        XCTAssertFalse(access.permits(generation: generation))
    }

    private func record(id: String = AccessProductID.monthly.rawValue, kind: PurchaseTransaction.Kind = .subscription,
                        expiration: Date?, revoked: Date? = nil, upgraded: Bool = false) -> PurchaseTransaction {
        PurchaseTransaction(productID: id, kind: kind, transactionID: 1, originalTransactionID: 1,
                            purchaseDate: date, signedDate: date, expirationDate: expiration,
                            revocationDate: revoked, isUpgraded: upgraded)
    }
}

final class PurchaseTestClock: Sendable {
    private let value: Mutex<Date>
    init(_ date: Date) { value = Mutex(date) }
    var now: Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
}
