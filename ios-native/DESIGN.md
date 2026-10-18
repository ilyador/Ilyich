# Native iOS design contract

Reference: the user's Claude artifact, 14 artboards, inspected on 2026-10-18. This records the intended world; implementation and verification status are tracked separately.

- One continuous, edge-to-edge photo grid. Four columns by default, fine separators, small month badges at boundaries. The current month floats above the content, with selection and account controls.
- A glass search capsule sits above the bottom safe area. Search and people/album/place filters update the same library. The unfiltered scroll position survives clearing a filter.
- Left-edge shelves fan out as native glass capsules over the library. Keep an accessible, labelled button alternative to the drag gesture. Secondary functional screens use native navigation and sheets.
- The right time rail scales by photo count, exposes months and years, gives one haptic tick per month while scrubbing, and returns to a quiet state after interaction. Reduced Motion removes travel animation.
- Places replaces bottom search with a 3D Earth rising from the bottom edge. Real locations are photo markers; day/night follows system appearance. No invented trips, place names, counts, or markers.
- Search results present actual verification state and useful recovery. Preserve the reference's filter chips only where backed by a real server field. Do not invent an understood-query breakdown or progress percentage.
- Viewer presents the photo on black with sparse glass controls, a dismiss gesture, zoom, paging, video/Live Photo playback and a native details sheet. Details include real EXIF, albums, OCR, and Lightroom development state.
- Use system typography and SF Symbols for native Dynamic Type and accessibility. Semantic foreground/background colors adapt to appearance. The reference's cyan selection accent is reserved for selected controls; the app's star identity is retained.
- Use actual iOS 26 glass materials and shared glass containers. No CSS-style imitation of refraction, no full-grid blur while a search runs. Press and gesture feedback remains interruptible.

The downloaded HTML reference is evidence only, never embedded into the app. Its editor-only glow rule is excluded from the local design detector; native UI remains subject to visual review.
