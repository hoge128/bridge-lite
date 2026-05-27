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
use std::sync::{Arc, Mutex, OnceLock};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::SystemTime;

// EXIF 索引の進捗をポーリング可能にするグローバルカウンタ
static EXIF_INDEX_PROGRESS: AtomicUsize = AtomicUsize::new(0);
static EXIF_INDEX_TOTAL: AtomicUsize = AtomicUsize::new(0);

use bridge_core::developed::DEVELOPED_SOFTWARE_KEYWORDS;
use bridge_core::error::{CoreError, CoreErrorId};
use bridge_core::metadata::ExifData as CoreExifData;
use bridge_core::scanner::{ImageEntry as CoreImageEntry, RAW_EXTENSIONS, SUPPORTED_EXTENSIONS};
use bridge_core::xmp::{Flag as CoreFlag, Label as CoreLabel, XmpData as CoreXmpData};

// ── Tokio runtime singleton ────────────────────────────────────────────────

static TOKIO_RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();

#[allow(dead_code)]
fn runtime() -> &'static tokio::runtime::Runtime {
    TOKIO_RUNTIME.get_or_init(|| {
        // 通常モード: 論理コア数の 1/2 に制限して他アプリへの影響を抑える。
        // Burst Mode 対応時は bridge_set_burst_mode() 経由で切替可能にする（要再起動）。
        let workers = std::thread::available_parallelism()
            .map(|n| (n.get() / 2).max(2))
            .unwrap_or(2);
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(workers)
            .enable_all()
            .build()
            .expect("Failed to build Tokio runtime")
    })
}

// ── Internal helper types ──────────────────────────────────────────────────

pub struct BridgeDatabase {
    #[allow(dead_code)]
    db_path: PathBuf,
    conn: Arc<Mutex<rusqlite::Connection>>,
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
        let conn = bridge_core::db::open_connection(&path).map_err(|e| BridgeFfiError {
            code: CoreErrorId::Db as u32,
            message: e.to_string(),
        })?;
        Ok(BridgeDatabase {
            db_path: path,
            conn: Arc::new(Mutex::new(conn)),
        })
    }
}

/// Error type for FFI boundary.
pub struct BridgeFfiError {
    pub code: u32,
    pub message: String,
}

/// A list of image entries returned from a scan, plus file counts for progress reporting.
pub struct ImageEntryList {
    pub entries: Vec<CoreImageEntry>,
    /// Total files encountered during the directory walk (all extensions).
    pub total_files: usize,
    /// Files with a supported image or RAW extension.
    pub image_files: usize,
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
        FfiImageEntry {
            id: e.id as u64,
            path: e.path.to_string_lossy().into_owned(),
            filename: e.filename.clone(),
            is_raw: e.is_raw,
            file_size: e.file_size,
            modified_unix: system_time_to_unix(e.modified),
            created_unix: system_time_to_unix(e.created),
            has_jpg_partner: e.has_jpg_partner,
            shot_id: e.shot_id,
        }
    }
}

fn system_time_to_unix(t: Option<SystemTime>) -> i64 {
    t.and_then(|st| st.duration_since(SystemTime::UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .unwrap_or(-1)
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
    pub exposure_bias: String,
    pub flash: String,
    pub white_balance: String,
    pub image_description: String,
    pub user_comment: String,
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
            exposure_bias: String::new(),
            flash: String::new(),
            white_balance: String::new(),
            image_description: String::new(),
            user_comment: String::new(),
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
            exposure_bias: e.exposure_bias.clone().unwrap_or_default(),
            flash: e.flash.clone().unwrap_or_default(),
            white_balance: e.white_balance.clone().unwrap_or_default(),
            image_description: e.image_description.clone().unwrap_or_default(),
            user_comment: e.user_comment.clone().unwrap_or_default(),
        }
    }
}

/// EXIF batch result — index-aligned with the ImageEntryList used to create it.
pub struct FfiExifBatch {
    results: Vec<FfiExifResult>,
}

/// Thumbnail batch result — index-aligned with the ImageEntryList used to create it.
pub struct FfiThumbBatch {
    results: Vec<FfiOptionalBytes>,
}

/// XMP result (found flag + fields).
pub struct FfiXmpResult {
    pub found: bool,
    pub rating: i32,
    pub label: u8,
    pub flag: u8,
    pub developed: bool,
    pub caption: String,
}

impl FfiXmpResult {
    fn not_found() -> Self {
        FfiXmpResult {
            found: false,
            rating: -1,
            label: 0,
            flag: 0,
            developed: false,
            caption: String::new(),
        }
    }

    fn from_core(d: &CoreXmpData) -> Self {
        let label_u8 = d
            .label
            .map(|l| match l {
                CoreLabel::Red => 1u8,
                CoreLabel::Yellow => 2,
                CoreLabel::Green => 3,
                CoreLabel::Blue => 4,
                CoreLabel::Purple => 5,
            })
            .unwrap_or(0);

        let flag_u8 = d
            .flag
            .map(|f| match f {
                CoreFlag::Pick => 1u8,
                CoreFlag::Reject => 2,
            })
            .unwrap_or(0);

        FfiXmpResult {
            found: true,
            rating: d.rating.map(|r| r as i32).unwrap_or(-1),
            label: label_u8,
            flag: flag_u8,
            developed: d.developed,
            caption: d.caption.clone().unwrap_or_default(),
        }
    }
}

/// Optional bytes result (found flag + data).
#[derive(Clone)]
pub struct FfiOptionalBytes {
    pub found: bool,
    pub data: Vec<u8>,
    pub aspect_ok: bool,
    pub raw_orientation: u8,
}

impl FfiOptionalBytes {
    fn none() -> Self {
        FfiOptionalBytes {
            found: false,
            data: Vec::new(),
            aspect_ok: false,
            raw_orientation: 0,
        }
    }
    fn some(val: (Vec<u8>, bool, u8)) -> Self {
        FfiOptionalBytes {
            found: true,
            data: val.0,
            aspect_ok: val.1,
            raw_orientation: val.2,
        }
    }
    fn some_data(data: Vec<u8>) -> Self {
        FfiOptionalBytes {
            found: true,
            data,
            aspect_ok: false,
            raw_orientation: 0,
        }
    }
}

/// Shot groups map: shot_id → [entry_id, ...]
pub struct ShotGroupsMap {
    pub shot_ids: Vec<u64>,
    pub groups: HashMap<u64, Vec<u64>>,
}

/// Accumulates thumbnail items for a single batched INSERT per flush.
/// Interior Mutex allows push/flush via shared `&self` reference (required by swift-bridge).
pub struct ThumbBatchBuilder {
    items: Mutex<Vec<(PathBuf, Vec<u8>, bool, u8)>>,
    conn: Arc<Mutex<rusqlite::Connection>>,
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
        type FfiThumbBatch;
        type ShotGroupsMap;

        // Database API
        fn bridge_open_database(db_path: &str) -> Result<BridgeDatabase, BridgeFfiError>;
        fn bridge_ffi_error_message(e: &BridgeFfiError) -> String;

        // Scan API
        fn bridge_scan_directory(db: &BridgeDatabase, path: &str) -> ImageEntryList;
        fn bridge_index_new_entries(db: &BridgeDatabase, entries: &ImageEntryList);
        fn image_entry_list_count(list: &ImageEntryList) -> usize;
        fn image_entry_list_total_files(list: &ImageEntryList) -> usize;
        fn image_entry_list_image_files(list: &ImageEntryList) -> usize;
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
        fn bridge_fetch_exif_for_entries(
            db: &BridgeDatabase,
            entries: &ImageEntryList,
        ) -> FfiExifBatch;
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
        fn ffi_exif_exposure_bias(r: &FfiExifResult) -> String;
        fn ffi_exif_flash(r: &FfiExifResult) -> String;
        fn ffi_exif_white_balance(r: &FfiExifResult) -> String;
        fn ffi_exif_image_description(r: &FfiExifResult) -> String;
        fn ffi_exif_user_comment(r: &FfiExifResult) -> String;

        // XMP API
        fn bridge_read_xmp(path: &str, jpg_use_sidecar: bool) -> FfiXmpResult;
        fn ffi_xmp_found(r: &FfiXmpResult) -> bool;
        fn ffi_xmp_rating(r: &FfiXmpResult) -> i32;
        fn ffi_xmp_label(r: &FfiXmpResult) -> u8;
        fn ffi_xmp_flag(r: &FfiXmpResult) -> u8;
        fn ffi_xmp_developed(r: &FfiXmpResult) -> bool;
        fn ffi_xmp_caption(r: &FfiXmpResult) -> String;
        fn bridge_write_xmp(
            db: &BridgeDatabase,
            path: &str,
            rating: i32,
            label: u8,
            flag: u8,
            caption: &str,
            caption_present: bool,
            jpg_use_sidecar: bool,
        ) -> bool;
        fn bridge_jpg_has_rated_embedded_xmp(path: &str) -> bool;

        // pHash API
        fn bridge_compute_phash_from_luma(pixels: &[u8]) -> u64;
        fn bridge_fetch_phash(db: &BridgeDatabase, path: &str) -> i64;
        fn bridge_store_phash(db: &BridgeDatabase, path: &str, phash: u64);

        // Thumbnail cache API
        fn bridge_fetch_cached_thumbnail(db: &BridgeDatabase, path: &str) -> FfiOptionalBytes;
        fn ffi_optional_bytes_found(r: &FfiOptionalBytes) -> bool;
        fn ffi_optional_bytes_data(r: &FfiOptionalBytes) -> Vec<u8>;
        fn ffi_optional_bytes_aspect_ok(r: &FfiOptionalBytes) -> bool;
        fn ffi_optional_bytes_raw_orientation(r: &FfiOptionalBytes) -> u8;
        fn bridge_store_cached_thumbnail(
            db: &BridgeDatabase,
            path: &str,
            jpeg: &[u8],
            aspect_ok: bool,
            raw_orientation: u8,
        );
        // Batch thumbnail fetch — 1 SQLite connection, index-aligned with entries list
        fn bridge_fetch_cached_thumbnails_for_entries(
            db: &BridgeDatabase,
            entries: &ImageEntryList,
        ) -> FfiThumbBatch;
        fn ffi_thumb_batch_count(r: &FfiThumbBatch) -> usize;
        fn ffi_thumb_batch_jpeg_at(r: &FfiThumbBatch, idx: usize) -> FfiOptionalBytes;

        // Batch thumbnail write — accumulate items then flush in a single transaction
        type ThumbBatchBuilder;
        fn bridge_thumb_batch_new(db: &BridgeDatabase) -> ThumbBatchBuilder;
        fn bridge_thumb_batch_push(
            builder: &ThumbBatchBuilder,
            path: &str,
            jpeg: &[u8],
            aspect_ok: bool,
            raw_orientation: u8,
        );
        fn bridge_thumb_batch_flush(builder: &ThumbBatchBuilder);

        // Rendered thumbnail cache API
        fn bridge_fetch_cached_rendered(
            db: &BridgeDatabase,
            path: &str,
            engine: &str,
            width: u32,
        ) -> FfiOptionalBytes;
        fn bridge_store_cached_rendered(
            db: &BridgeDatabase,
            path: &str,
            engine: &str,
            width: u32,
            jpeg: &[u8],
        );
        fn bridge_clear_rendered_cache(db: &BridgeDatabase);
        fn bridge_prune_cache(db: &BridgeDatabase, max_age_days: u32);

        // RAW embedded JPEG API (quality: 0=Thumbnail, 1=Preview, 2=Full)
        fn bridge_extract_raw_jpeg(path: &str, quality: u8) -> FfiOptionalBytes;

        // Shot grouping API
        fn bridge_reindex_shot_groups(
            db: &BridgeDatabase,
            entries: &ImageEntryList,
            split_threshold_secs: i64,
            phash_hamming_threshold: u32,
        ) -> ShotGroupsMap;
        fn shot_groups_map_count(m: &ShotGroupsMap) -> usize;
        fn shot_groups_map_shot_id_at(m: &ShotGroupsMap, idx: usize) -> u64;
        fn shot_groups_map_members_for(m: &ShotGroupsMap, shot_id: u64) -> Vec<u64>;

        // Constants / utilities
        fn bridge_is_raw(path: &str) -> bool;
        fn bridge_developed_keywords() -> Vec<String>;
        fn bridge_has_images_beyond_scan_depth(path: &str) -> bool;

        // EXIF indexing progress (poll from Swift during scan)
        fn bridge_exif_index_progress() -> usize;
        fn bridge_exif_index_total() -> usize;
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

fn bridge_scan_directory(_db: &BridgeDatabase, path: &str) -> ImageEntryList {
    let result = bridge_core::scanner::scan_directory(PathBuf::from(path));
    ImageEntryList {
        entries: result.entries,
        total_files: result.total_files,
        image_files: result.image_files,
    }
}

fn bridge_index_new_entries(db: &BridgeDatabase, entries: &ImageEntryList) {
    // 前回スキャンのカウンタが残っていると、ポーラーが即 break してしまうため先頭でリセット。
    // Phase 1（キャッシュチェック）中は total=0 のままになり、UI はサムネイルフェーズを維持する。
    EXIF_INDEX_TOTAL.store(0, Ordering::Relaxed);
    EXIF_INDEX_PROGRESS.store(0, Ordering::Relaxed);

    // スキャン済みエントリの mtime をそのまま使う（stat 再呼び出しを排除）。
    // SD カード経由の stat は 1 回 100-300ms かかることがあり、825 ファイル分を
    // ミューテックス保持中に実行すると db.conn を数分間占有してサムネイル書き込みを
    // 完全にブロックしてしまう。エントリ取得時に既に mtime を取得済みなので再読不要。
    let path_mtimes: Vec<(PathBuf, i64)> = entries.entries.iter()
        .map(|e| (e.path.clone(), system_time_to_unix(e.modified)))
        .collect();

    // Phase 1: キャッシュヒット確認（ロック短時間・SQL クエリのみ）
    let misses: Vec<(PathBuf, i64)> = {
        let conn = db.conn.lock().unwrap_or_else(|e| e.into_inner());
        let cached = bridge_core::db::fetch_exif_batch(&path_mtimes, &conn);
        path_mtimes.iter()
            .filter(|(p, _)| !cached.contains_key(p))
            .cloned()
            .collect()
    }; // ロック解放

    if misses.is_empty() {
        return;
    }

    // Phase 2: ファイルから EXIF 読み込み（ロック不要、純粋なファイル I/O）
    // グローバルカウンタを初期化して Swift 側からポーリング可能にする
    EXIF_INDEX_TOTAL.store(misses.len(), Ordering::Relaxed);
    EXIF_INDEX_PROGRESS.store(0, Ordering::Relaxed);
    let new_data = std::sync::Mutex::new(Vec::<(PathBuf, i64, CoreExifData)>::new());
    bridge_core::runtime::background_pool().scope(|scope| {
        for (path, mtime) in &misses {
            scope.spawn(|_| {
                let mtime = *mtime;
                if let Some(exif) = bridge_core::metadata::read_exif_sync(path) {
                    let mut data = new_data.lock().unwrap_or_else(|e| e.into_inner());
                    data.push((path.clone(), mtime, exif));
                }
                EXIF_INDEX_PROGRESS.fetch_add(1, Ordering::Relaxed);
            });
        }
    });
    let new_data = new_data.into_inner().unwrap_or_else(|e| e.into_inner());

    // Phase 3: SQLite に一括書き込み（ロック短時間）
    if !new_data.is_empty() {
        let conn = db.conn.lock().unwrap_or_else(|e| e.into_inner());
        let _ = conn.execute_batch("BEGIN");
        for (path, mtime, exif) in &new_data {
            let _ = bridge_core::db::upsert(&conn, path, exif, *mtime);
        }
        let _ = conn.execute_batch("COMMIT");
    }
}

fn image_entry_list_count(list: &ImageEntryList) -> usize {
    list.entries.len()
}
fn image_entry_list_total_files(list: &ImageEntryList) -> usize {
    list.total_files
}
fn image_entry_list_image_files(list: &ImageEntryList) -> usize {
    list.image_files
}

fn image_entry_list_get(list: &ImageEntryList, idx: usize) -> FfiImageEntry {
    FfiImageEntry::from_core(&list.entries[idx])
}

fn ffi_image_entry_id(entry: &FfiImageEntry) -> u64 {
    entry.id
}
fn ffi_image_entry_path(entry: &FfiImageEntry) -> String {
    entry.path.clone()
}
fn ffi_image_entry_filename(entry: &FfiImageEntry) -> String {
    entry.filename.clone()
}
fn ffi_image_entry_is_raw(entry: &FfiImageEntry) -> bool {
    entry.is_raw
}
fn ffi_image_entry_file_size(entry: &FfiImageEntry) -> u64 {
    entry.file_size
}
fn ffi_image_entry_modified_unix(entry: &FfiImageEntry) -> i64 {
    entry.modified_unix
}
fn ffi_image_entry_created_unix(entry: &FfiImageEntry) -> i64 {
    entry.created_unix
}
fn ffi_image_entry_has_jpg_partner(entry: &FfiImageEntry) -> bool {
    entry.has_jpg_partner
}
fn ffi_image_entry_shot_id(entry: &FfiImageEntry) -> u64 {
    entry.shot_id
}

// ── EXIF API impl ──────────────────────────────────────────────────────────

fn bridge_fetch_exif(db: &BridgeDatabase, path: &str) -> FfiExifResult {
    let p = Path::new(path);
    let conn = db.conn.lock().unwrap_or_else(|e| e.into_inner());
    bridge_core::db::fetch_or_index(p, &conn)
        .as_ref()
        .map(FfiExifResult::from_core)
        .unwrap_or_else(FfiExifResult::not_found)
}

fn ffi_exif_found(r: &FfiExifResult) -> bool {
    r.found
}
fn ffi_exif_make(r: &FfiExifResult) -> String {
    r.make.clone()
}
fn ffi_exif_model(r: &FfiExifResult) -> String {
    r.model.clone()
}
fn ffi_exif_datetime(r: &FfiExifResult) -> String {
    r.datetime.clone()
}
fn ffi_exif_subsec(r: &FfiExifResult) -> String {
    r.subsec.clone()
}
fn ffi_exif_exposure(r: &FfiExifResult) -> String {
    r.exposure.clone()
}
fn ffi_exif_fnumber(r: &FfiExifResult) -> String {
    r.fnumber.clone()
}
fn ffi_exif_iso(r: &FfiExifResult) -> i32 {
    r.iso
}
fn ffi_exif_focal_length(r: &FfiExifResult) -> String {
    r.focal_length.clone()
}
fn ffi_exif_focal_length_35mm(r: &FfiExifResult) -> i32 {
    r.focal_length_35mm
}
fn ffi_exif_lens_model(r: &FfiExifResult) -> String {
    r.lens_model.clone()
}
fn ffi_exif_width(r: &FfiExifResult) -> i32 {
    r.width
}
fn ffi_exif_height(r: &FfiExifResult) -> i32 {
    r.height
}
fn ffi_exif_software(r: &FfiExifResult) -> String {
    r.software.clone()
}
fn ffi_exif_artist(r: &FfiExifResult) -> String {
    r.artist.clone()
}
fn ffi_exif_exposure_bias(r: &FfiExifResult) -> String {
    r.exposure_bias.clone()
}
fn ffi_exif_flash(r: &FfiExifResult) -> String {
    r.flash.clone()
}
fn ffi_exif_white_balance(r: &FfiExifResult) -> String {
    r.white_balance.clone()
}
fn ffi_exif_image_description(r: &FfiExifResult) -> String {
    r.image_description.clone()
}
fn ffi_exif_user_comment(r: &FfiExifResult) -> String {
    r.user_comment.clone()
}

fn bridge_fetch_exif_for_entries(db: &BridgeDatabase, entries: &ImageEntryList) -> FfiExifBatch {
    let path_mtimes: Vec<(PathBuf, i64)> = entries
        .entries
        .iter()
        .map(|e| (e.path.clone(), system_time_to_unix(e.modified)))
        .collect();
    let paths_only: Vec<PathBuf> = path_mtimes.iter().map(|(p, _)| p.clone()).collect();
    let conn = db.conn.lock().unwrap_or_else(|e| e.into_inner());
    let mut map = bridge_core::db::fetch_exif_batch(&path_mtimes, &conn);
    let results = paths_only
        .into_iter()
        .map(|p| {
            map.remove(&p)
                .map(|e| FfiExifResult::from_core(&e))
                .unwrap_or_else(FfiExifResult::not_found)
        })
        .collect();
    FfiExifBatch { results }
}

fn ffi_exif_batch_count(r: &FfiExifBatch) -> usize {
    r.results.len()
}
fn ffi_exif_batch_exif_at(r: &FfiExifBatch, idx: usize) -> FfiExifResult {
    r.results[idx].clone()
}

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

fn ffi_xmp_found(r: &FfiXmpResult) -> bool {
    r.found
}
fn ffi_xmp_rating(r: &FfiXmpResult) -> i32 {
    r.rating
}
fn ffi_xmp_label(r: &FfiXmpResult) -> u8 {
    r.label
}
fn ffi_xmp_flag(r: &FfiXmpResult) -> u8 {
    r.flag
}
fn ffi_xmp_developed(r: &FfiXmpResult) -> bool {
    r.developed
}
fn ffi_xmp_caption(r: &FfiXmpResult) -> String {
    r.caption.clone()
}

fn bridge_write_xmp(
    db: &BridgeDatabase,
    path: &str,
    rating: i32,
    label: u8,
    flag: u8,
    caption: &str,
    caption_present: bool,
    jpg_use_sidecar: bool,
) -> bool {
    let p = Path::new(path);
    // When caption_present=false (rating-only write), preserve the existing caption
    // by reading the current XMP and passing it through unchanged.
    let caption_value = if caption_present {
        // Empty string = clear; non-empty = set
        Some(caption.to_string())
    } else {
        // Preserve whatever is already in the XMP (None means don't touch)
        bridge_core::xmp::read_metadata(p, jpg_use_sidecar).and_then(|d| d.caption)
    };
    let data = CoreXmpData {
        rating: if rating >= 0 {
            Some(rating.clamp(0, 5) as u8)
        } else {
            None
        },
        label: label_from_u8(label),
        flag: flag_from_u8(flag),
        developed: false,
        caption: caption_value,
    };
    let ok = bridge_core::xmp::write_metadata(p, &data, jpg_use_sidecar).is_ok();
    if ok {
        let conn = db.conn.lock().unwrap_or_else(|e| e.into_inner());
        bridge_core::db::update_xmp(p, &conn, &data);
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
    let conn = db.conn.lock().unwrap_or_else(|e| e.into_inner());
    bridge_core::db::fetch_phash(p, &conn)
        .map(|v| v as i64)
        .unwrap_or(-1)
}

fn bridge_store_phash(db: &BridgeDatabase, path: &str, phash: u64) {
    let p = Path::new(path);
    let conn = db.conn.lock().unwrap_or_else(|e| e.into_inner());
    bridge_core::db::store_phash(p, &conn, phash);
}

// ── Thumbnail cache API impl ───────────────────────────────────────────────

fn bridge_fetch_cached_thumbnail(db: &BridgeDatabase, path: &str) -> FfiOptionalBytes {
    let p = Path::new(path);
    let conn = db.conn.lock().unwrap_or_else(|e| e.into_inner());
    bridge_core::db::fetch_thumb(p, &conn)
        .map(FfiOptionalBytes::some)
        .unwrap_or_else(FfiOptionalBytes::none)
}

fn ffi_optional_bytes_found(r: &FfiOptionalBytes) -> bool {
    r.found
}
fn ffi_optional_bytes_data(r: &FfiOptionalBytes) -> Vec<u8> {
    r.data.clone()
}
#[allow(dead_code)]
fn ffi_optional_bytes_aspect_ok(r: &FfiOptionalBytes) -> bool {
    r.aspect_ok
}
#[allow(dead_code)]
fn ffi_optional_bytes_raw_orientation(r: &FfiOptionalBytes) -> u8 {
    r.raw_orientation
}

fn bridge_store_cached_thumbnail(
    db: &BridgeDatabase,
    path: &str,
    jpeg: &[u8],
    aspect_ok: bool,
    raw_orientation: u8,
) {
    let p = Path::new(path);
    let conn = db.conn.lock().unwrap_or_else(|e| e.into_inner());
    bridge_core::db::store_thumb(p, &conn, jpeg, aspect_ok, raw_orientation);
}

fn bridge_thumb_batch_new(db: &BridgeDatabase) -> ThumbBatchBuilder {
    ThumbBatchBuilder {
        items: Mutex::new(Vec::new()),
        conn: Arc::clone(&db.conn),
    }
}

fn bridge_thumb_batch_push(
    builder: &ThumbBatchBuilder,
    path: &str,
    jpeg: &[u8],
    aspect_ok: bool,
    raw_orientation: u8,
) {
    let mut guard = builder.items.lock().unwrap_or_else(|e| e.into_inner());
    guard.push((
        PathBuf::from(path),
        jpeg.to_vec(),
        aspect_ok,
        raw_orientation,
    ));
}

fn bridge_thumb_batch_flush(builder: &ThumbBatchBuilder) {
    let items: Vec<_> = {
        let mut guard = builder.items.lock().unwrap_or_else(|e| e.into_inner());
        std::mem::take(&mut *guard)
    };
    if !items.is_empty() {
        let conn = builder.conn.lock().unwrap_or_else(|e| e.into_inner());
        bridge_core::db::store_thumb_batch(&items, &conn);
    }
}

fn bridge_fetch_cached_thumbnails_for_entries(
    db: &BridgeDatabase,
    entries: &ImageEntryList,
) -> FfiThumbBatch {
    let path_mtimes: Vec<(PathBuf, i64)> = entries
        .entries
        .iter()
        .map(|e| (e.path.clone(), system_time_to_unix(e.modified)))
        .collect();
    let paths_only: Vec<PathBuf> = path_mtimes.iter().map(|(p, _)| p.clone()).collect();
    let conn = db.conn.lock().unwrap_or_else(|e| e.into_inner());
    let mut map = bridge_core::db::fetch_thumb_batch(&path_mtimes, &conn);
    let results = paths_only
        .into_iter()
        .map(|p| {
            map.remove(&p)
                .map(FfiOptionalBytes::some)
                .unwrap_or_else(FfiOptionalBytes::none)
        })
        .collect();
    FfiThumbBatch { results }
}

fn ffi_thumb_batch_count(r: &FfiThumbBatch) -> usize {
    r.results.len()
}
fn ffi_thumb_batch_jpeg_at(r: &FfiThumbBatch, idx: usize) -> FfiOptionalBytes {
    r.results[idx].clone()
}

// ── Rendered thumbnail cache API impl ─────────────────────────────────────

fn bridge_fetch_cached_rendered(
    db: &BridgeDatabase,
    path: &str,
    engine: &str,
    width: u32,
) -> FfiOptionalBytes {
    let p = Path::new(path);
    let conn = db.conn.lock().unwrap_or_else(|e| e.into_inner());
    bridge_core::db::fetch_rendered(p, &conn, engine, width)
        .map(FfiOptionalBytes::some_data)
        .unwrap_or_else(FfiOptionalBytes::none)
}

fn bridge_store_cached_rendered(
    db: &BridgeDatabase,
    path: &str,
    engine: &str,
    width: u32,
    jpeg: &[u8],
) {
    let p = Path::new(path);
    let conn = db.conn.lock().unwrap_or_else(|e| e.into_inner());
    bridge_core::db::store_rendered(p, &conn, engine, width, jpeg);
}

fn bridge_clear_rendered_cache(db: &BridgeDatabase) {
    let conn = db.conn.lock().unwrap_or_else(|e| e.into_inner());
    bridge_core::db::clear_rendered(&conn);
}

fn bridge_prune_cache(db: &BridgeDatabase, max_age_days: u32) {
    let conn = db.conn.lock().unwrap_or_else(|e| e.into_inner());
    bridge_core::db::prune_cache(&conn, max_age_days);
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
        .map(FfiOptionalBytes::some_data)
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

    let path_mtimes: Vec<(PathBuf, i64)> = images
        .iter()
        .map(|e| (e.path.clone(), system_time_to_unix(e.modified)))
        .collect();
    let conn = db.conn.lock().unwrap_or_else(|e| e.into_inner());
    let exif_by_path = bridge_core::db::fetch_exif_batch(&path_mtimes, &conn);
    let exif_by_id: HashMap<usize, CoreExifData> = images
        .iter()
        .filter_map(|e| exif_by_path.get(&e.path).map(|ex| (e.id, ex.clone())))
        .collect();

    let phash_by_path = bridge_core::db::fetch_phash_batch(&path_mtimes, &conn);
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

    ShotGroupsMap {
        shot_ids,
        groups: converted,
    }
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

fn bridge_exif_index_progress() -> usize {
    EXIF_INDEX_PROGRESS.load(Ordering::Relaxed)
}

fn bridge_exif_index_total() -> usize {
    EXIF_INDEX_TOTAL.load(Ordering::Relaxed)
}
