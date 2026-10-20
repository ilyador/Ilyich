import Foundation

/// The complete local index serves timeline navigation; first sync never delays
/// the server timeline, and semantic searches retain the server's cursor contract.
struct NativeLibraryAPI: LibraryAPI {
    let client: APIClient
    let entities: EntityStore
    let sync: NativeSync
    var cacheScope: String { client.cacheScope }

    func timeBuckets(filter: TimelineFilter) async throws -> [TimeBucket] {
        if filter.visibility != .locked, try await entities.isComplete() {
            return try await entities.timeBuckets(filter: filter)
        }
        return try await client.timeBuckets(filter: filter)
    }
    func timeBucket(_ bucket: String, filter: TimelineFilter) async throws -> [Asset] {
        if filter.visibility != .locked, try await entities.isComplete() {
            return try await entities.timeBucket(bucket, filter: filter)
        }
        return try await client.timeBucket(bucket, filter: filter)
    }
    func monthPlaces(filter: TimelineFilter) async throws -> [MonthPlaceCount] {
        guard filter.visibility != .locked, try await entities.isComplete() else { return [] }
        return try await entities.monthPlaces(filter: filter)
    }
    func search(_ query: SearchQuery) async throws -> SearchResponse { try await client.search(query) }
    func metadataSearch(_ query: MetadataQuery) async throws -> SearchResponse { try await client.metadataSearch(query) }
    func refresh() async throws { _ = try await sync.synchronize() }
}

extension Notification.Name {
    static let ilyichLibraryChanged = Notification.Name("ilyich.libraryChanged")
}
