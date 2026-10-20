import Foundation
import SwiftUI
import WidgetKit



enum WidgetError: Error, Codable {
  case noLogin
  case fetchFailed
  case albumNotFound
  case noAssetsAvailable
}

enum FetchError: Error {
  case unableToResize
  case invalidImage
  case invalidURL
  case fetchFailed
}

extension WidgetError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .noLogin:
      return "Login to Ilyich"

    case .fetchFailed:
      return "Unable to connect to Ilyich"

    case .albumNotFound:
      return "Album not found"

    case .noAssetsAvailable:
      return "No assets available"
    }
  }
}

enum AssetType: String, Codable {
  case image = "IMAGE"
  case video = "VIDEO"
  case audio = "AUDIO"
  case other = "OTHER"
}

struct Asset: Codable {
  let id: String
  let type: AssetType
  var memoryID: String? = nil

  private enum CodingKeys: String, CodingKey {
    case id, type
  }

  var deepLink: URL? {
    var components = URLComponents()
    components.scheme = "immich"
    components.host = memoryID == nil ? "asset" : "memory"
    components.queryItems = [URLQueryItem(name: "id", value: memoryID ?? id)]
    return components.url
  }
}

struct SearchFilter: Codable {
  var type = AssetType.image
  var size = 1
  var albumIds: [String] = []
  var isFavorite: Bool? = nil
  // Timeline photos only: never the Locked Folder, even while it is unlocked, nor the archive.
  var visibility = "timeline"
}

struct MemoryResult: Codable {
  let id: String
  var assets: [Asset]
  let type: String

  struct MemoryData: Codable {
    let year: Int
  }

  let data: MemoryData
}

struct Album: Codable, Equatable {
  let id: String
  let albumName: String

  static let NONE = Album(id: "NONE", albumName: "None")
  static let FAVORITES = Album(id: "FAVORITES", albumName: "Favorites")

  var filter: SearchFilter {
    switch self {
    case Album.NONE:
      return SearchFilter()
    case Album.FAVORITES:
      return SearchFilter(isFavorite: true)

    // regular album
    default:
      return SearchFilter(albumIds: [id])
    }
  }

  var isVirtual: Bool {
    switch self {
    case Album.NONE, Album.FAVORITES:
      return true
    default:
      return false
    }
  }
}

/// The existing native widget views keep their API, while credentials come from
/// the shared keychain and authenticated images use headers rather than URL tokens.
final class ImmichAPI: @unchecked Sendable {
  let saved: SavedSession
  var scope: String { saved.scope }
  private let network: URLSession
  private let connection: ServerConnection

  init() async throws {
    guard let saved = try SessionKeychain.read() else { throw WidgetError.noLogin }
    self.saved = saved
    connection = try ServerConnection(server: saved.server)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    network = URLSession(configuration: configuration, delegate: SameOriginRedirectDelegate(origin: saved.server), delegateQueue: nil)
  }

  private func request(_ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
    guard let current = try SessionKeychain.read(), current.scope == saved.scope, current.token == saved.token else { throw WidgetError.noLogin }
    var request = try await connection.request(path: path, query: query, token: saved.token)
    request.httpMethod = body == nil ? "GET" : "POST"
    request.httpBody = body
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    let (data, response) = try await network.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw WidgetError.fetchFailed }
    guard let current = try SessionKeychain.read(), current.scope == saved.scope, current.token == saved.token else { throw WidgetError.noLogin }
    return data
  }

  func fetchSearchResults(with filters: SearchFilter = Album.NONE.filter) async throws -> [Asset] {
    try JSONDecoder().decode([Asset].self, from: await request("search/random", body: JSONEncoder().encode(filters)))
  }
  func fetchMemory(for date: Date) async throws -> [MemoryResult] {
    let day = date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day().dateSeparator(.dash))
    let memories = try JSONDecoder().decode([MemoryResult].self, from: await request("memories", query: [.init(name: "for", value: day)]))
    return memories.map { memory in
      var annotated = memory
      annotated.assets = memory.assets.map { asset in
        var asset = asset
        asset.memoryID = memory.id
        return asset
      }
      return annotated
    }
  }
  func fetchAlbums() async throws -> [Album] {
    try JSONDecoder().decode([Album].self, from: await request("albums"))
  }
  func fetchImage(asset: Asset) async throws -> UIImage {
    let data = try await request("assets/\(asset.id)/thumbnail", query: [.init(name: "size", value: "preview"), .init(name: "edited", value: "true")])
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
            kCGImageSourceCreateThumbnailWithTransform: true,
          ] as CFDictionary) else { throw FetchError.invalidImage }
    return UIImage(cgImage: thumbnail)
  }
}

actor AlbumCache {
  static let shared = AlbumCache()
  private var scope: String?
  private var albums: [Album]?
  func getAlbums(refresh: Bool = false) async throws -> [Album] {
    let api = try await ImmichAPI()
    if scope == api.scope, let albums, !refresh { return albums }
    let result = try await api.fetchAlbums()
    scope = api.scope; albums = result
    return result
  }
}
