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

fn find_root(canonical: &mut HashMap<u64, u64>, id: u64) -> u64 {
    // Iterative path-halving compression.
    let mut cur = id;
    loop {
        match canonical.get(&cur).copied() {
            Some(parent) if parent != cur => {
                // Path compression: point cur → grandparent when possible.
                if let Some(&grandparent) = canonical.get(&parent) {
                    canonical.insert(cur, grandparent);
                    cur = grandparent;
                } else {
                    cur = parent;
                }
            }
            _ => return cur,
        }
    }
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
/// more than `SPLIT_THRESHOLD_SECS` apart. Members without EXIF datetimes are kept
/// in the first (earliest) cluster.
fn split_by_timestamp(
    members: &[usize],
    exif: &HashMap<usize, ExifData>,
    original_shot_id: u64,
) -> Vec<(u64, Vec<usize>)> {
    const SPLIT_THRESHOLD_SECS: i64 = 10;

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
    if span <= SPLIT_THRESHOLD_SECS {
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
                } else if t - cluster_start <= SPLIT_THRESHOLD_SECS {
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

/// Re-group images by EXIF timestamp after all EXIF data has been indexed.
///
/// Two operations are applied in sequence:
///
/// 1. **Split** — any stem-based group whose members span more than 10 seconds is
///    broken into temporal clusters.  EXIF-lacking members stay in the earliest cluster.
///
/// 2. **Merge** — images in different groups that share the same `(datetime, subsec)`
///    pair are unified into one group.  The `subsec` requirement prevents merging
///    consecutive single-second shots on cameras without sub-second timestamps.
///
/// Mutates `images[*].shot_id` to reflect the new grouping and returns the new
/// `shot_groups` map.
/// Hamming distance threshold for pHash similarity.
/// Kept tight (≤2) so that only true duplicates (copy/rename of the same JPEG) are merged.
/// Consecutive shots of visually similar scenes typically differ by 4+ bits; a threshold
/// of 8 was too permissive and caused false merges for burst sequences.
const PHASH_HAMMING_THRESHOLD: u32 = 2;
/// Maximum datetime gap (seconds) for pHash-based merging.
const PHASH_DATETIME_WINDOW_SECS: i64 = 2;

pub fn reindex_shot_groups(
    images: &mut [ImageEntry],
    exif: &HashMap<usize, ExifData>,
    phashes: &HashMap<usize, u64>,
) -> HashMap<u64, Vec<usize>> {
    // ── Phase 1: seed from stem-based shot_id ─────────────────────────────
    let mut groups: HashMap<u64, Vec<usize>> = HashMap::new();
    for entry in images.iter() {
        groups.entry(entry.shot_id).or_default().push(entry.id);
    }

    // ── Phase 2: split groups with large timestamp spans ──────────────────
    let shot_ids: Vec<u64> = groups.keys().cloned().collect();
    let mut working: HashMap<u64, Vec<usize>> = HashMap::new();

    for shot_id in shot_ids {
        let members = groups.remove(&shot_id).unwrap();
        let subgroups = split_by_timestamp(&members, exif, shot_id);
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

    // ── Phase 3: merge groups with identical (datetime, subsec) ───────────
    // Only merge when subsec is present: prevents false merges on cameras that
    // don't record sub-second timestamps.
    let mut ts_index: HashMap<(String, String), Vec<u64>> = HashMap::new();
    for (&shot_id, members) in &working {
        for &id in members {
            if let Some(e) = exif.get(&id) {
                if let (Some(dt), Some(ss)) = (&e.datetime, &e.subsec) {
                    let entry = ts_index.entry((dt.clone(), ss.clone())).or_default();
                    if !entry.contains(&shot_id) {
                        entry.push(shot_id);
                    }
                }
            }
        }
    }

    let mut canonical: HashMap<u64, u64> = HashMap::new();
    for group_ids in ts_index.values() {
        if group_ids.len() <= 1 { continue; }
        let first = find_root(&mut canonical, group_ids[0]);
        for &gid in &group_ids[1..] {
            let root = find_root(&mut canonical, gid);
            if root != first {
                canonical.insert(root, first);
            }
        }
    }

    // Apply Phase-3 canonical merges before Phase 4.
    let working = if canonical.is_empty() {
        working
    } else {
        let mut merged: HashMap<u64, Vec<usize>> = HashMap::new();
        for (shot_id, members) in working {
            let canon = find_root(&mut canonical, shot_id);
            let target = merged.entry(canon).or_default();
            for id in members {
                if !target.contains(&id) {
                    target.push(id);
                }
            }
        }
        for (&canon_id, members) in &merged {
            for &id in members {
                if let Some(entry) = images.get_mut(id) {
                    entry.shot_id = canon_id;
                }
            }
        }
        merged
    };

    // ── Phase 4: pHash merge ──────────────────────────────────────────────
    // For each group compute a representative pHash (bit-wise majority vote across
    // members) and the earliest datetime.  Then merge groups whose representative
    // pHashes are within PHASH_HAMMING_THRESHOLD bits AND whose datetimes are within
    // PHASH_DATETIME_WINDOW_SECS.  datetime constraint prevents false merges on
    // visually-similar scenes from different sessions.
    let mut working = working;
    let group_ids: Vec<u64> = working.keys().cloned().collect();

    // Build per-group (representative_phash, earliest_datetime_secs).
    let group_meta: HashMap<u64, (Option<u64>, Option<i64>)> = group_ids
        .iter()
        .map(|&sid| {
            let members = working.get(&sid).map(|v| v.as_slice()).unwrap_or(&[]);
            let rep_phash = majority_vote_phash(members, phashes);
            let earliest_ts = members
                .iter()
                .filter_map(|&id| {
                    exif.get(&id)?.datetime.as_deref().and_then(parse_datetime_secs)
                })
                .min();
            (sid, (rep_phash, earliest_ts))
        })
        .collect();

    let mut phash_canonical: HashMap<u64, u64> = HashMap::new();
    let ids: Vec<u64> = group_ids.clone();
    for i in 0..ids.len() {
        for j in (i + 1)..ids.len() {
            let a = ids[i];
            let b = ids[j];
            let (Some(ha), Some(ta)) = group_meta[&a] else { continue };
            let (Some(hb), Some(tb)) = group_meta[&b] else { continue };
            if crate::phash::hamming(ha, hb) > PHASH_HAMMING_THRESHOLD {
                continue;
            }
            if (ta - tb).abs() > PHASH_DATETIME_WINDOW_SECS {
                continue;
            }
            let ra = find_root(&mut phash_canonical, a);
            let rb = find_root(&mut phash_canonical, b);
            if ra != rb {
                // Prefer the smaller id as canonical root for determinism.
                if ra < rb {
                    phash_canonical.insert(rb, ra);
                } else {
                    phash_canonical.insert(ra, rb);
                }
            }
        }
    }

    if !phash_canonical.is_empty() {
        let mut final_groups: HashMap<u64, Vec<usize>> = HashMap::new();
        for (shot_id, members) in working {
            let canon = find_root(&mut phash_canonical, shot_id);
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
        working = final_groups;
    }

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

        let groups = reindex_shot_groups(&mut images, &exif, &HashMap::new());
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

        let groups = reindex_shot_groups(&mut images, &exif, &HashMap::new());
        assert_eq!(groups.len(), 2, "should split into two groups");
        assert_ne!(images[0].shot_id, images[1].shot_id, "shot_id should differ after split");
    }

    #[test]
    fn merges_cross_group_same_subsec() {
        let mut images = vec![make_entry(0, 1), make_entry(1, 2)];
        let mut exif = HashMap::new();
        // Same datetime + subsec but different stem groups → should merge
        exif.insert(0, exif_with_datetime("2026:04:21 10:00:00", Some("500")));
        exif.insert(1, exif_with_datetime("2026:04:21 10:00:00", Some("500")));

        let groups = reindex_shot_groups(&mut images, &exif, &HashMap::new());
        assert_eq!(groups.len(), 1, "should merge into one group");
        assert_eq!(images[0].shot_id, images[1].shot_id);
    }

    #[test]
    fn no_merge_without_subsec() {
        let mut images = vec![make_entry(0, 1), make_entry(1, 2)];
        let mut exif = HashMap::new();
        // Same datetime second but NO subsec → must not merge (could be consecutive shots)
        exif.insert(0, exif_with_datetime("2026:04:21 10:00:00", None));
        exif.insert(1, exif_with_datetime("2026:04:21 10:00:00", None));

        let groups = reindex_shot_groups(&mut images, &exif, &HashMap::new());
        assert_eq!(groups.len(), 2, "must not merge without subsec");
    }

    #[test]
    fn missing_exif_stays_in_original_group() {
        let mut images = vec![make_entry(0, 1), make_entry(1, 1), make_entry(2, 1)];
        let mut exif = HashMap::new();
        exif.insert(0, exif_with_datetime("2026:04:21 10:00:00", None));
        exif.insert(1, exif_with_datetime("2026:04:21 10:01:00", None)); // 60s gap
        // id=2 has no EXIF

        let groups = reindex_shot_groups(&mut images, &exif, &HashMap::new());
        // id=0 and id=2 (no EXIF) should be in one group; id=1 in another
        assert_eq!(groups.len(), 2);
        let group_of_0 = images[0].shot_id;
        assert_eq!(images[2].shot_id, group_of_0, "EXIF-lacking entry stays with earliest cluster");
        assert_ne!(images[1].shot_id, group_of_0);
    }

    #[test]
    fn merges_by_phash_with_close_datetime() {
        // Two entries in different stem groups, close datetime, low hamming distance → merge
        let mut images = vec![make_entry(0, 10), make_entry(1, 20)];
        let mut exif = HashMap::new();
        exif.insert(0, exif_with_datetime("2026:04:21 10:00:00", None));
        exif.insert(1, exif_with_datetime("2026:04:21 10:00:01", None)); // 1s diff
        let mut phashes = HashMap::new();
        phashes.insert(0, 0x0000_0000_0000_0FFFu64);
        phashes.insert(1, 0x0000_0000_0000_1FFFu64); // hamming = 1

        let groups = reindex_shot_groups(&mut images, &exif, &phashes);
        assert_eq!(groups.len(), 1, "should merge by pHash + close datetime");
        assert_eq!(images[0].shot_id, images[1].shot_id);
    }

    #[test]
    fn no_phash_merge_when_datetime_far() {
        // Low hamming but datetime 60s apart → must NOT merge
        let mut images = vec![make_entry(0, 10), make_entry(1, 20)];
        let mut exif = HashMap::new();
        exif.insert(0, exif_with_datetime("2026:04:21 10:00:00", None));
        exif.insert(1, exif_with_datetime("2026:04:21 10:01:00", None)); // 60s diff
        let mut phashes = HashMap::new();
        phashes.insert(0, 0x0000_0000_0000_0FFFu64);
        phashes.insert(1, 0x0000_0000_0000_1FFFu64); // hamming = 1

        let groups = reindex_shot_groups(&mut images, &exif, &phashes);
        assert_eq!(groups.len(), 2, "must not merge when datetime is far apart");
        assert_ne!(images[0].shot_id, images[1].shot_id);
    }

    #[test]
    fn no_phash_merge_when_distance_above_threshold() {
        // Close datetime but high hamming → must NOT merge
        let mut images = vec![make_entry(0, 10), make_entry(1, 20)];
        let mut exif = HashMap::new();
        exif.insert(0, exif_with_datetime("2026:04:21 10:00:00", None));
        exif.insert(1, exif_with_datetime("2026:04:21 10:00:01", None));
        let mut phashes = HashMap::new();
        phashes.insert(0, 0x0000_FFFF_0000_FFFFu64);
        phashes.insert(1, 0xFFFF_0000_FFFF_0000u64); // hamming = 32

        let groups = reindex_shot_groups(&mut images, &exif, &phashes);
        assert_eq!(groups.len(), 2, "must not merge when hamming distance is high");
    }

    #[test]
    fn aeb_group_members_not_split_by_phash() {
        // 3 members in same stem group; one has distant pHash → no split (Phase 4 only merges)
        let mut images = vec![make_entry(0, 1), make_entry(1, 1), make_entry(2, 1)];
        let mut exif = HashMap::new();
        exif.insert(0, exif_with_datetime("2026:04:21 10:00:00", None));
        exif.insert(1, exif_with_datetime("2026:04:21 10:00:01", None));
        exif.insert(2, exif_with_datetime("2026:04:21 10:00:01", None));
        let mut phashes = HashMap::new();
        phashes.insert(0, 0x0000_FFFF_0000_FFFFu64);
        phashes.insert(1, 0x0000_0000_0000_FFFFu64);
        phashes.insert(2, 0xFFFF_0000_FFFF_0000u64); // very different

        let groups = reindex_shot_groups(&mut images, &exif, &phashes);
        // All 3 share the same stem-based shot_id → stay in 1 group regardless
        assert_eq!(groups.len(), 1, "Phase 4 must not split existing groups");
    }

    #[test]
    fn month_boundary_datetime_diff() {
        // 2026-03-31 23:59:59 and 2026-04-01 00:00:01 → 2 second gap
        let mut images = vec![make_entry(0, 10), make_entry(1, 20)];
        let mut exif = HashMap::new();
        exif.insert(0, exif_with_datetime("2026:03:31 23:59:59", None));
        exif.insert(1, exif_with_datetime("2026:04:01 00:00:01", None));
        let mut phashes = HashMap::new();
        phashes.insert(0, 0x0000_0000_0000_0FFFu64);
        phashes.insert(1, 0x0000_0000_0000_1FFFu64); // hamming = 1

        let groups = reindex_shot_groups(&mut images, &exif, &phashes);
        assert_eq!(groups.len(), 1, "month boundary with 2s gap should merge");
    }
}
