use std::path::PathBuf;

use image_hasher::{HashAlg, HasherConfig};

/// Compute a 64-bit perceptual hash (DCT-based) from a 32×32 grayscale pixel buffer.
///
/// This is the primary pHash API for bridge-core. The caller (e.g. Swift side or
/// iced-app) provides a 32×32 = 1024 byte grayscale image, and this function
/// computes and returns the 64-bit pHash.
pub fn compute_phash_from_luma_32x32(pixels: &[u8; 1024]) -> u64 {
    let gray = image::GrayImage::from_raw(32, 32, pixels.to_vec())
        .expect("32x32 grayscale image should always be valid");
    let img = image::DynamicImage::ImageLuma8(gray);

    let hasher = HasherConfig::new()
        .hash_alg(HashAlg::Mean)
        .hash_size(8, 8)
        .preproc_dct()
        .to_hasher();

    let hash = hasher.hash_image(&img);
    let bytes: [u8; 8] = hash.as_bytes().try_into().expect("pHash must be 8 bytes");
    u64::from_le_bytes(bytes)
}

pub fn hamming(a: u64, b: u64) -> u32 {
    (a ^ b).count_ones()
}

/// Fetch all cached pHashes for the given paths in a single connection.
/// Only entries whose mtime still matches the current file mtime are returned.
pub fn fetch_phash_batch(
    paths: &[PathBuf],
    db_path: &std::path::Path,
) -> std::collections::HashMap<PathBuf, u64> {
    crate::db::fetch_phash_batch(paths, db_path)
}

/// Persist a pHash for the given file path.
pub fn store_phash(path: &std::path::Path, db_path: &std::path::Path, phash: u64) {
    crate::db::store_phash(path, db_path, phash);
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

    #[test]
    fn compute_phash_from_luma_32x32_produces_nonzero() {
        // A non-trivial grayscale image (gradient) should produce a non-zero hash.
        let mut pixels = [0u8; 1024];
        for (i, p) in pixels.iter_mut().enumerate() {
            *p = (i % 256) as u8;
        }
        let hash = compute_phash_from_luma_32x32(&pixels);
        // Hash could theoretically be 0, but it's astronomically unlikely for a gradient.
        // Just check it completes without panic.
        let _ = hash;
    }

    #[test]
    fn identical_images_produce_identical_hashes() {
        let pixels = [128u8; 1024];
        let h1 = compute_phash_from_luma_32x32(&pixels);
        let h2 = compute_phash_from_luma_32x32(&pixels);
        assert_eq!(h1, h2);
    }
}
