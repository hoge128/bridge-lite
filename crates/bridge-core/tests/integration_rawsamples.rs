use bridge_core::raw_thumb::{extract, Quality};
use std::path::Path;

fn test_dir() -> std::path::PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../test/rawsamples")
}

fn check(filename: &str) -> String {
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

#[test] fn canon_cr2()  { println!("CR2  {}", check("RAW_CANON_EOS_5DMARK3.CR2")); }
#[test] fn canon_cr3()  { println!("CR3  {}", check("RAW_CANON_EOS_R5.CR3")); }
#[test] fn nikon_nef()  { println!("NEF  {}", check("RAW_NIKON_Z6II.NEF")); }
#[test] fn sony_arw()   { println!("ARW  {}", check("RAW_SONY_ILCE7RM4.ARW")); }
#[test] fn pana_rw2()   { println!("RW2  {}", check("RAW_PANASONIC_GH6.RW2")); }
#[test] fn fuji_raf()   { println!("RAF  {}", check("RAW_FUJIFILM_XT5.RAF")); }
#[test] fn olympus_orf(){ println!("ORF  {}", check("RAW_OLYMPUS_EM5.ORF")); }
#[test] fn pentax_pef() { println!("PEF  {}", check("RAW_PENTAX_K1.PEF")); }
#[test] fn leica_dng()  { println!("DNG  {}", check("RAW_LEICA_M10.DNG")); }
