import Foundation

struct TimeBucket: Codable, Hashable, Identifiable, Sendable {
    let timeBucket: String
    let count: Int
    var id: String { timeBucket }
    var date: Date? { APIDate.parse(timeBucket) }
}

/// The photos of one place. Only the local library index can lay them out by month, so the server
/// never sees this filter. A place is known by its name and size, which keeps its feed and caches
/// apart from the library's.
struct TimelinePlace: Hashable, Sendable {
    let key: String
    let assetIDs: [String]

    init(id: String, assetIDs: [String]) {
        key = "\(id)#\(assetIDs.count)"; self.assetIDs = assetIDs
    }
    // A place can hold thousands of photos; comparing and hashing them all would slow every lookup.
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

struct TimelineFilter: Hashable, Sendable {
    var visibility: AssetVisibility? = .timeline
    var albumID: String?
    var personID: String?
    var userID: String?
    var isFavorite: Bool?
    var isTrashed: Bool?
    /// Photos with a developed Lightroom preview, or, with false, the rest.
    var isDeveloped: Bool?
    var withStacked = true
    var withPartners = false
    var order = "desc"
    var orderBy = "takenAt"
    var place: TimelinePlace?

    /// Names this feed for the caches on the phone. A place is part of it, though the server never
    /// sees one.
    var cacheKey: String {
        let items = queryItems.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
        return place.map { items + "&place=" + $0.key } ?? items
    }

    var queryItems: [URLQueryItem] {
        var items = [URLQueryItem(name: "order", value: order), URLQueryItem(name: "orderBy", value: orderBy),
                     URLQueryItem(name: "withStacked", value: String(withStacked))]
        for (name, value) in [("visibility", visibility?.rawValue), ("albumId", albumID), ("personId", personID), ("userId", userID),
                              ("isFavorite", isFavorite.map(String.init)), ("isTrashed", isTrashed.map(String.init)),
                              ("isDeveloped", isDeveloped.map(String.init))] {
            if let value { items.append(.init(name: name, value: value)) }
        }
        if withPartners { items.append(.init(name: "withPartners", value: "true")) }
        return items
    }
}

/// The server returns columns with matching row counts, rather than one object per asset.
struct TimeBucketPayload: Decodable, Sendable {
    let id: [String]
    let ownerId: [String]
    let ratio: [Double]
    let isFavorite: [Bool]
    let isTrashed: [Bool]
    let isImage: [Bool]
    let visibility: [AssetVisibility]
    let fileCreatedAt: [Date]
    let createdAt: [Date]
    let localOffsetHours: [Double]
    let duration: [Int?]
    let thumbhash: [String?]
    let mediaRevision: [String]?
    let livePhotoVideoId: [String?]

    func assets() throws -> [Asset] {
        let counts = [ownerId.count, ratio.count, isFavorite.count, isTrashed.count, isImage.count,
                      visibility.count, fileCreatedAt.count, createdAt.count, localOffsetHours.count,
                      duration.count, thumbhash.count, livePhotoVideoId.count]
        guard counts.allSatisfy({ $0 == id.count }), mediaRevision == nil || mediaRevision?.count == id.count else {
            throw APIError.invalidResponse("The photo timeline contains mismatched columns.")
        }
        return id.indices.map { index in
            var asset = Asset(id: id[index], type: isImage[index] ? .image : .video, ownerId: ownerId[index],
                              fileCreatedAt: fileCreatedAt[index],
                              localDateTime: fileCreatedAt[index].addingTimeInterval(localOffsetHours[index] * 3600),
                              isFavorite: isFavorite[index], mediaRevision: mediaRevision?[index], thumbhash: thumbhash[index],
                              timelineRatio: ratio[index])
            asset.createdAt = createdAt[index]; asset.duration = duration[index]
            asset.isTrashed = isTrashed[index]; asset.visibility = visibility[index]
            asset.livePhotoVideoId = livePhotoVideoId[index]
            return asset
        }
    }
}
