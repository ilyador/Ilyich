# Native iOS Architecture Rebuild Plan

Status: roadmap. Durable transfer/recovery foundations are implemented. New-photos-only backup is the current priority; the bulk verification redesign below is deferred.

## Goal

Build a reliable foundation with clear ownership, durable recovery, and Photos-like timeline scrubbing. Rewrite or delete orchestration that obstructs those goals; retain sound components such as image decoding, the virtual grid, Live Photo pairing, and resumable sync.

Preserve the capabilities in [PRODUCT.md](ios-native/PRODUCT.md), the visual behavior in [DESIGN.md](ios-native/DESIGN.md), and the functionality tracked in [PARITY.md](ios-native/PARITY.md).

## Ownership

| Component | Responsibility |
| --- | --- |
| Account runtime | Session-scoped dependencies, authorization and lifecycle |
| Verification and transfer services | Durable checks, resource fingerprints, uploads, receipts and recovery |
| PhotoKit adapter | Native reads and mutations with correct executor boundaries |
| Library repository | Query semantics, local/server routing and typed changes |
| Thumbnail service | Local thumbnail coverage, decoded cache and viewport scheduling |
| Feature stores | Observable presentation state and user commands |
| Navigation coordinator | Typed destinations and presentation transitions |
| Widget support | Extension-safe fetching and deterministic timelines |

Views render state and submit commands. Services receive explicit dependencies and own their work outside the UI lifecycle.

## Workstreams

### 1. Establish contracts and regression coverage

Define shared query, mutation, authorization and lifecycle contracts first. Capture the reported failures in regression tests. Preserve existing search continuation, verification, cancellation and scroll-restoration behavior, along with the backup formats needed for migration.

### 2. Separate verification from uploading

**Current requirement: back up new photos only.** Save the existing Photos identifiers as an account-scoped starting point, without reading originals or checking past backups. Cancel the old library queue while preserving receipts and media. Automatically back up later additions, including imports with old capture dates; keep the starting point across restarts and re-enabling. Existing items and their later edits remain excluded. Show progress only for new items and keep historical receipts available separately.

The following work is deferred until bulk verification is needed:

The existing SQLite transfer engine and background transport remain the foundation. The current check path acquires the upload staging slot before checking known copies; one slow iCloud resource can block unrelated checks. It also discards PhotoKit preparation progress. A 16 November read-only phone snapshot found 407 confirmations, 18,104 queued items, one preparing item and one submitted upload, with no recorded error. This establishes slow progress, not the precise cause of the reported pause at 388.

Replace that sequence with independently scheduled stages:

- **Inventory and fast matching:** checkpoint the selected Photos inventory and apply subsequent changes incrementally. Batch saved checksum and trusted identity lookups against the server index without taking a file-preparation slot. Offer checking without uploading; unknown items remain unknown.
- **Resource verification:** use one account/revision/resource-scoped checksum store across browsing, backup and recovery. Reuse receipts and valid hashes; hash bytes while exporting once. Keep current edits, original sources and Live Photo motion distinct. Persist each result immediately.
- **Preparation and upload:** only proven missing required resources enter the upload queue. Give local reads and iCloud downloads separate bounded capacity. A no-progress deadline defers a stalled resource so other work continues. Preserve prepared files across interruption within a storage budget.
- **Optional follow-up:** original-version grouping, album work and notifications run independently. Remove source-original downloading from the current-file upload path; retain the durable grouping worker and its fresh proof checks.
- **Progress:** persist the inventory and completed checks across launches. Show checked, already backed up, needs upload and waiting counts, plus the current iCloud/hash/upload phase and progress. Revalidate changed or missing copies; do not discard valid matches just to rebuild the display.

Replace minute-by-minute full identity reloads with indexed lookups and incremental updates, including archive fingerprint changes. Batch fresh server proof reads. Avoid rescanning the whole selected set after no-op transfer events. Filename/date similarity may narrow candidates, but cannot create verified backup or cleanup proof.

### 3. Make background execution explicit

Keep the single background URLSession for prepared file uploads, submitting bounded batches instead of depending on a wake for each next file. Use iOS 26+ continued processing for a user-started initial check/backup, with system-visible progress and cancellation. Automatic maintenance uses scheduled processing windows. Inventory, hashing and iCloud preparation must checkpoint and yield when their execution window expires.

An OS-owned upload may continue while the app is suspended; arbitrary PhotoKit work does not inherit that guarantee. iOS can also stop continued processing. Resume only incomplete work, preserve existing session identifiers, and reconcile attempts before accepting completion. Migrate current receipts, preferences and pending jobs without a second engine or forced uploads. Apple's guidance: [background transfers](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background) and [continued processing](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask).

### 4. Centralize PhotoKit and cleanup operations

Move native mutations out of views into an executor-safe PhotoKit adapter. Track committed results independently of the presenting screen.

A separate cleanup service filters candidates locally, verifies matching receipts with bounded concurrency, and revalidates only the selected items before deletion. Missing server copies exclude individual candidates. Account, policy or resource changes invalidate stale verification. Existing server contracts cannot make remote verification and later local deletion atomic.

### 5. Unify library queries and invalidation

Use one typed query preserving scope, trash status, visibility, predicates, ordering and place membership across browsing and search. Active assets are the default; unsupported backend operations remain explicit. Place identity includes membership revision.

Keep a lightweight local ordering index suitable for viewport queries. Publish precise asset and access changes so one deletion or edit preserves unrelated cached media. Fence late results by account and authorization generation. Remove lossy filter translation and notification dictionaries used as internal contracts.

### 6. Separate feed loading from presentation

Split `LibraryStore` into presentation state, timeline loading, per-month projections and a concrete cursor-based asset feed. Compute projections outside the main actor and update affected months incrementally.

Pagination owns request identity, continuation and retry state. Preserve existing verification semantics and reject stale responses. Keep timeline buckets and numbered People pages separate. Feed readiness must drive current thumbnail demand without requiring another gesture.

### 7. Make Photos-like scrubbing a core requirement

Maintain persistent, revisioned real thumbnails across the library, with explicit coverage and storage policy. Use existing server renditions initially; benchmark a smaller scrub tier if needed. Keep a bounded decoded window around the visible and predicted timeline position, then sharpen images as movement slows.

One thumbnail scheduler owns loading, preheating, prioritization and cancellation. Rail dragging and ordinary scrolling share interaction state. Current visible work has reserved capacity; obsolete work and background warming cannot monopolize it. Coalesce duplicate work and keep disk maintenance outside the display path.

Cells display prepared images immediately while scrubbing. Use shared PhotoKit preheating for device assets and retain the existing off-main decoder for server images. Replace cell-owned loading policy and the blanket wait-until-scrolling-stops behavior.

Validate offline random jumps after thumbnail preparation, direction reversals, relaunch and memory pressure. Decoded hits should appear in the next frame; measure disk-hit latency separately from network misses and placeholders. A first uncached remote request remains network-bound.

This follows Apple's guidance on [image preparation and prefetching](https://developer.apple.com/videos/play/wwdc2021/10252/) and [PhotoKit thumbnail caching](https://developer.apple.com/documentation/photos/phcachingimagemanager).

### 8. Rewrite navigation and mutation propagation

Reduce `LibraryView` to composition and presentation. Typed routes carry their required context; one settings catalog keeps every destination, sign-out and read-only policy reachable.

Mutation results identify the affected assets and operation. Collections handle deletion, restoration, locking and membership changes correctly. Remove parallel destination variables, overlapping presentation flags and callbacks capturing the initially opened photo.

### 9. Replace widgets and formalize media capabilities

Move native widgets fully under `ios-native`, removing the Flutter source dependency. Separate fetching from deterministic timeline planning, including ordered dates and partial failures.

Viewer actions reflect actual capabilities. Offer Cast only when receiver authorization supports the asset. Locked-media casting requires a separately designed asset-scoped grant under a future server contract.

## Delivery and completion

Define the shared contracts first, then develop backup/recovery and library/thumbnail work in parallel. Establish the PhotoKit boundary early. Each subsystem replaces its predecessor completely; remove obsolete code and temporary adapters after validated migration.

Completion requires:

- Regression, concurrency and interruption-recovery coverage.
- Migration tests with existing receipts and active transfers.
- Backup throughput tests: one stalled iCloud item cannot block a batch of cached checks; unchanged resources are not rehashed after restart; interrupted inventory resumes from its checkpoint; optional source matching cannot delay upload handoff. Measure the real library's cold and warm passes, API calls, bytes downloaded and time without progress.
- Check-only mode makes zero upload attempts. Resource changes, Live Photos, missing server files, offline state and account changes retain strict proof requirements.
- Equivalent local/server query results and correct scoped cache invalidation.
- UI coverage for navigation, pagination, mutations and deep links.
- Release-build measurements on the target iPhone: real-thumbnail latency, frame hitches, bounded memory and responsive interaction during background work.

Photos-like scrubbing is part of the library/media cutover, with persistent thumbnail coverage and measured display performance as acceptance gates.
