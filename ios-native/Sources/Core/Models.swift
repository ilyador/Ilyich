import Foundation

enum APIJSON {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            guard let date = APIDate.parse(value) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid server date"))
            }
            return date
        }
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

enum APIDate {
    static func parse(_ value: String) -> Date? {
        var value = value.replacingOccurrences(of: " ", with: "T")
        if value.count == 10 { value += "T00:00:00Z" }
        // SQL time-bucket UTC components omit the zone; never use the phone's zone.
        if value.count > 10, !value.hasSuffix("Z"), !value.dropFirst(10).contains("+"), !value.dropFirst(10).contains("-") {
            value += "Z"
        }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
            ?? (try? Date.ISO8601FormatStyle().parse(value))
    }
}

struct LoginResponse: Codable, Sendable {
    let accessToken: String
    let userId: String
    let userEmail: String
    let name: String
    let isAdmin: Bool
    let shouldChangePassword: Bool
    let profileImagePath: String?
    let isOnboarded: Bool?
}

struct ServerFeatures: Decodable, Sendable {
    let passwordLogin: Bool
    let oauth: Bool
    let smartSearch: Bool
    let searchVerification: Bool?
    let ocr: Bool
    let facialRecognition: Bool
    let map: Bool
    let trash: Bool
    let sidecar: Bool
    let realtimeTranscoding: Bool
}

struct ServerConfig: Decodable, Sendable {
    let externalDomain: String
    let isInitialized: Bool
    let maintenanceMode: Bool
    let loginPageMessage: String
    let oauthButtonText: String
    let mapLightStyleUrl: String
    let mapDarkStyleUrl: String
    let trashDays: Int
}

struct AuthStatus: Decodable, Sendable {
    let pinCode: Bool
    let password: Bool
    let isElevated: Bool
    let expiresAt: Date?
    let pinExpiresAt: Date?
}

struct User: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let email: String?
    let profileImagePath: String?
    var quotaSizeInBytes: Int64? = nil
    var quotaUsageInBytes: Int64? = nil
}

enum AssetKind: String, Codable, Sendable {
    case image = "IMAGE", video = "VIDEO", audio = "AUDIO", other = "OTHER"
    init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
    }
}

enum AssetVisibility: String, Codable, Sendable {
    case timeline, archive, hidden, locked
}

struct Asset: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var ownerId: String?
    var owner: User?
    var tags: [AssetTag]?
    var stack: AssetStack?
    var type: AssetKind
    var originalFileName: String
    var fileCreatedAt: Date?
    var localDateTime: Date?
    var createdAt: Date?
    var width: Int?
    var height: Int?
    var duration: Int?
    var isFavorite: Bool
    var isTrashed: Bool
    var isEdited: Bool
    var isDeveloped: Bool
    /// Timeline columns omit edit state. Only detailed/API sync records can
    /// authorize substituting a local original for the server's rendition.
    var hasKnownEditState: Bool
    var visibility: AssetVisibility
    var mediaRevision: String?
    var thumbhash: String?
    var livePhotoVideoId: String?
    var exifInfo: ExifInfo?
    var people: [Person]?
    var timelineRatio: Double?

    var isVideo: Bool { type == .video }
    var isAnimatedImage: Bool { type == .image && livePhotoVideoId == nil && (duration ?? 0) > 0 }
    var aspectRatio: Double {
        if let width, let height, width > 0, height > 0 { return Double(width) / Double(height) }
        return timelineRatio.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 1
    }
    var cacheRevision: String { mediaRevision ?? thumbhash ?? "unversioned" }
    var displayName: String { originalFileName.isEmpty ? "Photo" : originalFileName }

    init(id: String, type: AssetKind = .image, originalFileName: String = "", ownerId: String? = nil,
         fileCreatedAt: Date? = nil, localDateTime: Date? = nil, width: Int? = nil, height: Int? = nil,
         isFavorite: Bool = false, isDeveloped: Bool = false, mediaRevision: String? = nil, thumbhash: String? = nil,
         timelineRatio: Double? = nil) {
        self.id = id; self.type = type; self.originalFileName = originalFileName; self.ownerId = ownerId
        self.fileCreatedAt = fileCreatedAt; self.localDateTime = localDateTime; self.width = width; self.height = height
        self.isFavorite = isFavorite; self.isDeveloped = isDeveloped; self.mediaRevision = mediaRevision
        self.thumbhash = thumbhash; self.timelineRatio = timelineRatio
        self.isTrashed = false; self.isEdited = false; self.visibility = .timeline; self.hasKnownEditState = false
    }

    enum CodingKeys: String, CodingKey {
        case id, ownerId, owner, tags, stack, type, originalFileName, fileCreatedAt, localDateTime, createdAt, width, height, duration
        case isFavorite, isTrashed, isEdited, isDeveloped, hasKnownEditState, visibility, mediaRevision, thumbhash, livePhotoVideoId, exifInfo, people, timelineRatio
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        ownerId = try c.decodeIfPresent(String.self, forKey: .ownerId)
        owner = try c.decodeIfPresent(User.self, forKey: .owner)
        tags = try c.decodeIfPresent([AssetTag].self, forKey: .tags)
        stack = try c.decodeIfPresent(AssetStack.self, forKey: .stack)
        type = try c.decode(AssetKind.self, forKey: .type)
        originalFileName = try c.decodeIfPresent(String.self, forKey: .originalFileName) ?? ""
        fileCreatedAt = try c.decodeIfPresent(Date.self, forKey: .fileCreatedAt)
        localDateTime = try c.decodeIfPresent(Date.self, forKey: .localDateTime)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        width = try c.decodeIfPresent(Int.self, forKey: .width); height = try c.decodeIfPresent(Int.self, forKey: .height)
        duration = try c.decodeIfPresent(Int.self, forKey: .duration)
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        isTrashed = try c.decodeIfPresent(Bool.self, forKey: .isTrashed) ?? false
        isEdited = try c.decodeIfPresent(Bool.self, forKey: .isEdited) ?? false
        isDeveloped = try c.decodeIfPresent(Bool.self, forKey: .isDeveloped) ?? false
        hasKnownEditState = try c.decodeIfPresent(Bool.self, forKey: .hasKnownEditState) ?? (c.contains(.isEdited) && c.contains(.isDeveloped))
        visibility = try c.decodeIfPresent(AssetVisibility.self, forKey: .visibility) ?? .timeline
        mediaRevision = try c.decodeIfPresent(String.self, forKey: .mediaRevision)
        thumbhash = try c.decodeIfPresent(String.self, forKey: .thumbhash)
        livePhotoVideoId = try c.decodeIfPresent(String.self, forKey: .livePhotoVideoId)
        exifInfo = try c.decodeIfPresent(ExifInfo.self, forKey: .exifInfo)
        people = try c.decodeIfPresent([Person].self, forKey: .people)
        timelineRatio = try c.decodeIfPresent(Double.self, forKey: .timelineRatio)
    }
}

struct AssetTag: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let value: String
}
struct AssetStack: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let primaryAssetId: String
    let assetCount: Int
}
struct StackDetails: Decodable, Sendable {
    let id: String
    let primaryAssetId: String
    let assets: [Asset]
}

struct ExifInfo: Codable, Hashable, Sendable {
    let exifImageWidth: Int?
    let exifImageHeight: Int?
    let orientation: String?
    let projectionType: String?
    let timeZone: String?
    let description: String?
    let city: String?
    let state: String?
    let country: String?
    let latitude: Double?
    let longitude: Double?
    let make: String?
    let model: String?
    let lensModel: String?
    let fNumber: Double?
    let exposureTime: String?
    let iso: Double?
    let focalLength: Double?
    let fileSizeInByte: Int64?
    let rating: Int?
}

struct Album: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var albumName: String
    var description: String?
    var albumThumbnailAssetId: String?
    let assetCount: Int
    let shared: Bool
    let albumUsers: [AlbumUser]?
    let startDate: Date?
    let endDate: Date?
    let updatedAt: Date?
    let order: String?
}

struct AlbumUser: Codable, Hashable, Sendable {
    let user: User
    let role: String
}

struct Person: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var name: String
    let birthDate: String?
    let thumbnailPath: String?
    let updatedAt: Date?
    let isHidden: Bool?
    let isFavorite: Bool?
}

struct PeopleResponse: Decodable, Sendable {
    let people: [Person]
    let total: Int
    let hidden: Int
    let hasNextPage: Bool?
}

struct MapMarker: Decodable, Hashable, Identifiable, Sendable {
    let id: String
    let lat: Double
    let lon: Double
    let city: String?
    let state: String?
    let country: String?
}

struct AssetStatistics: Decodable, Sendable {
    let images: Int
    let videos: Int
    let total: Int
}

struct BulkResult: Decodable, Identifiable, Sendable {
    let id: String
    let success: Bool
    let error: String?
    let errorMessage: String?
}

struct TrashResult: Decodable, Sendable { let count: Int }

struct Memory: Decodable, Identifiable, Sendable {
    let id: String
    let type: String
    let memoryAt: Date
    let isSaved: Bool
    var assets: [Asset]
    let data: MemoryData
    var seenAt: Date? = nil
    var showAt: Date? = nil
    var hideAt: Date? = nil
}
struct MemoryData: Decodable, Sendable { let year: Int; let personId: String?; let personName: String? }

struct Partner: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let email: String
    let inTimeline: Bool?
}

struct DuplicateGroup: Decodable, Identifiable, Sendable {
    let duplicateId: String
    let assets: [Asset]
    let suggestedKeepAssetIds: [String]
    var id: String { duplicateId }
}

struct SharedLink: Decodable, Identifiable, Sendable {
    let id: String
    let key: String
    let slug: String?
    let type: String
    let description: String?
    let expiresAt: Date?
    let allowDownload: Bool
    let allowUpload: Bool
    let showMetadata: Bool
    let assets: [Asset]
    let album: Album?
}
