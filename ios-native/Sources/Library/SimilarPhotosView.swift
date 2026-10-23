import SwiftUI

struct SimilarPhotosView: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let reference: Asset
    @State private var store: LibraryStore
    @State private var viewing: Asset?
    @Environment(\.dismiss) private var dismiss
    init(api: APIClient, pipeline: MediaPipeline, reference: Asset) {
        self.api = api; self.pipeline = pipeline; self.reference = reference
        _store = State(initialValue: LibraryStore(source: LibraryRepository(client: api, index: nil, sync: nil)))
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
            .onDisappear { store.stop() }
            .fullScreenCover(item: $viewing) { asset in
                AssetViewer(api: api, pipeline: pipeline, assets: store.results, initial: asset,
                            onUpdated: store.update, onDeleted: { _ in store.findSimilar(to: reference) })
            }
        }
    }
}
