use std::path::{Path, PathBuf};

use image_hasher::{HashAlg, HasherConfig};

/// Compute a 64-bit perceptual hash (DCT-based) for the given image file.
///
/// Priority for the source image:
/// 1. Cached thumbnail JPEG from the DB (avoids re-decoding)
/// 2. Embedded JPEG from RAW IFD chain
/// 3. macOS CGImageSource decode (non-RAW / DNG)
///
/// Returns `None` if no image data can be obtained.
pub fn compute_phash_sync(path: &Path, db_path: &Path) -> Option<u64> {
    if let Some(cached) = crate::db::fetch_phash(path, db_path) {
        return Some(cached);
    }

    let img = load_image_for_hash(path, db_path)?;

    let hasher = HasherConfig::new()
        .hash_alg(HashAlg::Mean)
        .hash_size(8, 8)
        .preproc_dct()
        .to_hasher();

    let hash = hasher.hash_image(&img);
    let bytes: [u8; 8] = hash.as_bytes().try_into().ok()?;
    let phash = u64::from_le_bytes(bytes);

    crate::db::store_phash(path, db_path, phash);
    Some(phash)
}

pub async fn compute_phash_async(
    id: usize,
    path: PathBuf,
    db_path: PathBuf,
) -> (usize, Option<u64>) {
    let result = tokio::task::spawn_blocking(move || compute_phash_sync(&path, &db_path))
        .await
        .ok()
        .flatten();
    (id, result)
}

pub fn hamming(a: u64, b: u64) -> u32 {
    (a ^ b).count_ones()
}

fn load_image_for_hash(path: &Path, db_path: &Path) -> Option<image::DynamicImage> {
    // 1. Cached thumbnail JPEG
    if let Some(jpeg) = crate::db::fetch_thumb(path, db_path) {
        if let Ok(img) = image::load_from_memory(&jpeg) {
            return Some(img);
        }
    }

    // 2. Embedded JPEG for RAW files
    if crate::thumbnail::is_raw(path) {
        if let Some(bytes) = crate::raw_thumb::extract(path, crate::raw_thumb::Quality::Thumbnail) {
            if let Ok(img) = image::load_from_memory(&bytes) {
                return Some(img);
            }
        }
    }

    // 3. macOS CGImageSource (handles JPEG / PNG / TIFF / DNG / HEIF)
    #[cfg(target_os = "macos")]
    if let Some((w, h, rgba)) = crate::macos_thumb::create_thumbnail(path, 256) {
        if let Some(img) = image::RgbaImage::from_raw(w, h, rgba) {
            return Some(image::DynamicImage::ImageRgba8(img));
        }
    }

    // 4. Fallback: full decode via image crate
    image::open(path).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hamming_identical() {
        assert_eq!(hamming(0xDEADBEEF_CAFEBABE, 0xDEADBEEF_CAFEBABE), 0);
    }

    #[test]
    fn hamming_all_bits_differ() {
        assert_eq!(hamming(0u64, !0u64), 64);
    }

    #[test]
    fn hamming_close() {
        // 1-bit difference
        assert_eq!(hamming(0b0001, 0b0011), 1);
    }
}
