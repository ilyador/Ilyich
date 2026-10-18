import Foundation

enum DiagnosticLevel: String, CaseIterable, Sendable {
    case off, errors, requests
    var title: String {
        switch self { case .off: "Off"; case .errors: "Errors only"; case .requests: "All requests" }
    }
}
enum DiagnosticOutcome: String, Sendable { case success, failed, cancelled, blocked }
struct DiagnosticEvent: Identifiable, Sendable {
    let id: UUID
    let date: Date
    let method: String
    let category: String
    let statusCode: Int?
    let milliseconds: Int
    let outcome: DiagnosticOutcome
}

/// Bounded, in-memory operational events. Never retain URLs, IDs, parameters,
/// headers, request/response bodies, tokens, or free-form error descriptions.
actor DiagnosticsStore {
    static let shared = DiagnosticsStore()
    static let levelKey = "diagnosticLevel"
    private let fixedLevel: DiagnosticLevel?
    private var events: [DiagnosticEvent] = []
    private let capacity = 300

    init(level: DiagnosticLevel? = nil) { fixedLevel = level }
    func record(method: String, path: String, statusCode: Int?, startedAt: Date, outcome: DiagnosticOutcome) {
        let level = fixedLevel ?? DiagnosticLevel(rawValue: UserDefaults.standard.string(forKey: Self.levelKey) ?? "errors") ?? .errors
        guard level != .off, level == .requests || [.failed, .blocked].contains(outcome) else { return }
        let method = method.uppercased()
        let safeMethod = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"].contains(method) ? method : "OTHER"
        let elapsed = Date().timeIntervalSince(startedAt)
        let duration = elapsed.isFinite ? Int(min(86_400_000, max(0, elapsed * 1_000))) : 0
        events.append(.init(id: UUID(), date: Date(), method: safeMethod, category: Self.category(path: path),
                            statusCode: statusCode.flatMap { (100...599).contains($0) ? $0 : nil }, milliseconds: duration, outcome: outcome))
        if events.count > capacity { events.removeFirst(events.count - capacity) }
    }
    func snapshot() -> [DiagnosticEvent] { events.reversed() }
    func clear() { events.removeAll() }
    nonisolated static func category(path: String) -> String {
        let prefix = path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        switch prefix {
        case "assets", "albums", "people", "search", "auth", "sessions", "users", "server", "partners", "memories", "activities", "duplicates", "tags", "stacks", "faces", "map", "shared-links", "folders", "sync": return prefix
        default: return "other"
        }
    }
    nonisolated static func report(events: [DiagnosticEvent]) -> String {
        let format = ISO8601DateFormatter()
        let rows = events.map { event in
            "\(format.string(from: event.date)) \(event.method) \(event.category) \(event.statusCode.map(String.init) ?? "—") \(event.outcome.rawValue) \(event.milliseconds)ms"
        }
        return (["Ilyich request diagnostics", "Categories only. No URLs, identifiers, headers, queries, bodies, or error text are recorded."] + rows).joined(separator: "\n")
    }
}

extension Notification.Name {
    static let ilyichCachesReset = Notification.Name("IlyichCachesReset")
}
