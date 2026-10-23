import SwiftUI

struct ViewerStackView: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let stackID: String
    /// A fresher record of a photo, read from the server.
    let onUpdated: (Asset) -> Void
    @State private var stack: StackDetails?
    @State private var viewing: Asset?
    @State private var error: String?
    @State private var confirmUnstack = false
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mutations) private var mutations
    private var context: CapabilityContext { CapabilityContext(api: api, features: nil) }
    /// Whether this photo's place in the stack can be changed: only its owner can.
    private func stacking(_ asset: Asset) -> ActionAvailability { AssetCapabilityPolicy.evaluate(asset, context: context)[.stack] }
    /// Unstacking changes every photo in it.
    private var unstacking: ActionAvailability { AssetCapabilityPolicy.evaluate(selection: stack?.assets ?? [], context: context)[.stack] }
    var body: some View {
        List {
            ForEach(stack?.assets ?? []) { asset in
                HStack {
                    Button { viewing = asset } label: {
                        HStack {
                            FeatureThumbnail(api: api, pipeline: pipeline, assetID: asset.id, revision: asset.cacheRevision).frame(width: 64, height: 64).clipShape(.rect(cornerRadius: 8))
                            VStack(alignment: .leading) {
                                Text(asset.displayName).lineLimit(2)
                                if asset.id == stack?.primaryAssetId { Text("Stack cover").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }.buttonStyle(.plain)
                    Spacer()
                    let availability = stacking(asset)
                    if availability != .hidden {
                        Menu {
                            Button("Set as stack cover") { run(.setStackCover(stack: stackID, asset: asset.id), on: [asset]) }
                            Button("Remove from stack") { run(.removeFromStack(stack: stackID, assets: [asset.id]), on: [asset]) }
                        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("Stack actions for \(asset.displayName)")
                            .disabled(availability != .offered)
                    }
                }.disabled(busy)
            }
            if let error { Text(error).foregroundStyle(.secondary); Button("Retry") { Task { await load() } } }
        }.navigationTitle("Stack").navigationBarTitleDisplayMode(.inline)
            .overlay { if stack == nil && error == nil { ProgressView() } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if unstacking != .hidden {
                    ToolbarItem(placement: .topBarTrailing) { Button("Unstack") { confirmUnstack = true }.disabled(busy || unstacking != .offered) }
                }
            }
            .confirmationDialog("Unstack these photos?", isPresented: $confirmUnstack, titleVisibility: .visible) {
                Button("Unstack") { run(.unstack(stack: stackID), on: stack?.assets ?? [], then: { dismiss() }) }
            } message: { Text("All photos are kept and will appear separately in the timeline.") }
            .task { await load() }
            // The stack is read again whenever one of its photos changes, here or in its viewer;
            // the feed takes stack changes from the sync's change.
            .onMutationApplied { result in
                guard !Set(result.succeeded).isDisjoint(with: (stack?.assets ?? []).map(\.id)) else { return }
                Task { await load() }
            }
            .fullScreenCover(item: $viewing) { asset in
                AssetViewer(api: api, pipeline: pipeline, assets: stack?.assets ?? [asset], initial: asset, onUpdated: onUpdated, onDeleted: { _ in Task { await load() } })
            }
    }
    private func load() async {
        do { stack = try await api.request(.get, path: "stacks/\(stackID)") }
        catch { self.error = error.localizedDescription }
    }
    /// Has the account's mutations make the change; the stack is read again once it is made.
    private func run(_ request: MutationRequest, on assets: [Asset], then: @escaping @MainActor () -> Void = {}) {
        guard let mutations else { error = APIError.signedOut.localizedDescription; return }
        busy = true
        let handle = mutations.start(request, on: assets)
        Task {
            defer { busy = false }
            do { _ = try await handle.result; then() }
            catch { self.error = error.localizedDescription }
        }
    }
}
