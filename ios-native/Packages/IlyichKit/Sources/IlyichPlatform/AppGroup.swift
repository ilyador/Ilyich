import Foundation
import os

/// The App Group the app and its extensions share. Its identifier comes from the bundle's
/// AppGroupId key and is never written down here: the sideloading tool rewrites the bundle's
/// identifiers when it signs the app.
public enum AppGroup {
    /// This bundle's App Group.
    public static var identifier: String {
        get throws(AppGroupError) { try resolved.get() }
    }

    /// Whether the bundle names an App Group at all, usable or not.
    public static var isDeclared: Bool { Bundle.main.object(forInfoDictionaryKey: infoKey) != nil }

    /// The group's shared preferences, or nil when the group is unavailable.
    public static var defaults: UserDefaults? {
        guard let group = try? identifier else { return nil }
        return UserDefaults(suiteName: group)
    }

    /// Checks an AppGroupId value. A build setting left unexpanded counts as missing.
    public static func identifier(from value: Any?) throws(AppGroupError) -> String {
        guard let group = value as? String, group.hasPrefix("group."), !group.contains("$(") else { throw .unavailable }
        return group
    }

    private static let infoKey = "AppGroupId"

    /// Read once per process and logged, so the device console shows which group a re-signed
    /// build resolved.
    private static let resolved: Result<String, AppGroupError> = {
        let logger = Logger(subsystem: "app.ilyich.native", category: "AppGroup")
        let value = Bundle.main.object(forInfoDictionaryKey: infoKey)
        do throws(AppGroupError) {
            let group = try identifier(from: value)
            let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
            logger.notice("App Group \(group, privacy: .public) resolved, container \(container?.path ?? "unavailable", privacy: .public)")
            return .success(group)
        } catch {
            logger.error("App Group unavailable: AppGroupId is \(String(describing: value), privacy: .public)")
            return .failure(error)
        }
    }()
}

/// The bundle names no usable App Group, so the app is signed wrongly.
public enum AppGroupError: LocalizedError, Equatable, Sendable {
    case unavailable

    public var errorDescription: String? { "The app’s shared storage is unavailable. Check the app’s signing and reinstall." }
}

/// Files in the App Group container, named by their path below it. The container's absolute
/// path is not stable: iOS reports it under /var or /private/var, and a reinstall can move it
/// to a new UUID.
public struct AppGroupLayout: Sendable {
    /// Top-level folders whose files earlier formats recorded by absolute path.
    public static let recordedFolders = ["Backup", "ShareInbox"]

    public let container: URL

    public init(container: URL) { self.container = container }

    /// This bundle's App Group container.
    public static func current() throws(AppGroupError) -> AppGroupLayout {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: try AppGroup.identifier) else {
            throw .unavailable
        }
        return AppGroupLayout(container: container)
    }

    /// A recorded file's path from its Backup or ShareInbox folder on, or nil for a file
    /// outside both. Whatever precedes that folder is the old container path and is ignored.
    public static func relativePath(of url: URL) -> String? {
        guard url.isFileURL else { return nil }
        let components = url.standardizedFileURL.pathComponents
        guard let start = components.firstIndex(where: { recordedFolders.contains($0) }), start < components.count - 1 else { return nil }
        return components[start...].joined(separator: "/")
    }

    /// The file a recorded URL names, in this container.
    public func resolve(_ recorded: URL) -> URL? {
        Self.relativePath(of: recorded).map(url(forRelativePath:))
    }

    /// A file in this container.
    public func url(forRelativePath path: String) -> URL {
        container.appendingPathComponent(path, isDirectory: false)
    }
}
