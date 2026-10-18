import SwiftUI

/// A feature grid that opens an asset on tap, or multi-selects for bulk actions after the user taps Select.
/// Selection is keyed by asset ID and keeps snapshots, so it survives pagination and parent reloads.
struct SelectableFeatureAssetGrid: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let assets: [Asset]
    let onOpenAsset: (Asset) -> Void
    /// Called after a bulk action completes. The parent should reload its collection.
    let onChanged: () -> Void
    @State private var selecting = false
    @State private var selected: [String: Asset] = [:]
    @State private var showActions = false

    private var selectedAssets: [Asset] {
        let order = Dictionary(assets.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        return selected.values.sorted { (order[$0.id] ?? .max, $0.id) < (order[$1.id] ?? .max, $1.id) }
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: .init(.flexible(), spacing: 2), count: 3), spacing: 2) {
            ForEach(assets) { asset in cell(asset) }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(selecting ? "Done" : "Select") { selecting.toggle(); if !selecting { selected = [:] } }
                    .disabled(!selecting && assets.isEmpty)
            }
            if selecting {
                ToolbarItemGroup(placement: .bottomBar) {
                    Text(selected.isEmpty ? "Select items" : "\(selected.count) selected").font(.subheadline).monospacedDigit()
                    Spacer()
                    Button("Actions", systemImage: "ellipsis.circle") { showActions = true }.disabled(selected.isEmpty)
                }
            }
        }
        .sheet(isPresented: $showActions) {
            NavigationStack {
                BulkActionsView(api: api, pipeline: pipeline, assets: selectedAssets, onChanged: completed)
            }
        }
    }

    private func cell(_ asset: Asset) -> some View {
        let isSelected = selected[asset.id] != nil
        return Button { tap(asset) } label: {
            FeatureAssetImage(pipeline: pipeline, asset: asset).aspectRatio(1, contentMode: .fit)
                .overlay(alignment: .bottomTrailing) { if asset.isVideo { Image(systemName: "play.fill").font(.caption).foregroundStyle(.white).padding(7).shadow(radius: 2) } }
                .overlay { if isSelected { Rectangle().stroke(Color.accentColor, lineWidth: 3) } }
                .overlay(alignment: .topLeading) { if selecting { badge(isSelected) } }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(asset.displayName)
        .accessibilityValue(selecting ? (isSelected ? "Selected" : "Not selected") : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func badge(_ isSelected: Bool) -> some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3).symbolRenderingMode(.palette)
            .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.9), isSelected ? Color.accentColor : Color.clear)
            .shadow(radius: 2).padding(6)
    }

    private func tap(_ asset: Asset) {
        guard selecting else { onOpenAsset(asset); return }
        if selected[asset.id] == nil { selected[asset.id] = asset } else { selected[asset.id] = nil }
    }

    private func completed() {
        selected = [:]; selecting = false
        onChanged()
    }
}
