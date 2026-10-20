import Foundation
@testable import Ilyich

/// Golden files from Tests/Fixtures, which the test bundle carries as one folder, paths kept.
enum FixtureLoader {
    private final class BundleToken {}

    static var root: URL {
        Bundle(for: BundleToken.self).resourceURL!.appendingPathComponent("Fixtures", isDirectory: true)
    }

    static func url(_ path: String) -> URL { root.appendingPathComponent(path, isDirectory: false) }

    static func data(_ path: String) throws -> Data { try Data(contentsOf: url(path)) }

    /// Decodes with the legacy writers' JSON settings.
    static func decode<T: Decodable>(_ type: T.Type, from path: String) throws -> T {
        try Legacy.decoder().decode(type, from: data(path))
    }

    /// Every file below a fixture folder, as sorted paths relative to it.
    static func files(in folder: String) throws -> [String] {
        let base = url(folder).standardizedFileURL.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var paths: [String] = []
        for case let file as URL in enumerator where (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            let path = file.standardizedFileURL.resolvingSymlinksInPath().path
            paths.append(String(path.dropFirst(base.path.count + 1)))
        }
        return paths.sorted()
    }

    /// JSON rewritten with sorted keys, and with the arrays at the given paths sorted, so two
    /// encodings compare equal whatever order their writer chose. JSONEncoder orders an object's
    /// keys differently from one process to the next, and a Set's members too. A path names
    /// object keys from the root, separated by dots; * matches any key.
    static func canonicalJSON(_ data: Data, unorderedArrays: Set<String> = []) throws -> String {
        let patterns = unorderedArrays.map { $0.split(separator: ".").map(String.init) }
        func matches(_ path: [String]) -> Bool {
            patterns.contains { $0.count == path.count && zip($0, path).allSatisfy { $0 == "*" || $0 == $1 } }
        }
        func text(_ value: Any) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
        func walk(_ value: Any, _ path: [String]) -> Any {
            if let object = value as? [String: Any] {
                return Dictionary(uniqueKeysWithValues: object.map { ($0.key, walk($0.value, path + [$0.key])) })
            }
            if let array = value as? [Any] {
                let items = array.map { walk($0, path) }
                return matches(path) ? items.sorted { text($0) < text($1) } : items
            }
            return value
        }
        let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return text(walk(value, []))
    }
}
