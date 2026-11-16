import Foundation

struct NewPhotosBackupError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
    static let missingBaseline = Self(message: "New-photos backup needs its saved Photos baseline. Pause backup and set it up again.")
    static let changingPolicy = Self(message: "Backup settings are being updated. Try again when setup finishes.")
}

extension TransferStore {
    func newPhotosBaselineStartedAt() throws -> Date? {
        var result: Date?
        try database().run("SELECT started_at FROM new_photos_baseline_state WHERE id=1") { result = $0.date(0) }
        return result
    }

    func newPhotosBaselineIDs() throws -> Set<String>? {
        guard try newPhotosBaselineStartedAt() != nil else { return nil }
        var result = Set<String>()
        try database().run("SELECT local_id FROM new_photos_baseline") { if let id = $0.text(0) { result.insert(id) } }
        return result
    }

    func beginNewPhotosPolicyChange(_ token: UUID, permits: @Sendable () -> Bool) throws {
        guard permits() else { throw CancellationError() }
        try database().run("INSERT OR REPLACE INTO new_photos_activation(id,token) VALUES(1,?)", [.text(token.uuidString)])
    }

    func endNewPhotosPolicyChange(_ token: UUID) throws {
        try database().run("DELETE FROM new_photos_activation WHERE id=1 AND token=?", [.text(token.uuidString)])
    }

    func newPhotosPolicyChanging() throws -> Bool {
        var pending = false
        try database().run("SELECT 1 FROM new_photos_activation WHERE id=1") { _ in pending = true }
        return pending
    }

    func pastBackupVerificationAllowed() throws -> Bool {
        try newPhotosPolicyChanging() == false && preferences()?.newPhotosOnly != true
    }

    /// All automatic readers fail closed while the baseline is absent or being captured.
    func automaticFollowUpLocalIDs(_ localIDs: [String]) throws -> Set<String> {
        if try newPhotosPolicyChanging() { return [] }
        guard try preferences()?.newPhotosOnly == true else { return Set(localIDs) }
        guard try newPhotosBaselineStartedAt() != nil else { throw NewPhotosBackupError.missingBaseline }
        var result = Set<String>()
        try database().run("""
            SELECT value FROM json_each(?) WHERE value NOT IN (SELECT local_id FROM new_photos_baseline)
            """, [.text(TransferJSON.encode(localIDs))]) { if let id = $0.text(0) { result.insert(id) } }
        return result
    }

    /// SQL fragments use only internal column names, never external input.
    func automaticFollowUpSQL(_ column: String = "local_id") throws -> String {
        if try newPhotosPolicyChanging() { return "0" }
        guard try preferences()?.newPhotosOnly == true else { return "1" }
        guard try newPhotosBaselineStartedAt() != nil else { throw NewPhotosBackupError.missingBaseline }
        return "\(column) NOT IN (SELECT local_id FROM new_photos_baseline)"
    }

    func isExcludedFromNewPhotosBackup(_ localID: String) throws -> Bool {
        try !automaticFollowUpLocalIDs([localID]).contains(localID)
    }

    func filterNewPhotosCandidates(_ candidates: [DeviceCandidate]) throws -> [DeviceCandidate] {
        let allowed = try automaticFollowUpLocalIDs(candidates.map(\.id))
        return candidates.filter { allowed.contains($0.id) }
    }

    /// Every existing library job for the captured IDs is cancelled, including older manual
    /// and failed jobs. Explicit user commands issued after activation may upload those IDs.
    func newPhotosCutoverJobs(_ localIDs: Set<String>?) throws -> (sources: [TransferSource], attempts: [AttemptID]) {
        let db = try database()
        let keys: [TransferSQLite.Value] = [.integer(localIDs == nil ? 1 : 0), .text(TransferJSON.encode(localIDs?.sorted() ?? []))]
        var sources: [TransferSource] = []
        var attempts: [AttemptID] = []
        try db.run("SELECT source_key FROM jobs WHERE lane='library' AND (?=1 OR source_key IN (SELECT value FROM json_each(?)))", keys) {
            if let id = $0.text(0) { sources.append(.photo(.init(rawValue: id))) }
        }
        try db.run("""
            SELECT a.id FROM attempts a JOIN jobs j ON j.id=a.job_id WHERE j.lane='library' \
            AND (?=1 OR j.source_key IN (SELECT value FROM json_each(?)))
            """, keys) { if let id = $0.text(0) { attempts.append(AttemptID(legacy: id)) } }
        return (sources, attempts)
    }

    /// Metadata-only cutover; neither confirmations nor receipts are changed. A ready baseline
    /// is immutable, so changing settings or re-enabling never turns existing future IDs old.
    func commitNewPhotosBackupBaseline(_ localIDs: Set<String>?, startedAt: Date, expectedPreferences: TransferPreferences,
                                      permits: @Sendable () -> Bool) throws -> TransferPreferences {
        let db = try database()
        return try db.transaction {
            try Task.checkCancellation()
            guard permits() else { throw CancellationError() }
            guard try (preferences() ?? TransferPreferences()) == expectedPreferences else { throw StalePreferencesEdit() }
            let started: Date
            if let saved = try newPhotosBaselineStartedAt() { started = saved }
            else {
                guard let localIDs else { throw NewPhotosBackupError.missingBaseline }
                try db.run("DELETE FROM new_photos_baseline")
                for (index, id) in localIDs.sorted().enumerated() {
                    if index % 1_024 == 0 { try Task.checkCancellation(); guard permits() else { throw CancellationError() } }
                    try db.run("INSERT INTO new_photos_baseline(local_id) VALUES(?)", [.text(id)])
                }
                started = startedAt
                try db.run("INSERT INTO new_photos_baseline_state(id,started_at) VALUES(1,?)", [.date(started)])
            }
            guard permits() else { throw CancellationError() }
            var updated = expectedPreferences
            updated.newPhotosOnly = true
            updated.newPhotosBaselineStartedAt = started
            updated.scope = .entireLibrary
            updated.automatic = true
            try db.run("INSERT INTO preferences(id,json) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET json=excluded.json", [.text(TransferJSON.encode(updated))])
            try db.run("""
                INSERT INTO engine_state(id,intent,blocker,last_message) VALUES(1,'automatic',NULL,NULL) \
                ON CONFLICT(id) DO UPDATE SET intent='automatic',blocker=NULL,last_message=NULL
                """)
            try db.run("DELETE FROM new_photos_activation")
            return updated
        }
    }

    func newPhotosConfirmedCount() throws -> Int {
        guard try newPhotosBaselineStartedAt() != nil else { throw NewPhotosBackupError.missingBaseline }
        var count = 0
        try database().run("SELECT count(*) FROM confirmations WHERE local_id NOT IN (SELECT local_id FROM new_photos_baseline)") { count = Int($0.integer(0) ?? 0) }
        return count
    }
}
