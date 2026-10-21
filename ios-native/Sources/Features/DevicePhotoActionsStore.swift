import Foundation
import IlyichPlatform
import Observation
import Photos

/// A change the phone-photo actions made to Photos.
enum DevicePhotoChange: Equatable, Sendable {
    case favorite(Bool)
    case removed([String])
}

/// The phone-photo actions for a selection: favorite and remove go through the Photos adapter,
/// which checks each photo again inside the change and journals it; backup adds them to the
/// queue and takes that call's own outcome; sharing prepares files with DeviceShareExporter.
@MainActor @Observable final class DevicePhotoActionsStore {
    /// The selection, as it was chosen. Removal holds each photo to the content it had then.
    let photos: [LocalPhoto]
    private(set) var busy = false
    private(set) var preparing = false
    private(set) var progress: Double?
    var failure: FeatureFailure?
    var share: LocalSharePackage?
    var showBackup = false
    /// Favorites as Photos holds them now, which the selection may predate.
    private var favorites: [String: Bool] = [:]
    var makeFavorite: Bool { !photos.allSatisfy { favorites[$0.id] ?? $0.isFavorite } }

    @ObservationIgnored private let device: any DevicePhotoActing
    @ObservationIgnored private let backup: any BackupEnqueuing
    @ObservationIgnored private let exporter: DeviceShareExporter
    @ObservationIgnored private let authorize: @MainActor () throws -> Void
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var exportFolder: URL?

    init(photos: [LocalPhoto], device: any DevicePhotoActing = PhotoKitAdapter.shared,
         backup: (any BackupEnqueuing)? = nil, exporter: DeviceShareExporter = .shared,
         authorize: @escaping @MainActor () throws -> Void = DevicePhotoActionsStore.requireWriteSession) {
        self.photos = photos
        self.device = device
        self.backup = backup ?? BackupCoordinator.shared
        self.exporter = exporter
        self.authorize = authorize
    }

    /// Signed in, and not in read-only mode.
    static func requireWriteSession() throws {
        guard let saved = try KeychainCredentialStore().load() else { throw APIError.signedOut }
        guard !ReadOnlyPolicy.isEnabled(server: saved.server, userID: saved.userID) else { throw ReadOnlyPolicy.ReadOnlyError() }
    }

    /// Reads the selection's favorites from Photos again.
    func refresh() async {
        let current = await device.photos(withIDs: photos.map(\.id))
        for photo in current { favorites[photo.id] = photo.isFavorite }
    }

    func favorite() async -> DevicePhotoChange? {
        guard !busy else { return nil }
        busy = true; defer { busy = false }
        do {
            try authorize(); let ids = try selectedIDs(), value = makeFavorite
            try Task.checkCancellation(); try authorize()
            switch await device.perform(.setFavorite(ids, value, expected: [:])).outcome {
            case .committed:
                for id in ids { favorites[id.rawValue] = value }
                return .favorite(value)
            case .declined, .interrupted: return nil
            case .revisionChanged: throw Self.unavailable
            case .notPermitted: throw BackupError.message("Photos does not allow changing one of the selected items.")
            case .failed(let reason): throw BackupError.message(reason)
            }
        } catch is CancellationError { } catch { failure = .init(error) }
        return nil
    }

    func remove() async -> DevicePhotoChange? {
        guard !busy else { return nil }
        busy = true; defer { busy = false }
        do {
            try authorize(); let ids = try selectedIDs()
            // Each photo must still show what it showed when chosen, or nothing is removed. A
            // favorite since then moved its revision but not its content.
            var expected: [DeviceAssetID: AssetRevision] = [:]
            for photo in photos {
                guard photo.modified != nil,
                      let revision = await device.currentRevision(of: photo.id, sameContentAs: photo.modified) else { throw Self.changed }
                expected[DeviceAssetID(rawValue: photo.id)] = revision
            }
            try Task.checkCancellation(); try authorize()
            switch await device.perform(.delete(ids, expected: expected, origin: .user)).outcome {
            case .committed: return .removed(ids.map(\.rawValue))
            // Declining iOS's prompt is the person's answer, not an error.
            case .declined, .interrupted: return nil
            case .revisionChanged: throw Self.changed
            case .notPermitted: throw BackupError.message("Photos does not allow removing one of the selected items.")
            case .failed(let reason): throw BackupError.message(reason)
            }
        } catch is CancellationError { } catch { failure = .init(error) }
        return nil
    }

    func backUp() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            try authorize(); try await requirePresent()
            switch await backup.enqueue(localIDs: photos.map(\.id), albumID: nil) {
            case .queued: showBackup = true
            case .failed(let message): throw BackupError.message(message)
            }
        } catch is CancellationError { } catch { failure = .init(error) }
    }

    func prepareShare(preview: Bool, allowCloud: Bool) async {
        guard !busy else { return }
        busy = true; preparing = true; progress = 0
        let token = UUID(); generation = token
        defer { if generation == token { busy = false; preparing = false } }
        do {
            try await requirePresent()
            let package = try await exporter.prepare(photos, preview: preview, allowCloud: allowCloud) { value in
                Task { @MainActor [weak self] in if self?.generation == token { self?.progress = value } }
            }
            guard generation == token, !Task.isCancelled else { await exporter.remove(package.folder); throw CancellationError() }
            exportFolder = package.folder; share = package
        } catch is CancellationError { } catch { if generation == token { failure = .init(error) } }
    }

    /// Removes the shared files once the share sheet closes.
    func cleanupShare() {
        guard let folder = exportFolder else { return }
        exportFolder = nil
        Task { [exporter] in await exporter.remove(folder) }
    }

    /// The screen went: anything still preparing is dropped, and files no sheet shows are removed.
    func abandon() {
        generation = UUID(); busy = false; preparing = false
        if share == nil { cleanupShare() }
    }

    /// The selection, once Photos access allows using it.
    private func selectedIDs() throws -> [DeviceAssetID] {
        guard PhotoKitAdapter.canRead(device.authorization) else { throw BackupError.message("Allow Photos access in Settings to use these items.") }
        let ids = photos.map(\.id)
        guard Set(ids).count == ids.count, !ids.isEmpty else { throw BackupError.message("Select the photos again before continuing.") }
        return ids.map { DeviceAssetID(rawValue: $0) }
    }

    /// Every selected photo is still in Photos.
    private func requirePresent() async throws {
        let ids = try selectedIDs().map(\.rawValue)
        let found = Set(await device.photos(withIDs: ids).map(\.id))
        guard ids.allSatisfy(found.contains) else { throw Self.unavailable }
    }

    private static let unavailable = BackupError.message("Some selected photos are no longer available. Refresh your selection and try again.")
    private static let changed = BackupError.message("A selected photo changed or is no longer available. Refresh your selection before removing it.")
}
