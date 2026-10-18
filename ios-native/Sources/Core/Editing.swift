import Foundation

struct RecognizedText: Decodable, Identifiable, Sendable {
    let id: String
    let text: String
    let textScore: Double
}

struct PixelDimensions: Codable, Equatable, Sendable {
    let width: Int
    let height: Int
}

struct PixelCrop: Codable, Equatable, Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    /// Clamp rounded crop edges together; independent rounding can exceed the source by one pixel.
    static func normalized(x: Double, y: Double, width: Double, height: Double, in size: PixelDimensions) throws -> PixelCrop {
        guard size.width > 0, size.height > 0, [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else {
            throw APIError.invalidResponse("The image dimensions are unavailable for cropping.")
        }
        let left = min(size.width - 1, Int((min(1, max(0, x)) * Double(size.width)).rounded(.down)))
        let top = min(size.height - 1, Int((min(1, max(0, y)) * Double(size.height)).rounded(.down)))
        let right = min(size.width, max(left + 1, Int((min(1, max(0, x + width)) * Double(size.width)).rounded())))
        let bottom = min(size.height, max(top + 1, Int((min(1, max(0, y + height)) * Double(size.height)).rounded())))
        return .init(x: left, y: top, width: right - left, height: bottom - top)
    }
}

enum MirrorAxis: String, Codable, Sendable { case horizontal, vertical }

enum PhotoEdit: Codable, Equatable, Sendable {
    case crop(PixelCrop)
    case rotate(Int)
    case mirror(MirrorAxis)

    private enum CodingKeys: String, CodingKey { case action, parameters }
    private struct Rotation: Codable { let angle: Int }
    private struct Mirror: Codable { let axis: MirrorAxis }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .action) {
        case "crop": self = .crop(try container.decode(PixelCrop.self, forKey: .parameters))
        case "rotate": self = .rotate(try container.decode(Rotation.self, forKey: .parameters).angle)
        case "mirror": self = .mirror(try container.decode(Mirror.self, forKey: .parameters).axis)
        default: throw DecodingError.dataCorruptedError(forKey: .action, in: container, debugDescription: "Unsupported image edit")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .crop(let crop):
            try container.encode("crop", forKey: .action); try container.encode(crop, forKey: .parameters)
        case .rotate(let angle):
            try container.encode("rotate", forKey: .action); try container.encode(Rotation(angle: angle), forKey: .parameters)
        case .mirror(let axis):
            try container.encode("mirror", forKey: .action); try container.encode(Mirror(axis: axis), forKey: .parameters)
        }
    }
}

struct AssetEdits: Decodable, Sendable {
    let assetId: String
    let edits: [PhotoEdit]
    let baseDimensions: PixelDimensions?
}
struct EditSubmission: Encodable, Sendable { let edits: [PhotoEdit] }

/// Integer dihedral transform: preserve any ordering of the server's right-angle rotations and mirrors.
struct PhotoTransform: Equatable, Sendable {
    var a = 1, b = 0, c = 0, d = 1
    static func * (lhs: Self, rhs: Self) -> Self {
        .init(a: lhs.a * rhs.a + lhs.c * rhs.b, b: lhs.b * rhs.a + lhs.d * rhs.b,
              c: lhs.a * rhs.c + lhs.c * rhs.d, d: lhs.b * rhs.c + lhs.d * rhs.d)
    }
    init(a: Int = 1, b: Int = 0, c: Int = 0, d: Int = 1) { self.a = a; self.b = b; self.c = c; self.d = d }
    init(edits: [PhotoEdit]) {
        self.init()
        for edit in edits {
            switch edit {
            case .crop: break
            case .rotate(let angle):
                let rotations = [Self(), Self(a: 0, b: -1, c: 1, d: 0), Self(a: -1, d: -1), Self(a: 0, b: 1, c: -1, d: 0)]
                self = self * rotations[((angle / 90) % 4 + 4) % 4]
            case .mirror(let axis): self = self * (axis == .horizontal ? Self(d: -1) : Self(a: -1))
            }
        }
    }
    var edits: [PhotoEdit] {
        for angle in [0, 90, 180, 270] {
            for mirror in [false, true] {
                let candidate: [PhotoEdit] = (angle == 0 ? [] : [.rotate(angle)]) + (mirror ? [.mirror(.vertical)] : [])
                if Self(edits: candidate) == self { return candidate }
            }
        }
        return [] // Every right-angle rotation/reflection is one of the eight candidates.
    }
}
