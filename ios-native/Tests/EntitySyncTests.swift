import Foundation
import IlyichPlatform
import XCTest
@testable import Ilyich

@MainActor
final class EntitySyncTests: XCTestCase {
    private func makeStore(_ root: URL, scope: String = "server|alice") throws -> EntityStore {
        try EntityStore(scope: scope, userID: "alice", directory: root)
    }
    private func event(_ type: String, _ json: String, ack: String? = nil) throws -> EntitySyncEvent {
        .init(type: type, data: try JSONDecoder().decode([String: EntityJSON].self, from: Data(json.utf8)), ack: ack ?? type + "|1")
    }
    private func asset(_ id: String, owner: String = "alice", visibility: String = "timeline", deleted: Bool = false, favorite: Bool = false, stack: String? = nil, developed: Bool = true) throws -> EntitySyncEvent {
        try event("AssetV2", """
        {"id":"\(id)","ownerId":"\(owner)","type":"IMAGE","originalFileName":"\(id).NEF","checksum":"AQIDBA==","width":6000,"height":4000,"fileCreatedAt":"2026-01-31T23:30:00Z","localDateTime":"2026-02-01T05:00:00Z","createdAt":"2026-03-01T00:00:00Z","visibility":"\(visibility)","isFavorite":\(favorite),"deletedAt":\(deleted ? "\"2026-03-04T00:00:00Z\"" : "null"),"stackId":\(stack.map { "\"\($0)\"" } ?? "null"),"isEdited":false,"isDeveloped":\(developed),"mediaRevision":"xmp-7"}
        """, ack: "AssetV2|\(id)")
    }
    func testCancelledReadLeavesDatabaseAvailableForNextRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root)

        let cancelledRead = Task { try await store.statistics() }
        cancelledRead.cancel()
        do {
            _ = try await cancelledRead.value
            XCTFail("A cancelled read should stop before returning results")
        } catch is CancellationError { }

        let statistics = try await store.statistics()
        XCTAssertTrue(statistics.counts.isEmpty)
    }
    func testDurableCommitRetainsUnacknowledgedCursorAcrossReopenAndIsolatesAccounts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root), epoch = await store.epoch()
        let needsReset = try await store.prepare(sessionFingerprint: "session-one")
        XCTAssertTrue(needsReset)
        _ = try await store.apply([asset("photo"), event("SyncCompleteV1", "{}", ack: "SyncCompleteV1|finished")], epoch: epoch)
        try await store.markResetRequested()
        let reopened = try makeStore(root)
        let cached = try await reopened.asset(id: "photo")
        XCTAssertEqual(cached?.cacheRevision, "xmp-7")
        let pending = try await reopened.pendingAcknowledgements()
        XCTAssertEqual(Set(pending), ["AssetV2|photo", "SyncCompleteV1|finished"])
        let sameSession = try await reopened.prepare(sessionFingerprint: "session-one")
        XCTAssertFalse(sameSession)
        try await reopened.acknowledged(["AssetV2|older"])
        let stillPending = try await reopened.pendingAcknowledgements()
        XCTAssertTrue(stillPending.contains("AssetV2|photo"))
        let other = try makeStore(root, scope: "server|bob")
        let otherAsset = try await other.asset(id: "photo")
        XCTAssertNil(otherAsset)
        let changedSession = try await reopened.prepare(sessionFingerprint: "session-two")
        XCTAssertTrue(changedSession)
        let removed = try await reopened.asset(id: "photo")
        XCTAssertNil(removed)
    }
    func testInvalidBatchRollsBackEntitiesAndCheckpointsTogether() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root), epoch = await store.epoch()
        do {
            _ = try await store.apply([asset("photo"), event("UnsupportedV99", "{}")], epoch: epoch)
            XCTFail("Unknown events must not be silently acknowledged")
        } catch is APIError { }
        let removed = try await store.asset(id: "photo"), pending = try await store.pendingAcknowledgements()
        XCTAssertNil(removed); XCTAssertTrue(pending.isEmpty)
        _ = try await store.apply([asset("photo")], epoch: epoch)
        _ = try await store.apply([event("SyncAckV1", "{}", ack: "PartnerAssetBackfillV2|change|complete")], epoch: epoch)
        let backfillAck = try await store.pendingAcknowledgements()
        XCTAssertTrue(backfillAck.contains("PartnerAssetBackfillV2|change|complete"))
    }
    func testResetAndLogoutInvalidateStoredRecordsAndRejectLateWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root), epoch = await store.epoch()
        _ = try await store.apply([asset("photo"), event("SyncCompleteV1", "{}")], epoch: epoch)
        let reset = try await store.apply([event("SyncResetV1", "{}", ack: "SyncResetV1|reset")], epoch: epoch)
        XCTAssertTrue(reset.serverReset)
        let removed = try await store.asset(id: "photo"), complete = try await store.isComplete()
        XCTAssertNil(removed); XCTAssertFalse(complete)
        let pending = try await store.pendingAcknowledgements()
        XCTAssertEqual(pending, ["SyncResetV1|reset"])
        try await store.clear()
        do { _ = try await store.apply([asset("late")], epoch: epoch); XCTFail("Logout must fence late responses") }
        catch is CancellationError { }
    }
    func testRevocationRemovesSharedDataOnlyWhenNoRemainingGrantExists() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root), epoch = await store.epoch()
        _ = try await store.apply([
            asset("mine"), asset("shared", owner: "bob"),
            event("PartnerV1", #"{"sharedById":"bob","sharedWithId":"alice","inTimeline":true}"#),
            event("AlbumV2", #"{"id":"album","name":"Trip","description":"","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","thumbnailAssetId":"shared","isActivityEnabled":true,"order":"desc"}"#),
            event("AlbumUserV1", #"{"albumId":"album","userId":"alice","role":"viewer"}"#),
            event("AlbumToAssetV1", #"{"albumId":"album","assetId":"shared"}"#)
        ], epoch: epoch)
        _ = try await store.apply([event("PartnerDeleteV1", #"{"sharedById":"bob","sharedWithId":"alice"}"#)], epoch: epoch)
        let stillShared = try await store.asset(id: "shared")
        XCTAssertNotNil(stillShared)
        _ = try await store.apply([event("AlbumUserDeleteV1", #"{"albumId":"album","userId":"alice"}"#)], epoch: epoch)
        let revoked = try await store.asset(id: "shared"), owned = try await store.asset(id: "mine")
        XCTAssertNil(revoked); XCTAssertNotNil(owned)
        let albums = try await store.albums()
        XCTAssertTrue(albums.isEmpty)
    }
    func testPartnersReadBothDirectionsScopedToUserAndHonorDeleteAndDirection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root), epoch = await store.epoch()
        func user(_ id: String) throws -> EntitySyncEvent {
            try event("UserV1", #"{"id":"\#(id)","name":"\#(id.capitalized)","email":"\#(id)@example.com","deletedAt":null}"#, ack: "UserV1|\(id)")
        }
        _ = try await store.apply([
            user("alice"), user("bob"), user("carol"), user("dave"),
            event("PartnerV1", #"{"sharedById":"bob","sharedWithId":"alice","inTimeline":true}"#, ack: "P|1"),
            event("PartnerV1", #"{"sharedById":"alice","sharedWithId":"carol","inTimeline":false}"#, ack: "P|2"),
            event("PartnerV1", #"{"sharedById":"dave","sharedWithId":"bob","inTimeline":true}"#, ack: "P|3")
        ], epoch: epoch)
        let with = try await store.partners(direction: "shared-with"), by = try await store.partners(direction: "shared-by")
        XCTAssertEqual(with.map(\.id), ["bob"]); XCTAssertEqual(with.first?.email, "bob@example.com"); XCTAssertEqual(with.first?.inTimeline, true)
        XCTAssertEqual(by.map(\.id), ["carol"]); XCTAssertEqual(by.first?.inTimeline, false)
        do { _ = try await store.partners(direction: "all"); XCTFail("Unknown direction must be rejected") } catch { }
        _ = try await store.apply([event("PartnerDeleteV1", #"{"sharedById":"bob","sharedWithId":"alice"}"#, ack: "P|4")], epoch: epoch)
        let afterDelete = try await store.partners(direction: "shared-with")
        XCTAssertTrue(afterDelete.isEmpty)
    }
    func testSingleAlbumAndPersonReadersMatchListsAndHonorDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root), epoch = await store.epoch()
        func user(_ id: String) throws -> EntitySyncEvent {
            try event("UserV1", #"{"id":"\#(id)","name":"\#(id.capitalized)","email":"\#(id)@example.com","deletedAt":null}"#, ack: "UserV1|\(id)")
        }
        _ = try await store.apply([
            user("alice"), user("bob"), asset("a1"), asset("a2"),
            event("AlbumV2", #"{"id":"album","name":"Trip","description":"","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","thumbnailAssetId":"a1","isActivityEnabled":true,"order":"desc"}"#, ack: "A|1"),
            event("AlbumV2", #"{"id":"other","name":"Other","description":"","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","thumbnailAssetId":null,"isActivityEnabled":true,"order":"desc"}"#, ack: "A|2"),
            event("AlbumUserV1", #"{"albumId":"album","userId":"alice","role":"owner"}"#, ack: "AU|1"),
            event("AlbumUserV1", #"{"albumId":"album","userId":"bob","role":"editor"}"#, ack: "AU|2"),
            event("AlbumToAssetV1", #"{"albumId":"album","assetId":"a1"}"#, ack: "AA|1"),
            event("AlbumToAssetV1", #"{"albumId":"album","assetId":"a2"}"#, ack: "AA|2"),
            event("PersonV1", #"{"id":"person","name":"Pat","isHidden":true}"#, ack: "P|1")
        ], epoch: epoch)
        let list = try await store.albums(), detail = try await store.album(id: "album")
        XCTAssertEqual(detail?.id, "album")
        XCTAssertEqual(detail?.assetCount, 2)
        XCTAssertEqual(detail?.shared, true)
        XCTAssertEqual(detail?.albumName, list.first { $0.id == "album" }?.albumName)
        XCTAssertEqual(detail?.albumUsers?.map { "\($0.user.id):\($0.role)" }.sorted(), ["alice:owner", "bob:editor"])
        let person = try await store.person(id: "person"), missingPerson = try await store.person(id: "nobody"), missingAlbum = try await store.album(id: "nobody")
        XCTAssertEqual(person?.name, "Pat"); XCTAssertEqual(person?.isHidden, true)
        XCTAssertNil(missingPerson); XCTAssertNil(missingAlbum)
        _ = try await store.apply([
            event("AlbumDeleteV1", #"{"albumId":"album"}"#, ack: "AD|1"),
            event("PersonDeleteV1", #"{"personId":"person"}"#, ack: "PD|1")
        ], epoch: epoch)
        let deletedAlbum = try await store.album(id: "album"), deletedPerson = try await store.person(id: "person")
        XCTAssertNil(deletedAlbum); XCTAssertNil(deletedPerson)
    }
    func testPersonTimelineMembershipDeduplicatesFacesAndHonorsVisibilityAndAlbumShares() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root), epoch = await store.epoch()
        func face(_ id: String, assetID: String, visible: Bool? = true, deleted: Bool = false) throws -> EntitySyncEvent {
            let visibility = visible.map { ",\"isVisible\":\($0)" } ?? ""
            let deletion = deleted ? ",\"deletedAt\":\"2026-03-04T00:00:00Z\"" : ""
            return try event("AssetFaceV3", "{\"id\":\"\(id)\",\"assetId\":\"\(assetID)\",\"personId\":\"person\"\(visibility)\(deletion)}", ack: "Face|\(id)")
        }
        _ = try await store.apply([
            asset("own-visible"), asset("own-invisible"), asset("own-deleted-face"), asset("own-missing-visibility"),
            asset("shared-visible", owner: "bob"), asset("unshared-bob", owner: "bob"),
            asset("locked", visibility: "locked"), asset("trashed", deleted: true),
            event("AlbumV2", #"{"id":"shared-album","name":"Shared","description":"","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","thumbnailAssetId":"shared-visible","isActivityEnabled":true,"order":"desc"}"#, ack: "Album|shared"),
            event("AlbumUserV1", #"{"albumId":"shared-album","userId":"alice","role":"viewer"}"#, ack: "AlbumUser|shared"),
            event("AlbumToAssetV1", #"{"albumId":"shared-album","assetId":"shared-visible"}"#, ack: "AlbumAsset|shared"),
            face("own-face-1", assetID: "own-visible"), face("own-face-2", assetID: "own-visible"),
            face("invisible-face", assetID: "own-invisible", visible: false),
            face("deleted-face", assetID: "own-deleted-face", deleted: true),
            face("missing-visible-flag", assetID: "own-missing-visibility", visible: nil),
            face("shared-face", assetID: "shared-visible"),
            face("unshared-face", assetID: "unshared-bob"),
            face("locked-face", assetID: "locked"), face("trash-face", assetID: "trashed")
        ], epoch: epoch)

        var personFilter = TimelineFilter()
        personFilter.personID = "person"
        let peoplePhotos = try await store.timelineAssets(filter: personFilter)
        XCTAssertEqual(Set(peoplePhotos.map(\.id)), ["own-visible", "shared-visible"])
        XCTAssertEqual(peoplePhotos.count, 2, "Multiple visible faces must not duplicate an asset")
        let peopleBuckets = try await store.timeBuckets(filter: personFilter)
        XCTAssertEqual(peopleBuckets.map(\.count).reduce(0, +), 2)

        var albumFilter = TimelineFilter()
        albumFilter.albumID = "shared-album"
        let albumPhotos = try await store.timelineAssets(filter: albumFilter)
        XCTAssertEqual(albumPhotos.map(\.id), ["shared-visible"])
        let albumBuckets = try await store.timeBuckets(filter: albumFilter)
        XCTAssertEqual(albumBuckets.map(\.count).reduce(0, +), 1)
    }
    func testLockedTransitionPurgesMetadataAndCannotBeRepopulatedByLaterExif() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root), epoch = await store.epoch()
        _ = try await store.apply([asset("photo"), event("AssetExifV1", #"{"assetId":"photo","description":"private caption"}"#)], epoch: epoch)
        _ = try await store.apply([asset("photo", visibility: "locked"), event("AssetExifV1", #"{"assetId":"photo","description":"late private caption"}"#)], epoch: epoch)
        let locked = try await store.asset(id: "photo"), exif = try await store.entityData(kind: "exif", id: "photo")
        XCTAssertNil(locked); XCTAssertNil(exif)
        let resetPending = try await store.takeAccessInvalidation(), purges = try await store.pendingMediaPurges()
        XCTAssertFalse(resetPending, "Locking one photo forgets only that photo's media.")
        XCTAssertEqual(purges, [MediaPurge(assetID: "photo", revoked: true)])
    }
    /// Every removed photo waits in the index until its media is forgotten, past the summary's
    /// 2,000 IDs, and photos that left the account are marked revoked.
    func testRemovedPhotosWaitInTheIndexUntilTheirMediaIsForgotten() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root), epoch = await store.epoch()
        let ids = (0..<2_100).map { "deleted-\($0)" }
        _ = try await store.apply(try ids.map { try asset($0) } + [
            asset("bob-shared", owner: "bob"),
            event("AlbumV2", #"{"id":"shared","ownerId":"bob","name":"Shared","description":"","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","thumbnailAssetId":null,"isActivityEnabled":true,"order":"desc"}"#),
            event("AlbumUserV1", #"{"albumId":"shared","userId":"alice","role":"viewer"}"#),
            event("AlbumToAssetV1", #"{"albumId":"shared","assetId":"bob-shared"}"#),
        ], epoch: epoch)
        let deletion = try await store.apply(try ids.map { try event("AssetDeleteV1", "{\"assetId\":\"\($0)\"}") }, epoch: epoch)
        let unshared = try await store.apply([event("AlbumUserDeleteV1", #"{"albumId":"shared","userId":"alice"}"#)], epoch: epoch)
        let queued = try await store.pendingMediaPurges(limit: 5_000)
        XCTAssertTrue(deletion.accessLost.isEmpty, "Deletions change nothing the account may see.")
        XCTAssertEqual(deletion.removed.count, 2_100, "Every deletion is named: a change has no cap below 50,000.")
        XCTAssertEqual(unshared.accessLost, ["bob-shared"], "Bob's photo left the account.")
        XCTAssertEqual(queued.count, 2_101, "Every removed photo is queued, past the summary's 2,000 IDs.")
        XCTAssertEqual(queued.filter(\.revoked).map(\.assetID), ["bob-shared"])

        try await store.finishMediaPurges(Array(queued.prefix(2_000)))
        let left = try await store.pendingMediaPurges(limit: 5_000)
        let resetPending = try await store.takeAccessInvalidation()
        XCTAssertEqual(left.count, 101, "Forgotten photos leave the queue.")
        XCTAssertFalse(resetPending, "Neither removal empties every cache.")
    }
    func testOfflineTimelineUsesLocalMonthsFavoritesStacksAndBothCloudDateFormats() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root), epoch = await store.epoch()
        _ = try await store.apply([
            asset("primary", favorite: true, stack: "stack"), asset("secondary", stack: "stack"), asset("trash", deleted: true), asset("hidden", visibility: "hidden"),
            event("StackV1", #"{"id":"stack","ownerId":"alice","primaryAssetId":"primary","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}"#),
            event("AssetMetadataV1", #"{"assetId":"primary","key":"mobile-app","value":{"iCloudId":"cloud-photo","createdAt":"2026-01-31T23:30:00Z","adjustmentTime":1700000000,"latitude":"38.7","longitude":-9.1}}"#)
        ], epoch: epoch)
        let buckets = try await store.timeBuckets()
        XCTAssertEqual(buckets.map(\.timeBucket), ["2026-02-01"])
        XCTAssertEqual(buckets.first?.count, 1)
        var filter = TimelineFilter(); filter.isFavorite = true
        let favorites = try await store.timeBucket("2026-02-01", filter: filter)
        XCTAssertEqual(favorites.map(\.id), ["primary"])
        filter.withStacked = false; filter.isFavorite = nil
        let all = try await store.timelineAssets(filter: filter)
        XCTAssertEqual(Set(all.map(\.id)), ["primary", "secondary"])
        filter.visibility = nil
        let defaultVisibility = try await store.timelineAssets(filter: filter)
        XCTAssertFalse(defaultVisibility.contains { $0.id == "hidden" })
        let matches = try await store.localAssetMatches()
        XCTAssertEqual(Set(matches.map(\.assetID)), ["primary", "secondary", "trash", "hidden"])
        let paired = try XCTUnwrap(matches.first { $0.assetID == "primary" })
        XCTAssertEqual(paired.cloudID, "cloud-photo")
        XCTAssertEqual(paired.createdAt, APIDate.parse("2026-01-31T23:30:00Z"))
        XCTAssertEqual(paired.adjustmentTime, Date(timeIntervalSince1970: 1700000000))
        XCTAssertEqual(paired.latitude, 38.7)
    }
    func testLightroomIsLaidOutByMonthFromTheDevelopedPhotos() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root), epoch = await store.epoch()
        _ = try await store.apply([asset("developed-1"), asset("developed-2"), asset("phone", developed: false)], epoch: epoch)
        let lightroom = TimelineFilter(isDeveloped: true)
        let buckets = try await store.timeBuckets(filter: lightroom)
        XCTAssertEqual(buckets.first?.count, 2, "Only the developed photos.")
        let month = try await store.timeBucket("2026-02-01", filter: lightroom)
        XCTAssertEqual(Set(month.map(\.id)), ["developed-1", "developed-2"])
    }
    func testAPlaceIsLaidOutByMonthFromItsOwnPhotos() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root), epoch = await store.epoch()
        _ = try await store.apply([asset("lisbon-1"), asset("lisbon-2"), asset("porto"), asset("partner", owner: "bob"),
                                   asset("gone", deleted: true)], epoch: epoch)
        let place = TimelineFilter(place: TimelinePlace(id: "Lisbon", assetIDs: ["lisbon-1", "lisbon-2", "partner", "gone", "unknown"]))
        let buckets = try await store.timeBuckets(filter: place)
        XCTAssertEqual(buckets.map(\.timeBucket), ["2026-02-01"])
        XCTAssertEqual(buckets.first?.count, 3, "The place's photos from its map, a partner's included, without deleted or unknown ones.")
        let month = try await store.timeBucket("2026-02-01", filter: place)
        XCTAssertEqual(Set(month.map(\.id)), ["lisbon-1", "lisbon-2", "partner"])
        let library = try await store.timeBuckets()
        XCTAssertEqual(library.first?.count, 3, "The library itself is unchanged: its own three photos.")
    }
    func testOfflineMemoriesUseServerDateWindowAndExcludeUnavailableOrHiddenPeopleAssets() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root), epoch = await store.epoch()
        func memory(_ id: String, show: String?, hide: String?, owner: String = "alice", deleted: Bool = false) throws -> EntitySyncEvent {
            let object: [String: EntityJSON] = ["id": .string(id), "ownerId": .string(owner), "type": .string("OnThisDay"), "memoryAt": .string("2024-10-18T00:00:00Z"), "data": .object(["year": .integer(2024)]), "isSaved": .bool(false), "showAt": show.map(EntityJSON.string) ?? .null, "hideAt": hide.map(EntityJSON.string) ?? .null, "seenAt": .string("2026-10-18T09:00:00Z"), "deletedAt": deleted ? .string("2026-10-18T00:00:00Z") : .null]
            return EntitySyncEvent(type: "MemoryV2", data: object, ack: "MemoryV2|" + id)
        }
        _ = try await store.apply([
            asset("visible"), asset("hidden-person"), asset("archived", visibility: "archive"), asset("trash", deleted: true), asset("locked", visibility: "locked"),
            memory("today", show: "2026-10-18T00:00:00Z", hide: "2026-10-18T00:00:00Z"),
            memory("anytime", show: nil, hide: nil),
            memory("future", show: "2026-10-19T00:00:00Z", hide: nil),
            memory("expired", show: nil, hide: "2026-10-17T23:59:59Z"),
            memory("other", show: nil, hide: nil, owner: "bob"),
            memory("deleted", show: nil, hide: nil, deleted: true),
            event("PersonV1", #"{"id":"person","isHidden":true}"#),
            event("AssetFaceV3", #"{"id":"face","assetId":"hidden-person","personId":"person"}"#)
        ], epoch: epoch)
        for id in ["visible", "hidden-person", "archived", "trash", "locked"] {
            _ = try await store.apply([event("MemoryToAssetV2", "{\"memoryId\":\"today\",\"assetId\":\"\(id)\"}")], epoch: epoch)
        }
        _ = try await store.apply([event("MemoryToAssetV2", #"{"memoryId":"anytime","assetId":"visible"}"#)], epoch: epoch)
        let memories = try await store.memories(onCivilDate: "2026-10-18")
        XCTAssertEqual(memories.map(\.id), ["today", "anytime"])
        XCTAssertEqual(memories.first?.assets.map(\.id), ["visible"])
        XCTAssertEqual(memories.first?.seenAt, APIDate.parse("2026-10-18T09:00:00Z"))
        _ = try await store.apply([event("UserMetadataV1", #"{"userId":"alice","key":"preferences","value":{"memories":{"enabled":false}}}"#)], epoch: epoch)
        let disabled = try await store.memories(onCivilDate: "2026-10-18")
        XCTAssertTrue(disabled.isEmpty)
    }

    func testSocketProtocolHandlesHeartbeatEditsAndSessionErrorsWithoutCredentialsInMessages() throws {
        if case .ping(let payload) = try SocketEventPacket.parse("2probe") { XCTAssertEqual(payload, "probe") }
        else { XCTFail("Engine.IO ping requires pong") }
        if case .invalidation(let update) = try SocketEventPacket.parse(#"42["AssetEditReadyV2",{"asset":{"id":"photo","mediaRevision":"new"},"edit":[]}]"#) { XCTAssertEqual(update.assetIDs, ["photo"]) }
        else { XCTFail("Published edit must invalidate media") }
        XCTAssertThrowsError(try SocketEventPacket.parse(#"42["error","unauthorized"]"#))
        XCTAssertTrue(ReadOnlyPolicy.permits(method: "POST", path: "sync/ack"))
        XCTAssertTrue(ReadOnlyPolicy.permits(method: "POST", path: "sync/stream"))
        XCTAssertFalse(ReadOnlyPolicy.permits(method: "POST", path: "assets"))
    }
}

private final class SyncHTTPFixture: @unchecked Sendable {
    struct Response: Sendable { let status: Int; let body: Data }
    private let lock = NSLock()
    private var replies: [String: [Response]] = [:]
    private var requests: [URLRequest] = []
    func reset() { lock.lock(); defer { lock.unlock() }; replies.removeAll(); requests.removeAll() }
    func set(_ path: String, _ values: [Response]) { lock.lock(); defer { lock.unlock() }; replies[path] = values }
    func reply(_ request: URLRequest) -> Response {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        let path = request.url?.path ?? ""
        guard var values = replies[path], !values.isEmpty else { return .init(status: 500, body: Data()) }
        let value = values.removeFirst(); replies[path] = values; return value
    }
    func bodies(_ path: String) -> [Data] {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.url?.path == path }.compactMap { request in
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return nil }
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096), data = Data()
            while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count)) }
            return data
        }
    }
}
private final class SyncTestURLProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = SyncHTTPFixture()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "sync-test.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let value = Self.fixture.reply(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: value.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/jsonlines+json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: value.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

extension EntitySyncTests {
    func testMetadataResetRequestsServerReplayAndRebuildsLocalEntities() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyncTestURLProtocol.self]
        let api = try APIClient(baseURL: URL(string: "https://sync-test.invalid")!, accessToken: "test-session", userID: "alice",
                                sessionConfiguration: configuration, networkConfiguration: .init())
        defer { Task { await api.shutdown() } }
        let store = try EntityStore(scope: api.cacheScope, userID: "alice", directory: root)
        let fingerprint = try await api.syncSessionFingerprint()
        let needsReset = try await store.prepare(sessionFingerprint: fingerprint)
        XCTAssertTrue(needsReset)
        let epoch = await store.epoch()
        _ = try await store.apply([asset("old"), event("SyncCompleteV1", "{}", ack: "SyncCompleteV1|old")], epoch: epoch)
        try await store.markResetRequested()
        try await store.clear()

        let replay = try JSONEncoder().encode(asset("fresh")) + Data("\n".utf8)
            + JSONEncoder().encode(event("SyncCompleteV1", "{}", ack: "SyncCompleteV1|fresh")) + Data("\n".utf8)
        SyncTestURLProtocol.fixture.reset()
        SyncTestURLProtocol.fixture.set("/api/sync/stream", [.init(status: 200, body: replay)])
        SyncTestURLProtocol.fixture.set("/api/sync/ack", [.init(status: 204, body: Data())])
        let sync = NativeSync(api: api, store: store)
        _ = try await sync.pass()

        let requests = try SyncTestURLProtocol.fixture.bodies("/api/sync/stream").map { try JSONDecoder().decode([String: EntityJSON].self, from: $0) }
        XCTAssertEqual(requests.map { $0["reset"] }, [.bool(true)])
        let old = try await store.asset(id: "old"), fresh = try await store.asset(id: "fresh")
        XCTAssertNil(old)
        XCTAssertNotNil(fresh)
        let complete = try await store.isComplete()
        XCTAssertTrue(complete)
    }

    func testInterruptedInitialStreamResumesWithoutAnotherServerReset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SyncTestURLProtocol.self]
        let api = try APIClient(baseURL: URL(string: "https://sync-test.invalid")!, accessToken: "test-session", userID: "alice",
                                sessionConfiguration: configuration, networkConfiguration: .init())
        defer { Task { await api.shutdown() } }
        let store = try EntityStore(scope: api.cacheScope, userID: "alice", directory: root)
        let sync = NativeSync(api: api, store: store)
        let partial = try JSONEncoder().encode(asset("photo")) + Data("\n".utf8)
        let complete = try JSONEncoder().encode(event("SyncCompleteV1", "{}", ack: "SyncCompleteV1|finished")) + Data("\n".utf8)
        SyncTestURLProtocol.fixture.reset()
        SyncTestURLProtocol.fixture.set("/api/sync/stream", [.init(status: 200, body: partial), .init(status: 200, body: complete)])
        SyncTestURLProtocol.fixture.set("/api/sync/ack", [.init(status: 204, body: Data()), .init(status: 204, body: Data())])
        do { _ = try await sync.pass(); XCTFail("A missing complete marker must fail") }
        catch is APIError { }
        let firstSaved = try await store.asset(id: "photo"), initiallyComplete = try await store.isComplete()
        XCTAssertNotNil(firstSaved); XCTAssertFalse(initiallyComplete)
        let resumed = try await sync.pass()
        XCTAssertTrue(resumed.completed)
        let requests = try SyncTestURLProtocol.fixture.bodies("/api/sync/stream").map { try JSONDecoder().decode([String: EntityJSON].self, from: $0) }
        XCTAssertEqual(requests.map { $0["reset"] }, [.bool(true), .bool(false)])
        let pending = try await store.pendingAcknowledgements()
        XCTAssertTrue(pending.isEmpty)
    }
}

extension EntitySyncTests {
    func testOfflineMapMarkersMatchMapScopeFiltersAndCoordinateProjection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root), epoch = await store.epoch()
        func located(_ id: String, owner: String = "alice", visibility: String = "timeline", favorite: Bool = true, deleted: Bool = false) throws -> [EntitySyncEvent] {
            [try asset(id, owner: owner, visibility: visibility, deleted: deleted, favorite: favorite),
             try event("AssetExifV1", #"{"assetId":"\#(id)","latitude":38.7,"longitude":-9.1,"city":"Lisbon","state":"Lisbon","country":"Portugal"}"#)]
        }
        var events = try located("owned")
        events += try located("not-favorite", favorite: false)
        events += try located("archived", visibility: "archive")
        events += try located("hidden", visibility: "hidden")
        events += try located("locked", visibility: "locked")
        events += try located("deleted", favorite: false, deleted: true)
        events += try located("partner-photo", owner: "bob")
        events += try located("partner-archive", owner: "bob", visibility: "archive")
        events += try located("album-photo", owner: "carol")
        events += [
            try event("UserV1", #"{"id":"bob","name":"Bob","email":"bob@example.com","deletedAt":null}"#),
            try event("PartnerV1", #"{"sharedById":"bob","sharedWithId":"alice","inTimeline":false}"#),
            try event("AlbumV2", #"{"id":"shared-album","name":"Shared","deletedAt":null}"#),
            try event("AlbumUserV1", #"{"albumId":"shared-album","userId":"alice","role":"viewer"}"#),
            try event("AlbumToAssetV1", #"{"albumId":"shared-album","assetId":"album-photo"}"#)
        ]
        _ = try await store.apply(events, epoch: epoch)

        let standard = try await store.mapMarkers(.init(withPartners: true, withSharedAlbums: true, isArchived: false))
        XCTAssertEqual(Set(standard.map(\.id)), ["owned", "not-favorite", "partner-photo", "album-photo"])
        let ownOnly = try await store.mapMarkers(.init(isArchived: false))
        XCTAssertEqual(Set(ownOnly.map(\.id)), ["owned", "not-favorite"])
        let favorites = try await store.mapMarkers(.init(withPartners: true, withSharedAlbums: true, isArchived: false, isFavorite: true))
        XCTAssertEqual(Set(favorites.map(\.id)), ["owned", "partner-photo", "album-photo"])
        let withArchive = try await store.mapMarkers(.init(withPartners: true, withSharedAlbums: true, isArchived: true))
        XCTAssertEqual(Set(withArchive.map(\.id)), ["owned", "not-favorite", "archived", "partner-photo", "album-photo"])
        let after = try await store.mapMarkers(.init(withPartners: true, withSharedAlbums: true, isArchived: true,
                                                    fileCreatedAfter: APIDate.parse("2026-02-01T00:00:00Z")))
        XCTAssertTrue(after.isEmpty)
        XCTAssertEqual(standard.first?.city, "Lisbon")
    }

    func testCachedServerFeaturesPersistThroughSyncResetAndClearWithStore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try makeStore(root)
        _ = try await store.prepare(sessionFingerprint: "session-one")
        let features = ServerFeatures(passwordLogin: true, oauth: false, smartSearch: true, searchVerification: nil,
                                      ocr: false, facialRecognition: true, map: true, trash: true, sidecar: false,
                                      realtimeTranscoding: true)
        try await store.persistCachedServerFeatures(features)
        let epoch = await store.epoch()
        _ = try await store.apply([event("SyncCompleteV1", "{}")], epoch: epoch)
        _ = try await store.apply([event("SyncResetV1", "{}", ack: "SyncResetV1|reset")], epoch: epoch)
        let cached = try await store.cachedServerFeatures()
        let complete = try await store.isComplete()
        XCTAssertEqual(cached?.map, true)
        XCTAssertEqual(cached?.smartSearch, true)
        XCTAssertFalse(complete)
        try await store.clear()
        let cleared = try await store.cachedServerFeatures()
        XCTAssertNil(cleared)
    }
}
