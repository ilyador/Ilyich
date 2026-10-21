import Foundation

/// What recovery reads and writes (B6, dormant). Recovery works on jobs no lease holds: each write
/// checks that in the same transaction, so a job the engine leased meanwhile is left to the engine.
extension TransferStore {
    /// Library jobs with something to recover: a stage, an attempt, or a state that says the
    /// transport has their upload. A job queued and never staged has nothing.
    func recoveryJobs() throws -> [RecoveryJob] {
        let db = try database()
        var found: [(StoredJob, Bool)] = []
        try db.run("""
            SELECT \(Self.jobColumns),lease_token IS NOT NULL FROM jobs j WHERE lane='library' AND \
            (state IN ('submitting','submitted','finalizing') OR EXISTS(SELECT 1 FROM stages s WHERE s.job_id=j.id) \
            OR EXISTS(SELECT 1 FROM attempts a WHERE a.job_id=j.id)) ORDER BY seq,id
            """) { row in
            if let job = Self.storedJob(row) { found.append((job, row.integer(13) == 1)) }
        }
        return try found.map { job, leased in
            RecoveryJob(job: job, leased: leased, stage: try libraryStage(job: job.id), attempts: try libraryAttempts(job: job.id))
        }
    }

    /// What staging must keep for every job, leased or not: each stage's folder, and each
    /// unanswered attempt with the folder of its body.
    func stagingReferences() throws -> StagingReferences {
        let db = try database()
        var references = StagingReferences()
        try db.run("SELECT DISTINCT folder FROM stages") { row in
            if let folder = row.text(0) { references.folders.insert(folder) }
        }
        try db.run("SELECT id,body_path FROM attempts WHERE state IN ('created','bodyWritten','submitted','interrupted')") { row in
            if let id = row.text(0) { references.attempts.insert(id) }
            if let body = row.text(1), let slash = body.lastIndex(of: "/") { references.folders.insert(String(body[..<slash])) }
        }
        return references
    }

    /// Records what recovery found for a job no lease holds: an attempt's row as it now stands,
    /// with the failure it ended in, a Live Photo video's server ID, and the job's new state, in
    /// one transaction. Returns false, changing nothing, when a lease holds the job or it is gone.
    func recover(job: Int64, attempt: LibraryAttempt?, failure: OutcomeRecord? = nil, motion: (stage: String, remoteID: String)? = nil,
                 change: RecoveredJobChange, at date: Date) throws -> Bool {
        let db = try database()
        return try db.transaction {
            var found = false
            try db.run("SELECT 1 FROM jobs WHERE id=? AND lane='library' AND lease_token IS NULL", [.integer(job)]) { _ in found = true }
            guard found else { return false }
            if let attempt { try Self.writeAttempt(db, attempt, failure: failure, job: job) }
            if let motion {
                try db.run("UPDATE stages SET motion_remote_id=? WHERE stage_id=? AND job_id=?", [.text(motion.remoteID), .text(motion.stage), .integer(job)])
            }
            switch change {
            case .keep:
                break
            case .state(let state, let phase):
                try db.run("UPDATE jobs SET state=?,phase=coalesce(?,phase) WHERE id=?", [.text(state.rawValue), .optionalText(phase), .integer(job)])
            case .retry(let notBefore, let message):
                try db.run("""
                    UPDATE jobs SET state='retryScheduled',not_before=?,retry_count=retry_count+1,error_class='transient',error_message=?,error_at=? \
                    WHERE id=?
                    """, [.date(notBefore), .text(message), .date(date), .integer(job)])
            case .waiting(let reason):
                try db.run("UPDATE jobs SET state='waiting',error_class='waiting',error_message=?,error_at=? WHERE id=?",
                           [.text(reason.storedValue), .date(date), .integer(job)])
            case .failed(let message):
                try db.run("UPDATE jobs SET state='failed',error_class='item',error_message=?,error_at=?,not_before=NULL WHERE id=?",
                           [.text(message), .date(date), .integer(job)])
            case .pending:
                try Self.dropStages(db, ofJobsIn: "SELECT ?", [.integer(job)])
                try db.run("UPDATE jobs SET state='queued',phase=NULL,not_before=NULL WHERE id=?", [.integer(job)])
            }
            return true
        }
    }
}

/// A library job as recovery finds it.
struct RecoveryJob: Hashable, Sendable {
    let job: StoredJob
    /// A lease holds it: the engine is running it, and recovery leaves it alone.
    let leased: Bool
    let stage: LibraryStage?
    /// In the order they were made.
    let attempts: [LibraryAttempt]
}

/// What recovery does to a job.
enum RecoveredJobChange: Hashable, Sendable {
    case keep
    /// A new state; nil keeps the phase.
    case state(JobState, phase: String?)
    /// A transient failure: it runs again from `notBefore`.
    case retry(notBefore: Date, message: String)
    /// Only this job waits for the condition.
    case waiting(WaitReason)
    /// An item failure, which only the user retries.
    case failed(String)
    /// Staged again from the start: its stage goes and its unanswered attempts are abandoned.
    case pending
}
