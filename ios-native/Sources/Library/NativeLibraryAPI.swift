import Foundation

/// The complete local index serves timeline navigation; first sync never delays
/// the server timeline, and semantic searches retain the server's cursor contract.
struct NativeLibraryAPI: LibraryAPI {
    let client: APIClient
    let entities: EntityStore
    /// The account's sync, which runs refreshes as its own passes. Nil where nothing syncs.
    let sync: SyncEngine?
    var cacheScope: String { client.cacheScope }

    func timeBuckets(filter: TimelineFilter) async throws -> [TimeBucket] {
        if filter.visibility != .locked, try await entities.isComplete() {
            return try await entities.timeBuckets(filter: filter)
        }
        guard filter.place == nil else { throw LibraryAPIError.placeNeedsOfflineLibrary }
        return try await client.timeBuckets(filter: filter)
    }
    func timeBucket(_ bucket: String, filter: TimelineFilter) async throws -> [Asset] {
        if filter.visibility != .locked, try await entities.isComplete() {
            FeedMonthProbe.note(.index)
            // The feed's first month read the slow way starts building the index months are found by.
            return try await entities.timeBucket(bucket, filter: filter, buildingIndex: true)
        }
        guard filter.place == nil else { throw LibraryAPIError.placeNeedsOfflineLibrary }
        FeedMonthProbe.note(.serverTimeline)
        return try await client.timeBucket(bucket, filter: filter)
    }
    /// A place's photos are laid out by month only from the complete local index.
    func supportsPlaceTimelines() async -> Bool { (try? await entities.isComplete()) == true }
    func monthPlaces(filter: TimelineFilter) async throws -> [MonthPlaceCount] {
        guard filter.visibility != .locked, try await entities.isComplete() else { return [] }
        return try await entities.monthPlaces(filter: filter)
    }
    func search(_ query: SearchQuery) async throws -> SearchResponse { try await client.search(query) }
    func metadataSearch(_ query: MetadataQuery) async throws -> SearchResponse { try await client.metadataSearch(query) }
    /// A sync pass, published like every other, and what it changed.
    func refresh() async throws -> LibraryChange? { try await sync?.refresh() }
}
