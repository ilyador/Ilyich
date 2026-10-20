import CoreHaptics
import UIKit

/// One vocabulary for the library: a light tick moves between items, a firmer tap opens or closes a
/// menu, a crisp tap chooses, rows come loose for reordering with a rising run of ticks, and the
/// Earth rumbles as it rises and sinks.
@MainActor enum Haptics {
    private static var enabled: Bool { UserDefaults.standard.object(forKey: "hapticFeedback") as? Bool ?? true }
    private static var engine: CHHapticEngine?
    private static var buildPlayer: CHHapticAdvancedPatternPlayer?
    private static var buildLevel: Float = 0
    /// The release stands alone: taps that would land right on top of it are skipped.
    private static var quietUntil: CFTimeInterval = 0

    /// Moving between items: shelf rows, timeline months, selections.
    static func selectionChanged() {
        guard enabled, CACurrentMediaTime() >= quietUntil else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// A rumble that rises with the glow at a shelf row's tip, sharper as it nears its peak;
    /// zero lets it fade out.
    static func buildUp(_ level: CGFloat) {
        let level = Float(min(1, max(0, level)))
        guard enabled, CHHapticEngine.capabilitiesForHardware().supportsHaptics, level > 0.01 else { stopBuildUp(); return }
        guard buildPlayer == nil || abs(level - buildLevel) > 0.02 else { return }
        do {
            if buildPlayer == nil {
                let engine = try startedEngine()
                let rumble = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.25)
                ], relativeTime: 0, duration: 30)
                let player = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: [rumble], parameters: []))
                try player.start(atTime: CHHapticTimeImmediate)
                buildPlayer = player
            }
            buildLevel = level
            try buildPlayer?.sendParameters([
                CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: 0.08 + 0.72 * level * level, relativeTime: 0),
                CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: -0.15 + 0.55 * level, relativeTime: 0)
            ], atTime: CHHapticTimeImmediate)
        } catch {
            buildPlayer = nil
        }
    }

    static func stopBuildUp() {
        guard let buildPlayer else { return }
        try? buildPlayer.stop(atTime: CHHapticTimeImmediate)
        self.buildPlayer = nil
        buildLevel = 0
    }

    /// The glow peaks and the row opens: the rumble gives way to one crisp click.
    static func released() {
        stopBuildUp()
        guard enabled else { return }
        quietUntil = CACurrentMediaTime() + 0.15
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { UIImpactFeedbackGenerator(style: .rigid).impactOccurred(); return }
        let click = CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.9)
        ], relativeTime: 0)
        let settle = CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.45),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3)
        ], relativeTime: 0.06)
        play([click, settle], curves: []) { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
    }
    /// Opening the shelves or a group within them.
    static func menuOpened() { impact(.medium) }
    /// Putting the shelves away.
    static func menuClosed() { impact(.soft, intensity: 0.7) }
    /// Choosing the highlighted shelf or a timeline year.
    static func itemChosen() { impact(.rigid) }
    /// Taking hold of the timeline.
    static func grabbed() { impact(.light, intensity: 0.8) }
    /// Dropping a reordered shelf row into place.
    static func rowDropped() { impact(.soft, intensity: 0.9) }

    /// The rows come loose for reordering: a quick rising run of ticks over a short buzz that
    /// lands on one crisp click, unlike any other moment in the library.
    static func reorderStarted() {
        guard enabled else { return }
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { impact(.rigid); return }
        let ticks = [(0.0, 0.45, 0.35), (0.055, 0.6, 0.55), (0.11, 0.75, 0.75), (0.2, 1.0, 1.0)].map { time, intensity, sharpness in
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(intensity)),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(sharpness))
            ], relativeTime: time)
        }
        let buzz = CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.35),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
        ], relativeTime: 0, duration: 0.17)
        let rise = CHHapticParameterCurve(parameterID: .hapticIntensityControl,
                                          controlPoints: [.init(relativeTime: 0, value: 0.3), .init(relativeTime: 0.17, value: 0.9)], relativeTime: 0)
        play(ticks + [buzz], curves: [rise]) { impact(.rigid) }
    }

    /// A low rumble that swells while the Earth rises and lands with a soft thud, or fades while it sinks.
    static func earth(rising: Bool) {
        guard enabled else { return }
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { impact(.heavy); return }
        let duration: TimeInterval = rising ? 0.5 : 0.38
        var events = [CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.15)
        ], relativeTime: 0, duration: duration)]
        if rising {
            events.append(CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.6),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3)
            ], relativeTime: duration))
        }
        let swell = CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: rising
            ? [.init(relativeTime: 0, value: 0.15), .init(relativeTime: duration * 0.7, value: 0.7), .init(relativeTime: duration, value: 0.2)]
            : [.init(relativeTime: 0, value: 0.6), .init(relativeTime: duration, value: 0.05)], relativeTime: 0)
        play(events, curves: [swell]) { impact(.heavy) }
    }

    private static func play(_ events: [CHHapticEvent], curves: [CHHapticParameterCurve], fallback: () -> Void) {
        do {
            try startedEngine().makePlayer(with: CHHapticPattern(events: events, parameterCurves: curves)).start(atTime: CHHapticTimeImmediate)
        } catch {
            fallback()
        }
    }

    private static func startedEngine() throws -> CHHapticEngine {
        let engine = try self.engine ?? CHHapticEngine()
        if self.engine == nil {
            engine.isAutoShutdownEnabled = true
            // A reset invalidates the rumble's player; the next build makes a new one.
            engine.resetHandler = { Task { @MainActor in Haptics.buildPlayer = nil } }
            self.engine = engine
        }
        try engine.start()
        return engine
    }

    private static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle, intensity: CGFloat = 1) {
        guard enabled, CACurrentMediaTime() >= quietUntil else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred(intensity: intensity)
    }
}
