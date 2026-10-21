import SwiftUI

/// Memories are manually browsed stories, independent of slideshow timing and
/// repeat preferences. Horizontal movement changes photos; vertical movement
/// changes memories and eventually reaches a finite epilogue.
struct MemoryPlaybackView: View {
    let api: APIClient
    let pipeline: MediaPipeline
    let memories: [Memory]
    var initialID: String? = nil
    /// Opens the photo, or shows it in the library's timeline, once the player and the screens
    /// under it have closed.
    let onNavigate: (NavigationIntent) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var cursor = MemoryCursor()
    @State private var initialized = false
    @State private var oldIdleTimer = false
    @State private var readyAssetID: String?
    private var available: [Memory] { memories.filter { !$0.assets.isEmpty } }
    private var memory: Memory? { available.indices.contains(cursor.memory) ? available[cursor.memory] : nil }
    private var asset: Asset? { guard let memory, memory.assets.indices.contains(cursor.asset) else { return nil }; return memory.assets[cursor.asset] }
    private var counts: [Int] { available.map { $0.assets.count } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Close memories", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly).frame(width: 44, height: 44)
                Spacer()
                if let memory { Text("\(cursor.asset + 1) of \(memory.assets.count)").font(.subheadline.monospacedDigit()) }
            }.padding(.horizontal, 12).buttonStyle(.glass)
            if let memory, let asset {
                MemoryProgress(count: memory.assets.count, selected: cursor.asset).frame(height: 4).padding(.horizontal, 22).padding(.vertical, 12)
                ZStack {
                    if asset.isVideo {
                        AuthenticatedVideo(api: api, assetID: asset.id, active: scenePhase == .active).id(asset.id)
                    } else {
                        SlideshowStill(pipeline: pipeline, asset: asset, look: "contain", onReady: { readyAssetID = asset.id }, onFailure: { readyAssetID = nil })
                            .id(asset.id + asset.cacheRevision)
                            .overlay {
                                if readyAssetID == asset.id { HStack(spacing: 0) {
                                    Button { cursor.previous(counts: counts) } label: { Color.clear.contentShape(Rectangle()) }.accessibilityLabel("Previous photo")
                                    Button { cursor.next(counts: counts) } label: { Color.clear.contentShape(Rectangle()) }.accessibilityLabel("Next photo")
                                }.buttonStyle(.plain) }
                            }
                    }
                }.contentShape(Rectangle()).simultaneousGesture(navigationGesture)
                VStack(spacing: 16) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(title(memory)).font(.subheadline).foregroundStyle(.secondary)
                            if let date = asset.fileCreatedAt { Text(date, format: .dateTime.year().month(.wide).day()).font(.headline) }
                        }
                        Spacer(minLength: 12)
                        Menu {
                            Button("Open photo", systemImage: "arrow.up.right.square") { onNavigate(.openAsset(asset)) }
                            Button("Show in timeline", systemImage: "calendar") { onNavigate(.showInTimeline(asset)) }
                        } label: {
                            Image(systemName: "ellipsis").frame(width: 44, height: 44)
                        }.accessibilityLabel("Memory photo actions")
                    }
                    GlassEffectContainer { HStack(spacing: 30) {
                        Button("Previous memory", systemImage: "chevron.up") { cursor.previousMemory(counts: counts) }.labelStyle(.iconOnly).disabled(cursor.memory == 0)
                        Button("Previous photo", systemImage: "chevron.left") { cursor.previous(counts: counts) }.labelStyle(.iconOnly).disabled(cursor.memory == 0 && cursor.asset == 0)
                        Button("Next photo", systemImage: "chevron.right") { cursor.next(counts: counts) }.labelStyle(.iconOnly)
                            .accessibilityIdentifier("memories.nextPhoto")
                        Button("Next memory", systemImage: "chevron.down") { cursor.nextMemory(counts: counts) }.labelStyle(.iconOnly)
                    }.buttonStyle(.glass).controlSize(.large) }
                }.padding(22)
            } else {
                Spacer()
                VStack(spacing: 20) {
                    Image(systemName: "checkmark.circle").font(.system(size: 56, weight: .light)).accessibilityHidden(true)
                    Text(available.isEmpty ? "No memories to show" : "You’re all caught up").font(.title2.weight(.semibold))
                    Text("Check back tomorrow for more moments.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                    GlassEffectContainer { VStack(spacing: 16) {
                        if !available.isEmpty { Button("Start over") { cursor = MemoryCursor() }.buttonStyle(.glass) }
                        Button("Close") { dismiss() }.buttonStyle(.glass)
                    } }
                }.padding(28).contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 70).onEnded { value in if value.translation.height < -70 { dismiss() } })
                Spacer()
            }
        }
        .foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black).preferredColorScheme(.dark).statusBarHidden()
        .onAppear {
            guard !initialized else { return }; initialized = true
            cursor.memory = initialID.flatMap { id in available.firstIndex { $0.id == id } } ?? 0
            oldIdleTimer = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = oldIdleTimer }
        .onChange(of: asset?.id) { _, _ in readyAssetID = nil }
        .task(id: asset?.id) {
            var next = cursor; next.next(counts: counts)
            guard available.indices.contains(next.memory), available[next.memory].assets.indices.contains(next.asset) else { return }
            let asset = available[next.memory].assets[next.asset]
            guard !asset.isVideo else { return }
            _ = try? await pipeline.image(for: asset, size: .preview, pixelSize: 2200)
        }
    }
    private var navigationGesture: some Gesture {
        DragGesture(minimumDistance: 50).onEnded { gesture in
            let translation = gesture.translation
            if abs(translation.height) > abs(translation.width) {
                if translation.height < -70 { cursor.nextMemory(counts: counts) }
                else if translation.height > 70 { cursor.previousMemory(counts: counts) }
            } else if translation.width < -70 { cursor.next(counts: counts) }
            else if translation.width > 70 { cursor.previous(counts: counts) }
        }
    }
    private func title(_ memory: Memory) -> String {
        memory.data.personName ?? (memory.memoryAt.formatted(.dateTime.month(.wide).day()) + " · " + String(memory.data.year))
    }
}

private struct MemoryProgress: View {
    let count: Int
    let selected: Int
    var body: some View {
        Canvas { context, size in
            guard count > 0 else { return }
            let gap = min(2, size.width / Double(count) / 4)
            let width = (size.width - gap * Double(count - 1)) / Double(count)
            for index in 0..<count {
                let rect = CGRect(x: Double(index) * (width + gap), y: 0, width: width, height: size.height)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(index <= selected ? .white : .white.opacity(0.25)))
            }
        }.accessibilityElement().accessibilityLabel("Memory progress").accessibilityValue("Photo \(selected + 1) of \(count)")
    }
}
