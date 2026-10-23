import SwiftUI

struct SimilarPhotosView: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let reference: Asset
    @State private var store: LibraryFeedStore
    @State private var viewing: Asset?
    /// Changes made here, or anywhere, reach the results in place (N2).
    @State private var follower = MutationFollower()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mutations) private var mutations
    init(api: APIClient, pipeline: MediaPipeline, reference: Asset) {
        self.api = api; self.pipeline = pipeline; self.reference = reference
        _store = State(initialValue: LibraryFeedStore(source: LibraryRepository(client: api, index: nil, sync: nil)))
    }
    var body: some View {
        NavigationStack {
            ZStack {
                PhotoGrid(store: store, pipeline: pipeline, columns: 3, topInset: 0, bottomInset: 16) { viewing = $0 }
                if store.isSearching && store.results.isEmpty { ProgressView("Finding similar photos") }
                if !store.isSearching, store.results.isEmpty, store.error == nil {
                    ContentUnavailableView("No similar photos", systemImage: "photo.on.rectangle.angled")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let error = store.error { HStack { Text(error).font(.footnote); Button("Retry") { store.retrySearch() } }.padding().background(.regularMaterial) }
            }
            .navigationTitle("Similar photos").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { if !store.started { store.started = true; store.findSimilar(to: reference) } }
            .onAppear {
                let store = store
                follower.follow(mutations) { await FeedMutationApplier.apply($0, to: store, refreshes: false) }
            }
            .onDisappear { store.stop() }
            .fullScreenCover(item: $viewing) { asset in
                AssetViewer(api: api, pipeline: pipeline, assets: store.results, initial: asset,
                            onUpdated: store.update, onDeleted: { store.removeLocally([$0]) })
            }
        }
    }
}
