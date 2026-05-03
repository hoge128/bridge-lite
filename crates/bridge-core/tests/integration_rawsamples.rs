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

