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
/// Whether a date is set, said with an explicit null as the V3 search schema needs:
/// {"eq": null} for unset and {"ne": null} for set.
struct NullDateFilter: Codable, Hashable, Sendable {
    var isSet: Bool
    static let unset = NullDateFilter(isSet: false)
    static let set = NullDateFilter(isSet: true)

    private enum CodingKeys: String, CodingKey { case eq, ne }
    init(isSet: Bool) { self.isSet = isSet }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.ne) || container.contains(.eq) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Neither eq nor ne."))
        }
        isSet = container.contains(.ne)
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeNil(forKey: isSet ? .ne : .eq)
    }
}
/// The order of a metadata search.
struct SearchOrder: Codable, Hashable, Sendable {
    enum Field: String, Codable, Sendable { case localDateTime, fileCreatedAt }
    var field: Field
    /// asc or desc.
    var direction: String
}
struct OCRFilter: Codable, Hashable, Sendable { var matches: String }
struct BoolFilter: Codable, Hashable, Sendable { var eq: Bool }
struct IDFilter: Codable, Hashable, Sendable { var eq: String?; var ne: String? }
struct SearchIDAlternative: Codable, Hashable, Sendable { var id: IDFilter }
struct PatternFilter: Codable, Hashable, Sendable {
    var like: String
    static func containing(_ text: String) -> Self {
        .init(like: "%" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%")
    }
}
struct RatingFilter: Codable, Hashable, Sendable {
    var eq: Int?
    private enum CodingKeys: String, CodingKey { case eq }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(eq, forKey: .eq)
    }
}
enum SearchMode: String, CaseIterable, Identifiable, Sendable {
    case context = "Photo content", filename = "Filename", description = "Description", ocr = "Text in photos"
    var id: Self { self }
}

extension SearchFilter {
    /// The library as it is browsed: timeline and archive. Saying so explicitly keeps the Locked
    /// Folder out of searches while it is unlocked, when the server would otherwise include it.
    static let library = SearchFilter(visibility: StringFilter(in: ["timeline", "archive"]))
}

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
    var state: StringFilter?
    var make: StringFilter?
    var model: StringFilter?
    var originalFileName: PatternFilter?
    var description: PatternFilter?
    var rating: RatingFilter?
    var hasAlbums: BoolFilter?
    var tagIds: IDsFilter?
    var trashedAt: NullDateFilter?

    func matching(_ text: String, mode: SearchMode) -> Self {
        var filter = self
        guard !text.isEmpty else { return filter }
        switch mode {
        case .context: break
        case .filename: filter.originalFileName = .containing(text)
        case .description: filter.description = .containing(text)
        case .ocr: filter.ocr = OCRFilter(matches: text)
        }
        return filter
    }
}

struct SearchQuery: Encodable, Sendable {
    var query: String?
    var queryAssetId: String?
    var language: String? = Locale.current.language.languageCode?.identifier
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
    var orderBy: SearchOrder?
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
