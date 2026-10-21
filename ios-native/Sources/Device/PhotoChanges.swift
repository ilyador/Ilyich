import Foundation
import Synchronization

/// A phone asset as a change block, or a check made before one, reads it.
struct DeviceAssetState: Hashable, Sendable {
    let id: DeviceAssetID
    /// Nil when Photos reports no modification date.
    let revision: AssetRevision?
    let isFavorite: Bool
    let canDelete: Bool
    let canEditProperties: Bool
}

/// What a check found about the assets a change names.
enum PhotoChangeVerdict: Hashable, Sendable {
    case allowed
    /// An asset is gone, or isn't at the revision expected.
    case revisionChanged
    /// Photos doesn't allow this change to one of the assets.
    case notPermitted
}

/// The checks a change passes before Photos is asked, and again inside its change block. All or
/// nothing: one asset failing stops the whole change.
enum PhotoChangeChecks {
    static func verdict(for mutation: DeviceMutation, found: [DeviceAssetState]) -> PhotoChangeVerdict {
        switch mutation {
        case .delete(let ids, let expected, _): deletion(ids, expected: expected, found: found)
        case .setFavorite(let ids, _, let expected): favorite(ids, expected: expected, found: found)
        case .create: .allowed
        }
    }

    /// A deletion needs every asset, each at exactly the revision expected, and each deletable.
    /// An asset with no expected revision is never deleted.
    static func deletion(_ ids: [DeviceAssetID], expected: [DeviceAssetID: AssetRevision], found: [DeviceAssetState]) -> PhotoChangeVerdict {
        check(ids, found: found, permitted: \.canDelete) { id, state in
            guard let wanted = expected[id] else { return false }
            return state.revision == wanted
        }
    }

    /// Favoriting needs every asset, at the revision expected where one is named, and each
    /// editable.
    static func favorite(_ ids: [DeviceAssetID], expected: [DeviceAssetID: AssetRevision], found: [DeviceAssetState]) -> PhotoChangeVerdict {
        check(ids, found: found, permitted: \.canEditProperties) { id, state in
            guard let wanted = expected[id] else { return true }
            return state.revision == wanted
        }
    }

    private static func check(_ ids: [DeviceAssetID], found: [DeviceAssetState], permitted: KeyPath<DeviceAssetState, Bool>,
                              current: (DeviceAssetID, DeviceAssetState) -> Bool) -> PhotoChangeVerdict {
        guard !ids.isEmpty else { return .revisionChanged }
        let byID = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var states: [DeviceAssetState] = []
        for id in ids {
            guard let state = byID[id], current(id, state) else { return .revisionChanged }
            states.append(state)
        }
        return states.allSatisfy { $0[keyPath: permitted] } ? .allowed : .notPermitted
    }
}

/// What a change block found and asked for. The block writes it on Photos' queue; the adapter
/// reads it once Photos has answered.
final class ChangeReport: Sendable {
    struct Value: Equatable, Sendable {
        /// Nil until the block runs.
        var verdict: PhotoChangeVerdict?
        /// The block asked Photos for the change.
        var requested = false
        /// The assets a save made.
        var created: [DeviceAssetID] = []
    }

    private let state = Mutex(Value())

    init() {}

    var value: Value { state.withLock { $0 } }

    func found(_ verdict: PhotoChangeVerdict) { state.withLock { $0.verdict = verdict } }

    func requested(creating created: [DeviceAssetID] = []) {
        state.withLock { value in
            value.requested = true
            value.created = created
        }
    }
}

/// PhotoKit runs change blocks on its own queue. A block written inside an actor's method, or a
/// main-actor view's, inherits that isolation, and Swift 6 traps when PhotoKit calls it there.
/// So every block is built here, outside any actor, from Sendable values and a ChangeReport. Each
/// checks again, inside the change, what the change was told to expect, and asks Photos for
/// nothing unless every check holds.
enum PhotoChanges {
    nonisolated static func block(for mutation: DeviceMutation, library: any PhotoLibraryPerforming, assets: any AssetFetching,
                                  report: ChangeReport) -> @Sendable () -> Void {
        switch mutation {
        case .delete(let ids, let expected, _):
            delete(ids, expected: expected, library: library, assets: assets, report: report)
        case .setFavorite(let ids, let value, let expected):
            favorite(ids, value, expected: expected, library: library, assets: assets, report: report)
        case .create(let still, let video, let pairedVideo, _):
            create(still: still, video: video, pairedVideo: pairedVideo, library: library, report: report)
        }
    }

    nonisolated static func delete(_ ids: [DeviceAssetID], expected: [DeviceAssetID: AssetRevision], library: any PhotoLibraryPerforming,
                                   assets: any AssetFetching, report: ChangeReport) -> @Sendable () -> Void {
        {
            let verdict = PhotoChangeChecks.deletion(ids, expected: expected, found: assets.states(of: ids))
            report.found(verdict)
            guard verdict == .allowed else { return }
            library.requestDeletion(of: ids)
            report.requested()
        }
    }

    nonisolated static func favorite(_ ids: [DeviceAssetID], _ value: Bool, expected: [DeviceAssetID: AssetRevision],
                                     library: any PhotoLibraryPerforming, assets: any AssetFetching,
                                     report: ChangeReport) -> @Sendable () -> Void {
        {
            let verdict = PhotoChangeChecks.favorite(ids, expected: expected, found: assets.states(of: ids))
            report.found(verdict)
            guard verdict == .allowed else { return }
            library.requestFavorite(value, for: ids)
            report.requested()
        }
    }

    nonisolated static func create(still: URL?, video: URL?, pairedVideo: URL?, library: any PhotoLibraryPerforming,
                                   report: ChangeReport) -> @Sendable () -> Void {
        {
            report.found(.allowed)
            let created = library.requestCreation(still: still, video: video, pairedVideo: pairedVideo)
            report.requested(creating: created.map { [$0] } ?? [])
        }
    }
}
