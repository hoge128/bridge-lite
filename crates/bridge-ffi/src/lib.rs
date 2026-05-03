// bridge-ffi: swift-bridge FFI layer for bridge-lite
//
// swift-bridge 0.1.59 の制約:
//   - opaque type は Box<T> でなく T として宣言・返却する
//   - Result<Box<T>, E> は使えない -> Result<T, E> を使う
//   - Vec<u8>, Vec<u64>, Vec<String>, &[u8] は OK
//   - #[swift_bridge(associated_to = T)] のコンストラクタには impl T のメソッドが必要なため
//     今回はすべてトップレベル関数として定義する

#![allow(unused_imports)]

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::SystemTime;

use bridge_core::error::{CoreError, CoreErrorId};
use bridge_core::scanner::{ImageEntry as CoreImageEntry, SUPPORTED_EXTENSIONS, RAW_EXTENSIONS};
use bridge_core::metadata::ExifData as CoreExifData;
use bridge_core::xmp::{XmpData as CoreXmpData, Label as CoreLabel, Flag as CoreFlag};
use bridge_core::developed::DEVELOPED_SOFTWARE_KEYWORDS;

// ── Tokio runtime singleton ────────────────────────────────────────────────

static TOKIO_RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();

#[allow(dead_code)]
fn runtime() -> &'static tokio::runtime::Runtime {
    TOKIO_RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("Failed to build Tokio runtime")
    })
}

// ── Internal helper types ──────────────────────────────────────────────────

/// Wrapper around a DB path.
/// bridge-core functions open and close connections internally (WAL mode),
/// so we only need to hold the path here.
pub struct BridgeDatabase {
    db_path: PathBuf,
}

impl BridgeDatabase {
    fn open_inner(db_path_str: &str) -> Result<BridgeDatabase, BridgeFfiError> {
        let path = PathBuf::from(db_path_str);
        if !bridge_core::db::ensure_schema(&path) {
            return Err(BridgeFfiError {
                code: CoreErrorId::Db as u32,
                message: format!("Failed to open/init DB at: {}", db_path_str),
            });
        }
        Ok(BridgeDatabase { db_path: path })
    }
}

/// Error type for FFI boundary.
pub struct BridgeFfiError {
    pub code: u32,
    pub message: String,
}

/// A list of image entries returned from a scan.
pub struct ImageEntryList {
    pub entries: Vec<CoreImageEntry>,
}

/// A single image entry exposed to Swift.
pub struct FfiImageEntry {
    pub id: u64,
    pub path: String,
    pub filename: String,
    pub is_raw: bool,
    pub file_size: u64,
    pub modified_unix: i64,
    pub created_unix: i64,
    pub has_jpg_partner: bool,
    pub shot_id: u64,
}

impl FfiImageEntry {
    fn from_core(e: &CoreImageEntry) -> Self {
        let to_unix = |t: Option<SystemTime>| -> i64 {
            t.and_then(|st| st.duration_since(SystemTime::UNIX_EPOCH).ok())
                .map(|d| d.as_secs() as i64)
                .unwrap_or(-1)
        };
        FfiImageEntry {
            id: e.id as u64,
            path: e.path.to_string_lossy().into_owned(),
            filename: e.filename.clone(),
            is_raw: e.is_raw,
            file_size: e.file_size,
            modified_unix: to_unix(e.modified),
            created_unix: to_unix(e.created),
            has_jpg_partner: e.has_jpg_partner,
            shot_id: e.shot_id,
        }
    }
}

/// EXIF result (found flag + fields).
#[derive(Clone)]
pub struct FfiExifResult {
    pub found: bool,
    pub make: String,
    pub model: String,
    pub datetime: String,
    pub subsec: String,
    pub exposure: String,
    pub fnumber: String,
    pub iso: i32,
    pub focal_length: String,
    pub focal_length_35mm: i32,
    pub lens_model: String,
    pub width: i32,
    pub height: i32,
    pub software: String,
    pub artist: String,
}

impl FfiExifResult {
    fn not_found() -> Self {
        FfiExifResult {
            found: false,
            make: String::new(),
            model: String::new(),
            datetime: String::new(),
            subsec: String::new(),
            exposure: String::new(),
            fnumber: String::new(),
            iso: -1,
            focal_length: String::new(),
            focal_length_35mm: -1,
            lens_model: String::new(),
            width: -1,
            height: -1,
            software: String::new(),
            artist: String::new(),
        }
    }

    fn from_core(e: &CoreExifData) -> Self {
        FfiExifResult {
            found: true,
            make: e.make.clone().unwrap_or_default(),
            model: e.model.clone().unwrap_or_default(),
            datetime: e.datetime.clone().unwrap_or_default(),
            subsec: e.subsec.clone().unwrap_or_default(),
            exposure: e.exposure_time.clone().unwrap_or_default(),
            fnumber: e.fnumber.clone().unwrap_or_default(),
            iso: e.iso.map(|v| v as i32).unwrap_or(-1),
            focal_length: e.focal_length.clone().unwrap_or_default(),
            focal_length_35mm: e.focal_length_35mm.map(|v| v as i32).unwrap_or(-1),
            lens_model: e.lens_model.clone().unwrap_or_default(),
            width: e.width.map(|v| v as i32).unwrap_or(-1),
            height: e.height.map(|v| v as i32).unwrap_or(-1),
            software: e.software.clone().unwrap_or_default(),
            artist: e.artist.clone().unwrap_or_default(),
        }
    }
}

/// EXIF batch result — index-aligned with the ImageEntryList used to create it.
pub struct FfiExifBatch {
    results: Vec<FfiExifResult>,
}

/// XMP result (found flag + fields).
pub struct FfiXmpResult {
    pub found: bool,
    pub rating: i32,
    pub label: u8,
    pub flag: u8,
    pub developed: bool,
}

impl FfiXmpResult {
    fn not_found() -> Self {
        FfiXmpResult {
            found: false,
            rating: -1,
            label: 0,
            flag: 0,
            developed: false,
        }
    }

    fn from_core(d: &CoreXmpData) -> Self {
        let label_u8 = d.label.map(|l| match l {
            CoreLabel::Red    => 1u8,
            CoreLabel::Yellow => 2,
            CoreLabel::Green  => 3,
            CoreLabel::Blue   => 4,
            CoreLabel::Purple => 5,
        }).unwrap_or(0);

        let flag_u8 = d.flag.map(|f| match f {
            CoreFlag::Pick   => 1u8,
            CoreFlag::Reject => 2,
        }).unwrap_or(0);

        FfiXmpResult {
            found: true,
            rating: d.rating.map(|r| r as i32).unwrap_or(-1),
            label: label_u8,
            flag: flag_u8,
            developed: d.developed,
        }
    }
}

/// Optional bytes result (found flag + data).
pub struct FfiOptionalBytes {
    pub found: bool,
    pub data: Vec<u8>,
}

impl FfiOptionalBytes {
    fn none() -> Self {
        FfiOptionalBytes { found: false, data: Vec::new() }
    }
    fn some(data: Vec<u8>) -> Self {
        FfiOptionalBytes { found: true, data }
    }
}

/// Shot groups map: shot_id → [entry_id, ...]
pub struct ShotGroupsMap {
    pub shot_ids: Vec<u64>,
    pub groups: HashMap<u64, Vec<u64>>,
}

// ── XMP write helper ───────────────────────────────────────────────────────

fn label_from_u8(v: u8) -> Option<CoreLabel> {
    match v {
        1 => Some(CoreLabel::Red),
        2 => Some(CoreLabel::Yellow),
        3 => Some(CoreLabel::Green),
        4 => Some(CoreLabel::Blue),
        5 => Some(CoreLabel::Purple),
        _ => None,
    }
}

fn flag_from_u8(v: u8) -> Option<CoreFlag> {
    match v {
        1 => Some(CoreFlag::Pick),
        2 => Some(CoreFlag::Reject),
        _ => None,
    }
}

// ── swift-bridge module ───────────────────────────────────────────────────
// NOTE: swift-bridge 0.1.59 の制約により:
//   - 戻り値の opaque type は Box<T> でなく T として記述する
//   - Result<T, E> の T, E も Box なし

#[swift_bridge::bridge]
mod ffi {
    extern "Rust" {
        type BridgeDatabase;
        type BridgeFfiError;
        type ImageEntryList;
        type FfiImageEntry;
        type FfiExifResult;
        type FfiExifBatch;
        type FfiXmpResult;
        type FfiOptionalBytes;
        type ShotGroupsMap;

        // Database API
        fn bridge_open_database(db_path: &str) -> Result<BridgeDatabase, BridgeFfiError>;
        fn bridge_ffi_error_message(e: &BridgeFfiError) -> String;

        // Scan API
        fn bridge_scan_directory(db: &BridgeDatabase, path: &str) -> ImageEntryList;
        fn image_entry_list_count(list: &ImageEntryList) -> usize;
        fn image_entry_list_get(list: &ImageEntryList, idx: usize) -> FfiImageEntry;

        // ImageEntry field accessors
        fn ffi_image_entry_id(entry: &FfiImageEntry) -> u64;
        fn ffi_image_entry_path(entry: &FfiImageEntry) -> String;
        fn ffi_image_entry_filename(entry: &FfiImageEntry) -> String;
        fn ffi_image_entry_is_raw(entry: &FfiImageEntry) -> bool;
        fn ffi_image_entry_file_size(entry: &FfiImageEntry) -> u64;
        fn ffi_image_entry_modified_unix(entry: &FfiImageEntry) -> i64;
        fn ffi_image_entry_created_unix(entry: &FfiImageEntry) -> i64;
        fn ffi_image_entry_has_jpg_partner(entry: &FfiImageEntry) -> bool;
        fn ffi_image_entry_shot_id(entry: &FfiImageEntry) -> u64;

        // EXIF API
        fn bridge_fetch_exif(db: &BridgeDatabase, path: &str) -> FfiExifResult;
        // Batch EXIF fetch — 1 SQLite connection, index-aligned with entries list
        fn bridge_fetch_exif_for_entries(db: &BridgeDatabase, entries: &ImageEntryList) -> FfiExifBatch;
        fn ffi_exif_batch_count(r: &FfiExifBatch) -> usize;
        fn ffi_exif_batch_exif_at(r: &FfiExifBatch, idx: usize) -> FfiExifResult;
        fn ffi_exif_found(r: &FfiExifResult) -> bool;
        fn ffi_exif_make(r: &FfiExifResult) -> String;
        fn ffi_exif_model(r: &FfiExifResult) -> String;
        fn ffi_exif_datetime(r: &FfiExifResult) -> String;
        fn ffi_exif_subsec(r: &FfiExifResult) -> String;
        fn ffi_exif_exposure(r: &FfiExifResult) -> String;
        fn ffi_exif_fnumber(r: &FfiExifResult) -> String;
        fn ffi_exif_iso(r: &FfiExifResult) -> i32;
        fn ffi_exif_focal_length(r: &FfiExifResult) -> String;
        fn ffi_exif_focal_length_35mm(r: &FfiExifResult) -> i32;
        fn ffi_exif_lens_model(r: &FfiExifResult) -> String;
        fn ffi_exif_width(r: &FfiExifResult) -> i32;
        fn ffi_exif_height(r: &FfiExifResult) -> i32;
        fn ffi_exif_software(r: &FfiExifResult) -> String;
        fn ffi_exif_artist(r: &FfiExifResult) -> String;

        // XMP API
        fn bridge_read_xmp(path: &str, jpg_use_sidecar: bool) -> FfiXmpResult;
        fn ffi_xmp_found(r: &FfiXmpResult) -> bool;
        fn ffi_xmp_rating(r: &FfiXmpResult) -> i32;
        fn ffi_xmp_label(r: &FfiXmpResult) -> u8;
        fn ffi_xmp_flag(r: &FfiXmpResult) -> u8;
        fn ffi_xmp_developed(r: &FfiXmpResult) -> bool;
        fn bridge_write_xmp(db: &BridgeDatabase, path: &str, rating: i32, label: u8, flag: u8, jpg_use_sidecar: bool) -> bool;
        fn bridge_jpg_has_rated_embedded_xmp(path: &str) -> bool;

        // pHash API
        fn bridge_compute_phash_from_luma(pixels: &[u8]) -> u64;
        fn bridge_fetch_phash(db: &BridgeDatabase, path: &str) -> i64;
        fn bridge_store_phash(db: &BridgeDatabase, path: &str, phash: u64);

        // Thumbnail cache API
        fn bridge_fetch_cached_thumbnail(db: &BridgeDatabase, path: &str) -> FfiOptionalBytes;
        fn ffi_optional_bytes_found(r: &FfiOptionalBytes) -> bool;
        fn ffi_optional_bytes_data(r: &FfiOptionalBytes) -> Vec<u8>;
        fn bridge_store_cached_thumbnail(db: &BridgeDatabase, path: &str, jpeg: &[u8]);

        // Rendered thumbnail cache API
        fn bridge_fetch_cached_rendered(db: &BridgeDatabase, path: &str, engine: &str, width: u32) -> FfiOptionalBytes;
        fn bridge_store_cached_rendered(db: &BridgeDatabase, path: &str, engine: &str, width: u32, jpeg: &[u8]);
        fn bridge_clear_rendered_cache(db: &BridgeDatabase);

        // RAW embedded JPEG API (quality: 0=Thumbnail, 1=Preview, 2=Full)
        fn bridge_extract_raw_jpeg(path: &str, quality: u8) -> FfiOptionalBytes;

        // Shot grouping API
        fn bridge_reindex_shot_groups(db: &BridgeDatabase, entries: &ImageEntryList, split_threshold_secs: i64, phash_hamming_threshold: u32) -> ShotGroupsMap;
        fn shot_groups_map_count(m: &ShotGroupsMap) -> usize;
        fn shot_groups_map_shot_id_at(m: &ShotGroupsMap, idx: usize) -> u64;
        fn shot_groups_map_members_for(m: &ShotGroupsMap, shot_id: u64) -> Vec<u64>;

        // Constants / utilities
        fn bridge_is_raw(path: &str) -> bool;
        fn bridge_developed_keywords() -> Vec<String>;
        fn bridge_has_images_beyond_scan_depth(path: &str) -> bool;
    }
}

// ── Database API impl ──────────────────────────────────────────────────────

fn bridge_open_database(db_path: &str) -> Result<BridgeDatabase, BridgeFfiError> {
    BridgeDatabase::open_inner(db_path)
}

fn bridge_ffi_error_message(e: &BridgeFfiError) -> String {
    e.message.clone()
}

// ── Scan API impl ──────────────────────────────────────────────────────────

fn bridge_scan_directory(db: &BridgeDatabase, path: &str) -> ImageEntryList {
    let entries = bridge_core::scanner::scan_directory(PathBuf::from(path));
    // Persist EXIF to DB for newly scanned entries in parallel (cache hits via
    // one IN-clause query, misses parsed with rayon, written in one transaction).
    let db_path = db.db_path.clone();
    let paths: Vec<PathBuf> = entries.iter().map(|e| e.path.clone()).collect();
    bridge_core::db::index_new_entries(&paths, &db_path);
    ImageEntryList { entries }
}

fn image_entry_list_count(list: &ImageEntryList) -> usize {
    list.entries.len()
}

fn image_entry_list_get(list: &ImageEntryList, idx: usize) -> FfiImageEntry {
    FfiImageEntry::from_core(&list.entries[idx])
}

fn ffi_image_entry_id(entry: &FfiImageEntry) -> u64 { entry.id }
fn ffi_image_entry_path(entry: &FfiImageEntry) -> String { entry.path.clone() }
fn ffi_image_entry_filename(entry: &FfiImageEntry) -> String { entry.filename.clone() }
fn ffi_image_entry_is_raw(entry: &FfiImageEntry) -> bool { entry.is_raw }
fn ffi_image_entry_file_size(entry: &FfiImageEntry) -> u64 { entry.file_size }
fn ffi_image_entry_modified_unix(entry: &FfiImageEntry) -> i64 { entry.modified_unix }
fn ffi_image_entry_created_unix(entry: &FfiImageEntry) -> i64 { entry.created_unix }
fn ffi_image_entry_has_jpg_partner(entry: &FfiImageEntry) -> bool { entry.has_jpg_partner }
fn ffi_image_entry_shot_id(entry: &FfiImageEntry) -> u64 { entry.shot_id }

// ── EXIF API impl ──────────────────────────────────────────────────────────

fn bridge_fetch_exif(db: &BridgeDatabase, path: &str) -> FfiExifResult {
    let p = Path::new(path);
    bridge_core::db::fetch_or_index(p, &db.db_path)
        .as_ref()
        .map(FfiExifResult::from_core)
        .unwrap_or_else(FfiExifResult::not_found)
}

fn ffi_exif_found(r: &FfiExifResult) -> bool { r.found }
fn ffi_exif_make(r: &FfiExifResult) -> String { r.make.clone() }
fn ffi_exif_model(r: &FfiExifResult) -> String { r.model.clone() }
fn ffi_exif_datetime(r: &FfiExifResult) -> String { r.datetime.clone() }
fn ffi_exif_subsec(r: &FfiExifResult) -> String { r.subsec.clone() }
fn ffi_exif_exposure(r: &FfiExifResult) -> String { r.exposure.clone() }
fn ffi_exif_fnumber(r: &FfiExifResult) -> String { r.fnumber.clone() }
fn ffi_exif_iso(r: &FfiExifResult) -> i32 { r.iso }
fn ffi_exif_focal_length(r: &FfiExifResult) -> String { r.focal_length.clone() }
fn ffi_exif_focal_length_35mm(r: &FfiExifResult) -> i32 { r.focal_length_35mm }
fn ffi_exif_lens_model(r: &FfiExifResult) -> String { r.lens_model.clone() }
fn ffi_exif_width(r: &FfiExifResult) -> i32 { r.width }
fn ffi_exif_height(r: &FfiExifResult) -> i32 { r.height }
fn ffi_exif_software(r: &FfiExifResult) -> String { r.software.clone() }
fn ffi_exif_artist(r: &FfiExifResult) -> String { r.artist.clone() }

fn bridge_fetch_exif_for_entries(db: &BridgeDatabase, entries: &ImageEntryList) -> FfiExifBatch {
    let paths: Vec<PathBuf> = entries.entries.iter().map(|e| e.path.clone()).collect();
    let mut map = bridge_core::db::fetch_exif_batch(&paths, &db.db_path);
    let results = paths
        .into_iter()
        .map(|p| {
            map.remove(&p)
                .map(|e| FfiExifResult::from_core(&e))
                .unwrap_or_else(FfiExifResult::not_found)
        })
        .collect();
    FfiExifBatch { results }
}

fn ffi_exif_batch_count(r: &FfiExifBatch) -> usize { r.results.len() }
fn ffi_exif_batch_exif_at(r: &FfiExifBatch, idx: usize) -> FfiExifResult { r.results[idx].clone() }

// ── XMP API impl ───────────────────────────────────────────────────────────

fn bridge_read_xmp(path: &str, jpg_use_sidecar: bool) -> FfiXmpResult {
    let p = Path::new(path);
    bridge_core::xmp::read_metadata(p, jpg_use_sidecar)
        .as_ref()
        .map(FfiXmpResult::from_core)
        .unwrap_or_else(FfiXmpResult::not_found)
}

fn bridge_jpg_has_rated_embedded_xmp(path: &str) -> bool {
    bridge_core::xmp::jpg_has_rated_embedded_xmp(Path::new(path))
}

fn ffi_xmp_found(r: &FfiXmpResult) -> bool { r.found }
fn ffi_xmp_rating(r: &FfiXmpResult) -> i32 { r.rating }
fn ffi_xmp_label(r: &FfiXmpResult) -> u8 { r.label }
fn ffi_xmp_flag(r: &FfiXmpResult) -> u8 { r.flag }
fn ffi_xmp_developed(r: &FfiXmpResult) -> bool { r.developed }

fn bridge_write_xmp(db: &BridgeDatabase, path: &str, rating: i32, label: u8, flag: u8, jpg_use_sidecar: bool) -> bool {
    let p = Path::new(path);
    let data = CoreXmpData {
        rating: if rating >= 0 { Some(rating.clamp(0, 5) as u8) } else { None },
        label: label_from_u8(label),
        flag: flag_from_u8(flag),
        developed: false,
    };
    let ok = bridge_core::xmp::write_metadata(p, &data, jpg_use_sidecar).is_ok();
    if ok {
        bridge_core::db::update_xmp(p, &db.db_path, &data);
    }
    ok
}

// ── pHash API impl ─────────────────────────────────────────────────────────

fn bridge_compute_phash_from_luma(pixels: &[u8]) -> u64 {
    if pixels.len() != 1024 {
        return 0;
    }
    let arr: &[u8; 1024] = pixels.try_into().expect("length checked above");
    bridge_core::phash::compute_phash_from_luma_32x32(arr)
}

fn bridge_fetch_phash(db: &BridgeDatabase, path: &str) -> i64 {
    let p = Path::new(path);
    bridge_core::db::fetch_phash(p, &db.db_path)
        .map(|v| v as i64)
        .unwrap_or(-1)
}

fn bridge_store_phash(db: &BridgeDatabase, path: &str, phash: u64) {
    let p = Path::new(path);
    bridge_core::db::store_phash(p, &db.db_path, phash);
}

// ── Thumbnail cache API impl ───────────────────────────────────────────────

fn bridge_fetch_cached_thumbnail(db: &BridgeDatabase, path: &str) -> FfiOptionalBytes {
    let p = Path::new(path);
    bridge_core::db::fetch_thumb(p, &db.db_path)
        .map(FfiOptionalBytes::some)
        .unwrap_or_else(FfiOptionalBytes::none)
}

fn ffi_optional_bytes_found(r: &FfiOptionalBytes) -> bool { r.found }
fn ffi_optional_bytes_data(r: &FfiOptionalBytes) -> Vec<u8> { r.data.clone() }

fn bridge_store_cached_thumbnail(db: &BridgeDatabase, path: &str, jpeg: &[u8]) {
    let p = Path::new(path);
    bridge_core::db::store_thumb(p, &db.db_path, jpeg);
}

// ── Rendered thumbnail cache API impl ─────────────────────────────────────

fn bridge_fetch_cached_rendered(db: &BridgeDatabase, path: &str, engine: &str, width: u32) -> FfiOptionalBytes {
    let p = Path::new(path);
    bridge_core::db::fetch_rendered(p, &db.db_path, engine, width)
        .map(FfiOptionalBytes::some)
        .unwrap_or_else(FfiOptionalBytes::none)
}

fn bridge_store_cached_rendered(db: &BridgeDatabase, path: &str, engine: &str, width: u32, jpeg: &[u8]) {
    let p = Path::new(path);
    bridge_core::db::store_rendered(p, &db.db_path, engine, width, jpeg);
}

fn bridge_clear_rendered_cache(db: &BridgeDatabase) {
    bridge_core::db::clear_rendered(&db.db_path);
}

// ── RAW embedded JPEG API impl ─────────────────────────────────────────────

fn bridge_extract_raw_jpeg(path: &str, quality: u8) -> FfiOptionalBytes {
    use bridge_core::raw_thumb::Quality;
    let q = match quality {
        0 => Quality::Thumbnail,
        1 => Quality::Preview,
        _ => Quality::Full,
    };
    bridge_core::raw_thumb::extract(Path::new(path), q)
        .map(FfiOptionalBytes::some)
        .unwrap_or_else(FfiOptionalBytes::none)
}

// ── Shot grouping API impl ─────────────────────────────────────────────────

fn bridge_reindex_shot_groups(
    db: &BridgeDatabase,
    entries: &ImageEntryList,
    split_threshold_secs: i64,
    phash_hamming_threshold: u32,
) -> ShotGroupsMap {
    let mut images: Vec<CoreImageEntry> = entries.entries.clone();

    let paths: Vec<PathBuf> = images.iter().map(|e| e.path.clone()).collect();
    let exif_by_path = bridge_core::db::fetch_exif_batch(&paths, &db.db_path);
    let exif_by_id: HashMap<usize, CoreExifData> = images
        .iter()
        .filter_map(|e| exif_by_path.get(&e.path).map(|ex| (e.id, ex.clone())))
        .collect();

    let phash_by_path = bridge_core::db::fetch_phash_batch(&paths, &db.db_path);
    let phash_by_id: HashMap<usize, u64> = images
        .iter()
        .filter_map(|e| phash_by_path.get(&e.path).map(|&h| (e.id, h)))
        .collect();

    let groups = bridge_core::pairing::reindex_shot_groups(
        &mut images,
        &exif_by_id,
        &phash_by_id,
        split_threshold_secs,
        phash_hamming_threshold,
    );

    let mut shot_ids: Vec<u64> = groups.keys().cloned().collect();
    shot_ids.sort_unstable();

    let converted: HashMap<u64, Vec<u64>> = groups
        .into_iter()
        .map(|(sid, members)| (sid, members.into_iter().map(|id| id as u64).collect()))
        .collect();

    ShotGroupsMap { shot_ids, groups: converted }
}

fn shot_groups_map_count(m: &ShotGroupsMap) -> usize {
    m.shot_ids.len()
}

fn shot_groups_map_shot_id_at(m: &ShotGroupsMap, idx: usize) -> u64 {
    m.shot_ids[idx]
}

fn shot_groups_map_members_for(m: &ShotGroupsMap, shot_id: u64) -> Vec<u64> {
    m.groups.get(&shot_id).cloned().unwrap_or_default()
}

// ── Constants / utilities impl ─────────────────────────────────────────────

fn bridge_is_raw(path: &str) -> bool {
    bridge_core::scanner::is_raw(Path::new(path))
}

fn bridge_developed_keywords() -> Vec<String> {
    DEVELOPED_SOFTWARE_KEYWORDS
        .iter()
        .map(|s| s.to_string())
        .collect()
}

fn bridge_has_images_beyond_scan_depth(path: &str) -> bool {
    bridge_core::scanner::has_images_beyond_depth(
        Path::new(path),
        bridge_core::scanner::SCAN_MAX_DEPTH,
    )
}
