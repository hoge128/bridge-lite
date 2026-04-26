use bridge_core::scanner::{compute_shot_id, normalize_stem, is_raw};
use std::path::Path;

fn sid(s: &str) -> u64 { compute_shot_id(&normalize_stem(s)) }

#[test]
fn same_stem_pairs() {
    assert_eq!(sid("DSE06419"), sid("DSE06419"));
    assert_eq!(sid("foo"), sid("foo-edit"));
    assert_eq!(sid("foo"), sid("foo_edit"));
    assert_eq!(sid("foo"), sid("foo-edit2"));
    assert_eq!(sid("foo"), sid("foo-Enhanced"));
    assert_eq!(sid("foo"), sid("foo-copy"));
    assert_eq!(sid("foo"), sid("foo_copy"));
    assert_eq!(sid("foo"), sid("foo-v2"));
    assert_eq!(sid("foo"), sid("foo_v3"));
    assert_eq!(sid("IMG"), sid("IMG (2)"));
    assert_eq!(sid("IMG_0001"), sid("IMG_0001-edit"));
}

#[test]
fn different_stems_are_distinct() {
    assert_ne!(sid("DSC_0001"), sid("DSC_0002"));
    assert_ne!(sid("img001"), sid("img002"));
}

#[test]
fn short_stem_protection() {
    assert_ne!(sid("A"), sid("A-edit"));
    assert_ne!(sid("AB"), sid("AB-edit"));
}

#[test]
fn multi_strip() {
    assert_eq!(sid("foo"), sid("foo-edit-copy"));
    assert_eq!(normalize_stem("bar-v2-copy"), normalize_stem("bar"));
}

#[test]
fn software_suffix_stripping() {
    assert_eq!(sid("DSE06384"), sid("DSE06384-DxO_DeepPRIME XD2s"));
    assert_eq!(sid("DSE06384"), sid("DSE06384-Lightroom-Export"));
    assert_eq!(sid("foo"), sid("foo-CaptureOne-adjusted"));
    assert_ne!(sid("DSE06384"), sid("DSE06385-DxO_DeepPRIME XD2s"));
}

#[test]
fn is_raw_detection() {
    assert!(is_raw(Path::new("photo.ARW")));
    assert!(is_raw(Path::new("photo.arw")));
    assert!(is_raw(Path::new("photo.CR3")));
    assert!(is_raw(Path::new("photo.NEF")));
    assert!(!is_raw(Path::new("photo.jpg")));
    assert!(!is_raw(Path::new("photo.JPG")));
    assert!(!is_raw(Path::new("photo.png")));
    assert!(!is_raw(Path::new("photo.txt")));
}
