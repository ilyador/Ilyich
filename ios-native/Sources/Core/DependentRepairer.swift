import Foundation

/// Where a repair gets an asset's dependents: its EXIF, faces and OCR, as the sync stream's own
/// records (AssetExifV1, AssetFaceV3, AssetOcrV1).
protocol DependentFetching: Sendable {
    func dependents(of assetID: String) async throws -> [EntitySyncEvent]
}

/// Fetches the dependents of one asset again (architecture section 1, DependentRepairer). The
/// index queues an asset when the sync stream cannot bring its dependents back by itself, as
/// when a photo leaves the Locked Folder: locking dropped its EXIF, faces and OCR, and the server
/// sends them again only when they change. Repairs run while the app is in front, two at a time;
/// one that fails waits and is tried again, up to `attempts` times.
actor DependentRepairer {
    private let index: LibraryIndex
    private let fetcher: any DependentFetching
    private let concurrency: Int
    private let attempts: Int

    init(index: LibraryIndex, fetcher: any DependentFetching, concurrency: Int = 2, attempts: Int = 5) {
        self.index = index
        self.fetcher = fetcher
        self.concurrency = max(concurrency, 1)
        self.attempts = max(attempts, 1)
    }

    /// Repairs every asset due now and returns what the repairs changed. Cancelling stops it
    /// between repairs; what was written stays.
    func run(now: Date = Date()) async -> IndexChange {
        var change = IndexChange()
        var tried = Set<String>()
        while !Task.isCancelled {
            guard let due = try? await index.dueRepairs(limit: 32, now: now) else { break }
            let batch = due.filter { !tried.contains($0) }
            guard !batch.isEmpty else { break }
            tried.formUnion(batch)
            await withTaskGroup(of: IndexChange?.self) { group in
                var next = batch.makeIterator()
                for _ in 0..<concurrency { if let id = next.next() { group.addTask { await self.repair(id, now: now) } } }
                while let done = await group.next() {
                    if let done { change.merge(done) }
                    if !Task.isCancelled, let id = next.next() { group.addTask { await self.repair(id, now: now) } }
                }
            }
        }
        change.limitItems()
        return change
    }

    private func repair(_ assetID: String, now: Date) async -> IndexChange? {
        do {
            try await index.beginRepair(assetID: assetID)
            let events = try await fetcher.dependents(of: assetID)
            try Task.checkCancellation()
            return try await index.applyRepair(assetID: assetID, events)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return nil }
            let failures = (try? await index.writer.repairAttempts()[assetID]) ?? 0
            let retry = Self.isPermanent(error) || failures + 1 >= attempts ? nil : now.addingTimeInterval(60 * pow(4, Double(failures)))
            try? await index.failRepair(assetID: assetID, retryAt: retry)
            return nil
        }
    }

    /// The asset is gone, or the account may no longer see it: there is nothing to repair. Immich
    /// answers a photo the account cannot read, gone or locked, with 400 (requireAccess).
    static func isPermanent(_ error: any Error) -> Bool {
        switch error as? ServerFailure {
        case .notFound?, .forbidden?, .undecodable?, .http(400, _)?: true
        default: false
        }
    }
}

/// Fetches an asset's dependents from the server: the asset for its EXIF, its faces and its OCR,
/// written in the sync stream's shapes so the index stores them as if the stream had sent them.
struct ServerDependentFetcher: DependentFetching {
    let client: APIClient

    /// AssetExifV1's fields; the asset's exifInfo carries them under the same names.
    static let exifFields = [
        "description", "exifImageWidth", "exifImageHeight", "fileSizeInByte", "orientation", "dateTimeOriginal", "modifyDate",
        "timeZone", "latitude", "longitude", "projectionType", "city", "state", "country", "make", "model", "lensModel",
        "fNumber", "focalLength", "iso", "exposureTime", "profileDescription", "rating", "fps",
    ]
    static let faceFields = ["imageWidth", "imageHeight", "boundingBoxX1", "boundingBoxY1", "boundingBoxX2", "boundingBoxY2"]
    static let ocrFields = ["x1", "y1", "x2", "y2", "x3", "y3", "x4", "y4", "boxScore", "textScore", "text"]

    func dependents(of assetID: String) async throws -> [EntitySyncEvent] {
        let asset: [String: EntityJSON] = try await client.request(.get, path: "assets/\(assetID)")
        // Locked again since it was queued: it keeps no dependents.
        if asset["visibility"]?.string == "locked" { return [] }
        let faces: [[String: EntityJSON]] = try await optional { try await client.request(.get, path: "faces", query: [URLQueryItem(name: "id", value: assetID)]) }
        let ocr: [[String: EntityJSON]] = try await optional { try await client.request(.get, path: "assets/\(assetID)/ocr") }
        return Self.events(assetID: assetID, asset: asset, faces: faces, ocr: ocr)
    }

    /// Faces and OCR the server won't give this account, or doesn't have, are none; any other
    /// failure fails the repair, which is tried again.
    private func optional(_ fetch: () async throws -> [[String: EntityJSON]]) async throws -> [[String: EntityJSON]] {
        do { return try await fetch() } catch where DependentRepairer.isPermanent(error) { return [] }
    }

    /// The records for what the server answered, each with every field of its sync shape.
    static func events(assetID: String, asset: [String: EntityJSON], faces: [[String: EntityJSON]], ocr: [[String: EntityJSON]]) -> [EntitySyncEvent] {
        var events: [EntitySyncEvent] = []
        if case .object(let exif)? = asset["exifInfo"] {
            var record: [String: EntityJSON] = ["assetId": .string(assetID)]
            for field in exifFields { record[field] = exif[field] ?? .null }
            events.append(EntitySyncEvent(type: "AssetExifV1", data: record, ack: "AssetExifV1|repair"))
        }
        for face in faces {
            guard let id = face["id"]?.string else { continue }
            var record: [String: EntityJSON] = ["id": .string(id), "assetId": .string(assetID), "deletedAt": .null, "isVisible": .bool(true),
                                                "sourceType": face["sourceType"] ?? .string("machine-learning")]
            if case .object(let person)? = face["person"], let personID = person["id"]?.string { record["personId"] = .string(personID) } else { record["personId"] = .null }
            for field in faceFields { record[field] = face[field] ?? .null }
            events.append(EntitySyncEvent(type: "AssetFaceV3", data: record, ack: "AssetFaceV3|repair"))
        }
        for line in ocr {
            guard let id = line["id"]?.string else { continue }
            var record: [String: EntityJSON] = ["id": .string(id), "assetId": .string(assetID), "isVisible": .bool(true)]
            for field in ocrFields { record[field] = line[field] ?? .null }
            events.append(EntitySyncEvent(type: "AssetOcrV1", data: record, ack: "AssetOcrV1|repair"))
        }
        return events
    }
}
