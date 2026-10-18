import Foundation
import XCTest
@testable import Ilyich

final class AppLinkTests: XCTestCase {
    func testWidgetLinkWorksBeforeSignInWithoutChangingServer() {
        let id = "00000000-0000-4000-8000-000000000001"
        XCTAssertEqual(AppLink(url: URL(string: "immich://asset?id=\(id)")!, server: nil), .asset(id))
        XCTAssertNil(AppLink(url: URL(string: "immich://asset?id=../../users/me")!, server: nil))
    }
    func testWebLinksAreRestrictedToConfiguredServerAndProxyPrefix() {
        let id = "00000000-0000-4000-8000-000000000001"
        let server = URL(string: "https://photos.example/prefix/api")!
        XCTAssertEqual(AppLink(url: URL(string: "https://photos.example/prefix/albums/\(id)")!, server: server), .album(id))
        for value in ["https://other.example/prefix/photos/\(id)", "http://photos.example/prefix/photos/\(id)", "https://photos.example/photos/\(id)", "https://user:password@photos.example/prefix/photos/\(id)"] {
            XCTAssertNil(AppLink(url: URL(string: value)!, server: server))
        }
    }
    func testSharesMemoriesAndActivityKeepTheirRealContext() {
        let asset = "00000000-0000-4000-8000-000000000001"
        let album = "00000000-0000-4000-8000-000000000002"
        let server = URL(string: "https://photos.example/prefix/api")!
        XCTAssertEqual(AppLink(url: URL(string: "immich://share")!, server: nil), .sharedFiles)
        XCTAssertEqual(AppLink(url: URL(string: "immich://memory")!, server: nil), .memory(nil))
        XCTAssertEqual(AppLink(url: URL(string: "immich://memory?id=\(asset)")!, server: nil), .memory(asset))
        XCTAssertEqual(AppLink(url: URL(string: "immich://activity?albumId=\(album)")!, server: nil), .activity(album))
        XCTAssertEqual(AppLink(url: URL(string: "https://photos.example/prefix/albums/\(album)/photos/\(asset)")!, server: server), .asset(asset, albumID: album))
        XCTAssertNil(AppLink(url: URL(string: "immich://asset?id=\(asset)&albumId=invalid")!, server: nil))
        XCTAssertNil(AppLink(url: URL(string: "immich://share/users/me")!, server: nil))
    }
}
