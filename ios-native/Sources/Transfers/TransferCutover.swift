import Foundation
import Synchronization

/// Which engine an account's backup can run on after its import (B9).
enum TransferCutover: Equatable, Sendable {
    /// The transfers database is the engine's.
    case engine
    /// Today's backup keeps running from state.json, for this reason, shown in Diagnostics.
    case legacy(String)
}

/// Which engine runs an account's backup, as TransferHost decided it, and where its receipts are.
enum CutoverChoice: Sendable {
    case engine(TransferReceiptSource)
    case legacy
    /// Neither: the account's runtime ended, or the other engine runs in this process.
    case unavailable
}

/// The account's choice, once made. Readers that come first wait for it, up to a limit.
final class TransferCutoverState: Sendable {
    private struct State {
        var choice: CutoverChoice?
        var waiters: [UUID: CheckedContinuation<CutoverChoice?, Never>] = [:]
    }
    private let state = Mutex(State())

    /// Records the choice, once; a later one is ignored.
    func decide(_ choice: CutoverChoice) {
        let waiters = state.withLock { state -> [CheckedContinuation<CutoverChoice?, Never>] in
            guard state.choice == nil else { return [] }
            state.choice = choice
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.resume(returning: choice) }
    }

    /// The choice, waiting for it up to `limit`; nil if none came by then or the wait was cancelled.
    func choice(waitingAtMost limit: Duration = .seconds(60)) async -> CutoverChoice? {
        if let choice = state.withLock({ $0.choice }) { return choice }
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: limit)
            self?.give(up: id)
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let ready = state.withLock { state -> CutoverChoice?? in
                    if let choice = state.choice { return .some(choice) }
                    if Task.isCancelled { return .some(nil) }
                    state.waiters[id] = continuation
                    return .none
                }
                if let ready { continuation.resume(returning: ready) }
            }
        } onCancel: {
            self.give(up: id)
        }
    }

    private func give(up id: UUID) {
        state.withLock { $0.waiters.removeValue(forKey: id) }?.resume(returning: nil)
    }
}

/// The receipts cleanup and the device index read for an account (DS12): the transfers
/// database's once the engine runs its backup, else today's backup state, until B10 retires it.
struct CutoverReceipts: ReceiptRepository, DeviceIndexBackupSource {
    let cutover: TransferCutoverState
    var legacyReceipts = LegacyStateReceipts()
    var legacyInputs = LegacyBackupIndexInputs()

    func receipts(account: String) async -> [String: CleanupReceipt]? {
        switch await cutover.choice() {
        case .engine(let source): await source.receipts(account: account)
        case .legacy: await legacyReceipts.receipts(account: account)
        case .unavailable, nil: nil
        }
    }

    func recordSizes(_ sizes: [String: VerifiedSize], account: String) async {
        switch await cutover.choice() {
        case .engine(let source): await source.recordSizes(sizes, account: account)
        case .legacy: await legacyReceipts.recordSizes(sizes, account: account)
        case .unavailable, nil: break
        }
    }

    func markLocallyDeleted(_ localIDs: [String], account: String) async {
        if case .engine(let source) = await cutover.choice() { await source.markLocallyDeleted(localIDs, account: account) }
    }

    func inputs(account: String) async -> DeviceIndexBackupInputs? {
        switch await cutover.choice() {
        case .engine(let source): await source.inputs(account: account)
        case .legacy: await legacyInputs.inputs(account: account)
        case .unavailable, nil: nil
        }
    }

    /// Cleanup's and the device index's subscriptions come early; each waits for the choice.
    func changes() async -> AsyncStream<Void> {
        switch await cutover.choice(waitingAtMost: .seconds(3_600)) {
        case .engine(let source): await source.changes()
        case .legacy, .unavailable, nil: await legacyInputs.changes()
        }
    }
}
