import Foundation
import IlyichPlatform
import Photos
import Synchronization
import XCTest
@testable import Ilyich

/// Photos as backup staging and discovery see it: photos in albums, each staged as files whose
/// bytes follow its ID and date, so an edited photo has another checksum.
final class FakeStaging: PhotoLibraryStaging {
    struct Photo: Sendable {
        var modified: Date
        var isVideo = false
        var isLive = false
        var sidecar = false
        var bytes = 64
    }

    struct Staged: Sendable {
        let localID: String
        let policy: StagingPolicy
    }

    private struct State {
        var access: PHAuthorizationStatus = .authorized
        var photos: [String: Photo] = [:]
        var albums: [String: [String]] = [:]
        var failures: [String: [@Sendable () -> any Error]] = [:]
        var gates: [String: TransferGate] = [:]
        var staged: [Staged] = []
        /// Discovery waits here after its first batch.
        var discoveryGate: TransferGate?
        var discoveryReachedGate = false
    }

    private let state = Mutex(State())
    static let album = "album-1"

    func add(_ id: String, _ photo: Photo = Photo(modified: FakeStaging.date), album: String = FakeStaging.album) {
        state.withLock {
            $0.photos[id] = photo
            if !($0.albums[album] ?? []).contains(id) { $0.albums[album, default: []].append(id) }
        }
    }

    func edit(_ id: String, modified: Date) { state.withLock { $0.photos[id]?.modified = modified } }
    func delete(_ id: String) {
        state.withLock { state in
            state.photos[id] = nil
            for album in state.albums.keys { state.albums[album]?.removeAll { $0 == id } }
        }
    }
    func setAccess(_ status: PHAuthorizationStatus) { state.withLock { $0.access = status } }
    /// The next staging of the photo throws.
    func fail(_ id: String, _ error: @escaping @Sendable () -> any Error) { state.withLock { $0.failures[id, default: []].append(error) } }
    /// Staging of the photo waits at the gate.
    func hold(_ id: String, at gate: TransferGate) { state.withLock { $0.gates[id] = gate } }
    func holdDiscovery(at gate: TransferGate) { state.withLock { $0.discoveryGate = gate } }
    var discoveryWaits: Bool { state.withLock { $0.discoveryReachedGate } }
    var staged: [Staged] { state.withLock { $0.staged } }
    func stagings(_ id: String) -> Int { staged.filter { $0.localID == id }.count }

    static let date = Date(timeIntervalSinceReferenceDate: 700_000_000.25)

    var authorization: PHAuthorizationStatus { state.withLock { $0.access } }

    func albums() async -> [DeviceAlbum] {
        state.withLock { $0.albums.map { DeviceAlbum(id: $0.key, title: $0.key, count: $0.value.count, isShared: false) } }
    }

    func candidates(included: Set<String>, excluded: Set<String>) -> AsyncThrowingStream<[DeviceCandidate], any Error> {
        let (candidates, gate) = state.withLock { state -> ([DeviceCandidate], TransferGate?) in
            let excludedIDs = Set(excluded.flatMap { state.albums[$0] ?? [] })
            let ids = Set(included.flatMap { state.albums[$0] ?? [] }).subtracting(excludedIDs).sorted()
            return (ids.compactMap { id in state.photos[id].map { DeviceCandidate(id: id, modified: $0.modified) } }, state.discoveryGate)
        }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: [DeviceCandidate].self)
        let task = Task {
            for (index, candidate) in candidates.enumerated() {
                continuation.yield([candidate])
                if index == 0, let gate {
                    self.state.withLock { $0.discoveryReachedGate = true }
                    await gate.wait()
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func stage(_ localID: String, into directory: URL, stageID: String, policy: StagingPolicy,
               progress: @escaping @Sendable (Double) -> Void) async throws -> PreparedPhoto {
        let (photo, failure, gate) = state.withLock { state in
            state.staged.append(Staged(localID: localID, policy: policy))
            let failure = state.failures[localID]?.isEmpty == false ? state.failures[localID]!.removeFirst() : nil
            return (state.photos[localID], failure, state.gates.removeValue(forKey: localID))
        }
        if let gate { await gate.wait() }
        if let failure { throw failure() }
        guard let photo else { throw BackupError.item("This photo is no longer available to Ilyich. Check Photos access and retry.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func file(_ name: String, filename: String, type: String) throws -> UploadFile {
            let url = directory.appendingPathComponent(name)
            let seed = "\(localID)|\(name)|\(photo.modified.timeIntervalSinceReferenceDate)|"
            let body = String(repeating: seed, count: photo.bytes / max(seed.utf8.count, 1) + 1).prefix(photo.bytes)
            try Data(body.utf8).write(to: url)
            return UploadFile(url: url, filename: filename, contentType: type)
        }
        let original = try file("original", filename: localID + (photo.isVideo ? ".MOV" : ".HEIC"), type: photo.isVideo ? "video/quicktime" : "image/heic")
        let motion = photo.isLive ? try file("motion", filename: localID + "-live.MOV", type: "video/quicktime") : nil
        let sidecar = photo.sidecar ? try file("sidecar", filename: localID + ".xmp", type: "application/rdf+xml") : nil
        var fields = StagingRules.fields(created: photo.modified, modified: photo.modified, isFavorite: false, duration: photo.isVideo ? 3 : 0)
        fields["metadata"] = #"[{"key":"mobile-app","value":{"iCloudId":"cloud-\#(localID)"}}]"#
        return PreparedPhoto(localID: localID, modificationDate: photo.modified, original: original, motion: motion, sidecar: sidecar,
                             fields: fields, isVideo: photo.isVideo, stageID: stageID)
    }

    func albumMembers(_ albumID: String, excluded: Set<String>) async -> [String] {
        state.withLock { $0.albums[albumID] ?? [] }.sorted()
    }

    func existing(_ localIDs: [String]) async throws -> Set<String> {
        state.withLock { state in Set(localIDs.filter { state.photos[$0] != nil }) }
    }
}

/// The server as transfers see it: the bulk upload check, upload requests and Live Photo pairing.
final class FakeTransferServer: TransferServerAPI {
    struct Check: Equatable, Sendable {
        let id: String
        let checksum: String
    }

    struct Request: Equatable, Sendable {
        let boundary: String
        let allowsCellular: Bool
    }

    enum Holding: Sendable {
        case duplicate(String, trashed: Bool)
        case rejected(String)
    }

    private struct State {
        var held: [String: Holding] = [:]
        var checks: [Check] = []
        var requests: [Request] = []
        var pairings: [String: String] = [:]
        var paired: [(asset: String, motion: String)] = []
    }

    private let state = Mutex(State())

    /// The server already holds a file with this checksum.
    func hold(checksum: String, as holding: Holding) { state.withLock { $0.held[checksum] = holding } }
    func pair(_ asset: String, with motion: String) { state.withLock { $0.pairings[asset] = motion } }
    var checks: [Check] { state.withLock { $0.checks } }
    var requests: [Request] { state.withLock { $0.requests } }
    var paired: [String: String] { state.withLock { Dictionary($0.paired.map { ($0.asset, $0.motion) }, uniquingKeysWith: { $1 }) } }

    func bulkUploadCheck(_ items: [UploadCheck.Item]) async throws -> [UploadCheckResponse.Result] {
        try await results(for: items)
    }

    private func results(for items: [UploadCheck.Item]) async throws -> [UploadCheckResponse.Result] {
        let data = try state.withLock { state -> Data in
            let results: [[String: Any]] = items.map { item in
                state.checks.append(Check(id: item.id, checksum: item.checksum))
                switch state.held[item.checksum] {
                case .duplicate(let asset, let trashed)?:
                    return ["id": item.id, "action": "reject", "reason": "duplicate", "assetId": asset, "isTrashed": trashed]
                case .rejected(let reason)?:
                    return ["id": item.id, "action": "reject", "reason": reason]
                case nil:
                    return ["id": item.id, "action": "accept"]
                }
            }
            return try JSONSerialization.data(withJSONObject: ["results": results])
        }
        return try JSONDecoder().decode(UploadCheckResponse.self, from: data).results
    }

    func uploadRequest(boundary: String, allowsCellular: Bool) async throws -> URLRequest {
        state.withLock { $0.requests.append(Request(boundary: boundary, allowsCellular: allowsCellular)) }
        var request = URLRequest(url: URL(string: "https://photos.example/api/assets")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.allowsCellularAccess = allowsCellular
        request.allowsExpensiveNetworkAccess = allowsCellular
        return request
    }

    func remoteAsset(id: String) async throws -> BackupRemoteAsset {
        BackupRemoteAsset(id: id, ownerId: "owner", checksum: "", isTrashed: false, livePhotoVideoId: state.withLock { $0.pairings[id] })
    }

    func livePhotoVideoID(of assetID: String) async throws -> String? { state.withLock { $0.pairings[assetID] } }

    func setLivePhotoVideo(assetID: String, motionID: String) async throws {
        state.withLock {
            $0.pairings[assetID] = motionID
            $0.paired.append((assetID, motionID))
        }
    }

    func createStack(_ assetIDs: [String]) async throws {}
    func addToAlbum(_ albumID: String, assetIDs: [String]) async throws -> [BulkResult] { [] }
    func ownedAlbums() async throws -> [Album] { [] }
    func createAlbum(name: String) async throws -> Album { throw URLError(.unsupportedURL) }
}

/// The background transport and the server's answer to each upload. A body sent is read back, so a
/// test sees its fields, file name and boundary. By default each upload is created as a new
/// asset; a script per file name answers otherwise.
final class FakeUploads: PartUploading {
    struct Upload: Sendable {
        let key: AttemptKey
        let filename: String
        let boundary: String
        let fields: [String: String]
        let hasSidecar: Bool
        let allowsCellular: Bool
    }

    enum Answer: Sendable {
        case created
        case duplicate(String)
        case status(Int)
    }

    private struct State {
        var uploads: [Upload] = []
        var scripts: [String: [Answer]] = [:]
        var onDisk: [AttemptID: OutcomeRecord] = [:]
        var acknowledged: [AttemptID] = []
        var nextTask = 0
        var nextAsset = 0
        var gate: TransferGate?
        var waiting = 0
    }

    private let state = Mutex(State())
    let group: TemporaryAppGroup

    init(group: TemporaryAppGroup) { self.group = group }

    var uploads: [Upload] { state.withLock { $0.uploads } }
    func uploads(of filename: String) -> [Upload] { uploads.filter { $0.filename == filename } }
    var acknowledged: [AttemptID] { state.withLock { $0.acknowledged } }
    /// Uploads with the transport and not yet answered.
    var waiting: Int { state.withLock { $0.waiting } }
    func answer(_ filename: String, _ answers: Answer...) { state.withLock { $0.scripts[filename, default: []].append(contentsOf: answers) } }
    /// Answers wait at the gate.
    func hold(at gate: TransferGate) { state.withLock { $0.gate = gate } }
    /// An answer already on disk for the attempt, which nobody applied.
    func record(_ outcome: OutcomeRecord, for attempt: AttemptID) { state.withLock { $0.onDisk[attempt] = outcome } }

    func submit(_ request: URLRequest, key: AttemptKey) async throws -> Int {
        let body = String(decoding: try Data(contentsOf: group.url(key.bodyPath)), as: UTF8.self)
        let type = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        let boundary = type.components(separatedBy: "boundary=").last ?? ""
        var fields: [String: String] = [:]
        var filename = ""
        var hasSidecar = false
        for part in body.components(separatedBy: "--" + boundary) {
            guard let header = part.range(of: "\r\n\r\n") else { continue }
            let head = String(part[..<header.lowerBound])
            let value = String(part[header.upperBound...]).replacingOccurrences(of: "\r\n", with: "")
            guard let name = head.components(separatedBy: "name=\"").dropFirst().first?.components(separatedBy: "\"").first else { continue }
            if name == "assetData" {
                filename = head.components(separatedBy: "filename=\"").dropFirst().first?.components(separatedBy: "\"").first ?? ""
            } else if name == "sidecarData" {
                hasSidecar = true
            } else {
                fields[name] = value
            }
        }
        return state.withLock { state in
            state.uploads.append(Upload(key: key, filename: filename, boundary: boundary, fields: fields, hasSidecar: hasSidecar,
                                        allowsCellular: request.allowsCellularAccess))
            state.nextTask += 1
            return state.nextTask
        }
    }

    func recordedOutcome(for key: AttemptKey) throws -> OutcomeRecord? { state.withLock { $0.onDisk[key.attempt] } }

    func outcome(for key: AttemptKey, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> OutcomeRecord {
        let gate = state.withLock { state -> TransferGate? in
            state.waiting += 1
            return state.gate
        }
        if let gate { await gate.wait() }
        progress(10, 10)
        return state.withLock { state in
            state.waiting -= 1
            let upload = state.uploads.last { $0.key == key }
            let filename = upload?.filename ?? ""
            let answer = state.scripts[filename]?.isEmpty == false ? state.scripts[filename]!.removeFirst() : .created
            switch answer {
            case .created:
                state.nextAsset += 1
                return OutcomeRecord(receipt: .init(id: "srv-\(filename)-\(state.nextAsset)", status: "created"), v: 2)
            case .duplicate(let id):
                return OutcomeRecord(receipt: .init(id: id, status: "duplicate"), v: 2)
            case .status(let status):
                return OutcomeRecord(httpStatus: status, v: 2)
            }
        }
    }

    func acknowledge(_ key: AttemptKey, keepingBody: Bool) throws {
        state.withLock {
            $0.onDisk[key.attempt] = nil
            $0.acknowledged.append(key.attempt)
        }
        if !keepingBody { try? FileManager.default.removeItem(at: group.url(key.bodyPath)) }
    }
}

/// The library job executor on a transfer engine that owns a fresh database, with fake Photos, a
/// fake server and a fake transport, in a throwaway App Group. Backup covers FakeStaging.album.
struct LibraryJobHarness {
    let group: TemporaryAppGroup
    let folder: URL
    let store: TransferStore
    let clock = TestClock()
    let authorization = FakeTransferAuthorization()
    let staging = FakeStaging()
    let server = FakeTransferServer()
    let uploads: FakeUploads
    let pipeline: TransferPipeline
    let executor: LibraryJobExecutor
    let engine: TransferEngine<TestClock>
    static let account = FakeTransferAuthorization.account

    init(limits: TransferPipeline.Limits = TransferPipeline.Limits(), preferences: TransferPreferences = LibraryJobHarness.preferences()) async throws {
        group = try TemporaryAppGroup()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryJobs-" + UUID().uuidString, isDirectory: true)
        store = TransferStore(url: folder.appendingPathComponent("transfers.sqlite"))
        try await store.claimForEngine()
        try await store.savePreferences(preferences)
        uploads = FakeUploads(group: group)
        pipeline = TransferPipeline(limits: limits)
        executor = LibraryJobExecutor(store: store, staging: staging, server: server, uploader: uploads, layout: group.layout,
                                      account: Self.account, pipeline: pipeline)
        let clock = self.clock
        engine = TransferEngine(store: store, executor: executor, authorization: authorization, clock: clock, concurrency: executor.concurrency,
                                now: { TransferEngineHarness.base.addingTimeInterval(TimeInterval(clock.now.offset.components.seconds)) },
                                random: { 0.5 })
    }

    static func preferences(cellularPhotos: Bool = false, cellularVideos: Bool = false) -> TransferPreferences {
        var preferences = TransferPreferences(Legacy.BackupPreferences())
        preferences.includedAlbums = [FakeStaging.album]
        preferences.cellularPhotos = cellularPhotos
        preferences.cellularVideos = cellularVideos
        return preferences
    }

    /// Queues the photos as a selection and starts an automatic run.
    func run(_ ids: String...) async throws {
        _ = try await engine.enqueue(ids.map { TransferRequest(source: .photo(DeviceAssetID(rawValue: $0)), origin: .selection) })
        try await engine.setIntent(.automatic)
        try await engine.start()
    }

    func discover() async throws -> DiscoveryMerge? {
        try await engine.discover(LibraryDiscovery(store: store, staging: staging))
    }

    func job(_ id: String) async throws -> StoredJob? { try await store.job(lane: .library, sourceKey: id) }
    func receipt(_ id: String) async throws -> TransferReceipt? { try await store.receipts(for: [id])[id] }
    func backedUp(_ ids: String...) async throws -> Bool { try await store.receipts(for: ids).count == ids.count }
    func states(_ ids: String...) async throws -> [JobState?] {
        var states: [JobState?] = []
        for id in ids { states.append(try await job(id)?.state) }
        return states
    }
    func confirmed(_ id: String) async throws -> Bool { try await store.historyPage(offset: 0, limit: 1_000).contains { $0.localID.rawValue == id } }
    func dump(_ table: String) async throws -> [[TransferSQLite.Value]] { try await store.dump()[table] ?? [] }

    /// A job with a stage and attempts as an earlier run or build left them, then given back.
    func seed(_ id: String, stage: (String) -> LibraryStage, attempts: [LibraryAttempt] = []) async throws {
        _ = try await store.enqueue([TransferRequest(source: .photo(DeviceAssetID(rawValue: id)), origin: .legacy)])
        let token = UUID()
        guard let job = try await store.job(lane: .library, sourceKey: id), try await store.lease(job: job.id, token: token) else {
            throw TransferEngineHarness.Missing()
        }
        let folder = AccountStoragePaths(Self.account).backup + "/" + UUID().uuidString
        let made = stage(folder)
        let saved = try await store.saveStage(made, job: job.id, token: token)
        XCTAssertTrue(saved)
        for attempt in attempts {
            let recorded = try await store.saveAttempt(attempt, job: job.id, token: token)
            XCTAssertTrue(recorded)
        }
        _ = try await store.advance(job: job.id, token: token, to: .staged, phase: nil)
        try await store.release(job: job.id, token: token)
    }

    /// A staged file of the test's in the stage's folder.
    func stagedFile(_ folder: String, _ name: String, filename: String, contents: String) throws -> StagedFile {
        try group.write(contents, to: folder + "/" + name)
        return StagedFile(path: folder + "/" + name, filename: filename, contentType: "application/octet-stream")
    }

    func tearDown() async {
        await engine.stop()
        await store.close()
        try? FileManager.default.removeItem(at: folder)
        group.remove()
    }
}
