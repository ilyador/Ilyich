import IlyichPlatform
import IlyichShareInbox
import UIKit
import XCTest
@testable import Ilyich

/// Pins the formats on disk that outlive a build: share manifests, the widget's snapshots, the
/// thumbnail store's layout, the network settings and the saved session. Each fixture in
/// Tests/Fixtures was written by the production encoder of its day. JSONEncoder orders keys
/// differently from one process to the next, so encodings are compared as JSON. The formats only
/// older builds wrote (backup state, task descriptions and outcomes, version 1 manifests, places
/// and fingerprint caches) went with their readers in B10 and C8.
final class LegacyFormatsTests: XCTestCase {
    private typealias G = LegacyGoldens
    private func bits(_ date: Date?) -> UInt64? { date?.timeIntervalSinceReferenceDate.bitPattern }
    private var widgetFolder: String { "widget/" + AccountStoragePaths(G.account).widgetCache }

    func testEveryFixtureDecodes() throws {
        let files = try FixtureLoader.files(in: "")
        XCTAssertEqual(files.count, 15, "Every fixture reached the test bundle.")
        for path in files {
            let data = try FixtureLoader.data(path)
            let name = (path as NSString).lastPathComponent
            switch path {
            case "share/manifest-v2.json", "share/manifest-v2-with-urls.json": _ = try ShareManifest.decode(data, batch: G.batchID, folder: G.sharedFolder)
            case _ where path.hasPrefix("widget/") && name.hasSuffix("_metadata.json"): _ = try Legacy.decoder().decode(Legacy.WidgetMetadata.self, from: data)
            case _ where path.hasPrefix("widget/") && name.hasSuffix(".png"): XCTAssertNotNil(UIImage(data: data), path)
            case "widget/flutter/defaults.json": _ = try JSONDecoder().decode([String: String].self, from: data)
            case "session/network-config-v1.json": _ = try JSONDecoder().decode(NetworkConfiguration.self, from: data)
            case "session/saved-session-v1.json": _ = try JSONDecoder().decode(StoredCredential.self, from: data)
            case _ where path.hasPrefix("caches/IlyichThumbnails/"): XCTAssertNotNil(UIImage(data: data), path)
            default: XCTFail("\(path) has no reader; every fixture must be decoded here.")
            }
        }
    }

    /// Dates keep their bits: in the rows B9's import wrote on the phone, which the transfer engine
    /// reads (LegacyGoldens.importedSeed; TransferStoreTests round-trips them through the store),
    /// and in both share manifests. The goldens' literals are those bits.
    func testDatesMatchByBitPattern() throws {
        let seed = G.importedSeed()
        XCTAssertEqual(seed.confirmations.map { bits($0.1) }, [G.Bits.l2, G.Bits.l4, G.Bits.l5])
        XCTAssertEqual(bits(seed.receipts.first?.confirmedAt), G.Bits.l2ConfirmedAt)
        XCTAssertEqual(seed.stages.map { bits($0.modified) }, [G.Bits.current, G.Bits.l6])
        for path in ["share/manifest-v2.json", "share/manifest-v2-with-urls.json"] {
            let manifest = try ShareManifest.decode(FixtureLoader.data(path), batch: G.batchID, folder: G.sharedFolder)
            XCTAssertEqual(bits(manifest.createdAt), G.Bits.manifest, path)
        }
        for (date, pinned) in [(G.Dates.current, G.Bits.current), (G.Dates.l2, G.Bits.l2), (G.Dates.l4, G.Bits.l4), (G.Dates.l5, G.Bits.l5),
                               (G.Dates.l6, G.Bits.l6), (G.Dates.l2ConfirmedAt, G.Bits.l2ConfirmedAt), (G.Dates.failure, G.Bits.failure),
                               (G.Dates.manifest, G.Bits.manifest)] {
            XCTAssertEqual(bits(date), pinned)
        }
    }

    func testProductionEncodersWriteTheFixtures() throws {
        let encoder = JSONEncoder()
        var table: [(path: String, produced: Data, sets: Set<String>)] = [
            ("share/manifest-v2.json", try ShareManifest.encode(G.manifestV2), []),
            ("session/network-config-v1.json", try encoder.encode(G.networkConfiguration.validated()), []),
            ("session/saved-session-v1.json", try encoder.encode(G.credential), []),
            // The widget's writer is compiled only into the Swift 5 widget extension; its verbatim mirror stands in.
            ("widget/flutter/random_NONE_0_metadata.json", try encoder.encode(G.flutterMetadata), []),
        ]
        for (key, metadata) in G.widgetMetadata { table.append(("\(widgetFolder)/\(key)_metadata.json", try encoder.encode(metadata), [])) }
        for entry in table {
            XCTAssertEqual(try FixtureLoader.canonicalJSON(entry.produced, unorderedArrays: entry.sets),
                           try FixtureLoader.canonicalJSON(FixtureLoader.data(entry.path), unorderedArrays: entry.sets), entry.path)
        }
        // A version 2 manifest is written with sorted keys, so the fixture is its exact bytes.
        XCTAssertEqual(String(decoding: try ShareManifest.encode(G.manifestV2), as: UTF8.self),
                       String(decoding: try FixtureLoader.data("share/manifest-v2.json"), as: UTF8.self))
    }

    /// What the Share extension and the app write today, version 2 by name alone, and what builds
    /// from W3 to 3040093 wrote, each file's URL beside its name, read as the same batch: the URLs
    /// are skipped, so a batch survives a moved container.
    func testShareManifestV2() throws {
        let data = try FixtureLoader.data("share/manifest-v2.json")
        XCTAssertEqual(try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])["v"] as? Int, 2)
        XCTAssertNil(String(decoding: data, as: UTF8.self).range(of: "url"), "Files are written by name alone.")
        XCTAssertEqual(try ShareManifest.decode(data, batch: G.batchID, folder: G.sharedFolder), G.manifestV2)
        let withURLs = try FixtureLoader.data("share/manifest-v2-with-urls.json")
        XCTAssertEqual(try ShareManifest.decode(withURLs, batch: G.batchID, folder: G.sharedFolder), G.manifestV2,
                       "What builds from W3 to 3040093 left on the phone reads as the same batch.")
        let moved = URL(fileURLWithPath: "/private/var/mobile/Containers/Shared/AppGroup/11111111-2222-4333-8444-555555555555/ShareInbox/\(G.batchID.uuidString)",
                        isDirectory: true)
        for manifest in [data, withURLs] {
            XCTAssertEqual(try ShareManifest.decode(manifest, batch: G.batchID, folder: moved).attachments.first?.original.url.path,
                           moved.path + "/" + G.sharedFiles[0])
        }
        XCTAssertThrowsError(try ShareManifest.decode(data, batch: UUID(), folder: G.sharedFolder), "A manifest belongs to its own folder.")
    }

    func testWidgetCacheV1AndFlutterWidgetKeys() throws {
        XCTAssertEqual(try FixtureLoader.files(in: widgetFolder),
                       ["memory_1_image.png", "memory_1_metadata.json", "random_NONE_0_image.png", "random_NONE_0_metadata.json"])
        XCTAssertEqual(widgetFolder, "widget/WidgetCache2/\(G.digest)")
        let random = try FixtureLoader.decode(Legacy.WidgetMetadata.self, from: "\(widgetFolder)/random_NONE_0_metadata.json")
        XCTAssertEqual(random.accountScope, G.digest, "A snapshot is shown only to the account that cached it.")
        XCTAssertEqual(random.deepLink?.absoluteString, "immich://asset?id=\(G.widgetAsset)")
        XCTAssertFalse(random.forceFullColor)
        XCTAssertNil(random.subtitle); XCTAssertNil(random.error)
        let memory = try FixtureLoader.decode(Legacy.WidgetMetadata.self, from: "\(widgetFolder)/memory_1_metadata.json")
        XCTAssertEqual(memory.subtitle, "3 years ago")
        XCTAssertEqual(memory.deepLink?.absoluteString, "immich://memory?id=\(G.memoryID)")
        XCTAssertTrue(memory.forceFullColor)
        for path in ["\(widgetFolder)/random_NONE_0_image.png", "\(widgetFolder)/memory_1_image.png", "widget/flutter/random_NONE_0_image.png"] {
            let png = try FixtureLoader.data(path)
            XCTAssertEqual(Array(png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], path)
            XCTAssertNil(png.range(of: Data("CgBI".utf8)), "\(path) was copied into the bundle unchanged.")
        }
        // An error encodes as Swift encodes a case without values.
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(Legacy.WidgetError.fetchFailed), as: UTF8.self), #"{"fetchFailed":{}}"#)
        XCTAssertEqual(try JSONDecoder().decode(Legacy.WidgetMetadata.self, from: Data(#"{"error":{"noLogin":{}}}"#.utf8)).error, .noLogin)

        // The Flutter app's widget: its credentials in the App Group's preferences and a snapshot
        // at the container's root, without an account.
        let flutter = try FixtureLoader.decode(Legacy.WidgetMetadata.self, from: "widget/flutter/random_NONE_0_metadata.json")
        XCTAssertNil(flutter.accountScope)
        XCTAssertTrue(flutter.forceFullColor)
        XCTAssertEqual(flutter.deepLink?.absoluteString, "immich://asset?id=\(G.widgetAsset)")
        let values = try JSONDecoder().decode([String: String].self, from: FixtureLoader.data("widget/flutter/defaults.json"))
        XCTAssertEqual(Set(values.keys), Set(Legacy.FlutterWidgetCredentials.keys))
        let suite = "LegacyFormatsTests.flutter"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        for (key, value) in values { defaults.set(value, forKey: key) }
        let credentials = try XCTUnwrap(Legacy.FlutterWidgetCredentials(defaults: defaults))
        XCTAssertEqual(credentials.serverURL, "https://photos.example.org/api")
        XCTAssertEqual(credentials.token, "flutter-session-token")
        XCTAssertEqual(credentials.customHeaders, ["CF-Access-Client-Id": "client.access", "CF-Access-Client-Secret": "access-secret"])
        // Flutter's sign-out wrote empty strings.
        defaults.set("", forKey: Legacy.FlutterWidgetCredentials.tokenKey)
        XCTAssertNil(Legacy.FlutterWidgetCredentials(defaults: defaults))
    }

    func testThumbnailTreeV1IsTheStoreLayout() async throws {
        let scope = G.account.cacheScope
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LegacyFormatsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ThumbnailDiskStore.shared(scope: scope, root: root)
        let fixture = try FixtureLoader.files(in: "caches/IlyichThumbnails")
        XCTAssertEqual(Set(fixture.map { $0.split(separator: "/")[0] }), [Substring(G.digest.prefix(32))])
        XCTAssertEqual(AccountStoragePaths(G.account).thumbnails, "IlyichThumbnails/" + G.digest.prefix(32))
        var expected: [String] = []
        for (assetID, revision) in G.thumbnails {
            let path = Legacy.thumbnailPath(scope: scope, assetID: assetID, revision: revision)
            XCTAssertEqual(store.url(assetID: assetID, revision: revision).path, root.appendingPathComponent(path).path, assetID)
            let bytes = try FixtureLoader.data("caches/" + path)
            await store.store(bytes, assetID: assetID, revision: revision)
            XCTAssertEqual(store.data(assetID: assetID, revision: revision), bytes, assetID)
            expected.append(String(path.dropFirst("IlyichThumbnails/".count)))
        }
        XCTAssertEqual(fixture, expected.sorted())
        let written = FileManager.default.enumerator(at: root.appendingPathComponent("IlyichThumbnails"), includingPropertiesForKeys: [.isRegularFileKey])?
            .compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
            // T1's index sits beside the folders; the thumbnails themselves keep the v1 layout.
            .filter { !$0.lastPathComponent.hasPrefix(ThumbnailDiskStore.indexName) }
        XCTAssertEqual(written?.count, fixture.count, "The store wrote nothing else.")
        // An ID with characters other than letters, digits and hyphens is hashed; others are lowercased.
        XCTAssertTrue(expected.contains { $0.contains("/6f1c2a40-0000-4000-8000-000000000001.") })
        XCTAssertFalse(expected.contains { $0.contains("local") })
    }

    func testNetworkConfigurationAndSavedSessionV1() throws {
        let data = try FixtureLoader.data("session/network-config-v1.json")
        let network = try JSONDecoder().decode(NetworkConfiguration.self, from: data)
        XCTAssertEqual(network, try G.networkConfiguration.validated())
        XCTAssertEqual(try network.validated(), network, "Loading validates without changing what was stored.")
        XCTAssertEqual(Set(try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys),
                       ["customHeaders", "alternateEndpoints", "automaticallySwitchEndpoints", "preferredWifiName", "localEndpoint"])
        let session = try FixtureLoader.data("session/saved-session-v1.json")
        let credential = try JSONDecoder().decode(StoredCredential.self, from: session)
        XCTAssertEqual(credential, G.credential)
        XCTAssertEqual(credential.scope, G.digest)
        XCTAssertEqual(Set(try XCTUnwrap(JSONSerialization.jsonObject(with: session) as? [String: Any]).keys),
                       ["server", "token", "userID", "name", "requiresPasswordChange"])
    }
}
