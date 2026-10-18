# Ilyich for iOS

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Users and purpose

A native iPhone client for the user's self-hosted Ilyich photo library. Find, view, organize, edit, share, and back up personal photos and videos smoothly across a large library.

## Capabilities and constraints

Preserve all functions of the existing mobile app. The user confirmed this on 2026-10-18. This includes device backup, local media, shared albums, editing, locked photos, share extension, widgets, OCR, natural-language search, and Lightroom-developed previews. Function inventory: `.local/ios-redesign/functionality-inventory.json` (local audit; not shipped).

Use the existing server contracts. Keep originals and sidecars as sources; show the server's revisioned developed previews. Parsing names and descriptions and visual search verification remain server responsibilities. Do not fabricate verification progress, search interpretation, or counts absent from the API.

The new client is independent of the existing Flutter client during development. The working phone installation remains available until the native app has passed parity and device checks.

## Brand commitments

Ilyich name and approved gold origami star on crimson (`design/ilyich-logo.png`). The user supplied the Claude artifact titled “Ilyich iOS — Liquid Glass” as the binding redesign reference.

## Confirmed refinements

No voice-search control. Places must be a beautiful, performant 3D globe matching the reference, with day and night appearances selected by light and dark mode.

The user's device is an iPhone 15 Pro running iOS 27. Target iOS 27 directly, with no older-iOS compatibility layers or iPad layouts. The globe supports pinch zoom and rotation, and a photo's location opens the same globe focused on that photo.

## Success and accessibility

Fast first useful content, responsive scrolling and gestures, bounded memory, no image decoding on the main thread. Native Liquid Glass, native accessibility, Dynamic Type, sufficient contrast and touch targets, and Reduce Motion support. Verify real flows, error recovery, and actual iOS rendering rather than treating a successful build as usability evidence.
