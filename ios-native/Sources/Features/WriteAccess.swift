import SwiftUI

/// Disables a mutation affordance while leaving navigation and media browsing usable.
/// APIClient/backup enforce the same policy again immediately before sending writes.
private struct WriteAccessModifier: ViewModifier {
    let api: APIClient?
    let applies: Bool
    @State private var readOnly: Bool

    init(api: APIClient?, applies: Bool) {
        self.api = api; self.applies = applies
        _readOnly = State(initialValue: Self.isReadOnly(api))
    }
    func body(content: Content) -> some View {
        content.disabled(applies && readOnly)
            .onAppear { readOnly = Self.isReadOnly(api) }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in readOnly = Self.isReadOnly(api) }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in readOnly = Self.isReadOnly(api) }
    }
    private static func isReadOnly(_ api: APIClient?) -> Bool {
        if let api { return api.isReadOnly }
        guard let session = try? SessionKeychain.read() else { return true }
        return ReadOnlyPolicy.isEnabled(server: session.server, userID: session.userID)
    }
}

extension View {
    func requiresWriteAccess(_ api: APIClient? = nil, when applies: Bool = true) -> some View {
        modifier(WriteAccessModifier(api: api, applies: applies))
    }
}
