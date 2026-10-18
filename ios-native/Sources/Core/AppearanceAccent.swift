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
