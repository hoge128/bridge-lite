use bridge_core::raw_thumb::{extract, Quality};
use std::path::Path;

const RW2_PATH: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../test/2026-02-08_上野動物園/RAW/P1101297.RW2"
);

#[test]
fn rw2_thumbnail_extracts_valid_jpeg() {
    let path = Path::new(RW2_PATH);
    if !path.exists() {
        eprintln!("Skipping: test file not found at {RW2_PATH}");
        return;
    }
    let bytes = extract(path, Quality::Thumbnail)
        .expect("RW2 thumbnail extraction should succeed");
    assert!(bytes.starts_with(&[0xFF, 0xD8]), "must be JPEG SOI");
    assert!(bytes.ends_with(&[0xFF, 0xD9]), "must be JPEG EOI");
    assert!(bytes.len() > 1024, "thumbnail should be > 1 KB");
}

#[test]
fn rw2_preview_extracts_valid_jpeg() {
    let path = Path::new(RW2_PATH);
    if !path.exists() {
        eprintln!("Skipping: test file not found at {RW2_PATH}");
        return;
    }
    let bytes = extract(path, Quality::Preview)
        .expect("RW2 preview extraction should succeed");
    assert!(bytes.starts_with(&[0xFF, 0xD8]), "must be JPEG SOI");
    assert!(bytes.ends_with(&[0xFF, 0xD9]), "must be JPEG EOI");
    assert!(bytes.len() > 100_000, "preview should be > 100 KB");
}
