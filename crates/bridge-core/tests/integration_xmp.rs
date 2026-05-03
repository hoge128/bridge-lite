use bridge_core::xmp::{Flag, Label, XmpData, write_sidecar, read_sidecar, read_metadata};

#[test]
fn roundtrip_write_then_read() {
    let tmp_dir = std::env::temp_dir().join("bridge_core_xmp_test");
    std::fs::create_dir_all(&tmp_dir).unwrap();
    let fake_img = tmp_dir.join("test_img.ARW");
    std::fs::write(&fake_img, b"").unwrap();

    let data_in = XmpData { rating: Some(4), label: Some(Label::Green), ..Default::default() };
    write_sidecar(&fake_img, &data_in).expect("write_sidecar should succeed");

    let data_out = read_sidecar(&fake_img).expect("read_sidecar should succeed");
    assert_eq!(data_out.rating, Some(4));
    assert_eq!(data_out.label, Some(Label::Green));
    assert_eq!(data_out.flag, None);

    let _ = std::fs::remove_dir_all(&tmp_dir);
}

#[test]
fn roundtrip_reject_flag() {
    let tmp_dir = std::env::temp_dir().join("bridge_core_xmp_reject_test");
    std::fs::create_dir_all(&tmp_dir).unwrap();
    let fake_img = tmp_dir.join("reject_img.ARW");
    std::fs::write(&fake_img, b"").unwrap();

    let data_in = XmpData { flag: Some(Flag::Reject), ..Default::default() };
    write_sidecar(&fake_img, &data_in).unwrap();
    let data_out = read_sidecar(&fake_img).unwrap();
    assert_eq!(data_out.flag, Some(Flag::Reject));
    assert_eq!(data_out.rating, None);

    let _ = std::fs::remove_dir_all(&tmp_dir);
}

#[test]
fn write_includes_label_color_for_bridge_compat() {
    let tmp_dir = std::env::temp_dir().join("bridge_core_labelcolor_test");
    std::fs::create_dir_all(&tmp_dir).unwrap();
    let fake_img = tmp_dir.join("test.ARW");
    std::fs::write(&fake_img, b"").unwrap();

    let data_in = XmpData { rating: Some(3), label: Some(Label::Red), ..Default::default() };
    write_sidecar(&fake_img, &data_in).expect("write should succeed");

    let xml = std::fs::read_to_string(tmp_dir.join("test.xmp")).unwrap();
    assert!(xml.contains("xmp:Label") || xml.contains("Label>"), "xmp:Label must be present");
    assert!(xml.contains("LabelColor"), "photoshop:LabelColor must be present");
    assert!(xml.contains("red"), "LabelColor value must be lowercase 'red'");

    let data_out = read_sidecar(&fake_img).unwrap();
    assert_eq!(data_out.label, Some(Label::Red));

    let _ = std::fs::remove_dir_all(&tmp_dir);
}

/// Bridge writes xmp:Label="Select" (or localized "選択") for Red.
/// Saving with the same Red color should preserve the original label text.
#[test]
fn preserve_label_text_when_same_color() {
    let tmp_dir = std::env::temp_dir().join("bridge_lite_preserve_label_same_color");
    std::fs::create_dir_all(&tmp_dir).unwrap();
    let fake_img = tmp_dir.join("img.ARW");
    std::fs::write(&fake_img, b"").unwrap();

    // Pre-populate sidecar with Bridge-style "Select" label (maps to Red)
    let xmp_path = tmp_dir.join("img.xmp");
    std::fs::write(&xmp_path, r#"<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
<rdf:Description rdf:about=""
  xmlns:xmp="http://ns.adobe.com/xap/1.0/"
  xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
  xmp:Label="Select"
  photoshop:LabelColor="red"/>
</rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>"#).unwrap();

    // Write Red label — should preserve "Select" since it maps to same color
    let data = XmpData { label: Some(Label::Red), ..Default::default() };
    write_sidecar(&fake_img, &data).expect("write_sidecar should succeed");

    let xml_after = std::fs::read_to_string(&xmp_path).unwrap();
    assert!(xml_after.contains("Select"), "Bridge label text 'Select' must be preserved when re-saving same Red color");

    let data_out = read_sidecar(&fake_img).unwrap();
    assert_eq!(data_out.label, Some(Label::Red), "Color must still be Red");

    let _ = std::fs::remove_dir_all(&tmp_dir);
}

/// DNG files try embedded XMP first; if that fails they fall back to sidecar.
/// This verifies that read_metadata on a .dng path reaches the sidecar when
/// embedded parsing returns nothing (e.g. empty file has no TIFF header).
#[test]
fn dng_falls_back_to_sidecar_when_no_embedded_xmp() {
    let tmp_dir = std::env::temp_dir().join("bridge_core_dng_dispatch_test");
    std::fs::create_dir_all(&tmp_dir).unwrap();
    let fake_dng = tmp_dir.join("photo.dng");
    // Empty file: embedded XMP extraction will fail gracefully.
    std::fs::write(&fake_dng, b"").unwrap();

    let data_in = XmpData { rating: Some(2), label: Some(Label::Blue), ..Default::default() };
    write_sidecar(&fake_dng, &data_in).unwrap();

    let data_out = read_metadata(&fake_dng, false)
        .expect("read_metadata must fall back to sidecar for DNG when embedded XMP is absent");
    assert_eq!(data_out.rating, Some(2));
    assert_eq!(data_out.label, Some(Label::Blue));

    let _ = std::fs::remove_dir_all(&tmp_dir);
}

/// When the color changes, xmp:Label must be updated to the canonical English name.
#[test]
fn overwrite_label_text_when_color_changes() {
    let tmp_dir = std::env::temp_dir().join("bridge_lite_overwrite_label_color_change");
    std::fs::create_dir_all(&tmp_dir).unwrap();
    let fake_img = tmp_dir.join("img.ARW");
    std::fs::write(&fake_img, b"").unwrap();

    // Pre-populate sidecar with "Select" (Red)
    let xmp_path = tmp_dir.join("img.xmp");
    std::fs::write(&xmp_path, r#"<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
<rdf:Description rdf:about=""
  xmlns:xmp="http://ns.adobe.com/xap/1.0/"
  xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
  xmp:Label="Select"
  photoshop:LabelColor="red"/>
</rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>"#).unwrap();

    // Change to Yellow — "Select" must be overwritten with "Yellow"
    let data = XmpData { label: Some(Label::Yellow), ..Default::default() };
    write_sidecar(&fake_img, &data).expect("write_sidecar should succeed");

    let xml_after = std::fs::read_to_string(&xmp_path).unwrap();
    assert!(xml_after.contains("Yellow"), "xmp:Label must be updated to 'Yellow'");
    assert!(!xml_after.contains("Select"), "Old 'Select' label text must be replaced");

    let data_out = read_sidecar(&fake_img).unwrap();
    assert_eq!(data_out.label, Some(Label::Yellow), "Color must be Yellow");

    let _ = std::fs::remove_dir_all(&tmp_dir);
}
