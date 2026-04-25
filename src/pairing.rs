use std::collections::HashMap;

use crate::metadata::ExifData;
use crate::scanner::ImageEntry;

/// Parse EXIF datetime "YYYY:MM:DD HH:MM:SS" → an i64 suitable for gap comparisons.
/// Not epoch-accurate; only needs to be consistent and monotonic within a session.
fn parse_datetime_secs(dt: &str) -> Option<i64> {
    if dt.len() < 19 { return None; }
    let y:  i64 = dt[0..4].parse().ok()?;
    let mo: i64 = dt[5..7].parse().ok()?;
    let d:  i64 = dt[8..10].parse().ok()?;
    let h:  i64 = dt[11..13].parse().ok()?;
    let m:  i64 = dt[14..16].parse().ok()?;
    let s:  i64 = dt[17..19].parse().ok()?;
    Some(
        y  * 365 * 24 * 3600
        + mo * 30  * 24 * 3600
        + d  * 24  * 3600
        + h  * 3600
        + m  * 60
        + s,
    )
}

fn find_root(canonical: &HashMap<u64, u64>, mut id: u64) -> u64 {
    loop {
        match canonical.get(&id) {
            Some(&next) if next != id => id = next,
            _ => return id,
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
pub fn reindex_shot_groups(
    images: &mut [ImageEntry],
    exif: &HashMap<usize, ExifData>,
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
        let first = find_root(&canonical, group_ids[0]);
        for &gid in &group_ids[1..] {
            let root = find_root(&canonical, gid);
            if root != first {
                canonical.insert(root, first);
            }
        }
    }

    if canonical.is_empty() {
        sort_groups(&mut working, images);
        return working;
    }

    let mut merged: HashMap<u64, Vec<usize>> = HashMap::new();
    for (shot_id, members) in working {
        let canon = find_root(&canonical, shot_id);
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

    sort_groups(&mut merged, images);
    merged
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

        let groups = reindex_shot_groups(&mut images, &exif);
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

        let groups = reindex_shot_groups(&mut images, &exif);
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

        let groups = reindex_shot_groups(&mut images, &exif);
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

        let groups = reindex_shot_groups(&mut images, &exif);
        assert_eq!(groups.len(), 2, "must not merge without subsec");
    }

    #[test]
    fn missing_exif_stays_in_original_group() {
        let mut images = vec![make_entry(0, 1), make_entry(1, 1), make_entry(2, 1)];
        let mut exif = HashMap::new();
        exif.insert(0, exif_with_datetime("2026:04:21 10:00:00", None));
        exif.insert(1, exif_with_datetime("2026:04:21 10:01:00", None)); // 60s gap
        // id=2 has no EXIF

        let groups = reindex_shot_groups(&mut images, &exif);
        // id=0 and id=2 (no EXIF) should be in one group; id=1 in another
        assert_eq!(groups.len(), 2);
        let group_of_0 = images[0].shot_id;
        assert_eq!(images[2].shot_id, group_of_0, "EXIF-lacking entry stays with earliest cluster");
        assert_ne!(images[1].shot_id, group_of_0);
    }
}
