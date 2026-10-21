import SwiftUI

extension EnvironmentValues {
    /// What the signed-in account may do. The app sets it at its root from SessionStore, so the
    /// views below follow a read-only change in the same frame. Nil while nobody is signed in.
    @Entry var authorization: AuthorizationSnapshot? = nil
}

/// Disables a mutation affordance while leaving navigation and media browsing usable. It reads the
/// account's authorization from the environment: no Keychain read and no polling.
/// APIClient/backup enforce the same policy again immediately before sending writes.
private struct WriteAccessModifier: ViewModifier {
    let applies: Bool
    @Environment(\.authorization) private var authorization

    func body(content: Content) -> some View {
        // With nobody signed in there is nothing to change.
        content.disabled(applies && authorization?.readOnly != false)
    }
}

extension View {
    func requiresWriteAccess(when applies: Bool = true) -> some View {
        modifier(WriteAccessModifier(applies: applies))
    }
}
