# iOS backup and photo sources

Backup inventory, library presentation, and media loading have separate responsibilities. Choosing what to back up must not turn the Immich feed into an unresolved copy of the phone’s library.

## Ownership

- **Backup engine:** owns selection, discovery, durable upload jobs, checksum checks, confirmations, retries and scheduling. Existing records remain authoritative across updates.
- **Device index:** records exact server associations and proves which local items are distinct. Whole-library items with unresolved identities stay out of the default feed; explicit phone browsing remains available.
- **Account media resolver:** chooses the viewing source for every entry point: feed, phone browser, backup history and cleanup preview. It fences account, authorization and photo revisions across asynchronous work.
- **Views:** render shared state and send explicit commands. Byte updates stay in the small status views, rather than invalidating the photo grid.

## Source contract

| Evidence | Viewing behavior |
| --- | --- |
| Verified, eligible server association | Use the server viewer and its cached/developed previews first. |
| Known server copy; connection unavailable | Show server recovery and retry. A phone fallback is an explicit choice. |
| No verified server association | Use Photos for the selected item; this does not prove it is absent from Immich. |
| Photos requires a network download | Explain availability, offer download, show actual progress, allow cancel/retry. |
| Account or access changed | Discard stale work; never expose an old or ineligible server asset. |

Exact receipts, persisted fingerprints and cloud identifiers establish associations. Filenames and timestamps do not. Opening a photo does not download its original merely to identify it.

## Backup and status contract

- Enabling automatic backup or changing its scope checks the selection immediately while the app is open. Ordinary Photos changes use the configured delay.
- Background restrictions affect scheduling independently of foreground/manual backup. The UI explains global and per-app iOS refresh settings.
- A scan measures the unique selected inventory. Its items are **verified on server**, **not checked yet**, or **proven to need upload**. Queue membership alone proves nothing about server absence. Verification includes older backups and is never described as a count of new uploads.
- Known copies are checked before original-file staging. Current saved checksums use server duplicate preflight; an unadjusted single original can also use a unique, guarded cloud-identity match checked against the current account’s live server record. Metadata-only matches do not create cleanup receipts. Ambiguous, edited and compound resources retain full resource verification.
- External-library primary checksums identify paths, not file contents. The server keeps a separate, persistent content fingerprint, invalidated when the source changes. Preflight compares actual content across uploads and external libraries; a fresh exact asset read supplies proof for receipts and device cleanup. Native code never uses a path hash as file proof.
- Edited Photos items can match their unmodified source to an existing archive file by content checksum. Source identity is cached separately from the current rendition, with revision/resource validation. A source match links versions through Immich stacks; it never confirms the current edit or grants device cleanup. Existing stack members and cover choices are preserved.
- **Link archived originals** checks already-confirmed edits while backup stays paused. It reads originals under the existing iCloud/cellular preferences and saves exact associations without uploading files. New backups cache source evidence before upload, then commit durable original-matching work with the current receipt. The post-upload worker retries that work independently of uploads, rechecks the Photos source and both server checksums, and queues grouping only after fresh proof.
- Original matching distinguishes unsupported sources, stale revisions and temporary Photos/network failures. Deferred work retains its reason and retry time across app restarts. A saved backup remains verified while grouping waits; retrying grouping never requeues its upload. Each worker pass processes a bounded page.
- Transfer database upgrades are explicit, additive migrations. Historical schema 1 gains the missing confirmation-copy table; schema 3 seeds durable original-matching work from current confirmed receipts. Preferences, pause intent, receipts and upload jobs are preserved.
- Initial external-library preparation holds the photo lane and shows **Preparing server library**. It does not claim files are missing, create thousands of retries, or change the user’s pause or automatic-backup preference. Completed hashes are reused; originals need reading once, then only after changes.
- Read-only confirmation reconciliation runs at account startup, on coalesced library changes, and when the app comes forward, including while backup is paused. Deleted, trashed or changed remote copies are removed from account, history and selected counts without staging or starting uploads. Discovery also revalidates earlier confirmations. Offline failures preserve history, labeled as previously verified; missing catalog entries require an exact server read before invalidation.
- A partial server identity index defers the photo lane instead of treating missing metadata as a reason to download originals. Shared uploads remain independent. Cloud identities are indexed once and refreshed periodically, rather than scanning the whole server catalog for every photo.
- The selection fraction appears only after the inventory’s duplicate checks are complete. Current-upload bytes describe active file parts and reset as files finish. Unknown items show checking, never an upload backlog or invented percentage.
- If an old backup has no reusable identity, reading or downloading the original may still be necessary for exact comparison. Server duplicate preflight remains the final gate before sending file bytes. Pausing stays durable across updates; reconciliation never enables backup.
- An empty queue becomes “up to date” only after a successful scan of the current selection. Errors, new selections and stale scans cannot claim completion.
- Settings shows the same numbers as the compact bottom indicator. The indicator opens backup details and reserves space above the feed controls.

## Delivery checks

Verify exact source resolution, unresolved-item projection, permission/network recovery, duplicate skipping, automatic/manual start, cancellation, account changes and truthful counts. Inspect the real Settings modal and progress components in light, dark and large text. Build and install the verified owner app on both reachable phones; keep App Store delivery separate.

## Comparison with the original Immich client

Compared the checked-in Flutter client at `e426c21f` (2026-11-14) and cached official upstream `b7510e79` (2026-10-31). This is source evidence, not a verification of the latest store release; BrowserOS research was unavailable.

| Area | Original behavior used as the baseline | Native implementation |
| --- | --- | --- |
| Selection | Unique union of selected albums; exclusions win. Recents is treated as the all-photos album. | Explicit whole-library query plus the same exclusion/set rules; no dependence on localized smart-album names. |
| Duplicate identity | Current-account checksums join local and remote assets; un-hashed items remain unresolved. | Current-revision receipts and exact fingerprints/cloud bridges; upload preflight verifies duplicates. Unknown matches remain unknown. |
| Counts | Total, backed-up and remaining belong to the current selection; hashing/processing is separate. | Selected, verified, not checked, and to upload are separate; historical confirmations are not new uploads. |
| Viewing | A merged asset retains its remote identity. Usable local media is normally preferred, with remote paths for server/developed media and missing local files. | One resolver preserves the verified server identity across every viewer. Known server copies use the server viewer/cache; outages do not silently become iCloud downloads. |
| Background work | Foreground work and iOS background URLSession/worker budgets have distinct responsibilities. | One durable transfer engine; denied background refresh does not block an explicit foreground check or upload. |

Source references: `mobile/lib/infrastructure/repositories/backup.repository.dart`, `timeline.repository.dart`, `mobile/lib/domain/services/hash.service.dart`, `mobile/lib/presentation/widgets/images/image_provider.dart`, and `mobile/lib/providers/backup/backup.provider.dart`. The Flutter services cannot be dropped unchanged into SwiftUI; their established contracts are the baseline for the port.
