import SwiftUI

enum AppearanceAccent: String, CaseIterable, Identifiable {
    static let storageKey = "appearanceAccent"

    case design, indigo, purple, pink, red, orange, yellow, lime, green, cyan, slate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .design: "Ilyich"
        case .indigo: "Indigo"
        case .purple: "Deep purple"
        case .pink: "Pink"
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .lime: "Lime"
        case .green: "Green"
        case .cyan: "Cyan"
        case .slate: "Slate gray"
        }
    }

    /// App-wide tint. The design default keeps the neutral primary tint.
    var tint: Color {
        switch self {
        case .design: .primary
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .lime: Color(red: 0.55, green: 0.80, blue: 0.10)
        case .green: .green
        case .cyan: .cyan
        case .slate: Color(red: 0.44, green: 0.50, blue: 0.56)
        }
    }

    /// Tint for selected controls. The design default keeps the approved cyan.
    var selectionTint: Color { self == .design ? .cyan : tint }
}

/// Gives native switches a legible, user-selected on color without changing link or toolbar tint.
struct AccentSwitchStyle: ToggleStyle {
    var accent: AppearanceAccent

    func makeBody(configuration: Configuration) -> some View {
        Toggle(isOn: configuration.$isOn) { configuration.label }
            .toggleStyle(.switch)
            .tint(accent.selectionTint)
    }
}

/// Applies the app's control appearance at each independently hosted SwiftUI root.
/// SwiftUI presentations and UIKit-hosted screens do not reliably inherit these modifiers.
struct AppControlAppearance: ViewModifier {
    @AppStorage(AppearanceAccent.storageKey) private var accentName = AppearanceAccent.design.rawValue

    private var accent: AppearanceAccent { AppearanceAccent(rawValue: accentName) ?? .design }

    func body(content: Content) -> some View {
        content
            .tint(accent.tint)
            .toggleStyle(AccentSwitchStyle(accent: accent))
    }
}

extension View {
    func appControlAppearance() -> some View {
        modifier(AppControlAppearance())
    }
}
