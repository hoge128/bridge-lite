use std::collections::HashMap;
use std::path::PathBuf;
use std::time::SystemTime;

use bridge_core::metadata::ExifData;
use bridge_core::pairing::reindex_shot_groups;
use bridge_core::scanner::ImageEntry;

fn make_entry(id: usize, shot_id: u64) -> ImageEntry {
    ImageEntry {
        id,
        path: PathBuf::from(format!("/tmp/img{id}.jpg")),
        filename: format!("img{id}.jpg"),
        is_raw: false,
        file_size: 1000,
        modified: Some(SystemTime::UNIX_EPOCH),
        created:  Some(SystemTime::UNIX_EPOCH),
        has_jpg_partner: false,
        shot_id,
    }
}

fn exif_with_datetime(dt: &str, ss: Option<&str>) -> ExifData {
    ExifData {
        datetime: Some(dt.to_string()),
        subsec: ss.map(|s| s.to_string()),
        ..Default::default()
    }
}

#[test]
fn no_split_within_threshold() {
    let mut images = vec![make_entry(0, 1), make_entry(1, 1)];
    let mut exif = HashMap::new();
    exif.insert(0, exif_with_datetime("2026:04:21 10:00:00", None));
    exif.insert(1, exif_with_datetime("2026:04:21 10:00:05", None));

    let groups = reindex_shot_groups(&mut images, &exif, &HashMap::new(), bridge_core::pairing::DEFAULT_SPLIT_THRESHOLD_SECS, bridge_core::pairing::DEFAULT_PHASH_HAMMING_THRESHOLD);
    assert_eq!(groups.len(), 1);
    let g = groups.values().next().unwrap();
    assert_eq!(g.len(), 2);
}

#[test]
fn splits_group_beyond_threshold() {
    let mut images = vec![make_entry(0, 1), make_entry(1, 1)];
    let mut exif = HashMap::new();
    exif.insert(0, exif_with_datetime("2026:04:21 10:00:00", None));
    exif.insert(1, exif_with_datetime("2026:04:21 10:00:30", None));

    let groups = reindex_shot_groups(&mut images, &exif, &HashMap::new(), bridge_core::pairing::DEFAULT_SPLIT_THRESHOLD_SECS, bridge_core::pairing::DEFAULT_PHASH_HAMMING_THRESHOLD);
    assert_eq!(groups.len(), 2, "should split into two groups");
    assert_ne!(images[0].shot_id, images[1].shot_id);
}

#[test]
fn merges_cross_group_same_subsec() {
    let mut images = vec![make_entry(0, 1), make_entry(1, 2)];
    let mut exif = HashMap::new();
    exif.insert(0, exif_with_datetime("2026:04:21 10:00:00", Some("500")));
    exif.insert(1, exif_with_datetime("2026:04:21 10:00:00", Some("500")));

    let groups = reindex_shot_groups(&mut images, &exif, &HashMap::new(), bridge_core::pairing::DEFAULT_SPLIT_THRESHOLD_SECS, bridge_core::pairing::DEFAULT_PHASH_HAMMING_THRESHOLD);
    assert_eq!(groups.len(), 1, "should merge into one group");
    assert_eq!(images[0].shot_id, images[1].shot_id);
}

#[test]
fn no_merge_without_subsec() {
    let mut images = vec![make_entry(0, 1), make_entry(1, 2)];
    let mut exif = HashMap::new();
    exif.insert(0, exif_with_datetime("2026:04:21 10:00:00", None));
    exif.insert(1, exif_with_datetime("2026:04:21 10:00:00", None));

    let groups = reindex_shot_groups(&mut images, &exif, &HashMap::new(), bridge_core::pairing::DEFAULT_SPLIT_THRESHOLD_SECS, bridge_core::pairing::DEFAULT_PHASH_HAMMING_THRESHOLD);
    assert_eq!(groups.len(), 2, "must not merge without subsec");
}

#[test]
fn missing_exif_stays_in_original_group() {
    let mut images = vec![make_entry(0, 1), make_entry(1, 1), make_entry(2, 1)];
    let mut exif = HashMap::new();
    exif.insert(0, exif_with_datetime("2026:04:21 10:00:00", None));
    exif.insert(1, exif_with_datetime("2026:04:21 10:01:00", None));

    let groups = reindex_shot_groups(&mut images, &exif, &HashMap::new(), bridge_core::pairing::DEFAULT_SPLIT_THRESHOLD_SECS, bridge_core::pairing::DEFAULT_PHASH_HAMMING_THRESHOLD);
    assert_eq!(groups.len(), 2);
    let group_of_0 = images[0].shot_id;
    assert_eq!(images[2].shot_id, group_of_0, "EXIF-lacking entry stays with earliest cluster");
    assert_ne!(images[1].shot_id, group_of_0);
}

#[test]
fn merges_by_phash_with_close_datetime() {
    let mut images = vec![make_entry(0, 10), make_entry(1, 20)];
    let mut exif = HashMap::new();
    exif.insert(0, exif_with_datetime("2026:04:21 10:00:00", None));
    exif.insert(1, exif_with_datetime("2026:04:21 10:00:01", None));
    let mut phashes = HashMap::new();
    phashes.insert(0, 0x0000_0000_0000_0FFFu64);
    phashes.insert(1, 0x0000_0000_0000_1FFFu64);

    let groups = reindex_shot_groups(&mut images, &exif, &phashes, bridge_core::pairing::DEFAULT_SPLIT_THRESHOLD_SECS, bridge_core::pairing::DEFAULT_PHASH_HAMMING_THRESHOLD);
    assert_eq!(groups.len(), 1, "should merge by pHash + close datetime");
    assert_eq!(images[0].shot_id, images[1].shot_id);
}

#[test]
fn no_phash_merge_when_datetime_far() {
    let mut images = vec![make_entry(0, 10), make_entry(1, 20)];
    let mut exif = HashMap::new();
    exif.insert(0, exif_with_datetime("2026:04:21 10:00:00", None));
    exif.insert(1, exif_with_datetime("2026:04:21 10:01:00", None));
    let mut phashes = HashMap::new();
    phashes.insert(0, 0x0000_0000_0000_0FFFu64);
    phashes.insert(1, 0x0000_0000_0000_1FFFu64);

    let groups = reindex_shot_groups(&mut images, &exif, &phashes, bridge_core::pairing::DEFAULT_SPLIT_THRESHOLD_SECS, bridge_core::pairing::DEFAULT_PHASH_HAMMING_THRESHOLD);
    assert_eq!(groups.len(), 2, "must not merge when datetime is far apart");
    assert_ne!(images[0].shot_id, images[1].shot_id);
}

#[test]
fn no_phash_merge_when_distance_above_threshold() {
    let mut images = vec![make_entry(0, 10), make_entry(1, 20)];
    let mut exif = HashMap::new();
    exif.insert(0, exif_with_datetime("2026:04:21 10:00:00", None));
    exif.insert(1, exif_with_datetime("2026:04:21 10:00:01", None));
    let mut phashes = HashMap::new();
    phashes.insert(0, 0x0000_FFFF_0000_FFFFu64);
    phashes.insert(1, 0xFFFF_0000_FFFF_0000u64);

    let groups = reindex_shot_groups(&mut images, &exif, &phashes, bridge_core::pairing::DEFAULT_SPLIT_THRESHOLD_SECS, bridge_core::pairing::DEFAULT_PHASH_HAMMING_THRESHOLD);
    assert_eq!(groups.len(), 2, "must not merge when hamming distance is high");
}

#[test]
fn month_boundary_datetime_diff() {
    let mut images = vec![make_entry(0, 10), make_entry(1, 20)];
    let mut exif = HashMap::new();
    exif.insert(0, exif_with_datetime("2026:03:31 23:59:59", None));
    exif.insert(1, exif_with_datetime("2026:04:01 00:00:01", None));
    let mut phashes = HashMap::new();
    phashes.insert(0, 0x0000_0000_0000_0FFFu64);
    phashes.insert(1, 0x0000_0000_0000_1FFFu64);

    let groups = reindex_shot_groups(&mut images, &exif, &phashes, bridge_core::pairing::DEFAULT_SPLIT_THRESHOLD_SECS, bridge_core::pairing::DEFAULT_PHASH_HAMMING_THRESHOLD);
    assert_eq!(groups.len(), 1, "month boundary with 2s gap should merge");
}
