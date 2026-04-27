// This is the ONLY module permitted to write files in the user's photo directory.
// All writes go through `write_metadata` (embedded) or `write_sidecar` (RAW),
// both of which preserve btime via `crate::btime::preserve_btime`.

use std::io;
use std::path::{Path, PathBuf};
use std::str::FromStr;

use xmp_toolkit::{xmp_ns, OpenFileOptions, XmpFile, XmpMeta, XmpValue};

use crate::developed::DEVELOPED_SOFTWARE_KEYWORDS;

const NS_CRS: &str = "http://ns.adobe.com/camera-raw-settings/1.0/";
const NS_DXO: &str = "http://ns.dxo.com/framework/1.0/";

#[derive(Debug, Clone, Default)]
pub struct XmpData {
    pub rating:    Option<u8>,
    pub label:     Option<Label>,
    pub flag:      Option<Flag>,
    /// True if XMP contains fingerprints of a RAW developer (Lightroom, DxO, etc.).
    /// Derived on read; never written back to file.
    pub developed: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Label {
    Red,
    Yellow,
    Green,
    Blue,
    Purple,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Flag {
    Pick,
    Reject,
}

impl Label {
    /// Lightroom-compatible label name written to `xmp:Label`.
    pub fn as_str(self) -> &'static str {
        match self {
            Label::Red    => "Red",
            Label::Yellow => "Yellow",
            Label::Green  => "Green",
            Label::Blue   => "Blue",
            Label::Purple => "Purple",
        }
    }

    /// Lowercase color name written to `photoshop:LabelColor` (Adobe Bridge convention).
    pub fn label_color(self) -> &'static str {
        match self {
            Label::Red    => "red",
            Label::Yellow => "yellow",
            Label::Green  => "green",
            Label::Blue   => "blue",
            Label::Purple => "purple",
        }
    }

    /// Parse `xmp:Label` string → Label.
    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            // Lightroom-compatible values (canonical write format)
            "Red"    => Some(Label::Red),
            "Yellow" => Some(Label::Yellow),
            "Green"  => Some(Label::Green),
            "Blue"   => Some(Label::Blue),
            "Purple" => Some(Label::Purple),
            // Adobe Bridge English default label names → mapped to LR colors
            "Select"   => Some(Label::Red),
            "Second"   => Some(Label::Yellow),
            "Approved" => Some(Label::Green),
            "Review"   => Some(Label::Blue),
            "To Do"    => Some(Label::Purple),
            _ => None,
        }
    }

    /// Parse `photoshop:LabelColor` string → Label.
    /// Bridge writes lowercase color names here regardless of UI language.
    pub fn from_label_color(s: &str) -> Option<Self> {
        match s {
            "red"    => Some(Label::Red),
            "yellow" => Some(Label::Yellow),
            "green"  => Some(Label::Green),
            "blue"   => Some(Label::Blue),
            "purple" => Some(Label::Purple),
            _ => None,
        }
    }
}

impl Flag {
    pub fn as_str(self) -> &'static str {
        match self {
            Flag::Pick   => "Pick",
            Flag::Reject => "Reject",
        }
    }
}

// ── Public dispatch API ──────────────────────────────────────────────────────
// Callers use these and never need to know JPG vs RAW.

/// Read XMP metadata from an image file.
/// - Non-RAW (JPG/TIFF/PNG): tries embedded XMP first, falls back to sidecar
///   (for files written by a previous bridge-lite version that used sidecars).
/// - RAW (ARW/CR2/…): reads sidecar only.
pub fn read_metadata(image_path: &Path) -> Option<XmpData> {
    let ext_is_dng = image_path
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.eq_ignore_ascii_case("dng"))
        .unwrap_or(false);

    if ext_is_dng {
        // DNG is TIFF-based and stores XMP embedded (Lightroom, DxO PhotoLab, etc.
        // write develop metadata into the DNG itself — no sidecar is created).
        // Fall back to sidecar for hand-crafted or legacy workflows.
        read_embedded(image_path).or_else(|| read_sidecar(image_path))
    } else if crate::scanner::is_raw(image_path) {
        read_sidecar(image_path)
    } else {
        read_embedded(image_path).or_else(|| read_sidecar(image_path))
    }
}

/// Write XMP metadata to an image file. btime is preserved on all paths.
/// - Non-RAW: embeds into the image file (APP1 segment for JPEG).
/// - RAW: writes/updates a stem-only `.xmp` sidecar. The RAW body is never touched.
pub fn write_metadata(image_path: &Path, data: &XmpData) -> io::Result<()> {
    if crate::scanner::is_raw(image_path) {
        write_sidecar(image_path, data)
    } else {
        write_embedded(image_path, data)
    }
}

// ── Internal: shared XmpMeta ↔ XmpData helpers ───────────────────────────────

/// Returns true if the XMP contains fingerprints of a RAW developer:
/// - `crs:RawFileName` — written by Lightroom/ACR and DxO PhotoLab outputs
/// - `crs:HasSettings` — present when Lightroom/ACR develop settings are applied
/// - `DxO:WhiteLevel` / `DxO:AdobeWhiteLevel` — DxO-specific properties
/// - `xmpMM:DerivedFrom` — file was derived from another (raw → processed DNG)
/// - `xmp:CreatorTool` — standard field written by most RAW developers
/// - `xmpMM:History[N]/stEvt:softwareAgent` matching a known developer keyword
///   (excluding entries with `stEvt:changed="/metadata"`, which Bridge writes
///   for rating/label changes via the Camera Raw engine)
fn detect_developed(meta: &XmpMeta) -> bool {
    if meta.property(NS_CRS, "RawFileName").is_some() { return true; }
    if meta.property(NS_CRS, "HasSettings").is_some() { return true; }
    if meta.property(NS_DXO, "WhiteLevel").is_some() { return true; }
    if meta.property(NS_DXO, "AdobeWhiteLevel").is_some() { return true; }

    // xmpMM:DerivedFrom: present when a file was derived/converted from another
    // (e.g., DxO PureRAW ARW→DNG, Lightroom DNG export). Strong processed indicator.
    if meta.property(xmp_ns::XMP_MM, "DerivedFrom").is_some() { return true; }

    // xmp:CreatorTool: standard XMP field that most RAW developers write.
    if let Some(tool) = meta.property(xmp_ns::XMP, "CreatorTool") {
        let lower = tool.value.to_lowercase();
        if DEVELOPED_SOFTWARE_KEYWORDS.iter().any(|kw| lower.contains(kw)) {
            return true;
        }
    }

    // xmpMM:History walk: Camera Raw / Lightroom / Photoshop write softwareAgent entries
    // when saving a developed file. Match against known developer keywords.
    //
    // Exception: Adobe Bridge writes Camera Raw history entries with
    // stEvt:changed="/metadata" when the user rates or labels a SOOC JPEG.
    // These are metadata-only writes — not real development — so skip them.
    // Entries with stEvt:changed="/metadata/crs" (Camera Raw settings change)
    // or stEvt:changed="/" (full rewrite) are legitimate develop operations.
    for i in 1..=10 {
        let agent_path = format!("History[{}]/stEvt:softwareAgent", i);
        let agent = match meta.property(xmp_ns::XMP_MM, &agent_path) {
            Some(a) => a,
            None => break,
        };

        let changed_path = format!("History[{}]/stEvt:changed", i);
        if let Some(changed) = meta.property(xmp_ns::XMP_MM, &changed_path) {
            if changed.value == "/metadata" {
                continue;
            }
        }

        let lower = agent.value.to_lowercase();
        if DEVELOPED_SOFTWARE_KEYWORDS.iter().any(|kw| lower.contains(kw)) {
            return true;
        }
    }
    false
}

fn parse_xmp_data(meta: &XmpMeta) -> XmpData {
    let mut data = XmpData::default();

    if let Some(v) = meta.property_i32(xmp_ns::XMP, "Rating") {
        if v.value < 0 {
            data.flag = Some(Flag::Reject);
        } else {
            data.rating = Some(v.value.clamp(0, 5) as u8);
        }
    }

    // photoshop:LabelColor takes priority: Bridge writes lowercase "red"/"yellow"/…
    // here regardless of UI language, so it's more reliable than xmp:Label which
    // Bridge localizes (e.g. "選択" in Japanese). Fall back to xmp:Label for
    // files written by Lightroom or other tools that omit photoshop:LabelColor.
    let label_from_color = meta.property(xmp_ns::PHOTOSHOP, "LabelColor")
        .and_then(|v| Label::from_label_color(&v.value));
    let label_from_text = meta.property(xmp_ns::XMP, "Label")
        .and_then(|v| Label::from_str(&v.value));
    data.label = label_from_color.or(label_from_text);

    data.developed = detect_developed(meta);

    data
}

fn apply_xmp_data(meta: &mut XmpMeta, data: &XmpData) -> io::Result<()> {
    // xmp:Rating: -1 = Reject, 0-5 = stars, absent = remove property
    let rating_int: Option<i32> = match data.flag {
        Some(Flag::Reject) => Some(-1),
        _ => data.rating.map(|r| r as i32),
    };
    if let Some(n) = rating_int {
        meta.set_property_i32(xmp_ns::XMP, "Rating", &XmpValue::new(n))
            .map_err(|e| io::Error::new(io::ErrorKind::Other, e.debug_message))?;
    } else {
        let _ = meta.delete_property(xmp_ns::XMP, "Rating");
    }

    // xmp:Label + photoshop:LabelColor must be written together for Bridge compatibility.
    // Preserve an existing xmp:Label string if it maps to the same color — this keeps
    // Bridge-localized names (e.g. Japanese "選択") intact when re-saving the same color.
    if let Some(label) = data.label {
        let existing_text = meta.property(xmp_ns::XMP, "Label").map(|v| v.value);
        let same_color = existing_text
            .as_deref()
            .and_then(Label::from_str)
            == Some(label);
        if !same_color {
            meta.set_property(xmp_ns::XMP, "Label", &XmpValue::new(label.as_str().to_string()))
                .map_err(|e| io::Error::new(io::ErrorKind::Other, e.debug_message))?;
        }
        meta.set_property(xmp_ns::PHOTOSHOP, "LabelColor", &XmpValue::new(label.label_color().to_string()))
            .map_err(|e| io::Error::new(io::ErrorKind::Other, e.debug_message))?;
    } else {
        let _ = meta.delete_property(xmp_ns::XMP, "Label");
        let _ = meta.delete_property(xmp_ns::PHOTOSHOP, "LabelColor");
    }

    Ok(())
}

// ── Embedded XMP (JPG / TIFF / PNG) ─────────────────────────────────────────

fn read_embedded(image_path: &Path) -> Option<XmpData> {
    let meta = XmpMeta::from_file(image_path).ok()?;
    Some(parse_xmp_data(&meta))
}

fn write_embedded(image_path: &Path, data: &XmpData) -> io::Result<()> {
    crate::btime::preserve_btime(image_path, || {
        let mut xf = XmpFile::new()
            .map_err(|e| io::Error::new(io::ErrorKind::Other, e.debug_message))?;

        // Try smart handler first (fast, format-specific); fall back to packet scanning.
        xf.open_file(
            image_path,
            OpenFileOptions::default().for_update().use_smart_handler(),
        )
        .or_else(|_| {
            xf.open_file(
                image_path,
                OpenFileOptions::default().for_update().use_packet_scanning(),
            )
        })
        .map_err(|e| io::Error::new(io::ErrorKind::Other, e.debug_message))?;

        let mut meta = xf.xmp().unwrap_or_else(|| XmpMeta::new().expect("XMP init failed"));
        apply_xmp_data(&mut meta, data)?;

        if !xf.can_put_xmp(&meta) {
            return Err(io::Error::new(io::ErrorKind::Other, "can_put_xmp returned false"));
        }
        xf.put_xmp(&meta)
            .map_err(|e| io::Error::new(io::ErrorKind::Other, e.debug_message))?;
        // try_close performs the actual disk write; plain close() swallows errors.
        xf.try_close()
            .map_err(|e| io::Error::new(io::ErrorKind::Other, e.debug_message))?;
        Ok(())
    })
}

// ── Sidecar XMP (RAW) ────────────────────────────────────────────────────────

/// Returns the XMP sidecar path for an image (Adobe stem-only convention).
/// `photo.ARW` -> `photo.xmp`
pub fn sidecar_path(image_path: &Path) -> PathBuf {
    let mut p = image_path.to_path_buf();
    p.set_extension("xmp");
    p
}

/// Reads and parses the XMP sidecar for `image_path` using the Adobe XMP Toolkit SDK.
/// Returns None if no sidecar exists or parsing fails.
pub fn read_sidecar(image_path: &Path) -> Option<XmpData> {
    let xmp_path = sidecar_path(image_path);
    let xml = std::fs::read_to_string(&xmp_path).ok()?;
    let meta = XmpMeta::from_str(&xml).ok()?;
    Some(parse_xmp_data(&meta))
}

/// Writes rating/label/flag to the XMP sidecar for `image_path`.
/// Preserves all existing XMP properties. Performs an atomic rename and preserves btime.
///
/// # Panics (debug only)
/// Asserts that the computed target path ends in `.xmp` and shares a directory with
/// the image. This makes it structurally impossible to overwrite the image itself.
pub fn write_sidecar(image_path: &Path, data: &XmpData) -> io::Result<()> {
    let xmp_path = sidecar_path(image_path);

    debug_assert!(
        xmp_path.extension()
            .map(|e| e.eq_ignore_ascii_case("xmp"))
            .unwrap_or(false),
        "write_sidecar: target must have .xmp extension, got {:?}",
        xmp_path,
    );
    debug_assert_eq!(
        xmp_path.parent(),
        image_path.parent(),
        "write_sidecar: sidecar must be in the same directory as the image",
    );

    let mut meta = if xmp_path.exists() {
        let xml = std::fs::read_to_string(&xmp_path)?;
        XmpMeta::from_str(&xml)
            .unwrap_or_else(|_| XmpMeta::new().expect("XMP init failed"))
    } else {
        XmpMeta::new().expect("XMP init failed")
    };

    apply_xmp_data(&mut meta, data)?;

    let xml_out = meta.to_string();
    let tmp_path = xmp_path.with_extension("xmp.tmp");
    std::fs::write(&tmp_path, xml_out.as_bytes())?;
    crate::btime::preserve_btime(&xmp_path, || std::fs::rename(&tmp_path, &xmp_path))?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(target_os = "macos")]
    use std::os::darwin::fs::MetadataExt;
    use std::path::Path;

    #[test]
    fn reads_adobe_xmp_sidecar() {
        // DSE06383.xmp was written by Adobe Bridge (Japanese) with a Red label.
        // Bridge writes xmp:Label="選択" + photoshop:LabelColor="red".
        // We should read it as Label::Red via photoshop:LabelColor.
        let arw = Path::new("/Users/itotsum/work/bridge-lite/test/20260221/raw/DSE06383.ARW");
        let data = read_sidecar(arw).expect("sidecar should be readable via xmp_toolkit");
        assert_eq!(data.label, Some(Label::Red), "Bridge photoshop:LabelColor should map to Label::Red");
        assert_eq!(data.flag, None);
    }

    #[test]
    fn reads_embedded_jpg_rating() {
        // DSE06419.JPG was rated 3 stars in Adobe Bridge (embedded XMP, no sidecar).
        let jpg = Path::new("/Users/itotsum/work/bridge-lite/test/20260221/jpg/DSE06419.JPG");
        let data = read_metadata(jpg).expect("embedded XMP should be readable");
        assert_eq!(data.rating, Some(3), "Bridge embedded xmp:Rating=3 should be read");
        assert_eq!(data.flag, None);
    }

    #[test]
    fn write_includes_label_color_for_bridge_compat() {
        let tmp_dir = std::env::temp_dir().join("bridge_lite_labelcolor_test");
        std::fs::create_dir_all(&tmp_dir).unwrap();
        let fake_img = tmp_dir.join("test.ARW");
        std::fs::write(&fake_img, b"").unwrap();

        let data_in = XmpData { rating: Some(3), label: Some(Label::Red), flag: None, developed: false };
        write_sidecar(&fake_img, &data_in).expect("write should succeed");

        let xml = std::fs::read_to_string(tmp_dir.join("test.xmp")).unwrap();
        assert!(xml.contains("xmp:Label") || xml.contains("Label>"), "xmp:Label must be present");
        assert!(xml.contains("LabelColor"), "photoshop:LabelColor must be present for Bridge compat");
        assert!(xml.contains("red"), "LabelColor value must be lowercase 'red'");

        let data_out = read_sidecar(&fake_img).unwrap();
        assert_eq!(data_out.label, Some(Label::Red));

        let _ = std::fs::remove_dir_all(&tmp_dir);
    }

    #[test]
    fn roundtrip_write_then_read() {
        let tmp_dir = std::env::temp_dir().join("bridge_lite_xmp_test");
        std::fs::create_dir_all(&tmp_dir).unwrap();
        let fake_img = tmp_dir.join("test_img.ARW");
        std::fs::write(&fake_img, b"").unwrap();

        let data_in = XmpData { rating: Some(4), label: Some(Label::Green), flag: None, developed: false };
        write_sidecar(&fake_img, &data_in).expect("write_sidecar should succeed");

        let data_out = read_sidecar(&fake_img).expect("read_sidecar should succeed");
        assert_eq!(data_out.rating, Some(4));
        assert_eq!(data_out.label, Some(Label::Green));
        assert_eq!(data_out.flag, None);

        let _ = std::fs::remove_dir_all(&tmp_dir);
    }

    #[test]
    fn roundtrip_reject_flag() {
        let tmp_dir = std::env::temp_dir().join("bridge_lite_xmp_reject_test");
        std::fs::create_dir_all(&tmp_dir).unwrap();
        let fake_img = tmp_dir.join("reject_img.ARW");
        std::fs::write(&fake_img, b"").unwrap();

        let data_in = XmpData { rating: None, label: None, flag: Some(Flag::Reject), developed: false };
        write_sidecar(&fake_img, &data_in).unwrap();
        let data_out = read_sidecar(&fake_img).unwrap();
        assert_eq!(data_out.flag, Some(Flag::Reject));
        assert_eq!(data_out.rating, None);

        let _ = std::fs::remove_dir_all(&tmp_dir);
    }

    #[test]
    fn write_preserves_existing_properties() {
        let arw = Path::new("/Users/itotsum/work/bridge-lite/test/20260221/raw/DSE06383.ARW");
        let _original = read_sidecar(arw).expect("test sidecar should exist");

        let tmp_dir = std::env::temp_dir().join("bridge_lite_xmp_preserve_test");
        std::fs::create_dir_all(&tmp_dir).unwrap();
        let tmp_img = tmp_dir.join("DSE06383.ARW");
        let src_xmp = arw.with_extension("xmp");
        let dst_xmp = tmp_dir.join("DSE06383.xmp");
        std::fs::copy(&src_xmp, &dst_xmp).expect("should copy test XMP");
        std::fs::write(&tmp_img, b"").unwrap();

        let new_data = XmpData { rating: Some(3), label: None, flag: None, developed: false };
        write_sidecar(&tmp_img, &new_data).unwrap();

        let result = read_sidecar(&tmp_img).unwrap();
        assert_eq!(result.rating, Some(3));

        let xml = std::fs::read_to_string(&dst_xmp).unwrap();
        assert!(xml.contains("xmp:Rating"), "Rating property should be present");

        let _ = std::fs::remove_dir_all(&tmp_dir);
    }

    #[test]
    fn detects_developed_via_crs_raw_filename() {
        let _ = XmpMeta::register_namespace(NS_CRS, "crs");
        let mut meta = XmpMeta::new().unwrap();
        meta.set_property(NS_CRS, "RawFileName", &XmpValue::new("test.ARW".to_string()))
            .unwrap();
        let data = parse_xmp_data(&meta);
        assert!(data.developed, "crs:RawFileName should flag developed");
    }

    #[test]
    fn detects_developed_via_dxo_namespace() {
        let _ = XmpMeta::register_namespace(NS_DXO, "DxO");
        let mut meta = XmpMeta::new().unwrap();
        meta.set_property(NS_DXO, "WhiteLevel", &XmpValue::new("31742".to_string()))
            .unwrap();
        let data = parse_xmp_data(&meta);
        assert!(data.developed, "DxO:WhiteLevel should flag developed");
    }

    #[test]
    fn does_not_flag_camera_original_jpg() {
        let mut meta = XmpMeta::new().unwrap();
        meta.set_property_i32(xmp_ns::XMP, "Rating", &XmpValue::new(3)).unwrap();
        let data = parse_xmp_data(&meta);
        assert!(!data.developed, "plain xmp:Rating must not flag developed");
    }

    fn make_meta_with_history(agent: &str, changed: Option<&str>) -> XmpMeta {
        let changed_attr = match changed {
            Some(c) => format!(r#" stEvt:changed="{}""#, c),
            None => String::new(),
        };
        let xml = format!(
            r#"<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
<rdf:Description rdf:about=""
  xmlns:xmpMM="http://ns.adobe.com/xap/1.0/mm/"
  xmlns:stEvt="http://ns.adobe.com/xap/1.0/sType/ResourceEvent#">
  <xmpMM:History>
    <rdf:Seq>
      <rdf:li stEvt:action="saved" stEvt:softwareAgent="{agent}"{changed}/>
    </rdf:Seq>
  </xmpMM:History>
</rdf:Description>
</rdf:RDF>
</x:xmpmeta><?xpacket end="w"?>"#,
            agent = agent,
            changed = changed_attr,
        );
        XmpMeta::from_str(&xml).expect("parse test XMP")
    }

    #[test]
    fn ignores_bridge_metadata_only_history() {
        let meta = make_meta_with_history("Adobe Photoshop Camera Raw 18.1", Some("/metadata"));
        let data = parse_xmp_data(&meta);
        assert!(!data.developed,
            "Camera Raw entry with stEvt:changed=/metadata must NOT flag developed");
    }

    #[test]
    fn detects_developed_via_history_real_edit() {
        let meta = make_meta_with_history("Adobe Photoshop Lightroom 13.0", Some("/"));
        let data = parse_xmp_data(&meta);
        assert!(data.developed,
            "Lightroom entry with stEvt:changed=/ must flag developed");
    }

    #[test]
    fn detects_developed_via_history_crs_settings_change() {
        let meta = make_meta_with_history("Adobe Photoshop Camera Raw 18.1", Some("/metadata/crs"));
        let data = parse_xmp_data(&meta);
        assert!(data.developed,
            "/metadata/crs (Camera Raw settings change) must flag developed");
    }

    #[test]
    fn roundtrip_embedded_jpg() {
        // Copy a small JPG to temp dir, write rating+label, read back.
        let src_jpg = Path::new("/Users/itotsum/work/bridge-lite/test/20260221/jpg/DSE06419.JPG");
        if !src_jpg.exists() {
            return; // Skip if test asset unavailable
        }

        let tmp_dir = std::env::temp_dir().join("bridge_lite_embedded_test");
        std::fs::create_dir_all(&tmp_dir).unwrap();
        let tmp_jpg = tmp_dir.join("DSE06419.JPG");
        std::fs::copy(src_jpg, &tmp_jpg).expect("copy test JPG");

        let data_in = XmpData { rating: Some(5), label: Some(Label::Red), flag: None, developed: false };
        write_metadata(&tmp_jpg, &data_in).expect("write_embedded should succeed");

        // Must NOT have created a sidecar
        assert!(
            !tmp_dir.join("DSE06419.xmp").exists(),
            "write_metadata must not create a sidecar for JPG"
        );

        let data_out = read_metadata(&tmp_jpg).expect("read_embedded should succeed");
        assert_eq!(data_out.rating, Some(5));
        assert_eq!(data_out.label, Some(Label::Red));
        assert_eq!(data_out.flag, None);

        let _ = std::fs::remove_dir_all(&tmp_dir);
    }

    #[test]
    #[cfg(target_os = "macos")]
    fn embedded_write_preserves_btime() {
        let src_jpg = Path::new("/Users/itotsum/work/bridge-lite/test/20260221/jpg/DSE06419.JPG");
        if !src_jpg.exists() {
            return;
        }

        let tmp_dir = std::env::temp_dir().join("bridge_lite_btime_test");
        std::fs::create_dir_all(&tmp_dir).unwrap();
        let tmp_jpg = tmp_dir.join("DSE06419.JPG");
        std::fs::copy(src_jpg, &tmp_jpg).expect("copy test JPG");

        let btime_before = std::fs::metadata(&tmp_jpg).unwrap().st_birthtime();

        let data = XmpData { rating: Some(2), label: None, flag: None, developed: false };
        write_metadata(&tmp_jpg, &data).expect("write_embedded should succeed");

        let btime_after = std::fs::metadata(&tmp_jpg).unwrap().st_birthtime();
        assert_eq!(btime_before, btime_after, "btime must be preserved after embedded write");

        let _ = std::fs::remove_dir_all(&tmp_dir);
    }
}
