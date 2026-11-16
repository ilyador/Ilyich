import XCTest
import IlyichPlatform
@testable import Ilyich

final class BackupStackPlanTests: XCTestCase {
    private func asset(_ id: String, stack: AssetStack? = nil, owner: String = "owner", trashed: Bool = false) -> BackupRemoteAsset {
        BackupRemoteAsset(id: id, ownerId: owner, checksum: "sum", isTrashed: trashed, livePhotoVideoId: nil, stack: stack)
    }

    func testNewStackKeepsEditOnTop() throws {
        XCTAssertEqual(try BackupStackPlan.assetIDs(for: [asset("edit"), asset("base")], existing: nil, ownerID: "owner"), ["edit", "base"])
    }

    func testExistingMembersAndChosenCoverArePreserved() throws {
        let summary = AssetStack(id: "group", primaryAssetId: "cover", assetCount: 3)
        let existing = BackupStackSnapshot(id: "group", primaryAssetId: "cover", assets: [asset("base"), asset("cover"), asset("other")])
        let ids = try BackupStackPlan.assetIDs(for: [asset("edit"), asset("base", stack: summary)], existing: existing, ownerID: "owner")
        XCTAssertEqual(ids?.first, "cover")
        XCTAssertEqual(Set(ids ?? []), ["cover", "base", "other", "edit"])
    }

    func testRepeatedLinkDoesNotWriteAgain() throws {
        let summary = AssetStack(id: "group", primaryAssetId: "edit", assetCount: 2)
        let assets = [asset("edit", stack: summary), asset("base", stack: summary)]
        XCTAssertNil(try BackupStackPlan.assetIDs(for: assets,
            existing: BackupStackSnapshot(id: "group", primaryAssetId: "edit", assets: assets), ownerID: "owner"))
    }

    func testIndependentUserGroupsAreNotMerged() {
        let edit = asset("edit", stack: AssetStack(id: "one", primaryAssetId: "edit", assetCount: 2))
        let base = asset("base", stack: AssetStack(id: "two", primaryAssetId: "base", assetCount: 2))
        XCTAssertThrowsError(try BackupStackPlan.assetIDs(for: [edit, base], existing: nil, ownerID: "owner"))
    }

    func testChangedGroupMembershipCannotMoveAPhoto() {
        let base = asset("base", stack: AssetStack(id: "group", primaryAssetId: "cover", assetCount: 2))
        let changed = BackupStackSnapshot(id: "group", primaryAssetId: "cover", assets: [asset("cover"), asset("other")])
        XCTAssertThrowsError(try BackupStackPlan.assetIDs(for: [asset("edit"), base], existing: changed, ownerID: "owner"))
    }

    func testTrashedAndOtherOwnersCopiesCannotBeGrouped() {
        XCTAssertThrowsError(try BackupStackPlan.assetIDs(for: [asset("edit"), asset("base", trashed: true)], existing: nil, ownerID: "owner"))
        XCTAssertThrowsError(try BackupStackPlan.assetIDs(for: [asset("edit"), asset("base", owner: "other")], existing: nil, ownerID: "owner"))
    }

    func testAPIKeepsChecksumProofAcrossItsStackRead() async throws {
        let server = makeStubServer()
        let edit = #"{"id":"edit","ownerId":"owner","checksum":"edit-sum","checksumAlgorithm":"sha1","isTrashed":false}"#
        let base = #"{"id":"base","ownerId":"owner","checksum":"base-sum","checksumAlgorithm":"sha1","isTrashed":false,"stack":{"id":"group","primaryAssetId":"base","assetCount":1}}"#
        server.route("GET", "assets/edit", .json(edit))
        server.route("GET", "assets/base", .json(base), .json(base.replacingOccurrences(of: "base-sum", with: "changed")))
        server.route("GET", "stacks/group", .json("{\"id\":\"group\",\"primaryAssetId\":\"base\",\"assets\":[" + base + "]}"))
        let api = try APIClient(baseURL: server.baseURL, accessToken: "token", userID: "owner",
                                sessionConfiguration: server.configuration(), networkConfiguration: NetworkConfiguration(), wifiName: NoWiFi())
        addTeardownBlock { await api.shutdown() }
        do {
            try await APITransferServer(client: api).createStack(["edit", "base"], expectedChecksums: ["edit": "edit-sum", "base": "base-sum"])
            XCTFail("Changed source bytes must prevent the grouping write.")
        } catch { XCTAssertTrue(server.requests("POST", "stacks").isEmpty) }
        XCTAssertEqual(server.requests("GET", "assets/base").count, 2)
        XCTAssertEqual(server.requests("GET", "stacks/group").count, 1)
    }

    func testAPIRejectsObservedStackChangeBeforePosting() async throws {
        let server = makeStubServer()
        let edit = #"{"id":"edit","ownerId":"owner","checksum":"edit-sum","checksumAlgorithm":"sha1","isTrashed":false}"#
        let movedEdit = #"{"id":"edit","ownerId":"owner","checksum":"edit-sum","checksumAlgorithm":"sha1","isTrashed":false,"stack":{"id":"another-group","primaryAssetId":"edit","assetCount":2}}"#
        let base = #"{"id":"base","ownerId":"owner","checksum":"base-sum","checksumAlgorithm":"sha1","isTrashed":false,"stack":{"id":"group","primaryAssetId":"base","assetCount":2}}"#
        let cover = #"{"id":"cover","ownerId":"owner","checksum":"cover-sum","checksumAlgorithm":"sha1","isTrashed":false}"#
        server.route("GET", "assets/edit", .json(edit), .json(movedEdit))
        server.route("GET", "assets/base", .json(base))
        server.route("GET", "stacks/group", .json("{\"id\":\"group\",\"primaryAssetId\":\"base\",\"assets\":[" + base + "," + cover + "]}"))
        let api = try APIClient(baseURL: server.baseURL, accessToken: "token", userID: "owner",
                                sessionConfiguration: server.configuration(), networkConfiguration: NetworkConfiguration(), wifiName: NoWiFi())
        addTeardownBlock { await api.shutdown() }
        do {
            try await APITransferServer(client: api).createStack(["edit", "base"], expectedChecksums: ["edit": "edit-sum", "base": "base-sum"])
            XCTFail("Unchanged file bytes cannot authorize moving a photo out of its newly chosen group.")
        } catch {
            guard case ServerFailure.http(400, _) = error else { return XCTFail("Expected the observed group change to be rejected: \(error)") }
        }
        XCTAssertEqual(server.requests("GET", "assets/edit").count, 2)
        XCTAssertTrue(server.requests("POST", "stacks").isEmpty)
    }

    func testAPIRejectsObservedExistingCoverOrMemberChangesBeforePosting() async throws {
        for changedCover in [true, false] {
            let server = makeStubServer()
            let edit = #"{"id":"edit","ownerId":"owner","checksum":"edit-sum","checksumAlgorithm":"sha1","isTrashed":false}"#
            let base = #"{"id":"base","ownerId":"owner","checksum":"base-sum","checksumAlgorithm":"sha1","isTrashed":false,"stack":{"id":"group","primaryAssetId":"base","assetCount":2}}"#
            let cover = #"{"id":"cover","ownerId":"owner","checksum":"cover-sum","checksumAlgorithm":"sha1","isTrashed":false}"#
            let extra = #"{"id":"extra","ownerId":"owner","checksum":"extra-sum","checksumAlgorithm":"sha1","isTrashed":false}"#
            let initial = "{\"id\":\"group\",\"primaryAssetId\":\"base\",\"assets\":[" + base + "," + cover + "]}"
            let changed = changedCover
                ? "{\"id\":\"group\",\"primaryAssetId\":\"cover\",\"assets\":[" + base + "," + cover + "]}"
                : "{\"id\":\"group\",\"primaryAssetId\":\"base\",\"assets\":[" + base + "," + cover + "," + extra + "]}"
            server.route("GET", "assets/edit", .json(edit))
            server.route("GET", "assets/base", .json(base))
            server.route("GET", "stacks/group", .json(initial), .json(changed))
            let api = try APIClient(baseURL: server.baseURL, accessToken: "token", userID: "owner",
                                    sessionConfiguration: server.configuration(), networkConfiguration: NetworkConfiguration(), wifiName: NoWiFi())
            addTeardownBlock { await api.shutdown() }
            do {
                try await APITransferServer(client: api).createStack(["edit", "base"], expectedChecksums: ["edit": "edit-sum", "base": "base-sum"])
                XCTFail("A changed cover or member set must invalidate the saved grouping plan.")
            } catch {
                guard case ServerFailure.http(400, _) = error else { return XCTFail("Expected the observed group change to be rejected: \(error)") }
            }
            XCTAssertEqual(server.requests("GET", "stacks/group").count, 2)
            XCTAssertTrue(server.requests("POST", "stacks").isEmpty)
        }
    }

    func testAPIRevalidatesHistoryTasksAndPreservesUnchangedGroupsDespiteMemberOrder() async throws {
        let server = makeStubServer()
        let edit = #"{"id":"edit","ownerId":"owner","checksum":"edit-sum","checksumAlgorithm":"sha1","isTrashed":false}"#
        let base = #"{"id":"base","ownerId":"owner","checksum":"base-sum","checksumAlgorithm":"sha1","isTrashed":false,"stack":{"id":"group","primaryAssetId":"cover","assetCount":2}}"#
        let cover = #"{"id":"cover","ownerId":"owner","checksum":"cover-sum","checksumAlgorithm":"sha1","isTrashed":false}"#
        server.route("GET", "assets/edit", .json(edit))
        server.route("GET", "assets/base", .json(base))
        server.route("GET", "stacks/group",
            .json("{\"id\":\"group\",\"primaryAssetId\":\"cover\",\"assets\":[" + base + "," + cover + "]}"),
            .json("{\"id\":\"group\",\"primaryAssetId\":\"cover\",\"assets\":[" + cover + "," + base + "]}"))
        server.route("POST", "stacks", .json(#"{"id":"group","primaryAssetId":"cover","assets":[]}"#))
        let api = try APIClient(baseURL: server.baseURL, accessToken: "token", userID: "owner",
                                sessionConfiguration: server.configuration(), networkConfiguration: NetworkConfiguration(), wifiName: NoWiFi())
        addTeardownBlock { await api.shutdown() }
        try await APITransferServer(client: api).createStack(["edit", "base"])
        XCTAssertEqual(server.requests("GET", "assets/edit").count, 2)
        XCTAssertEqual(server.requests("GET", "assets/base").count, 2)
        XCTAssertEqual(server.requests("GET", "stacks/group").count, 2)
        let requests = server.requests("POST", "stacks")
        XCTAssertEqual(requests.count, 1)
        let body = try XCTUnwrap(requests.first?.body)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: [String]])
        XCTAssertEqual(payload["assetIds"]?.first, "cover")
        XCTAssertEqual(Set(payload["assetIds"] ?? []), ["cover", "base", "edit"])
    }
}
