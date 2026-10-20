# Native iOS Architecture Rebuild Plan

Status: proposed; implementation has not started.

## Goal

Build a reliable foundation with clear ownership, durable recovery, and Photos-like timeline scrubbing. Rewrite or delete orchestration that obstructs those goals; retain sound components such as image decoding, the virtual grid, Live Photo pairing, and resumable sync.

Preserve the capabilities in [PRODUCT.md](ios-native/PRODUCT.md), the visual behavior in [DESIGN.md](ios-native/DESIGN.md), and the functionality tracked in [PARITY.md](ios-native/PARITY.md).

## Ownership

| Component | Responsibility |
| --- | --- |
| Account runtime | Session-scoped dependencies, authorization and lifecycle |
| Transfer engine and database | Durable backup/share jobs, attempts, receipts and recovery |
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

### 2. Replace backup orchestration

Replace `BackupCoordinator` with one durable transfer state machine outside the main actor. Reserve operations before suspension and validate their ownership when results return. Replace whole-history JSON rewrites with incremental SQLite persistence.

Separate successful file backup from album updates and notifications. Temporary failures retry automatically; environmental restrictions wait; account restrictions and item failures remain explicit. Approved share uploads use the same engine. Remove duplicated execution loops and independently writable running/error flags.

### 3. Rebuild background transfer recovery

Make `BackgroundUploads` a transport adapter and `BackupLifecycle` a source of lifecycle events. Reconcile operating-system tasks, durable attempts, results and staged files after interruption.

Preserve existing session identifiers and import legacy state idempotently. Keep active resources recoverable, acknowledge results after durable commit, and run one execution engine during cutover.

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
- Equivalent local/server query results and correct scoped cache invalidation.
- UI coverage for navigation, pagination, mutations and deep links.
- Release-build measurements on the target iPhone: real-thumbnail latency, frame hitches, bounded memory and responsive interaction during background work.

Photos-like scrubbing is part of the library/media cutover, with persistent thumbnail coverage and measured display performance as acceptance gates.
