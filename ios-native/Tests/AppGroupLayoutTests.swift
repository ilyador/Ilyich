import Foundation
import IlyichPlatform
import XCTest

final class AppGroupLayoutTests: XCTestCase {
    private let current = "/private/var/mobile/Containers/Shared/AppGroup/0E7C2C1B-5A57-4D2C-9A8E-2D4C1C0F8A11"
    private let previous = "/private/var/mobile/Containers/Shared/AppGroup/9B3F6A52-1F0D-4E8B-8C5A-6F2E7D9A4B30"

    func testVarAndPrivateVarAndANewContainerUUIDResolveToTheSamePath() {
        let layout = AppGroupLayout(container: URL(fileURLWithPath: current, isDirectory: true))
        let file = "Backup/cb73830dc48b80dcb5bfbf7950f74cb2efcdefb3be8cb10ec10c37faf0721712/5C1D8E2A-7B3F-4A6C-9E0D-1F2A3B4C5D6E/stage.receipt"
        let roots = [current, current.replacingOccurrences(of: "/private/var/", with: "/var/"),
                     previous, previous.replacingOccurrences(of: "/private/var/", with: "/var/")]
        for root in roots {
            let recorded = URL(fileURLWithPath: root + "/" + file)
            XCTAssertEqual(AppGroupLayout.relativePath(of: recorded), file, root)
            XCTAssertEqual(layout.resolve(recorded)?.path, current + "/" + file, root)
        }
        let manifest = "ShareInbox/6D3A1E0B-2C4F-4B8A-9D7E-0A1B2C3D4E5F/manifest.json"
        XCTAssertEqual(layout.resolve(URL(fileURLWithPath: previous + "/" + manifest))?.path, current + "/" + manifest)
        XCTAssertEqual(layout.url(forRelativePath: manifest).path, current + "/" + manifest)
        XCTAssertNil(AppGroupLayout.relativePath(of: URL(fileURLWithPath: current + "/WidgetCache2/scope/random_image.png")),
                     "Only folders that earlier formats recorded by absolute path are resolved.")
        XCTAssertNil(AppGroupLayout.relativePath(of: URL(string: "https://photos.example/Backup/scope/stage")!))
    }

    func testTheAppGroupComesFromTheBundleAndAnUnexpandedSettingIsUnavailable() throws {
        XCTAssertEqual(try AppGroup.identifier, "group.app.alextran.immich")
        XCTAssertEqual(try AppGroup.identifier(from: "group.app.alextran.immich.H4K2MSF2SG"), "group.app.alextran.immich.H4K2MSF2SG")
        for value in ["$(CUSTOM_GROUP_ID)", "app.alextran.immich", nil, 7] as [Any?] {
            XCTAssertThrowsError(try AppGroup.identifier(from: value)) { error in
                XCTAssertEqual(error as? AppGroupError, .unavailable)
            }
        }
    }
}
