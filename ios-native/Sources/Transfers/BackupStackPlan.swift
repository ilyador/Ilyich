import Foundation

/// A stack is a presentation choice, not evidence that either file is backed up.
struct BackupStackSnapshot: Decodable, Sendable {
    let id: String
    let primaryAssetId: String
    let assets: [BackupRemoteAsset]
}

enum BackupStackPlan {
    /// Nil means the relationship already exists. Never split or merge independent user stacks.
    static func assetIDs(for assets: [BackupRemoteAsset], existing: BackupStackSnapshot?, ownerID: String) throws -> [String]? {
        guard assets.allSatisfy({ eligible($0, ownerID: ownerID) }) else {
            throw ServerFailure.http(400, "Only available photos owned by this account can be linked.")
        }
        let ids = assets.map(\.id).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        guard ids.count > 1 else { return nil }
        let stackIDs = Set(assets.compactMap { $0.stack?.id })
        guard stackIDs.count <= 1 else {
            throw ServerFailure.http(400, "These photos already belong to different stacks. Their groups were preserved.")
        }
        guard let stackID = stackIDs.first else { return ids }
        guard let existing, existing.id == stackID,
              existing.assets.allSatisfy({ eligible($0, ownerID: ownerID) }),
              existing.assets.contains(where: { $0.id == existing.primaryAssetId }) else {
            throw APIError.invalidResponse("The existing photo group could not be verified.")
        }
        let members = Set(existing.assets.map(\.id))
        guard assets.filter({ $0.stack != nil }).allSatisfy({ members.contains($0.id) }) else {
            throw APIError.invalidResponse("The photo group changed while it was being checked. Try again.")
        }
        if Set(ids).isSubset(of: members) { return nil }
        // Including the primary tells Immich to retain every member of that stack. Keep the
        // user's cover selection as well; only a completely new stack puts the new edit first.
        return ([existing.primaryAssetId] + existing.assets.map(\.id) + ids)
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    private static func eligible(_ asset: BackupRemoteAsset, ownerID: String) -> Bool {
        asset.ownerId == ownerID && !asset.isTrashed && asset.isOffline != true
            && asset.visibility != "locked" && asset.visibility != "hidden"
    }
}
