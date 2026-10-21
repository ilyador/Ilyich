import SwiftUI

struct ViewerStackView: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let stackID: String
    let onUpdated: (Asset) -> Void
    let onChanged: () -> Void
    @State private var stack: StackDetails?
    @State private var viewing: Asset?
    @State private var error: String?
    @State private var confirmUnstack = false
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss
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
                            Button("Set as stack cover") { run { let _: StackDetails = try await api.request(.put, path: "stacks/\(stackID)", body: ["primaryAssetId": asset.id]) } }
                            Button("Remove from stack") { run { try await api.requestVoid(.delete, path: "stacks/\(stackID)/assets/\(asset.id)") } }
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
                Button("Unstack") {
                    busy = true
                    Task {
                        defer { busy = false }
                        do { try await api.requestVoid(.delete, path: "stacks/\(stackID)"); onChanged(); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
            } message: { Text("All photos are kept and will appear separately in the timeline.") }
            .task { await load() }
            .fullScreenCover(item: $viewing) { asset in
                AssetViewer(api: api, pipeline: pipeline, assets: stack?.assets ?? [asset], initial: asset, onUpdated: onUpdated, onDeleted: { onChanged(); Task { await load() } })
            }
    }
    private func load() async {
        do { stack = try await api.request(.get, path: "stacks/\(stackID)") }
        catch { self.error = error.localizedDescription }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do { try await operation(); onChanged(); await load() }
            catch { self.error = error.localizedDescription }
        }
    }
}
