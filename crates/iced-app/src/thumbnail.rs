use std::path::{Path, PathBuf};

use iced::widget::image::Handle;

pub const THUMB_SIZE: u32 = 200;

pub enum ThumbResult {
    Loaded { id: usize, handle: Handle },
    Failed(usize),
}

pub async fn generate(id: usize, path: PathBuf, db_path: PathBuf) -> ThumbResult {
    match tokio::task::spawn_blocking(move || generate_sync(&path, &db_path)).await {
        Ok(Some((w, h, pixels))) => ThumbResult::Loaded {
            id,
            handle: Handle::from_rgba(w, h, pixels),
        },
        _ => ThumbResult::Failed(id),
    }
}

fn generate_sync(path: &Path, db_path: &Path) -> Option<(u32, u32, Vec<u8>)> {
    // Cache hit: decode stored JPEG → RGBA
    if let Some(jpeg) = crate::db::fetch_thumb(path, db_path) {
        if let Ok(img) = image::load_from_memory(&jpeg) {
            let rgba = img.to_rgba8();
            let (w, h) = rgba.dimensions();
            return Some((w, h, rgba.into_raw()));
        }
    }

    let (w, h, pixels) = generate_raw(path)?;
    store_thumb_jpeg(path, db_path, w, h, &pixels);
    Some((w, h, pixels))
}

fn generate_raw(path: &Path) -> Option<(u32, u32, Vec<u8>)> {
    if bridge_core::scanner::is_raw(path) {
        // Camera RAW files embed JPEG previews in IFD chain; try that first.
        if let Some(bytes) = bridge_core::raw_thumb::extract(path, bridge_core::raw_thumb::Quality::Thumbnail) {
            if let Ok(img) = image::load_from_memory(&bytes) {
                return Some(center_crop_rgba(img, THUMB_SIZE));
            }
        }
        // No embedded JPEG (e.g. DxO output DNG): fall through to platform decoder.
    }

    // macOS fast path via CGImageSource — handles JPEG/PNG/TIFF/DNG/HEIF
    #[cfg(target_os = "macos")]
    if let Some(result) = crate::macos_thumb::create_thumbnail(path, THUMB_SIZE) {
        return Some(result);
    }

    // Fallback: full decode via image crate + EXIF orientation correction
    let img = image::open(path).ok()?;
    let img = apply_exif_orientation(img, path);
    Some(center_crop_rgba(img, THUMB_SIZE))
}

fn store_thumb_jpeg(path: &Path, db_path: &Path, w: u32, h: u32, pixels: &[u8]) {
    use image::ImageEncoder;
    // Convert RGBA → RGB (JPEG has no alpha)
    let rgb: Vec<u8> = pixels.chunks(4).flat_map(|c| [c[0], c[1], c[2]]).collect();
    let mut jpeg_bytes = Vec::new();
    if image::codecs::jpeg::JpegEncoder::new_with_quality(&mut jpeg_bytes, 85)
        .write_image(&rgb, w, h, image::ExtendedColorType::Rgb8)
        .is_ok()
    {
        crate::db::store_thumb(path, db_path, &jpeg_bytes);
    }
}

/// Center-crop to square then resize to `size × size`, returning RGBA bytes.
pub fn center_crop_rgba(img: image::DynamicImage, size: u32) -> (u32, u32, Vec<u8>) {
    use image::GenericImageView;
    let (w, h) = img.dimensions();
    let sq = w.min(h);
    let x = (w - sq) / 2;
    let y = (h - sq) / 2;
    let cropped = img.crop_imm(x, y, sq, sq);
    let thumb = cropped.resize_exact(size, size, image::imageops::FilterType::Triangle);
    let rgba = thumb.to_rgba8();
    let (tw, th) = rgba.dimensions();
    (tw, th, rgba.into_raw())
}

/// Apply EXIF orientation to a decoded image (for non-macOS / fallback path).
/// CGImageSource handles this automatically via kCGImageSourceCreateThumbnailWithTransform.
pub fn apply_exif_orientation(img: image::DynamicImage, path: &Path) -> image::DynamicImage {
    let orientation = read_exif_orientation(path).unwrap_or(1);
    match orientation {
        1 => img,
        2 => img.fliph(),
        3 => img.rotate180(),
        4 => img.flipv(),
        5 => img.rotate90().fliph(),
        6 => img.rotate90(),
        7 => img.rotate270().fliph(),
        8 => img.rotate270(),
        _ => img,
    }
}

fn read_exif_orientation(path: &Path) -> Option<u32> {
    use exif::{In, Tag, Value};
    let file = std::fs::File::open(path).ok()?;
    let mut reader = std::io::BufReader::new(file);
    let exif = exif::Reader::new().read_from_container(&mut reader).ok()?;
    let field = exif.get_field(Tag::Orientation, In::PRIMARY)?;
    if let Value::Short(v) = &field.value {
        v.first().map(|&n| n as u32)
    } else {
        None
    }
}

/// Returns true if the given path has a RAW file extension.
/// Delegates to bridge_core::scanner::is_raw.
pub fn is_raw(path: &Path) -> bool {
    bridge_core::scanner::is_raw(path)
}
