import XCTest
@testable import Ilyich

/// What the viewer, the selection actions, the info sheet and a stack offer for a photo.
final class AssetCapabilityPolicyTests: XCTestCase {
    private let me = "me"
    private let everyFeature = ServerFeatures(passwordLogin: true, oauth: false, smartSearch: true, searchVerification: nil, ocr: true,
                                              facialRecognition: true, map: true, trash: true, sidecar: true, realtimeTranscoding: true)

    /// A photo of mine with its details loaded, as the viewer has it once it settles on it.
    private func photo(_ id: String = "photo", owner: String? = "me", visibility: AssetVisibility = .timeline,
                       name: String = "IMG_0001.HEIC", projection: String? = nil, type: AssetKind = .image) -> Asset {
        var asset = Asset(id: id, type: type, originalFileName: name, ownerId: owner)
        asset.visibility = visibility
        asset.hasKnownEditState = true
        if let projection { asset.exifInfo = exif(projection: projection) }
        return asset
    }

    private func exif(projection: String) -> ExifInfo {
        ExifInfo(exifImageWidth: 8000, exifImageHeight: 4000, orientation: nil, projectionType: projection, timeZone: nil, description: nil,
                 city: nil, state: nil, country: nil, latitude: nil, longitude: nil, make: nil, model: nil, lensModel: nil,
                 fNumber: nil, exposureTime: nil, iso: nil, focalLength: nil, fileSizeInByte: nil, rating: nil)
    }

    private func context(writable: Bool = true, features: ServerFeatures? = nil, album: String? = nil) -> CapabilityContext {
        CapabilityContext(viewerID: me, writable: writable, features: features ?? everyFeature, album: album)
    }

    private func evaluate(_ asset: Asset, _ context: CapabilityContext? = nil) -> AssetCapabilities {
        AssetCapabilityPolicy.evaluate(asset, context: context ?? self.context())
    }

    func testCastIsHiddenForLockedPhotos() {
        XCTAssertEqual(evaluate(photo())[.cast], .offered)
        XCTAssertEqual(evaluate(photo(visibility: .locked))[.cast], .hidden, "A locked photo never reaches a TV.")
        XCTAssertEqual(evaluate(photo(visibility: .archive))[.cast], .offered)
    }

    /// The server's editor refuses panoramas, by projection or as an Insta360 file. The server
    /// writes the projection upper-cased.
    func testEditIsHiddenForPanoramasAndInspFiles() {
        XCTAssertEqual(evaluate(photo())[.edit], .offered)
        XCTAssertEqual(evaluate(photo(projection: "EQUIRECTANGULAR"))[.edit], .hidden, "As the server writes it.")
        XCTAssertEqual(evaluate(photo(projection: "equirectangular"))[.edit], .hidden)
        XCTAssertEqual(evaluate(photo(name: "PANO_0001.insp"))[.edit], .hidden)
        XCTAssertEqual(evaluate(photo(name: "PANO_0001.INSP"))[.edit], .hidden)
        XCTAssertEqual(evaluate(photo(projection: "CUBEFACE"))[.edit], .offered, "Only an equirectangular projection is a panorama to the server.")
        XCTAssertTrue(AssetCapabilityPolicy.isPanorama(photo(projection: "EQUIRECTANGULAR")))
    }

    func testEditIsHiddenForGifsSvgsLivePhotosVideosAndTrash() {
        XCTAssertEqual(evaluate(photo(name: "loop.gif"))[.edit], .hidden)
        XCTAssertEqual(evaluate(photo(name: "logo.SVG"))[.edit], .hidden)
        var live = photo(); live.livePhotoVideoId = "motion"
        XCTAssertEqual(evaluate(live)[.edit], .hidden, "The server can't edit a Live Photo.")
        XCTAssertEqual(evaluate(photo(name: "clip.mov", type: .video))[.edit], .hidden)
        var animated = photo(); animated.duration = 2_000
        XCTAssertEqual(evaluate(animated)[.edit], .hidden)
        var trashed = photo(); trashed.isTrashed = true
        XCTAssertEqual(evaluate(trashed)[.edit], .hidden)
        XCTAssertEqual(evaluate(photo(owner: "partner"))[.edit], .hidden, "Only the owner edits a photo.")
    }

    /// A timeline row carries no file name or projection, so Edit waits for the photo's details
    /// instead of opening the editor on a panorama.
    func testEditWaitsForAKnownEditState() {
        var row = Asset(id: "row", ownerId: me)
        row.hasKnownEditState = false
        XCTAssertEqual(evaluate(row)[.edit], .disabled(AssetCapabilityPolicy.loadingReason))
        XCTAssertTrue(evaluate(row)[.edit].awaitsDetails, "The viewer keeps Edit lit and waits for the details on a tap.")
        XCTAssertEqual(evaluate(row, context(writable: false))[.edit], .disabled(AssetCapabilityPolicy.readOnlyReason),
                       "Read-only mode is not a wait, even before the details arrive.")
        XCTAssertFalse(evaluate(row, context(writable: false))[.edit].awaitsDetails)
        var live = row; live.livePhotoVideoId = "motion"
        XCTAssertEqual(evaluate(live)[.edit], .hidden, "What the row does say still hides it.")
    }

    func testLockedPhotosHideAlbumLinkProfileBrowserSimilarCoverCommentsArchiveAndStack() {
        let locked = evaluate(photo(visibility: .locked), context(album: "album"))
        for action: AssetAction in [.addToAlbum, .sharedLink, .profilePhoto, .openInBrowser, .findSimilar, .albumCover, .comments, .archive, .stack, .cast] {
            XCTAssertEqual(locked[action], .hidden, "\(action) is hidden for a locked photo.")
        }
        let open = evaluate(photo(), context(album: "album"))
        for action: AssetAction in [.addToAlbum, .sharedLink, .profilePhoto, .openInBrowser, .findSimilar, .albumCover, .comments, .archive, .stack, .cast] {
            XCTAssertEqual(open[action], .offered, "\(action) is offered outside the Locked Folder.")
        }
    }

    /// Until the owner decides otherwise, a locked photo can still be shared, downloaded, saved,
    /// favorited, edited, deleted and moved out of the folder.
    func testLockedPhotosKeepSharingSavingAndTheirOwnersChanges() {
        let locked = evaluate(photo(visibility: .locked))
        for action: AssetAction in [.share, .download, .saveToPhotos, .favorite, .lock, .trash, .edit, .editInfo, .selectText] {
            XCTAssertEqual(locked[action], .offered, "\(action) stays for a locked photo.")
        }
    }

    func testOnlyTheOwnerChangesAPhoto() {
        let partners = evaluate(photo(owner: "partner"))
        for action: AssetAction in [.favorite, .archive, .lock, .trash, .deletePermanently, .restore, .edit, .editInfo, .stack] {
            XCTAssertEqual(partners[action], .hidden, "\(action) needs the owner.")
        }
        for action: AssetAction in [.share, .download, .saveToPhotos, .addToAlbum, .sharedLink, .cast, .findSimilar] {
            XCTAssertEqual(partners[action], .offered, "\(action) works on a partner's photo.")
        }
        XCTAssertEqual(evaluate(photo(owner: nil))[.favorite], .hidden, "A photo with no known owner is nobody's to change.")
        let signedOut = CapabilityContext(viewerID: nil, writable: true, features: everyFeature, album: nil)
        XCTAssertEqual(evaluate(photo(owner: nil), signedOut)[.trash], .hidden)
    }

    /// Read-only mode dims every change, with its reason, and leaves viewing and sharing alone.
    func testReadOnlyDisablesEveryChange() {
        let readOnly = evaluate(photo(), context(writable: false, album: "album"))
        let reason = ActionAvailability.disabled(AssetCapabilityPolicy.readOnlyReason)
        for action: AssetAction in [.favorite, .archive, .lock, .trash, .addToAlbum, .albumCover, .profilePhoto, .sharedLink, .stack,
                                    .edit, .editInfo, .saveToPhotos] {
            XCTAssertEqual(readOnly[action], reason, "\(action) waits for read-only mode to end.")
        }
        for action: AssetAction in [.share, .download, .cast, .findSimilar, .openInBrowser, .comments, .selectText] {
            XCTAssertEqual(readOnly[action], .offered, "\(action) only reads.")
        }
        var trashed = photo(); trashed.isTrashed = true
        XCTAssertEqual(evaluate(trashed, context(writable: false))[.restore], reason)
    }

    func testTrashOffersRestoreAndPermanentDeletion() {
        var trashed = photo(); trashed.isTrashed = true
        let inTrash = evaluate(trashed)
        XCTAssertEqual(inTrash[.restore], .offered)
        XCTAssertEqual(inTrash[.deletePermanently], .offered)
        XCTAssertEqual(inTrash[.trash], .hidden)
        XCTAssertEqual(inTrash[.archive], .hidden)
        XCTAssertEqual(inTrash[.lock], .hidden)
        let active = evaluate(photo())
        XCTAssertEqual(active[.trash], .offered)
        XCTAssertEqual(active[.restore], .hidden)
        XCTAssertEqual(active[.deletePermanently], .hidden)
    }

    /// Without a Trash on the server, deleting is for good; until the features arrive it is assumed,
    /// while restoring, similar photos and text wait for them.
    func testTheServersFeaturesDecideTrashSimilarPhotosAndText() {
        let noTrash = ServerFeatures(passwordLogin: true, oauth: false, smartSearch: false, searchVerification: nil, ocr: false,
                                     facialRecognition: true, map: true, trash: false, sidecar: true, realtimeTranscoding: true)
        let bare = evaluate(photo(), context(features: noTrash))
        XCTAssertEqual(bare[.trash], .hidden)
        XCTAssertEqual(bare[.deletePermanently], .offered)
        XCTAssertEqual(bare[.findSimilar], .hidden)
        XCTAssertEqual(bare[.selectText], .hidden)
        let loading = AssetCapabilityPolicy.evaluate(photo(), context: CapabilityContext(viewerID: me, writable: true, features: nil, album: nil))
        XCTAssertEqual(loading[.trash], .offered)
        XCTAssertEqual(loading[.findSimilar], .hidden)
        var trashed = photo(); trashed.isTrashed = true
        XCTAssertEqual(AssetCapabilityPolicy.evaluate(trashed, context: CapabilityContext(viewerID: me, writable: true, features: nil, album: nil))[.restore], .hidden)
        XCTAssertEqual(evaluate(photo(name: "clip.mov", type: .video))[.selectText], .hidden, "Text is read from photos.")
    }

    func testAlbumActionsNeedTheAlbumThePhotoWasOpenedFrom() {
        XCTAssertEqual(evaluate(photo())[.albumCover], .hidden)
        XCTAssertEqual(evaluate(photo())[.comments], .hidden)
        XCTAssertEqual(evaluate(photo(), context(album: "album"))[.albumCover], .offered)
        XCTAssertEqual(evaluate(photo(owner: "partner"), context(album: "album"))[.albumCover], .offered, "An album's cover can be anyone's photo in it.")
        XCTAssertEqual(evaluate(photo(name: "clip.mov", type: .video))[.profilePhoto], .hidden)
    }

    /// A selection of one photo gets exactly what the photo gets alone.
    func testASelectionOfOneMatchesThePhoto() {
        var trashed = photo(); trashed.isTrashed = true
        var live = photo(); live.livePhotoVideoId = "motion"
        let photos = [photo(), photo(visibility: .locked), photo(owner: "partner"), photo(projection: "EQUIRECTANGULAR"), trashed, live,
                      Asset(id: "row", ownerId: me)]
        for context in [context(), context(writable: false), context(album: "album")] {
            for asset in photos {
                XCTAssertEqual(AssetCapabilityPolicy.evaluate(selection: [asset], context: context), AssetCapabilityPolicy.evaluate(asset, context: context),
                               asset.id)
            }
        }
        XCTAssertFalse(AssetCapabilityPolicy.evaluate(selection: [], context: context()).shows(.share), "An empty selection offers nothing.")
    }

    /// A selection offers what every photo in it allows.
    func testASelectionOffersOnlyWhatEveryPhotoAllows() {
        let mixedOwners = AssetCapabilityPolicy.evaluate(selection: [photo("a"), photo("b", owner: "partner")], context: context())
        XCTAssertEqual(mixedOwners[.favorite], .hidden)
        XCTAssertEqual(mixedOwners[.trash], .hidden)
        XCTAssertEqual(mixedOwners[.share], .offered)
        XCTAssertEqual(mixedOwners[.addToAlbum], .offered)

        let mixedLocks = AssetCapabilityPolicy.evaluate(selection: [photo("a"), photo("b", visibility: .locked)], context: context())
        XCTAssertEqual(mixedLocks[.addToAlbum], .hidden)
        XCTAssertEqual(mixedLocks[.sharedLink], .hidden)
        XCTAssertEqual(mixedLocks[.archive], .hidden)
        XCTAssertEqual(mixedLocks[.lock], .offered)
        XCTAssertEqual(mixedLocks[.saveToPhotos], .offered)

        var row = Asset(id: "row", ownerId: me); row.hasKnownEditState = false
        let loading = AssetCapabilityPolicy.evaluate(selection: [photo("a"), row], context: context())
        XCTAssertEqual(loading[.edit], .disabled(AssetCapabilityPolicy.loadingReason), "One photo still loading disables the whole selection's edit.")
        let both = AssetCapabilityPolicy.evaluate(selection: [photo("a"), row], context: context(writable: false))
        XCTAssertNotEqual(both[.edit], .offered)
        XCTAssertEqual(both[.favorite], .disabled(AssetCapabilityPolicy.readOnlyReason))
    }
}
