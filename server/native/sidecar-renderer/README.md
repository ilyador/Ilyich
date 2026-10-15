# Immich sidecar renderer

This helper develops an original photo using an external Lightroom XMP sidecar
and streams an RGBA bitmap into Immich's existing preview pipeline. It writes no
image files and does not create library assets. Photos without applicable sidecar
edits remain on Immich's normal preview path.

Lightcraft is a pinned Cargo Git dependency; the Lightcraft app is not required.
Its public CRS mapper, source loader and CPU pipeline provide the rendering.
The current [fork pin](https://github.com/ilyador/lightcraft/commit/80b44dee4e7d37f41871a0ee03d733a5679a5f0a)
includes the work in [Lightcraft PR #1226](https://github.com/storytold/lightcraft/pull/1226).
Appearance calibration belongs in Lightcraft; Lightroom parity remains incomplete.

## Build and test

Use Rust 1.94 or newer (Docker and CI use 1.98.0) and `libraw-dev` version 0.21 or
newer on Debian/Ubuntu:

```sh
cargo build --release --locked
cargo test --locked
cargo clippy --locked --all-targets -- -D warnings
cargo fmt --check
```

Custom LibRaw installations can set `LIBRAW_INCLUDE_DIR` to the directory
containing `libraw/libraw.h` and `LIBRAW_LIB_DIR` to the directory containing
`libraw_r.so`. Production uses `pkg-config` and the distribution package.
For a bare `pnpm` server process, set `IMMICH_SIDECAR_RENDERER` to the absolute
path of `target/release/immich-sidecar-renderer`.

## Invocation and response

```sh
immich-sidecar-renderer --version
immich-sidecar-renderer --original PHOTO.NEF --sidecar PHOTO.xmp --colorspace srgb --size 1440
```

`--sidecar` is required. External sidecar settings take precedence over embedded
XMP. `--size` is a positive short-edge size, preserving Immich's `fit: outside`
behavior without upscaling. Omit it for native developed resolution. The source
retains native detail before XMP cropping, including tight crops. Output supports
`srgb` and `p3`: pixels are gamma-encoded in that space for Sharp's existing
profile attachment and encoding.

Stdout contains one JSON line (at most 64 KiB), then exactly
`width * height * 4` interleaved RGBA bytes. A developed header has:

```json
{
  "version": 1,
  "rendererVersion": "immich-sidecar-renderer/0.1.0/adapter/BUILD_HASH/lightcraft/80b44dee4e7d37f41871a0ee03d733a5679a5f0a/libraw/0.21.5-Release",
  "status": "developed",
  "width": 2160,
  "height": 1440,
  "channels": 4,
  "colorspace": "srgb",
  "nativeWidth": 6000,
  "nativeHeight": 4000,
  "unmapped": ["CameraProfile", "Look"]
}
```

Metadata-only packets with unchanged source orientation, unsupported-only packets
and `AlreadyApplied` packets return `status: "skipped"`,
`reason: "no-applicable-development"`, and no pixels. Supported neutral controls
(including explicit monochrome-off, zero scalars and identity curves) still render.
Errors exit nonzero without a successful frame, allowing the caller to retain its
last valid cache. Source/XMP fingerprinting and cache publication belong to Immich.

## Source handling and limits

The loader uses Lightcraft's native RAW decoding, camera calibration and tone
preparation. It rejects Lightcraft's embedded-JPEG fallback and instead uses
LibRaw for unsupported RAW variants, including CR3. A small C++ shim calls
LibRaw's public API and owns its allocation; no decoder implementation is copied.
Camera support follows the decoders and file metadata, without camera-model
branches in this adapter. Only bundled camera profiles are used, so external
profile directories cannot alter previews.
The adapter preserves the calibration returned by Lightcraft's loader; appearance
corrections belong in that dependency rather than Immich.

Enhanced DNG pixels take precedence over retained original CFA data. Corrupt or
unsupported enhanced data fails rather than silently reverting to the noisy
original. Decoder differences, LibRaw's bounded 16-bit processing and source
white-point estimation can still affect appearance. Source dimensions are retained
for noise-reduction and sharpening scale.

Decoded pixels are already source-oriented. An XMP orientation applies only the
required delta. Saved crop corners are converted through Lightcraft's public
geometry APIs before mapping to the target orientation. Rotated local-mask/spot
coordinate fidelity still needs a controlled Lightroom XMP/export fixture; the
adapter does not add an unverified transform.

XMP is limited to 128 MiB, 64 nesting levels and 200,000 XML nodes. Source decoding
is limited to 100 million pixels. Transparent inputs with applicable edits are
rejected because the current pipeline discards alpha. Unsupported adjustments are
reported through `unmapped`, including unresolved profile tables; they are not
claims of Lightroom fidelity. `LIGHTCRAFT_PROFILE=1` enables timing diagnostics
on stderr.

Response diagnostics are bounded to fit the protocol header. If names are too
long or numerous, `AdditionalUnsupportedSettingsOmitted` reports the omission.

Procedural unit/protocol fixtures cover sidecar-only invocation, RAW/native detail,
external precedence, grayscale, crop/orientation, sizing without upscaling, neutral
profile controls, colorspaces, malformed XML and transparency. They verify the
integration contract, not Lightroom appearance parity.
