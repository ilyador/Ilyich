import Foundation
import CryptoKit

struct UploadFile: Codable, Sendable {
    let url: URL
    let filename: String
    let contentType: String
}

/// Builds a disk-backed multipart body; video bytes never accumulate in memory.
enum UploadBody {
    static func checksum(_ url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hash = Insecure.SHA1()
        while let chunk = try input.read(upToCount: 512 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return Data(hash.finalize()).base64EncodedString()
    }

    static func write(to output: URL, boundary: String, fields: [String: String], asset: UploadFile,
                      sidecar: UploadFile? = nil) throws {
        guard !boundary.isEmpty, boundary.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: output.path)
        #endif
        let writer = try FileHandle(forWritingTo: output)
        var succeeded = false
        defer {
            try? writer.close()
            if !succeeded { try? FileManager.default.removeItem(at: output) }
        }
        func text(_ value: String) throws { try writer.write(contentsOf: Data(value.utf8)) }
        func safe(_ value: String) -> String {
            value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        }
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            try text("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(safe(key))\"\r\n\r\n\(value)\r\n")
        }
        func file(_ source: UploadFile, key: String) throws {
            try text("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"; filename=\"\(safe(source.filename))\"\r\nContent-Type: \(safe(source.contentType))\r\n\r\n")
            let input = try FileHandle(forReadingFrom: source.url)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 512 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                try writer.write(contentsOf: chunk)
            }
            try text("\r\n")
        }
        try file(asset, key: "assetData")
        if let sidecar { try file(sidecar, key: "sidecarData") }
        try text("--\(boundary)--\r\n")
        try writer.synchronize()
        succeeded = true
    }
}

struct UploadReceipt: Codable, Sendable {
    let id: String
    let status: String
}

struct UploadCheck: Encodable, Sendable {
    struct Item: Encodable, Sendable { let id: String; let checksum: String }
    let assets: [Item]
}

struct UploadCheckResponse: Decodable, Sendable {
    struct Result: Decodable, Sendable {
        let id: String
        let action: String
        let reason: String?
        let assetId: String?
        let isTrashed: Bool?
    }
    let results: [Result]
}
