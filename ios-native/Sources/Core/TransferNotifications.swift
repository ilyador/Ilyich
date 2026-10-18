import Foundation
import UserNotifications

/// Count-only local notifications for transfers the user started in Ilyich.
@MainActor enum TransferNotifications {
    private static let center = UNUserNotificationCenter.current()
    private static var epoch: UInt64 = 0

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    static func requestAuthorization() async throws -> UNAuthorizationStatus {
        _ = try await center.requestAuthorization(options: [.alert, .sound])
        return await authorizationStatus()
    }

    static func started(id: UUID, kind: String, total: Int) async {
        await post(id: id, title: "\(kind) started", body: count(total))
    }

    static func finished(id: UUID, kind: String, total: Int, completed: Int, failed: Int) async {
        let title = failed > 0 ? "\(kind) needs attention" : "\(kind) finished"
        let body = failed > 0
            ? "Completed \(completed.formatted()) of \(total.formatted()); \(failed.formatted()) need retry."
            : "Completed \(completed.formatted()) of \(total.formatted())."
        await post(id: id, title: title, body: body, terminal: true)
    }

    private static func count(_ value: Int) -> String {
        "\(value.formatted()) item\(value == 1 ? "" : "s")"
    }

    static func cancel(id: UUID) {
        let identifier = "transfer.\(id.uuidString)"
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    static func clearAll() async {
        epoch &+= 1
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    private static func post(id: UUID, title: String, body: String, terminal: Bool = false) async {
        let postingEpoch = epoch
        let settings = await center.notificationSettings()
        guard !Task.isCancelled, postingEpoch == epoch else { return }
        guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else { return }
        let identifier = "transfer.\(id.uuidString)"
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if terminal, settings.soundSetting == .enabled { content.sound = .default }
        do {
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        } catch { return }
        if Task.isCancelled || postingEpoch != epoch {
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
        }
    }
}
