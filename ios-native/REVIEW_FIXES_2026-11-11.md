# Demo readiness fixes — 2026-11-11

Release: signed iOS **3.3.5 (3040107)** installed over the existing app and launched on both iPhone 13 Pro Max and iPhone 15 Pro; accounts/data preserved. Signature and installed versions verified. Final build result: `ReviewFixesQA/release-1794417773.xcresult`.

Validation: 77 final search/cleanup/collection unit tests passed, plus partner/query/index/coverage focused checks and the physical acceptance below. Albums offline UI passed; the owner confirmed People navigation on the phone. The new People UI case was removed after recording showed its automated tap below the visible shelf row; its offline screen assertions remain unverified, with logic covered by unit tests. Full suite not completed. Evidence retained in `ReviewFixesQA/offline-ui-stable-1794417100-evidence`.

## Cleanup and partner timeline

- Free Up Space rechecks receipts, kept albums, local revisions and permissions after remote verification and immediately before Photos changes. Cancellation and account/settings changes revoke the removal permit.
- The attended 30-photo test passed on iPhone 13 Pro Max: 24 eligible, six excluded, cancellation preserved all photos, exactly three selected photos removed, server originals intact, journal read back, later edits and read-only blocked removal. Test fixtures were cleaned up. Result: `ReviewFixesQA/device-native-20261111-4.xcresult`, one test, zero failures. The release removal switch is now enabled.
- This physical run used generated JPEGs and isolated receipts. Live Photo, Locked Folder and Shared Album policies have unit coverage; their additional physical cases and real transfer-receipt durability were not exercised by this run.
- Partner libraries marked “show in timeline” participate in eligible timeline/search/index queries and cache invalidation. Own-library backup coverage remains scoped to the owner.

## People and Albums

- Saved collection lists appear before a server refresh finishes. A connection failure keeps known items visible instead of replacing them with an empty list.
- The screens distinguish no saved copy, a failed refresh and a successful empty response. Connection errors appear inline with Retry.
- A successful server response remains authoritative, including an empty list. Confirmed album changes remain applied during an offline refresh.
- Access denials persist per account and endpoint in the existing library database. Restarting offline cannot reopen a denied list. A later successful read of that endpoint can reopen its cache; an older response cannot clear a newer denial.
- Denying Albums does not disable the saved People list, or vice versa. Already displayed denied content clears when a later refresh encounters the saved denial.
- Offline browsing requires a completed/readable saved index. Missing or incomplete data is reported rather than presented as an empty server library.
- Faces and album covers are available offline only when their images are already cached. These changes add no separate durable face-image store.

Sources: `AlbumsStore.swift`, `PeoplePager.swift`, `PeopleDirectory.swift`, `CollectionsStore.swift`, `CollectionListing.swift`, `APIClient.swift`, `LibraryIndex.swift`, `IndexWriter.swift`, `AlbumsView.swift`, `PeopleView.swift`, `FeatureSupport.swift`.

## AI search

- Demo verification is configured and live on `ilyich-server:3.3.5-demo-ai-20261111`. The backend now returns confirmed matches only; busy or interrupted verification cannot return unchecked candidates. Its 56 focused tests passed. The main server and existing demo assets were preserved.
- AI check remains off by default. The fork's cursor search sends `verify: true` when enabled and `verify: false` when disabled. Stock-server requests omit the unsupported verification field and cursor.
- If an enabled check reports verification unavailable, the client hides that response's unchecked candidates, including raw rows returned by older servers. Earlier confirmed matches remain visible.
- Partial responses retain the server's confirmed matches. Retry starts at the interrupted page's input cursor so unchecked candidates are not skipped or duplicated.
- The unavailable state explains that unchecked matches are hidden and offers Retry or Turn off AI check. Turning it off runs ordinary smart search without claiming visual verification.
- This defense depends on the server reporting its verification status honestly; it does not independently verify image content on the phone.

Sources: `SearchFeed.swift`, `LibraryView.swift`, `QueryPlanner.swift`, `SearchChoices.swift`.

## Paid access — validated, build uploaded

- Full app access uses verified StoreKit purchases: monthly, annual or lifetime. Eligible subscriptions have a one-week Apple introductory trial; lifetime is a one-time purchase.
- Entitlement checks cover the app scene, account/API activity and new backup/upload work. Losing access pauses work without deleting credentials, staged media, receipts or backup preferences. Transfers already scheduled with iOS can finish and journal their results.
- Restore, subscription management, support/legal links and saved-account controls remain accessible while locked. Optional developer contact links were removed.
- Validation passed 226 checks: 20 purchase-policy tests, 202 selected regressions, three normal purchase UI tests and one accelerated natural-expiry UI test. The three normal cases run first; accelerated expiry runs separately because the StoreKit test environment shares its clock. CI keeps separate result bundles for those invocations.
- Archive 3.3.5 (3040109) was exported with Apple Distribution signing and uploaded to App Store Connect on 2026-11-12. It is not yet selected in the submission draft; build 3040108 remains in TestFlight and unselected. Local StoreKit configuration remains restricted to test targets.
- Three genuine native paywall screenshots (monthly, yearly and lifetime) are staged at 1284 × 2778 and visually verified. App Store Connect login is pending, so product Review screenshot uploads and save/reload verification remain outstanding. No review submission was made.
- The Paid Apps agreement and applicable tax/banking forms remain separate account requirements.

## Regression coverage added or updated

- `OfflineCollectionsTests.swift`: saved-first loading, failed-refresh retention, missing versus empty data, durable denial/restart, independent endpoint recovery, stale response fencing and mutation retention.
- `CollectionsStoreTests.swift`: collection lists publish while the feature probe is still waiting.
- `LibraryTests.swift`: offline Albums without a saved copy show recovery actions and do not claim a legitimately empty library. People UI automation is limited as described above.
- `SearchFeedTests.swift`: unavailable raw candidates, confirmed-prefix retention, partial retries, no skipped tail, refresh retention and explicit opt-out recovery.
- `SearchChoicesTests.swift`, `QueryPlannerTests.swift`: explicit fork verification choices, unchanged default and stock-server field omission.

## Backup and settings follow-up — 2026-11-15

- Added an explicit **Back up entire library** scope, independent of Apple smart albums. Backup and the device timeline share the same selection rules; excluded albums win. Full Photos access covers photos, videos, hidden items and burst frames. Existing preferences retain their selected-album scope.
- Kept confirmation records and checksum duplicate checks. Unchanged completed items are not queued again; identical server files are reused. Optional album organization only copies selected real albums, in one direction, without copying the entire library into each album.
- Fixed switch contrast through a shared accent-aware native switch style. Added concise explanations for backup, iCloud originals, charging, cellular transfers, album organization, viewer/sharing, network addresses, slideshow, notifications and cleanup filters.
- Separated typed background-scheduling restrictions from upload errors. Device-policy changes recover scheduling automatically; refused requests are not retried for every Photos change. Scheduling runs off the main thread, with stale-response and initial-pause protection.
- **Validation:** the app and test targets compile; **94/94 targeted native tests pass** across ten suites. Architecture and whitespace checks pass. The Mac source was checksum-compared with this workspace. Evidence: `ios-native/build/BackupSettingsQA/final-20261115T183806Z` on the Mac.
- **Device delivery:** signed owner build **3.3.6 (3040114)** installed on the iPhone 15 Pro and its version verified. Remote launch requires unlocking the phone. The iPhone 13 Pro Max remains unchanged because Xcode could not establish wireless connectivity; installation is pending. The submitted App Store build 3040110 predates this follow-up and was not changed.

## Backup state and source rebuild — 2026-11-15

- Used the original Immich client’s selection, checksum matching and selection-count behavior as the baseline. The source comparison and contracts are in [BACKUP_ARCHITECTURE.md](BACKUP_ARCHITECTURE.md).
- Added one account-scoped media resolver used by every phone-photo viewer. Exact server matches open server media; server outages remain server errors with an explicit phone fallback. Unresolved whole-library copies remain indexed for backup but do not become duplicate rows in the server feed.
- Explicit backup-setting changes scan immediately. Discovery failures are visible; an unchecked or failed selection cannot claim to be backed up. Statistics measure the selected inventory and confirmed current revisions, independently of old history or uploads outside the selection.
- Added Settings statistics and a compact bottom indicator that opens backup details. Applied the shared native cyan switch style at each presentation root. Native screenshots verify the actual Settings modal in light, dark and accessibility text; component fixtures verify progress/count layout and its compact large-text form. Fixture counts are synthetic and are not production evidence.
- **Validation:** 115 targeted native unit tests pass, plus one owner UI test covering all three appearances/text sizes. The component snapshot test passed again after the bounded layout correction. No Photos deletion test or personal-photo manipulation was performed.
- **Build:** signed owner app and Share extension **3.3.6 (3040115)**; signature verification passes, both development profiles include both phones, and the bundle contains no test/StoreKit fixtures. This owner build is not an App Store archive.
- **Device delivery:** **3.3.6 (3040115) installed and version-verified on both iPhone 13 Pro Max and iPhone 15 Pro**, over the existing apps. The 13 Pro Max launched successfully; iOS blocked the 15 Pro’s remote launch while locked, so it can be opened manually after unlocking. Full source/project checksum comparison matches the tested workspace. The App Review submission was not changed.

## Existing-backup reconciliation — 2026-11-15

- Corrected a misleading count: this installation’s confirmations were presented as total server coverage, and every unchecked item looked like a new upload. Settings, history and the bottom indicator now distinguish **Verified**, **Not checked yet**, and **To upload**. Verification dates are not described as upload dates; no percentage appears while duplicate status is unknown.
- Known unadjusted single originals are reconciled against current server records before original-file staging. Saved current checksums use duplicate preflight; guarded cloud identities can confirm presence without creating cleanup receipts. Archived and hidden backups remain eligible. Edited, compound and ambiguous resources retain full verification; unmatched originals may still require an initial iCloud download to calculate their checksum.
- An incomplete server identity index defers the photo lane without blocking shared uploads or resuming a paused backup. The server catalog is indexed and reused across checks rather than repeatedly scanned for each photo. Final checksum preflight still gates file uploads.
- **Validation:** a clean build passed **73 tests** across nine targeted suites, including all five new reconciliation cases. Tests prove known duplicates cause zero staging/uploads, exact cleanup proof remains separate, incomplete metadata cannot trigger downloads, and pause remains respected. The component snapshot test passed again after the bounded large-text correction. Normal light/dark and accessibility layouts were inspected; counts are synthetic fixtures, not claims about the user’s library.
- Background-refresh code needed no change: the user confirmed the global iOS setting was Off, then enabled it. No backup was restarted during investigation.
- **Device delivery:** signed owner build **3.3.6 (3040116)** installed and version-verified on both phones without launching either app. The 15 Pro’s saved state remained paused with automatic backup off; the 13 Pro’s empty backup state remained paused. The submitted App Store build was not changed.
