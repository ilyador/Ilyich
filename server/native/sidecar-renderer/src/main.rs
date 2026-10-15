mod decode;
mod render;
mod xmp;

use lightcraft_engine::pipeline::OutputSpace;
use serde::Serialize;
use std::io::{Read, Write};
use std::path::PathBuf;

const LIGHTCRAFT_REV: &str = match option_env!("IMMICH_LIGHTCRAFT_REV") {
    Some(revision) => revision,
    None => "80b44dee4e7d37f41871a0ee03d733a5679a5f0a",
};

fn version() -> String {
    format!(
        "immich-sidecar-renderer/{}/adapter/{}/lightcraft/{}/libraw/{}",
        env!("CARGO_PKG_VERSION"),
        env!("IMMICH_RENDERER_BUILD"),
        LIGHTCRAFT_REV,
        decode::libraw_version()
    )
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Header {
    version: u8,
    renderer_version: String,
    status: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    reason: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    width: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    height: Option<usize>,
    channels: u8,
    colorspace: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    native_width: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    native_height: Option<usize>,
    unmapped: Vec<String>,
}

struct Args {
    original: PathBuf,
    sidecar: PathBuf,
    size: Option<usize>,
    space: OutputSpace,
    colorspace: String,
}

fn arguments() -> Result<Args, String> {
    let mut args = std::env::args_os().skip(1);
    let mut original = None;
    let mut sidecar = None;
    let mut size = None;
    let mut colorspace = "srgb".to_owned();
    while let Some(key) = args.next() {
        let value = args.next().ok_or("Missing argument value")?;
        match key.to_str() {
            Some("--original") if original.is_none() => original = Some(PathBuf::from(value)),
            Some("--sidecar") if sidecar.is_none() => sidecar = Some(PathBuf::from(value)),
            Some("--size") if size.is_none() => {
                let value = value
                    .to_str()
                    .ok_or("Invalid size")?
                    .parse::<usize>()
                    .map_err(|_| "Invalid size")?;
                if value == 0 {
                    return Err("Size must be positive".into());
                }
                size = Some(value);
            }
            Some("--colorspace") => {
                colorspace = value.to_str().ok_or("Invalid colorspace")?.to_owned()
            }
            _ => return Err(
                "Usage: --original PATH --sidecar PATH [--size SHORT_EDGE] [--colorspace srgb|p3]"
                    .into(),
            ),
        }
    }
    let space = match colorspace.as_str() {
        "srgb" => OutputSpace::Srgb,
        "p3" => OutputSpace::DisplayP3,
        _ => return Err("Colorspace must be srgb or p3".into()),
    };
    Ok(Args {
        original: original.ok_or("Missing --original")?,
        sidecar: sidecar.ok_or("Missing --sidecar")?,
        size,
        space,
        colorspace,
    })
}

fn bounded_diagnostics(names: Vec<String>) -> Vec<String> {
    // Even six-byte JSON escapes leave room for the remaining 64 KiB header.
    const MAX_NAMES: usize = 64;
    const MAX_NAME_BYTES: usize = 128;
    let mut bounded = Vec::new();
    let mut omitted = false;
    for name in names {
        if name.len() > MAX_NAME_BYTES || bounded.len() == MAX_NAMES {
            omitted = true;
        } else {
            bounded.push(name);
        }
    }
    if omitted {
        bounded.truncate(MAX_NAMES - 1);
        bounded.push("AdditionalUnsupportedSettingsOmitted".into());
    }
    bounded
}

fn write_response(mut header: Header, pixels: &[u8]) -> Result<(), String> {
    header.unmapped = bounded_diagnostics(header.unmapped);
    let json = serde_json::to_vec(&header).map_err(|e| e.to_string())?;
    if json.len() > 64 * 1024 {
        return Err("Renderer response header exceeds 64 KiB".into());
    }
    let mut stdout = std::io::stdout().lock();
    stdout
        .write_all(&json)
        .and_then(|_| stdout.write_all(b"\n"))
        .and_then(|_| stdout.write_all(pixels))
        .map_err(|e| format!("Write renderer response: {e}"))
}

fn run() -> Result<(), String> {
    if std::env::args_os().skip(1).collect::<Vec<_>>() == [std::ffi::OsString::from("--version")] {
        println!("{}", version());
        return Ok(());
    }
    let args = arguments()?;
    let mut xml = String::new();
    std::fs::File::open(&args.sidecar)
        .map_err(|e| format!("Open sidecar: {e}"))?
        .take(xmp::MAX_XMP_BYTES + 1)
        .read_to_string(&mut xml)
        .map_err(|e| format!("Read sidecar: {e}"))?;
    let packet = xmp::parse(&xml)?;
    let mut header = Header {
        version: 1,
        renderer_version: version(),
        status: "skipped",
        reason: Some("no-applicable-development"),
        width: None,
        height: None,
        channels: 4,
        colorspace: args.colorspace,
        native_width: None,
        native_height: None,
        unmapped: vec![],
    };
    match xmp::development(&packet) {
        xmp::Development::Skipped => {
            header.unmapped = xmp::settings(
                &packet,
                lightcraft_engine::crs::Target::Any,
                1.0,
                lightcraft_geom::Orientation::Normal,
            )
            .1;
            return write_response(header, &[]);
        }
        xmp::Development::Orientation(orientation)
            if orientation == decode::orientation(&args.original)? =>
        {
            return write_response(header, &[]);
        }
        _ => {}
    }
    let source = decode::load(&args.original)?;
    let image = render::develop(&source, &packet, args.size, args.space)?;
    header.status = "developed";
    header.reason = None;
    header.width = Some(image.pixels.width);
    header.height = Some(image.pixels.height);
    header.native_width = Some(image.native_width);
    header.native_height = Some(image.native_height);
    header.unmapped = image.unmapped;
    write_response(header, bytemuck::cast_slice(&image.pixels.data))
}

fn main() {
    match std::panic::catch_unwind(run) {
        Ok(Ok(())) => {}
        Ok(Err(error)) => {
            eprintln!("{error}");
            std::process::exit(1);
        }
        Err(_) => {
            eprintln!("Renderer panicked while processing the source");
            std::process::exit(1);
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn diagnostics_fit_the_header_even_with_maximum_json_escaping() {
        let names = super::bounded_diagnostics(vec!["\0".repeat(128); 65]);
        assert_eq!(names.len(), 64);
        assert_eq!(
            names.last().unwrap(),
            "AdditionalUnsupportedSettingsOmitted"
        );
        assert!(serde_json::to_vec(&names).unwrap().len() < 63 * 1024);
    }
}
