import Foundation
import Synchronization

/// Grid thumbnails decoded in memory, least recently used out first, within a budget of
/// min(128 MB, RAM / 64). One image serves every cell up to the size it was decoded for, so a
/// density change or another screen reuses it instead of decoding again; a thumbnail decoded at
/// its file's own size, because the cell is larger, serves every cell.
///
/// Photos on screen are pinned: the budget and a memory warning evict around them. Forgetting a
/// photo removes its images and no other. Reads are synchronous and safe from any thread, so a
/// cell draws a cached image in its first frame.
final class DecodedThumbnailCache: Sendable {
    let budget: Int
    let countLimit: Int

    private struct Node {
        let assetID: String
        let revision: String
        /// The largest cell short side, in pixels, this image covers.
        let serves: Int
        let image: PreparedImage
        let cost: Int
        var newer: UInt64?
        var older: UInt64?
    }
    private struct State {
        var nodes: [UInt64: Node] = [:]
        var byAsset: [String: [UInt64]] = [:]
        var newest: UInt64?
        var oldest: UInt64?
        var cost = 0
        var next: UInt64 = 0
        var pins: [String: Int] = [:]
    }
    private let state = Mutex(State())
    private let pressure: DispatchSourceMemoryPressure

    static var defaultBudget: Int { min(128 * 1024 * 1024, Int(ProcessInfo.processInfo.physicalMemory / 64)) }

    init(budget: Int = DecodedThumbnailCache.defaultBudget, countLimit: Int = 4_000) {
        self.budget = budget
        self.countLimit = countLimit
        pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        pressure.setEventHandler { [weak self] in self?.trimUnpinned() }
        pressure.activate()
    }

    deinit { pressure.cancel() }

    // MARK: Reads

    /// The image that covers a cell of `shortSide` pixels: the smallest one that does.
    func image(assetID: String, revision: String, shortSide: Int) -> PreparedImage? {
        state.withLock { state in
            var best: (UInt64, Node)?
            for id in state.byAsset[assetID] ?? [] {
                guard let node = state.nodes[id], node.revision == revision, node.serves >= shortSide else { continue }
                if best.map({ node.serves < $0.1.serves }) ?? true { best = (id, node) }
            }
            guard let best else { return nil }
            Self.moveToFront(best.0, &state)
            return best.1.image
        }
    }

    /// The sharpest image of the photo, at `revision` or, without one, at any.
    func largest(assetID: String, revision: String?) -> PreparedImage? {
        state.withLock { state in
            var best: Node?
            for id in state.byAsset[assetID] ?? [] {
                guard let node = state.nodes[id], revision == nil || node.revision == revision else { continue }
                if best.map({ node.serves > $0.serves }) ?? true { best = node }
            }
            return best?.image
        }
    }

    var count: Int { state.withLock { $0.nodes.count } }
    var cost: Int { state.withLock { $0.cost } }

    // MARK: Writes

    /// Keeps `image`, decoded for cells of `shortSide` pixels, unless `admits` refuses it. `admits`
    /// runs under the cache's lock, so a photo forgotten meanwhile is never kept.
    func insert(_ image: PreparedImage, assetID: String, revision: String, shortSide: Int, admits: () -> Bool = { true }) {
        let imageShort = min(image.cgImage.width, image.cgImage.height)
        // Smaller than asked for means the file itself is that small: no decode gets sharper.
        let serves = imageShort + 1 < shortSide ? Int.max : max(shortSide, imageShort)
        state.withLock { state in
            guard admits() else { return }
            for id in state.byAsset[assetID] ?? [] {
                guard let node = state.nodes[id] else { continue }
                if node.revision == revision && node.serves >= serves {
                    Self.moveToFront(id, &state); return
                }
            }
            // Older revisions and smaller copies are useless now.
            for id in state.byAsset[assetID] ?? [] {
                if let node = state.nodes[id], node.revision != revision || node.serves < serves { Self.remove(id, &state) }
            }
            let id = state.next
            state.next &+= 1
            state.nodes[id] = Node(assetID: assetID, revision: revision, serves: serves, image: image, cost: image.byteCost)
            state.byAsset[assetID, default: []].append(id)
            state.cost += image.byteCost
            Self.link(id, &state)
            evict(&state)
        }
    }

    /// Every image of these photos goes; nothing else does.
    func forget(_ assetIDs: some Sequence<String>) {
        state.withLock { state in
            for assetID in assetIDs {
                for id in state.byAsset[assetID] ?? [] { Self.remove(id, &state) }
            }
        }
    }

    /// The photo's thumbnail was made again: images of other revisions go.
    func refresh(assetID: String, revision: String) {
        state.withLock { state in
            for id in state.byAsset[assetID] ?? [] where state.nodes[id]?.revision != revision { Self.remove(id, &state) }
        }
    }

    func removeAll() {
        state.withLock { state in
            let pins = state.pins
            state = State()
            state.pins = pins
        }
    }

    /// A memory warning: everything not on screen goes.
    func trimUnpinned() {
        state.withLock { state in
            for (id, node) in state.nodes where state.pins[node.assetID] == nil { Self.remove(id, &state) }
        }
    }

    // MARK: Pins

    func pin(_ assetID: String) {
        state.withLock { $0.pins[assetID, default: 0] += 1 }
    }

    func unpin(_ assetID: String) {
        state.withLock { state in
            guard let count = state.pins[assetID] else { return }
            state.pins[assetID] = count > 1 ? count - 1 : nil
        }
    }

    // MARK: The recency list

    private func evict(_ state: inout State) {
        var cursor = state.oldest
        while let id = cursor, state.cost > budget || state.nodes.count > countLimit {
            guard let node = state.nodes[id] else { break }
            cursor = node.newer
            if state.pins[node.assetID] == nil { Self.remove(id, &state) }
        }
    }

    private static func link(_ id: UInt64, _ state: inout State) {
        state.nodes[id]?.older = state.newest
        state.nodes[id]?.newer = nil
        if let newest = state.newest { state.nodes[newest]?.newer = id }
        state.newest = id
        if state.oldest == nil { state.oldest = id }
    }

    private static func unlink(_ id: UInt64, _ state: inout State) {
        guard let node = state.nodes[id] else { return }
        if let newer = node.newer { state.nodes[newer]?.older = node.older } else { state.newest = node.older }
        if let older = node.older { state.nodes[older]?.newer = node.newer } else { state.oldest = node.newer }
        state.nodes[id]?.newer = nil
        state.nodes[id]?.older = nil
    }

    private static func moveToFront(_ id: UInt64, _ state: inout State) {
        guard state.newest != id else { return }
        unlink(id, &state)
        link(id, &state)
    }

    private static func remove(_ id: UInt64, _ state: inout State) {
        guard let node = state.nodes[id] else { return }
        unlink(id, &state)
        state.nodes[id] = nil
        state.cost -= node.cost
        if var ids = state.byAsset[node.assetID] {
            ids.removeAll { $0 == id }
            state.byAsset[node.assetID] = ids.isEmpty ? nil : ids
        }
    }
}
