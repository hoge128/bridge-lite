use bridge_core::xmp::{Flag, Label, XmpData, write_sidecar, read_sidecar};

#[test]
fn roundtrip_write_then_read() {
    let tmp_dir = std::env::temp_dir().join("bridge_core_xmp_test");
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
    let tmp_dir = std::env::temp_dir().join("bridge_core_xmp_reject_test");
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
fn write_includes_label_color_for_bridge_compat() {
    let tmp_dir = std::env::temp_dir().join("bridge_core_labelcolor_test");
    std::fs::create_dir_all(&tmp_dir).unwrap();
    let fake_img = tmp_dir.join("test.ARW");
    std::fs::write(&fake_img, b"").unwrap();

    let data_in = XmpData { rating: Some(3), label: Some(Label::Red), flag: None, developed: false };
    write_sidecar(&fake_img, &data_in).expect("write should succeed");

    let xml = std::fs::read_to_string(tmp_dir.join("test.xmp")).unwrap();
    assert!(xml.contains("xmp:Label") || xml.contains("Label>"), "xmp:Label must be present");
    assert!(xml.contains("LabelColor"), "photoshop:LabelColor must be present");
    assert!(xml.contains("red"), "LabelColor value must be lowercase 'red'");

    let data_out = read_sidecar(&fake_img).unwrap();
    assert_eq!(data_out.label, Some(Label::Red));

    let _ = std::fs::remove_dir_all(&tmp_dir);
}
