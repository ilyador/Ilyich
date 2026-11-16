# iCloud backup: findings and implementation

16 November 2026. Scope: efficient backup of new photos and videos, preserving originals and exact duplicate checks.

## Delivered

Build **3.4.1 (3040123)** is installed and launched on the iPhone 15 Pro. The persistent starting point introduced in 3040122 excludes 18,514 existing Photos items without downloading or verifying them. Cutover removed 18,104 old queued jobs and preserved 409 confirmations, without uploading or changing Photos. The post-launch check of 3040123 confirms the same starting point, automatic new-photos-only backup enabled, and zero jobs or attempts. Owner access is restored after 3040122 accidentally omitted its build flag.

## Implemented optimizations

- Calculate SHA-1 while exporting the resource, then persist it with the prepared file. Avoid rereading a large video just to hash it; retain the fallback for older prepared files.
- Check saved copies before taking a preparation slot. Share concurrent server-catalog loads so parallel checks do not multiply full-index reads.
- Move optional original-version matching entirely to the existing durable follow-up worker. Uploading the current photo must not wait for another iCloud original.
- Show PhotoKit's actual iCloud download progress separately from server upload progress.
- Cancel an export after three minutes without bytes or advancing download progress, release its slot, and retry that item later. Ongoing slow transfers remain eligible to finish.

The app and Share extension compile, and all 122 focused simulator tests pass, including cancellation, stalled exports, checksum persistence, progress and future-only regression cases. The device database integrity check passes. Local-first resource requests, cellular restrictions, bounded memory, saved stages, background-task adoption, and exact Live Photo pairing remain essential. This is correctness validation, not a measured real-world throughput improvement.

## Research that changes the longer-term design

**PhotoKit has a dedicated background resource upload extension.** Introduced in iOS 26.1, with an async interface in iOS 27, it lets the system manage resource downloads and uploads. Download-only jobs also exist. Full Photos access and a physical device are required. The extension declares a static `BackgroundUploadURLBase`; Apple does not clearly document arbitrary per-account host support. The inspected iOS 27.1 SDK exposes network-cost options, but no destination-host option or precomputed checksum. [Apple guide](https://developer.apple.com/documentation/photokit/uploading-asset-resources-in-the-background), [job options](https://developer.apple.com/documentation/photos/phassetresourceuploadjoboptions).

This is a promising next transport, not a drop-in replacement: Immich's asset endpoint expects multipart fields, while PhotoKit queues individual resources. Validate host restrictions and an authenticated compatible endpoint before shipping it. No central proxy is required by this proposal. [Immich 3.4.1 upload controller](https://github.com/immich-app/immich/blob/v3.4.1/server/src/controllers/asset-media.controller.ts).

**Use persistent Photos change tokens for incremental discovery.** They identify insertions, changes, and deletions across launches. Commit the cursor with processed changes; if history expires, rebuild metadata while retaining the immutable future-only baseline. This can eliminate repeated full metadata scans. [Apple's change-history guidance](https://developer.apple.com/videos/play/wwdc2022/10132/).

**True interrupted-upload resumption needs server support.** A background session alone does not establish byte-offset recovery after a terminal failure. Apple's resumable-upload protocol requires a compatible endpoint. [Resumable uploads](https://developer.apple.com/documentation/foundation/pausing-and-resuming-uploads).

## Further improvements, in order

1. Persist incremental discovery and coalesce concurrent reads of the same photo/revision.
2. Fill bounded background upload capacity before yielding; avoid one transfer per wake. [Apple's background-transfer guidance](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background).
3. Prepare Live Photo parts independently and write directly into a durable multipart artifact to reduce temporary disk use. Preserve pair completion and crash recovery.
4. Prototype PhotoKit-managed background uploads against a compatible endpoint, including normal scheduling with Developer Test Mode off.

The original Immich app batches work and streams foreground multipart uploads. Its approach informs these changes; copying its concurrency settings or metadata-derived hashes would not establish better throughput or exact backup proof here. Measure bytes read, temporary disk use, time to first upload, and recovery after interruption before widening concurrency.
