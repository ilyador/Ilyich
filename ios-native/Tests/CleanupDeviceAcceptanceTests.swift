import CryptoKit
import IlyichPlatform
import Photos
import UIKit
import XCTest
@testable import Ilyich

/// Opt-in, owner-attended acceptance of the real Photos adapter. Only assets created by this
/// test are touched. It uses the phone's saved demo sign-in in memory, uploads its own uniquely
/// named fixtures, and removes only those generated server assets afterward. Existing server
/// assets, production backup receipts and existing phone photos are never changed. Ordinary
/// test runs skip this class.
///
/// Run with TEST_RUNNER_ILYICH_CLEANUP_DEVICE_ACCEPTANCE=1. Allow Photos access, decline the
/// first deletion prompt, accept the second, and accept the final cleanup of this test's photos.
@MainActor final class CleanupDeviceAcceptanceTests: XCTestCase {
    func testThirtyDisposablePhotosThroughRealPhotoKit() async throws {
        guard ProcessInfo.processInfo.environment["ILYICH_CLEANUP_DEVICE_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Owner-attended Photos acceptance was not requested.")
        }
        guard let credential = try KeychainCredentialStore().load(), credential.server.host == "demo.sixbox.dedyn.io" else {
            throw XCTSkip("Sign in to the demo server on this phone before the owner-attended test.")
        }
        guard !ReadOnlyPolicy.isEnabled(server: credential.server, userID: credential.userID) else {
            throw XCTSkip("Turn off read-only mode for the owner-attended demo-fixture test.")
        }
        print("CLEANUP ACCEPTANCE: the human owner authorized this attended run to create and remove only its 30 generated phone photos and uniquely named demo-server copies; existing photos and server assets are excluded.")
        executionTimeAllowance = 600
        let permission = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard permission == .authorized else { throw XCTSkip("Full Photos access is required for disposable-fixture acceptance.") }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("IlyichCleanupAcceptance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let server = try AcceptanceServer(credential: credential)
        addTeardownBlock { try await server.cleanupGeneratedAssets() }
        let originals = try (0..<30).map { number -> URL in
            let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
                UIColor(hue: CGFloat(number) / 30, saturation: 0.8, brightness: 0.8, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
                // Names alone do not prevent checksum deduplication across retries.
                (String(folder.lastPathComponent.suffix(8)) as NSString).draw(at: CGPoint(x: 1, y: 4), withAttributes: [.font: UIFont.systemFont(ofSize: 7)])
                ("Ilyich test \(number)" as NSString).draw(at: CGPoint(x: 2, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 7)])
            }
            let url = folder.appendingPathComponent("\(folder.lastPathComponent)-\(number).jpg")
            try XCTUnwrap(image.jpegData(compressionQuality: 0.8)).write(to: url)
            return url
        }
        let fixture = try await createPhotos(originals)
        // Always clean only the exact identifiers this run created, even on an assertion failure.
        addTeardownBlock {
            let remaining = PHAsset.fetchAssets(withLocalIdentifiers: fixture.ids, options: nil)
            let albums = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [fixture.keptAlbum], options: nil)
            if remaining.count > 0 || albums.count > 0 {
                print("CLEANUP ACCEPTANCE: accept removal of the remaining generated test photos.")
                try await PHPhotoLibrary.shared().performChanges(Self.cleanupBlock(fixture))
            }
        }

        let photos = SystemPhotoKit()
        let journal = DeviceDatabase(url: folder.appendingPathComponent("device.sqlite"))
        let adapter = PhotoKitAdapter(library: photos, assets: photos,
                                      journal: journal, staging: photos)
        await adapter.start()
        let records = FakeReceipts()
        let owner = credential.userID
        let authorization = AuthorizationState(account: AccountID(server: URL(string: "https://cleanup-acceptance.invalid/api")!, userID: owner),
                                               token: UUID().uuidString, readOnly: false, requiresPasswordChange: false, mirror: nil)
        let suite = "CleanupDeviceAcceptance-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CleanupSettingsStore(defaults: defaults)
        settings.setKeepFavorites(true)
        settings.setKeepMediaType("none")
        settings.setKeptAlbumIDs([fixture.keptAlbum])
        settings.setCutoffDaysAgo(30)

        let assets = photos.cleanupAssets(fixture.ids.map(DeviceAssetID.init(rawValue:)))
        XCTAssertEqual(assets.count, 30)
        let byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id.rawValue, $0) })
        var remoteIDs: [String] = []
        for (number, id) in fixture.ids.enumerated() {
            let asset = try XCTUnwrap(byID[id])
            let revision = try XCTUnwrap(asset.revision)
            let bytes = try Data(contentsOf: originals[number])
            let uploaded = try await server.upload(originals[number], number: number)
            let checksum = Data(Insecure.SHA1.hash(data: bytes)).base64EncodedString()
            XCTAssertEqual(uploaded.checksum, checksum)
            remoteIDs.append(uploaded.id)
            let receipt = CleanupReceipt(localID: id, revision: revision,
                                         original: .init(id: uploaded.id, checksum: checksum), motion: nil)
            records.put(receipt, notify: false)
        }
        // Real server trash/deletion, a changed local revision, a favorite and a kept album.
        try await server.trash(Array(remoteIDs.prefix(2)))
        try await server.remove(remoteIDs[2])
        try await changeCreationDate(of: fixture.ids[3])

        let service = CleanupService(account: authorization.account.digest, ownerID: owner, authorization: authorization,
                                     receipts: records, device: { PhotoKitCleanupDevice(adapter: adapter, reader: photos) },
                                     remote: { try await server.fetch($0) }, settings: settings,
                                     credentialIsCurrent: { true }, removalAllowed: true)
        addTeardownBlock { await service.shutdown() }
        let scan = try await service.scan()
        let expected = Set(fixture.ids.dropFirst(6))
        XCTAssertEqual(Set(scan.candidates.map(\.localID)), expected)
        XCTAssertEqual(scan.exclusions[fixture.ids[0]], .inServerTrash)
        XCTAssertEqual(scan.exclusions[fixture.ids[1]], .inServerTrash)
        // Immich deliberately conflates a missing asset with denied read access in a 400.
        // Preserve the production verifier's fail-closed interpretation of that response.
        XCTAssertEqual(scan.exclusions[fixture.ids[2]], .serverError)
        XCTAssertEqual(scan.exclusions[fixture.ids[3]], .changedSinceBackup)
        XCTAssertEqual(scan.exclusions[fixture.ids[4]], .favorite)
        XCTAssertEqual(scan.exclusions[fixture.ids[5]], .keptAlbum)

        let selection = Set(fixture.ids[6..<9])
        print("CLEANUP ACCEPTANCE: decline the next Photos deletion prompt.")
        let declined = await service.remove(selection)
        XCTAssertEqual(declined, .declined)
        XCTAssertEqual(PHAsset.fetchAssets(withLocalIdentifiers: fixture.ids, options: nil).count, 30)
        XCTAssertTrue(records.marked.isEmpty)

        print("CLEANUP ACCEPTANCE: accept the next prompt for exactly three generated photos.")
        let removed = await service.remove(selection)
        XCTAssertEqual(removed, .removed(selection.sorted()))
        XCTAssertEqual(PHAsset.fetchAssets(withLocalIdentifiers: Array(selection), options: nil).count, 0)
        XCTAssertEqual(PHAsset.fetchAssets(withLocalIdentifiers: fixture.ids, options: nil).count, 27)
        XCTAssertEqual(records.marked, [selection.sorted()])
        let persisted = try await DeviceDatabase(url: journal.url).records()
        XCTAssertEqual(persisted.compactMap(\.outcome), [.declined, .committed(affected: selection.sorted().map(DeviceAssetID.init(rawValue:)), created: [])])
        for (number, original) in originals.enumerated() {
            XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), "The backup copy remains after local removal.")
            if number != 2 {
                let copy = try await server.fetch(remoteIDs[number])
                XCTAssertEqual(copy.ownerId, owner)
                if (6..<9).contains(number) {
                    let serverBytes = try await server.original(remoteIDs[number])
                    XCTAssertEqual(serverBytes, try Data(contentsOf: original))
                }
            }
        }
        // A real Photos edit after review must prevent removal, whether the observer has
        // already dropped the candidate or the final revision check catches it first.
        try await changeCreationDate(of: fixture.ids[9])
        let changed = await service.remove([fixture.ids[9]])
        XCTAssertTrue([.changed([fixture.ids[9]]), .blocked(.checkAgain)].contains(changed))
        XCTAssertEqual(PHAsset.fetchAssets(withLocalIdentifiers: [fixture.ids[9]], options: nil).count, 1)
        let review = try await service.scan()
        XCTAssertTrue(review.candidates.contains { $0.localID == fixture.ids[10] })
        _ = authorization.setReadOnly(true)
        let blocked = await service.remove([fixture.ids[10]])
        XCTAssertEqual(blocked, .blocked(.readOnly))
        XCTAssertEqual(PHAsset.fetchAssets(withLocalIdentifiers: [fixture.ids[10]], options: nil).count, 1)
    }

    private struct Fixtures: Sendable {
        let ids: [String]
        let keptAlbum: String
    }

    /// The real demo API, fenced to the exact assets this test created. No password is needed,
    /// stored or logged: the existing signed-in session stays inside the app's process.
    private actor AcceptanceServer {
        private let client: APIClient
        private let owner: String
        private let run = "ilyich-cleanup-acceptance-" + UUID().uuidString.lowercased()
        private var created: Set<String> = []
        private var paths: [String: String] = [:]

        init(credential: StoredCredential) throws {
            client = try APIClient(baseURL: credential.server, accessToken: credential.token, userID: credential.userID)
            owner = credential.userID
        }

        func upload(_ file: URL, number: Int) async throws -> BackupRemoteAsset {
            let name = "\(run)-\(number).jpg", boundary = UUID().uuidString
            var request = try await client.authorizedRequest(path: "assets")
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var body = Data()
            func append(_ string: String) { body.append(Data(string.utf8)) }
            let fields = ["deviceAssetId": name, "deviceId": run, "fileCreatedAt": "2020-01-26T00:00:00Z",
                          "fileModifiedAt": "2020-01-26T00:00:00Z", "isFavorite": "false"]
            for (key, value) in fields {
                append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n")
            }
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"assetData\"; filename=\"\(name)\"\r\nContent-Type: image/jpeg\r\n\r\n")
            body.append(try Data(contentsOf: file))
            append("\r\n--\(boundary)--\r\n")
            request.httpBody = body
            let data = try await send(request)
            struct Upload: Decodable { let id: String; let status: String }
            let uploaded = try JSONDecoder().decode(Upload.self, from: data)
            guard uploaded.status == "created" else { throw PhotosChangeFailure(message: "A generated fixture unexpectedly matched an existing server asset.") }
            created.insert(uploaded.id)
            let record: Record = try await client.request(.get, path: "assets/\(uploaded.id)")
            guard record.ownerId == owner, record.originalFileName == name else { throw PhotosChangeFailure(message: "Fixture ownership did not match.") }
            paths[uploaded.id] = record.originalPath ?? name
            return try await fetch(uploaded.id)
        }

        func fetch(_ id: String) async throws -> BackupRemoteAsset {
            guard created.contains(id) else { throw PhotosChangeFailure(message: "A fixture request named an unrelated asset.") }
            return try await client.request(.get, path: "assets/\(id)")
        }

        func original(_ id: String) async throws -> Data {
            guard created.contains(id) else { throw PhotosChangeFailure(message: "A fixture request named an unrelated asset.") }
            let request = try await client.authorizedRequest(path: "assets/\(id)/original")
            return try await send(request)
        }

        func trash(_ ids: [String]) async throws {
            guard Set(ids).isSubset(of: created) else { throw PhotosChangeFailure(message: "A fixture change named an unrelated asset.") }
            try await client.trashAssets(ids: ids)
        }

        func remove(_ id: String) async throws {
            guard created.contains(id), let path = paths[id] else { throw PhotosChangeFailure(message: "A fixture change named an unrelated asset.") }
            // Captured by the durable QA log before each authorized test-data deletion.
            print("CLEANUP ACCEPTANCE: owner-authorized generated server fixture deletion \(id): \(path)")
            try await client.trashAssets(ids: [id], permanently: true)
            for _ in 0..<50 {
                do { _ = try await fetch(id) }
                catch { if Self.isAbsent(error) { return }; throw error }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw PhotosChangeFailure(message: "The generated fixture was not removed from the server.")
        }

        func cleanupGeneratedAssets() async throws {
            defer { Task { await client.shutdown() } }
            for id in created.sorted() {
                do {
                    let record: Record = try await client.request(.get, path: "assets/\(id)")
                    guard record.ownerId == owner, record.originalFileName.hasPrefix(run + "-") else {
                        throw PhotosChangeFailure(message: "Refusing to clean up an unrelated server asset.")
                    }
                    try await remove(id)
                } catch { if Self.isAbsent(error) { continue }; throw error }
            }
        }

        /// Only the fixture teardown treats Immich's deliberately ambiguous response as an
        /// inaccessible copy. Production verification still receives the unmodified failure.
        private static func isAbsent(_ error: any Error) -> Bool {
            guard let failure = error as? ServerFailure else { return false }
            switch failure {
            case .notFound: return true
            case .http(400, "Not found or no asset.read access"): return true
            default: return false
            }
        }

        private struct Record: Decodable {
            let ownerId: String
            let originalFileName: String
            let originalPath: String?
        }

        private func send(_ request: URLRequest) async throws -> Data {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw PhotosChangeFailure(message: "The demo server could not complete the fixture request.")
            }
            return data
        }
    }

    /// No existing identifier is ever included in a Photos change request.
    private func createPhotos(_ urls: [URL]) async throws -> Fixtures {
        let result = Locked<Fixtures?>(nil)
        try await PHPhotoLibrary.shared().performChanges(Self.creationBlock(urls, result: result))
        return try XCTUnwrap(result.value)
    }

    // Like production PhotoChanges, blocks must be formed outside the main actor: Photos runs
    // them on its own queue, and Swift 6 enforces the isolation of their creation context.
    nonisolated private static func creationBlock(_ urls: [URL], result: Locked<Fixtures?>) -> @Sendable () -> Void {
        {
            var placeholders: [PHObjectPlaceholder] = []
            for (number, url) in urls.enumerated() {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: url, options: nil)
                request.creationDate = Date(timeIntervalSince1970: 1_580_000_000)
                request.isFavorite = number == 4
                if let placeholder = request.placeholderForCreatedAsset { placeholders.append(placeholder) }
            }
            let album = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: "Ilyich cleanup acceptance " + UUID().uuidString)
            let kept = album.placeholderForCreatedAssetCollection
            if placeholders.count == 30 {
                album.addAssets([placeholders[5]] as NSArray)
                result.mutate { $0 = Fixtures(ids: placeholders.map(\.localIdentifier), keptAlbum: kept.localIdentifier) }
            }
        }
    }

    private func changeCreationDate(of id: String) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        XCTAssertEqual(assets.count, 1)
        try await PHPhotoLibrary.shared().performChanges(Self.dateChangeBlock(id))
    }

    nonisolated private static func dateChangeBlock(_ id: String) -> @Sendable () -> Void {
        {
            if let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject {
                PHAssetChangeRequest(for: asset).creationDate = Date(timeIntervalSince1970: 1_590_000_000)
            }
        }
    }

    nonisolated private static func cleanupBlock(_ fixture: Fixtures) -> @Sendable () -> Void {
        {
            let remaining = PHAsset.fetchAssets(withLocalIdentifiers: fixture.ids, options: nil)
            let albums = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [fixture.keptAlbum], options: nil)
            if remaining.count > 0 { PHAssetChangeRequest.deleteAssets(remaining) }
            if albums.count > 0 { PHAssetCollectionChangeRequest.deleteAssetCollections(albums) }
        }
    }
}
