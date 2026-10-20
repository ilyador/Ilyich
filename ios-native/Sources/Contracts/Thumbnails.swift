import Foundation

/// One thumbnail's identity. A new revision is a new thumbnail.
enum ThumbnailKey: Hashable, Sendable {
    /// A server asset at a revision: its media revision, else its thumbhash, else "unversioned".
    case server(assetID: String, revision: String)
    case device(DeviceAssetID, modified: AssetRevision?)
}

/// How finely a thumbnail is decoded, cheapest first.
enum DecodeTier: Int, Comparable, Hashable, Sendable {
    /// The thumbhash.
    case sketch
    /// A small decode for fast scrolling.
    case scrub
    case grid

    static func < (a: DecodeTier, b: DecodeTier) -> Bool { a.rawValue < b.rawValue }
}

struct ThumbnailRequest: Hashable, Sendable {
    let key: ThumbnailKey
    let thumbhash: String?
    /// The cell's short side in pixels.
    let shortSide: Int
}

/// Why a thumbnail is wanted, most urgent first.
enum DemandBand: Int, Comparable, Hashable, Sendable {
    case visible
    /// Where a fling or a rail jump will land.
    case target
    /// Ahead in the direction of travel.
    case ahead
    /// Asked for by something other than the grid, such as the viewer.
    case explicit
    case behind
    /// Keeping the library on the phone.
    case coverage

    static func < (a: DemandBand, b: DemandBand) -> Bool { a.rawValue < b.rawValue }
}

/// How the grid is moving. Speeds are in screens per second; times are on the display clock.
enum Motion: Hashable, Sendable {
    case idle(since: TimeInterval)
    case tracking(speed: Double)
    case flinging(speed: Double)
    case scrubbing
}

/// Everything the grid wants now, replacing what it wanted before.
struct ViewportDemand: Hashable, Sendable {
    struct Item: Hashable, Sendable {
        let request: ThumbnailRequest
        let band: DemandBand
        /// Order within the band, nearest the focus first.
        let rank: Int
    }

    let generation: UInt64
    let items: [Item]
    let motion: Motion
}

enum ThumbnailInvalidation: Hashable, Sendable {
    /// These assets changed: their old revisions are useless.
    case assets(Set<String>)
    /// Access to these assets was lost: purge them now.
    case revoked(Set<String>)
    /// The account changed: drop everything held in memory.
    case account
    /// Compare what is stored with the index.
    case reconcile
}
