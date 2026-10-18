# Native iOS feature parity

Audit date: 2026-10-18. Scope: the 53 explicit incumbent mobile feature groups in the local functionality inventory. This is a source audit of the current working tree, including concurrent work; it is not a declaration that the replacement is complete or ready to install. Web-only features are excluded. Voice search is intentionally excluded by the user. Target: iPhone 15 Pro on iOS 27 only; iPad, earlier iOS versions and other form factors are not requirements. The share-extension row corrects an initial inventory overstatement using the actual incumbent consumer.

**Done** means the listed behavior has a concrete source implementation. **Partial** names an implemented flow and specific missing behavior. **Missing** means the incumbent feature has no equivalent implementation beyond a limited prerequisite. All rows still require relevant UI/device verification; a compiler pass is not a functional pass.

Source status: **15 done, 35 partial, 3 missing**. Do not interpret this count as a completion percentage.

## Verification evidence

- All app Sources have passed Swift 6 strict-concurrency typechecking against the Mac Catalyst SDK with real UIKit, PhotoKit, RealityKit and Google Cast headers. This does not replace an iPhone build, extension build or runtime test.
- Pure place grouping, cleanup-retention and diagnostics privacy/level/bounds checks have run successfully. XCTest suites cover Core/search/editing/range/cache/backup receipts, links, grouping and retention; simulator CI must still pass the current revision.
- Current UI tests cover sign-in and fixture-backed library interactions. PhotoKit permissions/cloud resources, true background upload, biometrics, Cast hardware, share/widgets and native visual fidelity have not been verified end to end.
- No deletion test has run on user photos. Cleanup uses durable backup receipts and fresh remote/local/account checks, and retains unverified/edited/auxiliary variants.

## Feature ledger

### Server connection, accounts and authentication

| Incumbent ID | Source status | Native evidence and remaining behavior |
|---|---|---|
| `server-login` | Done | [SignInView.swift](Sources/App/SignInView.swift), [SessionStore.swift](Sources/App/SessionStore.swift), [IlyichApp.swift](Sources/App/IlyichApp.swift) — URL validation, feature-aware password login/autofill, explicit errors and forced password change are implemented. |
| `oauth` | Done | [OAuthSignIn.swift](Sources/App/OAuthSignIn.swift), [Info.plist](Config/Info.plist) — ASWebAuthenticationSession, state/PKCE and the compatible app.immich callback are implemented. Actual provider round-trip remains unverified. |
| `session-lifecycle` | Done | [SessionStore.swift](Sources/App/SessionStore.swift), [SharedSession.swift](Sources/Backup/SharedSession.swift) — Keychain restoration, nonblocking validation, offline retention, 401 sign-out, upload cancellation and account/cache/widget/network-credential cleanup are implemented. |
| `profile` | Partial | [SettingsView.swift](Sources/Features/SettingsView.swift), [ProfilePhotoView.swift](Sources/Features/ProfilePhotoView.swift) — Name/password/sign-out, server counts/version and cropped profile-photo upload/removal exist. User storage/quota display is absent. |

### Networking and server compatibility

| Incumbent ID | Source status | Native evidence and remaining behavior |
|---|---|---|
| `endpoint-switching` | Partial | [ServerConnection.swift](Sources/Core/ServerConnection.swift), [NetworkConfiguration.swift](Sources/Core/NetworkConfiguration.swift), [NetworkSettingsView.swift](Sources/Features/NetworkSettingsView.swift) — Ordered reachable endpoints, proxy headers including separate proxy authorization and PKCS12 import/removal are implemented. Preferred-SSID selection and explicit reachability-test UI are absent. |
| `capability-gating` | Partial | [SignInView.swift](Sources/App/SignInView.swift), [SearchOptionsView.swift](Sources/Library/SearchOptionsView.swift), [Models.swift](Sources/Core/Models.swift) — Login/search flags are consumed. Map/trash/editing controls and protocol/version compatibility are not consistently gated; feature-fetch failures need a deliberate state. |

### Photo library and timeline

| Incumbent ID | Source status | Native evidence and remaining behavior |
|---|---|---|
| `merged-library` | Missing | [LibraryStore.swift](Sources/Library/LibraryStore.swift), [LocalLibraryViews.swift](Sources/Features/LocalLibraryViews.swift) — Server timeline and device library are separate. No unified checksum/cloud-ID merge, local-only/backed-up status or duplicate-free local/remote presentation exists yet. |
| `timeline-navigation` | Partial | [PhotoGrid.swift](Sources/Library/PhotoGrid.swift), [TimeRail.swift](Sources/Library/TimeRail.swift), [LibraryStore.swift](Sources/Library/LibraryStore.swift) — Virtualized dated server grid, scrubber, refresh, density setting and pinch density exist. Storage indicators and timeline memory lane remain absent; portrait/landscape scroll continuity requires UI verification. |
| `bulk-selection` | Partial | [LibraryView.swift](Sources/Library/LibraryView.swift), [PhotoGrid.swift](Sources/Library/PhotoGrid.swift), [BulkActionsView.swift](Sources/Library/BulkActionsView.swift) — Long-press/drag selection, date-group selection, count/cancel and expanded bulk favorites/archive/lock/album/tag/stack/share/edit actions exist. Complete merged local/remote eligibility and capability transitions remain incomplete; current controls enforce read-only mode. |
| `library-collections` | Partial | [MoreCollectionsView.swift](Sources/Features/MoreCollectionsView.swift), [LibraryView.swift](Sources/Library/LibraryView.swift) — Favorites/archive/locked/trash/video/motion/Lightroom/people/places/memories/folders and local albums are reachable. Dedicated recently-taken/recently-added entry points and uniform collection bulk actions are incomplete. |

### Backup, uploads and device library

| Incumbent ID | Source status | Native evidence and remaining behavior |
|---|---|---|
| `photos-permissions` | Done | [LocalPhotoLibrary.swift](Sources/Features/LocalPhotoLibrary.swift), [LocalLibraryViews.swift](Sources/Features/LocalLibraryViews.swift), [PhotoLibrary.swift](Sources/Backup/PhotoLibrary.swift) — Request/denied/limited access, limited-picker management, change observation, local albums and shared-album metadata exist. Permission transitions still require device tests. |
| `backup-selection` | Partial | [BackupSettingsView.swift](Sources/Backup/BackupSettingsView.swift), [BackupCoordinator.swift](Sources/Backup/BackupCoordinator.swift) — Included/excluded/off albums, remaining/current progress and confirmed counts exist. Per-asset source-album/detail screens are absent. |
| `backup-policies` | Done | [BackupSettingsView.swift](Sources/Backup/BackupSettingsView.swift), [BackupLifecycle.swift](Sources/Backup/BackupLifecycle.swift), [PhotoLibrary.swift](Sources/Backup/PhotoLibrary.swift) — Automatic backup, photo/video cellular choices, charging/delay/thermal constraints and permitted iCloud exports are implemented. Foreground/background policy behavior requires device verification. |
| `backup-transfer` | Partial | [BackgroundUploads.swift](Sources/Backup/BackgroundUploads.swift), [BackupCoordinator.swift](Sources/Backup/BackupCoordinator.swift), [BackupSettingsView.swift](Sources/Backup/BackupSettingsView.swift), [PhotoResourceExport.swift](Sources/Backup/PhotoResourceExport.swift) — Durable queue, background recovery, pause/retry/cancel, export/upload progress, speed and per-file failure records exist. Full pending/success item detail and source-album inspection remain incomplete. |
| `backup-media-integrity` | Done | [PhotoLibrary.swift](Sources/Backup/PhotoLibrary.swift), [BackupCoordinator.swift](Sources/Backup/BackupCoordinator.swift), [BackupReceipt.swift](Sources/Backup/BackupReceipt.swift) — Stream hashes, checksum deduplication, original names/dates, current full-size PhotoKit rendition, paired Live Photo upload and revision stacking now exist. Edited/cloud/paired-resource behavior requires device tests; cleanup conservatively retains resources without complete receipts. |
| `background-lifecycle` | Partial | [BackupLifecycle.swift](Sources/Backup/BackupLifecycle.swift), [BackgroundUploads.swift](Sources/Backup/BackgroundUploads.swift) — BGProcessing scheduling, expiry cancellation, power/thermal checks and upload continuation exist. Equivalent incremental metadata/hash synchronization and BGAppRefresh discovery behavior are incomplete. |
| `linked-albums` | Partial | [BackupCoordinator.swift](Sources/Backup/BackupCoordinator.swift), [BackupSettingsView.swift](Sources/Backup/BackupSettingsView.swift) — Optional sync now links/creates server albums and attaches receipt-backed uploaded assets without deleting server albums. Explicit per-album link selection/relink management and ambiguous same-name album handling need completion/review. |
| `manual-upload` | Partial | [LocalLibraryViews.swift](Sources/Features/LocalLibraryViews.swift), [BackupCoordinator.swift](Sources/Backup/BackupCoordinator.swift) — Selected local assets enter the real cancellable backup queue independently of automatic backup. Direct upload-then-add-to-selected-album and pending/partial album upload UI are absent. |

### Synchronization and offline operation

| Incumbent ID | Source status | Native evidence and remaining behavior |
|---|---|---|
| `local-database` | Missing | [TimelineCache.swift](Sources/Core/TimelineCache.swift), [LibraryStore.swift](Sources/Library/LibraryStore.swift) — A bounded visited-month cache exists, not the incumbent asset/EXIF/album/people/OCR entity database. Incremental sync events, migrations and websocket edit/upload notifications are absent. |
| `offline-browsing` | Partial | [TimelineCache.swift](Sources/Core/TimelineCache.swift), [MediaPipeline.swift](Sources/Core/MediaPipeline.swift), [LocalPhotoLibrary.swift](Sources/Features/LocalPhotoLibrary.swift) — Cached login, visited timeline metadata, bounded media cache and local PhotoKit browsing exist. Persistent secondary entity metadata, merged local fallback and cached detailed asset metadata remain incomplete. |
| `sync-recovery` | Missing | [TimelineCache.swift](Sources/Core/TimelineCache.swift), [LibraryStore.swift](Sources/Library/LibraryStore.swift) — Reload/retry exists. No entity-sync status/counts/manual resync or coherent remote edit/delete/restore event recovery. Diagnostics/cache-reset implementation is assigned next. |

### Photo/video viewer and metadata

| Incumbent ID | Source status | Native evidence and remaining behavior |
|---|---|---|
| `image-viewer` | Partial | [AssetViewer.swift](Sources/Viewer/AssetViewer.swift), [ViewerPhoto.swift](Sources/Viewer/ViewerPhoto.swift), [MediaPipeline.swift](Sources/Core/MediaPipeline.swift) — Swipe, pinch/double-tap, edge-navigation setting, chrome/dismissal, neighboring load and full-resolution upgrades exist. Animated image playback and merged local/remote source preference are absent. |
| `video-motion` | Done | [AuthenticatedVideo.swift](Sources/Viewer/AuthenticatedVideo.swift), [AssetViewer.swift](Sources/Viewer/AssetViewer.swift), [LocalPhotoLibrary.swift](Sources/Features/LocalPhotoLibrary.swift) — Authenticated seekable playback, autoplay/loop/mute/original controls, remote Live Photo still/video toggle and local PhotoKit video/Live Photo playback exist. Audio/rotation/cloud-only behavior needs device verification. |
| `asset-details` | Partial | [AssetInfoView.swift](Sources/Viewer/AssetInfoView.swift) — Caption/rating/EXIF/camera/date/location, owner/people/albums and editable date/GPS fields exist. Address search/location-picker parity, all timezone semantics and ownership gating need completion/verification. |
| `asset-actions` | Partial | [AssetViewer.swift](Sources/Viewer/AssetViewer.swift), [ViewerTagEditor.swift](Sources/Viewer/ViewerTagEditor.swift), [ViewerStackView.swift](Sources/Viewer/ViewerStackView.swift) — Favorite/archive/lock, tags, existing-stack management, album cover/profile image and browser actions exist. Full local/remote/partner/read-only eligibility and selection-based stack creation remain incomplete. |
| `casting` | Done | [CastController.swift](Sources/Cast/CastController.swift), [APIClient.swift](Sources/Core/APIClient.swift) — Real Google Cast discovery/session UI, receiver loading, controls, reconnect/error handling and short-lived server authorization exist. Cast receiver hardware and network reachability remain unverified. |

### Editing and custom developed media

| Incumbent ID | Source status | Native evidence and remaining behavior |
|---|---|---|
| `non-destructive-editing` | Partial | [PhotoEditor.swift](Sources/Viewer/PhotoEditor.swift), [Editing.swift](Sources/Core/Editing.swift) — Crop ratios/free crop/rotate/flip/reset, discard confirmation, server save and revision polling exist. Persistent edit-ready synchronization after navigating away is absent. |
| `lightcraft-developed-previews` | Partial | [MediaPipeline.swift](Sources/Core/MediaPipeline.swift), [MediaIdentity.swift](Sources/Core/MediaIdentity.swift), [PhotoEditor.swift](Sources/Viewer/PhotoEditor.swift), [ImmichAPI.swift](Extensions/Widget/ImmichAPI.swift) — Developed/edited thumbnails, revision keys, published base dimensions and original-vs-displayed export semantics exist. Sidecar change event propagation and every widget/share/Cast rendering path require verification. |

### Search, custom natural-language behavior and OCR

| Incumbent ID | Source status | Native evidence and remaining behavior |
|---|---|---|
| `search-modes` | Done | [SearchOptionsView.swift](Sources/Library/SearchOptionsView.swift), [LibraryStore.swift](Sources/Library/LibraryStore.swift), [Search.swift](Sources/Core/Search.swift) — Context/filename/description/OCR modes, locale, cursor paging, clear/focus and server ordering are implemented. Feature-disabled combinations require UI verification. |
| `search-filters` | Partial | [SearchOptionsView.swift](Sources/Library/SearchOptionsView.swift), [LibraryStore.swift](Sources/Library/LibraryStore.swift), [SimilarPhotosView.swift](Sources/Library/SimilarPhotosView.swift) — People/tags/location/camera/date/type/rating/favorite/archive/not-in-album filters, quick dates and similar-photo search exist. Metadata suggestions and complete paginated people/tag choices are absent. |
| `custom-natural-search` | Done | [Search.swift](Sources/Core/Search.swift), [LibraryStore.swift](Sources/Library/LibraryStore.swift) — Natural-language requests remain server planned; locale/scope/query-asset and verification complete/partial/unavailable semantics are represented. Validate fork-specific real query scenarios against the live server. |
| `ocr-viewer` | Partial | [OCRPhotoReader.swift](Sources/Viewer/OCRPhotoReader.swift), [ViewerPhoto.swift](Sources/Viewer/ViewerPhoto.swift), [AssetInfoView.swift](Sources/Viewer/AssetInfoView.swift) — Zoom-aligned quadrilateral overlay, text selection/copy and accessible text regions exist. Persistent OCR entity sync remains absent; edited image coordinate geometry needs fixture/device validation. |

### People, places and map

| Incumbent ID | Source status | Native evidence and remaining behavior |
|---|---|---|
| `people` | Partial | [PeopleView.swift](Sources/Features/PeopleView.swift), [AssetInfoView.swift](Sources/Viewer/AssetInfoView.swift), [LibraryStore.swift](Sources/Library/LibraryStore.swift) — People/person timelines, name/birthday edits, detail associations and filters exist. Birthday/age display and persisted face associations are incomplete. Full web face-management is not required by this mobile inventory. |
| `places-map` | Partial | [PlacesView.swift](Sources/Features/PlacesView.swift), [PlacesGlobeView.swift](Sources/Features/PlacesGlobeView.swift), [AssetInfoView.swift](Sources/Viewer/AssetInfoView.swift) — 3D day/night globe, bounded photo markers, pan/pinch/focus, exact photo groups and MapKit styles exist. Favorite/date/archive/partner filters, map feature gating and stale-request suppression are implemented. Address search/location picker for metadata edits remains absent; globe/marker visuals need device verification. |

### Albums, partners and collaboration

| Incumbent ID | Source status | Native evidence and remaining behavior |
|---|---|---|
| `album-management` | Partial | [AlbumsView.swift](Sources/Features/AlbumsView.swift), [AlbumAssetsManager.swift](Sources/Features/AlbumAssetsManager.swift) — Search/sort/create/name/description/cover/order/delete, remote add/remove and counts exist. Grid/list preference and date-range detail display are absent; local upload path is separate. |
| `shared-album-roles` | Partial | [AlbumsView.swift](Sources/Features/AlbumsView.swift), [AlbumAssetsManager.swift](Sources/Features/AlbumAssetsManager.swift) — Owner/editor/viewer checks, add/remove members and role updates exist. Self-leave membership and local upload/pending flows are absent; revoked-role/capability transitions need verification. |
| `comments-likes` | Partial | [AlbumActivityView.swift](Sources/Features/AlbumActivityView.swift), [AssetViewer.swift](Sources/Viewer/AssetViewer.swift) — Album/asset-context comments, likes, permitted deletion and owner activity toggle exist. Incoming activity deep links do not yet preserve album+asset context. |
| `partner-sharing` | Done | [MoreCollectionsView.swift](Sources/Features/MoreCollectionsView.swift), [APIClient.swift](Sources/Core/APIClient.swift) — Incoming/outgoing libraries, share/unshare confirmation, timeline inclusion and partner timeline navigation are implemented. Shared ownership/action behavior still needs device/API scenario verification. |

### Sharing, download and import

| Incumbent ID | Source status | Native evidence and remaining behavior |
|---|---|---|
| `outgoing-file-share` | Partial | [AssetViewer.swift](Sources/Viewer/AssetViewer.swift), [BulkActionsView.swift](Sources/Library/BulkActionsView.swift), [APIClient.swift](Sources/Core/APIClient.swift) — Single/multiple file system share, displayed/original exports and isolated temporary cleanup exist. Complete per-file preparation progress/cancel and persisted share-quality preference remain incomplete. |
| `public-share-links` | Done | [SharedLinksView.swift](Sources/Features/SharedLinksView.swift), [AssetViewer.swift](Sources/Viewer/AssetViewer.swift) — Album/individual create/list/edit/delete, native copy/share, slug/description, password/expiry and metadata/upload/download controls exist. |
| `download-to-photos` | Partial | [AssetViewer.swift](Sources/Viewer/AssetViewer.swift), [APIClient.swift](Sources/Core/APIClient.swift) — Photo/video downloads and PhotoKit add-only saving now assemble Live Photo still+paired video in a single creation transaction. Multi-item download task UI and cancellable progress are incomplete; actual Live Photo metadata pairing requires device validation. |
| `incoming-share-extension` | Partial | [ShareViewController.swift](Extensions/Share/ShareViewController.swift), [SharedInbox.swift](Sources/Backup/SharedInbox.swift), [ShareInboxStore.swift](Sources/Backup/ShareInboxStore.swift), [ShareInboxView.swift](Sources/Backup/ShareInboxView.swift) — Durable file staging, signed-in main-app review/selection, RAW+XMP and Live Photo attachment pairing, upload/progress/dedup/cancel gates are implemented. Cold launch/login callback and file formats need end-to-end verification. Source re-audit found old Dart consumes files only: plain text/non-file URL content and destination-album choice were inventory overstatements, not incumbent parity gaps. |

### Locked media, deletion and cleanup

| Incumbent ID | Source status | Native evidence and remaining behavior |
|---|---|---|
| `locked-folder` | Done | [LockedFolderView.swift](Sources/Features/LockedFolderView.swift), [PINSettingsView.swift](Sources/Features/PINSettingsView.swift) — Server elevation, PIN setup/change/remove, biometric-protected scoped PIN, unavailable/cancel flows and background/pop/expiry relocking are implemented. Device security/privacy-transition validation remains mandatory. |
| `delete-trash-restore` | Partial | [DuplicatesView.swift](Sources/Features/DuplicatesView.swift), [AlbumAssetsManager.swift](Sources/Features/AlbumAssetsManager.swift), [LocalLibraryViews.swift](Sources/Features/LocalLibraryViews.swift) — Selected and all-item server restore/permanent deletion, explicit irreversible confirmations, distinct album removal and verified local cleanup exist. Trash capability gates and cache invalidation are implemented. Unified merged local/server deletion semantics remain incomplete. |
| `free-up-space` | Partial | [LocalLibraryViews.swift](Sources/Features/LocalLibraryViews.swift), [CleanupPolicy.swift](Sources/Features/CleanupPolicy.swift), [BackupReceipt.swift](Sources/Backup/BackupReceipt.swift) — Verified candidates/preview/count, favorites/album/type/date retention, re-verification/session checks and explicit PhotoKit confirmation exist. Exact recoverable-byte estimate is absent; never claim bytes freed for iCloud-optimized items. |
| `read-only-mode` | Done | [ReadOnlyPolicy.swift](Sources/Core/ReadOnlyPolicy.swift), [APIClient.swift](Sources/Core/APIClient.swift), [WriteAccess.swift](Sources/Features/WriteAccess.swift), [SettingsView.swift](Sources/Features/SettingsView.swift), [BackgroundUploads.swift](Sources/Backup/BackgroundUploads.swift) — Server/account-scoped shared flag blocks server mutations and uploads while keeping browsing/search/session unlock usable. Mutation affordances disable, enabling pauses backup/share transfers, and local cleanup/save checks the flag before PhotoKit writes. Cross-process and late-request behavior require device verification. |

### Memories and slideshow

| Incumbent ID | Source status | Native evidence and remaining behavior |
|---|---|---|
| `memories` | Partial | [MoreCollectionsView.swift](Sources/Features/MoreCollectionsView.swift), [SlideshowView.swift](Sources/Features/SlideshowView.swift) — Today/saved memory list, title/date, save toggle and real slideshow playback exist. Main-timeline memory lane, memory deep links and incumbent epilogue/progress presentation are incomplete. |
| `slideshow` | Done | [SlideshowView.swift](Sources/Features/SlideshowView.swift), [AssetViewer.swift](Sources/Viewer/AssetViewer.swift) — Timing/repeat/direction/shuffle/look, pause/progress/previous/next and video-end advancement exist. Viewer uses its supplied loaded window; continuous whole-collection loading is not implemented. |

### Widgets, deep links and platform integration

| Incumbent ID | Source status | Native evidence and remaining behavior |
|---|---|---|
| `widgets` | Partial | [ImmichAPI.swift](Extensions/Widget/ImmichAPI.swift), [ImageEntry.swift](Extensions/Widget/ImageEntry.swift), [project.yml](project.yml) — Random album/favorites and memory widget source is included with shared account/network configuration, scoped cache and logout clearing. Memory links currently route to assets; endpoint-change refresh and installed timeline/configuration need verification. |
| `deep-links` | Partial | [AppLink.swift](Sources/App/AppLink.swift), [SessionStore.swift](Sources/App/SessionStore.swift), [LibraryView.swift](Sources/Library/LibraryView.swift), [ShareInboxView.swift](Sources/Backup/ShareInboxView.swift) — Validated UUID asset/album/person app-scheme and same-origin web links exist. Durable ShareMedia handoff is being integrated. Memory/activity/album-context routes remain incomplete. |
| `platform-access` | Partial | [Info.plist](Config/Info.plist), [project.yml](project.yml), [LocalLibraryViews.swift](Sources/Features/LocalLibraryViews.swift), [CastController.swift](Sources/Cast/CastController.swift) — PhotoKit permission/save/delete, Cast local-network permission and native sharing exist. App localization, notification/SSID controls and configurable haptics remain absent. User now targets only iPhone 15 Pro on iOS 27; iPad, older OS compatibility and other form factors are excluded. Dynamic Type, accessibility, ProMotion and portrait/landscape need device validation. |

### Settings, diagnostics and support

| Incumbent ID | Source status | Native evidence and remaining behavior |
|---|---|---|
| `preferences` | Partial | [SettingsView.swift](Sources/Features/SettingsView.swift), [SlideshowView.swift](Sources/Features/SlideshowView.swift), [NetworkSettingsView.swift](Sources/Features/NetworkSettingsView.swift) — Theme/grid, viewer playback/quality/navigation, slideshow/network/cleanup/backup preferences exist. Language/accent/haptics/grouping/storage indicator/album grid-list/share-quality preferences are incomplete. |
| `diagnostics` | Partial | [DiagnosticsView.swift](Sources/Features/DiagnosticsView.swift), [Diagnostics.swift](Sources/Core/Diagnostics.swift), [TimelineCache.swift](Sources/Core/TimelineCache.swift), [MediaPipeline.swift](Sources/Core/MediaPipeline.swift) — Sanitized bounded request log, errors/all/off levels, export/clear, actual cache usage/reset, backup counts and server/app details exist. Persistent entity-sync status and per-asset troubleshooting are incomplete. No credentials, URLs, IDs, queries, bodies or raw error text enter exported request logs. |

## Completion gates

1. Close the missing/partial behaviors without replacing them with labels or inactive controls. Refresh this ledger as each owner lands concrete code.
2. Run the current iPhone unit/UI/extension/archive checks, then review real screenshots against the approved design.
3. Exercise signed-device flows with disposable test media: limited/full permissions, iCloud-only and edited assets, Live Photo backup/save, background resume, role restrictions, read-only mode, PIN/biometric/expiry, cleanup retention, incoming/outgoing share handoff, widget links and Cast.
4. Preserve the fork’s natural-language verification semantics, OCR geometry and Lightroom-rendered appearance. Do not claim whole-library offline availability or Lightroom-equivalent development beyond the incumbent capabilities.
