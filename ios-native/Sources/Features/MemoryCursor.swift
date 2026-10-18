import Foundation

struct MemoryCursor: Equatable {
    var memory = 0
    var asset = 0
    mutating func next(counts: [Int]) {
        guard counts.indices.contains(memory) else { return }
        if asset + 1 < counts[memory] { asset += 1 } else { nextMemory(counts: counts) }
    }
    mutating func previous(counts: [Int]) {
        guard !counts.isEmpty else { self = Self(); return }
        if asset > 0 { asset -= 1 }
        else if memory > 0 { memory = min(memory - 1, counts.count - 1); asset = max(0, counts[memory] - 1) }
    }
    mutating func nextMemory(counts: [Int]) { memory = min(memory + 1, counts.count); asset = 0 }
    mutating func previousMemory(counts: [Int]) { memory = max(0, min(memory - 1, counts.count - 1)); asset = 0 }
}
