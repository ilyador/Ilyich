use crate::{decode::Source, xmp};
use lightcraft_engine::pipeline::{self, OutputSpace, RenderRequest};
use lightcraft_meta::XmpData;
use lightcraft_raster::Rgba8;

pub struct ResultImage {
    pub pixels: Rgba8,
    pub native_width: usize,
    pub native_height: usize,
    pub unmapped: Vec<String>,
}

pub fn develop(
    source: &Source,
    packet: &XmpData,
    size: Option<usize>,
    space: OutputSpace,
) -> Result<ResultImage, String> {
    let aspect = source.pixels.width as f64 / source.pixels.height as f64;
    let (settings, unmapped) = xmp::settings(
        packet,
        xmp::target(&source.info),
        aspect,
        source.orientation,
    );
    let frame = pipeline::frame_for(&source.pixels, &source.info, &settings, true);
    let (native_w, native_h) = frame.native_size();
    if !native_w.is_finite() || !native_h.is_finite() || native_w < 1.0 || native_h < 1.0 {
        return Err("XMP produces an invalid crop".into());
    }
    let scale = size.map_or(1.0, |s| (s as f64 / native_w.min(native_h)).min(1.0));
    let width = (native_w * scale).round().max(1.0) as usize;
    let height = (native_h * scale).round().max(1.0) as usize;
    let mut request = RenderRequest::fit(width, height);
    request.space = space;
    let rendered = pipeline::render(&source.pixels, &source.info, &settings, &request);
    let unmapped = bounded_names(unmapped);
    Ok(ResultImage {
        pixels: rendered.image,
        native_width: native_w.round().max(1.0) as usize,
        native_height: native_h.round().max(1.0) as usize,
        unmapped,
    })
}

/// Sorted, de-duplicated names, bounded so the response header stays within the protocol's
/// 64 KiB: at most 256 names of at most 128 bytes, with a marker when any were left out.
fn bounded_names(names: Vec<String>) -> Vec<String> {
    const MAX_NAMES: usize = 256;
    const MAX_NAME_BYTES: usize = 128;
    const OMITTED: &str = "AdditionalUnsupportedSettingsOmitted";
    let all: std::collections::BTreeSet<String> = names.into_iter().collect();
    let mut omitted = false;
    let mut out: Vec<String> = all
        .into_iter()
        .filter(|name| {
            let fits = name.len() <= MAX_NAME_BYTES;
            omitted |= !fits;
            fits
        })
        .collect();
    if out.len() > MAX_NAMES - 1 {
        out.truncate(MAX_NAMES - 1);
        omitted = true;
    }
    if omitted {
        out.push(OMITTED.into());
    }
    out
}
