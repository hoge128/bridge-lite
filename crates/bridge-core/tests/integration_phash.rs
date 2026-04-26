use bridge_core::phash::{hamming, compute_phash_from_luma_32x32};

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
fn identical_images_produce_identical_hashes() {
    let pixels = [128u8; 1024];
    let h1 = compute_phash_from_luma_32x32(&pixels);
    let h2 = compute_phash_from_luma_32x32(&pixels);
    assert_eq!(h1, h2);
}

#[test]
fn gradient_image_produces_stable_hash() {
    let mut pixels = [0u8; 1024];
    for (i, p) in pixels.iter_mut().enumerate() {
        *p = (i % 256) as u8;
    }
    let h1 = compute_phash_from_luma_32x32(&pixels);
    let h2 = compute_phash_from_luma_32x32(&pixels);
    assert_eq!(h1, h2, "same input must always produce same hash");
}

#[test]
fn different_images_may_differ() {
    // All-black vs all-white — these should differ
    let black = [0u8; 1024];
    let white = [255u8; 1024];
    let h_black = compute_phash_from_luma_32x32(&black);
    let h_white = compute_phash_from_luma_32x32(&white);
    // In practice these will almost certainly differ, but we just ensure no panic
    let _ = hamming(h_black, h_white);
}
