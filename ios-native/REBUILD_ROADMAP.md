# Native iOS rebuild roadmap

Working roadmap for [IOS_ARCHITECTURE_PLAN.md](../IOS_ARCHITECTURE_PLAN.md), from a read-only map of the code on 2026-10-20. Milestones run in dependency order; each must build, pass its tests and install on the phone. The critic's corrections at the end apply before the milestones they name.

## Target architecture

TARGET ARCHITECTURE (native iOS rebuild)\n\n0. RULES\n- One owner per piece of state. Views render values and send commands. Services own their Tasks; a service cancels its Tasks when it ends.\n- A device-scoped singleton exists only where iOS allows one per process:\n  - background URLSessions (TransportRegistry);\n  - BGTaskScheduler registration (LifecycleEventSource);\n  - the PhotoKit change observer and caching image manager (PhotoKitAdapter);\n  - the Google Cast context.\n  Everything account-specific lives in one AccountRuntime per signed-in account, torn down in a fixed order.\n- Nothing runs on the main actor that touches SQLite, the Keychain, file enumeration, PhotoKit fetches or image decoding. SQLite, ImageIO and PhotoKit work runs on dedicated serial queues used as custom executors, never on the cooperative pool.\n- Any result that can outlive a change of account, token, read-only state or Locked Folder elevation carries an AuthorizationEpoch. Stores commit only results whose epoch is current.\n- Persisted formats stay byte-identical, or an idempotent importer pinned by golden fixtures migrates them.\n- One execution engine per subsystem in every build. A replacement lands in the same milestone that deletes its predecessor. Temporary adapters are listed in section 9 with the milestone that removes each one.\n\n1. COMPONENTS (owner, executor, inputs and outputs)\n\nDEVICE SCOPE\n- IlyichAppDelegate (main). In didFinishLaunching it synchronously:\n  - registers the BG tasks;\n  - creates TransportRegistry, BackgroundEventAcks and PhotoKitAdapter;\n  - starts AccountManager.restore in an owned Task.\n  handleEventsForBackgroundURLSession calls acks.register FIRST, then touches registry.transport(id).\n- LifecycleEventSource (main).\n  - Inputs: BGTaskScheduler, NWPathMonitor, battery, thermal state, Low Power, app state.\n  - Output: AsyncStream<LifecycleEvent>.\n  - schedule(SchedulePlan) is called only by the TransferEngine.\n- TransportRegistry plus one BackgroundTransport per TransferSessionID (backup, share-upload). Each runs on a serial delegate OperationQueue. It accepts submit(request, bodyURL, AttemptKey) and returns a task id. The delegate atomically writes an Outcome file before it yields .finished. Outputs: a TransportEvent stream (progress, finished, drained) and inventory().\n- BackgroundEventAcks (main). Queues system completion handlers per identifier. Each handler runs after the engine commits that session's outcomes, or after a 20 s deadline.\n- PhotoKitAdapter: actor on DispatchSerialQueue app.ilyich.photokit (.userInitiated).\n  - The only PHPhotoLibraryChangeObserver. Bursts are coalesced over 250 ms and published as DeviceLibraryChange.\n  - access with a generation number; reads; staging export; perform(DeviceMutation).\n  - Media requests (image, playerItem, livePhoto) are nonisolated and use one shared PHCachingImageManager.\n  - Mutations are journaled in DeviceDatabase.\n- DeviceDatabase: Application Support/IlyichDevice/device.sqlite, on its own queue. Tables: device_mutation, device_fingerprint.\n- AccountManager: actor.\n  - Phases: restoring, waitingForUnlock, signedOut(reason), passwordChangeRequired, active, signingOut.\n  - Transitions are serialized. Opens and tears down the AccountRuntime.\n- GCK CastContext (main), set up at launch.\n\nACCOUNT SCOPE: AccountRuntime, a Sendable final class opened off-main\n- AuthorizationState: a Mutex snapshot with an epoch and an updates stream. Writes the App Group mirror keys account.digest and account.authorizationEpoch, and keeps the access epoch beside them in account.accessEpoch.\n- ServerTransport (actor) with ServerConnection (actor, in the package). APIClient remains as the endpoint catalogue over the transport. One set of URLSessions per runtime, invalidated at shutdown.\n- ServerCapabilities (actor). SyncEngine (actor): the only writer of SyncStatus; publishes LibraryChange.\n- LibraryIndex, over the existing entities file:\n  - IndexWriter on serial queue ilyich.index.writer (.utility), owning the only read-write connection;\n  - IndexReader.viewport (.userInitiated) and IndexReader.aggregate (.utility), each with its own read-only connection;\n  - DependentRepairer (actor).\n- LibraryRepository: QueryPlanner, ServerTimelineBackend, ServerSearchBackend and the offline fallbacks. Returns Fenced results.\n- LibraryChangeHub (actor). Gives each subscriber a merging mailbox and never drops a change.\n- MediaPipeline (actor). Previews, full-size images, faces and locked media only.\n- ThumbnailService:\n  - ThumbnailDiskStore (actor on its own queue);\n  - DecodedThumbnailCache (Mutex LRU);\n  - ThumbnailScheduler (actor);\n  - ThumbnailFetcher;\n  - DecodeLanes: 3 serial .userInitiated queues and 1 .utility queue;\n  - CoverageWorker (actor);\n  - DeviceThumbnailSource (main).\n- Transfers:\n  - TransferStore: actor on its own queue, Application Support/IlyichTransfers/<digest>.sqlite. Private container: never the app group, to avoid 0xdead10cc.\n  - TransferEngine: actor with one owned loop.\n  - PostUploadWorker (actor), TransferNotifier (main).\n  - LegacyBackupImporter, until B10.\n- ReceiptRepository (TransferStore). CleanupService (actor) with RemoteCopyVerifier. DeviceIndexService (actor).\n- LibraryMutationService (actor), CollectionsService (actor), MediaExportService (actor).\n- Cast: CastGrantStore (actor) and CastSessionService (main).\n- WidgetRefreshCoordinator (main). OwnedWork (actor): cancelAndJoin at shutdown.\n\nPRESENTATION (main actor, account-scoped)\n- AccountSession, SignInModel, SettingsCatalog.\n- LibraryScreenModel:\n  - LibraryNavigator and PresentationHost;\n  - LibraryFeedStore: FeedSession, TimelineFeed (actor), SearchFeed (actor), MonthProjector (@concurrent), MonthPlacesService (actor);\n  - FeedSelection, CollectionsStore, PeopleDirectory and PeoplePager;\n  - GridViewport, TimeRailController, ThumbnailBinder.\n- ViewerModel, BackupStore, ShareInboxModel, FreeUpSpaceStore, DeviceBrowserStore, DevicePhotoActionsStore, LockedFolderSession.\n\nEXTENSIONS (local package Packages/IlyichKit, Swift 6)\n- IlyichPlatform: AppGroup, AccountID, AccountStoragePaths, CredentialStore, NetworkConfiguration and its stores, ServerConnection, ReadOnlyPolicy, AuthorizationMirror.\n- IlyichShareInbox: manifest v1 reader and v2 writer, ShareInboxRepository, ShareStaging, PhotoResourceExport.\n- IlyichWidgetCore: WidgetMediaClient, WidgetTimelinePlanner, WidgetSnapshotStore.\n- The Share extension uses ShareInbox and Platform, with no credentials and no networking. The Widget uses WidgetCore and Platform.\n\n2. CONTRACTS (Swift sketches)\n\nIdentity and authorization\n- AccountID { server: URL /*normalized, ends in /api*/; userID; cacheScope = server.absoluteString+'|'+userID; digest = sha256hex(cacheScope) == SavedSession.scope }\n- AccountStoragePaths: the only place per-account names are derived. A test pins each name to today's code: IlyichEntities/<digest>.sqlite, Caches/IlyichThumbnails/<digest[0..<32]>, IlyichMedia/<digest>, <group>/Backup/<digest>, <group>/WidgetCache/<digest>, readOnly.<sha256(normalized|user)>, the locked PIN account, shelfOrder.<kind>.<cacheScope>.\n- StoredCredential: byte-equal to the SavedSession v1 JSON.\n- protocol CredentialStore { load() throws(CredentialError) -> StoredCredential?; save; remove }\n- CredentialError { signedOut, locked, missingEntitlement, keychain(OSStatus), corrupt }\n- struct AuthorizationEpoch: Hashable, Sendable { account: AccountID; value: UInt64 }\n- struct AuthorizationSnapshot { epoch; tokenDigest; readOnly; requiresPasswordChange; privateEpoch; func allows(_ op: Operation) -> Bool }\n- struct Fenced<V: Sendable> { epoch; value }\n\nFailures\n- enum ServerFailure: sessionExpired(String?) (a 401 with an Immich error body) | credentialsRejected(String) (a 401 on auth/login or oauth/callback; the server text is shown) | proxyRejected(Int) (401/403/407 without an Immich body) | forbidden(String?) | notFound | http(Int,String?) | undecodable | readOnly | passwordChangeRequired\n- enum TransportFailure: unreachable(URLError.Code) | endpointChanged | allEndpointsUnavailable | systemCancelled(reason: Int?)\n- enum FailureClass: transient(retryAfter: Duration?) | waiting(WaitReason, jobScoped: Bool) | account(AccountRestriction) | item(String)\n- WaitReason: deviceConditions | unmeteredNetwork | connectivity | serverBackoff\n- AccountRestriction: signedOut | sessionExpired | proxyRejected | readOnly | passwordChange | photosAccess | deviceStorage\n\nLibrary\n- MonthKey { year, month; init?(bucketID:); bucketID = YYYY-MM-01 }\n- AssetRevision { referenceSeconds: Double } stores PHAsset.modificationDate bit-exactly.\n- struct LibraryQuery: Hashable, Sendable\n  - Scope: library (me + partners with inTimeline) | mine | partner(id) | album(id) | person(id) | place(PlaceMembership)\n  - Trash: active | trashed\n  - Visibility: OptionSet of timeline and archive; hidden and locked cannot be expressed.\n  - Ranking: chronological(takenAt|createdAt, ascending) | relevance(text(q, mode, language) | similar(to:))\n  - Stacks: primaryOnly | all\n  - Predicates: favorite, developed, kind, motion, people, tags, inAnyAlbum, rating, taken, camera, location, text\n  - Presets: library, favorites, archive, trash, recentlyTaken, recentlyAdded, lightroom, videos, motion, partner, album, person, place\n  - refined(text:mode:) and similar(to:) keep scope, trash, visibility, stacks and developed.\n  - stableKey: the library's key equals today's TimelineFilter key.\n- LockedFolderQuery: served only by the server timeline, and only under an elevated epoch.\n- PlaceMembership { placeID; revision = sha256(sorted ids + marker query); assetIDs }. Equality and hashing use placeID and revision.\n- QueryPlan { backend: index|serverTimeline|serverSearch; limitations: Set<Limitation> }\n- Limitation: noMonths, includesStackMembers, excludesSharedAlbumMembers, ownerPostFilter, developedPostFilter(scanBudget:), indexStale(since:)\n- Unsupported: placeNeedsIndex, orderNotSearchable, predicate\n\nChanges\n- struct LibraryChange\n  - Identity: account; authorization; indexRevision; origin (sync | mutation(OperationID) | device).\n  - Assets: upserted [id: MonthMove]; removed; accessLost; mediaRevisions [id: rev].\n  - Collections: albums; people; stacks; collections [CollectionChange].\n  - Flags: partnersChanged, memoriesChanged, reset, routingChanged, configurationChanged, overflow.\n  - merge(_:)\n- CollectionChange: albumCreated | albumUpdated | albumDeleted | albumLeft | personUpdated | partnersChanged | memorySaved\n- enum MutationRequest: favorite, visibility, trash, deletePermanently, restore, restoreAllTrash, emptyTrash, addToAlbum, removeFromAlbum, setAlbumCover, createAlbum, stack, unstack, removeFromStack, setStackCover, update, rating, tag, reassignFace, removeFace, edits, resolveDuplicate, dismissDuplicate\n- MutationResult { operation; request; succeeded; failed [id: reason]; fresh [id: Asset]; followUp: LibraryChange? }\n\nDevice\n- DeviceAssetID and DeviceAlbumID: raw localIdentifier.\n- DeviceAccess { status, generation }\n- ResourceShape: singleOriginal | livePhoto | edited | multipleOriginals | other. classify(types, isVideo) is pure.\n- DeviceAsset { id, revision, created, isVideo, isLive, isFavorite, location, shape, canDelete, canEditProperties }\n- DeviceLibraryChange { access, inserted, removed, changed, albumsChanged, requiresFullReload }\n- DeviceMutation: delete(ids, expected [id: AssetRevision], origin) | setFavorite(ids, Bool, expected) | create(still, video, pairedVideo, origin)\n- MutationOrigin: user | cleanup(scan, account) | saveFromServer(asset, account)\n- DeviceMutationResult outcome: committed(affected, created) | declined | revisionChanged | notPermitted | failed\n\nTransfers\n- TransferLane: library | share\n- TransferSource: photo(localID) | shared(batch, attachment)\n- JobOrigin: discovery | selection | albumUpload | shareApproval | legacy\n- JobState: queued, staging, staged, submitting, submitted, finalizing, retryScheduled, waiting, failed\n- RunIntent: paused | automatic | manual. It gates only the library lane.\n- Lease { job, token, epoch }\n- AttemptID: a UUID. A legacy stageID or share identity is kept verbatim.\n- TransferSessionID.identifier = Bundle.main.bundleIdentifier + .backup | .share-upload (on the phone: app.alextran.immich.H4K2MSF2SG.*)\n- TaskDescriptor\n  - v2: {v:2, attempt, scope, outcome: path relative to the app group}\n  - legacy: {id, receipt: absolute URL}, resolved by locating the Backup/ or ShareInbox/ path component\n  - foreign\n- OutcomeRecord: the legacy keys {receipt, error, httpStatus} plus optional errorDomain, errorCode, cancelReason and v.\n- protocol TransferTransport { submit; results(); acknowledge(key); inventory(); cancel(scope:); progress() }\n- protocol TransferServerAPI { bulkUploadCheck; uploadRequest; remoteAsset(strict, no offline fallback); livePhotoVideoID; setLivePhotoVideo; createStack; addToAlbum; ownedAlbums; createAlbum }\n- protocol PhotoLibraryStaging { authorization; albums; candidates(stream of (id, revision) batches); stage(id, into, stageID, policy, progress); albumMembers }\n- TransferSnapshot { intent; phase; remaining; confirmed; failed; fileProgress; bytesSent; bytesExpected; bytesPerSecond; lastMessage }\n- EnqueueResult: queued(n) | alreadyBackedUp(n) | refused(AccountRestriction)\n- protocol TransferControlling: setIntent, enqueue, cancel, setPreferences, retry, snapshots, queuePage, historyPage, failures, albumUploadCounts\n\nLifecycle\n- LaunchReason: user | backgroundTask | urlSessionEvents(id)\n- EnvironmentSnapshot { appActive, network: none|unmetered|expensive|constrained, charging, thermal, lowPower }\n- LifecycleEvent: window(BGTaskLease) | becameActive | enteredBackground | environment | photoLibraryChanged | urlSessionEvents | preferencesChanged | readOnlyChanged\n- BGTaskLease.expire() calls setTaskCompleted(false) synchronously, with no await.\n\nThumbnails\n- ThumbnailKey: server(assetID, revision) | device(localID, modified)\n- DecodeTier: sketch < scrub < grid\n- ThumbnailRequest { key, thumbhash, shortSide }\n- DemandBand: visible < target < ahead < explicit < behind < coverage\n- Motion: idle(since) | tracking(speed) | flinging(speed) | scrubbing\n- ViewportDemand { generation, items [(request, band, rank)], motion }\n- ThumbnailInvalidation: assets(ids) | revoked(ids) | account | reconcile\n\nFeed\n- FeedSectionKey: month(MonthKey) | results\n- MonthProjection { key, entries, ids, dayGroups?, placeSummary? }\n- MonthState: unloaded | loading | loaded | failed\n- FeedSnapshot\n  - sessionID changes only when the scope changes.\n  - structure increments when counts or order change; the grid reloads and restores its anchor.\n  - content increments when only cells need reconfiguring.\n  - Also carries sections, months, results and totalCount.\n- protocol TimelineSource { plan; summary; month; monthPlaces }\n- protocol SearchSource { smart; metadata }\n\nNavigation\n- ModalRoute: viewer(ViewerRoute) | phoneViewer | people | albums | more(path) | memories(initialID) | activity(album, asset) | searchOptions | settings(SettingsRoute) | albumEditor | albumSharing | selectionActions(snapshot) | newAlbum | sharedFiles | confirm\n- ViewerRoute { initialAssetID, source: AssetSourceID (feed | collection | stack | similar | single | locked), albumContext }\n- SettingsRoute: root, account, backup, appearance, grid, network, notifications, server, diagnostics, about\n- NavigationIntent: present | openAsset | showInTimeline | exploreLocation | apply(query) | openShelf\n- LibraryOverlay: none | shelves | earth\n\nCapabilities\n- AssetCapabilityPolicy.evaluate(asset, context) -> [AssetAction: offered | disabled(reason) | hidden]\n- context = viewer, authorization snapshot, features, origin, cast availability, local copy.\n\n3. STORES\n\nTransfers DB (per account, private container, WAL, synchronous=FULL, completeUntilFirstUserAuthentication, excluded from backup)\n- Engine and settings:\n  - meta(schema, legacy_import_digest, engine)\n  - preferences(id=1, json)\n  - engine_state(intent, blocker, last_message)\n- Jobs and attempts:\n  - jobs(id, lane, source_key, origin, state, seq, not_before, retry_count, phase, error fields, lease_token, lease_epoch, batch_id; UNIQUE(lane, source_key); index on lane, state, not_before, seq)\n  - stages(job_id, stage_id, folder relative to the app group, modification_date REAL, file jsons, fields_json, motion_remote_id, motion_checksum, original_checksum)\n  - attempts(id PK = attempt/stage id, job_id, part, session, state created|bodyWritten|submitted|interrupted|completed|failed|abandoned, body_path, body_bytes, checksum, os_task_id, remote_id, remote_status, http_status, error_domain, error_code)\n- Results:\n  - confirmations(local_id, modification_date REAL, confirmed_at)\n  - receipts(local_id, modification_date REAL, original_id, original_checksum, original_bytes, motion_id, motion_checksum, motion_bytes, confirmed_at, verified_at, local_deleted_at)\n- Follow-up work:\n  - album_destinations(local_id, album_id, remote_id, state, attempts, error)\n  - stack_tasks\n  - linked_albums\n  - share_consumed\n  - notification_batches(id, kind, total, completed, failed, started_posted, terminal_posted)\n- Dates are always REAL timeIntervalSinceReferenceDate, written with sqlite3_bind_double.\n\nDevice DB\n- device_mutation(id, account_digest, kind, origin, asset_ids, expected_revisions, created_at, finished_at, outcome)\n- device_fingerprint(local_id PK, revision REAL, checksum)\n\nLibrary index (the existing IlyichEntities file)\n- user_version 0 -> 1 adds:\n  - asset_index, with columns ordered the way the server sorts;\n  - album_member, person_member, locked_asset;\n  - orphan_dependent, dependent_repair;\n  - index_state (revision, backfill cursor);\n  - month_places.\n- Payloads, metadata and acknowledgements are untouched, so no re-sync.\n\nThumbnail index\n- index.sqlite in the existing thumbnail root: meta(epoch, usage, index_complete, coverage_cursor, coverage_mark, policy_hash) and thumbnail(stem, digest, tier, bytes, stored_at, last_access).\n- Files stay at <root>/<stem2>/<stem>.<revdigest16>.\n\nStaging and outcomes\n- Legacy layout stays valid: <group>/Backup/<digest>/<folder>/{original,motion,sidecar,<id>.multipart,<id>.receipt}\n- Shares: <group>/ShareInbox/<batch>/{manifest.json,<identity>.multipart,<identity>.receipt}\n- Multipart boundaries stay Ilyich-<attemptID> for backups and the identity for shares.\n\n4. FLOWS\n\nBoot (every launch reason)\n1. Register BG tasks synchronously.\n2. AccountManager.restore. A locked keychain gives waitingForUnlock, retried on protectedDataDidBecomeAvailable.\n3. AccountRuntime.open off-main.\n4. TransferStore.open, then the importer (authoritative from B9).\n5. TransportRegistry.connect, then Recovery.reconcile, then apply outcomes, then ack drained sessions.\n6. SyncEngine starts (foreground only). Feeds open from the index.\n\nDelegate events never need the database: outcomes are files, so a session created before the import is safe.\n\nSync\n1. SyncEngine pass.\n2. IndexWriter commits one transaction per batch: entities, derived rows and acks together.\n3. A precise LibraryChange goes to the hub.\n4. Consumers act:\n   - TimelineFeed invalidates the months touched;\n   - SearchFeed prunes results;\n   - the thumbnail and media services forget removed assets and purge assets whose access was lost;\n   - DeviceIndexService, CollectionsStore, WidgetRefreshCoordinator and ViewerModel update.\n\nMutation\n1. A store command calls LibraryMutationService.start. The service owns the Task.\n2. One HTTP call. Bulk results allow partial success.\n3. Precise media invalidation.\n4. The hub publishes. The feed applies FeedMembership.\n5. The result of the follow-up sync pass is merged in.\n\nViewport\n1. Scroll delegate and rail pan go to GridViewport (motion EMA, fling target, ahead/behind windows, pins).\n2. ViewportDemand, at most one per frame and also when a month becomes ready.\n3. ThumbnailScheduler: presence map, then nonisolated disk read, decode lane or fetch.\n4. Deliveries are buffered with one main-actor hop per frame. ThumbnailBinder updates bound cells.\n\nBackup job\n1. Rows are created, then the loop takes a lease.\n2. Stage through the adapter. Record the checksum once.\n3. For each part, motion first (hidden, without metadata) and then the still with livePhotoVideoId:\n   a. bulk-upload-check;\n   b. write the body;\n   c. write the attempt row as submitting;\n   d. transport.submit;\n   e. mark submitted.\n4. A result arrives, live or reconciled, and is classified.\n5. One commit transaction WHERE lease matches: delete the job and stage; upsert the confirmation and receipt; set album_destinations.remote_id; insert a stack task; increment the batch.\n6. acknowledge, which deletes the outcome file and the body.\n7. PostUploadWorker runs the side effects.\n\nURLSession relaunch\n1. Register the ack.\n2. The delegate writes outcome files.\n3. engine.applyOutcomes(id) commits.\n4. ack(id), or after the 20 s deadline. Unknown identifiers are acked immediately.\n\nSign-out\n1. Bump the epoch and the mirror.\n2. Cancel and join owned work.\n3. Within 3 s, while network credentials still exist: auth/logout and DELETE the cast session.\n4. Remove the credential (tombstone first), the widget cache, notifications and the locked PIN.\n5. Apply the data policy for the sign-out reason.\n6. Shut down the transport and clear diagnostics.\n7. Publish signedOut.\n\n5. FAILURE CLASSES\n- item: only the user retries. It covers:\n  - BackupError.item; HTTP 413, 415, 422;\n  - a bulk-check reject that is not a duplicate; a trashed duplicate;\n  - PHPhotosError identifierNotFound, invalidResource, missingResource, requestNotSupportedForAsset;\n  - networkAccessRequired while iCloud downloads are off;\n  - missing or corrupt files; a Live pair conflict.\n- waiting:\n  - device conditions: the whole engine waits;\n  - an iCloud original that needs Wi-Fi: only that job waits;\n  - notConnected, connectionLost, dataNotAllowed, roaming off: the engine waits for connectivity;\n  - three consecutive 5xx: serverBackoff.\n  Any condition event clears these, whether the intent is manual or automatic.\n- transient: timedOut, cannotConnect, DNS, TLS; 408, 425, 429, 500, 502, 503, 504; an invalid response; a system-cancelled outcome (force-quit). Backoff is 30 s x 2^n with 20 % jitter, capped at 1 h. Unknown errors are transient for 5 attempts, then item.\n- account: explicit and engine-wide; automatic triggers never clear it. Covers sessionExpired (live or replayed), proxyRejected, readOnly, passwordChange, Photos access denied, out of storage.\n\n6. INVARIANTS\n\nDeletion safety (CleanupService and PhotoKitAdapter)\n- DS1. An asset is deleted only if:\n  - it is in the in-app selection;\n  - it is in the live candidates of the current scan;\n  - iOS's own prompt was accepted.\n- DS2. A candidate needs a receipt in the current account, not marked locally deleted. Its revision must be bit-equal to the asset's modificationDate at scan time and again inside the change block.\n- DS3. The shape must be singleOriginal, or livePhoto with a motion receipt. Edited, alternate/RAW+JPEG, adjustment and multiple-original assets are never candidates.\n- DS4. A fresh strict GET with no offline fallback must show the same id, owner == user, checksum == receipt checksum and not trashed. A Live Photo also needs livePhotoVideoId == motion id, with the motion asset passing the same match. Any other verdict (404, 403, 5xx, transport error, decode error) excludes only that item. A 401 aborts the scan.\n- DS5. Remove re-verifies only the selection, immediately before perform. Any failure removes nothing.\n- DS6. The account digest, token digest, read-only off and the epoch are checked after re-verification and again immediately before perform.\n- DS7. The policy is re-applied with current settings and fresh kept-album membership. Unknown values fail closed.\n- DS8. The change block issues a request only if every asset exists, canPerform(.delete) holds and every revision matches. Otherwise it issues nothing.\n- DS9. The journal row is written before performChanges. Receipts are marked local_deleted_at only on a committed outcome. Interrupted entries are reconciled at launch.\n- DS10. A declined iOS prompt is .declined, never an error, and receipts are untouched.\n- DS11. A scan is invalidated by a settings change, an access generation change, an epoch change or a receipt change. A device change drops only the affected candidates.\n- DS12. Exactly one ReceiptRepository is authoritative. Freed bytes are never claimed.\n\nBackup migration\n- BM1. The import is one transaction and idempotent: the same digest is a no-op, a crash before commit leaves the file intact, and a crash after commit creates no duplicates.\n- BM2. Dates are bit-exact.\n- BM3. Every confirmation and receipt maps to one row. Queue order is preserved, current first.\n- BM4. Legacy stage IDs become attempt IDs. Paths are relative to the app group.\n- BM5. A success outcome finalizes the job with zero POST /api/assets.\n- BM6. Legacy OS tasks are adopted by stage id and never re-created.\n- BM7. No result is applied before the import commits.\n- BM8. state.json is renamed only after commit and deleted only in B10. An unreadable file is quarantined, never fatal. A later digest from a reinstalled old build is merged with upserts.\n- BM9. One engine, unchanged session identifiers.\n- BM10. Files are deleted only after commit and acknowledgement. The sweep never removes a referenced body or one bound to a live task.\n- BM11. The system completion runs only after the durable commit or the deadline.\n- BM12. A stale lease never commits.\n- BM13. Side-effect failures never undo a confirmation.\n\nPrivacy\n- PF1. Hidden and locked are unrepresentable in LibraryQuery. Every search states trash and visibility. A defensive filter drops locked items.\n- PF2. The widget never requests locked or hidden assets.\n- PF3. accessLost purges memory, files and URL cache synchronously and fences late writes.\n- PF4. Relock bumps privateEpoch and purges private media.\n- PF5. Cast is never offered for locked assets.\n\n7. CONTRACT BEHAVIORS AT RISK (protected by the named milestones)\n- DESIGN 6, downloads wait while photos pass fast: replaced by the target-first motion policy in T3, with an owner-approved DESIGN.md edit. Kept: a started download completes; whole-library offline coverage on unmetered networks (T5); stages memory, then another size, then sketch, then stored, then network, crossfading.\n- DESIGN 7, the unfiltered position survives clearing a filter: broken today, fixed in F4. Browsing never opens a second grid: SimilarPhotos is an owner question.\n- DESIGN 8, shelf choreography (N4) and DESIGN 9, rail open-before-move, hold, per-feed places shown straight after launch, one tick per month (T4, F5): pinned by the existing unit and UI tests.\n- DESIGN 11, a place before sync is found by search: kept as an explicit planner limitation (Q5).\n- DESIGN 13, viewer neighbors load ahead and a photo opens on its preview or grid thumbnail (N3, T6).\n- PRODUCT, no invented counts: today's search count is the loaded count; owner question, F1. PRODUCT, no main-thread decoding: today the sketch decodes on main; fixed in T1.\n- PARITY changes:\n  - 401 sign-out becomes confirmed session expiry only (C5);\n  - transient backup errors retry instead of needing attention; album failures no longer keep photos queued (B9);\n  - background backup's NativeSync gate becomes best-effort (B7);\n  - partner timeline inclusion takes effect (Q5);\n  - Cast is hidden for locked assets (W2);\n  - a Trash selection offers restore and permanent delete (N2);\n  - configured widgets must survive (W5);\n  - read-only off resumes backup and shared uploads (C6), only once the owner agrees;\n  - offline fallbacks keep their eligibility (Q4).\n\n8. INSTRUMENTATION\n- OSSignposter, subsystem app.ilyich.native. Interval and event names are stable because the scripts parse them.\n  - thumbnails: thumb.display {source}, thumb.placeholder\n  - scrub: rail.scrub, grid.fling\n  - feed: feed.month {backend}, feed.commit\n  - launch: launch.firstContent\n  - sync: sync.pass\n  - index: index.backfill\n  - transfer: transfer.stage, transfer.submit, transfer.commit\n  - memory: mem.footprint (phys_footprint)\n  - perf: perf.scenario\n- PerfScenarioDriver ships in Release builds. It is inert unless the app is launched with -IlyichPerfScenario.\n\n9. TEMPORARY ADAPTERS (introduced -> removed)\n- SessionKeychain facade: C1 -> W5\n- LegacyNotificationBridge, re-posting ilyichLibraryChanged and ilyichCachesReset: C7 -> N4\n- LibraryIndex facade keeping EntityStore's method surface: Q2 -> Q5\n- TimelinePlacesCache epoch fence: C6 -> F5 (cache deleted)\n- section-to-MonthKey mapping inside LibraryStore: F2 -> F6\n- Coordinator-based demand source and the warmer coverage-band adapter: T2 -> T3 and T5\n- LegacyStateReceipts: P4 -> B9\n- LegacyCoordinatorBackend: B8 -> B9\n- Shadow import mode: B1 -> B9\n- Importer, legacy mirrors and legacy descriptor and outcome decoding: B1/B5 -> B10\n- BackupCoordinator per-scope APIClient cache: C5 -> B9\n- SessionStore's interim sign-out rule (sign out only when a second validateToken confirms sessionExpired): C5 -> C7\n- AuthorizationState owned by SessionStore, which pauses the coordinators for read-only mode: C6 -> C7 (AccountRuntime owns it)\n- WidgetRandomSearchBody: S0 -> W5

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
  - Free up space is used only with disposable media until P4
- **As built:** the critic's flag turning Remove off until P4 was not added. S0 (3040055) already made Free up space delete for real, so the flag would take away a working action; P1 only adds the journal, the in-block checks and the declined-prompt mapping on top of every check it had. Whether to turn it off until P4 is an owner question.

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

### P4 — Cleanup service with explicit deletion-safety invariants

- **Workstreams:** 4. **Depends on:** P1, C5, C6. **Risk:** critical.
- **Scope:** Per-account CleanupService actor implementing DS1 to DS12:
- scan: local filter in batches of 250 through the adapter, then shape, canDelete, policy and kept albums; an optional exclude-only index prefilter; at most 6 concurrent strict remote verifications; per-item exclusions; a 401 aborts; byte counts recorded only if the receipt is unchanged;
- remove: re-verify only the selection, check the gate twice, then perform delete with expected revisions;
- results: declined, changed or removed; markLocallyDeleted only on commit.
Also: CleanupSettingsStore (same keys and messaging-album default); RemoteCopyVerifier with no offline fallback; ReceiptRepository plus the temporary LegacyStateReceipts adapter over BackupCoordinator (removed in B9); FreeUpSpaceStore, one per account, observing mutations(). FreeUpSpaceView only renders. Delete verifiedLocalDeletionCandidates and verifiedOriginalByteCount.
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

### N5 — Locked Folder session

- **Workstreams:** 8, 9. **Depends on:** N3. **Risk:** high.
- **Scope:** LockedFolderSession handles unlock by PIN, password or biometrics (LockedPINStore unchanged), the expiry timer, and relock on background or disappear through owned scene events. Paging is generation-fenced. Relock bumps privateEpoch and purges private media. The locked viewer source never touches library caches. Move to Timeline reconciles the feed.
- **Migration:** None. The PIN Keychain item is unchanged.
- **Tests:**
  - testBackgroundRelocksSynchronouslyAndPurgesPrivateMedia
  - testLateResultAfterRelockDropped
- **Acceptance:**
  - On the phone: PIN and biometric unlock work; relocked after backgrounding; locked photos never reach the feed or widget

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

### T7 — Scrubbing acceptance gate and scrub-tier decision

- **Workstreams:** 7. **Depends on:** T4, T5, T6, F6. **Risk:** medium.
- **Scope:** Run every deviceMeasurements scenario on the final stack. If disk-hit p95 misses the budget, add a locally transcoded scrub tier (about 3 KB per photo, DecodeTier.scrub, beside the v1 files); otherwise record the decision not to. Publish the numbers in the PARITY build log.
- **Migration:** Scrub-tier files only if the tier is added.
- **Tests:**
  - UI testDirectionReversalAndRelaunchShowDecodedOrStoredThumbnails
  - Release performance runs on the phone
- **Acceptance:**
  - Every measurement gate is met, or the owner accepts documented exceptions

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

### W5 — Native widget extension without Flutter sources

- **Workstreams:** 9. **Depends on:** W4. **Risk:** high.
- **Scope:** Rewrite Extensions/Widget in Swift 6 on the core, keeping the kinds, intent and entity type names, parameter names and the NONE and FAVORITES IDs. AlbumQuery resolves offline from the album directory. Add a widget asset catalog with a resizable logo. Give each extension its own entitlements. project.yml drops the ../mobile paths, the Swift 5 override and the app asset catalog. Delete the SessionKeychain facade and WidgetRandomSearchBody.
- **Migration:** Configured home-screen widgets keep their identifiers.
- **Tests:**
  - AlbumEntityQueryTests.testConfiguredAlbumResolvesOfflineFromDirectory
  - WidgetEntryViewTests.testErrorStateKeepsLogoAndMessageInsideSmallWidget
- **Acceptance:**
  - On the phone, existing random and memory widgets survive the update without reconfiguration (owner check); an offline album widget shows its cache; the error state is legible

### B10 — Retire legacy backup formats

- **Workstreams:** 2, 3. **Depends on:** B9. **Risk:** medium.
- **Scope:** Gates: at least 7 days on device, inventory shows zero legacy descriptors, and the owner confirms no older build will be reinstalled. Then delete LegacyBackupImporter, the backup mirrors in LegacyFormats, legacy descriptor and outcome decoding, the state.json.imported files and unreferenced legacy stage folders. Also retire W3's share-manifest v1 reader and stop writing the v1 url keys in v2 manifests, once no v1 manifest remains. An unexpected legacy descriptor is cancelled and logged.
- **Migration:** Irreversible deletion of state.json.imported, behind the gates above.
- **Tests:**
  - RecoveryTests on v2 only
  - testUnexpectedLegacyDescriptorIsCancelledAndLogged
  - Date bit-exactness tests kept
- **Acceptance:**
  - On the phone, backup continues normally and Diagnostics shows no legacy state

## Persisted state

- Session credential. Keychain service app.ilyich.native.session, account current, access group AppGroupId, AfterFirstUnlockThisDeviceOnly; SavedSession v1 JSON. KEEP byte-identical; read through CredentialStore (C1). Read by the app, the widget and upload delegates.
- Sign-out tombstone. App Group defaults session.signedOut. KEEP; written before delete, cleared after save.
- Authorization mirror. App Group defaults account.digest and account.authorizationEpoch. NEW in C6. Read by extensions and URLSession delegates; a missing or older value fails closed for writes. Beside them account.accessEpoch (NEW in C6), read only by the app at launch.
- Read-only flag. App Group defaults readOnly.<sha256(normalized server|user)>. KEEP key.
- Network configuration and client certificate. Keychain service app.ilyich.native.network, accounts settings:<sha> and certificate:<sha>. KEEP. Loading drops invalid entries instead of failing (C5).
- Locked-folder PIN. Keychain service Ilyich.LockedFolder.PIN, account sha256(cacheScope), biometry. KEEP (N5).
- Offline library database. Application Support/IlyichEntities/<digest>.sqlite: entities, metadata (session fingerprint, complete, needsReset, accessInvalidated, cached features) and acknowledgements. KEEP the file. MIGRATE the schema user_version 0 to 1 by adding derived tables with a resumable backfill (Q2); payloads untouched. Never force a re-login, because server checkpoints belong to the session.
- Server-side sync checkpoints for the login session. KEEP; no migration step may create a new session.
- Backup state.json. <AppGroup>/Backup/<digest>/state.json (BackupState JSON, deferredToDate dates). Shadow-imported in B1; authoritative import into Application Support/IlyichTransfers/<digest>.sqlite in B9, then renamed state.json.imported; DELETED in B10 after the gates.
- Staged sources, multipart bodies and Outcome receipts. <AppGroup>/Backup/<digest>/<uuid>/{original,motion,sidecar,<stageID>.multipart,<stageID>.receipt}. KEEP in place: stage IDs become attempt IDs and paths are stored relative to the app group. Outcome v2 adds optional errorDomain, errorCode and cancelReason. Swept only when unreferenced and unbound (B6). Legacy decoding retired in B10.
- Background URLSession identifiers Bundle.main.bundleIdentifier + .backup and .share-upload (on the phone app.alextran.immich.H4K2MSF2SG.*), and task descriptors. Identifiers UNCHANGED. Legacy {id, receipt} descriptors adopted by ID (B5, B6). v2 descriptors written from B9. Legacy decoding removed in B10 once none remain.
- BGTask identifiers app.ilyich.native.backup.processing and app.ilyich.native.backup.refresh, and UIBackgroundModes. KEEP. A coverage identifier is added only if the owner approves.
- Transfer notifications transfer.<UUID> and the terminal replay state. MIGRATE from state.json into notification_batches (B1, B9); IDs reused.
- Share inbox. <AppGroup>/ShareInbox/<batch>/manifest.json plus files and <identity>.multipart and .receipt. v1 READ; new batches WRITTEN as v2 with relative names (W3). v2 keeps every v1 key, so a rolled-back build still reads it; readers since W3 use only the names. Upload identity derivation unchanged. Manifest-less folders collected after 24 h.
- Transfers database. Application Support/IlyichTransfers/<digest>.sqlite. NEW in B1, in the private container (never the app group), excluded from iCloud backup. Holds jobs, attempts, receipts and the rest.
- Device database. Application Support/IlyichDevice/device.sqlite. NEW in P1 (mutation journal); fingerprints added in P5.
- Fingerprint cache. Caches/IlyichFingerprints/<digest>.json. IMPORTED into device_fingerprint, then deleted (P5).
- Thumbnail files. Caches/IlyichThumbnails/<digest32>/<stem2>/<stem>.<rev16>, about 0.7 GB. KEEP in place, plus a new index.sqlite (T1). Moving to Application Support is an owner decision.
- Media URL cache. IlyichMedia/<digest>. KEEP. Precise purges; cleared only on sign-out, Clear browsing cache, or when a lock purge cannot find the entry.
- Timeline month snapshots. Caches/IlyichTimelines. DELETED in F2; the index is the cache.
- Month places. Caches/IlyichTimelinePlaces. Epoch-fenced in C6; IMPORTED into the index month_places table and the folder deleted in F5.
- Shelf order. UserDefaults shelfOrder.people.<cacheScope> and shelfOrder.albums.<cacheScope>. KEEP.
- Cleanup settings. cleanupKeepFavorites, cleanupKeepMediaType, cleanupKeepAlbumIDs, cleanupCutoffDaysAgo, cleanupDefaultsInitialized. KEEP keys and semantics (P4).
- Viewer, share, grid and appearance preferences: gridColumns, timelineGrouping, hapticFeedback, appearance, accent, viewer*, imageLoadOriginal, shareFileType, shareDownloadCloud, slideshow*, albumLayout, mapDetailStyle, diagnosticLevel. KEEP.
- Coverage policy. UserDefaults thumbnails.coverage.v1. NEW in T5, defaulting to today's behavior.
- Widget cache. <AppGroup>/WidgetCache/<digest>/<key>_image.png and _metadata.json. IMPORTED into the v2 layout, then deleted (W4).
- WidgetKit configurations: kinds com.immich.widget.random and com.immich.widget.memory, intent and entity type names, parameters album, showAlbumName and forceFullColor, IDs NONE and FAVORITES. KEEP exactly (W5).
- Legacy Flutter widget keys widget_server_url, widget_auth_token and widget_custom_headers, plus root cache files. PURGED once, behind flag legacyWidgetCleanup.v1 (W4).
- Cast child session. Server-side only, never on disk. Revoked on stop, end and sign-out (W2). The GCK SDK's resume data is untouched.
- Mutation journal outcomes and receipts.local_deleted_at. NEW (P1, P4). Keep versus prune receipts after local deletion is an owner question.

## Risks

- Two execution engines during the backup cutover. They would corrupt staging and duplicate tasks. Mitigation: B2 to B7 are dormant; B9 deletes the old code in the same change, with a grep gate script and a device migration gate.
- Migration fidelity. A shifted modification date requeues the library and drops cleanup eligibility. Mitigation: REAL dates bound as doubles; golden fixtures from the production encoder; shadow import on the real phone first (B1); state.json kept until B10.
- Deletion of user photos. Mitigation: DS1 to DS12; property tests; the commit-time block check; Recently Deleted as the 30-day net; device gate with disposable media (P4). Free up space becomes operational at P1 with the strict legacy verification. Use only disposable media until P4.
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
- Thumbnail store stays in Caches: an iOS purge drops offline coverage. Mitigation: the coverage worker restores it; moving it is an owner decision.
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
- Should the order within a month follow the server (local day, capture time, file name) everywhere, so the offline and online order match? The plan defaults to yes.
- Search defaults: active photos only, with timeline visibility unless Library and archive is chosen; the match count shows server totals only (none for smart search). Agreed?
- Should offline thumbnails stay in Caches (iOS may purge them; coverage re-downloads) or move to Application Support with a visible size cap? Coverage scope: your timeline only (default), or also archive, partners and shared albums? Should a background coverage task be allowed?
- Proposed performance gates: disk hit p95 at most 50 ms; hitch ratio under 5 ms/s; peak memory at most 450 MB; cold launch to first real thumbnails at most 1.0 s p50. Accept or adjust?
- May the inert perf scenario driver ship in Release builds (it is activated only by a devicectl launch argument), or do you prefer a separate profiling IPA for measurements?
- Backup behavior changes, defaults:
- transient errors retry silently with backoff capped at 1 h;
- album-add failures no longer keep photos queued;
- enqueue is allowed while a backup runs;
- Back up selected no longer triggers full discovery;
- photos deleted from Photos leave the queue;
- failed items are shown apart from remaining.
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
- keep Free up space's Remove working until P4, as since S0 (default), or turn it off until P4's cleanup service lands, as the critic proposed;
- keep all-or-nothing when re-verification finds changes (default), or allow removing the rest after confirming;
- count archived server copies as backed up (default yes) and Locked Folder copies (default no);
- keep receipts after local deletion as history (default yes);
- cleanup settings device-wide (default) or per account.
- While a new filter loads, keep the old grid frozen for up to 1.5 s and then show the new feed with placeholders? Is SimilarPhotos allowed to keep its own grid, given DESIGN's one-grid rule?
- Navigation, defaults keep today's behavior:
- a viewer opened from More closes the sheet rather than stacking above it;
- deleting in the viewer dismisses rather than moving to the next photo;
- the two Trash experiences stay separate;
- web links are parsed but have no Associated Domains entitlement.
Change any?
- Locked media in the viewer: keep Download original, Share and Save to Photos (default), or hide them as Flutter does? Should album widgets include archived photos (default no)?
- Cast: is a grant cap of 6 h for long videos acceptable? Locked assets stay non-castable until the server offers asset-scoped grants.
- Will an older build ever be reinstalled after the backup cutover (B9)? This decides when state.json.imported can be deleted (B10, default 7 days after confirmation). Use iOS 27 BGContinuedProcessingTask for user-started backups? It shows system UI; default no.
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

- Plan line 24, "Views render state and submit commands. Services receive explicit dependencies and own their work outside the UI lifecycle." No milestone moves work out of these views:
- SignInView creates a new APIClient on every serverAddress change (SignInView.swift:105-110). Each one opens two URLSessions plus a probe session that are never invalidated, and reads the Keychain on the main actor. The view also runs OAuth itself (:134-143). Architecture section 1 lists a SignInModel, but no milestone builds it.
- NetworkSettingsView writes the Keychain and imports PKCS#12 on the main actor. C1 only moves the stores into the package.
- PINSettingsView calls PUT/POST/DELETE auth/pin-code (PINSettingsView.swift:52-60).
- AccountSettings, ChangePassword and ProfilePhotoView call users/me, change-password and DELETE users/profile-image (ProfilePhotoView.swift:47).
- AlbumActivityView calls POST/DELETE activities and PATCH albums/{id} isActivityEnabled (AlbumActivityView.swift:70-86). N4's CollectionsService does not cover these.
- PhotoEditor's save-then-poll-for-mediaRevision loop. N2 adds an `edits` request but not the polling.
- LibraryView's globe warm-up task.
- Plan line 78, "Collections handle deletion, restoration, locking and membership changes correctly." Only the main feed (F4 FeedMembership) and the shelves (N4 CollectionsStore) apply changes. N2 and N3 delete the onChanged/onDeleted closures, but no milestone makes any of these consume MutationResult or LibraryChange: FolderAssetsView, the Locked Folder grid, AlbumAssetsManager, DuplicatesView, TrashView, InfoCollectionView's place grid, SimilarPhotos, MemoriesView. After N2 those grids keep showing deleted, restored or moved photos.
- Plan line 88, "remove obsolete code and temporary adapters after validated migration", and the roadmap's own rule that every temporary adapter is listed in section 9 with its removal milestone. None of these has a removal milestone or appears in section 9:
- the fingerprint-JSON importer (P5);
- the TimelinePlacesCache-JSON importer (F5);
- the widget-cache v1 importer and the legacyWidgetCleanup.v1 purge (W4);
- the share-manifest v1 reader (W3);
- C6's interim "AuthorizationState owned by SessionStore for now";
- C5's interim second-validateToken sign-out rule.
- Plan line 95, "UI coverage for navigation, pagination, mutations and deep links".
- Deep links have one UI test, N1's testDeepLinkOpensAssetOverOpenSheet. Nothing covers immich://memory, immich://activity, album or person links, immich://share from the extension, or a link that cold-launches the app.
- Pagination UI covers search only (F1). PeoplePager's numbered pages (F5) and Trash bucket paging have unit tests only.
- Plan line 30, "Capture the reported failures in regression tests". Two reported failures from the build log have no regression test:
- 3040019: the correlated face-membership query blocked all local reads for 5 s. EntitySyncTests:163 pins its correctness, not its latency.
- 3040030: the first cold use of the shelves stalled on the Earth mesh.
- Plan line 64, "Maintain persistent, revisioned real thumbnails across the library, with explicit coverage and storage policy".
- T1 keeps both the files and the new index.sqlite in Caches, which iOS may purge, with no defined behavior when files vanish under a complete index or the index vanishes over present files.
- T5's policy covers scope and conditions but not storage location or cap. Storage policy is left entirely to an owner question.
- Plan line 96, Release measurements of "responsive interaction during background work". T7 is the only milestone that runs the background-load gate, and it does not depend on B9. It can therefore measure the legacy main-actor BackupCoordinator, and its "Transfer* symbols at most 2 % of main-thread time" criterion only exists once the new engine is in.
- Plan line 9, "Preserve ... the functionality tracked in PARITY.md". PARITY completion gate 3 (PARITY.md:362) requires device checks that no milestone's acceptance includes:
- Photos permission transitions between limited, full and denied (absent from P1 and P3);
- shared-album role restrictions (absent from N4);
- outgoing share handoff (absent from W1's MediaExportService).

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
- F3: MonthProjector ports MergedTimeline.entries, which re-sorts every entry, remote rows included, by (date desc, id asc) (MergedTimeline.swift:49-53). In the merged main library this undoes Q3's server order (local day, fileCreatedAt, fileName, id). The owner default "offline and online order match" fails exactly where phone photos are merged.
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
- Gate on "no un-imported <group>/Backup/*/state.json remains".
- Schedule removal of the P5, F5, W3 and W4 importers here or in a final cleanup milestone, and add them to section 9.
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
