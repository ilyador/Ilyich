import Foundation

/// JSON is retained losslessly so adding a server field does not require a database migration.
indirect enum EntityJSON: Codable, Sendable, Equatable {
    case object([String: EntityJSON]), array([EntityJSON]), string(String), integer(Int64), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: EntityJSON].self) { self = .object(v) }
        else { self = .array(try c.decode([EntityJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    var string: String? { if case .string(let v) = self { return v }; return nil }
    var object: [String: EntityJSON]? { if case .object(let v) = self { return v }; return nil }
}

struct EntitySyncEvent: Codable, Sendable {
    let type: String
    var data: [String: EntityJSON]
    let ack: String
    var ackType: String { String(ack.prefix(while: { $0 != "|" })) }
}
struct SyncAcknowledgement: Decodable, Sendable { let type: String; let ack: String }
struct SyncChangeSummary: Sendable {
    var changed = false
    var reset = false
    var completed = false
    var assetIDs: Set<String> = []
    var deletedAssetIDs: Set<String> = []
    var collectionsChanged = false
    var accessChanged = false
    var configurationChanged = false
    mutating func merge(_ other: Self) {
        changed = changed || other.changed; reset = reset || other.reset
        completed = completed || other.completed; collectionsChanged = collectionsChanged || other.collectionsChanged
        accessChanged = accessChanged || other.accessChanged; configurationChanged = configurationChanged || other.configurationChanged
        // Callers use IDs for invalidation, not as a second copy of the whole library.
        if assetIDs.count < 2_000 { assetIDs.formUnion(other.assetIDs.prefix(2_000 - assetIDs.count)) }
        if deletedAssetIDs.count < 2_000 { deletedAssetIDs.formUnion(other.deletedAssetIDs.prefix(2_000 - deletedAssetIDs.count)) }
    }
}
struct EntityStoreStatistics: Sendable {
    let counts: [String: Int]
    let lastSync: Date?
    let isComplete: Bool
}

struct LocalAssetMatch: Sendable {
    let assetID: String
    let checksum: String
    let cloudID: String?
    let createdAt: Date?
    let adjustmentTime: Date?
    let latitude: Double?
    let longitude: Double?
}

/// The server checkpoints belong to the login session, not merely to the account.
struct EntitySyncRequest: Encodable, Sendable {
    static let types = ["AuthUsersV2", "UsersV1", "PartnersV1", "AssetsV2", "StacksV1", "PartnerAssetsV2", "PartnerStacksV1", "AlbumAssetsV2", "AlbumsV2", "AlbumUsersV1", "AlbumToAssetsV1", "AssetExifsV1", "AlbumAssetExifsV1", "PartnerAssetExifsV1", "AssetOcrV1", "MemoriesV2", "MemoryToAssetsV2", "PeopleV1", "AssetFacesV3", "UserMetadataV1", "AssetMetadataV1", "AssetEditsV1"]
    let types = Self.types
    let reset: Bool
}
