use std::path::PathBuf;

const N: usize = 32;

/// Compute a 64-bit perceptual hash (DCT-based) from a 32×32 grayscale pixel buffer.
///
/// Implements the classic DCT pHash: apply 2D DCT-II, take top-left 8×8 coefficients,
/// compare each to the mean, and pack into a 64-bit integer.
pub fn compute_phash_from_luma_32x32(pixels: &[u8; 1024]) -> u64 {
    let mut mat = [[0.0f32; N]; N];
    for r in 0..N {
        for c in 0..N {
            mat[r][c] = pixels[r * N + c] as f32;
        }
    }

    dct2d(&mut mat);

    let mut low = [0.0f32; 64];
    for r in 0..8 {
        for c in 0..8 {
            low[r * 8 + c] = mat[r][c];
        }
    }

    let mean = low.iter().sum::<f32>() / 64.0;
    let mut hash = 0u64;
    for (i, &v) in low.iter().enumerate() {
        if v >= mean {
            hash |= 1u64 << i;
        }
    }
    hash
}

pub fn hamming(a: u64, b: u64) -> u32 {
    (a ^ b).count_ones()
}

fn dct1d(row: &mut [f32; N]) {
    use std::f32::consts::PI;
    let scale_dc = (1.0f32 / N as f32).sqrt();
    let scale_ac = (2.0f32 / N as f32).sqrt();
    let mut out = [0.0f32; N];
    for k in 0..N {
        let sum: f32 = row
            .iter()
            .enumerate()
            .map(|(n, &x)| x * (PI * k as f32 * (2 * n + 1) as f32 / (2 * N) as f32).cos())
            .sum();
        out[k] = (if k == 0 { scale_dc } else { scale_ac }) * sum;
    }
    *row = out;
}

fn dct2d(mat: &mut [[f32; N]; N]) {
    for row in mat.iter_mut() {
        dct1d(row);
    }
    // Transpose → DCT on rows → Transpose back
    let mut t = [[0.0f32; N]; N];
    for r in 0..N {
        for c in 0..N {
            t[c][r] = mat[r][c];
        }
    }
    for row in t.iter_mut() {
        dct1d(row);
    }
    for r in 0..N {
        for c in 0..N {
            mat[r][c] = t[c][r];
        }
    }
}

/// Fetch all cached pHashes for the given paths in a single connection.
pub fn fetch_phash_batch(
    paths: &[PathBuf],
    db_path: &std::path::Path,
) -> std::collections::HashMap<PathBuf, u64> {
    let path_mtimes: Vec<(PathBuf, i64)> = paths
        .iter()
        .map(|p| {
            let mtime = std::fs::metadata(p)
                .ok()
                .and_then(|m| m.modified().ok())
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_secs() as i64)
                .unwrap_or(0);
            (p.clone(), mtime)
        })
        .collect();
    let Ok(conn) = crate::db::open_connection(db_path) else {
        return std::collections::HashMap::new();
    };
    crate::db::fetch_phash_batch(&path_mtimes, &conn)
}

/// Persist a pHash for the given file path.
pub fn store_phash(path: &std::path::Path, db_path: &std::path::Path, phash: u64) {
    if let Ok(conn) = crate::db::open_connection(db_path) {
        crate::db::store_phash(path, &conn, phash);
    }
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
        assert_eq!(hamming(0b0001, 0b0011), 1);
    }

    #[test]
    fn compute_phash_from_luma_32x32_produces_stable_result() {
        let mut pixels = [0u8; 1024];
        for (i, p) in pixels.iter_mut().enumerate() {
            *p = (i % 256) as u8;
        }
        let h1 = compute_phash_from_luma_32x32(&pixels);
        let h2 = compute_phash_from_luma_32x32(&pixels);
        assert_eq!(h1, h2);
    }

    #[test]
    fn identical_images_produce_identical_hashes() {
        let pixels = [128u8; 1024];
        let h1 = compute_phash_from_luma_32x32(&pixels);
        let h2 = compute_phash_from_luma_32x32(&pixels);
        assert_eq!(h1, h2);
    }

    #[test]
    fn different_images_may_differ() {
        let black = [0u8; 1024];
        let white = [255u8; 1024];
        let h_black = compute_phash_from_luma_32x32(&black);
        let h_white = compute_phash_from_luma_32x32(&white);
        let _ = hamming(h_black, h_white);
    }
}
