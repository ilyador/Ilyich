import Observation
import SwiftUI

@MainActor @Observable final class MemoryLaneStore {
    private(set) var memories: [Memory] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private var loadedAt: Date?

    func load(api: APIClient, force: Bool = false) async {
        guard !isLoading else { return }
        if !force, let loadedAt, Calendar.current.isDateInToday(loadedAt), Date().timeIntervalSince(loadedAt) < 300 { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await api.memories(on: Date())
            try Task.checkCancellation()
            memories = result.filter { !$0.assets.isEmpty }
            loadedAt = Date(); error = nil
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}

/// A scrolling supplement to the library, not another floating control. It
/// disappears with the first rows, leaving the photo grid and native glass quiet.
struct MemoryLane: View {
    let pipeline: MediaPipeline
    let memories: [Memory]
    let onOpen: (Memory) -> Void

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(memories) { memory in
                        MemoryLaneCard(pipeline: pipeline, memory: memory, maxWidth: max(0, geometry.size.width - 32)) { onOpen(memory) }
                    }
                }.padding(.horizontal, 16).padding(.vertical, 10)
            }
            .scrollIndicators(.hidden)
        }
        .accessibilityIdentifier("library.memories")
    }
}

private struct MemoryLaneCard: View {
    let pipeline: MediaPipeline
    let memory: Memory
    let maxWidth: CGFloat
    let onOpen: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var cardWidth = 152.0
    private var title: String {
        if let person = memory.data.personName, !person.isEmpty { return person }
        let years = max(0, Calendar.current.component(.year, from: Date()) - memory.data.year)
        return years == 1 ? "1 year ago" : years > 1 ? "\(years) years ago" : "On this day"
    }

    var body: some View {
        Button(action: onOpen) {
            ZStack(alignment: .bottomLeading) {
                if let asset = memory.assets.first { FeatureAssetImage(pipeline: pipeline, asset: asset) }
                LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom)
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2).padding(12)
            }
            .frame(width: min(cardWidth, maxWidth)).frame(maxHeight: .infinity)
            .clipShape(.rect(cornerRadius: 18))
        }.buttonStyle(.plain)
        .accessibilityLabel("\(title), \(memory.assets.count) photos")
        .accessibilityHint("Open memory")
    }
}

@MainActor final class MemoryLaneHeader: UICollectionReusableView {
    private var hosted: (UIView & UIContentView)?

    func configure(pipeline: MediaPipeline, memories: [Memory], onOpen: @escaping (Memory) -> Void) {
        let configuration = UIHostingConfiguration { MemoryLane(pipeline: pipeline, memories: memories, onOpen: onOpen) }
            .margins(.all, 0)
        if let hosted { hosted.configuration = configuration }
        else {
            let view = configuration.makeContentView()
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor), view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor), view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            hosted = view
        }
    }
}
