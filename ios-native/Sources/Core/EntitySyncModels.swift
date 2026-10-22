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

/// What committed sync batches did to the offline library, item by item. SyncEngine names the
/// account and authorization it happened under and publishes it as a LibraryChange.
struct IndexChange: Sendable, Equatable {
    typealias MonthMove = LibraryChange.MonthMove

    /// Assets added or changed, with the months they left and joined. An asset whose details
    /// changed (EXIF, edits, faces, text, metadata) stays in its month.
    var upserted: [String: MonthMove] = [:]
    var removed: Set<String> = []
    /// Removed assets the account may no longer see, as opposed to deleted ones.
    var accessLost: Set<String> = []
    /// An asset already in the index to its new media revision.
    var mediaRevisions: [String: String] = [:]
    var albums: Set<String> = []
    var people: Set<String> = []
    var stacks: Set<String> = []
    /// Partners, or the other users the library names, changed.
    var partnersChanged = false
    /// Memories, or the preferences that turn them on, changed.
    var memoriesChanged = false
    /// The server reset this session's sync: the index was emptied and fills again.
    var serverReset = false
    /// The index was emptied on the phone, for a new session or a first sync, and fills again.
    var localReset = false
    /// The index became complete, or stopped being complete, so feeds read from elsewhere.
    var routingChanged = false
    /// More items than a change names; consumers reload.
    var overflow = false
    /// The stream's completion marker arrived. The marker alone changes nothing.
    var completed = false
    /// The index's revision once these batches were in.
    var revision: UInt64 = 0

    var isEmpty: Bool {
        upserted.isEmpty && removed.isEmpty && accessLost.isEmpty && mediaRevisions.isEmpty && albums.isEmpty && people.isEmpty
            && stacks.isEmpty && !partnersChanged && !memoriesChanged && !serverReset && !localReset && !routingChanged && !overflow
    }

    /// The asset was written; `from` is where it was before this change began.
    mutating func upsert(_ id: String, from: MonthKey?, to: MonthKey?) {
        upserted[id] = MonthMove(from: upserted[id].map { $0.from } ?? from, to: to)
        removed.remove(id)
    }

    /// The asset's details changed while it stayed in `month`.
    mutating func touch(_ id: String, in month: MonthKey?) {
        guard upserted[id] == nil else { return }
        upsert(id, from: month, to: month)
    }

    mutating func remove(_ id: String, accessLost lost: Bool) {
        upserted[id] = nil
        mediaRevisions[id] = nil
        removed.insert(id)
        if lost { accessLost.insert(id) }
    }

    /// Folds a later change in, with the rules LibraryChange.merge follows.
    mutating func merge(_ later: IndexChange) {
        for (id, move) in later.upserted { upsert(id, from: move.from, to: move.to) }
        for id in later.removed { remove(id, accessLost: false) }
        accessLost.formUnion(later.accessLost)
        mediaRevisions.merge(later.mediaRevisions) { _, newer in newer }
        albums.formUnion(later.albums)
        people.formUnion(later.people)
        stacks.formUnion(later.stacks)
        partnersChanged = partnersChanged || later.partnersChanged
        memoriesChanged = memoriesChanged || later.memoriesChanged
        serverReset = serverReset || later.serverReset
        localReset = localReset || later.localReset
        routingChanged = routingChanged || later.routingChanged
        overflow = overflow || later.overflow
        completed = completed || later.completed
        revision = max(revision, later.revision)
        limitItems()
    }

    /// Overflows past LibraryChange.itemLimit items, keeping lost access, as LibraryChange does.
    mutating func limitItems() {
        let count = upserted.count + removed.count + accessLost.count + mediaRevisions.count + albums.count + people.count + stacks.count
        guard overflow || count > LibraryChange.itemLimit else { return }
        overflow = true
        upserted = [:]; removed = []; mediaRevisions = [:]
        albums = []; people = []; stacks = []
    }
}
/// A photo the index removed, whose cached media must go too. Revoked when access to it was lost
/// rather than the photo deleted.
struct MediaPurge: Hashable, Sendable {
    let assetID: String
    let revoked: Bool
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
    /// The timeline shows it: not in the trash, with timeline visibility.
    var visible = true
}

/// The server checkpoints belong to the login session, not merely to the account.
struct EntitySyncRequest: Encodable, Sendable {
    static let types = ["AuthUsersV2", "UsersV1", "PartnersV1", "AssetsV2", "StacksV1", "PartnerAssetsV2", "PartnerStacksV1", "AlbumAssetsV2", "AlbumsV2", "AlbumUsersV1", "AlbumToAssetsV1", "AssetExifsV1", "AlbumAssetExifsV1", "PartnerAssetExifsV1", "AssetOcrV1", "MemoriesV2", "MemoryToAssetsV2", "PeopleV1", "AssetFacesV3", "UserMetadataV1", "AssetMetadataV1", "AssetEditsV1"]
    let types = Self.types
    let reset: Bool
}
