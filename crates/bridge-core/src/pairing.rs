use std::collections::HashMap;

use chrono::NaiveDateTime;

use crate::metadata::ExifData;
use crate::scanner::ImageEntry;

/// Parse EXIF datetime "YYYY:MM:DD HH:MM:SS" → Unix timestamp (seconds).
fn parse_datetime_secs(dt: &str) -> Option<i64> {
    NaiveDateTime::parse_from_str(dt, "%Y:%m:%d %H:%M:%S")
        .ok()
        .map(|ndt| ndt.and_utc().timestamp())
}

/// Derive a new shot_id when splitting a stem-based group by timestamp.
/// Mixes the original shot_id with the cluster's earliest timestamp so that the
/// same split always produces the same ID (deterministic, collision-resistant).
fn derive_split_id(base: u64, cluster: &[usize], exif: &HashMap<usize, ExifData>) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    base.hash(&mut h);
    let min_ts = cluster
        .iter()
        .filter_map(|&id| exif.get(&id)?.datetime.as_deref().and_then(parse_datetime_secs))
        .min();
    match min_ts {
        Some(ts) => ts.hash(&mut h),
        None     => cluster.len().hash(&mut h),
    }
    let id = h.finish();
    if id == base { id ^ 0xDEAD_BEEF_CAFE_1234 } else { id }
}

/// Split a single stem-based group into temporal clusters if any two members are
/// more than `split_threshold_secs` apart. Members without EXIF datetimes are kept
/// in the first (earliest) cluster.
fn split_by_timestamp(
    members: &[usize],
    exif: &HashMap<usize, ExifData>,
    original_shot_id: u64,
    split_threshold_secs: i64,
) -> Vec<(u64, Vec<usize>)> {
    let mut timestamped: Vec<(usize, Option<i64>)> = members
        .iter()
        .map(|&id| {
            let ts = exif.get(&id)
                .and_then(|e| e.datetime.as_deref())
                .and_then(parse_datetime_secs);
            (id, ts)
        })
        .collect();

    let all_ts: Vec<i64> = timestamped.iter().filter_map(|(_, t)| *t).collect();
    if all_ts.is_empty() {
        return vec![(original_shot_id, members.to_vec())];
    }
    let span = all_ts.iter().max().unwrap() - all_ts.iter().min().unwrap();
    if span <= split_threshold_secs {
        return vec![(original_shot_id, members.to_vec())];
    }

    // Sort by timestamp; entries without timestamps go last.
    timestamped.sort_by_key(|(_, ts)| ts.unwrap_or(i64::MAX));

    let mut clusters: Vec<Vec<usize>> = Vec::new();
    let mut unknown: Vec<usize> = Vec::new();
    let mut current: Vec<usize> = Vec::new();
    let mut cluster_start: i64 = 0;

    for (id, ts) in timestamped {
        match ts {
            Some(t) => {
                if current.is_empty() {
                    cluster_start = t;
                    current.push(id);
                } else if t - cluster_start <= split_threshold_secs {
                    current.push(id);
                } else {
                    clusters.push(std::mem::take(&mut current));
                    cluster_start = t;
                    current.push(id);
                }
            }
            None => unknown.push(id),
        }
    }
    if !current.is_empty() {
        clusters.push(current);
    }
    if clusters.is_empty() {
        return vec![(original_shot_id, members.to_vec())];
    }

    // First cluster keeps the original shot_id; EXIF-lacking entries go with it.
    let mut first = clusters.remove(0);
    first.extend_from_slice(&unknown);
    let mut result = vec![(original_shot_id, first)];

    for cluster in clusters {
        let new_id = derive_split_id(original_shot_id, &cluster, exif);
        result.push((new_id, cluster));
    }
    result
}

fn sort_groups(groups: &mut HashMap<u64, Vec<usize>>, images: &[ImageEntry]) {
    for group in groups.values_mut() {
        group.sort_by(|&a, &b| {
            let ea = &images[a];
            let eb = &images[b];
            let ka = ea.created.or(ea.modified);
            let kb = eb.created.or(eb.modified);
            ka.cmp(&kb)
                .then_with(|| ea.is_raw.cmp(&eb.is_raw))
                .then_with(|| ea.filename.to_lowercase().cmp(&eb.filename.to_lowercase()))
        });
    }
}

/// Returns true when every member of a group lacks an EXIF datetime (IAD = Indeterminate).
/// IAD groups are candidates for phash-based rescue into confirmed groups.
fn is_iad_group(members: &[usize], exif: &HashMap<usize, ExifData>) -> bool {
    !members.is_empty()
        && members.iter().all(|&id| {
            exif.get(&id).and_then(|e| e.datetime.as_deref()).is_none()
        })
}

/// Default EXIF datetime gap (seconds) above which same-stem files are split into separate groups.
pub const DEFAULT_SPLIT_THRESHOLD_SECS: i64 = 2;

/// Default pHash Hamming distance threshold for IAD rescue.
/// IAD rescue is constrained to IAD→confirmed only, so a looser threshold is safe.
/// Cross-format exports (e.g. RAW → HEIC/PNG/WebP) typically land at hamming ≤ 14;
/// clearly different images are typically hamming ≥ 20.
pub const DEFAULT_PHASH_HAMMING_THRESHOLD: u32 = 15;

/// Re-group images after all EXIF and pHash data have been indexed.
///
/// Three tiers are applied in order:
///
/// 1. **Tier 1** — same normalised stem ∧ EXIF datetime span ≤ 2s → same group.
/// 2. **Tier 2** — same normalised stem ∧ EXIF datetime span > 2s → split into
///    temporal sub-groups (handles cross-camera same-name collisions).
/// 3. **Tier 3** — different normalised stems → always separate groups.
///    pHash is never used to merge confirmed groups, eliminating burst-shot false merges.
///
/// **Tier 4 (IAD rescue)** — groups whose *every* member lacks an EXIF datetime are
/// matched against confirmed groups (those with at least one EXIF datetime) via pHash.
/// If `hamming(phash_IAD, phash_confirmed) ≤ PHASH_HAMMING_THRESHOLD`, the IAD group
/// is absorbed into the confirmed group.  This rescues manually-renamed developed images
/// with stripped EXIF.  IAD-to-IAD merges are never performed.
///
/// Mutates `images[*].shot_id` to reflect the new grouping and returns the new
/// `shot_groups` map.
pub fn reindex_shot_groups(
    images: &mut [ImageEntry],
    exif: &HashMap<usize, ExifData>,
    phashes: &HashMap<usize, u64>,
    split_threshold_secs: i64,
    phash_hamming_threshold: u32,
) -> HashMap<u64, Vec<usize>> {
    // ── Phase 1: seed from stem-based shot_id ─────────────────────────────
    let mut groups: HashMap<u64, Vec<usize>> = HashMap::new();
    for entry in images.iter() {
        groups.entry(entry.shot_id).or_default().push(entry.id);
    }

    // ── Phase 2: split groups with large timestamp spans (Tier 1 / Tier 2) ─
    let shot_ids: Vec<u64> = groups.keys().cloned().collect();
    let mut working: HashMap<u64, Vec<usize>> = HashMap::new();

    for shot_id in shot_ids {
        let members = groups.remove(&shot_id).unwrap();
        let subgroups = split_by_timestamp(&members, exif, shot_id, split_threshold_secs);
        for (new_id, subgroup) in subgroups {
            if new_id != shot_id {
                for &id in &subgroup {
                    if let Some(entry) = images.get_mut(id) {
                        entry.shot_id = new_id;
                    }
                }
            }
            working.insert(new_id, subgroup);
        }
    }

    // ── Tier 4: IAD-rescue phash merge ────────────────────────────────────
    // Classify each group as IAD (all members lack EXIF datetime) or confirmed.
    // Only merge IAD → confirmed; confirmed-confirmed merges are forbidden.
    let group_ids: Vec<u64> = working.keys().cloned().collect();

    let is_iad: HashMap<u64, bool> = group_ids
        .iter()
        .map(|&sid| {
            let members = working.get(&sid).map(|v| v.as_slice()).unwrap_or(&[]);
            (sid, is_iad_group(members, exif))
        })
        .collect();

    let group_phash: HashMap<u64, Option<u64>> = group_ids
        .iter()
        .map(|&sid| {
            let members = working.get(&sid).map(|v| v.as_slice()).unwrap_or(&[]);
            (sid, majority_vote_phash(members, phashes))
        })
        .collect();

    // Returns the raw file stem (before normalization) of the first member of a group.
    let group_stem = |sid: u64| -> Option<String> {
        let first_id = *working.get(&sid)?.first()?;
        let filename = &images.get(first_id)?.filename;
        std::path::Path::new(filename)
            .file_stem()
            .and_then(|s| s.to_str())
            .map(|s| s.to_string())
    };

    // For each IAD group, find the first confirmed group within hamming threshold.
    let mut iad_to_confirmed: HashMap<u64, u64> = HashMap::new();
    for &iad_id in group_ids.iter().filter(|&&id| is_iad[&id]) {
        let Some(ha) = group_phash[&iad_id] else { continue };
        let iad_stem = group_stem(iad_id);
        for &conf_id in group_ids.iter().filter(|&&id| !is_iad[&id]) {
            // If both groups have DCF camera-generated stems they are distinct shots
            // (e.g. DSC02087 vs DSC02086). Skip rescue to avoid burst-shot false merges.
            if let (Some(ia), Some(ca)) = (&iad_stem, group_stem(conf_id)) {
                if crate::scanner::is_camera_generated_stem(ia)
                    && crate::scanner::is_camera_generated_stem(&ca)
                {
                    continue;
                }
            }
            let Some(hb) = group_phash[&conf_id] else { continue };
            if crate::phash::hamming(ha, hb) <= phash_hamming_threshold {
                iad_to_confirmed.insert(iad_id, conf_id);
                break;
            }
        }
    }

    let mut working = if iad_to_confirmed.is_empty() {
        working
    } else {
        let mut final_groups: HashMap<u64, Vec<usize>> = HashMap::new();
        for (shot_id, members) in working {
            let canon = iad_to_confirmed.get(&shot_id).copied().unwrap_or(shot_id);
            let target = final_groups.entry(canon).or_default();
            for id in members {
                if !target.contains(&id) {
                    target.push(id);
                }
            }
        }
        for (&canon_id, members) in &final_groups {
            for &id in members {
                if let Some(entry) = images.get_mut(id) {
                    entry.shot_id = canon_id;
                }
            }
        }
        final_groups
    };

    sort_groups(&mut working, images);
    working
}

/// Compute a representative pHash for a group via bit-wise majority vote.
/// Each bit in the output is 1 iff more than half the members have that bit set.
/// Returns `None` if no member has a pHash.
fn majority_vote_phash(members: &[usize], phashes: &HashMap<usize, u64>) -> Option<u64> {
    let hashes: Vec<u64> = members.iter().filter_map(|id| phashes.get(id).copied()).collect();
    if hashes.is_empty() {
        return None;
    }
    let threshold = hashes.len() as u32;
    let mut result = 0u64;
    for bit in 0..64u32 {
        let ones: u32 = hashes.iter().map(|&h| ((h >> bit) & 1) as u32).sum();
        if ones * 2 >= threshold {
            result |= 1u64 << bit;
        }
    }
    Some(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::time::SystemTime;

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

    fn make_entry_with_filename(id: usize, shot_id: u64, filename: &str) -> ImageEntry {
        ImageEntry {
            id,
            path: PathBuf::from(format!("/tmp/{filename}")),
            filename: filename.to_string(),
            is_raw: filename.to_ascii_lowercase().ends_with(".arw"),
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
        exif.insert(1, exif_with_datetime("2026:04:21 10:00:01", None)); // 1s gap (≤ 2s)

        let groups = reindex_shot_groups(&mut images, &exif, &HashMap::new(), DEFAULT_SPLIT_THRESHOLD_SECS, DEFAULT_PHASH_HAMMING_THRESHOLD);
        assert_eq!(groups.len(), 1);
        let g = groups.values().next().unwrap();
        assert_eq!(g.len(), 2);
    }

    #[test]
    fn splits_group_beyond_threshold() {
        let mut images = vec![make_entry(0, 1), make_entry(1, 1)];
        let mut exif = HashMap::new();
        exif.insert(0, exif_with_datetime("2026:04:21 10:00:00", None));
        exif.insert(1, exif_with_datetime("2026:04:21 10:00:30", None)); // 30s gap

        let groups = reindex_shot_groups(&mut images, &exif, &HashMap::new(), DEFAULT_SPLIT_THRESHOLD_SECS, DEFAULT_PHASH_HAMMING_THRESHOLD);
        assert_eq!(groups.len(), 2, "should split into two groups");
        assert_ne!(images[0].shot_id, images[1].shot_id, "shot_id should differ after split");
    }

    #[test]
    fn missing_exif_stays_in_original_group() {
        let mut images = vec![make_entry(0, 1), make_entry(1, 1), make_entry(2, 1)];
        let mut exif = HashMap::new();
        exif.insert(0, exif_with_datetime("2026:04:21 10:00:00", None));
        exif.insert(1, exif_with_datetime("2026:04:21 10:01:00", None)); // 60s gap
        // id=2 has no EXIF

        let groups = reindex_shot_groups(&mut images, &exif, &HashMap::new(), DEFAULT_SPLIT_THRESHOLD_SECS, DEFAULT_PHASH_HAMMING_THRESHOLD);
        // id=0 and id=2 (no EXIF) should be in one group; id=1 in another
        assert_eq!(groups.len(), 2);
        let group_of_0 = images[0].shot_id;
        assert_eq!(images[2].shot_id, group_of_0, "EXIF-lacking entry stays with earliest cluster");
        assert_ne!(images[1].shot_id, group_of_0);
    }

    #[test]
    fn different_stems_not_merged_even_with_same_datetime() {
        // Tier 3: different stem groups are never merged regardless of datetime or subsec.
        let mut images = vec![make_entry(0, 1), make_entry(1, 2)];
        let mut exif = HashMap::new();
        exif.insert(0, exif_with_datetime("2026:04:21 10:00:00", None));
        exif.insert(1, exif_with_datetime("2026:04:21 10:00:00", None));

        let groups = reindex_shot_groups(&mut images, &exif, &HashMap::new(), DEFAULT_SPLIT_THRESHOLD_SECS, DEFAULT_PHASH_HAMMING_THRESHOLD);
        assert_eq!(groups.len(), 2, "different stems must never merge");
    }

    #[test]
    fn iad_group_merges_into_confirmed_by_phash() {
        // Tier 4: IAD group (no EXIF datetime) + confirmed group + close phash → merge.
        let mut images = vec![make_entry(0, 10), make_entry(1, 20)];
        let mut exif = HashMap::new();
        // Only entry 1 has EXIF datetime (confirmed); entry 0 is IAD.
        exif.insert(1, exif_with_datetime("2026:04:21 10:00:00", None));
        let mut phashes = HashMap::new();
        phashes.insert(0, 0x0000_0000_0000_0FFFu64);
        phashes.insert(1, 0x0000_0000_0000_1FFFu64); // hamming = 1

        let groups = reindex_shot_groups(&mut images, &exif, &phashes, DEFAULT_SPLIT_THRESHOLD_SECS, DEFAULT_PHASH_HAMMING_THRESHOLD);
        assert_eq!(groups.len(), 1, "IAD group should merge into confirmed group via phash");
        assert_eq!(images[0].shot_id, images[1].shot_id);
    }

    #[test]
    fn confirmed_confirmed_never_merge_by_phash() {
        // Burst-shot safety: two confirmed groups (both have EXIF) must never merge by phash.
        let mut images = vec![make_entry(0, 10), make_entry(1, 20)];
        let mut exif = HashMap::new();
        exif.insert(0, exif_with_datetime("2026:04:21 10:00:00", None));
        exif.insert(1, exif_with_datetime("2026:04:21 10:00:01", None)); // 1s apart, close phash
        let mut phashes = HashMap::new();
        phashes.insert(0, 0x0000_0000_0000_0FFFu64);
        phashes.insert(1, 0x0000_0000_0000_1FFFu64); // hamming = 1

        let groups = reindex_shot_groups(&mut images, &exif, &phashes, DEFAULT_SPLIT_THRESHOLD_SECS, DEFAULT_PHASH_HAMMING_THRESHOLD);
        assert_eq!(groups.len(), 2, "confirmed-confirmed must never merge by phash (burst-shot safety)");
        assert_ne!(images[0].shot_id, images[1].shot_id);
    }

    #[test]
    fn iad_no_merge_when_hamming_too_high() {
        // IAD + confirmed group but high hamming distance → no rescue merge.
        let mut images = vec![make_entry(0, 10), make_entry(1, 20)];
        let mut exif = HashMap::new();
        exif.insert(1, exif_with_datetime("2026:04:21 10:00:00", None)); // entry 1 is confirmed
        // entry 0 has no EXIF (IAD)
        let mut phashes = HashMap::new();
        phashes.insert(0, 0x0000_FFFF_0000_FFFFu64);
        phashes.insert(1, 0xFFFF_0000_FFFF_0000u64); // hamming = 32

        let groups = reindex_shot_groups(&mut images, &exif, &phashes, DEFAULT_SPLIT_THRESHOLD_SECS, DEFAULT_PHASH_HAMMING_THRESHOLD);
        assert_eq!(groups.len(), 2, "must not merge IAD when hamming distance is high");
    }

    #[test]
    fn iad_iad_never_merge() {
        // Two IAD groups (both lack EXIF datetime) must never merge even with close phash.
        let mut images = vec![make_entry(0, 10), make_entry(1, 20)];
        let exif: HashMap<usize, ExifData> = HashMap::new(); // no EXIF for either
        let mut phashes = HashMap::new();
        phashes.insert(0, 0x0000_0000_0000_0FFFu64);
        phashes.insert(1, 0x0000_0000_0000_1FFFu64); // hamming = 1

        let groups = reindex_shot_groups(&mut images, &exif, &phashes, DEFAULT_SPLIT_THRESHOLD_SECS, DEFAULT_PHASH_HAMMING_THRESHOLD);
        assert_eq!(groups.len(), 2, "IAD-IAD must not merge");
        assert_ne!(images[0].shot_id, images[1].shot_id);
    }

    #[test]
    fn iad_rescue_works_without_datetime_constraint() {
        // IAD rescue has no datetime window — EXIF timestamp of the confirmed group is irrelevant.
        let mut images = vec![make_entry(0, 10), make_entry(1, 20)];
        let mut exif = HashMap::new();
        exif.insert(1, exif_with_datetime("2026:03:31 23:59:59", None)); // confirmed, month boundary
        // entry 0 has no EXIF (IAD)
        let mut phashes = HashMap::new();
        phashes.insert(0, 0x0000_0000_0000_0FFFu64);
        phashes.insert(1, 0x0000_0000_0000_1FFFu64); // hamming = 1

        let groups = reindex_shot_groups(&mut images, &exif, &phashes, DEFAULT_SPLIT_THRESHOLD_SECS, DEFAULT_PHASH_HAMMING_THRESHOLD);
        assert_eq!(groups.len(), 1, "IAD rescue should work regardless of timestamp");
    }

    #[test]
    fn iad_camera_stem_not_rescued_into_camera_confirmed() {
        // DSC02087.JPG (IAD, DCF camera name) must NOT rescue into DSC02086 group (confirmed).
        // Reproduces the inada/ test case: three files incorrectly merged into one group.
        let mut images = vec![
            make_entry_with_filename(0, 10, "DSC02087.JPG"),
            make_entry_with_filename(1, 20, "DSC02086.JPG"),
        ];
        let mut exif = HashMap::new();
        exif.insert(1, exif_with_datetime("2026:04:28 13:45:24", None)); // entry 1 confirmed
        let mut phashes = HashMap::new();
        phashes.insert(0, 0x0000_0000_0000_0FFFu64);
        phashes.insert(1, 0x0000_0000_0000_1FFFu64); // hamming = 1 (burst-like similarity)
        let groups = reindex_shot_groups(&mut images, &exif, &phashes, DEFAULT_SPLIT_THRESHOLD_SECS, DEFAULT_PHASH_HAMMING_THRESHOLD);
        assert_eq!(groups.len(), 2, "camera-named IAD must not rescue into camera-named confirmed");
        assert_ne!(images[0].shot_id, images[1].shot_id);
    }

    #[test]
    fn iad_non_camera_stem_still_rescues_into_camera_confirmed() {
        // portrait_edit.jpg (IAD, non-camera name) CAN still rescue into DSC02086 group.
        // This is the primary Tier 4 use case: EXIF-stripped developed image.
        let mut images = vec![
            make_entry_with_filename(0, 10, "portrait_edit.jpg"),
            make_entry_with_filename(1, 20, "DSC02086.ARW"),
        ];
        let mut exif = HashMap::new();
        exif.insert(1, exif_with_datetime("2026:04:28 13:45:24", None));
        let mut phashes = HashMap::new();
        phashes.insert(0, 0x0000_0000_0000_0FFFu64);
        phashes.insert(1, 0x0000_0000_0000_1FFFu64); // hamming = 1
        let groups = reindex_shot_groups(&mut images, &exif, &phashes, DEFAULT_SPLIT_THRESHOLD_SECS, DEFAULT_PHASH_HAMMING_THRESHOLD);
        assert_eq!(groups.len(), 1, "non-camera IAD should still rescue into confirmed");
        assert_eq!(images[0].shot_id, images[1].shot_id);
    }
}
