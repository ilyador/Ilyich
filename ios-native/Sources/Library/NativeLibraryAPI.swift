import Foundation

/// Today's feeds over the library repository: the complete, queryable local index serves timeline
/// navigation; first sync never delays the server timeline, and semantic searches retain the
/// server's cursor contract. Q5 moves the feeds onto LibraryQuery and deletes this.
struct NativeLibraryAPI: LibraryAPI {
    let repository: LibraryRepository
    var client: APIClient { repository.client }
    var cacheScope: String { client.cacheScope }
    var userID: String? { client.userID }

    init(repository: LibraryRepository) { self.repository = repository }
    init(client: APIClient, entities: EntityStore, sync: SyncEngine?) {
        repository = LibraryRepository(client: client, index: entities, sync: sync)
    }

    func timeBuckets(filter: TimelineFilter) async throws -> [TimeBucket] { try await repository.timeBuckets(filter: filter) }
    func timeBucket(_ bucket: String, filter: TimelineFilter) async throws -> [Asset] {
        try await repository.timeBucket(bucket, filter: filter)
    }
    func supportsPlaceTimelines() async -> Bool { await repository.supportsPlaceTimelines() }
    func monthPlaces(filter: TimelineFilter) async throws -> [MonthPlaceCount] { try await repository.monthPlaces(filter: filter) }
    func search(_ query: SearchQuery) async throws -> SearchResponse { try await client.search(query) }
    func metadataSearch(_ query: MetadataQuery) async throws -> SearchResponse { try await client.metadataSearch(query) }
    func refresh() async throws -> LibraryChange? { try await repository.refresh() }
}
