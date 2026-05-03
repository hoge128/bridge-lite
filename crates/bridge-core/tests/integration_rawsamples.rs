use bridge_core::metadata::read_exif_sync;
use bridge_core::raw_thumb::{extract, Quality};
use std::path::Path;

fn test_dir() -> std::path::PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../test/rawsamples")
}

fn check_thumb(filename: &str) -> String {
    let path = test_dir().join(filename);
    if !path.exists() {
        return "SKIP (file not found)".to_string();
    }
    match extract(&path, Quality::Thumbnail) {
        Some(bytes) if bytes.starts_with(&[0xFF, 0xD8]) && bytes.ends_with(&[0xFF, 0xD9]) => {
            format!("OK ({} KB)", bytes.len() / 1024)
        }
        Some(_) => "FAIL (invalid JPEG)".to_string(),
        None => "FAIL (None returned)".to_string(),
    }
}


fn check_exif(filename: &str) -> String {
    let path = test_dir().join(filename);
    if !path.exists() {
        return "SKIP (file not found)".to_string();
    }
    match read_exif_sync(&path) {
        Some(exif) => {
            let dt = exif.datetime.as_deref().unwrap_or("(no datetime)");
            let make = exif.make.as_deref().unwrap_or("(no make)");
            format!("OK  datetime={dt}  make={make}")
        }
        None => "FAIL (None returned)".to_string(),
    }
}

// ── Thumbnail extraction ───────────────────────────────────────────────────────
#[test] fn thumb_canon_cr2()  { println!("CR2  {}", check_thumb("RAW_CANON_EOS_5DMARK3.CR2")); }
#[test] fn thumb_canon_cr3()  { println!("CR3  {}", check_thumb("RAW_CANON_EOS_R5.CR3")); }
#[test] fn thumb_nikon_nef()  { println!("NEF  {}", check_thumb("RAW_NIKON_Z6II.NEF")); }
#[test] fn thumb_sony_arw()   { println!("ARW  {}", check_thumb("RAW_SONY_ILCE7RM4.ARW")); }
#[test] fn thumb_pana_rw2()   { println!("RW2  {}", check_thumb("RAW_PANASONIC_GH6.RW2")); }
#[test] fn thumb_fuji_raf()   { println!("RAF  {}", check_thumb("RAW_FUJIFILM_XT5.RAF")); }
#[test] fn thumb_olympus_orf(){ println!("ORF  {}", check_thumb("RAW_OLYMPUS_EM5.ORF")); }
#[test] fn thumb_pentax_pef() { println!("PEF  {}", check_thumb("RAW_PENTAX_K1.PEF")); }
#[test] fn thumb_leica_dng()  { println!("DNG  {}", check_thumb("RAW_LEICA_M10.DNG")); }

// ── Preview extraction (Quality::Preview — used by ThumbnailPipeline) ─────────
//
// These must not regress to None — ThumbnailPipeline falls back to
// CGImageSourceCreateImageAtIndex which crashes on macOS 26 for proprietary RAW.

fn assert_preview(filename: &str) {
    let path = test_dir().join(filename);
    if !path.exists() { return; }
    let result = extract(&path, Quality::Preview);
    assert!(
        result.is_some(),
        "{filename}: Quality::Preview returned None — thumbnail grid will show nothing"
    );
}

fn assert_full(filename: &str) {
    let path = test_dir().join(filename);
    if !path.exists() { return; }
    let result = extract(&path, Quality::Full);
    assert!(
        result.is_some(),
        "{filename}: Quality::Full returned None — viewer falls through to ImageIO which may crash"
    );
}

#[test] fn preview_canon_cr2()  { assert_preview("RAW_CANON_EOS_5DMARK3.CR2"); }
#[test] fn preview_canon_cr3()  { assert_preview("RAW_CANON_EOS_R5.CR3"); }
#[test] fn preview_nikon_nef()  { assert_preview("RAW_NIKON_Z6II.NEF"); }
#[test] fn preview_sony_arw()   { assert_preview("RAW_SONY_ILCE7RM4.ARW"); }
#[test] fn preview_pana_rw2()   { assert_preview("RAW_PANASONIC_GH6.RW2"); }
#[test] fn preview_fuji_raf()   { assert_preview("RAW_FUJIFILM_XT5.RAF"); }
#[test] fn preview_olympus_orf(){ assert_preview("RAW_OLYMPUS_EM5.ORF"); }
#[test] fn preview_pentax_pef() { assert_preview("RAW_PENTAX_K1.PEF"); }
#[test] fn preview_leica_dng()  { assert_preview("RAW_LEICA_M10.DNG"); }

// ── Full extraction (Quality::Full — used by ViewerView) ──────────────────────
#[test] fn full_canon_cr2()  { assert_full("RAW_CANON_EOS_5DMARK3.CR2"); }
#[test] fn full_canon_cr3()  { assert_full("RAW_CANON_EOS_R5.CR3"); }
#[test] fn full_nikon_nef()  { assert_full("RAW_NIKON_Z6II.NEF"); }
#[test] fn full_sony_arw()   { assert_full("RAW_SONY_ILCE7RM4.ARW"); }
#[test] fn full_pana_rw2()   { assert_full("RAW_PANASONIC_GH6.RW2"); }
#[test] fn full_fuji_raf()   { assert_full("RAW_FUJIFILM_XT5.RAF"); }
#[test] fn full_olympus_orf(){ assert_full("RAW_OLYMPUS_EM5.ORF"); }
#[test] fn full_pentax_pef() { assert_full("RAW_PENTAX_K1.PEF"); }
#[test] fn full_leica_dng()  { assert_full("RAW_LEICA_M10.DNG"); }

// ── EXIF reading ──────────────────────────────────────────────────────────────
#[test] fn exif_canon_cr2()  { println!("CR2  {}", check_exif("RAW_CANON_EOS_5DMARK3.CR2")); }
#[test] fn exif_canon_cr3()  { println!("CR3  {}", check_exif("RAW_CANON_EOS_R5.CR3")); }
#[test] fn exif_nikon_nef()  { println!("NEF  {}", check_exif("RAW_NIKON_Z6II.NEF")); }
#[test] fn exif_sony_arw()   { println!("ARW  {}", check_exif("RAW_SONY_ILCE7RM4.ARW")); }
#[test] fn exif_pana_rw2()   { println!("RW2  {}", check_exif("RAW_PANASONIC_GH6.RW2")); }
#[test] fn exif_fuji_raf()   { println!("RAF  {}", check_exif("RAW_FUJIFILM_XT5.RAF")); }
#[test] fn exif_olympus_orf(){ println!("ORF  {}", check_exif("RAW_OLYMPUS_EM5.ORF")); }
#[test] fn exif_pentax_pef() { println!("PEF  {}", check_exif("RAW_PENTAX_K1.PEF")); }
#[test] fn exif_leica_dng()  { println!("DNG  {}", check_exif("RAW_LEICA_M10.DNG")); }

// ── EXIF datetime must not be None for any supported RAW format ───────────────

fn assert_datetime(filename: &str) {
    let path = test_dir().join(filename);
    if !path.exists() { return; } // テストファイルがない環境はスキップ
    let exif = read_exif_sync(&path)
        .unwrap_or_else(|| panic!("{filename}: read_exif_sync returned None"));
    assert!(
        exif.datetime.is_some(),
        "{filename}: datetime is None — file will be treated as IAD and may be mis-grouped"
    );
}

#[test] fn datetime_cr2()  { assert_datetime("RAW_CANON_EOS_5DMARK3.CR2"); }
#[test] fn datetime_cr3()  { assert_datetime("RAW_CANON_EOS_R5.CR3"); }
#[test] fn datetime_nef()  { assert_datetime("RAW_NIKON_Z6II.NEF"); }
#[test] fn datetime_arw()  { assert_datetime("RAW_SONY_ILCE7RM4.ARW"); }
#[test] fn datetime_rw2()  { assert_datetime("RAW_PANASONIC_GH6.RW2"); }
#[test] fn datetime_raf()  { assert_datetime("RAW_FUJIFILM_XT5.RAF"); }
#[test] fn datetime_orf()  { assert_datetime("RAW_OLYMPUS_EM5.ORF"); }
#[test] fn datetime_pef()  { assert_datetime("RAW_PENTAX_K1.PEF"); }
#[test] fn datetime_dng()  { assert_datetime("RAW_LEICA_M10.DNG"); }

