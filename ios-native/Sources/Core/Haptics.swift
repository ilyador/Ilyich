import UIKit

@MainActor enum Haptics {
    static func selectionChanged() {
        guard UserDefaults.standard.object(forKey: "hapticFeedback") as? Bool ?? true else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }
}
