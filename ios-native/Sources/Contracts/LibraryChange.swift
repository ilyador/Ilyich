import Foundation
import IlyichPlatform

/// Names one library mutation, so its result and its change can be matched.
struct OperationID: Hashable, Sendable {
    let value: UUID
    init() { value = UUID() }
}

/// What one sync batch, mutation or phone change did to the library, precisely enough that each
/// consumer updates only what it shows.
struct LibraryChange: Sendable {
    enum Origin: Hashable, Sendable {
        case sync
        case mutation(OperationID)
        case device
    }

    /// The months an upserted asset left and joined. Nil when it wasn't, or isn't, in a month.
    struct MonthMove: Hashable, Sendable {
        var from: MonthKey?
        var to: MonthKey?
    }

    // Identity
    var account: AccountID
    var authorization: AuthorizationEpoch
    var indexRevision: UInt64
    var origin: Origin
    /// The index holds every change the server had at this instant: the sync pass behind this
    /// change began reading the server then and read its whole stream, so a photo this phone took
    /// out of its feeds before then is as the index has it (F4). Nil when nothing says so, as for
    /// a pass that failed partway, a repair or a reset.
    var syncedThrough: ContinuousClock.Instant?

    // Assets
    var upserted: [String: MonthMove] = [:]
    var removed: Set<String> = []
    /// Assets this account may no longer see. Their media must be purged.
    var accessLost: Set<String> = []
    /// Asset ID to its new media revision.
    var mediaRevisions: [String: String] = [:]

    // Collections
    var albums: Set<String> = []
    var people: Set<String> = []
    var stacks: Set<String> = []
    var collections: [CollectionChange] = []

    // Flags
    var partnersChanged = false
    var memoriesChanged = false
    /// Everything may have changed: consumers reload.
    var reset = false
    /// The backend that serves some queries changed, for example when the index became complete.
    var routingChanged = false
    var configurationChanged = false
    /// The change gave up naming items one by one; consumers reload.
    var overflow = false

    /// A change names at most this many items. Past it, it overflows: it keeps only the assets
    /// whose access was lost, which are never forgotten, and consumers reload.
    static let itemLimit = 50_000

    /// Nothing changed, as after a sync pass whose stream held only its completion marker.
    var isEmpty: Bool {
        upserted.isEmpty && removed.isEmpty && accessLost.isEmpty && mediaRevisions.isEmpty && albums.isEmpty && people.isEmpty
            && stacks.isEmpty && collections.isEmpty && !partnersChanged && !memoriesChanged && !reset && !routingChanged
            && !configurationChanged && !overflow
    }

    /// Overflows once the change names more than `itemLimit` items.
    mutating func limitItems() {
        let count = upserted.count + removed.count + accessLost.count + mediaRevisions.count + albums.count + people.count
            + stacks.count + collections.count
        guard overflow || count > Self.itemLimit else { return }
        overflow = true
        upserted = [:]; removed = []; mediaRevisions = [:]
        albums = []; people = []; stacks = []; collections = []
    }

    /// Folds a later change into this one, so a subscriber that fell behind still sees every
    /// effect. The later change's identity wins. An asset removed and then upserted counts as
    /// upserted, and the other way round; lost access is never forgotten, since a purge is
    /// always safe. A change from another account replaces this one and resets.
    mutating func merge(_ later: LibraryChange) {
        guard later.account == account else {
            self = later
            reset = true
            return
        }
        authorization = later.authorization
        indexRevision = later.indexRevision
        origin = later.origin
        // The index only moves forward: it holds what the newest full pass read.
        if let synced = later.syncedThrough { syncedThrough = max(syncedThrough ?? synced, synced) }
        for (id, move) in later.upserted {
            upserted[id] = MonthMove(from: upserted[id].map { $0.from } ?? move.from, to: move.to)
            removed.remove(id)
        }
        for id in later.removed {
            upserted[id] = nil
            removed.insert(id)
        }
        accessLost.formUnion(later.accessLost)
        mediaRevisions.merge(later.mediaRevisions) { _, newer in newer }
        albums.formUnion(later.albums)
        people.formUnion(later.people)
        stacks.formUnion(later.stacks)
        collections += later.collections
        partnersChanged = partnersChanged || later.partnersChanged
        memoriesChanged = memoriesChanged || later.memoriesChanged
        reset = reset || later.reset
        routingChanged = routingChanged || later.routingChanged
        configurationChanged = configurationChanged || later.configurationChanged
        overflow = overflow || later.overflow
        limitItems()
    }
}

enum CollectionChange: Hashable, Sendable {
    case albumCreated(String)
    case albumUpdated(String)
    case albumDeleted(String)
    case albumLeft(String)
    case personUpdated(String)
    case partnersChanged
    case memorySaved(String)
}

/// One user command that changes the library on the server. Asset IDs are server IDs.
enum MutationRequest: Equatable, Sendable {
    /// The editable details of one asset; nil leaves a field as it is.
    struct AssetFields: Equatable, Sendable {
        var description: String?
        var dateTimeOriginal: String?
        var latitude: Double?
        var longitude: Double?
    }

    case favorite([String], Bool)
    case visibility([String], AssetVisibility)
    case trash([String])
    case deletePermanently([String])
    case restore([String])
    case restoreAllTrash
    case emptyTrash
    case addToAlbum(album: String, assets: [String])
    case removeFromAlbum(album: String, assets: [String])
    case setAlbumCover(album: String, asset: String)
    case createAlbum(name: String, assets: [String])
    /// The first asset becomes the stack's primary.
    case stack([String])
    case unstack(stack: String)
    case removeFromStack(stack: String, assets: [String])
    case setStackCover(stack: String, asset: String)
    case update(String, AssetFields)
    case rating([String], Int?)
    case tag([String], tags: [String])
    case reassignFace(face: String, person: String)
    case removeFace(String)
    case edits(asset: String, [PhotoEdit])
    case resolveDuplicate(group: String, keep: [String], trash: [String])
    case dismissDuplicate(group: String)
}

/// What a mutation did. Bulk requests can partly succeed.
struct MutationResult: Sendable {
    let operation: OperationID
    let request: MutationRequest
    /// The photos the change was made to.
    let succeeded: [String]
    /// Asset ID to the reason it failed.
    let failed: [String: String]
    /// Assets as the change left them: the server's record where it answered with one, else the
    /// record of the screen that asked, changed as the server changed it. None for a photo
    /// deleted for good.
    let fresh: [String: Asset]
    /// The sync pass that followed, merged in when it arrives.
    var followUp: LibraryChange?
    /// The album the server answered with: the one made, or the one whose cover was set.
    var album: Album? = nil
    /// How many photos the server says it changed, where it says so (Trash's restore and empty).
    var affected: Int? = nil
}
