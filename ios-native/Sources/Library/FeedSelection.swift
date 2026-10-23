import Foundation
import Observation

/// What is selected in the feed shown (REBUILD_ROADMAP.md F6), and selecting a whole month
/// through the feed. The feed store owns it and clears it when the scope changes; the grid, its
/// sideways drag, the selection bar and the month menu read and change it.
///
/// A selected photo is named as the grid names it: a server photo by its ID, a photo only the
/// phone has by "local:" and its ID. Each is recorded as it was when it was selected, so a month
/// the feed lets go, or the drag passed before it loaded, still says what was selected; a server
/// photo's copy on the phone is kept beside it, for actions that need the phone's file.
@MainActor @Observable final class FeedSelection {
    var selected: Set<String> = [] {
        didSet {
            records = records.filter { selected.contains($0.key) }
            localRecords = localRecords.filter { selected.contains("local:" + $0.key) }
            matchedCopies = matchedCopies.filter { selected.contains($0.key) }
        }
    }
    var isSelecting = false {
        didSet { if !isSelecting { monthTask?.cancel(); setSelectingMonth(false) } }
    }
    /// A whole month is being read to be selected or deselected.
    private(set) var isSelectingMonth = false

    /// The selected server photos, by ID.
    private var records: [String: Asset] = [:]
    /// The selected photos only the phone has, by their own ID.
    private var localRecords: [String: LocalPhoto] = [:]
    /// The phone's copies of selected server photos, by the server photo's ID.
    private var matchedCopies: [String: LocalPhoto] = [:]
    @ObservationIgnored private var monthTask: Task<Void, Never>?
    /// Names the month selection on its way; one cancelled or overtaken changes nothing when it ends.
    @ObservationIgnored private var monthOperation = UUID()

    /// The selected photos only the phone has.
    var localPhotos: [LocalPhoto] { Array(localRecords.values) }
    /// Every phone photo the selection holds: those only the phone has and the copies of server photos.
    var devicePhotos: [LocalPhoto] {
        var seen = Set<String>()
        return (Array(localRecords.values) + Array(matchedCopies.values)).filter { seen.insert($0.id).inserted }
    }

    /// The selected server photos, as recorded when they were selected. A photo selected by its ID
    /// alone, with no record, is looked for among `rows`, which are read only then.
    func assets(among rows: () -> [Asset]) -> [Asset] {
        var assets = Array(records.values)
        let unrecorded = selected.filter { records[$0] == nil && !$0.hasPrefix("local:") }
        guard !unrecorded.isEmpty else { return assets }
        var seen = Set(records.keys)
        for asset in rows() where unrecorded.contains(asset.id) && seen.insert(asset.id).inserted { assets.append(asset) }
        return assets
    }

    func toggle(_ asset: Asset) {
        if selected.contains(asset.id) { selected.remove(asset.id) }
        else { selected.insert(asset.id); records[asset.id] = asset }
    }

    func select(_ asset: Asset) { selected.insert(asset.id); records[asset.id] = asset }

    func toggle(_ entry: LibraryEntry) {
        if let asset = entry.remote {
            toggle(asset)
            if selected.contains(asset.id), let local = entry.local { matchedCopies[asset.id] = local }
            return
        }
        guard let photo = entry.local else { return }
        if selected.contains(entry.id) { selected.remove(entry.id) }
        else { selected.insert(entry.id); localRecords[photo.id] = photo }
    }

    func select(_ entry: LibraryEntry) {
        if let asset = entry.remote { select(asset); if let local = entry.local { matchedCopies[asset.id] = local } }
        else if let photo = entry.local { selected.insert(entry.id); localRecords[photo.id] = photo }
    }

    /// One step of a drag across the grid, applied as a single change: the records are filtered
    /// once per step, not once per photo.
    func change(adding: [LibraryEntry], removing: [LibraryEntry]) {
        guard !adding.isEmpty || !removing.isEmpty else { return }
        record(adding)
        var next = selected
        next.subtract(removing.map(\.id))
        next.formUnion(adding.map(\.id))
        selected = next
    }

    /// Selects or deselects a whole month. `month` reads every photo of it through the feed, the
    /// photos the grid has let go or never loaded included, so a virtualized grid never selects
    /// only the cells it happens to hold; it answers nil when the feed has moved on, and then
    /// nothing changes. One month at a time, and only while selecting; leaving selection, or the
    /// feed cancelling it, drops the month on its way. A failure goes to `failed`.
    func selectMonth(_ selecting: Bool, reading month: @escaping @MainActor () async throws -> [LibraryEntry]?,
                     failed: @escaping @MainActor (any Error) -> Void) {
        guard isSelecting, !isSelectingMonth else { return }
        let operation = UUID()
        monthOperation = operation
        setSelectingMonth(true)
        monthTask = Task {
            defer { if monthOperation == operation { setSelectingMonth(false) } }
            do {
                guard let entries = try await month() else { return }
                try Task.checkCancellation()
                guard isSelecting else { return }
                let ids = Set(entries.map(\.id))
                if selecting {
                    record(entries)
                    selected.formUnion(ids)
                } else {
                    selected.subtract(ids)
                }
            } catch is CancellationError {
            } catch {
                failed(error)
            }
        }
    }

    /// Drops the month selection on its way, as the feed does when it changes under it.
    func cancelMonthSelection() {
        monthTask?.cancel()
        monthOperation = UUID()
        setSelectingMonth(false)
    }

    /// Nothing selected, and selection over.
    func clear() {
        selected = []
        isSelecting = false
    }

    private func record(_ entries: [LibraryEntry]) {
        for entry in entries {
            if let asset = entry.remote {
                records[asset.id] = asset
                if let local = entry.local { matchedCopies[asset.id] = local }
            } else if let photo = entry.local {
                localRecords[photo.id] = photo
            }
        }
    }

    /// Changes the flag only when it changes, so a sync's reload doesn't redraw the selection title.
    private func setSelectingMonth(_ value: Bool) {
        if isSelectingMonth != value { isSelectingMonth = value }
    }
}
