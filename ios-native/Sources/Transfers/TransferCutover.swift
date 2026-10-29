import Foundation
import Synchronization

/// Whether an account's backup can run on the transfer engine, once its transfers database is
/// readied (AccountRuntime.prepareTransfers).
enum TransferCutover: Equatable, Sendable {
    /// The transfers database is the engine's.
    case engine
    /// The account's backup can't start, for this reason, shown in Diagnostics.
    case unavailable(String)
}

/// Whether the account's backup runs on the transfer engine, as TransferHost decided it, and where
/// its receipts are.
enum CutoverChoice: Sendable {
    case engine(TransferReceiptSource)
    /// The account's backup doesn't run: its runtime ended, or the engine couldn't start for it.
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
/// database's, once the engine runs the account's backup. Readers that come first wait for it.
struct CutoverReceipts: ReceiptRepository, DeviceIndexBackupSource {
    let cutover: TransferCutoverState

    func receipts(account: String) async -> [String: CleanupReceipt]? {
        guard case .engine(let source) = await cutover.choice() else { return nil }
        return await source.receipts(account: account)
    }

    func recordSizes(_ sizes: [String: VerifiedSize], account: String) async {
        if case .engine(let source) = await cutover.choice() { await source.recordSizes(sizes, account: account) }
    }

    func markLocallyDeleted(_ localIDs: [String], account: String) async {
        if case .engine(let source) = await cutover.choice() { await source.markLocallyDeleted(localIDs, account: account) }
    }

    func inputs(account: String) async -> DeviceIndexBackupInputs? {
        guard case .engine(let source) = await cutover.choice() else { return nil }
        return await source.inputs(account: account)
    }

    /// Cleanup's and the device index's subscriptions come early; each waits for the choice. An
    /// account whose backup doesn't run has no changes to tell of.
    func changes() async -> AsyncStream<Void> {
        guard case .engine(let source) = await cutover.choice(waitingAtMost: .seconds(3_600)) else {
            return AsyncStream { $0.finish() }
        }
        return await source.changes()
    }
}
