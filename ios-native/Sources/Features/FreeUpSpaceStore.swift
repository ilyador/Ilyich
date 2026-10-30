import Foundation
import IlyichPlatform
import Observation
import Photos
import SwiftUI

extension EnvironmentValues {
    /// The signed-in account's Free up space. The app sets it at its root; nil while nobody is
    /// signed in.
    @Entry var freeUpSpace: FreeUpSpaceStore? = nil
}

/// What Free up space shows and the commands it sends, one per account (REBUILD_ROADMAP.md P4).
/// The account's CleanupService does the checking and removing; this follows its events, and the
/// adapter's results, so a candidate that changes leaves the screen at once.
@MainActor @Observable final class FreeUpSpaceStore {
    /// Backed-up photos kept for one reason.
    struct ExclusionGroup: Identifiable, Hashable {
        let exclusion: CleanupExclusion
        let ids: [String]
        var id: CleanupExclusion { exclusion }
    }

    private(set) var permission: PHAuthorizationStatus
    private(set) var albums: [DeviceAlbum] = []
    private(set) var filtersReady = false
    private(set) var cutoff: Date
    private(set) var keepFavorites: Bool
    private(set) var keepMediaType: String
    private(set) var keptAlbumIDs: Set<String>
    private(set) var checking = false
    private(set) var checked = false
    private(set) var removing = false
    /// The candidates, newest first.
    private(set) var candidates: [LocalPhoto] = []
    private(set) var exclusions: [ExclusionGroup] = []
    var selection = Set<String>()
    private(set) var message: String?
    var failure: String?

    /// Removal stays unavailable until the owner's device test (CleanupRemovalGate).
    var removeAvailable: Bool { service.removalAllowed }

    @ObservationIgnored let service: CleanupService
    @ObservationIgnored private let settings: CleanupSettingsStore
    @ObservationIgnored private let adapter: PhotoKitAdapter
    @ObservationIgnored private var sizes: [String: Int64?] = [:]
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var following: [Task<Void, Never>] = []
    @ObservationIgnored private let now: @Sendable () -> Date
    /// The check on screen, so one dropped as a whole while the screen wasn't following is seen.
    @ObservationIgnored private var scanID: UUID?
    /// The owner picked a cutoff that isn't saved yet. Until then it is the saved number of days
    /// before today, worked out again each time, so it never drifts as days pass.
    @ObservationIgnored private var cutoffEdited = false

    init(service: CleanupService, settings: CleanupSettingsStore = CleanupSettingsStore(), adapter: PhotoKitAdapter = .shared,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.service = service
        self.settings = settings
        self.adapter = adapter
        self.now = now
        let saved = settings.load()
        permission = adapter.authorization
        cutoff = saved.cutoff(now: now())
        keepFavorites = saved.keepFavorites
        keepMediaType = saved.keepMediaType
        keptAlbumIDs = saved.keptAlbumIDs ?? []
    }

    // MARK: Showing

    /// While the screen shows: reads the filters, and follows the service and Photos' results.
    func appear() async {
        if following.isEmpty {
            let service = service, adapter = adapter
            following.append(Task { [weak self] in
                for await event in await service.events() { self?.apply(event) }
            })
            following.append(Task { [weak self] in
                for await result in adapter.mutations() {
                    if case .committed(let affected, _) = result.outcome { self?.drop(Set(affected.map(\.rawValue))) }
                }
            })
        }
        // Back from another screen: what changed meanwhile is no longer offered, and a check
        // dropped as a whole meanwhile asks to be made again.
        if checked, !checking {
            if await service.currentScanID != scanID {
                clear(); message = Self.checkAgain
            } else {
                let live = await service.liveCandidates
                drop(Set(candidates.map(\.id)).subtracting(live))
            }
        }
        await refreshFilters()
        // The results on screen were found with the cutoff shown, so it stays while they do.
        if !checked, !checking, !cutoffEdited { cutoff = settings.load().cutoff(now: now()) }
        filtersReady = true
    }

    func disappear() {
        operation?.cancel(); operation = nil
        for task in following { task.cancel() }
        following = []
    }

    /// Access and albums again, and once with access the albums of messaging apps kept.
    func refreshFilters() async {
        permission = adapter.authorization
        albums = await adapter.albums()
        if PhotoKitAdapter.canRead(permission), let kept = settings.applyMessagingDefaults(albums: albums) { keptAlbumIDs = kept }
    }

    func requestAccess() async {
        permission = await adapter.requestAccess().status
        await refreshFilters()
    }

    /// The originals' size of `ids`, or of every candidate when empty; nil when any is unknown.
    func originalsSize(of ids: Set<String>) -> Int64? {
        var total: Int64 = 0
        for id in ids.isEmpty ? Set(candidates.map(\.id)) : ids {
            guard let bytes = sizes[id] ?? nil else { return nil }
            let (sum, overflow) = total.addingReportingOverflow(bytes)
            guard !overflow else { return nil }
            total = sum
        }
        return total
    }

    /// The phone photos among `ids`, for a list of those kept for one reason.
    func photos(_ ids: [String]) async -> [LocalPhoto] { await adapter.photos(withIDs: ids) }

    // MARK: Settings

    func setCutoff(_ date: Date) { guard date != cutoff else { return }; cutoff = date; cutoffEdited = true; invalidate() }

    func setKeepFavorites(_ value: Bool) {
        guard value != keepFavorites else { return }
        keepFavorites = value; settings.setKeepFavorites(value); invalidate()
    }

    func setKeepMediaType(_ value: String) {
        guard value != keepMediaType else { return }
        keepMediaType = value; settings.setKeepMediaType(value); invalidate()
    }

    func setKept(_ albumID: String, _ kept: Bool) {
        var ids = keptAlbumIDs
        if kept { ids.insert(albumID) } else { ids.remove(albumID) }
        guard ids != keptAlbumIDs else { return }
        keptAlbumIDs = ids; settings.setKeptAlbumIDs(ids); invalidate()
    }

    /// A setting changed: nothing checked before holds.
    private func invalidate() {
        operation?.cancel(); operation = nil
        clear()
        let service = service
        Task { await service.invalidate() }
    }

    private func clear() {
        selection = []; candidates = []; exclusions = []; sizes = [:]; checked = false; message = nil; scanID = nil
    }

    // MARK: Commands

    /// Starts a check; the task is for tests to wait on.
    @discardableResult func check() -> Task<Void, Never>? {
        guard !checking, !removing else { return nil }
        operation?.cancel()
        let task = Task { await runCheck() }
        operation = task
        return task
    }

    private func runCheck() async {
        checking = true; defer { checking = false }
        clear()
        guard PhotoKitAdapter.canRead(adapter.authorization) else { failure = CleanupCheckError.photosAccess.errorDescription; return }
        if !cutoffEdited { cutoff = settings.load().cutoff(now: now()) }
        settings.setCutoffDaysAgo(max(0, Calendar.current.dateComponents([.day], from: cutoff, to: now()).day ?? 0))
        cutoffEdited = false
        do {
            let result = try await service.scan(cutoff: cutoff)
            let photos = await adapter.photos(withIDs: result.candidates.map(\.localID))
            try Task.checkCancellation()
            // A candidate dropped while its photo was read stays dropped.
            let live = await service.liveCandidates
            try Task.checkCancellation()
            candidates = photos.filter { live.contains($0.id) }
            sizes = Dictionary(result.candidates.map { ($0.localID, $0.originalBytes) }, uniquingKeysWith: { first, _ in first })
            exclusions = Dictionary(grouping: result.exclusions, by: \.value)
                .map { ExclusionGroup(exclusion: $0.key, ids: $0.value.map(\.key).sorted()) }
                .sorted { $0.ids.count == $1.ids.count ? $0.exclusion.rawValue < $1.exclusion.rawValue : $0.ids.count > $1.ids.count }
            scanID = result.id
            checked = true
        } catch is CancellationError {
        } catch { failure = error.localizedDescription }
    }

    func remove() {
        guard removeAvailable, !selection.isEmpty, !removing, !checking else { return }
        operation = Task { await runRemove() }
    }

    private func runRemove() async {
        removing = true; defer { removing = false }
        let requested = selection
        // Once asked, Photos finishes the removal even if this screen goes, and the journal keeps how it ended.
        switch await service.remove(requested) {
        case .removed(let ids):
            drop(Set(ids)); selection = []
            message = "Removed \(ids.count) item\(ids.count == 1 ? "" : "s") from Apple Photos. Your server copies are kept."
        case .declined:
            // Declining iOS's prompt is the person's answer, not an error. Nothing was removed.
            break
        case .changed(let ids):
            drop(ids)
            failure = "A photo or its backup changed since you reviewed it. Nothing was removed. Check again before continuing."
        case .blocked(.readOnly):
            failure = ReadOnlyPolicy.ReadOnlyError().errorDescription
        case .blocked(.sessionChanged):
            clear(); failure = "Your account or session changed. Nothing was removed. Check again before continuing."
        case .blocked(.checkAgain):
            clear(); failure = "Your photo library changed. Nothing was removed. Check again before continuing."
        case .blocked(.unavailable):
            break
        case .failed(let reason):
            failure = reason
        }
    }

    // MARK: Changes

    private func apply(_ event: CleanupEvent) {
        switch event {
        case .dropped(let ids): drop(ids)
        case .invalidated(.settings): break
        case .invalidated:
            guard checked || checking else { return }
            operation?.cancel(); operation = nil
            clear(); message = Self.checkAgain
        }
    }

    private static let checkAgain = "Your account, Photos access or library changed. Check again."

    private func drop(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        candidates.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        for id in ids { sizes[id] = nil }
    }
}
