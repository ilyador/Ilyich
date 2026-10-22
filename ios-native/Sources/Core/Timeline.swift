import Foundation

struct TimeBucket: Codable, Hashable, Identifiable, Sendable {
    let timeBucket: String
    let count: Int
    var id: String { timeBucket }
    var date: Date? { APIDate.parse(timeBucket) }
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
