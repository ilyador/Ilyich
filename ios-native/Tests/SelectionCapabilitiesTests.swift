import XCTest
@testable import Ilyich

/// What a selection of server photos offers (N2): what every photo allows, and in the Trash only
/// Restore and Delete permanently.
final class SelectionCapabilitiesTests: XCTestCase {
    private let features = ServerFeatures(passwordLogin: true, oauth: false, smartSearch: true, searchVerification: nil, ocr: true,
                                          facialRecognition: true, map: true, trash: true, sidecar: true, realtimeTranscoding: true)

    private func photo(_ id: String, owner: String = "me", trashed: Bool = false) -> Asset {
        var asset = Asset(id: id, originalFileName: id + ".jpg", ownerId: owner)
        asset.isTrashed = trashed
        asset.hasKnownEditState = true
        return asset
    }

    private func context(writable: Bool = true, features: ServerFeatures?? = .none) -> CapabilityContext {
        CapabilityContext(viewerID: "me", writable: writable, features: features ?? self.features, album: nil)
    }

    private func shown(_ capabilities: AssetCapabilities) -> Set<AssetAction> {
        Set(AssetAction.allCases.filter(capabilities.shows))
    }

    func testATrashSelectionOffersOnlyRestoreAndPermanentDelete() {
        let selection = [photo("a", trashed: true), photo("b", trashed: true)]
        XCTAssertTrue(SelectionCapabilities.isTrash(selection))

        let can = SelectionCapabilities.evaluate(selection, context: context())

        XCTAssertEqual(shown(can), [.restore, .deletePermanently], "Nothing else: no favorite, album, share, edit or Trash again.")
        XCTAssertTrue(can.offers(.restore))
        XCTAssertTrue(can.offers(.deletePermanently))
    }

    /// Outside the Trash a selection offers what every photo in it allows, as before.
    func testALibrarySelectionOffersWhatEveryPhotoAllows() {
        let selection = [photo("a"), photo("b")]
        XCTAssertFalse(SelectionCapabilities.isTrash(selection))

        let can = SelectionCapabilities.evaluate(selection, context: context())

        XCTAssertEqual(can, AssetCapabilityPolicy.evaluate(selection: selection, context: context()))
        XCTAssertTrue(can.offers(.trash))
        XCTAssertTrue(can.offers(.favorite))
        XCTAssertFalse(can.shows(.restore))
        XCTAssertFalse(can.shows(.deletePermanently), "Outside the Trash, deleting goes to Trash first.")
    }

    /// Read-only mode keeps both shown and disables them, with its reason.
    func testReadOnlyModeDisablesRestoreAndPermanentDeleteInTrash() {
        let can = SelectionCapabilities.evaluate([photo("a", trashed: true)], context: context(writable: false))

        XCTAssertEqual(shown(can), [.restore, .deletePermanently])
        XCTAssertEqual(can[.restore], .disabled(AssetCapabilityPolicy.readOnlyReason))
        XCTAssertEqual(can[.deletePermanently], .disabled(AssetCapabilityPolicy.readOnlyReason))
    }

    /// Until the server's features say there is a Trash, Restore waits; deleting for good stays.
    func testRestoreWaitsForTheServersFeatures() {
        let can = SelectionCapabilities.evaluate([photo("a", trashed: true)], context: context(features: .some(nil)))

        XCTAssertFalse(can.shows(.restore))
        XCTAssertTrue(can.offers(.deletePermanently))
    }

    /// A selection that isn't all in the Trash is no Trash selection, and someone else's photo in
    /// the Trash can be neither restored nor deleted.
    func testAMixedSelectionIsNotATrashSelection() {
        let mixed = [photo("a", trashed: true), photo("b")]
        XCTAssertFalse(SelectionCapabilities.isTrash(mixed))
        XCTAssertFalse(SelectionCapabilities.isTrash([]))
        let can = SelectionCapabilities.evaluate(mixed, context: context())
        XCTAssertFalse(can.shows(.restore))
        XCTAssertFalse(can.shows(.trash))

        let theirs = SelectionCapabilities.evaluate([photo("a", trashed: true), photo("b", owner: "partner", trashed: true)], context: context())
        XCTAssertEqual(shown(theirs), [], "Only the owner restores or deletes.")
    }
}
