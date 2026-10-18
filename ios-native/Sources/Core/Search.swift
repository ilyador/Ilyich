import Foundation

struct IDsFilter: Codable, Hashable, Sendable {
    var all: [String]?
    var any: [String]?
    var none: [String]?
}
struct StringFilter: Codable, Hashable, Sendable {
    var eq: String?
    var `in`: [String]?
}
struct DateFilter: Codable, Hashable, Sendable {
    var gte: Date?
    var lt: Date?
}
struct OCRFilter: Codable, Hashable, Sendable { var matches: String }
struct BoolFilter: Codable, Hashable, Sendable { var eq: Bool }
struct IDFilter: Codable, Hashable, Sendable { var eq: String?; var ne: String? }
struct SearchIDAlternative: Codable, Hashable, Sendable { var id: IDFilter }

struct SearchFilter: Codable, Hashable, Sendable {
    var id: IDFilter?
    var type: StringFilter?
    var isMotion: BoolFilter?
    var personIds: IDsFilter?
    var albumIds: IDsFilter?
    var city: StringFilter?
    var country: StringFilter?
    var takenAt: DateFilter?
    var visibility: StringFilter?
    var isFavorite: BoolFilter?
    var ocr: OCRFilter?
    var or: [SearchIDAlternative]?
}

struct SearchQuery: Encodable, Sendable {
    var query: String
    var filter = SearchFilter()
    var cursor: String?
    var size = 10
    var verify: Bool?
    var withExif = true
}

struct MetadataQuery: Encodable, Sendable {
    var filter = SearchFilter()
    var cursor: String?
    var size = 100
    var withExif = true
}

struct SearchResponse: Decodable, Sendable {
    let assets: SearchAssets
    let verification: Verification?
}

struct SearchAssets: Decodable, Sendable {
    let items: [Asset]
    let count: Int
    let nextCursor: String?
    let nextPage: String?
    // The server's deprecated `total` is only the current page length.
    var hasMore: Bool { nextCursor != nil || nextPage != nil }
}

struct Verification: Decodable, Sendable {
    enum Status: String, Decodable, Sendable {
        case complete, partial, unavailable
        case notNeeded = "not-needed"
    }
    let status: Status
    let checked: Int
    let rejected: Int
    var canRetry: Bool { status == .partial || status == .unavailable }
}
