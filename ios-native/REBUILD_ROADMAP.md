# Native iOS rebuild roadmap

Working roadmap for [IOS_ARCHITECTURE_PLAN.md](../IOS_ARCHITECTURE_PLAN.md), from a read-only map of the code on 2026-10-20. Milestones run in dependency order; each must build, pass its tests and install on the phone. The critic's corrections at the end apply before the milestones they name.

## Target architecture

TARGET ARCHITECTURE (native iOS rebuild)\n\n0. RULES\n- One owner per piece of state. Views render values and send commands. Services own their Tasks; a service cancels its Tasks when it ends.\n- A device-scoped singleton exists only where iOS allows one per process:\n  - background URLSessions (TransportRegistry);\n  - BGTaskScheduler registration (LifecycleEventSource);\n  - the PhotoKit change observer and caching image manager (PhotoKitAdapter);\n  - the Google Cast context.\n  Everything account-specific lives in one AccountRuntime per signed-in account, torn down in a fixed order.\n- Nothing runs on the main actor that touches SQLite, the Keychain, file enumeration, PhotoKit fetches or image decoding. SQLite, ImageIO and PhotoKit work runs on dedicated serial queues used as custom executors, never on the cooperative pool.\n- Any result that can outlive a change of account, token, read-only state or Locked Folder elevation carries an AuthorizationEpoch. Stores commit only results whose epoch is current.\n- Persisted formats stay byte-identical, or an idempotent importer pinned by golden fixtures migrates them.\n- One execution engine per subsystem in every build. A replacement lands in the same milestone that deletes its predecessor. Temporary adapters are listed in section 9 with the milestone that removes each one.\n\n1. COMPONENTS (owner, executor, inputs and outputs)\n\nDEVICE SCOPE\n- IlyichAppDelegate (main). In didFinishLaunching it synchronously:\n  - registers the BG tasks;\n  - creates TransportRegistry, BackgroundEventAcks and PhotoKitAdapter;\n  - starts AccountManager.restore in an owned Task.\n  handleEventsForBackgroundURLSession calls acks.register FIRST, then touches registry.transport(id).\n- LifecycleEventSource (main).\n  - Inputs: BGTaskScheduler, NWPathMonitor, battery, thermal state, Low Power, app state.\n  - Output: AsyncStream<LifecycleEvent>.\n  - schedule(SchedulePlan) is called only by the TransferEngine.\n- TransportRegistry plus one BackgroundTransport per TransferSessionID (backup, share-upload). Each runs on a serial delegate OperationQueue. It accepts submit(request, bodyURL, AttemptKey) and returns a task id. The delegate atomically writes an Outcome file before it yields .finished. Outputs: a TransportEvent stream (progress, finished, drained) and inventory().\n- BackgroundEventAcks (main). Queues system completion handlers per identifier. Each handler runs after the engine commits that session's outcomes, or after a 20 s deadline.\n- PhotoKitAdapter: actor on DispatchSerialQueue app.ilyich.photokit (.userInitiated).\n  - The only PHPhotoLibraryChangeObserver. Bursts are coalesced over 250 ms and published as DeviceLibraryChange.\n  - access with a generation number; reads; staging export; perform(DeviceMutation).\n  - Media requests (image, playerItem, livePhoto) are nonisolated and use one shared PHCachingImageManager.\n  - Mutations are journaled in DeviceDatabase.\n- DeviceDatabase: Application Support/IlyichDevice/device.sqlite, on its own queue. Tables: device_mutation, device_fingerprint.\n- AccountManager: actor.\n  - Phases: restoring, waitingForUnlock, signedOut(reason), passwordChangeRequired, active, signingOut.\n  - Transitions are serialized. Opens and tears down the AccountRuntime.\n- GCK CastContext (main), set up at launch.\n\nACCOUNT SCOPE: AccountRuntime, a Sendable final class opened off-main\n- AuthorizationState: a Mutex snapshot with an epoch and an updates stream. Writes the App Group mirror keys account.digest and account.authorizationEpoch, and keeps the access epoch beside them in account.accessEpoch.\n- ServerTransport (actor) with ServerConnection (actor, in the package). APIClient remains as the endpoint catalogue over the transport. One set of URLSessions per runtime, invalidated at shutdown.\n- ServerCapabilities (actor). SyncEngine (actor): the only writer of SyncStatus; publishes LibraryChange.\n- LibraryIndex, over the existing entities file:\n  - IndexWriter on serial queue ilyich.index.writer (.utility), owning the only read-write connection;\n  - IndexReader.viewport (.userInitiated) and IndexReader.aggregate (.utility), each with its own read-only connection;\n  - DependentRepairer (actor).\n- LibraryRepository: QueryPlanner, ServerTimelineBackend, ServerSearchBackend and the offline fallbacks. Returns Fenced results.\n- LibraryChangeHub (actor). Gives each subscriber a merging mailbox and never drops a change.\n- MediaPipeline (actor). Previews, full-size images, faces and locked media only.\n- ThumbnailService:\n  - ThumbnailDiskStore (actor on its own queue);\n  - DecodedThumbnailCache (Mutex LRU);\n  - ThumbnailScheduler (actor);\n  - ThumbnailFetcher;\n  - DecodeLanes: 3 serial .userInitiated queues and 1 .utility queue;\n  - CoverageWorker (actor);\n  - DeviceThumbnailSource (main).\n- Transfers:\n  - TransferStore: actor on its own queue, Application Support/IlyichTransfers/<digest>.sqlite. Private container: never the app group, to avoid 0xdead10cc.\n  - TransferEngine: actor with one owned loop.\n  - PostUploadWorker (actor), TransferNotifier (main).\n  - LegacyBackupImporter, until C8 (removed: nothing on the phone still holds a state.json).\n- ReceiptRepository (TransferStore). CleanupService (actor) with RemoteCopyVerifier. DeviceIndexService (actor).\n- LibraryMutationService (actor), CollectionsService (actor), MediaExportService (actor).\n- Cast: CastGrantStore (actor) and CastSessionService (main).\n- WidgetRefreshCoordinator (main). OwnedWork (actor): cancelAndJoin at shutdown.\n\nPRESENTATION (main actor, account-scoped)\n- AccountSession, SignInModel, SettingsCatalog.\n- LibraryScreenModel:\n  - LibraryNavigator and PresentationHost;\n  - LibraryFeedStore: FeedSession, TimelineFeed (actor), SearchFeed (actor), MonthProjector (@concurrent), MonthPlacesService (actor);\n  - FeedSelection, CollectionsStore, PeopleDirectory and PeoplePager;\n  - GridViewport, TimeRailController, ThumbnailBinder.\n- ViewerModel, BackupStore, ShareInboxModel, FreeUpSpaceStore, DeviceBrowserStore, DevicePhotoActionsStore, LockedFolderSession.\n\nEXTENSIONS (local package Packages/IlyichKit, Swift 6)\n- IlyichPlatform: AppGroup, AccountID, AccountStoragePaths, CredentialStore, NetworkConfiguration and its stores, ServerConnection, ReadOnlyPolicy, AuthorizationMirror.\n- IlyichShareInbox: manifest v2 reader and writer (the v1 reader went in C8), ShareInboxRepository, ShareStaging, PhotoResourceExport.\n- IlyichWidgetCore: WidgetMediaClient, WidgetTimelinePlanner, WidgetSnapshotStore.\n- The Share extension uses ShareInbox and Platform, with no credentials and no networking. The Widget uses WidgetCore and Platform.\n\n2. CONTRACTS (Swift sketches)\n\nIdentity and authorization\n- AccountID { server: URL /*normalized, ends in /api*/; userID; cacheScope = server.absoluteString+'|'+userID; digest = sha256hex(cacheScope) == SavedSession.scope }\n- AccountStoragePaths: the only place per-account names are derived. A test pins each name to today's code: IlyichEntities/<digest>.sqlite, Application Support/IlyichThumbnails/<digest[0..<32]> (Caches before T8), IlyichMedia/<digest>, <group>/Backup/<digest>, <group>/WidgetCache/<digest>, readOnly.<sha256(normalized|user)>, the locked PIN account, shelfOrder.<kind>.<cacheScope>.\n- StoredCredential: byte-equal to the SavedSession v1 JSON.\n- protocol CredentialStore { load() throws(CredentialError) -> StoredCredential?; save; remove }\n- CredentialError { signedOut, locked, missingEntitlement, keychain(OSStatus), corrupt }\n- struct AuthorizationEpoch: Hashable, Sendable { account: AccountID; value: UInt64 }\n- struct AuthorizationSnapshot { epoch; tokenDigest; readOnly; requiresPasswordChange; privateEpoch; func allows(_ op: Operation) -> Bool }\n- struct Fenced<V: Sendable> { epoch; value }\n\nFailures\n- enum ServerFailure: sessionExpired(String?) (a 401 with an Immich error body) | credentialsRejected(String) (a 401 on auth/login or oauth/callback; the server text is shown) | proxyRejected(Int) (401/403/407 without an Immich body) | forbidden(String?) | notFound | http(Int,String?) | undecodable | readOnly | passwordChangeRequired\n- enum TransportFailure: unreachable(URLError.Code) | endpointChanged | allEndpointsUnavailable | systemCancelled(reason: Int?)\n- enum FailureClass: transient(retryAfter: Duration?) | waiting(WaitReason, jobScoped: Bool) | account(AccountRestriction) | item(String)\n- WaitReason: deviceConditions | unmeteredNetwork | connectivity | serverBackoff\n- AccountRestriction: signedOut | sessionExpired | proxyRejected | readOnly | passwordChange | photosAccess | deviceStorage\n\nLibrary\n- MonthKey { year, month; init?(bucketID:); bucketID = YYYY-MM-01 }\n- AssetRevision { referenceSeconds: Double } stores PHAsset.modificationDate bit-exactly.\n- struct LibraryQuery: Hashable, Sendable\n  - Scope: library (me + partners with inTimeline) | mine | partner(id) | album(id) | person(id) | place(PlaceMembership)\n  - Trash: active | trashed\n  - Visibility: OptionSet of timeline and archive; hidden and locked cannot be expressed.\n  - Ranking: chronological(takenAt|createdAt, ascending) | relevance(text(q, mode, language) | similar(to:))\n  - Stacks: primaryOnly | all\n  - Predicates: favorite, developed, kind, motion, people, tags, inAnyAlbum, rating, taken, camera, location, text\n  - Presets: library, favorites, archive, trash, recentlyTaken, recentlyAdded, lightroom, videos, motion, partner, album, person, place\n  - refined(text:mode:) and similar(to:) keep scope, trash, visibility, stacks and developed.\n  - stableKey: the library's key equals today's TimelineFilter key.\n- LockedFolderQuery: served only by the server timeline, and only under an elevated epoch.\n- PlaceMembership { placeID; revision = sha256(sorted ids + marker query); assetIDs }. Equality and hashing use placeID and revision.\n- QueryPlan { backend: index|serverTimeline|serverSearch; limitations: Set<Limitation> }\n- Limitation: noMonths, includesStackMembers, excludesSharedAlbumMembers, ownerPostFilter, developedPostFilter(scanBudget:), indexStale(since:)\n- Unsupported: placeNeedsIndex, orderNotSearchable, predicate\n\nChanges\n- struct LibraryChange\n  - Identity: account; authorization; indexRevision; origin (sync | mutation(OperationID) | device).\n  - Assets: upserted [id: MonthMove]; removed; accessLost; mediaRevisions [id: rev].\n  - Collections: albums; people; stacks; collections [CollectionChange].\n  - Flags: partnersChanged, memoriesChanged, reset, routingChanged, configurationChanged, overflow.\n  - merge(_:)\n- CollectionChange: albumCreated | albumUpdated | albumDeleted | albumLeft | personUpdated | partnersChanged | memorySaved\n- enum MutationRequest: favorite, visibility, trash, deletePermanently, restore, restoreAllTrash, emptyTrash, addToAlbum, removeFromAlbum, setAlbumCover, createAlbum, stack, unstack, removeFromStack, setStackCover, update, rating, tag, reassignFace, removeFace, edits, resolveDuplicate, dismissDuplicate\n- MutationResult { operation; request; succeeded; failed [id: reason]; fresh [id: Asset]; followUp: LibraryChange? }\n\nDevice\n- DeviceAssetID and DeviceAlbumID: raw localIdentifier.\n- DeviceAccess { status, generation }\n- ResourceShape: singleOriginal | livePhoto | edited | multipleOriginals | other. classify(types, isVideo) is pure.\n- DeviceAsset { id, revision, created, isVideo, isLive, isFavorite, location, shape, canDelete, canEditProperties }\n- DeviceLibraryChange { access, inserted, removed, changed, albumsChanged, requiresFullReload }\n- DeviceMutation: delete(ids, expected [id: AssetRevision], origin) | setFavorite(ids, Bool, expected) | create(still, video, pairedVideo, origin)\n- MutationOrigin: user | cleanup(scan, account) | saveFromServer(asset, account)\n- DeviceMutationResult outcome: committed(affected, created) | declined | revisionChanged | notPermitted | failed\n\nTransfers\n- TransferLane: library | share\n- TransferSource: photo(localID) | shared(batch, attachment)\n- JobOrigin: discovery | selection | albumUpload | shareApproval | legacy\n- JobState: queued, staging, staged, submitting, submitted, finalizing, retryScheduled, waiting, failed\n- RunIntent: paused | automatic | manual. It gates only the library lane.\n- Lease { job, token, epoch }\n- AttemptID: a UUID. A legacy stageID or share identity is kept verbatim.\n- TransferSessionID.identifier = Bundle.main.bundleIdentifier + .backup | .share-upload (on the phone: app.alextran.immich.H4K2MSF2SG.*)\n- TaskDescriptor\n  - v2: {v:2, attempt, scope, outcome: path relative to the app group}\n  - legacy: {id, receipt: absolute URL}, resolved by locating the Backup/ or ShareInbox/ path component (decoding retired in B10; since C8 such a description is foreign)\n  - foreign\n- OutcomeRecord: the legacy keys {receipt, error, httpStatus} plus optional errorDomain, errorCode, cancelReason and v.\n- protocol TransferTransport { submit; results(); acknowledge(key); inventory(); cancel(scope:); progress() }\n- protocol TransferServerAPI { bulkUploadCheck; uploadRequest; remoteAsset(strict, no offline fallback); livePhotoVideoID; setLivePhotoVideo; createStack; addToAlbum; ownedAlbums; createAlbum }\n- protocol PhotoLibraryStaging { authorization; albums; candidates(stream of (id, revision) batches); stage(id, into, stageID, policy, progress); albumMembers }\n- TransferSnapshot { intent; phase; remaining; confirmed; failed; fileProgress; bytesSent; bytesExpected; bytesPerSecond; lastMessage }\n- EnqueueResult: queued(n) | alreadyBackedUp(n) | refused(AccountRestriction)\n- protocol TransferControlling: setIntent, enqueue, cancel, setPreferences, retry, snapshots, queuePage, historyPage, failures, albumUploadCounts\n\nLifecycle\n- LaunchReason: user | backgroundTask | urlSessionEvents(id)\n- EnvironmentSnapshot { appActive, network: none|unmetered|expensive|constrained, charging, thermal, lowPower }\n- LifecycleEvent: window(BGTaskLease) | becameActive | enteredBackground | environment | photoLibraryChanged | urlSessionEvents | preferencesChanged | readOnlyChanged\n- BGTaskLease.expire() calls setTaskCompleted(false) synchronously, with no await.\n\nThumbnails\n- ThumbnailKey: server(assetID, revision) | device(localID, modified)\n- DecodeTier: sketch < scrub < grid\n- ThumbnailRequest { key, thumbhash, shortSide }\n- DemandBand: visible < target < ahead < explicit < behind < coverage\n- Motion: idle(since) | tracking(speed) | flinging(speed) | scrubbing\n- ViewportDemand { generation, items [(request, band, rank)], motion }\n- ThumbnailInvalidation: assets(ids) | revoked(ids) | account | reconcile\n\nFeed\n- FeedSectionKey: month(MonthKey) | results\n- MonthProjection { key, entries, ids, dayGroups?, placeSummary? }\n- MonthState: unloaded | loading | loaded | failed\n- FeedSnapshot\n  - sessionID changes only when the scope changes.\n  - structure increments when counts or order change; the grid reloads and restores its anchor.\n  - content increments when only cells need reconfiguring.\n  - Also carries sections, months, results and totalCount.\n- protocol TimelineSource { plan; summary; month; monthPlaces }\n- protocol SearchSource { smart; metadata }\n\nNavigation\n- ModalRoute: viewer(ViewerRoute) | phoneViewer | people | albums | more(path) | memories(initialID) | activity(album, asset) | searchOptions | settings(SettingsRoute) | albumEditor | albumSharing | selectionActions(snapshot) | newAlbum | sharedFiles | confirm\n- ViewerRoute { initialAssetID, source: AssetSourceID (feed | collection | stack | similar | single | locked), albumContext }\n- SettingsRoute: root, account, backup, appearance, grid, network, notifications, server, diagnostics, about\n- NavigationIntent: present | openAsset | showInTimeline | exploreLocation | apply(query) | openShelf\n- LibraryOverlay: none | shelves | earth\n\nCapabilities\n- AssetCapabilityPolicy.evaluate(asset, context) -> [AssetAction: offered | disabled(reason) | hidden]\n- context = viewer, authorization snapshot, features, origin, cast availability, local copy.\n\n3. STORES\n\nTransfers DB (per account, private container, WAL, synchronous=FULL, completeUntilFirstUserAuthentication, excluded from backup)\n- Engine and settings:\n  - meta(schema, legacy_import_digest, engine)\n  - preferences(id=1, json)\n  - engine_state(intent, blocker, last_message)\n- Jobs and attempts:\n  - jobs(id, lane, source_key, origin, state, seq, not_before, retry_count, phase, error fields, lease_token, lease_epoch, batch_id; UNIQUE(lane, source_key); index on lane, state, not_before, seq)\n  - stages(job_id, stage_id, folder relative to the app group, modification_date REAL, file jsons, fields_json, motion_remote_id, motion_checksum, original_checksum)\n  - attempts(id PK = attempt/stage id, job_id, part, session, state created|bodyWritten|submitted|interrupted|completed|failed|abandoned, body_path, body_bytes, checksum, os_task_id, remote_id, remote_status, http_status, error_domain, error_code)\n- Results:\n  - confirmations(local_id, modification_date REAL, confirmed_at)\n  - receipts(local_id, modification_date REAL, original_id, original_checksum, original_bytes, motion_id, motion_checksum, motion_bytes, confirmed_at, verified_at, local_deleted_at)\n- Follow-up work:\n  - album_destinations(local_id, album_id, remote_id, state, attempts, error)\n  - stack_tasks\n  - linked_albums\n  - share_consumed\n  - notification_batches(id, kind, total, completed, failed, started_posted, terminal_posted)\n- Dates are always REAL timeIntervalSinceReferenceDate, written with sqlite3_bind_double.\n\nDevice DB\n- device_mutation(id, account_digest, kind, origin, asset_ids, expected_revisions, created_at, finished_at, outcome)\n- device_fingerprint(local_id PK, revision REAL, checksum)\n\nLibrary index (the existing IlyichEntities file)\n- user_version 0 -> 1 adds:\n  - asset_index, with columns ordered the way the server sorts;\n  - album_member, person_member, locked_asset;\n  - orphan_dependent, dependent_repair;\n  - index_state (revision, backfill cursor);\n  - month_places.\n- Payloads, metadata and acknowledgements are untouched, so no re-sync.\n\nThumbnail index\n- index.sqlite in the existing thumbnail root: meta(epoch, usage, index_complete, coverage_cursor, coverage_mark, policy_hash) and thumbnail(stem, digest, tier, bytes, stored_at, last_access).\n- Files stay at <root>/<stem2>/<stem>.<revdigest16>.\n\nStaging and outcomes\n- Legacy layout stays valid: <group>/Backup/<digest>/<folder>/{original,motion,sidecar,<id>.multipart,<id>.receipt}\n- Shares: <group>/ShareInbox/<batch>/{manifest.json,<identity>.multipart,<identity>.receipt}\n- Multipart boundaries stay Ilyich-<attemptID> for backups and the identity for shares.\n\n4. FLOWS\n\nBoot (every launch reason)\n1. Register BG tasks synchronously.\n2. AccountManager.restore. A locked keychain gives waitingForUnlock, retried on protectedDataDidBecomeAvailable.\n3. AccountRuntime.open off-main.\n4. TransferStore.open, then the importer (authoritative from B9; since C8 the engine claims the database as it is).\n5. TransportRegistry.connect, then Recovery.reconcile, then apply outcomes, then ack drained sessions.\n6. SyncEngine starts (foreground only). Feeds open from the index.\n\nDelegate events never need the database: outcomes are files, so a session created before the import is safe.\n\nSync\n1. SyncEngine pass.\n2. IndexWriter commits one transaction per batch: entities, derived rows and acks together.\n3. A precise LibraryChange goes to the hub.\n4. Consumers act:\n   - TimelineFeed invalidates the months touched;\n   - SearchFeed prunes results;\n   - the thumbnail and media services forget removed assets and purge assets whose access was lost;\n   - DeviceIndexService, CollectionsStore, WidgetRefreshCoordinator and ViewerModel update.\n\nMutation\n1. A store command calls LibraryMutationService.start. The service owns the Task.\n2. One HTTP call. Bulk results allow partial success.\n3. Precise media invalidation.\n4. The hub publishes. The feed applies FeedMembership.\n5. The result of the follow-up sync pass is merged in.\n\nViewport\n1. Scroll delegate and rail pan go to GridViewport (motion EMA, fling target, ahead/behind windows, pins).\n2. ViewportDemand, at most one per frame and also when a month becomes ready.\n3. ThumbnailScheduler: presence map, then nonisolated disk read, decode lane or fetch.\n4. Deliveries are buffered with one main-actor hop per frame. ThumbnailBinder updates bound cells.\n\nBackup job\n1. Rows are created, then the loop takes a lease.\n2. Stage through the adapter. Record the checksum once.\n3. For each part, motion first (hidden, without metadata) and then the still with livePhotoVideoId:\n   a. bulk-upload-check;\n   b. write the body;\n   c. write the attempt row as submitting;\n   d. transport.submit;\n   e. mark submitted.\n4. A result arrives, live or reconciled, and is classified.\n5. One commit transaction WHERE lease matches: delete the job and stage; upsert the confirmation and receipt; set album_destinations.remote_id; insert a stack task; increment the batch.\n6. acknowledge, which deletes the outcome file and the body.\n7. PostUploadWorker runs the side effects.\n\nURLSession relaunch\n1. Register the ack.\n2. The delegate writes outcome files.\n3. engine.applyOutcomes(id) commits.\n4. ack(id), or after the 20 s deadline. Unknown identifiers are acked immediately.\n\nSign-out\n1. Bump the epoch and the mirror.\n2. Cancel and join owned work.\n3. Within 3 s, while network credentials still exist: auth/logout and DELETE the cast session.\n4. Remove the credential (tombstone first), the widget cache, notifications and the locked PIN.\n5. Apply the data policy for the sign-out reason.\n6. Shut down the transport and clear diagnostics.\n7. Publish signedOut.\n\n5. FAILURE CLASSES\n- item: only the user retries. It covers:\n  - BackupError.item; HTTP 413, 415, 422;\n  - a bulk-check reject that is not a duplicate; a trashed duplicate;\n  - PHPhotosError identifierNotFound, invalidResource, missingResource, requestNotSupportedForAsset;\n  - networkAccessRequired while iCloud downloads are off;\n  - missing or corrupt files; a Live pair conflict.\n- waiting:\n  - device conditions: the whole engine waits;\n  - an iCloud original that needs Wi-Fi: only that job waits;\n  - notConnected, connectionLost, dataNotAllowed, roaming off: the engine waits for connectivity;\n  - three consecutive 5xx: serverBackoff.\n  Any condition event clears these, whether the intent is manual or automatic.\n- transient: timedOut, cannotConnect, DNS, TLS; 408, 425, 429, 500, 502, 503, 504; an invalid response; a system-cancelled outcome (force-quit). Backoff is 30 s x 2^n with 20 % jitter, capped at 1 h. Unknown errors are transient for 5 attempts, then item.\n- account: explicit and engine-wide; automatic triggers never clear it. Covers sessionExpired (live or replayed), proxyRejected, readOnly, passwordChange, Photos access denied, out of storage.\n\n6. INVARIANTS\n\nDeletion safety (CleanupService and PhotoKitAdapter)\n- DS1. An asset is deleted only if:\n  - it is in the in-app selection;\n  - it is in the live candidates of the current scan;\n  - iOS's own prompt was accepted.\n- DS2. A candidate needs a receipt in the current account, not marked locally deleted. Its revision must be bit-equal to the asset's modificationDate at scan time and again inside the change block.\n- DS3. The shape must be singleOriginal, or livePhoto with a motion receipt. Edited, alternate/RAW+JPEG, adjustment and multiple-original assets are never candidates.\n- DS4. A fresh strict GET with no offline fallback must show the same id, owner == user, checksum == receipt checksum and not trashed. A Live Photo also needs livePhotoVideoId == motion id, with the motion asset passing the same match. Any other verdict (404, 403, 5xx, transport error, decode error) excludes only that item. A 401 aborts the scan.\n- DS5. Remove re-verifies only the selection, immediately before perform. Any failure removes nothing.\n- DS6. The account digest, token digest, read-only off and the epoch are checked after re-verification and again immediately before perform.\n- DS7. The policy is re-applied with current settings and fresh kept-album membership. Unknown values fail closed.\n- DS8. The change block issues a request only if every asset exists, canPerform(.delete) holds and every revision matches. Otherwise it issues nothing.\n- DS9. The journal row is written before performChanges. Receipts are marked local_deleted_at only on a committed outcome. Interrupted entries are reconciled at launch.\n- DS10. A declined iOS prompt is .declined, never an error, and receipts are untouched.\n- DS11. A scan is invalidated by a settings change, an access generation change, an epoch change or a receipt change. A device change drops only the affected candidates.\n- DS12. Exactly one ReceiptRepository is authoritative. Freed bytes are never claimed.\n\nBackup migration\n- BM1. The import is one transaction and idempotent: the same digest is a no-op, a crash before commit leaves the file intact, and a crash after commit creates no duplicates.\n- BM2. Dates are bit-exact.\n- BM3. Every confirmation and receipt maps to one row. Queue order is preserved, current first.\n- BM4. Legacy stage IDs become attempt IDs. Paths are relative to the app group.\n- BM5. A success outcome finalizes the job with zero POST /api/assets.\n- BM6. Legacy OS tasks are adopted by stage id and never re-created.\n- BM7. No result is applied before the import commits.\n- BM8. state.json is renamed only after commit and deleted only in B10. An unreadable file is quarantined, never fatal. A later digest from a reinstalled old build is merged with upserts.\n- BM9. One engine, unchanged session identifiers.\n- BM10. Files are deleted only after commit and acknowledgement. The sweep never removes a referenced body or one bound to a live task.\n- BM11. The system completion runs only after the durable commit or the deadline.\n- BM12. A stale lease never commits.\n- BM13. Side-effect failures never undo a confirmation.\n\nPrivacy\n- PF1. Hidden and locked are unrepresentable in LibraryQuery. Every search states trash and visibility. A defensive filter drops locked items.\n- PF2. The widget never requests locked or hidden assets.\n- PF3. accessLost purges memory, files and URL cache synchronously and fences late writes.\n- PF4. Relock bumps privateEpoch and purges private media.\n- PF5. Cast is never offered for locked assets.\n\n7. CONTRACT BEHAVIORS AT RISK (protected by the named milestones)\n- DESIGN 6, downloads wait while photos pass fast: replaced by the target-first motion policy in T3, with an owner-approved DESIGN.md edit. Kept: a started download completes; whole-library offline coverage on unmetered networks (T5); stages memory, then another size, then sketch, then stored, then network, crossfading.\n- DESIGN 7, the unfiltered position survives clearing a filter: broken today, fixed in F4. Browsing never opens a second grid: SimilarPhotos is an owner question.\n- DESIGN 8, shelf choreography (N4) and DESIGN 9, rail open-before-move, hold, per-feed places shown straight after launch, one tick per month (T4, F5): pinned by the existing unit and UI tests.\n- DESIGN 11, a place before sync is found by search: kept as an explicit planner limitation (Q5).\n- DESIGN 13, viewer neighbors load ahead and a photo opens on its preview or grid thumbnail (N3, T6).\n- PRODUCT, no invented counts: today's search count is the loaded count; owner question, F1. PRODUCT, no main-thread decoding: today the sketch decodes on main; fixed in T1.\n- PARITY changes:\n  - 401 sign-out becomes confirmed session expiry only (C5);\n  - transient backup errors retry instead of needing attention; album failures no longer keep photos queued (B9);\n  - background backup's NativeSync gate becomes best-effort (B7);\n  - partner timeline inclusion takes effect (Q5);\n  - Cast is hidden for locked assets (W2);\n  - a Trash selection offers restore and permanent delete (N2);\n  - configured widgets must survive (W5);\n  - read-only off resumes backup and shared uploads (C6), only once the owner agrees;\n  - offline fallbacks keep their eligibility (Q4).\n\n8. INSTRUMENTATION\n- OSSignposter, subsystem app.ilyich.native. Interval and event names are stable because the scripts parse them.\n  - thumbnails: thumb.display {source}, thumb.placeholder\n  - scrub: rail.scrub, grid.fling\n  - feed: feed.month {backend}, feed.commit\n  - launch: launch.firstContent\n  - sync: sync.pass\n  - index: index.backfill\n  - transfer: transfer.stage, transfer.submit, transfer.commit\n  - memory: mem.footprint (phys_footprint)\n  - perf: perf.scenario\n- PerfScenarioDriver ships in Release builds. It is inert unless the app is launched with -IlyichPerfScenario.\n\n9. TEMPORARY ADAPTERS (introduced -> removed; status as of A1)\n- SessionKeychain facade: C1 -> W5. Kept while the owner skipped W4 and W5 (widgets), as the Swift 5 widget used it; removed with the widget in A1.\n- LegacyNotificationBridge, re-posting ilyichLibraryChanged and ilyichCachesReset: C7 -> N4. Removed in N4 (3040085).\n- LibraryIndex facade keeping EntityStore's method surface: Q2 -> Q5. Q5 (3040074) removed the alias and the TimelineFilter surface; the forwarding methods stay as LibraryIndex's own API (they map SQLite errors and resume the backfill).\n- TimelinePlacesCache epoch fence: C6 -> F5 (cache deleted). Removed in F5 (3040079).\n- section-to-MonthKey mapping inside LibraryStore: F2 -> F6. Removed in F6 (3040083).\n- Coordinator-based demand source and the warmer coverage-band adapter: T2 -> T3 and T5. Removed in T5 (3040078) and T3 (3040079).\n- LegacyStateReceipts: P4 -> B10 (the way back; CutoverReceipts reads the transfers database from B9). Removed in B10 (3040092).\n- LegacyBackupIndexInputs (the device index reading today's backup state): P5 -> B10 (the way back). Removed in B10 (3040092).\n- Legacy fingerprint-JSON importer (DeviceDatabase.importLegacyFingerprints): P5 -> B10. Kept by B10; removed in C8.\n- Places-cache importer (LegacyPlacesImport) and its discard calls at a reset, an access change and sign-out: F5 -> C8. Removed in C8.\n- Share-manifest v1 reader and the v1 url keys v2 manifests kept: W3 -> B10. Kept by B10, as a v1 manifest could remain; removed in C8.\n- Widget-cache v1 importer and the Flutter widget-key purge: planned in W4. Never built as planned: the owner skipped W4 and W5, then removed the widget in A1, after which each launch deletes the widget's cache folders and removes the Flutter keys.\n- LegacyCoordinatorBackend: B8 -> B10 (the way back, behind BackupBackendRouter). Removed in B10 (3040092).\n- Shadow import mode: B1 -> B9 (the app imports authoritatively; B10 removed the mode). Removed in B10 (3040092).\n- Legacy descriptor and outcome decoding and their mirrors: B5 -> B10. Removed in B10 (3040092), which kept TaskDescriptor.legacy to cancel an older build's tasks; C8 removed the marker.\n- Authoritative import of a state.json no import read (LegacyBackupImporter) and the state.json mirrors: B1 -> once the owner abandons other accounts' old records (the critic's B10 gate; kept by B10's review). Removed in C8, with LegacyBackupPlan and LegacyRetirement: no state.json is left on the one phone.\n- BackupCoordinator per-scope APIClient cache: C5 -> B10 (the way back). Removed in B10 (3040092).\n- SessionStore's interim sign-out rule (sign out only when a second validateToken confirms sessionExpired): C5 -> C7. Done in C7 (3040068): the rule moved into AccountManager (SessionPolicy), runs as a transition of its own and stays (Risks: a confirming validateToken).\n- AuthorizationState owned by SessionStore, which pauses the coordinators for read-only mode: C6 -> C7 (AccountRuntime owns it). Done in C7 (3040068); read-only pauses the transfer engine since B9.\n- WidgetRandomSearchBody: S0 -> W5. Kept while the owner skipped W5; removed with the widget in A1.

## Milestones

### S0 — Safety fixes: reachable Settings, no locked photos in the widget

- **Workstreams:** 8, 9. **Depends on:** nothing. **Risk:** medium.
- **Scope:** New SettingsCatalog: a SettingsRoute enum with root, account, backup, appearance, grid, network, notifications, server, diagnostics and about, plus SettingsEntry readOnly and signOut. Screen.settings now carries its route, and the parallel settingsDestination variable is deleted. The Settings shelf level renders the catalog: today's six rows plus an All settings row that opens today's root SettingsView, which holds Read-only mode, Network, Notifications, Diagnostics and Sign out (owner may choose another placement). SettingsRouteView replaces SettingsDestinationView. Widget: a new pure WidgetRandomSearchBody always sends visibility timeline and type IMAGE; it is compiled by the widget and IlyichTests.
- **Migration:** None.
- **Tests:**
  - SettingsCatalogTests.testEveryRouteReadOnlyAndSignOutAreReachable
  - WidgetRandomSearchBodyTests.testRequestAlwaysSendsTimelineVisibility
  - UI testSettingsShelfReachesSignOutReadOnlyAndDiagnostics
- **Acceptance:**
  - On the phone, Read-only mode can be turned off and Sign out is reachable
  - With the Locked Folder unlocked, a widget reload never shows a locked or archived photo
  - Suites pass, apart from the two known simulator failures
- **As built:** Build 3040055. Read-only mode, Network, Notifications, Diagnostics and Sign out each got a row of their own on the Settings shelf (the owner's choice, instead of an All settings row). Library, person, album, place, Trash and similar-photo searches ask for the timeline and archive only; widgets ask for timeline photos only and their old image cache is dropped; Free up space no longer counts a Locked Folder copy, and the PhotoKit change blocks are built outside any actor.

### C1 — IlyichKit package for extension-safe identity, credentials and network

- **Workstreams:** 1, 9. **Depends on:** nothing. **Risk:** medium.
- **Scope:** New local package Packages/IlyichKit with product IlyichPlatform (Swift 6). It contains AccountID, AccountStoragePaths, AppGroup (with a distinct unavailable error) and AppGroupLayout (relative path resolution); StoredCredential, CredentialStore and KeychainCredentialStore (same service, account, access group, accessibility and tombstone); NetworkConfiguration, ServerAddress and their stores, ClientCertificateStore, SameOriginRedirectDelegate; ServerConnection, which takes its configuration as a value and an injected WiFiNameProviding; ReadOnlyPolicy; and AuthorizationMirror. The app and both extensions link it, and the moved files leave their source lists. The Swift 5 widget keeps a SessionKeychain facade. The macbook-air rsync set gains Extensions and Packages.
- **Migration:** None. Formats are byte-identical and every storage name is pinned.
- **Tests:**
  - CredentialStoreTests: v1 round-trip, tombstone, locked is distinct from absent
  - AccountStoragePathsTests.testPathsMatchLegacyLocations
  - AppGroupLayoutTests: /var vs /private/var and a new container UUID resolve to the same path
  - Existing network and endpoint tests moved unchanged
- **Acceptance:**
  - The Release app and both extensions build
  - On the phone: still signed in, widgets render, network settings intact, and the app group resolves (console log)
- **As built:** Build 3040056. IlyichKit's IlyichPlatform holds identity and storage paths, App Group resolution, the credential store, network configuration and certificates, the redirect delegate, the server connection and read-only policy; the app and both extensions link it, every stored name is byte for byte as before, and sign-out clears both widget caches.

### C2 — Shared contracts, legacy format mirrors and golden fixtures

- **Workstreams:** 1. **Depends on:** C1. **Risk:** low.
- **Scope:** Sources/Contracts holds every value type in architecture section 2. Sources/Legacy/LegacyFormats.swift holds verbatim Codable mirrors of BackupState (every key optional), PreparedPhoto, BackupReceipt, Outcome, Descriptor, SharedBatch v1, widget Metadata v1, TimelinePlaces and the fingerprint JSON. BackupState becomes internal so a test can encode the fixture with production code. Test support: TestClock, StubServer (URLProtocol with routes, gates, delays, and Immich-style vs proxy error bodies), FixtureLoader. Tests/Fixtures holds state-current (fractional dates, every key), state-9780e9625, outcomes (created, duplicate, 401, lost, force-quit cancel), a legacy descriptor, manifest v1, widget metadata v1, network config v1 and saved session v1.
- **Migration:** None. Fixtures pin every format that a later milestone imports.
- **Tests:**
  - LegacyFormatsTests: every fixture decodes; dates match by bitPattern; the oldest shape decodes; the production encoder equals the fixture
  - TaskDescriptorTests
  - LibraryQueryTests: presets and refined() keep scope
  - ResourceShapeTests: classification table
  - MonthKeyTests
- **Acceptance:**
  - Unit suite passes
  - No behavior change; installed on the phone
- **As built:** Build 3040057. Sources/Contracts, the LegacyFormats mirrors with 27 golden fixtures (most written by the production encoders), and TestClock, StubServer and FixtureLoader; nothing used the contracts yet.

### C3 — Regression ledger and a green baseline

- **Workstreams:** 1. **Depends on:** C2. **Risk:** low.
- **Scope:** Tests/KnownBugLedger.swift: each confirmed bug is a failing-first test wrapped in strict XCTExpectFailure and names the milestone that removes the wrapper. Entries: FEED-1 open photo in filter loses position (F4); FEED-2 phone-only newest month freezes clear (F4); FEED-3 sync reload racing scope change (F4); FEED-4 queued month index shifts (F2); FEED-5 month smaller than summary (F2); FEED-6 late places save after access change (C6); AUTH-1 wrong-password text (C5); AUTH-2 invalidation surfaces CancellationError (C5); SYNC-1 lost tail pass (Q1); SYNC-2 socket hints dropped (Q1); MEDIA-1 synced deletion wipes the thumbnail store (Q6); MEDIA-2 album removal sets accessChanged (Q3); SEARCH-1 search omits trash and visibility (Q4); QUERY-1 partners missing (Q5); BACKUP-1 a 5xx blocks automatic backup (B9); BACKUP-2 album failure keeps a photo queued (B9); CLEAN-1 one 404 aborts the cleanup check (P4). Fix the two long-standing simulator UI failures, or quarantine them with their recorded cause.
- **Migration:** None.
- **Tests:**
  - The ledger tests above
  - Both UI tests fixed or quarantined
- **Acceptance:**
  - Unit and UI suites have zero unexpected failures
  - Installed on the phone
- **As built:** Tests only, with no build of its own (the app stayed 3040057's; 3040058 first carried it). KnownBugLedger pins 13 bugs as strict expected failures; SYNC-1, BACKUP-1, BACKUP-2 and CLEAN-1 couldn't be reproduced without the phone (the file says why), and the two long-standing UI failures turned out to be the tests', now fixed.

### C4 — Measurement baseline on the phone

- **Workstreams:** 1, 7. **Depends on:** C3. **Risk:** medium.
- **Scope:** Add Sources/Core/Perf: the signposts from architecture section 8 and a MemorySampler. Instrument today's paths: PhotoCell bind to first real image tagged by source, rail scrub, month load, launch to first content, sync pass. Add PerfScenarioDriver, inert without -IlyichPerfScenario, with scenarios rail-random, rail-sweep, fling, reverse, relaunch-check, memory-warning and background-load. It drives the grid only through the rail and scroll APIs, waits 8 s after first content and prints PERF READY. Add scripts/perf/record.sh and summarize.py. Record a baseline for every scenario and add the summary to the PARITY build log.
- **Migration:** None.
- **Tests:**
  - SignpostNamesTests: names are stable
  - PerfScenarioDriverTests: inert without the argument; seed parsing
- **Acceptance:**
  - record.sh and summarize.py report thumb.display p50, p95 and max by source, hitch time ratio, longest hitch, hangs and peak footprint from the phone
  - Baseline recorded
- **As built:** Build 3040061. xctrace can't attach over Wi-Fi, the phone's only link, so the app measures itself while PerfScenarioDriver runs a scenario and writes a JSON summary that scripts/perf/record.sh fetches; the signpost names stay for Instruments. The baseline is in PARITY 3040061.

### C5 — Server transport and an honest failure taxonomy

- **Workstreams:** 1. **Depends on:** C2, C3. **Risk:** high.
- **Scope:** New ServerTransport actor. It creates its sessions once, sends Endpoint<T>, and shutdown() invalidates every session. Errors map to ServerFailure: an Immich JSON body is detected; credentialsRejected shows the server's text; proxyRejected is separate. ServerConnection fixes:
- invalidation names its endpoint and generation; reports for other endpoints are ignored;
- one re-resolution per generation, and waiters move to it (never CancellationError);
- probes run concurrently, keeping preference order;
- an idempotent GET retries once on endpointChanged; mutations are never replayed;
- a client certificate is offered for the local endpoint.
APIClient becomes the endpoint catalogue over the transport. BackupAttempt maps the new cases as before. AssetViewer no longer treats an expired session as a deletion. Interim SessionStore rule: sign out only after a second validateToken confirms sessionExpired, never on proxyRejected or forbidden. Interim leak fix: BackupCoordinator caches one client per scope and token.
- **Migration:** None.
- **Tests:**
  - AUTH-1 and AUTH-2 unwrapped
  - testPasswordLoginDisabledShowsTheServerMessage
  - FailureMappingTests
  - ServerConnectionTests: storms coalesce, non-selected endpoint ignored, share-only proxy rejected, last good kept
  - TransportTests: shutdown invalidates, same-origin redirect, local endpoint certificate
  - SessionPolicyTests.testProxyUnauthorizedNeverSignsOut
- **Acceptance:**
  - On the phone, switching between Tailscale and local Wi-Fi mid-scroll never strands sync, and Sync now works afterwards
- **As built:** Build 3040064. An Immich failure needs its X-Correlation-ID header and JSON message, so a 401, 403 or 407 without them is proxyRejected; sign-out waits for a second validateToken 2 s later and never follows a proxy refusal or a 403; a read retries once on a new route, a write never. AUTH-1 and AUTH-2 unwrapped.

### C6 — Authorization state and result fencing

- **Workstreams:** 1. **Depends on:** C5. **Risk:** medium.
- **Scope:** AuthorizationState (a Mutex snapshot with an epoch and an updates stream) is owned by SessionStore for now and writes AuthorizationMirror. WriteAccessModifier reads the snapshot from the environment, with no Keychain reads and no polling. A setReadOnly command bumps the epoch and pauses backup and share uploads. The Settings toggle and RequiredPasswordChange call it. TimelinePlacesCache saves carry the epoch and stale saves are rejected. The places save and the warmer start become owned Tasks.
- **Migration:** The App Group gains account.digest and account.authorizationEpoch, written for the existing credential, and account.accessEpoch, which only the app reads, so the access epoch goes on across launches.
- **Tests:**
  - FEED-6 unwrapped
  - AuthorizationTests.testReadOnlyToggleBumpsEpochAndMirror
  - FencingTests.testWarmerCannotStartAfterSignOut
  - testReadOnlyToggleFencesQueuedWrites
- **Acceptance:**
  - On the phone, read-only on and off disables and enables controls instantly, and read-only on pauses backup and shared uploads. Resuming them when it is turned off waits for the owner's answer (Open questions); until then C6 keeps today's behavior.
- **As built:** Build 3040066. AuthorizationState holds write, access and private generations (the critic's split epoch) and mirrors the digest and generations into the App Group; setReadOnly fences queued writes while reads go on, and places saves carry the epoch (FEED-6 unwrapped). SessionStore owned it until C7. Read-only kept today's upload behaviour (owner question).

### P1 — PhotoKit adapter: one executor, one observer, journaled mutations

- **Workstreams:** 4. **Depends on:** C6. **Risk:** high.
- **Scope:** PhotoKitAdapter actor on serial queue app.ilyich.photokit:
- access with a generation; the only change observer, using changeDetails and 250 ms coalescing;
- perform(DeviceMutation) builds every change block with nonisolated static factories that capture only Sendable values and a locked ChangeReport;
- inside the block: all-or-nothing checks for existence, canPerform and revision;
- userCancelled maps to declined.
DeviceDatabase holds the device_mutation journal: begin before performChanges, finish after, reconcileInterrupted at launch; results go to a mutations() stream. FreeUpSpaceView remove, LocalPhotoActionsView favorite and remove, and MediaExportService's Photos writer (SystemPhotoLibrary, W1) create all route through perform. LocalPhotoLibrary, DeviceTimelineIndex and BackupLifecycle subscribe to adapter.changes(). Seams: PhotoLibraryPerforming, AssetFetching.
- **Migration:** New, empty device.sqlite.
- **Tests:**
  - testChangeBlocksRunOffMainWithoutIsolationTrap
  - testDeleteBlockIssuesNoRequestWhenAnyRevisionChanged
  - testNotDeletableAssetMakesNoRequest
  - testDeclinedSystemPromptIsNotAFailure
  - MutationJournalTests: committed after the screen is gone; interrupted delete reconciled
  - testOneObserverCoalescesBursts
- **Acceptance:**
  - On the phone: favoriting a phone photo works; Remove from Apple Photos on a disposable photo lands in Recently Deleted; declining the prompt shows no error
  - Free up space's Remove is disabled on the phone until P4
- **As built:** Free up space's Remove sits behind `CleanupRemoval.isEnabled` (CleanupPolicy.swift), off until P4; checking still lists what would be removed. S0 (3040055) had already made it delete for real, with only the legacy verifier in front, so this build turns off an action the phone had. Turning it back on before P4 is an owner question.

### C7 — Account runtime replaces SessionStore

- **Workstreams:** 1. **Depends on:** C6. **Risk:** high.
- **Scope:** New Sources/Account:
- AccountManager (actor): phases; restore() idempotent with a waitingForUnlock retry; signIn, completeSSO, signOut(reason), sceneChanged, setReadOnly, resetLibraryMetadata, clearBrowsingCache; serialized transitions; the same account reopens only after shutdown.
- AccountRuntime: open() off-main; owns transport, capabilities, entities, media, warmer and OwnedWork.
- AccountSession: presentation only.
- SyncEngine: SessionStore's sync orchestration moved verbatim.
- Ordered shutdown as in architecture section 4.
- DEBUG-only AccountEnvironment.uiTest replaces the ProcessInfo checks inside services.
- Sign-out keeps the automatic-backup preference.
- LegacyNotificationBridge re-posts the old notifications for LibraryView, AssetViewer and Diagnostics.
- Delete SessionStore.swift and CastController's unowned revoke Task.
UI fixture gains auth/login, validateToken and logout.
- **Migration:** None on disk. No re-login, so the EntityStore session fingerprint and server checkpoints survive.
- **Tests:**
  - Restore: admin repair; non-admin gated; waits for unlock
  - Lifecycle:
- logout and cast revoke before credentials are removed;
- expiry sign-out not cancelled by itself;
- offline validation keeps the session;
- forbidden never signs out;
- explicit cleanup list;
- keeps the automatic-backup preference;
- sign-in waits for sign-out;
- same account reopens after shutdown
  - testAccountSwitchNeverServesThePreviousAccountsResults
  - UI testSignInThenSignOutReturnsToSignIn and testExpiredSessionReturnsToSignInWithExplanation
- **Acceptance:**
  - On the phone: restores without re-login and Diagnostics counts are unchanged
  - Never sign out the owner's main account on the phone, because it forces a full re-sync. Sign-out is checked on the simulator or with a test account
- **As built:** Build 3040068. AccountManager, AccountRuntime, AccountSession, SyncEngine, SignInModel and NetworkConfigurationService replace SessionStore; restore never signs out, and sign-out revokes Cast and logs out within 3 s before the credential goes; SignOutPolicy keeps today's sign-out data (owner question). C5's confirming validateToken became AccountManager's SessionPolicy.

### Q1 — Sync engine: one writer, no lost passes, typed changes

- **Workstreams:** 5. **Depends on:** C7. **Risk:** medium.
- **Scope:** SyncEngine correctness:
- coalescing by requested and completed sequence numbers;
- one SyncStatus writer;
- a BackgroundLease tied to the epoch;
- generation-checked startLive;
- socket hints merged (union of IDs, OR of flags); the parser accepts spread stack-update arguments;
- acks posted at most once per second, per 2,000 events or at the terminal marker.
Every pass, including pull-to-refresh, mutation and background passes, returns and publishes its LibraryChange. A stream that holds only SyncCompleteV1 publishes nothing. Set caps are removed; overflow is flagged above 50k IDs. Connect ack 40 is no longer a configuration change. NativeLibraryAPI.refresh returns the change.
- **Migration:** None.
- **Tests:**
  - SYNC-1 and SYNC-2 unwrapped
  - testUserRefreshPublishesItsChanges
  - testFencedCancellationDoesNotStrandSync
  - testEventsCannotStartAfterStop
  - testCompleteMarkerAloneIsNotALibraryChange
  - testBackgroundLeaseExpiryKeepsForegroundSync
  - Pinned: ack replay and the session-fingerprint wipe
- **Acceptance:**
  - On the phone, foregrounding with no server change causes no feed reload (no feed.month signposts)
  - A web edit appears through the socket
- **As built:** Build 3040070. SyncEngine is an actor and the sync status's only writer; passes coalesce, every pass publishes its LibraryChange and one that changes nothing publishes nothing; acks go once a second, per 2,000 events or at the end. SYNC-1 and SYNC-2 fixed.

### B1 — Transfer database and a shadow import of today's backup state

- **Workstreams:** 2. **Depends on:** C2, C7. **Risk:** critical.
- **Scope:** TransferStore actor on its own queue, using the schema in architecture section 3, in the private container. LegacyBackupImporter has two modes. Shadow mode, active now: when the state.json digest changes, rebuild the database from it in one transaction; never rename the file and never touch staging or transport, because BackupCoordinator stays authoritative. Authoritative mode is used from B9. ReceiptQuery API: receipts(for:), paged associations, receiptsForVerification(after:limit:), updateVerifiedSizes(ifUnchanged:). The import report goes to the diagnostics log and the console.
- **Migration:** Shadow only. state.json is untouched.
- **Tests:**
  - LegacyBackupImportTests: imports the current state exactly; imports the oldest shape; idempotent across crash points; unreadable state quarantined (authoritative) or reported (shadow); stranded album adds become runnable
  - TransferStoreTests: dates round-trip by bitPattern; completion is incremental and off-main with 60k receipts (constant statement count)
- **Acceptance:**
  - On the phone, shadow-importing the real state.json reports zero mismatches in receipts, confirmations, queue order, preferences, links, album adds, failures and notification batch, with every date bit-equal
  - Backup behavior unchanged
- **As built:**
  - The import runs 5 s after the runtime opens in front or the app comes out of the background (not when Control Center only makes it inactive), so a rebuild never competes with the first photos, and at once from Diagnostics; never on a write of state.json. The comparison is stored with the file's digest, so an unchanged file costs one hash and one read. Diagnostics has one section, Backup records copy: the mismatch total, when it was checked, the count per category (the ten above, stages and run intent included) and Compare again. The report also goes to the console and the exported log, as counts only.
  - Beyond section 3: stages are keyed by stage ID and keep is_video and suspended; meta keeps the comparison; a job's error fields are error_class, error_message, error_at and display_name; date columns have no declared type, because a REAL column stores -0.0 as 0 (BM2).
  - Nothing state.json holds is dropped. A suspended stage or a failure whose photo left the queue becomes a job, an album add for a photo never uploaded becomes an album upload job, and one for a photo with a receipt takes the receipt's server ID and can run at once. Stage IDs become interrupted attempts with their body paths, for B6 to adopt. Imported confirmations have no confirmed_at, which state.json never kept.
  - Authoritative mode imports once, ignores the same digest, and moves an unreadable file aside. A later digest is reported and changes nothing: BM8's merge is left to B9, which also answers the rollback question. A shadow import never touches a database the transfer engine or a later schema owns.
  - TransferStore.complete, the commit B2's engine will call with its lease, exists for the 60k-receipt test.

### W3 — Share inbox package

- **Workstreams:** 9, 2. **Depends on:** C1. **Risk:** medium.
- **Scope:** IlyichShareInbox product:
- ShareManifest v2 (relative file names) writer and v1 reader, with today's path confinement;
- ShareInboxRepository actor: per-batch ready or damaged; consume; garbage-collect folders without a manifest after 24 h;
- ShareStaging: providers, Live Photo export and XMP pairing by stem, moved out of ShareViewController, which keeps only UI;
- PhotoResourceExport with its own Deferral type.
The extension stops compiling UploadBody, BackupReceipt and SharedSession. ShareInboxStore loads through the repository off-main. LibraryView's main-thread inbox reads are deleted.
- **Migration:** v1 manifests are read. New batches are written as v2. The upload identity is still derived from the resolved absolute path.
- **Tests:**
  - testDamagedBatchDoesNotHideHealthyBatches
  - testV1ManifestLoadsAndRewritesAsV2
  - testUploadIdentityUnchangedAcrossVersions
  - testManifestlessFolderCollectedAfter24Hours
  - SharedInboxTests ported
- **Acceptance:**
  - On the phone: sharing 3 photos, a Live Photo and RAW plus XMP shows them in Shared files, and they upload
- **As built:** Build 3040064. IlyichShareInbox holds the inbox, manifests, staging and resource export; v2 manifests kept every v1 key for older builds; an unreadable batch stays on the phone and out of the list; consuming is idempotent and only the app collects garbage. C8 removed the v1 reader and the URL keys.

### P2 — Staging and resource export off the main actor

- **Workstreams:** 4. **Depends on:** P1. **Risk:** medium.
- **Scope:** DevicePhotos rules become pure helpers in the adapter:
- current resource choice, including RAW or JPEG via content editing input;
- Live motion uses fullSizePairedVideo, else pairedVideo;
- only .xmp files count as sidecars;
- mobile-app metadata only for unadjusted assets.
The adapter implements PhotoLibraryStaging. PhotoResourceExport and PhotoCurrentRepresentation leave @MainActor; their callbacks are built by nonisolated factories. BackupCoordinator calls the adapter for discovery, prepare, albums and the canRemove shape. The DevicePhotos enum is deleted. The album list is cached and refreshed on album changes only.
- **Migration:** None.
- **Tests:**
  - StagingRulesTests: resource table, metadata, XMP, Live Photo without motion is an item failure
  - testCandidatesStreamOffMain
  - testCancellationBeforeRequestIDDeletesPartialFile
- **Acceptance:**
  - On the phone, a backup of 20 mixed items (Live Photo, edited, RAW+JPEG, iCloud-only video) completes as before
  - No hangs during discovery
- **As built:** Build 3040071. Staging, resource export and album reads run on the adapter's queue; the files staged, their names, order and metadata are unchanged, and Backup settings and Free up space read albums asynchronously.

### Q2 — Library index v1: own executors, derived tables, resumable backfill

- **Workstreams:** 5. **Depends on:** Q1. **Risk:** medium.
- **Scope:** A shared SQLiteConnection with typed binds, a statement cache and cancellation. IndexWriter (serial, utility) and two IndexReaders (viewport and aggregate, read-only connections). A LibraryIndex facade keeps EntityStore's public methods for now. Migration user_version 0 to 1 adds the derived tables. The writer maintains derived rows in the same transaction as the sync batch and its acks. The backfill runs in batches of 5,000 with a resumable cursor. isQueryable stays false until it finishes, and reads stay on today's SQL meanwhile.
- **Migration:** In-place schema migration. Payloads, metadata and acknowledgements are untouched. No re-sync.
- **Tests:**
  - testBackfillResumesAfterCrashAtEveryBatch
  - testSyncBatchMaintainsDerivedRowsAtomically
  - testViewportReadRunsWhileWriterCommits
  - testReadsNeverOnMainThread
  - EntitySyncTests unchanged
- **Acceptance:**
  - On the phone the 60k-asset migration causes no hang of 250 ms or more; index.backfill duration recorded
  - Browsing unchanged while it runs
- **As built:** Build 3040071. EntityStore became LibraryIndex: an IndexWriter actor owns the only read-write connection and an IndexReader reads on its own; the derived tables fill by a resumable backfill 2 s after the account opens, and a write by an older build marks the index stale so the next launch rebuilds it (the critic's downgrade check).

### P3 — Phone browsing and actions through the adapter

- **Workstreams:** 4. **Depends on:** P1. **Risk:** medium.
- **Scope:** DeviceBrowserStore replaces LocalPhotoLibrary, with paged queries and incremental changes. Adapter media streams and one shared PHCachingImageManager. LocalPhotoMedia is rebuilt on them for viewer pages only. DevicePhotoActionsStore handles favorite and remove through perform, backup through a typed enqueue result, and sharing through a DeviceShareExporter actor that encodes off-main and whose temp folders are swept at launch. BackupQueueRow and LocalMediaFallback use the adapter's details and revisions. A favorite no longer disables the offline fallback. The local viewer updates its neighbors after a deletion.
- **Migration:** Leaked tmp/IlyichLocalShare-* folders are swept at launch.
- **Tests:**
  - DeviceBrowserStoreTests.testSingleChangeUpdatesOnlyThatPage
  - testBackupEnqueueOutcomeIgnoresStaleCoordinatorError
  - testFoldersSweptAtLaunch
  - testFavoriteToggleDoesNotDisableOfflineFallback
- **Acceptance:**
  - On the phone, On this phone scrolls smoothly over more than 20k photos; Live Photo share works; temp folders are gone after kill and relaunch
- **As built:**
  - `DeviceBrowserStore` (Sources/Features) reads 240-photo pages through `DeviceBrowsing` (the adapter, Sources/Device/DeviceBrowsing.swift). A change to photos already read re-reads only their pages; a removal of photos not yet read only moves the count; an insertion, a removal of a shown photo, an album change in an album view, or access reads the pages shown again. The next page loads as the last 60 photos come on screen; the Load more button stays.
  - `PhotoKitAdapter.media(_:_:)` (DeviceMedia.swift) is the one media path, over one shared `PHCachingImageManager`: it looks the asset up off the main thread and cancels the request when the stream is dropped. `LocalPhotoMedia` serves viewer pages only; the library grid's phone cells and `LocalPhotoThumbnail` use the stream directly, and the backup queue's rows read `details(of:)`. `LocalPhoto` moved to DeviceMedia.swift. `scripts/check-single-engine.sh` rule 6 keeps asset fetches and image requests in Sources/Device, except Free up space until P4.
  - `DevicePhotoActionsStore` runs favorite and remove through `perform`, backup through `BackupCoordinator.enqueue`'s new `BackupEnqueueOutcome`, and sharing through `DeviceShareExporter` (an actor on its own queue that encodes previews). The app delegate sweeps `tmp/IlyichLocalShare-*` at launch.
  - "A favorite no longer disables the offline fallback": the adapter's observer records, from Photos' per-asset change details, the modification dates an asset moved through while its content stayed the same (`ContentRevisions`). The fallback and a later removal accept those revisions; an edit, a revert or a removal forgets them. The server viewer only drops the phone copy after a removal. What the adapter learnt is kept in memory, so a favorite made while the app wasn't running still ends the fallback, as before.
  - The local viewer drops removed photos and shows the next one (else the one before); it closes when none is left.

### P4 — Cleanup service with explicit deletion-safety invariants

- **Workstreams:** 4. **Depends on:** P1, C5, C6. **Risk:** critical.
- **Scope:** Per-account CleanupService actor implementing DS1 to DS12:
- scan: local filter in batches of 250 through the adapter, then shape, canDelete, policy and kept albums; an optional exclude-only index prefilter; at most 6 concurrent strict remote verifications; per-item exclusions; a 401 aborts; byte counts recorded only if the receipt is unchanged;
- remove: re-verify only the selection, check the gate twice, then perform delete with expected revisions;
- results: declined, changed or removed; markLocallyDeleted only on commit.
Also: CleanupSettingsStore (same keys and messaging-album default); RemoteCopyVerifier with no offline fallback; ReceiptRepository plus the temporary LegacyStateReceipts adapter over BackupCoordinator (removed in B9); FreeUpSpaceStore, one per account, observing mutations(). FreeUpSpaceView only renders. Delete verifiedLocalDeletionCandidates and verifiedOriginalByteCount. Delete CleanupRemoval, which has kept Free up space's Remove off since P1, with its test.
- **Migration:** None. Receipts are read from the legacy state. Settings keys are unchanged.
- **Tests:**
  - CLEAN-1 unwrapped
  - Exclusion and abort: a missing server copy excludes only that candidate; 403 and timeouts exclude individually while 401 aborts; local filters run before any network request; at most 6 checks in flight
  - Re-verification at remove: only the selection is rechecked; a server copy trashed after the scan blocks the removal
  - Authorization and invalidation: a token change deletes nothing; read-only blocks removal; settings, access or library changes invalidate the scan; pausing backup does not cancel a check
  - Shape and deletability: a Live Photo without a motion receipt never qualifies; a Live pair or checksum mismatch excludes; an undeletable asset is excluded
  - Bookkeeping: byte counts are recorded only for unchanged receipts; CleanupSettingsStore reads the existing keys
  - Randomized property test over receipts, assets and server states asserting DS1 to DS8
- **Acceptance:**
  - Device gate with 30 disposable photos, owner present:
1. Trash 2 on the server, permanently delete 1, edit 1, favorite 1 and keep 1 in an album.
2. Check: only safe items are candidates, each exclusion with its reason.
3. Decline the iOS prompt: nothing removed and no error.
4. Accept: exactly the selection lands in Recently Deleted; server copies intact; receipts marked.
5. Turn on read-only during review: remove is blocked.
- **As built:**
  - `CleanupService` (Sources/Cleanup), one per account, owned by `AccountRuntime` and shut down first in `cancelAndJoin`. A check filters receipts on the phone in batches of 250 (revision, shape, deletability, settings, kept albums), then verifies the rest with `RemoteCopyVerifier`, at most 6 at once; a 401 (session expired, or a bare 401 from a proxy) aborts. The critic's DS4 and DS11 corrections apply: Locked Folder and offline server copies are excluded, archived ones count; a receipt, Photos or server change drops only the candidates it names, while settings, Photos access, the account, its token or its access epoch invalidate the whole check. A server change that resets or overflows also invalidates it.
  - Removal stays shut. `CleanupRemovalGate.isOpen` (CleanupPolicy.swift) is false, so Remove is unavailable as before and the service refuses before anything else; the owner's device gate above has not run. Opening it is that one line plus deleting `testFreeUpSpaceRemoveStaysClosedUntilTheDeviceGate`. This replaces "delete CleanupRemoval": the flag is renamed and kept, by the integrator's decision. The tests open the gate only on a service over FakePhotoKit.
  - Until B9, a cleanup removal is recorded only in the device_mutation journal (origin cleanup with the account digest and the expected revisions). `LegacyStateReceipts.markLocallyDeleted` writes nothing, since state.json has no field for it; B9's importer sets receipts.local_deleted_at from those journal rows.
  - Free up space's check now shows, below the candidates, every other backed-up phone photo grouped by why it stays, each group opening its first 300 photos. The device gate needs those reasons; nothing else on the screen changed.
  - No optional index prefilter: the receipts already bound the work, and nothing it would skip costs a request.

### Q3 — Index reads, server-equivalent order and precise access purge

- **Workstreams:** 5. **Depends on:** Q2. **Risk:** high.
- **Scope:** Months, month contents, month places, membership and map markers read from the derived tables, with no per-row JSON and no N+1 queries. Stack counts follow server rules. In-month order matches the server: local day, file-created time, file name, then id; createdAt order likewise. A targeted purge reports exact accessLost; album, partner and user deletes no longer set a global access change. Orphan dependents are kept and promoted. Unlocking or a re-grant enqueues a repair. DependentRepairer (foreground or unmetered, 2 at a time) refetches the asset and its OCR. Assets without EXIF are seeded for repair.
- **Migration:** Derived tables only.
- **Tests:**
  - MEDIA-2 unwrapped
  - testMonthOrderMatchesTheServer
  - testUnlockedPhotoRegainsItsMetadata
  - testFaceArrivingBeforeItsSharedAssetCountsOnceTheAssetArrives
  - EquivalenceTests.testIndexAndServerAgreeForEveryPreset (golden data from the seeded e2e server)
  - Pinned: place, Lightroom and person by month
- **Acceptance:**
  - On the phone, Lightroom still shows 20,968 photos in 54 months
  - Removing a photo from an album on the web keeps thumbnails (Diagnostics usage unchanged)
- **As built:**
  - Feeds, month places, map markers, album counts and person and album membership read asset_index, album_member and person_member, only once the index is readable (first sync complete and derived tables queryable); until then they come from the server, as before a sync completes. Single records (an asset, its people, memories, OCR) still read the entities. Months read the order index in order; the payload is still decoded per photo, since asset_index does not hold what the grid shows.
  - In-month order is the server's (AssetRepository.getTimeBucket): local day or created-at, then fileCreatedAt, then originalFileName, all one way, then id. MergedTimeline keeps that order and inserts phone-only photos by date (the F3 correction, done here so the merged and unmerged library agree).
  - Owner decision after Q3: keep the library's own order, not the server's. A month is ordered by the time taken (localDateTime; createdAt in created-at order), newest first unless the feed asks otherwise, then by id ascending, as before Q3: the index (schema version 3 swaps asset_index_order and asset_index_created for asset_index_taken (local_month DESC, local_date_time DESC, id) and asset_index_added, in place, indexes only), MergedTimeline (date desc, id asc, remote rows included) and months fetched from the server before the index is readable (APIClient sorts them the same way). Month membership and counts still follow the server.
  - Stack counts are the server's: members in the timeline and not trashed. albums() is three queries, not two per album.
  - Schema version 2 adds the created-at order index and a stack index, and drops asset_month_localDateTime and asset_month_createdAt; the reader no longer builds them on a second read-write connection.
  - The access purge checks only the photos of the album, album share or partner that went away, once per batch, and keeps a photo in an album the account owns. Lost-access IDs were already persisted in media_purges inside the batch transaction, and a legacy accessInvalidated='1' is already consumed by a full media wipe on the next settle, so both corrections hold without new state.
  - Partner or album EXIF that arrives before its asset waits in orphan_dependent and is promoted when it arrives. A face that arrives before its asset waits only as a marker (kind, id, asset id, no payload): a face does not say whose photo it is on, and one of a photo locked before Q2 must not be stored; when the asset arrives, a repair fetches its faces. The account's own EXIF, OCR, edits and metadata without their asset are still dropped: they belong to a locked or deleted photo, and locked_asset does not know photos locked before Q2.
  - Unlocking queues a dependent_repair. locked_asset does not know photos locked before Q2, so an asset of the account's own that the index never held but that the server created before the last completed sync is taken as unlocked and queued too (a first sync or one after a reset is not). DependentRepairer (two at a time, foreground only, started after a successful pass) fetches the asset's EXIF, faces and OCR and writes them as AssetExifV1, AssetFaceV3 and AssetOcrV1. 400 (Immich's answer for a photo the account cannot read, gone or locked), 403, 404 and undecodable drop a repair, or count as no faces or OCR; other failures back off 1, 4, 16, 64 minutes, five attempts in all. A repair whose asset had a dependent written by the stream while it was fetching writes nothing and stays queued, so older records never replace newer ones.
  - Not done: re-grant repairs (partner and album EXIF arrive again through the server's backfill events, faces come for every photo of the account's group and wait for theirs, and OCR comes only for its own photos), seeding assets without EXIF (the critic asks for a phone count and a cap first), and the e2e-server golden equivalence (the equivalence test checks the index against the server's rules applied to the same records instead).

### B2 — Transfer engine core (dormant), tested with fakes

- **Workstreams:** 2. **Depends on:** B1, C5. **Risk:** high.
- **Scope:** TransferEngine actor:
- commands only write rows and wake the loop; one owned loop reserves a lease, executes, then commits or fails;
- ensureOwned after every await; the commit uses WHERE lease;
- intents and waits; account blockers; retry and backoff with TestClock;
- a snapshots stream throttled to 4 Hz;
- the TransferControlling API.
TransferFailureClassifier implements the table in architecture section 5. JobExecuting is a seam with a fake executor. Not wired to OS sessions or the UI.
- **Migration:** None.
- **Tests:**
  - TransferEngineRaceTests: a second start never clears running or resets the active stage; late result after a released lease is discarded
  - TransferEngineFenceTests: token change gives an explicit block; read-only stops submission
  - ClassifierTests: every BackupAttemptTests input ported to the new classes
  - RetryTests: transient retries keep automatic eligible; environmental wait resumes for manual intent; automatic run skips item failures while manual retries them
- **Acceptance:**
  - Unit suite passes
  - App unchanged (dormant)
- **As built:**
  - TransferEngine runs only on a database it owns: meta.engine is transfer, set by B9's authoritative import or, for a fresh database no import ever wrote, by TransferStore.claimForEngine. It never runs on the shadow copy B1 rebuilds. No schema change.
  - Uploads are fenced by the session token and the write generation, not the access epoch, per the split epoch: losing access to some photos never cancels an upload. lease_epoch still records the access epoch.
  - Read-only on blocks the engine (blocker readOnly, persisted), as BackupCoordinator pauses today; read-only off does not resume it until the user acts (the owner question on read-only off resuming backup stands). A token change blocks with sessionExpired, which only the next session's engine clears; an ended session's signedOut block is never persisted.
  - A manual intent requeues the library lane's failed jobs once; an automatic one never does. A relaunch frees the old leases and keeps every job's state and phase, so the executor resumes from its stage; submitted jobs wait for their outcome (B6).
  - Classes beyond section 5's table: HTTP 400 is item; 403 and 404 from Immich are unknown (transient five times, then item); every 5xx counts toward serverBackoff, which also ends by itself after the backoff. An outcome with neither receipt, status nor v2 error code is an interrupted attempt (transient). Retry-After is honoured when an executor supplies it; none does yet.
  - Staging is not a seam of its own here: it belongs to JobExecuting, which B3 implements over P2's staging.

### Q4 — One typed query: planner, translators and the library repository

- **Workstreams:** 5. **Depends on:** Q3, C5. **Risk:** medium.
- **Scope:** QueryPlanner is pure, with explicit limitations and Unsupported cases. ServerTimelineRequest sends withPartners only for library with timeline visibility, no favorite filter and active trash. ServerSearchRequest:
- always sends visibility.in and trashedAt with an explicit null;
- uses localDateTime order;
- createdAt is Unsupported;
- owner and developed are post-filters with a 20k scan budget;
- a defensive filter drops locked and trash-mismatched items.
LibraryRepository implements TimelineSource and SearchSource; APIClient's offline fallbacks move into it, used only after a definite transport failure with a complete index. Place identity uses the membership revision. LibraryStore's search builds ServerSearchRequest.
Every shelf facet must be a predicate that combines with every other one by AND, so N6's stackable filters need no change to the model: album, one or more people, place membership, partner and the More categories (favorites, Lightroom, kinds and the rest). The planner states which combinations the server can serve and which need the index.
- **Migration:** Place cache keys change; old place files age out.
- **Tests:**
  - SEARCH-1 unwrapped
  - QueryPlannerTests: per-preset table
  - testSearchingInsideAFeedKeepsItsScope
  - testElevatedSessionSearchCannotShowLockedPhotos
  - testPlaceIdentityTracksMembershipNotCount
  - testWithPartnersNeverSentWithArchiveFavoritesOrTrash
  - testOfflineFallbackOnlyOnDefiniteTransportFailure
- **Acceptance:**
  - On the phone: library search excludes trashed photos; search inside Trash or a person keeps that scope
- **As built:**
  - QueryPlanner (Sources/Library/QueryPlanner.swift) is pure: the index serves every chronological query whose filters are only favorite and developed once it is readable; otherwise the server timeline serves the library, mine, a partner, an album and a person; everything else is server search with noMonths and includesStackMembers, plus ownerPostFilter (mine, partner), excludesSharedAlbumMembers (person) and developedPostFilter(scanBudget: 20,000). A place before the index is readable is a search, never Unsupported. createdAt order on search is orderNotSearchable; empty visibility is Unsupported.predicate. indexStale(since:) is added when the caller says the index serves while the server is unreachable (nothing does yet).
  - ServerTimelineRequest writes today's query items byte for byte (it builds them through TimelineFilter, which Q5 deletes) and sends withPartners only for the library with timeline visibility, no favorite filter and active trash, and only when asked: LibraryRepository.includesPartners is false until Q5 answers QUERY-1.
  - ServerSearchRequest always sends visibility.in (timeline, archive or both) and trashedAt {eq: null} or {ne: null}; metadata searches send orderBy localDateTime in the feed's direction. Its page filter drops locked, hidden, visibility-mismatched and trash-mismatched photos and applies the owner and developed post-filters; a post-filtered search reads pages of 500, up to 40 of them (20,000 photos), as the developed shelf did.
  - LibraryStore keeps the feed's search scope as a LibraryQuery (searchScope) and builds every search, similar and Search options request through ServerSearchRequest; searchFilter is now derived from it for Search options. Library, person, album, place and similar searches still look in the timeline and the archive, as since S0 (the owner question on search defaults stands). A field search inside Recently added is ordered by the time taken instead of failing as orderNotSearchable, so it keeps working (the critic's lost-capability note). TimelineFilter, SearchFilter and NativeLibraryAPI stay until Q5; NativeLibraryAPI now routes through LibraryRepository.
  - LibraryRepository implements TimelineSource and SearchSource on the planner; today's TimelineFilter routing moved into it unchanged. The offline fallbacks' policy moved into OfflineFallback beside it (a definite transport failure, never an HTTP status or a cancellation, and an index that is complete, or readable for albums, an album and map markers, each as before); APIClient's endpoint methods call it, since 49 call sites still read through APIClient until Q5 and N4 move them. Results are not wrapped in Fenced yet: nothing consumes the fence before F2.
  - Shelf facets stack (review fix): LibraryQuery.Scope is only the owner (library, mine, a partner); albums (a set, all of them), people (a set) and a place are predicates beside favorite, developed and the rest, so any facet ANDs with any other and N6 needs no model change. Two places or two partners are not a stack the model names (one place and one owner per query): photos of two owners are none, and N6 can intersect overlapping places into one membership. The planner says which stacks get months: the index takes any owner with at most one album, at most one person (with the library only, since the index widens a person to shared albums) and a place; the server timeline takes one of an owner, an album or a person, as today's feeds ask; everything else is search, with every facet in the filter. withPartners is sent only for the whole library, with no album, person or place. Preset stable keys are unchanged; several albums or people are listed as albumIds/personIds.
  - TimelinePlace is a PlaceMembership: its key is placeID#revision, so feed and place caches follow the photos, not their count, and old place files age out of the 12-file caches. PlaceCollection carries its membership, with the map marker query, computed off the main actor while the places are grouped.

### F1 — SearchFeed owns cursor pagination

- **Workstreams:** 6. **Depends on:** Q4. **Risk:** low.
- **Scope:** SearchFeed actor (Request, State, RetryPoint; first, more, retry, refresh) with LibraryStore.loadResults semantics moved verbatim:
- smart pages of 10; metadata pages of 100, or 500 developed-only;
- empty verified pages followed up to 3 times, or 40 developed-only;
- partial or unavailable verification gives a retry point;
- a nextPage-only continuation is rejected; a repeated cursor ends;
- dedup; refresh replays pagesLoaded with rowsChanged.
LibraryStore applies its State. A LibraryChange prunes deleted results in place. The match count shows a server total, or none (owner decision).
- **Migration:** None.
- **Tests:**
  - Ported continuation and verification tests: cursors nil, second, second and nil, next, next
  - testRefreshKeepsRowsWhenIDsUnchanged
  - testLibraryChangePrunesResultsWhileSearching
  - UI testSearchContinuesAnEmptyVerifiedPageAndCanClear
- **Acceptance:**
  - On the phone, verified search behaves as before
- **As built:**
  - SearchFeed (Sources/Library/SearchFeed.swift) is an actor per search with first, more, retry, refresh, prune and replace; LibraryStore.loadResults' loop moved into it unchanged, and its cursor, retry batch and page count are gone from LibraryStore, which keeps one SearchFeed per search and shows the State it returns. Every feed operation commits only if no later one started, and the store still drops a State whose search, text or generation moved on.
  - A LibraryChange reaches LibraryStore.prune(_:) through the legacy notification, which now carries the change: removed and access-lost photos leave the results shown in place (revision, no reset), and neither a later page, a retry nor a refresh brings them back for that search. removeLocally and update also go through the feed, so a later page no longer restores a deleted photo or an older copy.
  - Results still load further on scroll; Check more and Keep looking remain for verified searches.
  - Match count: Immich's search returns no total (its `total` is the page length), so State.totalCount is always nil and the header keeps showing the number of results shown, as before. The critic's correction (no count under post-filters) only concerns a server total, which never exists; the shown count can't overstate what is shown. Owner question: keep the count of photos shown, or show none.

### B3 — Library job executor and discovery (dormant)

- **Workstreams:** 2. **Depends on:** B2, P2. **Risk:** high.
- **Scope:** LibraryJobExecutor:
- stages through PhotoLibraryStaging;
- motion part hidden and without metadata, then the still with livePhotoVideoId; the motion id is reused across a crash;
- check id is the localID; body boundary Ilyich-<attempt>; checksum persisted once;
- duplicate rules: trashed is an item failure; a duplicate with an XMP sidecar succeeds only with this attempt's own created outcome; strict LivePhotoPairing;
- stack task on a new server id; cellular flags from the lease-time preferences; a legacy Live Photo without a motion checksum is confirmed without a receipt.
Discovery merges at commit time: temp table, NOT EXISTS an equal-date confirmation or an active job. A deleted asset drops its job (owner decision). TransferServerAPI uses the runtime's single client. Pipelining: at most 2 staged and 3 submitted, within a staging byte budget.
- **Migration:** None.
- **Tests:**
  - LibraryJobTests: motion hidden then still paired; XMP duplicate only for own attempt; trashed duplicate is item; changed date requeues and stacks; cellular per media type; legacy Live without receipt; one server client per runtime
  - testDiscoveryDoesNotRequeueItemConfirmedDuringDiscovery
  - testWiFiRequiredOriginalDefersOnlyThatJob
  - testPipelineRespectsStagingBudget
- **Acceptance:**
  - Unit suite passes
  - Dormant
- **As built:**
  - The engine runs up to `concurrency` jobs at once, each under its own lease (one by default, as in B2); TransferPipeline takes the turns inside them. A new stage starts only once every other stage's size is known and they total less than the budget (1 GiB; one stage may pass it alone), at most two waiting for the transport; at most three parts wait for their answers. Pause, cancel, read-only and blocks release every matching lease.
  - The executor waits for each part's answer under its lease through PartUploading. The real one (TransportPartUploader with TransportOutcomes) submits through TransferTransport and matches the transport's finished events, or the outcome file on disk, to the attempt; nothing creates it before B9. A lease lost while a part is with the transport leaves the job submitted, as B2 does; applying that outcome is B6's.
  - An unanswered attempt is resumed by its ID: an outcome on disk is applied without a check or an upload, and its body is sent again under the same ID, so the transport adopts a task iOS still holds. An answered one is recorded in its attempt row (remote ID and status), then its outcome file and body are acknowledged; the row is what a later XMP duplicate check reads as the attempt's own created outcome. A failed answer starts a new attempt after a new check.
  - The receipt takes the commit time when the executor gives none. The stage folder goes once the engine commits (JobExecuting.committed); a crash between the two leaves it for B6's sweep.
  - Discovery runs through TransferEngine.discover, which the snapshot shows as discovering. A photo Photos gives no date is queued only if never confirmed (today it is queued every pass). Deleted photos' jobs are dropped only with full Photos access, and never one leased or with the transport.
  - TransferServerAPI's reads are strict (no offline fallback). AccountRuntime.transferServer wraps the runtime's one client; nothing calls it before B9. PhotoLibraryStaging gained existing(_:), for discovery's deleted-photo check.

### Q5 — Feeds run on LibraryQuery; TimelineFilter and NativeLibraryAPI deleted

- **Workstreams:** 5, 6. **Depends on:** Q4. **Risk:** high.
- **Scope:** Every caller builds presets or a LibraryQuery: LibraryStore, More, the shelves, Places, the AssetInfo place collection, AlbumAssetsManager, Duplicates and Trash, LockedFolder (LockedFolderQuery) and Similar. A feed pins its plan and reopens on routingChanged, anchored by asset ID. The library preset includes partners shown in the timeline (owner default). Deleted: TimelineFilter, TimelinePlace, the LibraryAPI protocol, the placeNeedsOfflineLibrary silent fallback (now an explicit limitation using the existing copy), NativeLibraryAPI, setTimeline translation, developedOnlyResults policy, and the LibraryIndex facade's old method surface. Fixtures become fake sources. The UI fixture serves sync/stream and ack so UI tests use index routing.
- **Migration:** The library cache key stays byte-equal, except withPartners if adopted, which forces a one-time recount.
- **Tests:**
  - QUERY-1 unwrapped
  - FeedTests.testAFeedNeverMixesBackends
  - All LibraryStoreTests ported with unchanged names
  - UI testPeoplePlacesAndLightroomKeepTheCanonicalLibraryFeed on index routing
- **Acceptance:**
  - On the phone, counts for People, Places, Lightroom, Favorites, Archive, Trash and partner feeds are unchanged (except partners, if adopted)
- **As built:**
  - TimelineFilter, TimelinePlace, the LibraryAPI protocol, LibraryAPIError.placeNeedsOfflineLibrary, NativeLibraryAPI, setTimeline and the EntityStore alias are gone. LibraryStore reads through a LibraryFeedSource (TimelineSource + SearchSource + cacheScope, userID, refresh), which LibraryRepository implements; shelves call setFeed with presets (.favorites, .archive, .trash, .recentlyTaken, .recentlyAdded, .lightroom, .partner) and the store keeps feedQuery and feedPlan.
  - A feed plans on every load and passes that plan to summary, month and monthPlaces, so one load never mixes backends; the library reload that a sync change triggers (routingChanged included) plans again and keeps the grid on the photo it showed. A query the planner serves by search (a place before the index is readable) is shown as results with the noMonths limitation; nothing silently falls back on an error any more.
  - Translators: ServerTimelineRequest writes its own query items, byte for byte what TimelineFilter wrote (pinned as strings), and orders months in the library's order; init(LockedFolderQuery) serves the Locked Folder. IndexFeedRequest is the index's translation; LibraryIndex's feed reads take a LibraryQuery. AlbumAssetsManager, Duplicates/Trash and the Locked Folder build a LibraryQuery (or LockedFolderQuery) and still read the server timeline, as before.
  - Timeline and places caches are keyed by LibraryQuery.stableKey: byte-equal for the library and every shelf except Recently taken and Recently added (userId=me), whose old files age out of the twelve kept and which reload once.
  - Partners (QUERY-1) stay out: LibraryRepository.includesPartners is plumbed through the index and the server timeline but off, so the library shows exactly what it did; the ledger entry keeps its wrapper until the owner answers (and T5's coverage covers partners).
  - Not done here: the UI fixture's sync/stream and ack (the shared fixture server can't be changed by a milestone run), so UI tests still route through the server timeline; the LibraryIndex facade keeps its forwarding methods (they map SQLite errors and resume the backfill), only the alias and the TimelineFilter surface went.

### Q6 — Typed changes reach media precisely

- **Workstreams:** 5, 7. **Depends on:** Q1, Q3. **Risk:** high.
- **Scope:** LibraryChangeHub per runtime feeds the bridge. MediaPipeline.apply:
- removed assets are forgotten through an asset-to-key index;
- accessLost purges memory, thumbnail files and URL cache synchronously (clearing the URL cache only when an entry cannot be found, never the thumbnail store);
- in-flight downloads are cancelled;
- the thumbnail store write checks a revocation fence.
Routine removeAll calls become precise: viewer lock, bulk lock, Duplicates, Trash. removeAll stays only for sign-out and Clear browsing cache. A sync reset keeps revision-valid thumbnails.
- **Migration:** None.
- **Tests:**
  - MEDIA-1 unwrapped
  - testLockingOnePhotoPurgesOnlyThatPhotosMedia
  - testMoreThan2000DeletionsAreAllForgotten
  - testSyncResetKeepsRevisionValidThumbnails
  - testThumbnailFinishingAfterRevocationIsNotStored
  - testLockingOrTrashingFromTheAppForgetsOnlyThoseIDs
- **Acceptance:**
  - On the phone, locking one photo removes about one file from thumbnail usage, not all of it; scrubbing after a web deletion shows no blank months
- **As built:**
  - Most of the routine purges were already precise before Q6 (build 3040058): synced deletions and lost access reach media through the index's media_purges queue, which is committed in the batch transaction and cleared only after the media layer forgets them (the crash-safety correction), and the viewer lock, bulk lock, Duplicates and Trash already called forget with their IDs. MEDIA-1 was already unwrapped. removeAll stays only for sign-out and Clear browsing cache.
  - LibraryChangeHub (one per runtime, owned by its SyncEngine) gives each subscriber a mailbox that merges the changes it hasn't taken, and publishes in order: MediaPipeline.apply, then the legacy notifications, then the subscribers. SyncEngine.changes() subscribes to it. A sync's removals were already forgotten from the purge queue before publication, so apply forgets removed and accessLost only for changes of other origins, and for every change refreshes mediaRevisions: images of another revision leave memory, the URL cache entries this launch made and the thumbnail store, so the edit shows; no other photo is touched.
  - MediaPipeline keeps an asset-to-key index of its decoded and latest entries (MediaMemory), so forgetting a photo removes every size and revision of it from memory, not only its latest entry. Writes and removals happen under the index's lock after a check of MediaFence, so a decode or download that finishes after its photo was forgotten never reaches memory. ThumbnailStore checks the same fence on its own turn before writing, so a download begun before a lock or deletion is never stored; one begun after is (an unlocked or re-shared photo caches again). A fence past 20,000 photos refuses every older token instead.
  - The URL cache: entries made this launch are indexed by asset and removed one by one. Entries from an earlier launch can't be found by photo (URLCache can't be listed), so the first revocation of a launch that finds the cache may hold them clears the URL cache, never the thumbnail store, and later revocations are precise. Before Q6 every revocation cleared it.
  - Sync reset: memory, the URL cache and downloads in flight are cleared once per reset; the thumbnail store stays. Once the index is complete again, a sweep keeps only the files of assets it holds (not locked) at the revision it holds, and only then is accessInvalidated cleared, so a crash or a failed re-sync sweeps on a later pass. A legacy accessInvalidated='1' is reconciled the same way. This is the T1 orphan sweep the critic asked for, run after every reset; T1 still owns a general sweep.

### F7 — Search modes and filters as in Immich (owner request, 2026-10-21)

- **Workstreams:** 6, 8. **Depends on:** F1, Q5. **Risk:** low.
- **Scope:**
  - **What's wrong today.** Every search typed into the library bar runs the photo-content search with the server's LLM check. The app never sends `verify: false`, and the server checks every text search when verification is configured. The other modes (Filename, Description, Text in photos) and the filters exist in SearchOptionsView, but they are reachable only through the magnifying glass at the start of the bar, which reads as decoration, and the prompt always says "Describe a moment".
  - **Under the bar, a simple switch and More (owner, 2026-10-21).**
    - The switch turns the AI check on photo-content search on or off. Off is Immich's smart search, sent with `verify: false`; on is the fork's LLM-verified search, today's behaviour.
    - A More option next to it opens the granular Immich options:
      - the mode: Photo content, Filename, Description, Text in photos;
      - the filters: People, Places, Camera, Date, Media type, and Display options (favorites, archived, not in any album).
    - Chosen modes and filters show as removable chips under the bar while they apply. The prompt names the current mode. Choices persist until changed.
    - Every mode combines with every filter through LibraryQuery predicates. N6 later stacks the shelf facets on the same predicates.
  - **Design.** Design the switch, More and chips with the design skill, in the app's dark glass, and verify them on screenshots. The owner signs off on the look.
- **Migration:** None.
- **Tests:**
  - Each mode builds the right request: smart with `verify: false`, smart with verification, and metadata with filename, description or OCR
  - Filters combine with each mode
  - The mode survives clearing and a new search
  - UI: the switch toggles verification in the request; More changes the mode and filters, which show as chips and clear one by one
- **Acceptance:**
  - On the phone, with the switch off a photo-content search returns without the "Checking photo content" pass, and with it on the check runs; More reaches every Immich mode and filter; filters narrow results in every mode
- **Owner default, assumed:** the switch starts off, so plain smart search, since the owner asked that search stop always using the LLM.
- **As built:**
  - SearchChoices (AI check, mode, More's filters) lives in LibraryStore and persists per server and account in UserDefaults (`searchChoices.<scope>`, a new key; UI-test launches clear it). The mode is stored by a fixed name, and only More's own filters are kept.
  - With the switch off a Photo content search sends `verify: false`; on, it leaves verify unsaid, which is today's behaviour (the server verifies when configured). Sending `verify: true` would have made a server without verification answer every page "unavailable". Similar photos never send verify.
  - More's filters are merged into the feed's query (LibraryQuery.narrowed(by:)): people and tags join the feed's, other filters replace the feed's own, and a chosen visibility keeps to the feed's. A visibility outside the feed's (Only archived inside Favorites, Videos or another timeline-only feed, Left out inside Archive) leaves nothing to find: the search or view shows no photos without asking the server, rather than failing. The filters apply to every typed search and, with no text, More's Apply opens the feed narrowed as one list (the old "Filtered library"); the feed shown stays frozen on screen until that list is ready, and on an error. Removing the last chip returns to the feed. A mode alone opens nothing; it changes the prompt and the next search. Plain browsing never applies them: a chip removed at rest changes only the choices.
  - The row under the bar (AI check, More, chips) shows while the bar is focused and while the choices apply, so the timeline at rest is unchanged. The magnifying glass in the bar is now decoration only. Another mode's chip replaces the AI check, which belongs to Photo content. The progress line says "Checking photo content…" only for a checked search ("Searching…" otherwise), and the verification card shows only for one: the store keeps a verification only from the results of a checked search.
  - The shared UI fixture answers every search as verified and never reads `verify`, so the UI test sees the switch through the rerun (the card appears only once the checked search has answered) and not in the request body; SearchChoicesTests pins `verify: false` and the rerun's requests.
  - Search options now groups the filters as Immich does: Search in, People and tags, Place, Camera, Date taken, Media type, Display options (favorites, not in an album, archived, rating).

### F2 — TimelineFeed keyed by month

- **Workstreams:** 6. **Depends on:** Q5. **Risk:** medium.
- **Scope:** TimelineFeed actor:
- MonthKey queue of at most 6, 3 concurrent, 12 resident with visible and target months protected;
- tickets; the slot is released before cache writes;
- the month count reconciles the summary;
- transient retry with 1 to 30 s backoff on protected months;
- assets(of:) joins in-flight requests without polling;
- invalidate(months:).
LibraryStore drives it through a section-to-MonthKey mapping (removed in F6). Cells and prefetch stop requesting buckets; visible months come from viewportChanged. Delete the whole-snapshot TimelineCache and every call site.
- **Migration:** Delete Caches/IlyichTimelines (cache only).
- **Tests:**
  - FEED-4 and FEED-5 unwrapped
  - testSyncReloadDoesNotRestartAnInFlightMonth
  - testFailedVisibleMonthRetriesAfterATransientError
  - testRestoredMonthsStayWithinTheResidentBound
  - testShowInTimelineJoinsInFlightWithoutPolling
  - Ported: cold scrub bounds, eviction protection, rail jumps, date navigation
- **Acceptance:**
  - On the phone, rail-random feed.month p95 is no worse than the C4 baseline and no placeholders remain permanently
- **As built:**
  - `TimelineFeed` (Sources/Library, actor) owns the feed's months by MonthKey: three loads at a time, six queued, twelve resident with the months on screen and a jump's target protected; the month a jump lands on or the viewport shows goes first, and loads the grid left behind are dropped and asked for again if it comes back, as before. Each opening of a feed has a ticket, minted by the store, that every delivery carries; a delivery of a feed the store has left is dropped. A load's slot is released before its month is delivered, so the next month starts while the main thread draws. `assets(of:)` returns a resident month or joins the load on its way; Show in timeline and month selection use it instead of polling. `invalidate(months:)` marks months stale: they stay shown and are read again when the grid wants them, and a load on its way is kept, delivered, and read once more only if its month is wanted. A month that failed for a passing reason (no network, a timeout, a 5xx or 429) is asked again while it stays on screen, after 1 s, then 2, 4, 8, 16 and every 30 s; a refusal (4xx) waits for the banner's Retry, and a month off screen waits for the grid. The banner's Retry asks again for every month that failed, in the feed's order, behind the months on screen. A cancellation that was not the load's own (the transport shut down under it) is retried like a lost connection and never shown. FEED-5: a month's own count now stands over the summary's, so a month smaller than its summary leaves no placeholder (an empty month goes).
  - LibraryStore drives it through the section-to-MonthKey mapping (section 9, until F6): `loaded` and `bucketErrors` are the mirror the grid reads, filled by deliveries on the main actor. Commands go to the feed through one ordered task; a viewport or a target replaces the one queued before it, and the viewport is sent only when the months on screen change, so a scrub costs nothing per frame. A join (`assets(of:)`) waits for that task before it asks, so it can never overtake the `open` it belongs to, whatever the tasks' priorities. A sync's reload of the feed shown (same query and plan) keeps the feed and its loads on their way; a scope or plan change opens a new one. The saved library comes back on a feed of its own with its months, twelve at most around where it was left. Cells and prefetch no longer ask for months (PhotoGrid); the first two months of a feed, and the anchor's, are still asked for by name. The grid publishes its viewport after new rows or a reset as well as after a scroll, since UIKit reports no scroll for an offset that did not move (a feed opened from the top of the one before, a cold start whose first two months fill less than a screen). The months on screen also reach the feed at once through `TimelineFeed.Viewport` (a lock the store writes in `visibleSections`), so a load that lands while the viewport command is still queued cannot evict a month that has just scrolled on; the command still decides what loads. A sync's `invalidate` forgets the failed months too, so a refused month is asked for again when the grid wants it after the reload has taken the banner down.
  - Deleted: the whole-snapshot `TimelineCache` and `TimelineSnapshot`, their Diagnostics rows and the "visited timeline metadata" copy, and every call site (sync publish and reset, Clear browsing cache, lock/unlock, Duplicates). `Caches/IlyichTimelines` is deleted at every launch (idempotent; no flag). `TimelinePlacesCache` stays in its own file until F5. The two pinned cache tests: testCachedTimelineShowsItsMonthBeforeNetworkRefreshFinishes has no equivalent (first paint of a server-routed feed from a disk snapshot is gone by design; an index-routed feed's months come from the index, which FeedTests.testAFeedNeverMixesBackends and LibraryRepositoryTests pin), and testBackgroundRefreshKeepsLiveRowsAndDoesNotReplayOlderDiskSnapshot became testBackgroundRefreshKeepsLiveRowsUntilTheirMonthsAreReadAgain.
  - FEED-3 (a sync reload racing a scope change) is fixed by the join: the frozen feed waits for its first two months through `assets(of:)`, queued or not, instead of awaiting only the loads already running. FEED-2 (a phone-only newest month) stays with F4: the commit condition is unchanged.

### F3 — Month projections off the main actor

- **Workstreams:** 6. **Depends on:** F2. **Risk:** medium.
- **Scope:** MonthProjector (@concurrent, pure) takes MonthInput digests. DeviceTimelineIndex publishes a DeviceSnapshot with per-month digests. Only changed months are re-projected. Day groups are built only in day grouping. Place summaries are computed in the projection. updateSections and updateMergedEntries are deleted. A device publish increments structure only for the months it touches (no resetID); content increments drive cell reconfiguration.
- **Migration:** None.
- **Tests:**
  - testDevicePublishUpdatesOnlyItsMonth
  - testProjectionsNeverRunOnMain
  - MergedTimelineTests ported
  - testRepeatedDeviceSnapshotKeepsGridIdentity
- **Acceptance:**
  - On the phone, opening a viewer page causes no main-thread projection spike (Time Profiler)
  - Hitch ratio while fingerprinting is no worse than baseline
- **As built:**
  - `MonthProjector` (Sources/Library, pure, `@concurrent`) builds one month for the grid off the main actor: the server's photos and the phone-only ones merged, newest first by the time taken and then by ID (the owner's order, which `MergedTimeline` used), each server photo with its phone copy beside it, the month's days and its place summary. A feed that does not merge phone photos (an album, Recently added) keeps the server's order, as before. `MergedTimeline` still files the phone's photos by month and now digests each month and the matches, computed in the device index's actor as it publishes; `changedMonths(since:)` names the months a publish touched. The store consumes these digests rather than the contract's `DeviceSnapshot`, because `DeviceAsset` lacks the pixel size and duration that `LocalPhoto` carries for cells and the local viewer; `DeviceSnapshot` stays available from `DeviceIndexSnapshot.device()`.
  - LibraryStore keeps one projection per bucket; `updateSections`, `updateMergedEntries` and the per-call place summary are gone. A month the feed delivers is projected off the main actor and lands in one main-actor step with its rows (`loaded`), days and places, so nothing sorts or formats a date on the main thread; whoever needs the rows after `assets(of:)` (the commit of a replacement feed, tests) waits with `settleProjections()`. A snapshot from the phone projects only the months whose digest changed, plus every loaded month when the matches changed, then refreshes the sections in the same step; a snapshot that changes nothing costs a digest comparison and moves nothing. Opening a photo (`update`) re-projects only the photo's month. Runs go one at a time; a run under which the feed or its months changed applies nothing and starts over; a month changed again during a run waits for the next, which takes it for this run's reasons too, so a phone change it carried still restores the anchor; and a server month the feed lets go during a run stays gone, its rows not brought back past the twelve resident months. A snapshot that arrives while a feed is being replaced is merged in at the commit, and one that arrives while a filter shows is merged in when the filter clears back to the saved library.
  - Grid signals: a publish that moves rows the grid shows still restores the anchor through `restorePosition` and `resetID`, since today's grid has no separate structure counter (FeedSnapshot comes with F6); the clause "no resetID" is applied as "no reset to the top and no anchor lost". An identical snapshot, or a change that only reconfigures rows (a phone photo's revision), moves `revision` alone. Day groups are still built for every projected month, a few hundred microseconds off the main actor each: gating them on the grid's density would make the headers pop in a frame after a pinch, so that clause is not applied.
  - Tests: testDevicePublishUpdatesOnlyItsMonth and testProjectionsNeverRunOnMain (through `MonthProjector.Probe`); MergedTimelineTests ported to the projector with the time-taken order the owner kept (testMergedMonthKeepsServerOrder from the corrections is moot) and a digest test; testRepeatedDeviceSnapshotKeepsGridIdentityAndLocalEditStillInvalidatesMedia and the anchor test await the projection; the FEED-2 ledger tests wait for the projection before reading the sections (wrappers unchanged, F4 removes them). Review fixes: testAMonthLetGoDuringAProjectionRunStaysGone and testAMonthDeliveredAgainDuringAPhoneRunKeepsTheAnchor deliver a month through `feedTicket` while a run is on its way; testClearingAFilterMergesThePhonesPhotosThatChangedMeanwhile; testLoadingAMonthRedoesOnlyThatMonthAndForgetsTrimmedOnes waits for the edit's projection and checks that only its month is redone and that every month agrees with one projected from scratch.

### T1 — Thumbnail disk index, decoded window and correct decode size

- **Workstreams:** 7. **Depends on:** C4, Q6. **Risk:** medium.
- **Scope:** ThumbnailDiskStore keeps the existing root and file layout and adds index.sqlite:
- a presence map; nonisolated reads; enqueueWrite returns immediately; epoch-fenced;
- the previous revision is deleted through the presence map, with no directory listing;
- batched upserts and access touches;
- maintenance only after 5 s idle or in the background: trim to 90 % by last_access, orphan sweep.
DecodedThumbnailCache: Mutex LRU, budget min(128 MB, RAM/64), pins, a larger image serves a smaller cell, precise forget. Decoding: aspect-fill short side, never upscaled; sketches decoded off-main and premultiplied; average color. A DispatchSource handles memory pressure. MediaPipeline's thumbnail path uses these. ThumbnailStore, the NSCache thumbnail caches and ThumbHashImages are deleted.
- **Migration:** v1 files are adopted in place. The index is rebuilt after first frame at utility priority, falling back to fileExists until complete. Nothing is re-downloaded.
- **Tests:**
  - testFirstWriteAfterLaunchDoesNotEnumerateTheStore
  - testWriteAfterAccountResetIsDiscarded
  - testTrimEvictsLeastRecentlyViewedNotOldestWritten
  - testV1FilesAreAdoptedWithoutDownloading
  - testAspectFillDecodeCoversTheCell
  - testForgetKeepsUnrelatedImagesAndMemoryWarningKeepsPins
  - ThumbHash reference vectors unchanged
- **Acceptance:**
  - On the phone, rail-random over covered months makes about zero network thumbnail requests
  - Disk-hit p95 improves on the baseline
- **As built:**
  - ThumbnailDiskStore replaces ThumbnailStore and keeps its root and v1 file layout; the fixture tree is unchanged. index.sqlite (files: name, size, last_access; meta: writer, complete, cursor) sits in the scope folder beside the two-letter folders, so sign-out's removeAll takes it too and an older build's sweep skips it. The index is loaded into memory once; contains, replacing a revision, forget, refresh, sweep and trim use it and list no folder. One store per folder per process (ThumbnailDiskStore.shared), so the pipeline and its helpers share one view.
  - enqueueWrite returns at once: the bytes are readable from memory until the store's utility queue writes them, so a thumbnail flight ends as soon as its download does. The media fence is checked on enqueue and again on the queue's turn; removeAll raises the fence floor, so a download begun before a sign-out or reset is never written. Row changes and access touches (at most one a minute per file) are saved in batches.
  - Migration: v1 files are adopted folder by folder, 2 s after the store opens, at utility priority, saving a cursor after each folder so an interrupted build resumes; adopted files count as last viewed at their modification time. Until a folder is adopted the store falls back to the file system, as before. Nothing is deleted or downloaded. A missing index, or one with another writer marker, is rebuilt the same way.
  - Rollback and purges (critic's correction): every launch compares the folders with a complete index once, the same way, so files an older build's mtime trim or iOS removed leave the index and files an older build wrote are adopted. A read that fails for a file the index lists drops its row and is a miss.
  - Trimming to 90 % of the cap, least recently viewed first, runs only after 5 s without reads or writes, or when the app goes to the background; a write never trims. The orphan sweep is the existing one run after every sync reset (Q6's), now done through the index; the store has no asset list of its own to sweep against otherwise. Review fix: the sweep lists every folder first, even under a complete index, so files whose rows a crash kept from being saved, or that an older build wrote, are swept too.
  - DecodedThumbnailCache holds edited, unlocked grid thumbnails: a Mutex LRU within min(128 MB, RAM / 64) and 4,000 images, pins (grid cells pin the photo they show while on screen), a DispatchSource memory-pressure handler and the app's memory warning that both keep pins, and forget/refresh by asset. One image serves every cell up to the short side it was decoded for (any cell, when decoded at the file's own size), and a smaller or older copy is dropped when a better one arrives.
  - Grid thumbnails decode aspect-fill: the short side reaches the cell's, never above the file's own size. Previews and full-size images keep the fit decode.
  - Correction applied: only the thumbnail tier moved. Previews and full-size images stay in MediaPipeline's decoded and latest caches, now 64 MB and 40 MB since thumbnails have their own budget. latestImage(.thumbnail), which ViewerPhoto, FeatureSupport, the filmstrip and the grid use, now reads DecodedThumbnailCache, so a photo still opens on its cached preview or grid thumbnail (DESIGN 13) from T1 on.
  - ThumbHashImages no longer existed; ThumbHashSketches already decodes premultiplied BGRA sketches off the main thread and gives the average colour. Its decodeNow, which the grid used while moving slowly, is removed (review fix): every sketch now decodes on the sketch queue, a cell whose sketch prefetch has not decoded yet shows the average colour until it arrives, and the cache counts main-thread decodes so a test pins zero.

### F4 — Feed sessions, saved timeline and typed change application

- **Workstreams:** 6. **Depends on:** F3, Q6. **Risk:** high.
- **Scope:** FeedSession tracks pending and displayed sessions. A pending session is ready when its summary and first min(2, n) months have loaded, are local-only, or have failed. A 1.5 s timeout commits it with placeholders. On failure the old feed stays with Retry and Clear. SavedTimeline (snapshot, anchor, title) is patched by changes and by metadata refreshes. LibraryStore.apply(LibraryChange) uses FeedMembership: local decisions for visibility, trash, favorite, user and developed; album, person, place, partner and search scopes reconcile their months. update() keeps the saved timeline. Locking removes the row and keeps the anchor. clear() shows the saved timeline, then revalidates.
- **Migration:** None.
- **Tests:**
  - FEED-1, FEED-2 and FEED-3 unwrapped
  - FeedMembershipTests: table
  - testArchivingFromTheViewerRemovesThePhotoFromTheTimeline
  - testUnfavoritingInFavoritesRemovesThePhoto
  - testLockedUpdateKeepsTheTimelinePosition
  - testClearingRevalidatesTheRestoredLibrarySummary
  - testDeviceSnapshotDuringReplacementIsShownAfterCommit
- **Acceptance:**
  - On the phone, opening a photo in a person filter and then clearing returns to the same library position (DESIGN 7)
  - No frozen grid after rapid filter changes
- **As built:**
  - `FeedSession` (Sources/Library) names one opening of a feed: its ticket, query and plan. The store shows one session; a new scope's session is pending behind the frozen one (`FrozenFeed`, the displayed session) until it is ready: its summary is in and each of its first min(2, n) months has loaded or is only on the phone (FEED-2). Critic's correction applied: a failed first month keeps the frozen feed with the error, for Retry and Clear (PARITY 3040020), and the 1.5 s commit with placeholders is not built, since it waits for the owner's answer. The first months are worked out again after each round of joins, because a month that comes back empty leaves the feed (FEED-5) and the next takes its place; after three rounds with no failure the feed commits with what it has, so the grid never stays frozen with nothing on its way. A sync's reload while a feed is pending no longer gives the new feed the frozen feed's position, nor resets the frozen grid.
  - The saved library (`SavedTimeline`, unchanged in shape) is patched rather than dropped. `update()` gives it a photo's fresh record, or takes the photo out when the record takes it out of the library (archived, locked, in Trash); `removeLocally()`, a sync's removals and lost access take photos out; `refreshAfterMutation()` keeps it; a reset or an overflow drops it, and the library is then read afresh. The months sync changes touch while it is saved are remembered. `clear()` shows it at once and then revalidates: the summary is read again, and those months, and any month the summary counts otherwise than its rows, are read again when the grid wants them, shown meanwhile. Show in timeline restores it the same way and still scrolls when the check fails. A library that never loaded is no longer kept as a saved library with no plan.
  - `FeedMembership` (pure) decides from the record: visibility (a locked or hidden photo is in no feed), trash, favorite, owner (the account's own, or a partner's) and developed. Albums, people, places, partner sharing, search relevance and the other predicates reconcile. `update()` takes a photo its record excludes out of the feed in place, the grid keeping its offset (locking no longer reloads the library from its top), and otherwise shows the new record.
  - `LibraryStore.apply(LibraryChange)` replaces LibraryView's prune-and-reload. Removed and access-lost photos leave at once (feed, results, saved library). The months upserted photos left and joined, and those holding a photo whose media changed, are read again when the grid wants them; the summary is read again, and a month it counts otherwise than its rows is read again too. A reset, an overflow, a routing, configuration, partner or stack change, and an album or person change in that album's or person's feed read every month again, as every change did before. A text search is only pruned, as before; a results feed is read again only when the change touches a photo, album or person; a change that touches no photo reads nothing.
  - Withheld photos (TimelineFeed): a photo the store takes out before the source has the change stays out of every month read before then, in the feed it left and in the next one opened, so the library a filter clears back to cannot bring it back either. A deletion, a lock or a restore from Trash withholds it from every feed with the trash state it had; a record that left a feed (unfavorited in Favorites, archived from the library) withholds it from that feed only. A sync that began reading the server after it was taken out confirms it (see the review fixes below): reads begun after are trusted and the months it left are read again, so a photo taken out that is still there (a stack's cover after a stack change, which reaches the feed as a deletion) comes back as it did before. A sync's removals are kept out of loads already on their way. The owner's report of a deleted photo lingering in a filter was not reproduced as such; these are the paths found that bring one back (a month read before the offline library has synced, a load on its way, and clearing to a library reloaded from its top because the deletion dropped the saved one).
  - Tests: FEED-1 and FEED-2 unwrapped (FEED-3 was unwrapped in F2); FeedMembershipTests (table, readiness); FeedSessionTests with the five named tests and testAPendingLibraryLedByAMonthOnlyThePhoneHasCommits, testADeletedPhotoStaysOutOfTheFilterAndTheLibraryItClearsBackTo, testAPhotoTakenOutThatIsStillThereComesBackAfterTheSync, testASyncChangeReadsAgainOnlyTheMonthsItTouches, testAPendingFeedWhoseFirstMonthEmptiesStillReplacesTheFrozenFeed and testASyncDuringAReplacementOpensTheNewFeedAtItsTop. testRestoredMonthsStayWithinTheResidentBound (F2) waits for the clear's revalidation before it selects, and checks the kept month's own reads: the revalidation asks for the two newest months by name, which the twelve-month bound had not kept.
  - Review fixes: a withheld photo keeps every feed it was taken out of. Archiving inside a filter withheld it from the saved library and then from the filter, and the second replaced the first, so the library the filter cleared to could read it back from an offline library not yet synced. A withheld photo is confirmed by time, not by name: `LibraryChange.syncedThrough` says when the sync pass behind a change began reading the server (SyncEngine sets it for a pass that read its whole stream; a pass that failed partway, a repair and a reset leave it nil), and a change confirms every photo taken out before then, named or not, while `refreshAfterMutation` confirms those taken out before it was called. A pass already on its way when a photo was deleted, naming it for an earlier favorite, no longer brings it back, nor does a refresh asked for before the deletion, and a photo taken out as a precaution whose refresh failed comes back with the next pass's change instead of staying hidden until a pull to refresh. The months a sync's reload reads again, and the failed months whose banner it takes down, are owed to the feed until a reload has its plan, so a newer reload that takes over sends them with its own; the months the library had yet to read again when a filter opened are read again once it clears. While a new feed is pending, the "Some photos couldn’t load" Retry loads it again whole, as the other banner's Retry does, so it replaces the frozen feed. The viewer tells `onDeleted` which photo left: the grid of a photo's Info collection (a person, an album, a place) removed the photo it was opened on instead of the one deleted after a swipe, which kept the deleted photo on screen until the sheet closed; this matches the owner's report of a deleted photo lingering in a filter. Tests: testArchivingInsideAFilterKeepsThePhotoOutOfTheLibraryItClearsBackTo, testAReloadThatTakesOverStillReadsTheMonthsTheOneBeforeNamed, testASyncBegunBeforeADeletionDoesNotBringThePhotoBack, testAPhotoTakenOutWhoseRefreshFailedComesBackWithTheNextSync, testRetryingAPendingFeedsFailedMonthReplacesTheFrozenFeed and testAMonthLeftStaleWhenAFilterOpensIsReadAgainOnceItClears; SyncEngineTests check that a full pass stamps its change and a partial one doesn't. The Info collection's viewer has no test: it is view wiring, and N3's testDeletingTheSwipedToPhotoRemovesThatPhoto covers it once the viewer has a model.

### B4 — Post-upload work, share jobs and notifications (dormant)

- **Workstreams:** 2. **Depends on:** B3, W3. **Risk:** medium.
- **Scope:** PostUploadWorker:
- album destinations become runnable once remote_id is set; PUT at most 500 IDs; duplicate counts as done;
- stack tasks;
- linked-album sync, failing per album;
- never un-confirms a backup and never stops the run.
ShareJobExecutor: repository validation; upload in place; deterministic identity; file-name check id; share-upload session; share_consumed in the completion transaction; manifest rewrite after commit, replayed idempotently. TransferNotifier (main) observes notification_batches: started once and terminal once across relaunches; transfer.<UUID> IDs; epoch guard; never awaited by the engine.
- **Migration:** None.
- **Tests:**
  - PostUploadTests: album 403 keeps receipt and confirmation; stack failure doesn't stop the run; linked albums fail per album
  - ShareJobTests: errors survive restart; consume idempotent after crash; legacy identity adopts in-flight task
  - TransferNotifierTests: terminal posted once across relaunch; engine progresses while notifications hang
- **Acceptance:**
  - Unit suite passes
  - Dormant
- **As built:**
  - `PostUploadWorker` (actor, Sources/Transfers) runs beside the engine, never inside a job. The engine takes an optional `followUp` closure and calls it without waiting: at start, after each commit, when the library lane drains after running jobs (today's end of a run), on a manual run and on Retry all. A pass adds runnable album destinations per album, at most 500 IDs per PUT, success or `duplicate` deleting the row; then stack tasks (new upload on top of the earlier copy, as today); then, after a run or a manual run with Sync albums on, linked albums, each on its own (linked ID, else the server album with the phone album's name, else a new one). Forbidden, not found and other item refusals fail the row; a failure that may pass by itself leaves it pending, failed after five tries; an account failure, read-only mode or no network stops the pass and blames nothing. Confirmations and receipts are never touched. A manual run and Retry all set failed destinations and stack tasks pending again. Linked-album failures are in the pass's report only (no schema change).
  - Album destinations are made by `enqueue`: `TransferRequest` gained `album`. A photo already backed up with a receipt joins the album at once (counted alreadyBackedUp, no upload); one confirmed without a receipt (a legacy Live Photo) is queued again so the duplicate answer supplies its server ID. Requests with a notification batch create or grow its notification_batches row (kind backup or share).
  - `ShareJobExecutor` reads the batch through the new `ShareInboxRepository.batch(_:)`, keeps the attachment's files in place and records a stage row for it (checksums, the Live Photo video's server ID, the fields read once). Its identity hashes the path relative to the App Group in place of today's absolute path, so it doesn't depend on /var or /private/var; before checking the server it adopts a live task held under that identity or today's (both path forms), and applies a receipt left on disk under either; a failed outcome left on disk is deleted first (critic's correction). Attempts are written on the share-upload session. `completeShare` counts the notification batch; `committed` consumes the attachment and forgets share_consumed; `replayConsumed` settles what a crash left. Enqueue skips an attachment share_consumed still lists. `LaneJobExecutor` routes lanes for B9.
  - Recovery now resumes share jobs the transport had (staged, so the executor adopts or applies), keeps a legacy share task a share job is bound to, and cancels a version 2 share task of the account that no unanswered share attempt owns.
  - `TransferNotifier` (main) reads notification_batches when woken (`changed()` or the engine's snapshot stream), posts started once while jobs remain and the last notification once when none runs (failed jobs counted, the total being completed plus failed; a fully cancelled batch is withdrawn quietly), records each in the row, prunes posted rows no job references, and withdraws a post that returns after `stop()` or the session's end. `SystemTransferNotificationPoster` goes through today's TransferNotifications (transfer.<UUID>, same words, its epoch).
  - check-single-engine.sh rule 3c fails the build when code outside Sources/Transfers names these types, so they stay dormant beside BackupCoordinator and ShareInboxStore.

### B5 — Background transport and acknowledgements (dormant)

- **Workstreams:** 3. **Depends on:** C2. **Risk:** high.
- **Scope:** BackgroundTransport, one per TransferSessionID:
- identical configuration;
- submit returns the task id, with a v2 descriptor;
- the delegate caps responses at 64 KiB, refuses redirects, answers certificate challenges through the package helper, writes Outcome v2 atomically before signalling, throttles progress and reports drained sessions.
TransportRegistry is lazy behind an unfair lock and offers one merged event stream. BackgroundEventAcks registers first, queues handlers, remembers a drain that came before registration, and acks after commit or a 20 s deadline. inventory() decodes legacy and v2 descriptors and matches by ID. Tested through a TaskEventHandling seam.
- **Migration:** None (dormant). Outcome v2 still decodes legacy files.
- **Tests:**
  - testCompletionSurvivesDrainBeforeRegistration
  - testSystemCompletionOnlyAfterDurableCommit
  - testJournalFailureNeverReportsSuccessOrHangs
  - testOneURLSessionPerIdentifierUnderRacingLaunchPaths
  - testLegacyDescriptorAdoptedByStageIDDespitePathForm
- **Acceptance:**
  - Unit suite passes
  - Dormant
- **As built:** Build 3040064, dormant. BackgroundTransport, TransportRegistry and BackgroundEventAcks; the backup session's configuration moved into one function both engines used, and check-single-engine.sh landed here (the critic's correction). An answer from another origin is recorded as redirected, and acknowledgements are tied to numbered drains.

### B6 — Recovery reconcile and staging sweep (dormant)

- **Workstreams:** 3. **Depends on:** B1, B5. **Risk:** high.
- **Scope:** Recovery.reconcile:
- R1 applies unapplied outcomes;
- R2 binds, cancels or adopts OS tasks; a legacy share task is adopted while its manifest still lists the file;
- R3 re-checks interrupted attempts by persisted checksum: a duplicate completes (a sidecar still needs its own created outcome); otherwise resubmit with the existing body if body_bytes match;
- R4 resumes created or body-written attempts, or returns the job to pending;
- R5 runs StagingArea.sweep, which never touches referenced or bound bodies; legacy folders only after the import;
- R6 produces a report.
- **Migration:** None (dormant).
- **Tests:**
  - testLegacyTaskDescriptionReattachesInsteadOfUploadingAgain
  - testLegacyReceiptOutcomeCommitsWithoutNetwork
  - testSuspendedStageWithSuccessfulOutcomeFinalizesWithoutReupload
  - testStaleFailedOutcomeRetriesAutomatically
  - testForceQuitCancelledOutcomeIsResubmittedNotFailed
  - testReplayedHTTP401ClassifiedAsUnauthorized
  - testOriginalChecksumNotRecomputedOnResume
  - StagingTests: sweep removes only unreferenced folders; sign-out removes scope staging
- **Acceptance:**
  - Unit suite passes
  - Dormant
- **As built:**
  - Recovery (Sources/Transfers/Recovery.swift) runs only on a database the engine owns (else ReconcileError.notOwned, changing nothing) and leaves every leased job to the engine; each write checks lease_token IS NULL in its transaction. It needs no server: the re-check by persisted checksum in R3 is the executor's, which already checks before it resends, so reconcile stays offline and quick for B7's windows. R3 keeps a body only if it ends with its closing boundary and has its recorded size (the executor now checks the same before reusing one), else abandons it.
  - R1 commits a receipt for the still directly (stage checksum, else the attempt's, else hashed once; with no file left the photo is confirmed without a receipt). A video's receipt records its server ID and the job goes on to the still. A duplicate with a sidecar fails the photo, as the executor does; a duplicate that needs pairing stays on disk for the executor. A status is classified by TransferFailureClassifier: item fails the photo, transient retries at once, an account class (a replayed 401) goes in the report without blaming the photo or persisting a block. No status means no answer: interrupted, outcome acknowledged with the body kept. The executor now does the same for an unanswered outcome it meets itself.
  - R2 binds an unanswered attempt to its task (legacy by stage ID) and leaves the job submitted; it cancels live backup tasks of the account no unanswered attempt owns (TransferTransport gained cancel(tasks:)); other accounts' and foreign tasks stay. Legacy share tasks stay while ShareInbox/<batch>/manifest.json lists any attachment (or can't be read), and are cancelled when the batch is gone or empty: matching the exact attachment needs B4's identity, behind ShareTaskListing. Version 2 share tasks are left to B4.
  - R4: a job the transport had resumes as staged; one whose needed staged files are gone (and no kept body with its checksum covers them) returns to queued, its stage dropped.
  - StagingArea touches only UUID-named folders directly in Backup/<digest>, never state.json, other accounts or ShareInbox. It removes nothing while state.json is there and the database has not imported it authoritatively. Anything changed within 15 minutes stays. removeAll is the sign-out half; nothing calls it before B9, which cancels the account's tasks first. The database stays, and the next reconcile re-stages.

### B7 — Lifecycle events and background windows (dormant)

- **Workstreams:** 3. **Depends on:** B2. **Risk:** medium.
- **Scope:** LifecycleEventSource folds conditions into EnvironmentSnapshot and yields on change; its initial callback in the background is not a trigger, and photo library churn never reschedules. SchedulePlan comes from the engine only when it changes. BGTaskLease: expiration is synchronous, finish is idempotent. BackgroundAssertion wraps non-daemon steps started in the foreground. runBackgroundWindow:
1. reconcile;
2. apply;
3. submit staged bodies;
4. prepare the next job if none is daemon-owned;
5. in processing windows only, a best-effort metadata pre-sync (at most 20 s or 30 % of the budget) and then discovery;
6. finish once a daemon task is bound or nothing is runnable.
Refresh windows reconcile and submit only.
- **Migration:** None (dormant). The BG identifiers are unchanged.
- **Tests:**
  - testExpirationCompletesTaskSynchronously
  - testBackgroundLaunchStartsNoForegroundWork
  - testPathFlapDoesNotCancelDiscovery
  - testQueuedJobsRunWhenMetadataPreSyncFails
  - testWindowReturnsWhenWorkHandedToDaemonWithoutPolling
  - testLibraryChurnDoesNotPostponeWindows
- **Acceptance:**
  - Unit suite passes
  - Dormant
- **As built:**
  - `LifecycleEventSource` (Sources/Transfers, main actor) takes its readings through plain input methods, fed by `SystemLifecycleInputs` (NWPathMonitor on the main queue, battery, thermal, Low Power, app state), and registers and submits through the `BackgroundTaskScheduling` seam (`SystemBackgroundTaskScheduler` over BGTaskScheduler, on the non-deprecated `submitTaskRequest`). The network monitor's first callback seeds the snapshot on every launch, not only in the background. Coming forward and going to the background are their own events; the snapshot's appActive follows them without an extra environment event.
  - `SchedulePlan` holds delays, not dates, so an unchanged plan compares equal. The engine hands a plan to its `WindowScheduling` (the source) only when it changes, in order through one stream: the Automatic backup preference, with the engine not paused and no account block, asks for today's two windows (processing needing the network, power if Require charging is on, after max(30 s, trigger delay); refresh after 5 min); anything else asks for none. A manual run keeps them, as BackupLifecycle keeps them today; a pause drops them, as today's pause turns automatic backup off. The source submits a kind only when its shape changes or iOS used it up, and on its first plan reads what iOS still holds from an earlier launch, so a relaunch does not push a pending window back either. A request iOS turns down is asked for again when the app comes forward or goes to the background, or Photos changes (as BackupLifecycle resubmits today, but never replacing a request iOS took), and `schedulingError` carries today's message for B9 to show.
  - `BGTaskLease` gained its kind (from the identifier) and `onExpiration`; `expire()` completes the task first, synchronously, then cancels the window's work.
  - `TransferLifecycle` runs the windows over the `BackgroundWindowWork` seam. B6's reconcile and outcome application, "submit staged bodies" and the metadata pre-sync are steps of that seam; B9 builds the real one from Recovery, the engine, SyncEngine and LibraryDiscovery. The engine gained `handoff()`, which returns when a job advances to submitted or the loop finds nothing runnable (no polling), including a job that reaches submitted while the hand-off reads the store, and `daemonOwnsWork()`. A processing window runs step 4 before the pre-sync, as the scope lists, and once more after discovery if nothing went to the daemon yet. The pre-sync's budget is an assumed 120 s, so its limit is 20 s; an uncooperative pre-sync is abandoned, not awaited. A window that comes while another works completes at once, as today. Expiry cancels the window's steps but does not pause the engine (today's window pauses BackupCoordinator); the next launch frees the leases.
  - In the foreground, coming forward, a Photos change or a settings change starts a search after the trigger delay; a later trigger restarts the delay but never cancels a search under way (it searches once more afterwards). A condition change only calls the engine's conditionsChanged. In the background a Photos change does nothing. Going to the background holds a `BackgroundAssertion` until the engine hands off or has nothing runnable; the foreground search runs under one too.
  - scripts/check-single-engine.sh now also fails the build when code outside Sources/Transfers names the lifecycle's types: BackupLifecycle registers both identifiers until B9, and iOS allows one launch handler each. Info.plist and the identifiers are unchanged.

### B8 — Backup presentation on typed commands

- **Workstreams:** 2, 8. **Depends on:** B2. **Risk:** medium.
- **Scope:** BackupStore and ShareInboxModel run on TransferControlling. The temporary LegacyCoordinatorBackend wraps BackupCoordinator and ShareInboxStore (removed in B9). Views migrate:
- BackupSettingsView: debounced preferences, no polling;
- BackupQueueView: paged, adapter details;
- ShareInboxView: no polling;
- AlbumUploadStatusView: no activate();
- selection, local actions and LibraryView: typed enqueue results, no shared error;
- DiagnosticsView: counts.
Delete activate() calls from views; the app delegate activates once.
- **Migration:** None.
- **Tests:**
  - BackupStoreTests.testEnqueueReturnsItsOwnResult
  - testPreferencesWriteDebounced
  - testAlbumUploadCountsFromStore
- **Acceptance:**
  - On the phone, backup settings, queue and Shared files behave as before; progress updates without per-second polling
- **As built:**
  - `BackupStore` (main, `BackupStore.shared`, made at launch) serves Backup settings, the queue and confirmed uploads, the album upload chips, Diagnostics' counts and every "Back up selected" (LibraryView, LocalLibraryView, LocalPhotoActionsView through DevicePhotoActionsStore). It follows `snapshots()` and rereads failures, album counts and preferences with each snapshot. Preference edits are written 0.5 s after they pause, and before any command, so a command always runs with what the screen shows; a preference the backend changes (Pause switching automatic backup off) shows without being written back. Enqueue maps the call's own `EnqueueResult` or thrown error to `BackupEnqueueOutcome`; nothing reads a shared error for it.
  - `LegacyCoordinatorBackend` (main) is TransferControlling over BackupCoordinator and ShareInboxStore. Each command is the button it replaces: paused is Pause (automatic off, as today), manual is Back up now, retry is Retry failed uploads, enqueue is today's enqueue. Its snapshot stream comes from Observation of the coordinator, at most four a second with starting and stopping sent at once, so nothing polls. The queue page lists the queue in order, failed photos included, as the screen always did; history pages sort receipts off the main actor once per change.
  - Contract additions: `TransferSnapshot.activity` (today's status line; nil from the engine), `TransferRequest.album` (Upload to album; the engine's album destinations take it in B9), `preferences()`, and `albumUploadCounts()` returning `AlbumUploadCount { pending, failed }`. The engine's count joins album_destinations to failed jobs; a test pins it to today's counts on the golden state.
  - Upload progress is pushed: BackgroundUploads reports `didSendBodyData`, at most four times a second per task and at the last byte, to the coordinator and the share inbox. The upload speed is measured over a second or more, as the one-second poll measured it. The 1 s polling loops in BackupSettingsView and ShareInboxView are gone.
  - Correction applied: AccountManager calls `AccountDevice.activateBackup` on every transition to the active phase (launch and each sign-in), so no view calls activate(). The app delegate's launch and URLSession-event activations stay, as backup itself must not change. LibraryView refreshes the phone timeline when `activeScope` changes, since its activate() call went.
  - `ShareInboxModel` sends Upload and Pause through TransferControlling; the inbox's batches and per-file errors are still read from ShareInboxStore, the inbox's owner, until B9.
  - Free up space still reads verified candidates from BackupCoordinator (P4 owns it), and BackupLifecycle and PerfScenarioDriver still read the coordinator; B9 moves them.

### F5 — Places, people and shelf data as services

- **Workstreams:** 6. **Depends on:** Q3, F2, C7. **Risk:** medium.
- **Scope:** MonthPlacesService:
- serves memory, then index month_places, then a fresh count after 3 s;
- one count per query, plus at most one recount;
- epoch-fenced; 8 kept in memory with the library and displayed feeds pinned;
- year summaries computed once.
The TimelinePlacesCache JSON is imported once, then deleted. PeopleDirectory: single flight, single source per run, page cap. CollectionsStore: people, albums, features and orders; the newest load wins; reloads on scene active, a collection change, or a shelf opening after a failed load. PeoplePager serves PeopleView and SearchPeoplePicker, with the offline fallback. LibraryView.loadShelfData and loadAllPeople are deleted.
- **Migration:** Places JSON moves into month_places and the folder is deleted. ShelfOrder keys are unchanged.
- **Tests:**
  - testPlacesCountedBeforeAnAccessChangeAreNotKept
  - testSupersededReloadCannotChangePlaceTimelineSupport
  - testAllVisiblePeopleIsOneFlightFromOneSource
  - testPeoplePagerUsesTheOfflineFallback
  - testAStaleShelfLoadCannotDropANewAlbum
  - testFailedLaunchLoadKeepsPeopleAndAlbumsAndReloadsLater
  - Ported month-places tests
- **Acceptance:**
  - On the phone, rail place names appear right after relaunch
  - 147 people after a cold launch
  - An airplane-mode launch keeps the shelves
- **As built:**
  - `MonthPlacesService` (Sources/Library, main actor, observable; its reads, counts and ranking run off it) owns each feed's month places. The feed shown is served from memory, then from the index's month_places rows (aggregate connection), then counted afresh 3 s later through the feed's TimelineSource; the count is kept in memory and in the index under LibraryQuery.stableKey. One count runs at a time, for the feed shown; a reload while it runs asks for one recount after it, and showing another feed stops it. A count begins under the account's access epoch and, once the epoch moves, is neither shown nor kept: the feed is counted again. `IndexWriter.keepMonthPlaces` checks the epoch again inside its transaction, and SyncEngine moves the epoch before it clears month_places, so a write that passed the check before the move is removed by the clear and one after the move is refused. Eight feeds stay in memory, the library's and the feed shown pinned; the index keeps the twelve feeds written most recently (by rowid, as the twelve files were). `FeedPlaces` carries each year's two busiest places, worked out once per count, for the rail's year lens. LibraryStore keeps its places surface (monthPlaces, trips, placeSummary) over the service; TimeRail is unchanged.
  - `TimelinePlacesCache` and its per-scope epochs are gone: an access change clears month_places after the epoch moves, and a reset, a server reset or sign-out clears them with the derived tables. `LegacyPlacesImport` moves Caches/IlyichTimelinePlaces/<sha256(scope)>/*.json into month_places the first time the service reads the index, by hashing candidate keys (the library's, each shelf preset's, and every person, album in either order and partner the index knows), then deletes the account's folder, and the cache folder once it is empty. Its writes are fenced by the access epoch the service read before the import began, so an access change or sign-out during it keeps none of its rows. Wherever the earlier build deleted the files they are still deleted, unread (`LegacyPlacesImport.discard`): on an access change or reset, before SyncEngine moves the epoch, so an import that read them under the old epoch is refused or cleared; and at sign-out, through `AccountDevice.clearTimelineCaches` as before, whether or not the account's library ever opened to import them (review fix). The library's file is found under its pre-Q5 key, byte-equal. A place's key carries its membership revision and cannot be enumerated: its places are counted again when it opens. A file's trips are not imported, since the rows hold places, not trips; they return with the first count, 3 s after the feed shows.
  - `PeopleDirectory` loads every visible person for the shelves: one flight (callers that ask during a run join it), one source per run (the server's pages, or the index for the whole run when the first page gets no answer at all and the first sync is complete; a later page's failure fails the run rather than finishing it from the index), 100 per page, 50 pages at most. `APIClient.people(page:size:name:)`, which fell back page by page, became the server-only `peoplePage` and `offlinePeople(after:)`.
  - `PeoplePager` pages people by name for PeopleView and SearchPeoplePicker: numbered pages, a new query starts over and overtakes the page on its way, the offline library answers the whole query as one page when the server gives no answer at all (PeopleView had no offline fallback before), and a later page's failure is shown and asked for again on retry. The screens' own paging state went. Each screen keeps what it showed before (review fix): PeopleView starts with `keepingPeople`, so nothing changes during the debounce and the people it shows, which it filters itself, and whether there are more stay until the new query's first page replaces them, and stay when that page fails; a failed first page is asked for again on retry and then replaces them. SearchPeoplePicker empties at once.
  - `CollectionsStore` holds the shelves' people, albums, features and the owner's order; LibraryView.loadShelfData and loadAllPeople are deleted. The three loads run together and each applies as it lands; the newest load wins, so an older load landing late cannot put back what a newer one changed; a failed load keeps what the shelves show and is tried again when the app comes forward or the shelves open; a collection change loads again. New album and leaving an album change the store at once, as before, and are applied again over the albums of a load that was on its way when they happened (its answer may predate them), so no load drops an album made meanwhile or brings back one left (review fix).
  - Not done: a UI test of PeoplePager's numbered pages (the shared fixture serves every person in one page); the pages are unit-tested. testSupersededReloadCannotChangePlaceTimelineSupport is read as the shelves' features, which gate the Places row, not changing when a superseded load lands late.
  - C8 removed `LegacyPlacesImport` and its discard calls: no Caches/IlyichTimelinePlaces was left on the phone.

### T2 — One thumbnail scheduler; cells only bind

- **Workstreams:** 7. **Depends on:** T1. **Risk:** high.
- **Scope:** ThumbnailScheduler:
- a latest-wins mailbox and one job per key;
- band ceilings: visible 6, target 6, ahead 5, explicit 5, behind 4, coverage 2;
- decode lanes ordered by band, LIFO for visible items while scrubbing;
- epoch on every job; deliveries batched to one main hop per frame.
ThumbnailFetcher keeps today's session configuration and adds a request template, per-key backoff and task priority. DecodeLanes check an atomic wanted flag. ThumbnailBinder binds synchronously: memory exact, another size, sketch, average color; crossfade only over a placeholder. PhotoCell becomes passive. Interim: the Coordinator submits visible and prefetched items with its old gate as the motion proxy (removed in T3), and the warmer submits on the coverage band (removed in T5). Delete cell-owned loading, the detached prefetch decodes and MediaPipeline's grid flights.
- **Migration:** None.
- **Tests:**
  - testVisibleDemandGetsASlotWhileCoverageIsFetching
  - testObsoleteDiskDecodesNeverStart
  - testFetchedBytesAreDeliveredBeforeTheDiskWriteFinishes
  - testFailingThumbnailBacksOff
  - UI testRapidRightScrubLoadsVisibleThumbnails
- **Acceptance:**
  - On the phone, memory hits display in the same frame (100 %) and disk-hit p95 meets the budget
- **As built:**
  - ThumbnailScheduler (Core/ThumbnailScheduler.swift) is the only loader of grid thumbnails. One job per photo revision, whoever wants it: a grid's ViewportDemand (latest-wins mailbox per grid, worked in on the scheduler's own queue), or a single waiter (the viewer, filmstrip, feature tiles and globe on the explicit band, the warmer on coverage). The demand's generation is the media fence's token when it was built; every job carries it and the scheduler's generation, so forgotten photos and a reset are never stored or shown.
  - Download ceilings are read as "a band starts a download only while fewer than its ceiling are running" (visible/target 6, ahead/explicit 5, behind 4, coverage 2), so coverage never holds more than 2 slots and the screen always has one. A started download finishes into the store even if nobody wants it any more (as before); queued ones are dropped.
  - Decode lanes (3, off the main thread) pick the most urgent band; while scrubbing, visible photos go newest-on-screen first, otherwise nearest the middle. A lane checks the job's atomic wanted flag before reading the file. Downloaded bytes are decoded straight from memory and delivered while the disk write is still queued. A grid's deliveries are batched: everything finished before the main thread gets to it arrives in one hop (coalesced hop rather than a display link).
  - ThumbnailFetcher keeps the old thumbnail session configuration, builds requests from a template refreshed every 10 s and after any failure (query encoded as ServerAddress does, "+" as %2B), sets URLSessionTask priority by band, and backs a failing photo off 2 s, doubling to 5 min. A visible photo that failed is retried when its wait ends, instead of only when its cell was bound again.
  - ThumbnailBinder (Library/ThumbnailBinder.swift), one per grid, binds synchronously (exact size from memory, this photo at another size, its sketch, its average colour) and draws deliveries into the cells still showing that photo; crossfade only over a placeholder and never under Reduce Motion (critic's correction). PhotoCell no longer loads server photos. Phone-only photos still stream from PhotoKit in the cell until T6 moves them into the thumbnail service.
  - Interim as planned: the Coordinator's speed gate and rest timer are the motion proxy (closed gate = scrubbing: disk only), it submits visible cells and UIKit's prefetched paths (ahead band), at most once per run-loop turn. The warmer submits on coverage. Deleted: ThumbnailDecoder, the cells' loading tasks, MediaPipeline's grid flights, prefetchThumbnails and the detached decode.

### T3 — Viewport motion policy replaces wait-until-stopped

- **Workstreams:** 7. **Depends on:** T2, F2. **Risk:** high.
- **Scope:** GridViewport forwards the scroll delegate, including the willEndDragging target. Speed is an EMA. Visible, ahead (1 to 3 screens in the direction of travel) and behind (1 screen) windows come from the layout, with pins. Demand is submitted at most once per frame and also when a month becomes ready. Policy:
- scrubbing or above 2.5 screens/s: visible items from memory or disk at scrub tier; the network serves the target only;
- below 1.2 screens/s or idle: upgrade and fetch center-out;
- coverage only after 1.5 s idle.
Delete the Coordinator gate, rest timer and settle logic. Update the DESIGN.md binding with owner sign-off. The UI fixture adds thumbnail delay, offline and request-counter knobs.
- **Migration:** None.
- **Tests:**
  - testCellsLoadAfterAFastScrubStopsWithoutAnotherGesture
  - testFlingTargetIsPreparedBeforeDecelerationEnds
  - testRailScrubHoldsCoverage
  - testVisibleMonthReadinessDemandsThumbnailsWithoutAScroll
  - UI testOfflineRandomRailJumpsShowStoredThumbnails
- **Acceptance:**
  - On the phone, rail-sweep and fling hitch ratio is under 5 ms/s; prepared visible cells show real pixels within 300 ms per jump
- **As built:**
  - `GridViewport` (Sources/Library) takes the scroll delegate, including `willEndDragging`'s target, and the rail's state (through `TimelinePosition.isScrubbing`, until T4 hands it the pan). It measures the speed as an exponential moving average of screens per second over about 80 ms, seeded with UIKit's own velocity when a fling starts, and the direction of travel from the offset's deltas. It reads the windows off `VirtualPhotoLayout`: ahead in the direction of travel (one screen at rest or a slow scroll, as many screens as the grid moves in a second up to three), behind (one screen) and the fling's landing screen, each nearest the screen first and capped (150, 60, 80). The photos on screen still come from the cells through `ThumbnailBinder`, which knows what each cell shows; the binder puts the four bands into one demand, no photo twice, and prefetches the sketches of the target photos, and of the ahead photos unless the grid is fast (`ViewportPolicy.prefetchesSketchesAhead`: a rail sweep would otherwise queue a whole new window of sketches every frame). `ThumbHashSketches.prefetch` queues a hash once while it waits to decode, on a queue of its own at utility priority, so a cell's own sketch never waits behind the prefetch. UIKit's prefetch data source is gone with the Coordinator's gate, rest timer and settle logic.
  - The demand goes out at most once per frame, on a `CADisplayLink` that runs only while the grid moves, the rail's finger is down or a demand waits, and only when the rows on screen, the motion kind, the speed's side of the policy's thresholds, the direction, the ahead window, the fling target or the cell size changed since the last one, so a slow scroll within the same rows costs nothing. `contentChanged` (a month became ready, new rows, a reset, a density change) sends one again without a scroll. A delegate-reported stop (the drag ends, the deceleration ends, an animation ends) is idle on the next frame; an offset still for 100 ms is idle too (a held finger, the rail's resting finger, a perf scenario), and a fling whose end was never reported is idle after 500 ms still. The rail taking the grid from a fling drops the fling's target and its deceleration (setContentOffset stops a deceleration without a delegate end). The speed is measured only across frames the link ran: a jump after a rest (the rail, a date, Show in timeline, a perf jump) is not a fast scroll, and its screen downloads at once.
  - Policy (`ViewportPolicy`, Sources/Core): scrubbing or above 2.5 screens/s is fast, below 1.2 is slow, between them the grid's last decision stands; the scheduler keeps the decision per grid (`ThumbnailScheduler` reads it from each demand's motion), so there is one decider. While fast, only the target band downloads: a fling's landing screen, and the month under the rail's finger once it has rested 100 ms (the viewport sends the screen on the target band then, while the motion stays scrubbing, so the photos ahead and behind stay disk-only and coverage stays held). At rest or slow, the screen downloads from the middle out, then ahead, then behind, each under its ceiling as before. Visible photos decode newest-on-screen first while fast, as they did while scrubbing. Coverage's 1.5 s hold after motion is T5's `CoveragePolicy.motionHold`, fed by `TimelinePosition.onMotionChange` as before; `ViewportPolicy.coverageHold` names the same value and a test pins them equal.
  - Not done here: the scrub tier. `DecodeTier.scrub` has no files behind it until T7 decides, so a fast grid decodes stored thumbnails at the cell's size as T1 built it, with nothing to upgrade afterwards. Pins stay where T1 put them (a cell pins the photo it shows while on screen). PerfScenarioDriver still drives `store.scroller` and `TimelinePosition`; the viewport sees its scrolls through the delegate (T4 ports it, per the critic). The UI fixture server is shared by every test run and could not be edited or restarted, so the offline knob is the app's: `--ui-testing-offline-media` puts `OfflineMediaProtocol` (DEBUG only) in front of the media sessions, and every thumbnail, preview and original fails as without a network while the library itself still loads. No delay or request-counter knob was added; the UI test that needed offline tells a stored thumbnail from a sketch by the fixture photo's sun, since the fixture's sketch is as chromatic as its photos.
  - DESIGN.md 6's "downloads wait while photos pass fast" sentence now describes the target-first policy; it awaits the owner's sign-off.

### T4 — Rail and grid share one interaction model

- **Workstreams:** 7. **Depends on:** T3, F3. **Risk:** medium.
- **Scope:** TimeRailController holds TimeRailRest, open/hold state, the month and finger y. The UIKit pan calls handle() synchronously, which calls viewport.scrub(toFraction:). GridScroller moves out of LibraryStore into GridScrollController. TimelinePosition.isScrolling is replaced by the viewport phase. Lens previews use the explicit band at 3 x 38 pt. Lens place names come from projections, not a main-thread scan. The timePan observable is removed.
- **Migration:** None.
- **Tests:**
  - testRailPanMovesTheGridSynchronously
  - TimeRailRestTests unchanged
  - Rail UI flows (opens before photos move, scrubs back to newest, works with Earth open) unchanged
- **Acceptance:**
  - On the phone, rail-sweep hitch ratio is under 5 ms/s and DESIGN 9 rail behavior is unchanged (owner check)
- **As built:**
  - `TimeRailController` (Sources/Library, main actor, observable) holds the rail's interaction: `TimeRailRest` and its held moves, whether the lens and the column are out and have finished opening, the puck's visibility and its fade, the month under the finger or chosen (and a chosen year), the finger's y and the months' scale. `LibraryView.handleEdgePan` hands every trailing pan event to `handle(_:)` in the gesture's own callback; once the rail is open, the move goes on to `GridViewport.scrub(toFraction:)`, which sets the grid's offset at once, so the grid's delegate, the month the store reports and the demand all see it before the callback returns, with no SwiftUI update in between. `LibraryEdgeInteraction.timePan` and the view's `onChange` are gone. Opening before the photos move, the hold where the finger stops, the lift's quicker close, the tap-open, year taps, VoiceOver's adjust and the puck after a drag are the view's code moved over unchanged. The controller reaches the feed through `TimeRailFeed` (its months, the grid's position, `cancelPendingNavigation`, `scrollToBucket`), which LibraryStore adopts and F6's feed store can. A rail view put back on screen (shelves or search closed) starts afresh as its @State did; one that only reappears (the viewer closed) keeps where it was, told apart by a token in the view's own state.
  - `GridScrollController` (Sources/Library) is GridScroller moved out of LibraryStore, beside `TimelinePosition`, now the grid's section and item only. The grid's `GridViewport` owns it; the rail, the perf driver and the viewer's zoom (`zoomSourceView(for:in:)`) go through it. LibraryView owns the viewport and the controller and hands the viewport to PhotoGrid; a grid without a rail (Similar photos) makes its own. LibraryStore's only change is the removal of both types and its `scroller`.
  - `TimelinePosition.isScrolling` and `isScrubbing` are replaced by `GridViewport.phase` (idle, dragging, decelerating, scrubbing), set by the scroll delegate and the rail. `onScrollingChange` brings out the rail's puck and lets it fade; `onMotionChange` holds coverage as `TimelinePosition.onMotionChange` did. Two stuck states go with the flag: the rail grabbing a coasting grid used to leave isScrolling on (coverage held, and the next drag's puck missing) until another drag ended, and a coast whose end UIKit never reports now ends after the viewport's half second still. The viewport keeps UIKit's own scrolling apart from the rail's finger (`scrollPhase`, review fix): the rail's touch never reaches the collection view, so a coast the finger lands on goes on unless the rail moves the grid (setContentOffset ends it silently), and a touch lifted before the rail opens leaves the grid coasting, coverage held, until UIKit reports the end, as isScrolling did. A drag the finger lands on stays the rail's until it lifts.
  - The view (TimeRail.swift) draws the controller's state with the same views and modifiers in the same containers. Only what the finger places reads it: the lens, its bridge and the accent line are placed by a modifier that reads the finger, and the trip marks, which step aside for the lens, are a view of their own that reads the feed's trips once instead of once per month. The tape, the years and what the lens shows are drawn again only when the month or what is known of it changes; before, every move of the finger drew the whole rail twice (the timePan change, then fingerY), the Canvas of every tick included. On the simulator, screenshots of the rail at rest, tapped open, after a scrub and with a year chosen match the previous build's pixel for pixel, apart from grid thumbnails that arrived at a different moment. Views that read the controller keep reading it while they animate away, which values passed down from the old view's body did not (review fix): so a closing keeps the finger, the month and a chosen year until its animation has removed the lens, its bridge, the line and the trips (`animateClosing`, completion criteria `.removed`; the rail used again first forgets them then), `currentY` no longer drops to the rail's top once `expanded` is false, and the puck reads only the grid's or a chosen month's position (`puckY`). Lifting the finger, a tapped rail timing out and a chosen year all melt where they were again, and the puck slides out from where it was when a finger lands.
  - Already in place, unchanged: the lens's photos are FeatureAssetImage tiles, asked of the scheduler on the explicit band at their own pixel size since T6 (38 pt at 3x is 114 px, asked as 128, the grid's floor, so a grid thumbnail in memory serves them); the lens's place names come from the month projections (F3) or the feed's month places (F5), the year's worked out once per count, so nothing scans photos on the main thread.
  - PerfScenarioDriver (critic's correction) runs on the viewport and the controller, and by default drives the grid as C4's driver did, so every build's numbers compare with the C4 baseline (review fix): rail-random and rail-sweep scrub through `GridViewport.beginScrub`, `scrub(toFraction:)` and `endScrub` with nothing drawn over the grid, and fling and reverse tell the viewport the drag, its end and the coast's end (or the next flick catching it) but not the landing, which C4's flings never had. The one difference left from C4's input: the viewport hears a fling end, so its screen is at rest on the next frame rather than after the policy's tenth of a second. `-IlyichPerfDrive finger` (record.sh: `ILYICH_PERF_DRIVE=finger`) drives them as a finger does: the rail's controller scrubs as a finger once the rail is open (`beginDrivenScrub`, `drive`, `endDrivenScrub`), so the lens, the column, the month ticks, the haptics and the lens's photos come with every scrub, and each fling tells the viewport its velocity and landing as UIKit does. Its summaries carry `"drive": "finger"` (default summaries are unchanged) and record.sh writes its table beside the default one; compare finger runs only with finger runs.
  - Tests: TimeRailControllerTests (testRailPanMovesTheGridSynchronously: each pan event has moved the grid, run its delegate and set the month before `handle` returns; a touch lifted before the rail opens moves nothing even when the opening ends later; a driven scrub moves at once and holds coverage; without a grid the rail asks the feed for the month; a rail that leaves the screen lets go of the grid; review fixes: closing after a scrub or a tap keeps the line, the lens and the month where they were until the closing ends, the puck leaves from the grid's position as a finger lands, and a coast goes on under a touch that moves nothing but ends once the rail moves the grid). GridViewportTests drive the rail through `beginScrub`/`endScrub` (and `scrub(toFraction:)` where the rail moves the grid) and add testThePhaseFollowsTheDragTheCoastAndTheRail. PerfScenarioDriverTests parse the drive and check that only the finger drive is named in a summary. TimeRailRestTests unchanged; the rail UI flows and PerfScenarioUITests pass unchanged.

### P5 — Device index service replaces DeviceTimelineIndex

- **Workstreams:** 4. **Depends on:** P2, Q4, Q6. **Risk:** medium.
- **Scope:** DeviceIndexService (per runtime) consumes adapter changes, ReceiptRepository and visible identity rows (deletedAt null, timeline visibility) and publishes DeviceSnapshot. Only changed IDs are re-read. Fingerprinting stays serial, without network, aware of Low Power and thermal state, and re-checks the revision; results go to device_fingerprint. Legacy Caches/IlyichFingerprints JSON is imported, then deleted. A phone copy of a trashed or archived server asset stays local-only (locked per owner). LibraryView no longer owns the index.
- **Migration:** Fingerprint JSON moves into device.sqlite, then the file is deleted.
- **Tests:**
  - testSingleAssetChangeRereadsOnlyThatAsset
  - testLegacyFingerprintCacheIsImportedAndNotRehashed
  - testPhoneCopyOfTrashedServerAssetStaysVisibleAsLocal
- **Acceptance:**
  - On the phone, the merged library shows phone-only months with no rehash after install
- **As built:**
  - `DeviceIndexService` (Sources/Device, actor) is made per runtime when the environment uses the phone's photos and shut down at teardown; `DeviceTimelineIndex` is deleted. LibraryView only subscribes (`snapshots()`) and hands each snapshot's `MergedTimeline` to LibraryStore, as before. The first subscriber starts the service, so background launches and unit tests never read Photos. It works only while the app is in front (AccountSession forwards scene changes), as the old index stopped in the background.
  - Reads: the backup albums' members, identifiers only, then each asset once. A change from Photos re-reads only the assets it names; membership is re-enumerated (identifiers only) when albums may have changed, a photo was inserted, or the app comes forward. A change that Photos can't describe, or an access change, reads everything again. The old index re-read all 60k photos, cloud IDs and resource lists, and the whole identity table, after every burst, every sync pass and every foreground.
  - Matching is the old index's, step for step and in the same order (receipt for the same revision with its server copy present, fingerprint for the same revision, cloud identity for an unedited photo), so the photos, badges and order are unchanged, with one owner-locked difference: only visible identity rows can match (`LibraryIndex.identities` returns the owner's rows keyset-paged, each flagged visible when `deletedAt` is null and visibility is timeline), so a phone copy of a trashed, archived, hidden or locked server photo shows as a phone photo instead of disappearing. A phone photo whose receipt or cloud identity names such a hidden row is not fingerprinted, as no hash could match it. Album membership (identifiers only) is read again on any change that names a changed photo too, as a favorite or an edit moves it in or out of smart albums such as Favorites. `localAssetMatches` is gone.
  - Fingerprints: device.sqlite gains `device_fingerprint(local_id PK, revision REAL, checksum)`, user_version 2. At first start every `Caches/IlyichFingerprints/*.json` is imported (every account's file, as checksums don't depend on the account; a row the table already has wins), each file is deleted once committed, then the folder. An unreadable file is deleted and its photos are hashed again. Hashing is serial, without network, pauses in Low Power mode or when the phone is hot (retrying a minute later), re-checks the revision, and runs only while the offline library is complete with at least one row, as before. Rows are written 25 at a time, when the queue empties and when the app goes to the background; fingerprints of photos Photos reports removed are deleted.
  - Inputs: preferences and receipts come from today's backup state through `LegacyBackupIndexInputs` (section 9, until B9), only while the account's backup state is the one taken up, and without taking it up; server changes come from the sync's LibraryChange stream instead of the legacy notification. Server changes are coalesced for a second and backup changes (every upload moves a receipt) for five, the first of each read at once; an identical result is not published, so backup uploading doesn't make the grid reload.
  - `DeviceSnapshot` (C2's contract) is available as `DeviceIndexSnapshot.device()`; nothing consumes it until F3, so the store still takes `MergedTimeline`.
  - C8 removed the fingerprint import: no Caches/IlyichFingerprints was left on the phone, and no build that writes it will be installed again.

### W1 — Capability policy and export service

- **Workstreams:** 9. **Depends on:** C5. **Risk:** medium.
- **Scope:** AssetCapabilityPolicy:
- locked assets hide cast, add to album, shared link, profile photo, album cover, find similar, open in browser, comments, archive and stack;
- edit matches the server: EQUIRECTANGULAR upper-cased, .insp, gif and svg by extension, Live Photos, trashed, known edit state;
- ownership required; read-only disables;
- a selection intersects the per-asset results;
- download, share and save on locked assets per owner decision.
The viewer menu and footer, BulkActionsView, AssetInfoView and ViewerStackView render from it. MediaExportService replaces AssetViewer.transfer and AssetInfo's untracked download. The UI fixture adds a locked asset.
- **Migration:** None.
- **Tests:**
  - AssetCapabilityPolicyTests: cast hidden when locked; edit hidden for panorama and .insp; trashed; locked hides album, link, profile, browser, similar and cover; selection matches single; read-only
  - MediaExportServiceTests
  - UI testLockedFolderViewerMenuOffersOnlyPermittedActions
- **Acceptance:**
  - On the phone, the locked viewer menu shows only permitted actions and a panorama has no Edit
- **As built:** Build 3040066. AssetCapabilityPolicy drives the viewer, the selection actions, the info sheet and stacks; MediaExportService runs exports with an ExportTracker per screen; locked photos keep Share, Download original and Save to Photos (the default; owner question).

### N1 — Typed navigation and one presentation host

- **Workstreams:** 8. **Depends on:** C7. **Risk:** medium.
- **Scope:** LibraryNavigator: a layer stack, an alert slot, an overlay, one deferred intent and a generation counter. PresentationHost has one sheet and one cover per level and calls layerDidDismiss exactly once. DeepLinkResolver is fenced; it dismisses everything, then performs. presentWhenIdle covers Shared files. Deleted from LibraryView: the screen, viewing, local and album context, memory and activity context, pending destination and place focus, bulk selection, album sharing, create album, delete confirmation, error and shared-files flags. Also deleted: PhotoDestination and the MemoriesView pending chain. Opening the viewer from More keeps today's close-then-present behavior unless the owner chooses otherwise.
- **Migration:** None.
- **Tests:**
  - NavigatorTests: deep link while a sheet is open; a newer link cancels; showInTimeline from a memory unwinds once; Shared files waits while any modal or overlay is up
  - AppLinkTests additions
  - UI testDeepLinkOpensAssetOverOpenSheet
- **Acceptance:**
  - On the phone, a widget tap opens the photo even with a sheet open; memory Show in timeline lands once
- **As built:** `LibraryScreenModel` (Sources/Library) owns the `LibraryNavigator`, follows links, shows new shared files once nothing else is up, and warms up the Earth (the critic's correction). LibraryView keeps the shelves, the feed's filters and the search text; its shelves and Earth flags read and write the navigator's overlay, so the shelf code is unchanged. Where the code needed it, the contracts' sketch changed:
  - `LibraryOverlay` holds two flags rather than one case, since the shelves come out over the Earth.
  - Errors and confirmations sit in the alert slot rather than among the routes, as SwiftUI presents them apart from sheets.
  - Routes carry what their screens need (the photo, the album, the phone photo, the memories) rather than IDs that nothing could look up yet. `more(path:)`, `albumEditor`, `apply(LibraryQuery)` and `openShelf` wait for the milestones that use them, and the settings routes gained the viewer's screen.
  - Layers close one at a time from the top, as today's chained closes did, so each close is reported by its own host.
  - A link closes everything at once, the viewer and any sheet it has open included, and opens once it has been looked up; the shelves and the Earth stay. Albums and people the shelves hold are used without asking the server, which also spares fetching an album with every photo in it. A link that can't be followed says why over the library, where before the alert could be lost under a sheet.
  - While a full-screen viewer is up, the library is out of the window, and SwiftUI doesn't update it for a change from outside such as a link. A link that arrived then used to wait until the viewer was closed by hand. The screen model now watches the session for links, and the zoom presenter watches its own item.
  - `XCUIApplication.open` relaunches the app, so UI tests send links to the running app through `XCUIDevice.shared.system.open`; the cold-launch test relaunches on purpose. The shared fixture serves no single memory or album, so `immich://memory?id=` and a cold-launch album link have no UI test, and phone photos have none in UI tests.

### N2 — Mutation service and typed results

- **Workstreams:** 8. **Depends on:** Q6, F4, C5. **Risk:** high.
- **Scope:** LibraryMutationService: start() returns a handle owned by the service. Each request checks read-only and ownership, makes one HTTP call, reads partial results, invalidates media precisely, merges the follow-up sync and publishes. The viewer, selection bar, BulkActionsView, Duplicates and Trash route through it. SelectionCapabilities: a Trash selection offers restore and permanent delete only. Deleted: runSelection, the view-side cache wipes and onChanged refreshes. The UI fixture becomes stateful for asset, trash and album mutations.
- **Migration:** None.
- **Tests:**
  - testLockingOnePhotoForgetsOnlyThatPhoto
  - testTrashRestoreAndDuplicateResolveKeepOfflineThumbnails
  - testFollowUpSyncSummaryReachesSubscribers
  - testAResultIsPublishedAfterThePresentingScreenIsGone
  - SelectionCapabilitiesTests
  - UI testDeletingFromTheViewerRemovesThePhotoFromTheFeed and testArchivingFromTheViewerRemovesItFromTheLibrary
- **Acceptance:**
  - On the phone, a trash restore keeps thumbnails; a bulk favorite inside a filter updates in place without a jump
- **As built:**
  - `LibraryMutationService` (Sources/Library) is one actor per account, made by AccountRuntime and shut down first at teardown. `start(_:on:)` takes a `MutationRequest` and the screen's own records of the photos it names, returns a `MutationHandle`, and runs the work in a task the service owns, so it ends the same whether the screen waits, closes or is gone. A request is refused before it is sent in read-only mode (the transport refuses it again), and for photos the account may not change that way (`MutationPlan`): only the owner changes a photo's state, details, stack or edits, and a locked photo never goes in an album; a bulk request sends the rest and reports each photo refused, while a request for one photo, or one that must change all of them, is refused whole. Each request is one HTTP call (taking several photos out of a stack is one per photo, as the API has it), and a bulk answer is read photo by photo. Media is invalidated precisely: a lock forgets the photo's media at once, revoked; a permanent delete or an emptied Trash forgets those photos; an edit's old revision leaves once the new one exists; Trash, restore and duplicate resolve keep every thumbnail. The result is then published (`MutationEvent.applied`), the account's sync is asked for a pass, and the result is published again with the pass's change merged in (`.followedUp`); without an offline library nothing follows.
  - A result carries the photos' records as the change left them: the server's where it answered with one, else the asking screen's record changed as the server changed it (`MutationRequest.applied(to:)`), since the bulk calls answer with nothing. `MutationResult` gained `album` (the album made, or whose cover was set) and `affected` (Trash's own count).
  - Deviation from section 4's "the hub publishes": results go out on the service's own stream, not as hub LibraryChanges. The hub hands a change's removals to MediaPipeline.apply, which forgets the media of every removed photo of a non-sync origin, and a photo put in Trash must keep its thumbnails; the feed's own commands (F4's `update` and `removeLocally`) already apply a result precisely and in place. The follow-up pass reaches every hub subscriber as any pass does, and N4's bus can carry both.
  - Every screen that shows photos applies the results, whichever screen made the change (the critic's correction): the library feed (`FeedMutationApplier`, through `update`, `removeLocally` and `refreshAfterMutation` only, which F6 keeps; a photo put in Trash or restored leaves the feed of its old trash state, and its record goes to a feed of the other; the feed reads its months again itself only when no sync follows), the viewer's own records, the folder grid, the Locked Folder grid, the Trash, Duplicates, a photo's Info collection, Similar photos and a stack's sheet (`onMutationApplied`, `CollectionMembership`, `DuplicateGroups`). A subscription lives as long as its screen, not its tasks, since SwiftUI ends a screen's tasks while a full-screen viewer covers it. Left out: On this day, which closes before its photo opens; the album photo picker, whose own changes apply locally; the albums list (N4).
  - Through the service: the viewer's favorite, archive, Locked Folder moves, delete, restore, Add to album and album cover; its details' caption, rating, date and location and face fixes; the editor's save with the revision polling the critic moved here, so the new preview reaches the feed even if the editor has closed; a stack's cover, removal and unstack; the selection bar; BulkActionsView; Duplicates' resolve and dismiss; Trash's restore, delete, Restore all and Empty; the album photo picker. Tags keep their editor: `MutationRequest.tag` has no untag. Deleted: `runSelection`, the refreshes after a change in the selection actions and the folder and Locked Folder grids, the cache wipes of the viewer, BulkActionsView, Duplicates and Trash with the cachesReset they posted, and the stack sheet's `onChanged`, which took the viewer's photo out of the feed.
  - `SelectionCapabilities`: a selection all in the Trash offers only Restore and Delete permanently, in the selection bar and the selection actions; any other selection offers what every photo allows, as before. While the server's features load, Restore waits.
  - Locking and archiving use the bulk endpoint, as Immich's own apps do; locking there also takes the photo out of its albums, which PUT assets/{id} did not.
  - The UI fixture keeps a mutable session's asset, Trash and album changes for that session's token alone, new each launch (`--ui-testing-mutable-library`). Every other token's answers are byte for byte the old script's, checked request by request, so the tests sharing the server see nothing of another test's changes.
  - Tests: LibraryMutationServiceTests (the four named tests, a permanent delete, an edit's polling and a late preview, read-only, ownership, a partly refused bulk call, shutdown, the mutable session's token), SelectionCapabilitiesTests, MutationEffectsTests (one per collection kind as the critic asked, folder grid delete, Locked Folder Move to Timeline, Trash restore and Duplicates resolve, plus the feed's effect, the feed reading again only without a follow-up, the acceptance's bulk favorite inside a filter updating in place with nothing read again, and a photo put in Trash that no earlier read brings back, the owner's lingering photo), and UI testDeletingFromTheViewerRemovesThePhotoFromTheFeed and testArchivingFromTheViewerRemovesItFromTheLibrary, which use the mutable session.

### N3 — Viewer model and asset windows

- **Workstreams:** 8. **Depends on:** N1, N2, W1. **Risk:** medium.
- **Scope:** ViewerModel holds assets, selection and replacements, a sheet enum, a cover enum and a confirmation, and replaces the viewer's 16 flags. AssetWindowProvider has feed, collection, stack, similar, single and locked variants and is always asked about the current photo. refreshCurrentAsset writes replacements only; it publishes only when revision, visibility, trash or favorite changed. The onUpdated, onDeleted and onExploreLocation closures are deleted; explore and show-in-timeline become intents. Nested viewers present a ViewerRoute with their source. Deleting a photo keeps today's dismiss unless the owner chooses otherwise.
- **Migration:** None.
- **Tests:**
  - testDeletingTheSwipedToPhotoRemovesThatPhoto
  - testAFeedReloadKeepsTheCurrentPhoto
  - UI testOneSwipeAdvancesExactlyOnePhoto
  - Rotation, close and reopen viewer UI tests unchanged
- **Acceptance:**
  - On the phone, swiping 50 photos during a sync stays on the right photo; deleting after swiping removes that photo
- **As built:**
  - `ViewerModel` (Sources/Viewer/ViewerModel.swift) holds the photos the viewer pages through, the photo on screen and the fresher records, one `ViewerSheet` (details, place, album, shared link, stack, comments, Cast, similar photos, profile photo, the phone's copy, share), one `ViewerCover` (editor, Select text, slideshow) and one `ViewerConfirmation` (delete), with the alert, the running change, the exports and the refresh of the photo on screen. AssetViewer keeps only what it draws: the bars shown, Live Photo playback, the video pill, the pager's phase and the insets. Its commands run the mutations as N2 left them.
  - `AssetWindowProvider` (Sources/Viewer/AssetWindow.swift) has the six variants. Collection, stack and locked read an `AssetList` that the screen and its viewer share: Info collections, a stack's sheet, the Locked Folder. The model watches the source through Observation, so the zoom viewer, which SwiftUI no longer updated from the library under it, follows the feed live. It reads the window around the photo on screen whenever the source changes and whenever the photos have rested 0.35 s, never while a swipe or a scrub moves them. The feed's window is that photo's month and the months beside it, as loaded, so the viewer pages on into the next loaded month once it rests there; before, it stopped at the months beside the photo it opened on. A photo the source no longer holds (archived here, or deleted elsewhere and not yet read again) stays where it was on screen, placed by the window around its neighbor.
  - The pages move in the same change as the photos. The strip is laid out afresh under the old one, which fades out once both show the same thumbnails. On simulator recordings, checked frame by frame across a window that dropped the 100 photos before the one on screen, a strip scrolled in the same change landed past its end, and one scrolled a change later showed other thumbnails for a frame; the photo itself never moved.
  - refreshCurrentAsset writes replacements only. It publishes to the source only when the media revision (mediaRevision where both records carry one, else thumbhash), the visibility, the Trash or the favorite changed; before, every photo opened pushed its detailed record into the feed, which laid its month out again.
  - Deleted: AssetViewer's onUpdated, onDeleted and onExploreLocation, AssetInfoView's onUpdated and onExploreLocation (it takes the model), ViewerStackView's onUpdated, and pendingLocation. A photo found gone goes to its source (`lose`): the feed takes it out and asks the sync, as before; a list drops it and counts the loss, on which the Locked Folder and a stack read themselves again, as before.
  - Explore is the `.exploreLocation` intent, sent through the library's navigator by the library's viewer only. A sheet over the viewer closes first, then the viewer, then the Earth rises, the details' sequence as before (testPhotoInfoLocationOpensFocusedInteractiveEarth). Viewers opened over other screens show the place in a sheet, as before. The viewer has no Show in timeline; the memories' has been an intent since N1.
  - Nested viewers present a `ViewerRoute`, now Identifiable, with their source (`.collection`, `.stack`, `.similar`, `.locked`), and the zoom presenter takes the library's route. `.single` exists for a photo alone; nothing opens one yet.
  - Deleting moves on (deviation from the scope's "keeps today's dismiss", by the integrator's brief, which extends the owner's P3 answer for the phone's viewer): the photo on screen goes, not the one opened, and the viewer stays with the photo after it, or else the one before, in its place, as Photos does; it closes when no photo is left. An answer that comes mid-swipe waits for the photos to rest, and a source that hasn't yet applied the deletion doesn't bring the photo back. Before, the server viewer closed after a delete. Restore and Move to Locked Folder still close.
  - Tests: ViewerModelTests (the two named tests, the window following the photo on screen, the rest before it moves, archiving keeping the photo on screen, a collection's list, a deleted photo staying out of a source yet to apply the deletion, a refresh publishing only what lists show, the merge, explore as an intent) and UI testOneSwipeAdvancesExactlyOnePhoto, which also crosses the newest month's end. N2's testDeletingFromTheViewerRemovesThePhotoFromTheFeed now checks that the viewer stays on the next photo before closing it. The rotation, close and reopen UI tests are unchanged.

### N4 — Collections service, typed shelves, notification dictionaries retired

- **Workstreams:** 8. **Depends on:** N2, N3, F5. **Risk:** medium.
- **Scope:** CollectionsService handles albums, roles, members, links, people, partners and memories, publishing CollectionChange; CollectionsStore applies the changes in place. The feed clears its filter when the filtered album is deleted or left, and reloads on partnersChanged. ShelfCatalog rows carry a typed ShelfAction instead of a closure, from one LibraryCollection enum. The Sharing sheet closes on leave; the album name clears after create. Deleted: ilyichLibraryChanged, ilyichCachesReset, their posts and observers, and LegacyNotificationBridge. Diagnostics clear goes through AccountManager.
- **Migration:** None.
- **Tests:**
  - CollectionsStoreTests
  - testDeletingOrLeavingTheFilteredAlbumClearsTheFilter
  - ShelfCatalogTests: rows and IDs match today
  - The 30 shelf geometry tests and the shelf UI flows unchanged
  - UI testLeavingASharedAlbumClosesSharingAndClearsTheFilter
  - BusTests: every subscriber gets mutation and sync changes
- **Acceptance:**
  - On the phone, shelf choreography is unchanged (owner check); an album rename shows on the shelf immediately
- **As built:**
  - `LibraryBus` (Sources/Account) is the typed bus, one per account, made by AccountRuntime and closed first at teardown, so nothing the account does afterwards reaches a screen. It carries `LibraryEvent`: a sync's change once media has taken it in (`.changed`, with whether access may have been lost), a mutation's result (`.mutation`, N2's `.applied` and `.followedUp`), a collection change (`.collection`) and a cleared browsing cache (`.cachesCleared`). Posting never waits; each subscriber has a mailbox that keeps every event in order and folds sync changes it hasn't taken yet, one after another, into one. LibraryChangeHub posts its changes there instead of LegacyNotificationBridge and keeps its own merging mailboxes for coverage, the device index and cleanup. LibraryMutationService publishes on the bus; its `events()` is the bus's mutation results, so `onMutationApplied` and the screens N2 wired are unchanged. The app puts the bus in the environment (`\.libraryBus`), and the zoomed viewer is handed it as it is handed the mutations.
  - Deleted: ilyichLibraryChanged, ilyichCachesReset, their posts and observers, and LegacyNotificationBridge. Every subscriber moved to the bus, each covered by BusTests: the feed and its search results (`FeedEventApplier`: a sync's change applies in place as before, a mutation's result through FeedMutationApplier), the viewer's refresh (ViewerModel follows the bus for both its mutation results and the sync's changes), the shelves (CollectionsStore reloads on the sync changes that set the old `collections` flag, now `LibraryChange.reloadsCollections`) and Diagnostics' Clear browsing cache, which goes through AccountManager to `AccountRuntime.clearBrowsingCache` and the feed reads its months again.
  - `CollectionsService` (Sources/Library, an actor per account, shut down after the mutations) makes every change to albums (create, rename and order, delete, leave), members and roles, shared links, people, partners and memories, and album comments and likes (the critic's correction). A change is refused in read-only mode before it is sent and runs as the service's own work; reads belong to the screen that asks. Its result goes out as a `CollectionChange`, which now carries the server's record (an album, a person) so lists apply it without asking again. An album a mutation made or changed (made from the selected photos, its cover set, photos added or taken out) goes out the same way, read again for its count where the mutation's answer has no record. CollectionsStore follows the bus and applies changes in place, again over a load on its way; AlbumsView applies them to its list (`onCollectionChange`); the feed clears its filter when the album it shows is deleted or left, takes a rename into the filter tag, reads an album again when its photos' order changed, and reads itself again on a partner change. An album made in Manage albums now also reaches the shelves, and one deleted there leaves them.
  - `ShelfCatalog` (Sources/Library) builds the rows from what the server offers, the people and albums in the owner's order and what the feed shows (`ShelfSelection`). Rows carry a typed `ShelfAction` (open a group, show a `LibraryCollection`, the Earth, a screen, a question) instead of a closure; LibraryView performs them exactly as the closures did. `LibraryCollection` names a person, an album and More's eight collections, with their row IDs, titles, symbols, how the feed shows each and when the shelves mark it. Rows and IDs are pinned by ShelfCatalogTests; the shelf geometry tests are unchanged.
  - Leaving an album from Sharing closes Sharing; the feed and the shelves hear of it from the bus. The name typed for an album made from the selection clears once it is made.
  - `AccountSettingsService` (the critic's correction, C7 or N4) makes the account's name, password, Locked Folder PIN and profile photo changes, with the same read-only refusal and ownership (`OwnedRequests`, shared with CollectionsService). The PIN kept on this phone for biometric unlock is still LockedPINStore's, called where it was.
  - The UI fixture gives mutable sessions an album someone else shared with the fixture's user, answers an album's details (owner first, as Immich does) and lets the session leave it; every other token's answers are unchanged. `--ui-testing-fixture-port` (Debug only, set from `TEST_RUNNER_ILYICH_FIXTURE_PORT`) points a UI test run at a fixture of its own, so a fixture change can be tried without restarting the shared one.
  - Tests: BusTests (the order every subscriber hears a mutation, its follow-up sync and a rename in; folding and closing; the feed, its results, the viewer and the shelves following the bus), CollectionsStoreTests (in place and over a load on its way, the rename acceptance, one call per change and read-only, albums a mutation changed), testDeletingOrLeavingTheFilteredAlbumClearsTheFilter and testAPartnerChangeReadsTheFeedAgain, ShelfCatalogTests, AccountSettingsServiceTests, and UI testLeavingASharedAlbumClosesSharingAndClearsTheFilter and testRenamingAnAlbumShowsOnTheShelfAtOnce, which skip until the shared fixture runs this build's script.

### N5 — Locked Folder session

- **Workstreams:** 8, 9. **Depends on:** N3. **Risk:** high.
- **Scope:** LockedFolderSession handles unlock by PIN, password or biometrics (LockedPINStore unchanged), the expiry timer, and relock on background or disappear through owned scene events. Paging is generation-fenced. Relock bumps privateEpoch and purges private media. The locked viewer source never touches library caches. Move to Timeline reconciles the feed.
- **Migration:** None. The PIN Keychain item is unchanged.
- **Tests:**
  - testBackgroundRelocksSynchronouslyAndPurgesPrivateMedia
  - testLateResultAfterRelockDropped
- **Acceptance:**
  - On the phone: PIN and biometric unlock work; relocked after backgrounding; locked photos never reach the feed or widget
- **As built:**
  - `LockedFolderSession` (Sources/Features/LockedFolderSession.swift, main actor, observable) is one per account: AccountSession makes it with the runtime, ends it with the account and puts it in the environment, as it does Free up space. LockedFolderView only renders it and sends it commands. It holds the phase (locked, unlocking, unlocked), how the server says the folder unlocks, what is typed, the folder's photos (the `AssetList` its viewer pages through), the photo open in the viewer and the failure shown.
  - Unlock by PIN, or by the PIN kept behind biometrics, read from the Keychain off the main actor as before; with no PIN set, the PIN typed is set first and then unlocks. `LockedPINStore` moved into the session's file unchanged (service, account, accessibility, biometry), and now saves off the main actor too; a test pins the item's service and account. A failed unlock shows the server's words ("Wrong PIN code") where it gave any, rather than "HTTP 400". A PIN that can't be kept for biometrics leaves the folder open with the message that says the PIN still works; before, the folder relocked.
  - No unlock by the account's password (review fix). Immich's `auth/session/unlock` reads only the PIN (server/src/services/auth.service.ts, `unlockSession`) and answers a password with 400 "Either password or pinCode is required", so the form's "Use account password" never worked, before N5 either; it is gone. The password still changes or resets the PIN in Settings > Locked folder PIN (PINSettingsView), which the server accepts. The scope's "unlock by PIN, password or biometrics" doesn't fit Immich.
  - Relocking is synchronous: the Lock button, the screen going away (its own onDisappear), the server's elevation running out (the expiry timer, from pinExpiresAt, else expiresAt), and the app going to the background. The last comes through AccountSession.sceneChanged, which hands every scene change to the folder before anything else hears it, so the folder relocks whatever is on screen, its viewer included. By the time the call returns, the photos are gone, the viewer is closed, what was typed is cleared, the private epoch has moved and the pipeline holds no locked image; only telling the server (`auth/session/lock`) waits, under a background task assertion when the app is leaving. While the app is only inactive (the app switcher), the grid is hidden as before, not relocked.
  - Server locks (review fixes): an unlock waits for the locks asked for before it, so a lock held up by the network can't land after it and lock the folder again under it; the old screen kept Unlock disabled until its lock came back. A lock the server may not have heard, because it failed or because `auth/status` says the session is elevated while the folder is locked here (as after the app was killed with the folder open), is asked for again when the folder's screen appears or goes and when the app comes back or leaves: one request each time, never while a lock is on its way. Immich extends an elevation while requests keep coming, so a lost lock could otherwise last.
  - The private epoch (C6's contract) now moves: `AuthorizationState.setLockedFolderUnlocked` gives each unlock and relock a new one from the shared counter and sets `lockedFolderUnlocked`; the access epoch, the write generation and the App Group mirror don't move, so an unlock or relock discards no library read or write (the critic's correction). Ending the session locks the folder too.
  - Fencing: an unlock is sent under the private epoch of the moment and is never cancelled; one answering after a relock doesn't open the folder, and the server is told to lock again after it, unless a newer unlock is under way. The folder's months are read under the epoch it opened with, and a relock cancels the read; whatever lands later is dropped.
  - Private media: `MediaPipeline` keeps locked photos' images in a memory of their own (`PrivateMediaMemory`), behind one lock that a relock empties from any thread (`purgePrivateMedia`); before, they sat in the shared preview cache and a relock removed them later on the pipeline's actor. A locked photo's media is refused unless the account's Locked Folder is unlocked (`allows(.lockedMedia)`), and a download is kept only if the ticket it was asked under is still current when it lands. As before it goes over the session that keeps nothing, never through the thumbnail scheduler, its caches, the disk store or the URL cache, and T2's binder still skips locked photos. Rows read from the folder are marked locked whatever they say, so none can take the library's path.
  - Paging: no Load more button (the owner's decision). Months are read until the grid has 60 photos, then the next month once one of the last 30 comes on screen (`SelectableFeatureAssetGrid.onAssetAppear`); the newest month replaces what was shown and the rest are added, so a photo moved out meanwhile stays out. What is shown, the months it came from and what is left to read change together (review fix), so a read again that fails part-way leaves them in step: what was shown stays until the newest month arrives, and the grid reads on from where the read stopped, never a month twice. A read that a newer one replaced shows nothing it read.
  - The locked viewer source never touches library caches: `.locked` reads its photos from the server alone (`APIClient.serverAsset`) wherever the viewer reads one (`ViewerModel.readAsset`): the photo on screen, and, since the review, its Info, the editor's check, its tags and its faces. It never takes the offline library's fallback, whose row may not know yet that a photo was locked. Its records and losses stay in the folder's list. A loss has the session read the folder again, or relock when the server's elevation has ended (`AssetList.onLoss`).
  - Move to Timeline: the session follows the account's mutations itself, so a photo moved out or put in Trash leaves the folder in place whichever screen moved it. The feed reconciles through N2's paths: the follow-up sync names the photo and the feed reads its month again; without an offline library the feed reads its months again. testMovingAPhotoToTheTimelineReconcilesTheFeed pins both.
  - UI fixture (scripts/ui-fixture-server.py, backward compatible; the integrator restarts it): a Locked Folder with PIN 123456 (only the PIN unlocks, as in Immich), elevation per token, and the locked timeline, rows and details served only to an elevated token. Every other request answers byte for byte as before (121 requests compared, a mutable session's included). Until the restart, testLockedFolderViewerMenuOffersOnlyPermittedActions (W1) and the new testLockedFolderRelocksWhenTheAppGoesToTheBackground skip; both passed against a private copy of the new fixture.
  - Tests: LockedFolderSessionTests (the two named tests, which fail with the purge or the late-unlock fence removed; the elevation running out; PIN setup and a wrong PIN; an unlock waiting for the lock before it; a lock the server may not have heard asked for again; paging as the grid scrolls; reads again that fail part-way; the folder's viewer never reading the offline library; mutations followed in place; AccountSession handing the background to the folder; the PIN item; the feed reconciling a photo moved out), AuthorizationTests.testTheLockedFolderMovesOnlyThePrivateEpoch, and the UI test above.
  - Left as they were: PINSettingsView (the critic's AccountSettingsService is C7's or N4's), and the viewer's actions for locked photos (Share, Download original and Save to Photos stay; an open owner question).

### B9 — Cutover: one durable transfer engine

- **Workstreams:** 2, 3. **Depends on:** B3, B4, B6, B7, B8, P4, P5. **Risk:** critical.
- **Scope:** AccountRuntime owns the store, engine, worker and notifier. The app delegate registers BG tasks synchronously and boots in the order of architecture section 4; events are acked after commit. BackupStore and ShareInboxModel move onto the engine. ReceiptRepository becomes SQL-backed for cleanup and the device index. Deleted: BackupCoordinator, BackgroundUploads, BackupAttempt, BackupLifecycle's process, ProcessingWindow, polling and timer, the ShareInboxStore loop, prepareForBackgroundBackup, LegacyCoordinatorBackend and LegacyStateReceipts. scripts/check-single-engine.sh fails the build if an old symbol survives or a second background-configuration call site exists.
- **Migration:** Authoritative import per BM1 to BM8:
- one transaction, then reconcile adopts legacy tasks and outcomes;
- after a clean reconcile, state.json is renamed state.json.imported;
- a later digest is merged;
- an unreadable file is quarantined.
- **Tests:**
  - BACKUP-1 and BACKUP-2 unwrapped
  - BootTests with a fake OS: success outcome finalizes without POST; in-flight legacy task adopted; importing twice is a no-op; crash between commit and rename; a reinstalled old build's state merges
  - All B1 to B7 suites wired
- **Acceptance:**
  - Device migration gate, owner present:
1. On the old build, back up 50 or more items including a large video and force-quit mid-upload.
2. Install this build.
3. Import counts equal the pre-install counts; the video is adopted with no duplicate on the server; the queue resumes.
4. Airplane mode waits, then resumes. Read-only blocks.
5. With the phone locked for 10 minutes, uploads progress.
6. The share batch uploads. Free up space lists the same candidates.
- **As built:**
  - The way back stays, so B9 deletes nothing of today's backup (deviation, by the integrator's brief): BackupCoordinator, BackgroundUploads, BackupLifecycle, the ShareInboxStore upload loop, LegacyCoordinatorBackend, LegacyStateReceipts and LegacyBackupIndexInputs remain until B10, and run only when an account's import fails. `TransferHost` (main, device scope) picks one engine per process, since iOS allows one session per background identifier and one launch handler per task identifier: the first account activated decides and the choice holds until the app ends. An account whose records the transfer engine owns never runs on today's backup (its state.json stopped at the cutover), and one the process's engine can't run waits for the next launch: the screens say "Quit and reopen Ilyich to back up this account.", and today's backup can take up only the account it was chosen for (`BackupCoordinator.takesUp`). Diagnostics shows the engine and, on the way back or while an account waits, why ("Backup records" section).
  - Launch order (architecture section 4): didFinishLaunching registers both task identifiers at once through `BackgroundTaskRouter`, which holds a task until an engine takes it (and restores the account for it). A background session's completion that comes before the choice is held too and answered at iOS's 20 s deadline if nothing is chosen; a session is never made before the choice. Choosing the engine creates TransportRegistry (both sessions connected), BackgroundEventAcks and LifecycleEventSource with SystemLifecycleInputs and Photos changes, and routes their events to the account's runtime; drains that come first are kept for it.
  - `AccountRuntime` owns the import, its decision (`TransferCutoverState`) and the account's `TransferRuntime`: store, engine (concurrency from the library pipeline), LaneJobExecutor over the library and share executors with TransportPartUploader/TransportOutcomes, Recovery, PostUploadWorker (the engine's followUp), TransferNotifier (system poster) and TransferLifecycle over `EngineWindowWork`. Start: leases released, reconcile (adopting legacy tasks by stage ID, applying outcome files: BM5, BM6), `replayConsumed`, engine start, notifier, lifecycle, and a first automatic search in front. Every finished task and drain reconciles (coalesced, one pass at a time); a drain is acknowledged only by a pass that began after it (BM11).
  - Import: authoritative, once per runtime, when the account's backup starts (`prepareTransfers`), never on writes or on coming forward. state.json stays in place (critic's correction): a later digest, which only a reinstalled older build writes, is merged (`TransferStore.mergeLegacy`: receipts and confirmations it added, newer receipts, its queue, album adds and links; a job settles only for a photo it confirmed at a newer revision than the database had, and an album add whose photo has a job waits for that upload; the database's preferences, intent and stages win, since nothing says which side changed the preferences later) and reported as merged. An unreadable file is quarantined and the engine takes the database as it is: the B1 shadow copy keeps the last readable state's receipts. After the import, committed cleanup deletions of the account in the device journal set `receipts.local_deleted_at` where the revision still matches. Diagnostics' compare shows the comparison made at the import.
  - Run intent (deviation from the critic's mapping): automatic backup on imports as automatic whether or not state.json says paused, because today's backup marks itself paused after every run and restarts while automatic is on; mapping that to paused would stop automatic backup at the cutover. Off: a run under way is manual, else paused. Legacy outcomes are classified only by receipt and status (B6), and stages without a checksum hash once (B6's R1/R3).
  - Owner decisions applied: a manual run (Back up now, Retry, Back up selected while paused) asks for the background windows even with automatic backup off, and ends when nothing is left, back to automatic or paused, also when recovery commits its last photo after a relaunch; sign-out switches automatic off, pauses, cancels the account's tasks with iOS and keeps transfers.sqlite and the staged copies (no `StagingArea.removeAll`). Read-only on blocks the engine and does what the toggle always did, saved with the block: backup pauses with automatic backup off, and shared uploads stop (their jobs go, their files stay). Off lifts only the block, so nothing resumes and the user's own uploads are taken again.
  - The screens: `BackupStore.shared` and the Shared files sheet run on `BackupBackendRouter`, which reaches today's backup only when the process runs it (BM9): while the account's backup is prepared (the import, the engine's start) commands wait and reads find nothing; a preference edit is written only once the screen has read the preferences of the backup in use, so one made on the placeholder never overwrites the imported ones; with no backup running, commands are refused. The engine's snapshots carry iOS's refusal to schedule automatic backup, as BackupLifecycle's was shown. EngineBackend keeps each button's meaning (Pause also switches automatic off; Back up now discovers and runs; switching Automatic on starts it, off lets a run finish), counts failed photos in Remaining and lists them, and only them, in the queue and the retry list as today (Retry failed uploads retries photos; a shared file is retried from its sheet), lets Back up selected and a share's Upload retry a file that failed, and words the status line from the engine's phase. Confirmed uploads keep today's order (receipt time for imported confirmations). The Shared files sheet reads the share lane (queue, current file, progress, per-file errors from its failed jobs) from the engine; a file Pause upload or read-only mode stopped doesn't count as uploaded. Discovery's new jobs count in a backup notification batch, as each of today's runs posted one.
  - Device conditions: LibraryJobExecutor checks Require charging and temperature before each photo, as BackupCoordinator did, and the engine waits engine-wide until a condition changes.
  - Cleanup and the device index read receipts through `CutoverReceipts`: SQL over the transfers database (`TransferReceiptSource`, which also records verified sizes and local deletions) once the engine runs, else today's state; they wait for the account's decision. CleanupRemovalGate stays closed.
  - check-single-engine.sh: BackgroundUploads may be named only in the old engine's own files and TransferHost; the transport, lifecycle and follow-up types only in Sources/Transfers (TransferHost and TransferRuntime).
  - Tests: BootTests (a golden state.json at scale, 6,000 receipts pinned by digest: zero jobs, checks, stagings or uploads for confirmed photos and the screens read as today's; in-flight legacy task adopted and its drain acknowledged after commit; success outcome finalizes without POST; import twice and an end after commit are no-ops with state.json kept; a reinstalled old build's state merges; cleanup deletions marked; manual run windows; sign-out keeps staged copies), TransferHostTests (one engine per process, held events and tasks), BackupBackendRouterTests (commands wait for the account's engine and never reach today's backup meanwhile; iOS's refusal shown; an account the engine owns never runs on today's backup; paused shared files don't count as uploaded), KnownBugLedger BACKUP-1 and BACKUP-2 pinned on the engine. B1 to B7 suites run unchanged except the plan and retry expectations the owner decisions change.

### T5 — Coverage worker keeps the library offline

- **Workstreams:** 7. **Depends on:** T2, Q3, Q6. **Risk:** low.
- **Scope:** CoverageWorker pages asset_index by keyset on the aggregate reader and diffs against the presence map. coverage_cursor and coverage_mark persist. After a sync it rechecks only changed IDs; a full pass runs only after a reset or overflow. Policy lives in UserDefaults thumbnails.coverage.v1, defaulting to today: owner timeline, unmetered only, paused in Low Power, at serious thermal state, while the viewer is open, and for 1.5 s after motion. Diagnostics progress comes from the index. ThumbnailWarmer and its adapter are deleted.
- **Migration:** coverage_mark = 0 forces one verification pass; present files are never refetched.
- **Tests:**
  - testCoverageResumesAndRechecksOnlyChangedAssets
  - testCoverageHoldsWhileScrubbingOrViewing
  - testMeteredPathPausesCoverage
- **Acceptance:**
  - On the phone, a relaunch after a full pass makes zero coverage requests and Diagnostics stored equals total
- **As built:**
  - CoverageWorker (Core/CoverageWorker.swift) replaces ThumbnailWarmer and MediaPipeline.storeThumbnail, the warmer's coverage-band adapter. It is one of the account's LibraryServices, started by AccountRuntime.start 8 s after the account opens and stopped first in cancelAndJoin; once its session ends it never starts. It pages asset_index on the index's aggregate reader by keyset in the library's order (month and time taken newest first, then ID), 500 rows a page, and checks each row against the thumbnail store's presence map; the page is chosen on asset_index alone, as a co-routine over asset_index_taken without sorting, and only then joined (CROSS JOIN, so the page stays the outer loop) with each photo's entity for its revision, since joined first SQLite, which has no statistics for the index, walked every asset and sorted them for every page; only missing files are asked of ThumbnailScheduler.store on the coverage band (at most 2 of the 6 download slots, and only while fewer than 2 downloads run at all), two at a time. Present files are never fetched again. SyncEngine no longer knows the warmer: the worker subscribes to the account's changes itself.
  - Scope: the account's own timeline (owner_id, visibility timeline, not trashed). Partners, archived, trashed and locked photos are left out, as the owner question stands; a test pins each.
  - Position and mark: coverage_cursor (the keyset position as JSON), coverage_mark, policy_hash, coverage_total and coverage_stored live in the thumbnail index's meta table (ThumbnailDiskStore.coverageState), beside the files they describe, so sign-out and Clear browsing cache clear them with the files. The cursor is saved after each page and counts are committed per page, so a kill resumes after the last page saved and a page worked twice is never counted twice. The mark is the index's persisted index_state.revision (the writer's in-memory count starts at zero each launch) as it was when the pass began, which coverage_pass_mark carries beside the cursor, kept once the pass has walked the whole library: what changed during the pass is named by a change in memory, or, after a kill lost that memory, found at the next launch as a mark behind the index, which costs one verification pass that fetches no present file. A relaunch where the mark still matches makes no request and shows the saved counts. A download that failed clears coverage_pass_mark with the position, so the pass ends unverified in this launch or a later one and the next pass asks for the photo again. Saves go through the store's MediaFence (saveCoverageState refuses a token from before a clear), so Clear browsing cache in the middle of a pass never lands a position or counts in the emptied store: the pass ends and the next starts from the newest photo with fresh counts. The roadmap's "coverage_mark = 0 forces one verification pass" is a missing mark here, since index_state.revision can legitimately be 0 on an empty library; every phone before T5 has no mark and verifies once without fetching present files.
  - Rechecks: while the account is open each LibraryChange names the photos checked again (upserted and mediaRevisions, minus removed and accessLost), read through coverageRevisions, which answers only for photos still in the covered set. A reset, an overflowed change, or more than 20,000 names waiting asks for a whole pass. A change naming no photo (an album, a person) still moves the mark through an empty recheck, since it moves the index's revision too and would otherwise cost a whole pass at the next launch; the count is read again only when photos came or went. After a recheck the mark moves to the revision read before it, unless further changes already wait or a download in it failed: the photos that failed wait to be checked again and the mark stays where it was, so a kill meanwhile finds the index past it. A changed policy fingerprint (today only the scope) forces one verification pass.
  - Conditions (CoverageConditions, written by whoever knows): NWPathMonitor (unmetered only; expensive and Low Data Mode pause), Low Power Mode and the thermal state (serious and critical pause) from ProcessInfo, the app in front (AccountSession.sceneChanged), a photo open (LibraryView, navigator.isViewing) and the grid moving (TimelinePosition.onMotionChange, set by the grid's scroll delegate and the rail), with a hold of 1.5 s after motion ends. A download starts only when nothing holds; the at most two in flight finish. The worker also waits at 95 % of the store's cap rather than filling what the trim would evict, and after three failed downloads in a row lets what is in flight end and leaves the server alone for a minute (a hold of its own, which a change of conditions does not cut short); the photos that failed are not retried in that pass, so the counts stay honest; a pass or recheck in which a download failed leaves the library unverified, and after a pause that doubles with every failing round (a minute, then two, up to sixteen) they are asked for again. All of it is event-driven: no polling while held, and the board hears only of progress that changed.
  - Policy: CoveragePolicy in UserDefaults thumbnails.coverage.v1 (scope, unmeteredOnly, pausesInLowPowerMode, pausesWhenHot, pausesWhileViewing, motionHold), missing or unreadable means today's behavior; nothing in the app writes it yet.
  - Diagnostics' "Thumbnails kept offline" reads CoverageBoard, which the worker fills from the index: the count of covered photos and how many of them the presence map held or the pass fetched. The perf summary's warmerRunningShare keeps its name and now samples the worker.
  - Tests: CoverageWorkerTests (resume and recheck, reset, holds while viewing or moving, metered and Low Data paths, Low Power, heat and background, the disk budget, the failure pause, an ended session, an incomplete library, the policy's defaults and holds). FencingTests' warmer cases moved there.

### T6 — Phone photos and feature tiles through the thumbnail service

- **Workstreams:** 7. **Depends on:** T2, P3, P5. **Risk:** medium.
- **Scope:** DeviceThumbnailSource preheats through the shared PHCachingImageManager by diffing windows at the cell's pixel size, stopping on density change, memory warning and background. Cells take PHAssets from the device snapshot, with no main-thread fetch. Feature tiles, the lens, globe markers and the viewer placeholder use service.request with the revision from the index, so there is no GET assets/{id} round trip; the globe's private cache is deleted.
- **Migration:** None.
- **Tests:**
  - testPreheatFollowsTheWindowByDiff
  - testRequestsUseCellPixelSize
  - testNoAssetFetchBeforeThumbnailWhenIndexHasRevision
- **Acceptance:**
  - On the phone, a merged-library scrub across phone-only months stays under 5 ms/s hitch ratio; device-source p95 recorded
- **As built:**
  - Phone-only photos are grid photos like any other: `PhotoCell` binds them through `ThumbnailBinder` (`bind(_:toDevice:)`) under `ThumbnailKey.device(id, modified)`, which the caches and deliveries file as `device:<localID>` with the modification date, bit for bit, as the revision; the grid's demand carries them on the visible and ahead bands like server photos. `ThumbnailScheduler` renders a device key on its decode lanes through a `DeviceThumbnailProviding` source instead of reading a file: a synchronous `requestImage` at the cell's pixel size, aspect-fill, high quality, never from iCloud, on the app's one `PHCachingImageManager` (`PhotoKitAdapter.thumbnails`, Sources/Device, where check-single-engine's rule 6 keeps every fetch and image request). The result goes into `DecodedThumbnailCache` and to the cells in the same batched main-thread hop as server thumbnails; one Photos has only in iCloud, or no longer has, delivers nothing and the cell shows the iCloud or unavailable symbol as before and keeps it through a density change until Photos is asked again (the binder keeps a failed stage like a photo it shows; a phone photo has no sketch to fall back on), and the grid waits before asking Photos for it again, twice as long after each failure, in the fetcher's one backoff table (a failed cell is in every demand the grid sends while it scrolls; without the wait each demand cost Photos a futile render per such photo on the decode lanes), and such a photo is left out of the preheat window meanwhile. The per-cell `PhotoKitAdapter.media` stream, its Task and `UIImageView` are gone from the grid; the cell draws the rendered bitmap into its layer, turned upright off the main thread in the rare case Photos hands one over on its side.
  - `DeviceThumbnailSource` (Core) keeps Photos' caching manager one window ahead: the scheduler hands it the union of what every grid wants of the phone that memory lacks, at the largest cell, after each mailbox read; the source diffs it against the window before on a serial queue of its own (latest window wins), starting only the photos that came in and stopping only those that left, and fetching the PHAssets of newcomers in one batch off the main thread. A new cell size stops everything and starts the window over at the new size; a memory warning or the background stops everything and nothing is cached again until the app is forward and a grid says what it wants; sign-out stops it. A stop is a step of the source's own work, ahead of any window asked for after it: a window already queued is started and stopped with the rest, and the window the grid asks for after the warning starts after the stop, from nothing, instead of being wiped by it and lost until the grid scrolls again. The roadmap placed it on the main actor; it runs off it, as rule 0 asks of PhotoKit work.
  - The index already held no PHAssets ("cells take PHAssets from the device snapshot"): keeping 60k of them in memory for the merged library was not worth it, so the imaging layer keeps only the PHAssets of the window Photos is caching (a few hundred), looked up once per batch, and a request for a photo in the window fetches nothing. A request for one outside it, as after a fast scrub, fetches that one asset on the lane, off the main thread, as `media()` did per cell before.
  - Feature tiles (`FeatureThumbnail`: album covers, places, memories, the filter tag) and the globe's markers call `MediaPipeline.thumbnail(assetID:shortSide:fetch:)`: the offline library names the photo with its revision (`LibraryIndex.asset(id:)` on the viewport reader, wired by the runtime), so the thumbnail comes from memory, the disk or the server's thumbnail endpoint with no GET assets/{id}; only a photo the library lacks is fetched first. Tiles and the rail's lens (`FeatureAssetImage`) decode at their own pixel size (`tilePixels`: the tile's long side in pixels, since a photo of unknown shape aspect-fills it, and no less than the grid's 128), where they asked for 600, 500 and 120 before; the tiles are square but for the shelf row's cover, so a tile shares one decoded copy with the grid. A tile asks for its size in doubling steps that never fall (`tileRequest`) and names its photo once per cover (`MediaPipeline.namedAsset`), so a shelf row's cover, whose frame follows the finger from 64 to 244 points, asks three times on the way up and never on the way back instead of on every frame of the wave with an index lookup each; the image a tile shows is of the photo it names (`FeatureTileImage`): a new cover replaces the old one at once, with its copy in memory or nothing, and a failure shows only while nothing of the photo shows. The globe's private marker cache is deleted; `DecodedThumbnailCache` keeps them, and a marker seen before draws in its first frame from it.
  - The viewer's placeholder keeps opening on the preview or grid thumbnail in memory (T1 kept DESIGN 13); when memory has neither, as for a photo opened from a link, a memory or search, the stored grid thumbnail now stands in from disk through the service while the preview loads, and the grid finds that decode in memory afterwards; not while the filmstrip is scrubbed, when a page keeps to what memory has, as the view promises.
  - `ThumbSource.device` joins the perf sources ("device"), in `summarize.py` too, so the acceptance's device-source p95 can be read off a phone recording. Not done here: On this phone (`LocalPhotoThumbnail`, P3) still streams per cell through `PhotoKitAdapter.media`; it has no pipeline at hand and its grid is a SwiftUI `LazyVGrid`, so it was left as P3 built it.

### F6 — LibraryFeedStore replaces LibraryStore

- **Workstreams:** 6. **Depends on:** F4, F5, T4, N1. **Risk:** medium.
- **Scope:** LibraryFeedStore (displayed snapshot, replacing state, scope, title, verification, errors, scroll request, restore anchor, places, and the commands) and FeedSelection, which selects months through the feed. Delete LibraryStore and the section-to-MonthKey mapping. SimilarPhotos follows the owner decision.
- **Migration:** None.
- **Tests:**
  - Every store test ported with unchanged names and assertions
  - Selection tests
- **Acceptance:**
  - Unit and UI suites pass
  - Device scenarios are no worse than T4
- **As built:**
  - `LibraryFeedStore` (Sources/Library/LibraryFeedStore.swift, LibraryStore.swift renamed with its history) replaces LibraryStore and holds what the scope lists: what the grid displays, a new scope loading behind it, the scope and its title, the search's verification, the errors, the scroll request, the anchor to restore, the feeds' places and the commands. Its surface is LibraryStore's, so the views, the rail (`TimeRailFeed`), the perf driver and the zoom presenter only changed the type's name (LibraryView's banner reads `failedMonths`), and the entry points N2 builds on, `update(_:)`, `removeLocally(_:)`, `apply(_:)` and `refreshAfterMutation()`, keep their names and signatures. The viewer's actions, BulkActionsView, Duplicates and Trash are untouched.
  - The section-to-MonthKey mapping is gone (`monthKeys`, `monthBuckets`, `monthKeyByBucket`, `bucketOfMonth`; section 9). Each grid section carries its month (`LibrarySection.month`), and the store keys what the feed delivers by MonthKey, as TimelineFeed does: the server's rows (`rows`), the failed months (`failedMonths`, the banner), the projections, the deliveries waiting for theirs and the months to project again. A summary's months are read from its buckets once, when it arrives (`SummaryMonth`); a sync's summary re-reads none it already had, `MonthKey(bucketID:)` reads a bucket at midnight UTC (the server's "…T00:00:00Z") without parsing a date, which the deleted memo had saved, and the bucket the source reads each month by goes to the feed with the order, as before. Section IDs, positions and anchors stay the bucket strings the grid always used, so nothing the grid restores moved. Keying by month brought out what bucket IDs had hidden. The index names a month YYYY-MM-01, as the phone names a month only it has, so a month whose last server photo was deleted while the phone kept photos there kept its ID, and its rows and projection, made with the server's photo, outlived it: the deleted photo stayed in the month and the viewer could swipe to it. Now the server's photos of a month it no longer has go with it, and the phone's photos there are projected again. A month the server gains keeps showing the phone's photos until its own rows land, as it did with the index's IDs; a server-routed feed's "…T00:00:00Z" IDs used to blank it meanwhile (FeedMonthKeyTests, under the index's names and under a server-routed feed's).
  - What the grid displays, the feed as it stands or, while a new scope loads behind it, the frozen feed (F4's displayed session), is read through one protocol (`DisplayedFeed`): the rows, assets, days, place summaries, the restored index and the viewer's neighbours, so the frozen and the live paths can no longer differ. One did: the frozen feed's restored index looked a photo up in the server's rows before the projection, so the viewer closing over a frozen merged library could zoom back to the wrong cell; it now reads the projection first, as the live feed did (testClosingTheViewerOverAFrozenMergedLibraryZoomsBackToThePhotosCell). Each accessor still reads only what it needs, so SwiftUI observes what it observed before. The contract's `FeedSnapshot` stays a sketch: the grid's structure and content signals remain `resetID` and `revision`, which the pinned tests assert by name and the grid's reload and anchor logic reads; replacing them would change the grid's update model for nothing the owner sees. They do its counters' work: the grid reloads when its sections change, restores its anchor when `resetID` moves as well (a phone publish moves it only when it changed a month's count or rows the grid holds, F3), and only reconfigures its cells when `revision` alone moves. Not built is the rest of F3's clause, a phone publish moving the structure of only the months it touches: such a publish still reloads the whole grid (`reloadData`: one layout pass over the months, the visible cells bound again from memory) and sets the grid's offset back to its anchor, which ends a fling under way. T7 owns it (see its scope).
  - `FeedSelection` (Sources/Library/FeedSelection.swift, main actor, observable) holds what is selected and each photo's record, the phone copies beside them, and the month being read, and selects months through the feed: the store hands it a reader that takes the month under the viewport from the TimelineFeed, resident or joined on its way, and merges the phone's photos off the main actor, answering nil once the feed has moved on. Leaving selection, a sync's reload, a scope change or `stop()` drops the month on its way; a failure shows in the banner while the feed is the one it was read from. The store owns it and clears it with the scope, and keeps the selection's members it had (`selected`, `isSelecting`, `isSelectingGroup`, `selectedAssets`, `selectMonth`, …) as one-line forwards, so the grid's drag, the selection bar and N2's code use them as before. `selectedAssets` now reads the feed's rows only for a photo selected by ID alone, with no record; reading them every time made LibraryView's body run again for every month that landed while selecting.
  - Fewer redraws, nothing else changed: a month that lands clears its error only when it had one (LibraryView's body ran again for every month delivered), and the month-selection flag is set only when it changes (every sync's reload redrew the selection title).
  - SimilarPhotos keeps its own feed store and grid, as before: no owner decision is recorded (the question stands under "Open questions for the owner").
  - Tests: every store test is ported with unchanged names and assertions. LibraryStoreTests is LibraryFeedStoreTests, and it and the other suites that drive the store (FeedSessionTests, TimelineFeedTests, ScrubbingTests, KnownBugLedger, FeedTests, SearchFeedTests, SearchChoicesTests, LibraryRepositoryTests) differ from the base only by the type's name (SearchFeedTests by a comment too, FeedSessionTests by one new test, below); Tests/Support/FeedStoreViews.swift reads the store's months by section ID (`loaded`, `bucketErrors`, `visibleBucketIDs`) as the tests always named them. The rewrites the critic listed were made before F6: the place-key test in Q5 (testAPlaceKeepsItsOwnCachesAndTheServerNeverSeesIt, on `LibraryQuery.stableKey`), the two TimelineCache tests in F2 (testCachedTimelineShowsItsMonthBeforeNetworkRefreshFinishes deleted by design, testBackgroundRefreshKeepsLiveRowsAndDoesNotReplayOlderDiskSnapshot now testBackgroundRefreshKeepsLiveRowsUntilTheirMonthsAreReadAgain), and F4 kept testFailedReplacementRetainsOldFeedAndClearRestoresIt as it was. New: FeedSelectionTests (records and their phone copies, a photo selected by ID found among the rows, a drag step, a month selected and deselected whole, leaving selection or the feed moving on mid-read, a failed read, one month at a time, and through the store a month joined on its way and a reload dropping one); FeedMonthKeyTests (a month the server lost, and one it gained, both under the index's names and under a server-routed feed's, where the gained month's section changes its ID); in FeedSessionTests, testClosingTheViewerOverAFrozenMergedLibraryZoomsBackToThePhotosCell (the restored index of a frozen merged library, read from the projection); two MonthKeyTests assertions for the midnight forms; and the UI test testSelectingTheMonthSelectsEveryPhotoOfItNotOnlyThoseOnScreen, as no UI test selected a month before.

### N6 — Stackable filters and filter pills (owner request, 2026-10-20)

- **Workstreams:** 6, 8. **Depends on:** Q5, F5, N4, F6. **Risk:** medium.
- **Scope:**
  - **Filters stack.** Choosing a filter adds a layer instead of replacing the current one. Locations, people, albums and the More categories (favorites, Lightroom, videos and the rest) combine with AND, so a location plus a person shows that person's photos in that location.
  - **Shelves narrow to the stack.** With a location chosen, People lists only the people in that location's photos. Albums and the Earth's places narrow the same way, counted from the index.
  - **Pills.** The single filter shelf with its round X becomes a row of pills at the top, one per layer. Each pill has a small X that removes only its layer.
  - **The rise stays.** Choosing a row keeps today's choreography of the chosen shelf rising, but it lands in the next pill's position and morphs into the pill.
  - **Clear.** A Clear row at the top of the shelves, above People, removes every filter and closes the Earth if it is open.
- **Migration:** None.
- **Tests:**
  - Stack algebra: adding, removing a middle layer, clearing
  - People, album and place counts under a stack, from the index
  - The server plan for combinations the server can serve, and the stated index-only limitation for the rest
  - UI: a place then a person shows the intersection; removing one pill keeps the others; Clear empties the stack and closes the Earth; the rise lands on and morphs into its pill (checked on recorded frames)
- **Acceptance:**
  - On the phone: a location plus a person shows only that person's photos there; People under a location lists only people in it; each pill's X removes only its layer; Clear resets everything; the morph lands on the pill
- **As built:**
  - `FilterStack` (Sources/Library/FilterStack.swift, pure) holds the filters in the order chosen: `FilterLayer` is a person, an album or one of More's eight collections (`LibraryCollection`, so a layer's ID is its shelf row's), or a place. They combine by AND into one LibraryQuery: people and albums each a set (two people show the photos with both), a place, Recently taken and added keeping to the account's own photos, favorites, Lightroom, Videos (kind), Motion, Archive and Trash. Visibilities intersect, so Archive with Trash is the trashed archive. Recently added orders by the date added; one album alone keeps its own order. A layer alone is exactly the feed its row showed before (pinned), and is searched as before: a person, an album or a place in the timeline and the archive, a More collection in its own scope. A layer already there stays; a new place takes the place of the one there, since two places show nothing (Q4's note).
  - LibraryFeedStore keeps the stack (`stack`), with `add` (the shelves, the Earth, Browse more, Manage people and Manage albums), `remove` (a pill's X) and `clearFilters` (Clear, and the last pill's X, which brings the library back where it was left). Show in timeline (a memory's, the viewer's) leaves every layer too, as Clear does. Choosing a filter ends a search typed, as it always did; removing a pill keeps the search, or More's filtered view, and runs it again in what is left (with no layer left, in the library). `setPerson`, `setAlbum`, `setPlace` and `setFeed` show one layer alone, as links and the viewer's person and album ask. A partner's feed, More's filtered library and a search filter given whole are no layer: they replace the stack and give way to the first layer chosen after. An album deleted or left goes from a stack alone (alone, the filter clears as in N4); a rename names its layer anew.
  - Planner: the index lays out by month every stack of the shelves' facets once it is readable: any owner, any albums and people, a place, favorite, developed, a kind and motion (`IndexFeedRequest` lists albums and people; a kind and motion are looked up on the photo's own record by key, never by scanning). Without it, the server timeline serves what it did (one owner, album or person, with favorites and Lightroom), search serves the rest as one list, and Recently added stacked with a person, an album, a place, a kind or motion is index-only: search can't order it and the timeline can't filter it, so the planner says `QueryPlanner.needsIndex` and throws `Unsupported.needsIndex` ("These filters can be shown together once the offline library has synced."). With the index readable, Videos and Motion alone are now laid out by month with the rail too.
  - Partners stay out (QUERY-1 still wrapped). Every stack keeps to the library's owner rule: a person in the library still takes the albums shared with the account, as the server's person timeline does, but with an owner named (Recently taken or added) keeps to the account's photos. A place alone is still the map's photos there, whoever's they are, as it always was; stacked with any other filter it keeps to the library's photos as they do (`IndexFeedRequest.placeAlone`), so a partner's favorite in a place never comes in with Favorites, and the Earth's counts match the feed. Search reaches the partners shown in the timeline as well, so before the index is readable a stacked feed only search serves keeps on the phone to the same photos (`QueryPlanner.keepsToOwnPhotos`, the owner post-filter with its scan budget): the account's own, but for an album's photos and a place alone's. A search typed, in a stack or not, and More's filtered view reach the partners, as they always have.
  - `ShelfNarrowing` (main actor) counts, from the index's aggregate reader, the people and albums in the stacked feed's photos (`IndexReader.facets`) and the photos the Earth keeps (`feedIDs`, for the stack without its place, so another place stays to choose). The newest stack wins; a sync's change marks the counts stale and they are counted again the next time the shelves open, never on each change, so a backup's stream of changes counts nothing. With no filter, or without a readable index, nothing narrows. The shelves take the counts as they open and as each group opens, never while a level is under the finger, so no row moves beneath it: People and Albums list only those in the stack's photos (a layer chosen always stays listed), an album's row counts the stack's photos it holds, and the top level counts what is listed. The Earth shows only the places holding the stack's photos, each counting them, with its lights; a place chosen is always the whole place. A count again for the same stack that found other photos reaches the Earth as a new revision of its narrowing (`PlaceNarrowing.revision`, compared off the main actor; the same photos leave the Earth as it is). Reordering People or Albums while they are narrowed moves a row among those listed, by ID, and the rows not listed keep their places in the owner's order (`ShelfOrder.moving`).
  - Pills (`FilterPillLabel`, `FilterPillView`, `FilterPillFlow` in Sources/Library/FilterPills.swift) replace the filter tag and its round X: one 44 pt capsule per layer, in the order chosen, wrapping onto a second line rather than hiding one, then a search typed as a pill of its own with its match count. Each has the person's face, the album's cover or the collection's symbol (a pin for a place), the title and a small X that removes only its layer; a tap or a drag on the rest brings back its group of the shelves with its row under the finger, as the tag did. They wear the search chips' cyan glass (F7): an overlay outline under glass in the shared container is lost in the glass's rim, on the chips as on the old tag, so the tint is what reads cyan. A small spinner follows them while the feed changes. Hidden while the shelves are out, glass included; a hidden pill's X leaves the hierarchy. The album share button and uploads show for one album alone.
  - Clear: while filters apply the top level of the shelves starts with a Clear row above People (`ShelfAction.clear`), which removes every filter, ends a search and lowers the Earth.
  - The rise (LibraryView.closeShelves, LibraryShelfFan, LibraryShelfRowLabel): the chosen row still scrolls up level with its target on the softer spring and hands over at 0.6 s, but the target is its pill's place, the next one along the pills (measured on the hidden pill, laid out as soon as the filter applies). On the way the row also slides over to the pill's x (`morphX`), its edge corners round into a capsule, its glass takes on the pill's cyan, and it takes the pill's own layout (`FilterPillLabel`, face first, title following, the X at its end). Changes to the choreography, each for the landing: every filter row rises now, More's collections included (only people and albums did, as only they had a tag); the other pills come back as the rise begins rather than at the hand-off, so the row lands beside them; with several rows chosen, the one under the finger is the one that never activates (`selected` passes it; the interaction is unchanged); a pill opens the shelves with its own row under the finger; and the top level has one more row while filters apply. The 31 geometry tests are unchanged. Checked on a simulator recording at 60 fps (dark): Favorites rising beside Maya's pill arrives already in the pill's layout and glass, settles in place on the spring and is handed over with no jump.
  - UI fixture (scripts/ui-fixture-server.py; the integrator restarts it): Amsterdam on the map holds a photo and the clip, the clip has no faces, and a metadata search naming its photos (a place's feed before the offline library is readable) answers exactly those photos that match its people, kind and favorites. Every other request answers as before; the script takes an optional port for a private copy. Until the restart testAPlaceThenAPersonShowsTheirIntersectionAndAPillRemovesOnlyItsLayer skips; it passed against a private copy.
  - Tests: FilterStackTests (stack algebra: adding, removing a middle layer, clearing; each layer alone; AND; pills; where the next pill lands), StackedFiltersTests (a place then a person and each pill's X, Clear, Show in timeline, a search and More's filtered view kept, an album deleted from a stack, a stack only search serves keeping partners out, the narrowing, a late count for a stack left behind, the Earth counted again), CollectionsStoreTests (a move among the rows a stack lists), StackedFiltersIndexTests (every stack from the index, partners out; people, album and place counts under a stack; a 60,000-photo budget; a kind looked up by key), QueryPlannerTests.testAStackOnlySearchServesKeepsToTheLibrarysPhotos and testTheServerServesWhatItCanAndTheRestIsIndexOnly with the planner table rewritten where the index now serves (videos, motion, two albums or people, a person with an owner, Recently added with a kind), ShelfCatalogTests (Clear, narrowing, several marked), and UI testAPlaceThenAPersonShowsTheirIntersectionAndAPillRemovesOnlyItsLayer, testClearEmptiesTheFiltersAndLowersTheEarth and testAChosenRowRisesIntoTheNextPill; the UI tests that named the tag or "Clear filters" find the pills instead.

### T7 — Scrubbing acceptance gate and scrub-tier decision

- **Workstreams:** 7. **Depends on:** T4, T5, T6, F6. **Risk:** medium.
- **Scope:** Run every deviceMeasurements scenario on the final stack. If disk-hit p95 misses the budget, add a locally transcoded scrub tier (about 3 KB per photo, DecodeTier.scrub, beside the v1 files); otherwise record the decision not to. Publish the numbers in the PARITY build log. A phone publish that changes a month's count, or rows the grid holds, reloads the whole grid and sets its offset back to the anchor, which ends a fling under way (F6 kept `resetID` for FeedSnapshot's structure counter): measure it in background-load and in the owner's free scroll while backups run, and if it hitches or cuts a fling short, reload only the months the publish touched and keep the photo on screen in place without stopping the scroll; otherwise record the decision not to.
- **Migration:** Scrub-tier files only if the tier is added.
- **Tests:**
  - UI testDirectionReversalAndRelaunchShowDecodedOrStoredThumbnails
  - Release performance runs on the phone
- **Acceptance:**
  - Every measurement gate is met, or the owner accepts documented exceptions
- **As built:**
  - Measured on the phone with build 3040086 (PARITY 3040088). Met: rail-sweep, fling and reverse hitches under 5 ms/s with the longest hitch at most 50 ms; behind-band rows after a reversal from memory; rail-sweep disk-hit p95 23 ms; first content p50 395 ms and p95 401 ms; no network fetch for covered months; peak 251 MB and 160 MB two seconds after a trim; zero hangs.
  - Decode lanes follow the phone's cores (`ThumbnailScheduler.lanes(cores:)`, three to five, four on the 15 Pro); a perf run may set them with `-IlyichDecodeLanes`. Rail-random disk-hit p95 went from 74 to 63 ms.
  - Exceptions the owner accepted on 2026-10-23 ("scrubbing and shelves are good"): rail-random disk-hit p95 63 ms against 50, and rail-random and background-load hitches about 20 ms/s against 5 (about two dropped frames per far rail jump). No scrub tier was added. No month-scoped reload for phone publishes: background-load measured no extra cost (the backup queue was idle), so it stays a candidate only if flings stop short during large backups.
  - Not measured over Wi-Fi: the airplane-mode run and Time Profiler's main-thread share.
  - The owner's shelf settings: `glowZoneStart` 0.54 (was 0.46; 3040088, confirmed on the phone), and in 3040089 the areas at the top and bottom of the screen where a long list scrolls, measured from the screen's edge, 60% larger (`scrollAreaGrowth`), the added part at the zone's starting speed so nothing scrolls faster. 3040088's first attempt moved the zone's start only 0.3 rows, about 11% of that area.

### T8 — Grid thumbnails in Application Support (owner decision, 2026-10-29)

- **Workstreams:** 7. **Depends on:** T1, T5. **Risk:** low.
- **Scope:** ThumbnailDiskStore's root moves from Caches to Application Support/IlyichThumbnails, kept out of iCloud backup (isExcludedFromBackup on the root folder, set again whenever found missing). Library/Caches was emptied on the phone around the 3040092 install, and coverage was downloading the whole set again. A one-time move, before the store is first used and off the main thread, renames whatever is in Caches/IlyichThumbnails into the new root, folder by folder. It merges with anything already there without losing a listed file, and the launch comparison adopts what moved; then Caches/IlyichThumbnails goes. A move cut short finishes at the next launch, and nothing that moved is downloaded again. Everything that uses the store or its location follows: coverage (T5), Clear browsing cache and the usage Diagnostics shows, sign-out cleanup. The URL cache and the decoded caches stay where they are. The 1.5 GB cap with least-recently-viewed trimming and the launch comparison stay.
- **Migration:** Caches/IlyichThumbnails/<digest32>/<stem2>/<stem>.<rev16> and its index.sqlite move by rename to the same paths below Application Support. Nothing is copied, rewritten or downloaded.
- **Tests:**
  - testAnEarlierBuildsThumbnailsMoveToApplicationSupportWithTheirIndex
  - testAMoveStoppedAnywhereFinishesAtTheNextLaunch
  - testTheThumbnailFolderStaysOutOfBackups
  - testClearingEmptiesTheFolderInBothPlaces and testClearingTheBrowsingCacheEmptiesTheThumbnailFolder
  - testSignOutRemovesExactlyItsCleanupListForEitherReason, which now covers the thumbnails
- **Acceptance:**
  - On the phone, the first launch moves the store without a download: Diagnostics shows the same "Thumbnails kept offline" and photo download cache as before, and a devicectl listing shows no Caches/IlyichThumbnails
- **As built:**
  - Build 3040094, with C8 and G1. On the phone (2026-10-30), the first launch moved the store in one rename: no Caches/IlyichThumbnails, and Application Support/IlyichThumbnails/<digest> with its index and its 256 shard folders at their earlier sizes (devicectl listings before and after).
  - `ThumbnailDiskStore.directory(scope:root:)` defaults to Application Support. The app's store (`shared(scope:)`, opened by MediaPipeline when the account's runtime opens, off the main thread) names Caches as its earlier root; tests name both roots.
  - The store's first turn on its own utility queue (`prepare`) runs the move (`ThumbnailDiskStore+Move.swift`) before it loads the index or does anything else, under a lock for the process, as two accounts' stores may open together. At the first launch on the phone Application Support/IlyichThumbnails doesn't exist, so the whole tree moves in one rename (`renamex_np` with RENAME_EXCL, which never replaces anything). Every account's folder arrives with its index.sqlite, so the index stays complete, T5's position and counts come along, and no stored photo is asked for. The files keep their numbers on the volume, so they are renamed, not copied (a test checks).
  - When the new root exists already (a move a kill stopped, or an older build installed again after T8, which writes a new Caches folder), the move goes folder by folder. An account folder the new root lacks moves whole. One it has is merged: its index is first marked incomplete (meta complete and cursor deleted; an index that can't be opened is removed and rebuilt), so the store asks the disk until the launch comparison has adopted what arrived. Inside, a two-letter folder it lacks moves whole, one it has goes a file at a time, and a file already there is the same photo at the same revision, so the one in Application Support stays and the earlier copy goes, as does the earlier index. Nothing in Application Support is replaced or removed. Folders go once empty, Caches/IlyichThumbnails last. A test stops the move after each of its changes in turn: nothing is lost, and the next launch finishes it with every file listed and none a miss.
  - Until the move has run, reads look in Caches too: a file not found in its new place is looked for in the old one, then in the new one again, so a file that moves between the two looks is never a miss and never downloaded. Writes, forgetting, trimming and clearing run on the store's queue after the move. Anything that could not be moved (an error, not a kill) waits in Caches for the next launch's move and isn't read meanwhile, so forgetting a photo or a sweep can't miss a copy left there.
  - Backups: the IlyichThumbnails folder in Application Support gets isExcludedFromBackup whenever the store opens its index, at each launch and after Clear browsing cache, if the mark is missing. A folder moved from Caches has none, so the first launch sets it.
  - Followers: Clear browsing cache (Diagnostics, under Settings), sign-out for either reason and Diagnostics' cache usage already went through the store (removeAll, currentUsage), so they follow the folder; removeAll also deletes the account's folder in Caches if anything stayed there. Coverage reads its position from the moved index. No other code named the location (grep for IlyichThumbnails, cachesDirectory and the store's root). The URL cache (IlyichMedia, in Caches) and the decoded caches are unchanged.
  - Unchanged: the v1 layout and the index format (the fixture tree and the LegacyFormats mirror stand; only comments changed), the 1.5 GB cap with least-recently-viewed trimming, and the launch comparison.
  - The persisted-state entries "Thumbnail files" and "Coverage position and counts" and the risk "Thumbnail store stays in Caches" now say where the store lives since T8.

### W2 — Cast with scoped, revocable grants

- **Workstreams:** 9. **Depends on:** W1, C7. **Risk:** medium.
- **Scope:** CastGrantStore:
- single flight; reuse only when the remaining time is the need plus 60 s;
- duration clamp(need + 300, 900 to 21,600 s);
- revoke on stop, session end, account change and sign-out, awaited before logout.
CastEligibility: locked assets are ineligible. CastMediaResolver preflights HEAD with the child token. CastSessionService is generation-checked; following an ineligible asset keeps the current media. APIClient drops its cast state. GCK setup stays at launch.
- **Migration:** None.
- **Tests:**
  - testConcurrentRequestsCreateOneChildSession
  - testVideoGrantCoversPlaybackDuration
  - testStopAndSessionEndRevokeGrant
  - testPreflightUsesChildToken
  - testStaleLoadFailureDoesNotOverwriteNewerLoad
  - testFollowingIntoLockedAssetKeepsCurrentMedia
- **Acceptance:**
  - On the owner's Chromecast: a photo and a long video cast; Stop removes the Cast session from the web session list
- **As built:** Build 3040072, which never reached the phone; 3040074 first installed it. Each Cast session gets its own child-session grant sized to the media (15 min to 6 h), revoked on Stop, at the session's end, on an account change and before sign-out logs out; locked photos are never cast. It awaits a check on the owner's Chromecast.

### W4 — Widget core package

- **Workstreams:** 9. **Depends on:** C1, Q6. **Risk:** medium.
- **Scope:** IlyichWidgetCore:
- WidgetContract, with today's kinds and IDs;
- WidgetMediaClient: one connection and one invalidated session per timeline; v3 random filter with timeline visibility and size equal to the plan; memories respect the preference; failures typed;
- WidgetTimelinePlanner (pure): candidate order, no gaps, dates from the start of the minute, a memory budget, a midnight cut, backoff, .after policies;
- WidgetSnapshotStore: v2 layout, v1 import, album directory.
App side: WidgetRefreshCoordinator (typed changes, 60 s debounce, skipped in the background unless access changed) replaces direct reloads. LegacyAppGroupCleanup purges the Flutter widget keys once.
- **Migration:** Widget cache v1 is imported into v2. The Flutter widget credentials are purged once.
- **Tests:**
  - WidgetContractTests (written first)
  - WidgetMediaClientTests: never requests locked or hidden; size equals the plan
  - PlannerTests: candidate order; no gaps; snapshot is on-screen entry; midnight cut; memory budget
  - ServiceTests: locked keychain shows the cache; 401 shows sign-in; never another account's snapshot
  - SnapshotStoreTests: v1 import; sign-out clears
  - testSyncChurnCoalescesAndSkipsUnaffectedKinds
- **Acceptance:**
  - Unit suite passes
  - On the phone, widgets still update, now through the coordinator
- **As built:** Skipped by the owner (widgets), with W5.

### W5 — Native widget extension without Flutter sources

- **Workstreams:** 9. **Depends on:** W4. **Risk:** high.
- **Scope:** Rewrite Extensions/Widget in Swift 6 on the core, keeping the kinds, intent and entity type names, parameter names and the NONE and FAVORITES IDs. AlbumQuery resolves offline from the album directory. Add a widget asset catalog with a resizable logo. Give each extension its own entitlements. project.yml drops the ../mobile paths, the Swift 5 override and the app asset catalog. Delete the SessionKeychain facade and WidgetRandomSearchBody.
- **Migration:** Configured home-screen widgets keep their identifiers.
- **Tests:**
  - AlbumEntityQueryTests.testConfiguredAlbumResolvesOfflineFromDirectory
  - WidgetEntryViewTests.testErrorStateKeepsLogoAndMessageInsideSmallWidget
- **Acceptance:**
  - On the phone, existing random and memory widgets survive the update without reconfiguration (owner check); an offline album widget shows its cache; the error state is legible
- **As built:** Skipped by the owner (widgets), with W4.

### B10 — Retire legacy backup formats

- **Workstreams:** 2, 3. **Depends on:** B9. **Risk:** medium.
- **Scope:** Gates: at least 7 days on device, inventory shows zero legacy descriptors, and the owner confirms no older build will be reinstalled. Then delete LegacyBackupImporter, the backup mirrors in LegacyFormats, legacy descriptor and outcome decoding, the state.json files B9 left in place (B9 never renames them) and unreferenced legacy stage folders, and the way back B9 kept: BackupCoordinator, BackgroundUploads, BackupLifecycle and ProcessingWindow, the ShareInboxStore upload loop, LegacyCoordinatorBackend, LegacyStateReceipts, LegacyBackupIndexInputs, TransferHost's legacy branch and BackupBackendRouter's legacy backend; check-single-engine.sh then drops BackgroundUploads from its builders. Also retire W3's share-manifest v1 reader and stop writing the v1 url keys in v2 manifests, once no v1 manifest remains. An unexpected legacy descriptor is cancelled and logged.
- **Migration:** Irreversible deletion of state.json, behind the gates above.
- **Tests:**
  - RecoveryTests on v2 only
  - testUnexpectedLegacyDescriptorIsCancelledAndLogged
  - Date bit-exactness tests kept
- **Acceptance:**
  - On the phone, backup continues normally and Diagnostics shows no legacy state
- **As built:**
  - Gates: the owner confirmed on 2026-10-29 that B9 ran 7 days on the phone and no older build will be reinstalled. The rest is checked by the app, per account, as its TransferRuntime starts (`LegacyRetirement`, after the first reconcile): state.json is deleted only from a database the engine owns through B9's authoritative import whose recorded digest is the file's own SHA-256 (everything it says is in the database), and only while neither session holds a task an older build described. Otherwise it stays, logged with the reason, and Diagnostics' Engine row says why ("Old backup records kept: …"). Unreferenced legacy stage folders are recovery's sweep's (R5, as since B9), which now skips while iOS holds an older build's task, and still leaves alone a Backup folder whose state.json no import read (with the import kept, below, only a file an older build wrote after the engine took a database over without one). The critic's fourth gate ("no un-imported <group>/Backup/*/state.json remains") can't be checked from here and the owner hasn't abandoned such files, so the import of a state.json no import read stays (review fix, below).
  - An unexpected legacy descriptor (R0): every task described as builds before B9 did, in either session and for any account, is cancelled at each reconcile and counted in the report and the console; it is never adopted or sent again, its answer is never written or read, and a job whose stage it was uploading is checked again by its checksum (R3). `TaskDescriptor.legacy` now carries nothing: it only tells such a task from another app's.
  - Deleted: BackupCoordinator, BackgroundUploads, BackupLifecycle with ProcessingWindow, BackupAttempt, LivePhotoPairing, the ShareInboxStore upload loop (the store still reads and discards batches), LegacyCoordinatorBackend, LegacyStateReceipts, LegacyBackupIndexInputs, the importer's shadow mode, comparison (Diagnostics' Backup records copy) and merge, TransferHost's legacy branch and placement, BackupBackendRouter's legacy route, the outcome and task-description mirrors in LegacyFormats, legacy descriptor and outcome decoding, and ShareJobExecutor's legacy share identities. AccountDevice lost stopUploads, readOnlyChanged and recordTransferImport, which reached only the old engine, and the read-only toggle no longer waits on them; Diagnostics' Backup records section keeps only the Engine row. TransferHost starts the engine's sessions at the first account's activation, as B9 did when it chose the engine.
  - An account no import handed over (signed in last before B9, or a new one), kept deviating from the scope (review fix; the critic's correction to B10): `AccountRuntime.prepareTransfers` imports the state.json an older build left with B9's authoritative import (`LegacyBackupImporter`, authoritative only: no shadow copy, comparison or merge, since no older build will be reinstalled), over the copy B1 made of it. The account comes back as that build left it, signing out included (automatic backup off, paused), which the copy, made the last time the account opened in front, never saw; nothing it backed up is hashed or checked again. The file then goes at the engine's start like any other, and that build's unreferenced stage folders are swept. A database with no file to import, or whose file can't be decoded (moved aside, as in B9), is claimed (`claimForEngine`): a B1 copy keeps its records but has automatic backup switched off and waits, paused, so an account never starts uploading by itself from it. A file that can't be read now keeps the account's backup from starting until the next launch. The importer and the state.json mirrors go once the owner abandons other accounts' old records (open question).
  - Kept, deviating from the scope: the share-manifest v1 reader and the v1 url keys in v2 manifests, because `ShareInboxRepository.load` never rewrites a manifest, so a batch shared before W3 and never uploaded or discarded is still v1; and P5's fingerprint-JSON importer (section 9 schedules it for B10, the milestone's scope doesn't): it is no backup format, and it is inert once its files are gone (it deletes each on import, so on the phone they went with 3040076), so it can go with the other importers in a final cleanup.
  - check-single-engine.sh: only TransportSession builds a background session, and naming any type of the old engine fails the build (the importer, no engine, isn't on that list).
  - Tests: RecoveryTests on version 2 descriptors and outcomes only, with testUnexpectedLegacyDescriptorIsCancelledAndLogged; BootTests over the rows B9's import wrote (`TransferSeed`, `LegacyGoldens.importedSeed`), with the retirement cases (removed, an older build's upload with iOS, a file changed since the import) and an account no import read, signed out by an older build over a B1 copy with automatic backup on mid-run (imported, back paused with automatic backup off and the file's records, the file retired and the orphan stage swept); LegacyBackupImportTests, authoritative only (the golden file gives `importedSeed` row for row, the oldest shape, one transaction across crash points, an unreadable file set aside with the copy taken over paused, a file that can't be read now claims nothing, an engine-owned database takes no import, stranded album adds, 60,000 receipts off the main thread); AccountManagerTests through `prepareTransfers` (a new account, a B1 copy alone, a copy with the file); the date bit-exactness tests kept (TransferStoreTests through the store's own writes, LegacyFormatsTests through the state.json mirrors). The legacy outcome fixtures, BackupAttemptTests and LivePhotoPairingTests went with their code.
  - C8 removed what B10 kept: the import of a state.json no import read with LegacyRetirement, the share-manifest v1 reader and the URL keys, P5's fingerprint importer, and TaskDescriptor.legacy.

### C8 — Remove the temporary adapters; finish the bookkeeping

- **Workstreams:** 1, 2, 9. **Depends on:** B10, and the owner's confirmation (2026-10-29) that no build older than 3040092 will be installed again on the one phone. **Risk:** low.
- **Scope:** Delete what section 9 and the critic's correction to B10 still carried: P5's fingerprint-JSON importer, F5's places-cache importer, W3's share-manifest v1 reader (and the v1 url keys v2 still wrote, if nothing reads them), and B9's legacy backup import with LegacyBackupPlan, the state.json mirrors and LegacyRetirement; decide whether TaskDescriptor.legacy can go. Check C5's and C6's interim items. Tighten check-single-engine.sh. Bookkeeping: section 9, the missing As built notes, the critic's open clauses and PARITY's links.
- **Migration:** None. Share manifests are written without url keys, still version 2; the ones on disk read as before.
- **Tests:**
  - What the Share extension writes and what the app reads: SharedInboxTests, LegacyFormatsTests.testShareManifestV2 and the share/manifest-v2.json and manifest-v2-with-urls.json fixtures
  - A description an older build wrote is foreign and left alone: TaskDescriptorTests, BackgroundTransportTests, RecoveryTests
  - The date bit-exactness tests stay (TransferStoreTests through the store's own writes)
  - check-single-engine.sh refuses the deleted types and files
- **Acceptance:**
  - Unit and UI suites pass
  - On the phone: backup, Shared files and the merged library behave as before, with no rehash and no re-upload
- **As built:**
  - Build 3040094, with T8 and G1.
  - The facts the deletions rest on, from the integrator's read-only listing of the phone's containers on 2026-10-29: no Caches/IlyichFingerprints, no Caches/IlyichTimelinePlaces, and an App Group holding only Library/{Caches,Cookies,Preferences} (no Backup folder, state.json or ShareInbox). The owner confirmed no build older than 3040092 will be reinstalled, and this is the only device.
  - Deleted: `DeviceDatabase.importLegacyFingerprints` and `legacyFingerprintsFolder` with DeviceIndexService's call (saveFingerprints lost its keep-existing option); `LegacyPlacesImport` with its discard calls in SyncEngine and at sign-out (`AccountDevice.clearTimelineCaches` went, since month_places is cleared with the index and after every access change as before); `LegacyBackupImporter`, `LegacyBackupPlan` and `TransferStore.importLegacy`, `LegacyRetirement`, `AccountEnvironment.backupContainer`, TransferRuntime's retirement step, TransferHost's "Old backup records kept" text and Diagnostics' footer about it, StagingArea's guard for a state.json no import read, and the backup, share v1, places and fingerprint mirrors in LegacyFormats (the widget mirrors and the thumbnail layout stay). A database the engine doesn't own is claimed as it is: a new account's, or a copy B1 made, which waits paused with automatic backup off. TransferMeta reads only the import mode, which tells such a copy; the meta columns stay, so the database is unchanged. `AccountRuntime.importLocalDeletions` stays: it also marks a cleanup removal whose receipt a crash left unmarked.
  - Share manifests: version 2 is the only one read. The extension and the app write files by name alone; nothing read the url keys (readers since W3 use the names), so they are no longer written. The manifests builds from W3 to 3040093 wrote, url keys included, read as before (share/manifest-v2-with-urls.json pins it). A version 1 manifest would be a damaged batch, kept on disk and out of the list.
  - TaskDescriptor.legacy is gone (decision). B10 kept it to cancel tasks a build before B9 described. None can be left: B10 removed the phone's state.json, which it did only once neither session listed such a task, live or ending; no build that writes one will be installed again; and iOS ends a background upload a week after it starts (TransferSessionConfiguration's resource timeout), the last build that wrote them having left the phone on 2026-10-22. Such a description is now foreign like any other this build didn't write: recovery leaves it alone (R0 and the sweep's wait for it went), and its end is logged and ignored.
  - C6's interim item is done: AccountRuntime has owned AuthorizationState since C7 (3040068), and read-only pauses the transfer engine since B9; nothing of SessionStore remains. C5's confirming validateToken is no longer SessionStore's: C7 moved it into AccountManager (`SessionPolicy.confirmsExpiry`), where it runs as a transition of its own. It stays by design (Risks: a confirming validateToken against proxy and passing 401s), since a wrong sign-out costs the owner a full re-sync.
  - check-single-engine.sh rule 2c fails the build when code names a deleted importer or mirror, or the state.json, IlyichTimelinePlaces or IlyichFingerprints file names.
  - Tests: LegacyBackupImportTests and BootTests' retirement and import cases went; testTheStartSweepsStageFoldersNothingRefersTo keeps the start's sweep. RecoveryTests' R0 test went, and an older build's description joins the tasks testOrphanTasksAreCancelledAndOtherAccountsLeftAlone leaves alone. testLegacyFingerprintCacheIsImportedAndNotRehashed became testKeptFingerprintsAreNotRehashed, FencingTests' places test testAResetDropsTheKeptPlaces, and testV1ManifestLoadsAndRewritesAsV2 testAManifestWithURLsLoadsAndIsRewrittenWithNamesOnly. The places, fingerprint and backup-state format tests and their fixtures went: 15 fixtures remain of 23.

### G1 — Close the critic's open gaps

- **Workstreams:** 3, 4, 8. **Depends on:** N2, N4, N5. **Risk:** low.
- **Scope:** The plan clauses the critic found uncovered (see Critic's corrections): screens with lists of their own follow changes made elsewhere while they are open; UI tests for the People list's numbered pages, the Trash's month paging and a memory link that starts the app; a test that pins 3040030's fix.
- **Migration:** None.
- **Tests:**
  - CollectionFollowingTests (Trash and memories), LockedFolderSessionTests, SearchFeedTests.testAPhotoTrashedElsewhereLeavesATextSearch, FeedSessionTests.testAnAlbumOrPersonFeedFollowsMembershipChangedElsewhere
  - GlobeGeometryTests.testAColdBuildOfTheEarthNeverHoldsUpTheMainThread
  - UI: testThePeopleListLoadsItsNumberedPages, testTheTrashLoadsAMonthAtATimeAndRestoresAcrossItsPages, testAMemoryWidgetLinkThatStartsTheAppPlaysItsMemory (testAMemoryLinkThatStartsTheAppPlaysItsMemory since A1); AppLinkTests.testTheShareExtensionsLinkOpensSharedFiles
- **Acceptance:**
  - Unit and UI suites pass
- **As built:**
  - Build 3040094, with T8 and C8.
  - The Trash screen's state moved into TrashModel and On this day's into MemoriesModel; with the Locked Folder session they apply every change the account's sync publishes (`onLibraryChange`). A photo restored or put in Trash elsewhere leaves or joins the Trash; one moved out of the Locked Folder elsewhere leaves it, and one locked joins; a memory loses a photo archived, locked or put in Trash, and a memory saved or unsaved elsewhere shows it. Re-reads carry version counters, so a quiet read never brings back a photo that left meanwhile.
  - A text search drops a photo put in Trash elsewhere: a sync's change names it only as changed, so the search reads its record from the offline library (at most 200 per change) and decides as the feed's membership does.
  - Info's grids and Find similar drop photos deleted, locked or out of reach elsewhere.
  - Unchanged: a photo restored elsewhere returns to an open search, Info grid or memory only when it is read again; photos removed in the album editor leave the album feed at the next sync.
  - The fixture serves people a page at a time, a Trash holding photos in three months and a single memory; every earlier answer is unchanged.

### A1 — App Store readiness

- **Workstreams:** 9. **Depends on:** C8. **Risk:** low.
- **Scope:** The owner's decision for the App Store (2026-10-30): "Remove the widget completely. Reference immich only in description text, however point to my fork for backend. ... Do the most basic compliance, do not overlawyer and overcomplicate." The widget target compiled upstream Immich's AGPL widget sources from ../mobile/ios beside its own forks of them; that third-party code can't ship, so the widget goes entirely: its target, Extensions/Widget, every reload, and the paths, mirrors and fixtures only it needed; each launch deletes the folders it left in the App Group and the keys the Flutter app left there for its widget. No text a user sees names Immich, and About links the owner's fork as the source code and server. The app's links move from immich://, which the official Immich app also registers, to ilyich://. Basic compliance: a privacy manifest for the app and the Share extension, the export-compliance flag, and plain usage descriptions. The App Store description, review notes and privacy policy are the integrator's.
- **Migration:** <AppGroup>/WidgetCache and WidgetCache2 are deleted at every launch, and the Flutter widget keys are removed from the App Group's preferences. Home-screen widgets placed from earlier builds go with the update. Bundle and App Group identifiers, the x-immich-* headers, the API paths and the OAuth redirect are unchanged.
- **Tests:**
  - AppGroupLayoutTests.testTheWidgetsFoldersAreDeletedAtLaunchAndNothingElse and testTheFlutterWidgetsKeysAreRemovedAtLaunchAndNothingElse
  - AppLinkTests on ilyich:// (immich:// opens nothing) and testTheShareExtensionsLinkOpensSharedFiles; AccountManagerTests' sign-out steps without the widget reload
  - UI: the link tests on ilyich://, testAMemoryLinkThatStartsTheAppPlaysItsMemory (G1's memory widget link test, renamed), testEverySettingIsReachableFromTheSettingsShelf, SignInTests
- **Acceptance:**
  - Unit and UI suites pass; the Release build embeds no widget, and the app and its Share extension each carry a privacy manifest
  - On the phone: links and the Share extension's handoff open Ilyich; About shows the license line, the link and Licenses
- **As built:**
  - Build: the integrator's next build.
  - The widget: project.yml drops the WidgetExtension target, the app's dependency on it and its ../mobile/ios sources (upstream's widgets folder, WidgetBundle.swift and UIImage+Resize.swift). No target compiles anything outside ios-native now; GoogleCast and IlyichKit, the two packages, are inside it, and the Release build's 265 Swift files all are. Extensions/Widget went: ImageEntry, ImageWidgetView, ImmichAPI, the SessionKeychain facade and its Info.plist. The workflow build-ios-native.yml no longer expects the widget's appex.
  - Widget-only code in the app went with it: AccountDevice.reloadWidgets and its calls after sign-in, at sign-out and after each sync pass that succeeds (SyncEngine no longer takes the device), WidgetKit and the reload when network settings are saved, AccountStoragePaths.widgetCache, the removal of WidgetCache and WidgetCache2 at sign-out (KeychainCredentialStore.remove), and LegacyFormats' widget mirrors (WidgetMetadata, WidgetError, FlutterWidgetCredentials) with their goldens, their test and the seven widget fixtures: 8 fixtures remain of 15. Nothing else was the widget's alone. The server connection, Wi-Fi name, redirect delegate and saved session serve the app too, and the widget read no App Group key the app doesn't.
  - At every launch, off the main thread, `IlyichApp.deleteWidgetSnapshots` removes <AppGroup>/WidgetCache and WidgetCache2 with a plain removeItem: no flag, and a second run finds nothing. Beside it, `IlyichApp.removeFlutterWidgetKeys` removes widget_server_url, widget_auth_token and widget_custom_headers, which the Flutter app left in the App Group's preferences for its widget, with a plain removeObject: the token may be an old session's, and nothing reads them.
  - Links: AppLink answers ilyich:// only, so an immich:// link opens nothing. The Share extension hands over with ilyich://share, and Info.plist registers only ilyich, under the URL name app.ilyich.native. OAuth still gives stock servers the app.immich:///oauth-callback redirect, but the app no longer registers app.immich: ASWebAuthenticationSession catches its callback scheme itself. A throwaway probe on the iOS 27 simulator showed it: with only ilyich registered, a redirect to app.immich:///oauth-callback came back through the session's completion handler.
  - Branding: the only "Immich" a user could see was About's "Based on Immich. Licensed under the GNU AGPL v3." Credits now reads "Open source under the GNU AGPL v3.", followed by a "Source code and server" link to github.com/ilyador/Ilyich, which replaces the "Source code" link to the same address above it. Display names, usage descriptions and the Share extension's text say Ilyich or "your server". Kept, since stock servers need them and users never see them: the OAuth redirect, the x-immich-* headers, the API paths, and the bundle and App Group identifiers.
  - Licenses: Sources/Core/ThumbHash.swift ports the decoder of ThumbHash's reference implementation (MIT, Evan Wallace), the one piece of another project's code the app ships. Its notice now heads that file, and a Licenses row under About's Credits opens a plain page with it: the copyright line and the permission text exactly as the reference's LICENSE.md has them, each paragraph flowing to the screen's width.
  - Compliance: a PrivacyInfo.xcprivacy beside each target's Info.plist (Config/ for the app, Extensions/Share/ for the extension), added as a resource in project.yml. They declare no tracking, no tracking domains and no collected data: the app talks only to the user's own server. Required-reason APIs, from each target's sources and the symbols its Release binary references: the app uses UserDefaults, its own and the App Group's (CA92.1, 1C8F.1); file timestamps, of files in its own and the App Group's containers (C617.1: the thumbnail store, staging, shared files); and systemUptime for elapsed time (35F9.1). The Share extension reads the share inbox folders' dates (C617.1) and links IlyichPlatform's defaults code (CA92.1, 1C8F.1). Neither reads disk space or mach_absolute_time. GoogleCast 4.8.6 ships its own manifest, which the App Store reads with the app's: file timestamps (C617.1), UserDefaults (C56D.1, CA92.1), and collected device ID, other diagnostic data and product interaction, for analytics and app functionality, neither linked to the user nor used for tracking.
  - ITSAppUsesNonExemptEncryption is NO: the app uses HTTPS only. Every permission the app asks for has a plain description naming no server brand: Photos (to show, back up, favorite or remove the phone's photos, and to save to it), location (a photo's location in the location picker, and the Wi-Fi name), local network with Bonjour (a server on the local network, and Cast), and Face ID. The app asks for each of them, so none was dropped. NSAllowsArbitraryLoads stays for servers on plain HTTP.
  - Tests: LegacyFormatsTests lost testWidgetCacheV1AndFlutterWidgetKeys and the widget rows of its fixture and encoder tests, LegacyGoldens its widget values, AccountStoragePathsTests the widgetCache pin, AccountManagerTests the reloadWidgets step and SyncHarness the device. AppGroupLayoutTests' example of a folder outside the recorded ones is Library/Preferences, and testTheWidgetsFoldersAreDeletedAtLaunchAndNothingElse and testTheFlutterWidgetsKeysAreRemovedAtLaunchAndNothingElse are new. AppLinkTests use ilyich://; testWidgetLinkWorksBeforeSignInWithoutChangingServer became testAPhotoLinkWorksBeforeSignInWithoutChangingServer, which also checks that immich:// opens nothing. The UI link tests use ilyich://, testAMemoryWidgetLinkThatStartsTheAppPlaysItsMemory became testAMemoryLinkThatStartsTheAppPlaysItsMemory, and testEverySettingIsReachableFromTheSettingsShelf opens About to find the license line and the link, then Licenses to find ThumbHash's notice. Runs: IlyichTests, 988 tests with only the known-bug ledger's expected failure (GridViewportTests.testCellsLoadAfterAFastScrubStopsWithoutAnotherGesture failed once while the Release build compiled beside it, then passed on its retry); the 11 UI tests for links, sign-in, settings and Shared files; the Release device build without signing, whose app holds no widget and whose app and Share extension each hold their PrivacyInfo.xcprivacy beside GoogleCast's. check-single-engine.sh passes; it named nothing A1 removed. After the Flutter keys and Licenses were added, AppGroupLayoutTests, ThumbHashTests and the settings UI test passed again.

## Persisted state

- Session credential. Keychain service app.ilyich.native.session, account current, access group AppGroupId, AfterFirstUnlockThisDeviceOnly; SavedSession v1 JSON. KEEP byte-identical; read through CredentialStore (C1). Read by the app and upload delegates; the widget read it too until A1 removed it.
- Sign-out tombstone. App Group defaults session.signedOut. KEEP; written before delete, cleared after save.
- Authorization mirror. App Group defaults account.digest and account.authorizationEpoch. NEW in C6. Read by extensions and URLSession delegates; a missing or older value fails closed for writes. Beside them account.accessEpoch (NEW in C6), read only by the app at launch.
- Read-only flag. App Group defaults readOnly.<sha256(normalized server|user)>. KEEP key.
- Network configuration and client certificate. Keychain service app.ilyich.native.network, accounts settings:<sha> and certificate:<sha>. KEEP. Loading drops invalid entries instead of failing (C5).
- Locked-folder PIN. Keychain service Ilyich.LockedFolder.PIN, account sha256(cacheScope), biometry. KEEP (N5).
- Offline library database. Application Support/IlyichEntities/<digest>.sqlite: entities, metadata (session fingerprint, complete, needsReset, accessInvalidated, cached features) and acknowledgements. KEEP the file. MIGRATE the schema user_version 0 to 1 by adding derived tables with a resumable backfill (Q2); payloads untouched. Never force a re-login, because server checkpoints belong to the session.
- Server-side sync checkpoints for the login session. KEEP; no migration step may create a new session.
- Backup state.json. <AppGroup>/Backup/<digest>/state.json (BackupState JSON, deferredToDate dates). Shadow-imported in B1; authoritative import into Application Support/IlyichTransfers/<digest>.sqlite in B9, which kept it in place; DELETED on the phone by B10 (3040092) after the gates. Since C8 nothing reads it, and its mirrors are gone.
- Staged sources, multipart bodies and Outcome receipts. <AppGroup>/Backup/<digest>/<uuid>/{original,motion,sidecar,<stageID>.multipart,<stageID>.receipt}. KEEP in place: stage IDs become attempt IDs and paths are stored relative to the app group. Outcome v2 adds optional errorDomain, errorCode and cancelReason. Swept only when unreferenced and unbound (B6). Legacy decoding retired in B10.
- Background URLSession identifiers Bundle.main.bundleIdentifier + .backup and .share-upload (on the phone app.alextran.immich.H4K2MSF2SG.*), and task descriptors. Identifiers UNCHANGED. Legacy {id, receipt} descriptors adopted by ID (B5, B6). v2 descriptors written from B9. Legacy decoding removed in B10 once none remain; since C8 such a descriptor reads as foreign.
- BGTask identifiers app.ilyich.native.backup.processing and app.ilyich.native.backup.refresh, and UIBackgroundModes. KEEP. A coverage identifier is added only if the owner approves.
- Transfer notifications transfer.<UUID> and the terminal replay state. MIGRATE from state.json into notification_batches (B1, B9); IDs reused.
- Share inbox. <AppGroup>/ShareInbox/<batch>/manifest.json plus files and <identity>.multipart and .receipt. Version 2 only since C8, WRITTEN with names alone (W3 to 3040093 also wrote each file's url for builds before W3; those manifests read as before). A v1 manifest is no longer read: a damaged batch, kept on disk. Upload identity derivation unchanged. Manifest-less folders collected after 24 h.
- Transfers database. Application Support/IlyichTransfers/<digest>.sqlite. NEW in B1, in the private container (never the app group), excluded from iCloud backup. Holds jobs, attempts, receipts and the rest. Survives sign-out for either reason, as state.json does (pinned by C7's cleanup-list test).
- Device database. Application Support/IlyichDevice/device.sqlite. NEW in P1 (mutation journal); fingerprints added in P5.
- Fingerprint cache. Caches/IlyichFingerprints/<digest>.json. IMPORTED into device_fingerprint, then deleted (P5); the importer went in C8, none being left on the phone.
- Thumbnail files. Application Support/IlyichThumbnails/<digest32>/<stem2>/<stem>.<rev16>, with index.sqlite (T1), up to 1.5 GB, out of backups. MOVED from Caches by renaming in T8; nothing downloads again.
- Media URL cache. IlyichMedia/<digest>. KEEP. Precise purges; cleared only on sign-out, Clear browsing cache, or when a lock purge cannot find the entry.
- Timeline month snapshots. Caches/IlyichTimelines. DELETED in F2; the index is the cache.
- Month places. Caches/IlyichTimelinePlaces. Epoch-fenced in C6; IMPORTED into the index month_places table and the folder deleted in F5; the importer went in C8, none being left on the phone.
- Shelf order. UserDefaults shelfOrder.people.<cacheScope> and shelfOrder.albums.<cacheScope>. KEEP.
- Cleanup settings. cleanupKeepFavorites, cleanupKeepMediaType, cleanupKeepAlbumIDs, cleanupCutoffDaysAgo, cleanupDefaultsInitialized. KEEP keys and semantics (P4).
- Viewer, share, grid and appearance preferences: gridColumns, timelineGrouping, hapticFeedback, appearance, accent, viewer*, imageLoadOriginal, shareFileType, shareDownloadCloud, slideshow*, albumLayout, mapDetailStyle, diagnosticLevel. KEEP.
- Coverage policy. UserDefaults thumbnails.coverage.v1. NEW in T5, defaulting to today's behavior.
- Coverage position and counts. Rows coverage_cursor, coverage_mark, coverage_pass_mark, policy_hash, coverage_total and coverage_stored in the thumbnail index's meta table (Application Support/IlyichThumbnails/<digest32>/index.sqlite since T8). NEW in T5; cleared with the files on sign-out and Clear browsing cache, and a missing mark means one verification pass that fetches no present file.
- Widget cache. <AppGroup>/WidgetCache2/<digest>/<key>_image.png and _metadata.json, and WidgetCache/<digest> from builds before 3040055. DELETED at every launch since A1, which removed the widget (owner decision for the App Store); W4's import into a v2 layout was never built.
- WidgetKit configurations: kinds com.immich.widget.random and com.immich.widget.memory, intent and entity type names, parameters album, showAlbumName and forceFullColor, IDs NONE and FAVORITES. GONE with the widget in A1: widgets placed on the home screen go with the update.
- Legacy Flutter widget keys widget_server_url, widget_auth_token and widget_custom_headers, plus root cache files. REMOVED from the App Group's preferences at every launch since A1, with a plain removeObject and no flag: the token may be an old session's, and nothing reads them (W4's purge behind legacyWidgetCleanup.v1 was never built). Their mirrors and fixtures went in A1. The phone's App Group held no root cache files on 2026-10-29 (C8).
- Cast child session. Server-side only, never on disk. Revoked on stop, end and sign-out (W2). The GCK SDK's resume data is untouched.
- Mutation journal outcomes and receipts.local_deleted_at. NEW (P1, P4). Keep versus prune receipts after local deletion is an owner question.

## Risks

- Two execution engines during the backup cutover. They would corrupt staging and duplicate tasks. Mitigation: B2 to B7 are dormant; B9 deletes the old code in the same change, with a grep gate script and a device migration gate.
- Migration fidelity. A shifted modification date requeues the library and drops cleanup eligibility. Mitigation: REAL dates bound as doubles; golden fixtures from the production encoder; shadow import on the real phone first (B1); state.json kept until B10.
- Deletion of user photos. Mitigation: DS1 to DS12; property tests; the commit-time block check; Recently Deleted as the 30-day net; device gate with disposable media (P4). Free up space's Remove, which S0 made operational with the strict legacy verification, is off from P1 until P4.
- Server verification and local deletion can never be atomic under the current contracts. Mitigation: re-verify only the selection, immediately before perform; Apple's prompt stays the last window.
- Sideloaded bundle: iloader rewrites the bundle ID to app.alextran.immich.H4K2MSF2SG and may rewrite the app group. Identifiers must keep deriving from Bundle.main. Verify app-group resolution on the phone in C1 before any app-group format changes.
- 0xdead10cc termination if a SQLite lock is held in the app group at suspension. Mitigation: every database lives in the private container; the delegate journal is outcome files.
- Re-login triggers a full re-sync of about 60k assets. Never sign out the owner's account during device checks; sign-out is tested on the simulator or with a test account.
- Proxy 401 versus Immich 401 misclassification. Mitigation: body detection, a confirming validateToken, and Sign out always reachable.
- Widget identifier drift resets configured widgets. Mitigation: WidgetContractTests written first; owner checks the phone (W5).
- Privacy regressions: locked media in widgets, search, cast or caches. Mitigation: PF1 to PF5, S0, Q4, Q6, N5, W1, W2.
- Visible behavior changes:
- partners in the library;
- server in-month order;
- retries instead of errors;
- target-first thumbnail loading replacing DESIGN 6;
- Cast hidden for locked assets.
All need owner sign-off; defaults are listed in the questions.
- Index backfill and month_places import on a 60k library could hang or run long. Mitigation: resumable batches on the writer queue; server routing until queryable; hang measurement in Q2.
- Moving PhotoKit off the main actor may break UI-bound callbacks (the limited picker, PHLivePhotoView). Mitigation: nonisolated factories; UI pieces stay on main; device checks in P2 and P3.
- Thumbnail store stays in Caches: an iOS purge drops offline coverage. Resolved in T8: the store lives in Application Support, which iOS never empties.
- Shelf, rail and Earth choreography regressions from presentation rewrites. Mitigation: geometry code untouched; the 30 shelf unit tests and existing UI flows pinned; owner check in N4 and T4.
- SwiftUI nested presentation through PresentationHost may misfire dismissal callbacks. Mitigation: exactly-once layerDidDismiss tests; device checks.
- Background throughput is discretionary and unverifiable on the simulator. Mitigation: device measurement with the phone locked; staging budget; no throughput gate.
- Instruments may not attach to the iloader-signed app if it lacks get-task-allow. Mitigation: C4 verifies attach; fallback is --all-processes recording plus in-app signposts.
- The perf driver ships in Release. Mitigation: inert without a launch argument (only devicectl can pass one); invisible; drives only public scroll and rail APIs; owner may veto in favor of a profiling IPA.
- Build environment drift: the rsync recipe omits Extensions and Packages. Fixed in C1; the memory note needs updating.
- The UI fixture lacks sync and mutations, so index paths go untested. Mitigation: extended in C7, Q5, N2, W1 and T3.
- Strict V3 search schema: trashedAt needs an explicit null, and withPartners returns 400 with archive, favorites or trash. Mitigation: translator tests (Q4).
- Cast grants carry an account-wide token in a LAN-visible URL. Mitigation: shortest duration that covers playback, revoke on stop, locked assets excluded.

## Device measurements

- SETUP (macbook-air plus the phone, each session):
1. Build the Release IPA as usual on macbook-air (CURRENT_PROJECT_VERSION=<n>) and install it with iloader.
2. ssh macbook-air; cd ~/Dev/Ilyich/ios-native; export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer.
3. Check the phone: xcrun devicectl list devices (VIRUS!!! 00008130-000E0C910C38001C available), xcrun xctrace list devices, and xcrun devicectl device info apps --device 00008130-000E0C910C38001C | grep -i ilyich shows the build of app.alextran.immich.H4K2MSF2SG.
4. Phone state: unlocked; Developer Mode on; Auto-Lock Never; Low Power off; charging or above 50 %; thermal nominal; same Wi-Fi as the server (airplane mode for offline runs). A USB-C cable reduces trace overhead.
5. Attach check (C4): xcrun xctrace record --device 00008130-000E0C910C38001C --template 'Time Profiler' --attach Ilyich --time-limit 3s --output /tmp/attach.trace. If attach is refused, use --all-processes in every command below.
- RECORD a scenario with scripts/perf/record.sh <build> <scenario>. It runs:
1. xcrun devicectl device process launch --device 00008130-000E0C910C38001C --terminate-existing app.alextran.immich.H4K2MSF2SG -IlyichPerfScenario <scenario> -IlyichPerfSeed 7
2. sleep 3
3. xcrun xctrace record --device 00008130-000E0C910C38001C --template 'Animation Hitches' --instrument os_signpost --instrument Hangs --attach Ilyich --time-limit 90s --no-prompt --output build/perf/<build>/<scenario>.trace
The driver waits 8 s after first content, then emits a perf.scenario interval.
- EXPORT AND SUMMARIZE:
1. xcrun xctrace export --input <trace> --toc > toc.xml
2. For every table whose schema is os-signpost*, hitches* or *hang*: xcrun xctrace export --input <trace> --xpath '/trace-toc/run[@number="1"]/data/table[@schema="<schema>"]' > <schema>.xml
3. /Applications/Xcode.app/Contents/Developer/usr/bin/python3 scripts/perf/summarize.py build/perf/<build>/<scenario> writes summary.json with p50, p95 and max of thumb.display per source, hitch time ratio, longest hitch, hang count and peak or post-trim mem.footprint.
4. Append the table to the PARITY build log, next to the C4 baseline. Raw traces stay on the Mac.
- REAL-THUMBNAIL LATENCY (scenarios rail-random and rail-sweep, online, after T7 coverage is complete):
- memory-source binds displayed in the same frame: 100 %;
- disk-hit bind-to-display: p95 at most 50 ms, p99 at most 100 ms;
- network misses: p50 and p95 reported separately, gated only as no regression against baseline;
- placeholder (sketch or color) frames reported separately.
- OFFLINE RANDOM JUMPS after preparation (airplane mode, coverage complete, scenario rail-random with 20 seeded jumps and 1.5 s dwell):
- zero thumb.display events with source network;
- every visible cell shows real pixels within 300 ms of a jump, p95;
- hitch time ratio under 5 ms/s.
- DIRECTION REVERSALS AND FLINGS (scenarios reverse and fling, plus a manual 60 s free-scroll protocol by the owner under the same record command):
- hitch time ratio under 5 ms/s;
- longest hitch at most 50 ms;
- after a reversal, behind-band rows display from memory or disk (no network), measured via signposts.
- RELAUNCH (scenario relaunch-check, 5 cold launches via devicectl --terminate-existing):
- launch.firstContent (first grid frame with at least 12 real thumbnails): p50 at most 1.0 s, p95 at most 1.5 s;
- rail place names visible at first content (F5);
- no network thumbnail fetch for covered months.
- BOUNDED MEMORY AND PRESSURE (scenario memory-warning: rail-sweep, then the memory-pressure handler, then rail-random):
- peak phys_footprint at most 450 MB;
- decoded thumbnail cache at most min(128 MB, RAM/64);
- within 2 s of trim, footprint at most 300 MB;
- pinned visible cells still bind from memory.
Also check Activity Monitor template peaks over a 10-minute session.
- RESPONSIVE DURING BACKGROUND WORK (scenario background-load, run while 100 or more backups are queued, a sync pass and coverage are active; add --instrument 'Time Profiler'):
- hitch time ratio under 5 ms/s;
- zero hangs of 250 ms or more;
- main-thread samples in Transfer*, Sync*, Index* and Coverage* symbols at most 2 % of main-thread time.
- INDEX MIGRATION (first launch of Q2):
- index.backfill duration recorded;
- zero hangs of 250 ms or more;
- the feed stays interactive (hitch ratio under 5 ms/s during scroll).
- CLEANUP SCAN (P4, real library with about 21k receipts, read-only check, no deletion):
- time to candidates and peak concurrent GETs (at most 6) recorded;
- zero hangs;
- memory under 300 MB.
- BACKGROUND TRANSFERS (B9):
1. Queue 100 photos and lock the phone on Wi-Fi and power for 10 minutes.
2. Server-confirmed count before and after (server API) and transfer.commit signposts on next launch: more than 0 and no duplicates.
3. Force-quit mid-video: the next launch resubmits, not fails.
Reported, not gated.

## Open questions for the owner

- Untracked files in the repository root were left uncommitted, as the launching session's commit left them, because their status is unclear. Commit, add to .gitignore, or delete each:
- .design-upload-tmp/ (1.9 MB of temporary design uploads);
- .impeccable/ (a skill's hook cache);
- design/._ilyich-logo.png (macOS AppleDouble junk);
- LIGHTROOM_SIDECAR_PLAN.md (a server plan that contains a private Tailscale URL).
- S0 Settings: the default adds one All settings row to the Settings shelf. It opens today's full list with Sign out, Read-only mode, Network, Notifications and Diagnostics. Alternatives: give each its own row, or move Sign out and Read-only into Account.
- Should the main library include partners whose libraries are set to show in your timeline (Flutter parity; PARITY says done but it has no effect)? The plan defaults to yes.
- Should a person's feed include shared-album photos (server and today's native app) or only you plus partners (Flutter)? The plan defaults to server behavior.
- Should the order within a month follow the server (local day, capture time, file name) everywhere, so the offline and online order match? Owner: no; keep ordering by the time taken, then ID, everywhere (offline and online still match).
- Search defaults: active photos only, with timeline visibility unless Library and archive is chosen; the match count shows server totals only (none for smart search). Agreed?
- Should offline thumbnails stay in Caches (iOS may purge them; coverage re-downloads) or move to Application Support with a visible size cap? Owner (2026-10-29): move it to Application Support. Done in T8: the 1.5 GB cap and least-recently-viewed trimming stay as they were, and the size shows in Diagnostics as before, with no new setting. Coverage scope: your timeline only (default), or also archive, partners and shared albums? Should a background coverage task be allowed?
- Proposed performance gates: disk hit p95 at most 50 ms; hitch ratio under 5 ms/s; peak memory at most 450 MB; cold launch to first real thumbnails at most 1.0 s p50. Accept or adjust?
- May the inert perf scenario driver ship in Release builds (it is activated only by a devicectl launch argument), or do you prefer a separate profiling IPA for measurements?
- Backup behavior changes, defaults:
- transient errors retry silently with backoff capped at 1 h;
- album-add failures no longer keep photos queued;
- enqueue is allowed while a backup runs;
- Back up selected no longer triggers full discovery;
- photos deleted from Photos leave the queue;
- failed items are shown apart from remaining;
- what today's loop can no longer reach is uploaded at the cutover: a kept stage or a failure whose photo left the queue, and an album add for a photo never uploaded (B1 imports each as a job, so nothing is lost; no build is known to leave such a state).
Accept each?
- Should background backup's metadata sync stay a hard gate as today, or become best-effort before discovery so it never blocks queued uploads (the plan's default)? Should uploads respect Low Data Mode?
- Read-only mode and uploads: today, turning it on pauses backup and shared uploads and switches automatic backup off, turning it off starts nothing again, and the footer says "Backup stays paused until you start it again". C6's acceptance asked for turning it off to resume backup, which changes that, so C6 keeps today's behavior until you answer. Should turning read-only mode off resume backup, with automatic backup left on, and the shared uploads it stopped? A yes needs what to resume kept on disk, so that a relaunch while it is on does not lose it.
- Sign-out data, defaults:
- keep the automatic-backup preference;
- after a session-expiry sign-out, keep thumbnails and network settings for the same account;
- explicit sign-out wipes as today.
C7 keeps today's behavior until you answer: sign-out, for either reason, switches automatic backup off and removes thumbnails and network settings. SignOutPolicy holds each default, switched off.
Should a proxy 401 (no Immich error body) stop signing you out and show a connection problem instead?
- Cleanup:
- keep Free up space's Remove off from P1 until P4's cleanup service lands, as the critic proposed (default), or turn it back on before then, as S0 had it;
- keep all-or-nothing when re-verification finds changes (default), or allow removing the rest after confirming;
- count archived server copies as backed up (default yes) and Locked Folder copies (default no);
- keep receipts after local deletion as history (default yes);
- cleanup settings device-wide (default) or per account.
- While a new filter loads, keep the old grid frozen for up to 1.5 s and then show the new feed with placeholders? Is SimilarPhotos allowed to keep its own grid, given DESIGN's one-grid rule?
- Navigation, defaults keep today's behavior:
- a link leaves the shelves and the Earth up, as today; since N1 it first closes any sheet or viewer, where a photo link under a sheet used to do nothing;
- a viewer opened from More closes the sheet rather than stacking above it;
- deleting in the viewer moves on to the next photo, as the phone's viewer does since P3 (N3; it used to dismiss);
- the two Trash experiences stay separate;
- web links are parsed but have no Associated Domains entitlement.
Change any?
- Locked media in the viewer: keep Download original, Share and Save to Photos (default), or hide them as Flutter does? Should album widgets include archived photos (default no)?
- Cast: is a grant cap of 6 h for long videos acceptable? Locked assets stay non-castable until the server offers asset-scoped grants.
- Will an older build ever be reinstalled after the backup cutover (B9)? This decides when state.json.imported can be deleted (B10, default 7 days after confirmation). Answered 2026-10-29: no build older than 3040092 will be reinstalled (B10 and C8 acted on it). Use iOS 27 BGContinuedProcessingTask for user-started backups? It shows system UI; default no.
- Other accounts' old backup records (B10): B9 moved an account's backup records to the new engine only when that account signed in, so an account last signed in on this phone before build 3040077 still has the records an older version kept (state.json). B10 keeps B9's import for them: if such an account signs in again, it comes back as it was left (backup paused, automatic backup off, nothing it backed up checked or hashed again), and the importer stays in the app. Default: keep it until you confirm no such account will sign in on this phone again. Then it can go, and such an account would check its photos with the server again (hashing them, not uploading them twice) the next time it backs up. Answered by the phone check on 2026-10-29: the App Group holds no state.json, and this is the only device, so C8 removed the importer.
- Are server changes acceptable (isDeveloped and ownerId in the V3 search filter, a per-asset dependent backfill), or must the client keep post-filters and per-asset repair (default)?

## Critic's corrections

Revise the roadmap before execution. It maps nearly every plan clause to a milestone, and the persisted-state register is close to complete, but six problems must be fixed first.

1. **Privacy.** S0 leaves library and similar-photo search returning Locked Folder photos into the main feed during a PIN-elevated session until Q4. It also leaves locked widget snapshots cached on disk, where they can reappear as the offline fallback.
2. **Deletion safety.**
   - DS4 accepts a server copy in the Locked Folder.
   - DS11 makes cleanup unusable while backup runs, because every new receipt invalidates the whole scan.
   - receipts.local_deleted_at has nowhere to live before B9.
   - P1 enables real deletions behind a process instruction rather than a code gate.
3. **Backup migration.**
   - B9's rename makes any rollback start from an empty backup state.
   - B10 drops the importer while other accounts' state.json files may be un-imported.
   - The legacy intent mapping, the classification of legacy outcomes (whose only error text depends on the device locale) and the handling of stages without a checksum are unspecified.
4. **Dependency errors.** P5 needs P4 and F3, P4 needs C7, T7 needs B9, W1 needs C6, and C4 must precede every milestone whose acceptance uses its baseline.
5. **Regressions.**
   - T1 breaks the viewer's cached-preview opening (DESIGN 13) until T6.
   - F3 re-sorts away Q3's server order.
   - F2 and F4 contradict pinned store tests and PARITY 3040020.
   - The single authorization epoch drops in-flight reads on read-only or Locked Folder toggles.
   - Q3/Q6 lose today's crash-safe access-loss purge.
6. **Unowned view work.** Sign-in, network settings, PIN, account, album activity and editor polling stay in views with no milestone, against plan line 24.

All tracked changes were already committed before this step (HEAD 54ab500cd). The four untracked paths the roadmap already raises as an owner question remain uncommitted. This review only read files and changed nothing.

### Plan clauses not yet covered

Status as of C8 (2026-10-29), after each item: resolved, with where; in progress, with the agent working on it this round; or open, with why.

- Plan line 24, "Views render state and submit commands. Services receive explicit dependencies and own their work outside the UI lifecycle." No milestone moves work out of these views: **Resolved**, each below.
- SignInView creates a new APIClient on every serverAddress change (SignInView.swift:105-110). Each one opens two URLSessions plus a probe session that are never invalidated, and reads the Keychain on the main actor. The view also runs OAuth itself (:134-143). Architecture section 1 lists a SignInModel, but no milestone builds it. **Resolved** in C7 (3040068): SignInModel asks the server once typing pauses, through AccountManager.serverFeatures, which makes its client off the main actor and shuts it down; single sign-on runs there too.
- NetworkSettingsView writes the Keychain and imports PKCS#12 on the main actor. C1 only moves the stores into the package. **Resolved** in C7 (3040068): NetworkConfigurationService, an actor, does both.
- PINSettingsView calls PUT/POST/DELETE auth/pin-code (PINSettingsView.swift:52-60). **Resolved** in N4 (3040085): through AccountSettingsService.
- AccountSettings, ChangePassword and ProfilePhotoView call users/me, change-password and DELETE users/profile-image (ProfilePhotoView.swift:47). **Resolved** in N4 (3040085): through AccountSettingsService.
- AlbumActivityView calls POST/DELETE activities and PATCH albums/{id} isActivityEnabled (AlbumActivityView.swift:70-86). N4's CollectionsService does not cover these. **Resolved** in N4 (3040085): CollectionsService comments, likes, deletes activities and switches them on and off.
- PhotoEditor's save-then-poll-for-mediaRevision loop. N2 adds an `edits` request but not the polling. **Resolved** in N2 (3040083): LibraryMutationService's edits request polls for the new revision, so the preview reaches the feed after the editor has closed.
- LibraryView's globe warm-up task. **Resolved** in N1 (3040070): LibraryScreenModel warms up the Earth.
- Plan line 78, "Collections handle deletion, restoration, locking and membership changes correctly." Only the main feed (F4 FeedMembership) and the shelves (N4 CollectionsStore) apply changes. N2 and N3 delete the onChanged/onDeleted closures, but no milestone makes any of these consume MutationResult or LibraryChange: FolderAssetsView, the Locked Folder grid, AlbumAssetsManager, DuplicatesView, TrashView, InfoCollectionView's place grid, SimilarPhotos, MemoriesView. After N2 those grids keep showing deleted, restored or moved photos. **Resolved.** N2 (3040083) made the folder grid, the Locked Folder grid, Trash, Duplicates, Info collections, Similar photos and stacks follow mutation results, and N4 (3040085) the albums list. G1 (3040094) made them follow changes made elsewhere too: the Trash screen (TrashModel), the Locked Folder and On this day (MemoriesModel) follow every sync's change, a text search takes a named photo's record from the offline library, and Info's grids and Find similar drop photos gone elsewhere. The album, person, place, search, Favorites, Archive and Trash feeds are the main feed, which followed every kind of change already. CollectionFollowingTests, FeedSessionTests, LockedFolderSessionTests and SearchFeedTests pin it.
- Plan line 88, "remove obsolete code and temporary adapters after validated migration", and the roadmap's own rule that every temporary adapter is listed in section 9 with its removal milestone. None of these has a removal milestone or appears in section 9: **Resolved**; section 9 lists each with its status.
- the fingerprint-JSON importer (P5); **resolved:** removed in C8;
- the TimelinePlacesCache-JSON importer (F5); **resolved:** removed in C8;
- the widget-cache v1 importer and the legacyWidgetCleanup.v1 purge (W4); **resolved:** never built, as the owner skipped W4 and W5 (S0's drop of the pre-3040055 WidgetCache folder stays, in the widget and at sign-out);
- the share-manifest v1 reader (W3); **resolved:** removed in C8, with the v1 url keys v2 still wrote;
- C6's interim "AuthorizationState owned by SessionStore for now"; **resolved** in C7 (3040068): AccountRuntime owns it;
- C5's interim second-validateToken sign-out rule. **Resolved** in C7 (3040068): the rule is AccountManager's (SessionPolicy), run as a transition of its own; the confirming check stays by design (see C8's As built).
- Plan line 95, "UI coverage for navigation, pagination, mutations and deep links".
- Deep links have one UI test, N1's testDeepLinkOpensAssetOverOpenSheet. Nothing covers immich://memory, immich://activity, album or person links, immich://share from the extension, or a link that cold-launches the app. **Resolved.** N1 (3040070) also added testLinksOpenMemoriesSharedFilesAlbumsPeopleAndActivity, testMemoryShowInTimelineAndOpenPhotoCloseTheMemoriesFirst and testALinkThatStartsTheAppOpensItsPhoto. G1 (3040094) added testAMemoryWidgetLinkThatStartsTheAppPlaysItsMemory. No UI test can drive a share sheet, which belongs to another app, so the Share extension opens a shared link constant and AppLinkTests.testTheShareExtensionsLinkOpensSharedFiles pins the app's answer.
- Pagination UI covers search only (F1). PeoplePager's numbered pages (F5) and Trash bucket paging have unit tests only. **Resolved** in G1 (3040094): testThePeopleListLoadsItsNumberedPages and testTheTrashLoadsAMonthAtATimeAndRestoresAcrossItsPages.
- Plan line 30, "Capture the reported failures in regression tests". Two reported failures from the build log have no regression test:
- 3040019: the correlated face-membership query blocked all local reads for 5 s. EntitySyncTests:163 pins its correctness, not its latency. **Resolved** in Q3 (3040072): IndexReadsTests.testPersonTimelineOnALargeLibraryStaysWithinBudget loads a person's months and newest month on 60,000 photos within 500 ms.
- 3040030: the first cold use of the shelves stalled on the Earth mesh. **Resolved.** The fix was in place (the land mesh is built off the main thread in pieces of at most 24,000 triangles, warmed up 4 s after launch); G1 (3040094) pins it with GlobeGeometryTests.testAColdBuildOfTheEarthNeverHoldsUpTheMainThread, which fails at about 620 ms when the build runs on the main thread. RealityKit's own setup at the first mesh still holds the main thread once per launch, at the warm-up: 0.35 to 1.1 s on the simulator, not measured on the phone.
- Plan line 64, "Maintain persistent, revisioned real thumbnails across the library, with explicit coverage and storage policy".
- T1 keeps both the files and the new index.sqlite in Caches, which iOS may purge, with no defined behavior when files vanish under a complete index or the index vanishes over present files. **Behavior resolved** in T1 (3040074): every launch compares the folders with a complete index, a file the index lists that can't be read is a miss and loses its row, and a missing index is rebuilt. **Storage location resolved** in T8: Application Support, out of backups.
- T5's policy covers scope and conditions but not storage location or cap. Storage policy is left entirely to an owner question. **Resolved** in T8: the owner chose Application Support; the 1.5 GB cap stays, trimmed least recently viewed first.
- Plan line 96, Release measurements of "responsive interaction during background work". T7 is the only milestone that runs the background-load gate, and it does not depend on B9. It can therefore measure the legacy main-actor BackupCoordinator, and its "Transfer* symbols at most 2 % of main-thread time" criterion only exists once the new engine is in. **Resolved in part:** T7 measured background-load on 3040086, after B9's engine (PARITY 3040088): 19 ms/s of hitches, zero hangs, an exception the owner accepted. **Open:** the main-thread share in Transfer, Sync, Index and Coverage symbols, since Time Profiler can't attach over Wi-Fi, the phone's only link; it needs a run over USB.
- Plan line 9, "Preserve ... the functionality tracked in PARITY.md". PARITY completion gate 3 (PARITY.md:362) requires device checks that no milestone's acceptance includes:
- Photos permission transitions between limited, full and denied (absent from P1 and P3); **open:** a check by the owner on the phone, which no test run can make;
- shared-album role restrictions (absent from N4); **open:** needs a second account that shares an album with the owner's;
- outgoing share handoff (absent from W1's MediaExportService). **Resolved** by the owner on the phone (3040093, 2026-10-29), asked to send a photo, a video and a Live Photo from the viewer's Share button to other apps: "so far sharing worked well".

### Unsafe or unshippable as written

- S0 is not the complete safety fix. Two privacy problems remain:
- Library search can return Locked Folder photos into the main feed until Q4. The unfiltered library, findSimilar and place search build SearchFilter() with no visibility (LibraryStore.swift:632, 758, 796, then searchFilter.matching in loadResults). The server adds `visibility != locked` only for sessions that are not PIN-elevated (server/src/utils/search-filter.ts:45-58).
- Widget snapshots cached before S0 stay in <group>/WidgetCache/<scope>. A locked photo cached there is shown again as the fetchFailed fallback (ImageEntry.handleError -> loadCached), and W4's v1 import would carry it into v2.
- P1 turns Free up space from a likely crash (the inline change block at LocalLibraryViews.swift:253) into real deletions. Only the legacy verifier guards them:
- It runs serially over every receipt (about 21k) on the main actor.
- Its BackupRemoteAsset decodes no visibility (BackupReceipt.swift:27-61), so with an elevated session it accepts a server copy that sits in the Locked Folder.
"Use only disposable media until P4" is a process rule on a phone that receives every build, not a code gate.
- P4: as specified, cleanup can't be completed while backup runs.
- DS11 invalidates the whole scan on "a receipt change", and backup creates a receipt per upload, so with backup running a scan never reaches Remove. P4's test text "library changes invalidate the scan" also contradicts "a device change drops only the affected candidates".
- DS4 has no visibility check, although the owner default says Locked Folder copies don't count.
- markLocallyDeleted has nowhere to persist before B9: BackupState has no such key, and the B1 shadow DB is rebuilt from state.json.
- P4 is per-account but doesn't depend on C7, so nothing in AccountRuntime's shutdown order tears it down.
- P5 can't be built in its declared order. It consumes ReceiptRepository and LegacyStateReceipts, which P4 introduces, and publishes DeviceSnapshot, which F3 introduces. Yet it depends only on P2, Q4 and Q6.
- B1's shadow import "rebuilds the database when the state.json digest changes". BackupCoordinator rewrites state.json several times per photo (persist() at 345/361/372/395/414/431/443). If the trigger isn't throttled, every write causes a full rebuild of about 60k rows, doubling today's O(N^2) I/O during backup.
- B5 through B8 ship a dormant second `URLSessionConfiguration.background(withIdentifier:)` call site beside BackgroundUploads, while check-single-engine.sh only arrives in B9. If the dormant code is ever instantiated, the process holds two sessions with the same identifier, and event delivery is undefined.
- B8 ("the app delegate activates once") leaves backup blank after a sign-in without relaunch.
- BackupCoordinator.activate() is the only code that loads a scope's state.json (BackupCoordinator.swift:93-110). Today the views' .task calls to it handle account changes.
- After B8 deletes them, an in-session sign-in leaves backup settings, the queue, album upload chips and the receipts fed to DeviceTimelineIndex empty until relaunch or until a command happens to call activate().
- B9 has four gaps:
- Renaming state.json to state.json.imported makes a rollback to any pre-B9 build start from an empty BackupState: full re-discovery and re-hash, no receipts, no cleanup eligibility.
- The legacy paused/automatic to RunIntent mapping is unspecified. Mapping "unpaused" to manual retries every legacy item failure at cutover.
- Legacy failed outcomes carry only a localizedDescription, which depends on the device locale and must not be parsed.
- Cleanup deletions committed between P4 and B9 must be imported from device_mutation into receipts.local_deleted_at.
- B10 deletes the importer while other accounts' <group>/Backup/<digest>/state.json files may never have been imported. They are imported only when that account's runtime opens, and today they survive sign-out. Signing into such an account later loses its receipts and confirmations. That includes the test account the roadmap proposes for sign-out checks on the phone.
- Q2 has two failure modes:
- No downgrade detection. A reinstalled pre-Q2 build keeps syncing entities without maintaining the derived tables. On re-upgrade, user_version=1 and isQueryable=true serve stale months and counts.
- Derived rows are maintained inside the sync-batch transaction with no fallback, so a bug in derived maintenance blocks sync itself.
- Q3 and Q6 drop today's crash safety for access loss.
- Today accessInvalidated is committed in the same batch transaction (EntityStore.swift:101) and consumed only after the purge (takeAccessInvalidation, :47-49).
- The new accessLost IDs exist only in memory. A crash between the index commit and the hub delivery leaves revoked media on disk, violating PF3.
- A '1' left in that flag by the previous build is ignored after upgrade.
- Q6's "sync reset keeps revision-valid thumbnails" has no follow-up purge of assets the reset removed.
- T1 deletes "the NSCache thumbnail caches", but MediaPipeline.decoded and latest also hold previews (MediaPipeline.swift:45-49).
- ViewerPhoto.swift:38-41 opens a photo on latestImage(.preview), else on its grid thumbnail. FeatureSupport.swift:28/46/98 also use latestImage.
- These callers are rewired only in T6, so DESIGN 13's "a photo opens on its cached preview or its grid thumbnail" regresses from T1 to T6.
- The index in Caches has no handling for files deleted by an iOS purge or by an older build's mtime trim.
- F3: MonthProjector ports MergedTimeline.entries, which re-sorts every entry, remote rows included, by (date desc, id asc) (MergedTimeline.swift:49-53). In the merged main library this undoes Q3's server order (local day, fileCreatedAt, fileName, id). The owner default "offline and online order match" fails exactly where phone photos are merged. (Moot: the owner kept the time-taken order, which MergedTimeline already uses.)
- F4 combined with F2 breaks a pinned behavior.
- testFailedReplacementRetainsOldFeedAndClearRestoresIt makes the month request fail with HTTP 500 and asserts that the old feed stays, with an error and isReplacingFeed true (LibraryStoreTests.swift:256-276). This is PARITY 3040020: "errors retain them for Retry/Clear".
- F2 retries transient errors, F4 counts failed months as "ready", and F4 commits after 1.5 s. Together they replace the old feed, yet F6 claims every store test ports with unchanged assertions.
- F4 also hard-codes an answer to an open owner question.
- F2 deletes TimelineCache, which two pinned tests write directly: testCachedTimelineShowsItsMonthBeforeNetworkRefreshFinishes and testBackgroundRefreshKeepsLiveRowsAndDoesNotReplayOlderDiskSnapshot (LibraryStoreTests.swift:446-481, build 3040024's fix). Server-routed feeds (fresh install, or after a metadata reset) lose first paint, and Q5's and F6's "unchanged assertions" claims are false.
- C6's epoch design: setReadOnly bumps the single AuthorizationEpoch, and rule 0 also bumps it on Locked Folder elevation. Because "Stores commit only results whose epoch is current", toggling read-only or opening the Locked Folder discards in-flight month loads, thumbnail stores and places counts. Nothing re-requests the dropped protected months, so placeholders can stay, contrary to F2's acceptance.
- W4 purges widget_server_url and widget_auth_token unconditionally. PRODUCT.md:19 keeps the old Flutter installation working until parity. If an installed Flutter build shares the rewritten app group, its widgets break before then.
- W5 gives each extension its own entitlements file but doesn't repeat C1's on-phone check that the app group resolves. iloader rewrites the group per entitlements file, so this is where the group could silently change.
- Ordering errors:
- Q1 (no feed.month signposts), Q2 (index.backfill), F2 and F3 ("no worse than the C4 baseline") and P4 (cleanup-scan measurement) need C4's signposts or baseline, but C4 is not among their ancestors: C5 depends only on C2 and C3, so behavior changes can land before the baseline is recorded.
- T7 needs B9.
- W1's context uses C6's authorization snapshot but depends only on C5.

### Missing migrations

- S0: purge <group>/WidgetCache once for every scope, behind a flag, then call reloadAllTimelines. This keeps snapshots cached before S0 (locked, hidden or archived photos fetched during PIN elevation) from being shown as the fetchFailed fallback or imported by W4.
- receipts.local_deleted_at for cleanup deletions committed between P4 and B9. LegacyStateReceipts can't store it: BackupState has no key, and the shadow DB is rebuilt from state.json. B9's importer must set it from committed device_mutation rows whose origin is cleanup(account == digest) and whose expected revision equals the receipt's.
- EntityStore's accessInvalidated metadata flag. A '1' can be persisted by a pre-Q3 build that crashed between commit and consumption.
- Q3 must consume it once by running a full media reconcile.
- From then on, persist pending accessLost IDs in index_state inside the batch transaction and clear them after the media purge.
- Rollback and re-upgrade for every milestone that writes a new format. Only B9 has a downgrade question.
- Q2: nothing marks the derived rows as current.
- T1: an old build's mtime trim deletes files the index still lists.
- W3: older builds can't read v2 manifests, and SharedInbox.load fails for every batch when one manifest is bad.
- W4: older builds don't read v2 snapshots.
Add a writer marker, rebuild when it's stale, and treat a failed read of a thumbnail the index calls present as a miss.
- F5 places import:
- TimelinePlacesCache files are named sha256(TimelineFilter.cacheKey), and the JSON doesn't contain the key (TimelineCache.swift:100-104). The importer must hash candidate keys (the library key plus every person, album, partner and place key from the index) to map files to query_key.
- If Q5 adds withPartners first, the library file must also be found under the pre-Q5 key.
- Otherwise DESIGN 9's "places kept on the phone show straight after launch" is lost.
- B10: before deleting the importer, import every <group>/Backup/*/state.json, or get the owner to abandon them explicitly. Today they survive sign-out.
- IlyichTransfers/<digest>.sqlite at sign-out.
- Today explicit sign-out keeps state.json and its receipts; disconnect only resets memory (BackupCoordinator.swift:236-242).
- The roadmap's "explicit sign-out wipes as today" never names this file. State that it survives explicit and expiry sign-out, and pin that in C7's cleanup-list test and B9's tests.
- Engine state at B9:
- paused=false with automatic=true becomes the automatic intent, not manual, so legacy item failures aren't retried in bulk at cutover.
- paused=true becomes paused.
- The legacy error string becomes lastMessage, not an account blocker.
- Legacy Outcome files {receipt?, error, httpStatus?}: classify them only by receipt and httpStatus. An error with no httpStatus counts as an interrupted attempt, which is re-checked by checksum or resubmitted from the existing body. Never match on the localizedDescription text.
- Legacy stages have no original checksum; PreparedPhoto persists only motionChecksum.
- B6/B9 must either hash once in the foreground or resubmit the existing <stageID>.multipart and rely on the server's duplicate answer.
- testOriginalChecksumNotRecomputedOnResume can hold only for new attempts.
- Golden fixtures missing from C2 for formats that later milestones import:
- LocalFingerprintCache JSON (P5);
- TimelinePlaces JSON with its hashed file name (F5);
- a v1 widget cache PNG and metadata pair, plus the Flutter widget keys (W4);
- a legacy share descriptor {id: sha256 identity, receipt} in both /var and /private/var forms (B5/B6);
- a v1 thumbnail directory tree (T1).
- Fingerprints: the per-account IlyichFingerprints/<digest>.json files go into a device-scoped device_fingerprint table. Specify whether every account's file is imported (checksums don't depend on the account) or only the active one, and when the others are deleted.
- Network configuration: the register's "loading drops invalid entries", attributed to C5 though C5's scope never mentions it, must not rewrite the stored Keychain JSON, or the user's proxy headers are silently lost. Keep the stored data and drop invalid entries in memory with a warning.
- Share retries: B4's deterministic identity reuses <identity>.multipart and .receipt on every retry. Acknowledge or delete the earlier outcome before resubmitting, so a stale failed outcome isn't replayed the way it is today.

### Behavior at risk

- DESIGN 13, "a photo opens on its cached preview or its grid thumbnail": broken from T1 until T6, because T1 removes the latest/decoded caches that ViewerPhoto and the feature tiles read.
- DESIGN 6, "the whole library is kept on disk", and T7's offline gate (zero network thumbnails in airplane mode). Q5's default adds partners shown in the timeline to the library, but T5's coverage default covers only the owner's own timeline. Partner photos are never covered, so offline jumps into months with partner photos miss.
- DESIGN 6, pinching changes density during the gesture: testPinchingChangesDensityWhileTheFingersMove (UITests/LibraryTests.swift:95) isn't pinned in T2, T3 or T6, although cells become passive in T2 and T6 stops preheating on density change.
- DESIGN 6 crossfade under Reduce Motion: PhotoGrid skips the 0.18 s crossfade when Reduce Motion is on (PhotoGrid.swift:700-702). T2's ThumbnailBinder spec drops that rule.
- DESIGN 7 and PARITY 3040020, "the old photos remain visible until new buckets or results are ready; errors retain them for Retry/Clear": F4 commits on failed months and after a 1.5 s timeout, replacing the frozen feed.
- DESIGN 9, "the places kept on the phone show straight after launch": lost if F5's import can't map hashed file names, or if month_places rows are fenced by an epoch that moves on read-only or elevation toggles.
- DESIGN 11, "until the offline library has synced, the place's photos are found by search": the contracts keep Unsupported.placeNeedsIndex and Q5 deletes the silent fallback, but no test pins that a place requested before the index completes falls back to serverSearch with the noMonths limitation.
- DESIGN 11, photo location returns to the focused Earth: N1 and N3 delete onExploreLocation and pendingLocation without listing testPhotoInfoLocationOpensFocusedInteractiveEarth (UITests/LibraryTests.swift:453).
- In-month order: Q3 switches index-routed months to server order, but F3's merged projection re-sorts them by date then id. The library shows one order with phone photos merged and another without.
- PRODUCT, "Do not fabricate ... counts absent from the API": F1 shows a server total while Q4's post-filters (owner, developed within the 20k scan budget, and the defensive drop of locked and trash-mismatched items) remove results on the client. The total then overstates what is shown.
- Widgets: S0's `visibility: timeline` also drops archived photos from the Random and album widgets, which can show them today. PF2 only requires excluding locked and hidden. Section 7 doesn't list this change, and only album widgets are an owner question.
- Searching within Recently added: Q4 makes createdAt order unsupported, so a search that returns results today becomes an explicit error. Neither section 7 nor the owner questions list this lost capability.
- Read-only: C6's acceptance ("pauses and resumes backup") changes today's behavior. SettingsView calls pause() with disableAutomatic=true, which persists automatic=false, and the footer says "Backup stays paused until you start it again". The behavior change and the copy change are both unlisted.
- Q6's "a sync reset keeps revision-valid thumbnails" ends today's wipe on reset, so thumbnails of assets whose access was lost through a reset stay on disk. This privacy change is unlisted.
- W4: the 60 s debounce and skipped background reloads leave server-deleted photos on home-screen widgets until the next timeline, and the memory widget now obeys memories.enabled. Neither change is listed.
- Every build is installed on the owner's phone, yet several milestones ship defaults for owner questions that are still open:
- Q3's in-month order;
- Q5's partners in the library;
- F4's 1.5 s commit;
- B9's retry and queue semantics;
- C7's sign-out data policy;
- S0's settings placement;
- P5 keeping a phone copy local-only when its server copy is trashed or archived.
A wrong default lands on the working installation before sign-off.

### Corrections

- S0: add the privacy half of SEARCH-1. In LibraryStore.loadResults, send visibility {eq: timeline} whenever searchFilter.visibility is nil (the unfiltered library, findSimilar and place search), and drop any result whose visibility is locked. Move testElevatedSessionSearchCannotShowLockedPhotos from Q4 to S0; Q4 later replaces this with ServerSearchRequest.
- S0: add the one-time WidgetCache purge and reloadAllTimelines. Exclude only locked and hidden assets, as PF2 requires, and keep archived photos until the owner decides. Otherwise list "archived photos in the Random and album widgets" in section 7 and the owner questions.
- S0, optional: apply commit 9bcdcd94f's nonisolated change-block builder to the favorite block at LocalPhotoActionsView.swift:79 only, since favoriting deletes nothing. Leave deletion to P1.
- P1: put Free up space's Remove behind a flag that stays off until P4. Replace the acceptance line "used only with disposable media" with "Remove is disabled on the phone until P4".
- Fix the dependencies:
- P4: add C7.
- P5: add P4 and F3, or define DeviceSnapshot in C2's contracts.
- W1: add C6.
- T7: add B9.
- C5: add C4, so the baseline and signposts exist before any behavior change.
- DS4 and P4: add "visibility != locked", per the owner default (archived copies count). Decode visibility (and isOffline) in BackupRemoteAsset or RemoteCopyVerifier. Add a test that, with an elevated session, a receipt whose server copy is in the Locked Folder is excluded.
- DS11: make invalidation per item.
- A receipt change drops only the local IDs whose receipts changed.
- New receipts for assets outside the scan change nothing.
- A server LibraryChange drops only candidates whose IDs it contains.
- Only settings, access-generation, account or token changes invalidate the whole scan.
Add a test that an upload finishing mid-scan does not block Remove.
- P4 device gate: add
- a Live Photo pair;
- a backed-up photo moved to the Locked Folder on the web (must be excluded);
- an iCloud Shared Album asset (notDeletable);
- a photo edited after the scan but before Remove (must return .changed with zero deletions).
- P4: state that until B9, local deletions are recorded only in the device_mutation journal. Add the B9 import step that sets receipts.local_deleted_at from that journal.
- B1:
- Run the shadow import only when the runtime opens or the app comes to the foreground, plus from a Diagnostics compare action, never on each state.json write.
- Add current/suspended stages and the engine intent to the zero-mismatch acceptance list.
- B5: land check-single-engine.sh here, with BackgroundUploads allowlisted, plus a test that TransportRegistry is never instantiated in the app target before B9.
- B8: activate on every AccountManager transition to the active phase, not once at launch. Add a test that signing out and back in without relaunching shows the new account's backup state.
- B9:
- Keep state.json in place, tracked by digest, until B10 instead of renaming it, or make "no pre-B9 build will be reinstalled" a hard gate before B9.
- Specify the RunIntent mapping, the classification of legacy outcomes and the handling of legacy stages without a checksum, each with a BootTests case.
- B10:
- Gate on "no un-imported <group>/Backup/*/state.json remains". (Met: the phone check on 2026-10-29 found no state.json at all; C8.)
- Schedule removal of the P5, F5, W3 and W4 importers here or in a final cleanup milestone, and add them to section 9. (Done: C8 removed the P5, F5 and W3 ones, W4's was never built, and section 9 lists each.)
- Q2:
- Add index_state.maintained_through (for example a hash of the acknowledgements table) and re-run the backfill when it doesn't match.
- If maintaining a derived row fails, set isQueryable=false and keep committing entities; never fail the sync batch.
- Q3/Q6:
- Persist pending accessLost IDs in the batch transaction and clear them only after the media purge.
- Consume a legacy accessInvalidated='1' once with a full reconcile.
- Define T1's orphan sweep as removing files whose asset is absent from a complete asset_index, and run it after every sync reset.
- T1:
- Remove only thumbnail-tier entries; keep preview and full-size entries in MediaPipeline.latest and decoded.
- Rewire the thumbnail lookups at ViewerPhoto.swift:41 and FeatureSupport.swift:28/46/98 to DecodedThumbnailCache in T1 itself.
- When an indexed file can't be read, delete its row and treat it as a miss; if index.sqlite is missing, rebuild it.
- F3: insert local-only entries into the remote order by date without re-sorting remote rows. Replace MergedTimelineTests' "date then id" assertion with testMergedMonthKeepsServerOrder.
- F4 and F6:
- If the first months fail, keep the old feed with Retry and Clear, as the pinned test expects. Apply the timeout commit only to slow months, never failed ones, and only after the owner answers.
- Replace F6's "unchanged assertions" with a list of the rewritten tests (LibraryStoreTests:171 place key; 446 and 464 TimelineCache; F4's replacement tests), each mapped to an index-backed equivalent.
- Authorization: split the epoch.
- An access generation (account, token, accessLost) fences reads, caches and persisted rows such as month_places and the thumbnail index meta.
- A write generation (read-only, password change) fences writes and uploads.
- privateEpoch covers locked media only.
State that a read-only toggle or a Locked Folder unlock never discards library reads.
- Q5/T5: make T5's default coverage scope match the library preset, including partners if Q5 adopts them, or gate Q5's partner default on the coverage answer. Add a partner-photo case to T7's offline gate.
- Pin these tests:
- testPinchingChangesDensityWhileTheFingersMove in T2, T3 and T6;
- testPhotoInfoLocationOpensFocusedInteractiveEarth in N1 and N3;
- "a place before index completion falls back to serverSearch with noMonths, never Unsupported" in Q4 and Q5;
- "no crossfade under Reduce Motion" in T2.
- T4 and F6: port PerfScenarioDriver from LibraryStore.scroller and GridScroller to GridViewport and TimeRailController, so T7 can still run C4's scenarios.
- F1: show no match count whenever the QueryPlan carries ownerPostFilter or developedPostFilter, or the defensive filter dropped items.
- Add owned services for the views in the first uncovered clause:
- SignInModel, with a debounced probe and OAuth, plus an off-main NetworkConfigurationService (C7, or C5 for the configuration service);
- an AccountSettingsService for name, password, PIN and profile image (C7 or N4);
- album activity added to N4's CollectionsService;
- edit save and revision polling in N2's LibraryMutationService;
- globe warm-up in N1's LibraryScreenModel.
- N2: list every collection screen that applies MutationResult or LibraryChange, with one test per kind: folder grid delete, Locked Folder grid Move to Timeline, Trash restore, Duplicates resolve.
- W4/W5:
- W4: purge the Flutter widget keys only after the owner confirms no Flutter build shares the app group, or defer the purge until the native app passes parity (PRODUCT.md:19).
- W5: repeat C1's on-phone check that the app group resolves.
- Q3: before seeding DependentRepairer with "assets without EXIF", count them on the phone in Diagnostics and cap the backlog. Repaired rows must be written in the sync payload shapes (AssetExifV1, AssetFaceV3, AssetOcrV1), with an equivalence test against the seeded e2e server.
- C2: add the missing golden fixtures (fingerprint cache, places JSON with its hashed name, widget cache v1 and Flutter keys, legacy share descriptor, v1 thumbnail tree).
- Add tests:
- N1 UI tests for immich://memory, immich://activity, album, person and share links, plus a cold-launch link.
- An F5 UI test for PeoplePager's numbered pages.
- A regression test for 3040019: a person-timeline query on a 60k fixture stays within budget (Q3).
- A C4 scenario for 3040030: the first shelf open causes no hang of 250 ms or more.
- Owner questions:
- Add: archived photos in the Random widget; search within Recently added; thumbnail retention across a sync reset; read-only off resuming backup; rollback policy for the Q2, T1, W3, W4 and B9 formats.
- Put every defaulted behavior change behind a flag until its question is answered.
