import Foundation
import Synchronization

/// How far library jobs run ahead of each other (B3): at most two staged and not yet handed to
/// the transport, within a byte budget, and at most three parts with the transport awaiting their
/// answer. The engine runs up to `Limits.jobs` jobs at once; each waits here for its turn.
///
/// A staging permit is taken before a job stages or resumes its stage and held until its last part
/// is handed to the transport. A new stage starts only once every other stage's size is known and
/// they add up to less than the budget, so the files waiting on disk pass it by one stage at most;
/// a video larger than the budget still goes, once nothing else is staged. A submission permit is
/// held from a part's submission until its answer.
///
/// Waits end with CancellationError when their task is cancelled, as a released lease does.
final class TransferPipeline: Sendable {
    struct Limits: Hashable, Sendable {
        var staged = 2
        var submitted = 3
        /// Bytes of staged files not yet with the transport.
        var stagingBytes: Int64 = 1 << 30

        /// Jobs the engine runs at once: every staged and every submitted one.
        var jobs: Int { staged + submitted }
    }

    /// A turn taken. Release it once; a second release does nothing.
    struct Permit: Hashable, Sendable {
        fileprivate let id: UUID
        fileprivate let kind: Kind
    }

    fileprivate enum Kind: Hashable, Sendable { case staging, submission }

    /// The most ever held at once, for tests.
    struct Peaks: Hashable, Sendable {
        var staged = 0
        var submitted = 0
        var stagedBytes: Int64 = 0
    }

    private struct State {
        /// Each staged job's bytes, nil while it stages.
        var staged: [UUID: Int64?] = [:]
        var submitted: Set<UUID> = []
        var stagingWaiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []
        var submissionWaiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []
        var peaks = Peaks()

        var stagedBytes: Int64 { staged.values.reduce(0) { $0 + ($1 ?? 0) } }
        var sizesKnown: Bool { staged.values.allSatisfy { $0 != nil } }
    }

    let limits: Limits
    private let state = Mutex(State())

    init(limits: Limits = Limits()) { self.limits = limits }

    var peaks: Peaks { state.withLock { $0.peaks } }
    var stagedCount: Int { state.withLock { $0.staged.count } }
    var submittedCount: Int { state.withLock { $0.submitted.count } }

    /// Waits for a turn to stage: fewer than `staged` jobs staged, none still staging, and their
    /// files under the budget.
    func acquireStaging() async throws -> Permit {
        try await acquire(.staging)
    }

    /// The staged files' size, once known.
    func record(bytes: Int64, for permit: Permit) {
        let woken = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            guard permit.kind == .staging, state.staged.keys.contains(permit.id) else { return [] }
            state.staged.updateValue(max(bytes, 0), forKey: permit.id)
            state.peaks.stagedBytes = max(state.peaks.stagedBytes, state.stagedBytes)
            return Self.admit(&state, limits: limits)
        }
        for continuation in woken { continuation.resume() }
    }

    /// Waits for a turn to hand a part to the transport.
    func acquireSubmission() async throws -> Permit {
        try await acquire(.submission)
    }

    func release(_ permit: Permit) {
        let woken = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            switch permit.kind {
            case .staging: guard state.staged.removeValue(forKey: permit.id) != nil else { return [] }
            case .submission: guard state.submitted.remove(permit.id) != nil else { return [] }
            }
            return Self.admit(&state, limits: limits)
        }
        for continuation in woken { continuation.resume() }
    }

    // MARK: -

    private func acquire(_ kind: Kind) async throws -> Permit {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let admitted = state.withLock { state -> Bool in
                    if Task.isCancelled { return false }
                    switch kind {
                    case .staging: state.stagingWaiters.append((id, continuation))
                    case .submission: state.submissionWaiters.append((id, continuation))
                    }
                    return true
                }
                guard admitted else { return continuation.resume(throwing: CancellationError()) }
                let woken = state.withLock { Self.admit(&$0, limits: limits) }
                for continuation in woken { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                if let index = state.stagingWaiters.firstIndex(where: { $0.id == id }) { return state.stagingWaiters.remove(at: index).continuation }
                if let index = state.submissionWaiters.firstIndex(where: { $0.id == id }) { return state.submissionWaiters.remove(at: index).continuation }
                return nil
            }
            waiter?.resume(throwing: CancellationError())
        }
        // A cancellation that lands after admission gives the turn back.
        if Task.isCancelled {
            release(Permit(id: id, kind: kind))
            throw CancellationError()
        }
        return Permit(id: id, kind: kind)
    }

    /// Admits waiters, in order, while their limits allow, and returns those to resume.
    private static func admit(_ state: inout State, limits: Limits) -> [CheckedContinuation<Void, any Error>] {
        var woken: [CheckedContinuation<Void, any Error>] = []
        while let first = state.stagingWaiters.first, state.staged.count < limits.staged,
              state.staged.isEmpty || (state.sizesKnown && state.stagedBytes < limits.stagingBytes) {
            state.stagingWaiters.removeFirst()
            state.staged.updateValue(nil, forKey: first.id)
            state.peaks.staged = max(state.peaks.staged, state.staged.count)
            woken.append(first.continuation)
        }
        while let first = state.submissionWaiters.first, state.submitted.count < limits.submitted {
            state.submissionWaiters.removeFirst()
            state.submitted.insert(first.id)
            state.peaks.submitted = max(state.peaks.submitted, state.submitted.count)
            woken.append(first.continuation)
        }
        return woken
    }
}
