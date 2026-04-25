use std::collections::{BTreeSet, HashMap, HashSet, VecDeque};
use std::path::PathBuf;

use iced::keyboard::{self, key};
use iced::widget::image::{Handle as ImageHandle, Image};
use iced::widget::{button, checkbox, column, container, radio, row, scrollable, text, text_input, Row, Space};
use iced::{Alignment, ContentFit, Element, Length, Subscription, Task};

use crate::config::{Settings, ThemeChoice};
use crate::i18n::{self, Language};
use crate::metadata::{parse_focal_mm, ExifData};
use crate::scanner::ImageEntry;
use crate::thumbnail::ThumbResult;
use crate::xmp::{Flag, Label, XmpData};
use crate::theme::{alpha, font_size, radius, spacing};

// ── Constants ──────────────────────────────────────────────────────────────

const THUMB_DISPLAY: f32 = 180.0;
const FILTER_PANEL_WIDTH: f32 = 190.0;
const SIDEBAR_WIDTH: f32 = 260.0;
const GRID_COLUMNS: usize = 4;
/// Max concurrent thumbnail generation tasks
const THUMB_CONCURRENCY: usize = 16;
/// Max concurrent pHash computation tasks (separate pool to avoid CPU saturation)
const PHASH_CONCURRENCY: usize = 4;
/// Max long-edge for sidebar preview (pixels)
const PREVIEW_MAX_PX: u32 = 1000;
/// Max long-edge for fullscreen viewer (pixels, safety cap for memory)
const FULL_MAX_PX: u32 = 4000;

// ── Filter state ───────────────────────────────────────────────────────────

#[derive(Debug, Default)]
struct FilterState {
    excluded_cameras: HashSet<String>,
    iso_min: String,
    iso_max: String,
    focal_min: String,
    focal_max: String,
    date_from: String,
    date_to: String,
    filter_ratings: HashSet<u8>,
    filter_labels: HashSet<Label>,
    filter_flags: HashSet<Flag>,
}

impl FilterState {
    fn is_active(&self) -> bool {
        !self.excluded_cameras.is_empty()
            || !self.iso_min.is_empty()
            || !self.iso_max.is_empty()
            || !self.focal_min.is_empty()
            || !self.focal_max.is_empty()
            || !self.date_from.is_empty()
            || !self.date_to.is_empty()
            || !self.filter_ratings.is_empty()
            || !self.filter_labels.is_empty()
            || !self.filter_flags.is_empty()
    }

    fn passes(&self, exif: Option<&ExifData>, xmp: Option<&XmpData>) -> bool {
        if !self.excluded_cameras.is_empty() {
            if let Some(model) = exif.and_then(|e| e.model.as_deref()) {
                if self.excluded_cameras.contains(model) {
                    return false;
                }
            }
        }
        let iso = exif.and_then(|e| e.iso);
        if let Some(min) = parse_u32(&self.iso_min) {
            if iso.map_or(true, |v| v < min) {
                return false;
            }
        }
        if let Some(max) = parse_u32(&self.iso_max) {
            if iso.map_or(true, |v| v > max) {
                return false;
            }
        }
        let focal = exif
            .and_then(|e| e.focal_length.as_deref())
            .and_then(parse_focal_mm);
        if let Some(min) = parse_f32(&self.focal_min) {
            if focal.map_or(true, |v| v < min) {
                return false;
            }
        }
        if let Some(max) = parse_f32(&self.focal_max) {
            if focal.map_or(true, |v| v > max) {
                return false;
            }
        }
        let date_exif = exif
            .and_then(|e| e.datetime.as_deref())
            .and_then(|s| s.get(..10))
            .map(|s| s.replace(':', "-"));
        if !self.date_from.is_empty() {
            let from = &self.date_from;
            if date_exif.as_deref().map_or(true, |d| d < from.as_str()) {
                return false;
            }
        }
        if !self.date_to.is_empty() {
            let to = &self.date_to;
            if date_exif.as_deref().map_or(true, |d| d > to.as_str()) {
                return false;
            }
        }

        // XMP rating filter: set membership check; 0 = unrated
        if !self.filter_ratings.is_empty() {
            let rating = xmp.and_then(|x| x.rating).unwrap_or(0);
            if !self.filter_ratings.contains(&rating) {
                return false;
            }
        }

        // Label filter: only show images whose label is in the selected set
        if !self.filter_labels.is_empty() {
            match xmp.and_then(|x| x.label) {
                Some(l) if self.filter_labels.contains(&l) => {}
                _ => return false,
            }
        }

        // Flag filter: only show images whose flag is in the selected set
        if !self.filter_flags.is_empty() {
            match xmp.and_then(|x| x.flag) {
                Some(f) if self.filter_flags.contains(&f) => {}
                _ => return false,
            }
        }

        true
    }
}

fn parse_u32(s: &str) -> Option<u32> {
    let s = s.trim();
    if s.is_empty() { None } else { s.parse().ok() }
}
fn parse_f32(s: &str) -> Option<f32> {
    let s = s.trim();
    if s.is_empty() { None } else { s.parse().ok() }
}

// ── App state ──────────────────────────────────────────────────────────────

#[derive(Debug, Default)]
pub struct App {
    dir_input: String,
    images: Vec<ImageEntry>,
    thumbnails: HashMap<usize, ThumbnailState>,
    exif_data: HashMap<usize, ExifData>,
    xmp_data: HashMap<usize, XmpData>,
    indexed_count: usize,
    selected: Option<usize>,
    /// Medium-res preview loaded asynchronously for the selected image
    preview_handle: Option<ImageHandle>,
    /// Full-resolution image for the fullscreen viewer
    full_res_handle: Option<ImageHandle>,
    /// Whether the fullscreen viewer is active
    viewer_mode: bool,
    status: String,
    loading: bool,
    db_path: PathBuf,
    available_cameras: BTreeSet<String>,
    filter: FilterState,
    show_filters: bool,
    show_grid: bool,
    show_sidebar: bool,
    /// Reverse lookup: shot_id → list of all entry ids sharing that shot.
    shot_groups: HashMap<u64, Vec<usize>>,
    /// Perceptual hashes keyed by entry id (populated after thumbnail generation)
    phashes: HashMap<usize, u64>,
    /// Entry ids for which pHash computation has been attempted (success or failure)
    phash_attempted: HashSet<usize>,
    /// Number of pHash compute tasks currently in flight
    phash_active: usize,
    /// Pending pHash compute queue (entry id → path)
    phash_queue: VecDeque<(usize, PathBuf)>,
    /// Pending thumbnail generation queue (processed THUMB_CONCURRENCY at a time)
    thumb_queue: VecDeque<(usize, PathBuf)>,
    /// Persisted user preferences
    settings: Settings,
    /// In-flight edits of `settings` while the settings screen is open
    settings_draft: Settings,
    /// Whether the settings screen is currently visible
    show_settings: bool,
    /// Whether the About screen is visible
    show_about: bool,
}

#[derive(Debug, Clone)]
enum ThumbnailState {
    Loading,
    Loaded(ImageHandle),
    Failed,
}

// ── Messages ───────────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub enum Message {
    DbReady(PathBuf),
    DirInputChanged(String),
    OpenDirectory,
    DirectoryScanned(Vec<ImageEntry>),
    ThumbnailLoaded { id: usize, handle: ImageHandle },
    ThumbnailFailed(usize),
    ExifBatchLoaded(HashMap<PathBuf, ExifData>),
    ExifIndexed { id: usize, exif: Option<ExifData> },
    XmpBatchLoaded(HashMap<usize, XmpData>),
    XmpWriteResult(bool),
    ImageSelected(usize),
    PreviewLoaded { id: usize, handle: Option<ImageHandle> },
    FullResLoaded(Option<ImageHandle>),
    EnterViewer,
    ExitViewer,
    NavigateNext,
    NavigatePrev,
    KeyboardEvent(keyboard::Event),
    // Native menu bar
    MenuAction(muda::MenuId),
    // Panel visibility
    ToggleFilterPanel,
    ToggleGridPanel,
    ToggleSidebar,
    // Settings
    OpenSettings,
    CloseSettings,
    SettingsDefaultPathChanged(String),
    SettingsThemeChanged(ThemeChoice),
    SettingsLanguageChanged(Language),
    SettingsSave,
    // About
    ShowAbout,
    CloseAbout,
    // Filter
    CameraVisibilityChanged(String, bool),
    IsoMinChanged(String),
    IsoMaxChanged(String),
    FocalMinChanged(String),
    FocalMaxChanged(String),
    DateFromChanged(String),
    DateToChanged(String),
    FilterReset,
    RatingFilterToggled(u8),
    CyclePairVariant { reverse: bool },
    ReindexShotGroups,
    LabelFilterToggled(Label),
    FlagFilterToggled(Flag),
    PhashBatchLoaded(HashMap<PathBuf, u64>),
    PhashIndexed { id: usize, phash: Option<u64> },
}

// ── Entry point ────────────────────────────────────────────────────────────

pub fn run_with(settings: Settings) -> iced::Result {
    iced::application(move || boot(settings.clone()), update, view)
        .title("bridge-lite")
        .theme(|state: &App| state.settings.theme.to_iced())
        .subscription(subscription)
        .default_font(iced::Font::with_name("Inter"))
        .font(include_bytes!("../assets/fonts/InterVariable.ttf").as_slice())
        .font(include_bytes!("../assets/fonts/JetBrainsMono-Regular.ttf").as_slice())
        .window(iced::window::Settings {
            size: iced::Size::new(1400.0, 860.0),
            min_size: Some(iced::Size::new(800.0, 500.0)),
            ..Default::default()
        })
        .run()
}

fn boot(settings: Settings) -> (App, Task<Message>) {
    let db_path = crate::db::db_path();
    let init_path = db_path.clone();
    let fallback = db_path.clone();
    let task = Task::perform(
        async move {
            tokio::task::spawn_blocking(move || {
                crate::db::ensure_schema(&init_path);
                init_path
            })
            .await
            .unwrap_or(fallback)
        },
        Message::DbReady,
    );
    let mut app = App::default();
    app.db_path = db_path;
    app.show_filters = true;
    app.show_grid = true;
    app.show_sidebar = true;
    app.dir_input = settings.default_path.clone();
    app.settings_draft = settings.clone();
    app.settings = settings;
    (app, task)
}

fn subscription(_state: &App) -> Subscription<Message> {
    Subscription::batch([
        keyboard::listen().map(Message::KeyboardEvent),
        Subscription::run(crate::menu::event_stream).map(Message::MenuAction),
    ])
}

// ── Update ─────────────────────────────────────────────────────────────────

fn update(state: &mut App, message: Message) -> Task<Message> {
    match message {
        Message::DbReady(path) => {
            state.db_path = path;
            Task::none()
        }

        Message::DirInputChanged(s) => {
            state.dir_input = s;
            Task::none()
        }

        Message::OpenDirectory => {
            let path = PathBuf::from(state.dir_input.trim());
            if !path.is_dir() {
                state.status = i18n::format_dir_not_found(state.settings.language, &path);
                return Task::none();
            }
            state.loading = true;
            state.images.clear();
            state.thumbnails.clear();
            state.exif_data.clear();
            state.xmp_data.clear();
            state.shot_groups.clear();
            state.phashes.clear();
            state.phash_attempted.clear();
            state.phash_active = 0;
            state.phash_queue.clear();
            state.available_cameras.clear();
            state.filter = FilterState::default();
            state.indexed_count = 0;
            state.selected = None;
            state.preview_handle = None;
            state.thumb_queue.clear();
            state.status = i18n::t(state.settings.language).scanning.to_string();

            Task::perform(
                async move {
                    tokio::task::spawn_blocking(move || crate::scanner::scan_directory(path))
                        .await
                        .unwrap_or_default()
                },
                Message::DirectoryScanned,
            )
        }

        Message::DirectoryScanned(images) => {
            let total = images.len();
            state.loading = false;
            state.status = i18n::format_images_header(state.settings.language, total);

            // Build shot_groups reverse-lookup: shot_id → Vec<entry_id>
            state.shot_groups.clear();
            for entry in &images {
                state.shot_groups
                    .entry(entry.shot_id)
                    .or_default()
                    .push(entry.id);
            }
            // Sort each group by (created asc, is_raw, filename) so that
            // SOOC JPG → RAW → developed variants appear in shooting order.
            for group in state.shot_groups.values_mut() {
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

            for entry in &images {
                state.thumbnails.insert(entry.id, ThumbnailState::Loading);
            }

            // Queue all entries; start only the first THUMB_CONCURRENCY tasks.
            let mut queue: VecDeque<(usize, PathBuf)> = images
                .iter()
                .map(|e| (e.id, e.path.clone()))
                .collect();
            let initial: Vec<(usize, PathBuf)> = queue
                .drain(..THUMB_CONCURRENCY.min(total))
                .collect();
            state.thumb_queue = queue;

            let db_path = state.db_path.clone();
            let thumb_tasks: Vec<Task<Message>> = initial
                .into_iter()
                .map(|(id, path)| {
                    let dbp = db_path.clone();
                    Task::perform(crate::thumbnail::generate(id, path, dbp), |r| match r {
                        ThumbResult::Loaded { id, handle } => {
                            Message::ThumbnailLoaded { id, handle }
                        }
                        ThumbResult::Failed(id) => Message::ThumbnailFailed(id),
                    })
                })
                .collect();

            // Fetch all cached EXIF in one shot (single connection, one SELECT per
            // 500-path chunk). Only uncached paths trigger individual file reads later.
            let paths: Vec<PathBuf> = images.iter().map(|e| e.path.clone()).collect();
            let batch_task = Task::perform(
                crate::db::fetch_exif_batch_async(paths.clone(), db_path.clone()),
                Message::ExifBatchLoaded,
            );

            // Prefetch cached pHashes from DB in parallel with EXIF batch.
            let phash_batch_task = Task::perform(
                crate::db::fetch_phash_batch_async(paths, db_path.clone()),
                Message::PhashBatchLoaded,
            );

            // Read XMP sidecars for all images in a blocking thread.
            let xmp_entries: Vec<(usize, PathBuf)> =
                images.iter().map(|e| (e.id, e.path.clone())).collect();
            let xmp_task = Task::perform(
                async move {
                    tokio::task::spawn_blocking(move || {
                        xmp_entries
                            .into_iter()
                            .filter_map(|(id, path)| {
                                crate::xmp::read_metadata(&path).map(|x| (id, x))
                            })
                            .collect::<HashMap<usize, XmpData>>()
                    })
                    .await
                    .unwrap_or_default()
                },
                Message::XmpBatchLoaded,
            );

            state.images = images;
            let mut all = thumb_tasks;
            all.push(batch_task);
            all.push(phash_batch_task);
            all.push(xmp_task);
            Task::batch(all)
        }

        Message::ThumbnailLoaded { id, handle } => {
            state.thumbnails.insert(id, ThumbnailState::Loaded(handle));
            let thumb_task = dequeue_thumb(state);
            // Trigger pHash computation for this entry now that its thumbnail JPEG
            // is cached — reuses the JPEG bytes to avoid a second decode.
            let phash_task = maybe_spawn_phash(state, id);
            Task::batch([thumb_task, phash_task])
        }

        Message::ThumbnailFailed(id) => {
            state.thumbnails.insert(id, ThumbnailState::Failed);
            // Still attempt pHash via fallback paths even when thumbnail fails.
            let thumb_task = dequeue_thumb(state);
            let phash_task = maybe_spawn_phash(state, id);
            Task::batch([thumb_task, phash_task])
        }

        Message::ReindexShotGroups => {
            state.shot_groups = crate::pairing::reindex_shot_groups(
                &mut state.images,
                &state.exif_data,
                &state.phashes,
            );
            Task::none()
        }

        Message::PhashBatchLoaded(map) => {
            for entry in &state.images {
                if let Some(&phash) = map.get(&entry.path) {
                    state.phashes.insert(entry.id, phash);
                    state.phash_attempted.insert(entry.id);
                }
                // Misses will be computed via ThumbnailLoaded hook.
            }
            if should_reindex(state) {
                Task::done(Message::ReindexShotGroups)
            } else {
                Task::none()
            }
        }

        Message::PhashIndexed { id, phash } => {
            if let Some(p) = phash {
                state.phashes.insert(id, p);
            }
            state.phash_attempted.insert(id);
            state.phash_active = state.phash_active.saturating_sub(1);
            // Drain queue
            let drain_task = drain_phash_queue(state);
            if should_reindex(state) {
                Task::batch([drain_task, Task::done(Message::ReindexShotGroups)])
            } else {
                drain_task
            }
        }

        Message::ExifBatchLoaded(map) => {
            let mut missed: Vec<(usize, PathBuf)> = Vec::new();
            for entry in &state.images {
                if let Some(exif) = map.get(&entry.path) {
                    if let Some(model) = &exif.model {
                        state.available_cameras.insert(model.clone());
                    }
                    state.exif_data.insert(entry.id, exif.clone());
                    state.indexed_count += 1;
                } else {
                    missed.push((entry.id, entry.path.clone()));
                }
            }
            update_status(state);
            // Spawn individual index tasks only for cache misses.
            let db_path = state.db_path.clone();
            let tasks: Vec<Task<Message>> = missed
                .into_iter()
                .map(|(id, path)| {
                    let dbp = db_path.clone();
                    Task::perform(
                        crate::db::fetch_or_index_async(id, path, dbp),
                        |(id, exif)| Message::ExifIndexed { id, exif },
                    )
                })
                .collect();
            // If the batch covered every image (no misses), trigger timestamp regrouping now.
            let reindex = if tasks.is_empty() && should_reindex(state) {
                Task::done(Message::ReindexShotGroups)
            } else {
                Task::none()
            };
            let mut all = tasks;
            all.push(reindex);
            Task::batch(all)
        }

        Message::ExifIndexed { id, exif } => {
            if let Some(e) = exif {
                if let Some(model) = &e.model {
                    state.available_cameras.insert(model.clone());
                }
                state.exif_data.insert(id, e);
            }
            state.indexed_count += 1;
            update_status(state);
            // Trigger timestamp regrouping once the last EXIF miss completes.
            if should_reindex(state) {
                Task::done(Message::ReindexShotGroups)
            } else {
                Task::none()
            }
        }

        Message::XmpBatchLoaded(map) => {
            state.xmp_data = map;
            Task::none()
        }

        Message::XmpWriteResult(success) => {
            if !success {
                eprintln!("bridge-lite: XMP write failed");
            }
            Task::none()
        }

        Message::ImageSelected(id) => {
            select_image(state, id)
        }

        Message::NavigateNext => {
            let ids = filtered_ids(state);
            if let Some(next) = navigate(&ids, state.selected, 1) {
                select_image(state, next)
            } else {
                Task::none()
            }
        }

        Message::NavigatePrev => {
            let ids = filtered_ids(state);
            if let Some(prev) = navigate(&ids, state.selected, -1) {
                select_image(state, prev)
            } else {
                Task::none()
            }
        }

        Message::KeyboardEvent(event) => {
            match event {
                keyboard::Event::KeyPressed { key, modifiers, .. } => {
                    // Cmd+, → open settings
                    if modifiers.command() {
                        if let keyboard::Key::Character(ref c) = key {
                            if c.as_str() == "," {
                                state.settings_draft = state.settings.clone();
                                state.show_settings = !state.show_settings;
                                return Task::none();
                            }
                        }
                    }
                    match key {
                    keyboard::Key::Named(key::Named::ArrowRight) => {
                        let ids = filtered_ids(state);
                        if let Some(next) = navigate(&ids, state.selected, 1) {
                            return select_image(state, next);
                        }
                    }
                    keyboard::Key::Named(key::Named::ArrowLeft) => {
                        let ids = filtered_ids(state);
                        if let Some(prev) = navigate(&ids, state.selected, -1) {
                            return select_image(state, prev);
                        }
                    }
                    keyboard::Key::Named(key::Named::Space) => {
                        if state.selected.is_some() {
                            if state.viewer_mode {
                                state.viewer_mode = false;
                            } else {
                                state.viewer_mode = true;
                                state.full_res_handle = None;
                                if let Some(path) = state.selected
                                    .and_then(|id| state.images.get(id))
                                    .map(|e| e.path.clone())
                                {
                                    return Task::perform(
                                        async move {
                                            tokio::task::spawn_blocking(move || load_full_res(&path))
                                                .await
                                                .ok()
                                                .flatten()
                                        },
                                        Message::FullResLoaded,
                                    );
                                }
                            }
                        }
                    }
                    keyboard::Key::Named(key::Named::Escape) => {
                        if state.viewer_mode {
                            state.viewer_mode = false;
                        } else if state.show_about {
                            state.show_about = false;
                        } else if state.show_settings {
                            state.show_settings = false;
                        }
                    }
                    keyboard::Key::Named(key::Named::Tab)
                        if !state.show_settings && !state.show_about =>
                    {
                        let reverse = modifiers.shift();
                        return Task::done(Message::CyclePairVariant { reverse });
                    }
                    keyboard::Key::Character(ref c)
                        if !modifiers.command()
                            && !modifiers.alt()
                            && !modifiers.control()
                            && !state.show_settings
                            && !state.show_about =>
                    {
                        if let Some(id) = state.selected {
                            if let Some(path) = state.images.get(id).map(|e| e.path.clone()) {
                                let mut data = state.xmp_data.get(&id).cloned().unwrap_or_default();
                                let changed = apply_rating_key(c.as_str(), &mut data);
                                if changed {
                                    state.xmp_data.insert(id, data.clone());
                                    let db_path = state.db_path.clone();
                                    return Task::perform(
                                        async move {
                                            tokio::task::spawn_blocking(move || {
                                                let ok = crate::xmp::write_metadata(&path, &data).is_ok();
                                                if ok {
                                                    crate::db::update_xmp(&path, &db_path, &data);
                                                }
                                                ok
                                            })
                                            .await
                                            .unwrap_or(false)
                                        },
                                        Message::XmpWriteResult,
                                    );
                                }
                            }
                        }
                    }
                    _ => {}
                    }
                }
                _ => {}
            }
            Task::none()
        }

        Message::PreviewLoaded { id, handle } => {
            if state.selected == Some(id) {
                state.preview_handle = handle;
            }
            Task::none()
        }

        Message::FullResLoaded(handle) => {
            state.full_res_handle = handle;
            Task::none()
        }

        Message::EnterViewer => {
            if state.selected.is_none() {
                return Task::none();
            }
            state.viewer_mode = true;
            state.full_res_handle = None;
            let Some(path) = state.selected.and_then(|id| state.images.get(id)).map(|e| e.path.clone()) else {
                return Task::none();
            };
            Task::perform(
                async move {
                    tokio::task::spawn_blocking(move || load_full_res(&path))
                        .await
                        .ok()
                        .flatten()
                },
                Message::FullResLoaded,
            )
        }

        Message::ExitViewer => {
            state.viewer_mode = false;
            Task::none()
        }

        // ── Filter messages ─────────────────────────────────────────────

        Message::MenuAction(id) => {
            let ids = crate::menu::ids();
            if id == ids.open_dir {
                return update(state, Message::OpenDirectory);
            } else if id == ids.settings {
                return update(state, Message::OpenSettings);
            } else if id == ids.toggle_filter {
                return update(state, Message::ToggleFilterPanel);
            } else if id == ids.toggle_grid {
                return update(state, Message::ToggleGridPanel);
            } else if id == ids.toggle_sidebar {
                return update(state, Message::ToggleSidebar);
            } else if id == ids.about || id == ids.app_about {
                return update(state, Message::ShowAbout);
            }
            Task::none()
        }

        Message::OpenSettings => {
            state.settings_draft = state.settings.clone();
            state.show_settings = true;
            Task::none()
        }
        Message::CloseSettings => {
            state.show_settings = false;
            Task::none()
        }
        Message::SettingsDefaultPathChanged(s) => {
            state.settings_draft.default_path = s;
            Task::none()
        }
        Message::SettingsThemeChanged(t) => {
            state.settings_draft.theme = t;
            Task::none()
        }
        Message::SettingsLanguageChanged(lang) => {
            state.settings_draft.language = lang;
            Task::none()
        }
        Message::SettingsSave => {
            state.settings = state.settings_draft.clone();
            let _ = state.settings.save();
            crate::menu::update_language(state.settings.language);
            update_status(state);
            state.show_settings = false;
            Task::none()
        }
        Message::ShowAbout => {
            state.show_about = true;
            Task::none()
        }
        Message::CloseAbout => {
            state.show_about = false;
            Task::none()
        }

        Message::ToggleFilterPanel => {
            state.show_filters = !state.show_filters;
            Task::none()
        }
        Message::ToggleGridPanel => {
            state.show_grid = !state.show_grid;
            Task::none()
        }
        Message::ToggleSidebar => {
            state.show_sidebar = !state.show_sidebar;
            Task::none()
        }
        Message::CameraVisibilityChanged(cam, visible) => {
            if visible {
                state.filter.excluded_cameras.remove(&cam);
            } else {
                state.filter.excluded_cameras.insert(cam);
            }
            update_status(state);
            Task::none()
        }
        Message::IsoMinChanged(s) => { state.filter.iso_min = s; update_status(state); Task::none() }
        Message::IsoMaxChanged(s) => { state.filter.iso_max = s; update_status(state); Task::none() }
        Message::FocalMinChanged(s) => { state.filter.focal_min = s; update_status(state); Task::none() }
        Message::FocalMaxChanged(s) => { state.filter.focal_max = s; update_status(state); Task::none() }
        Message::DateFromChanged(s) => { state.filter.date_from = s; update_status(state); Task::none() }
        Message::DateToChanged(s) => { state.filter.date_to = s; update_status(state); Task::none() }
        Message::FilterReset => {
            state.filter = FilterState::default();
            update_status(state);
            Task::none()
        }
        Message::RatingFilterToggled(rating) => {
            if !state.filter.filter_ratings.remove(&rating) {
                state.filter.filter_ratings.insert(rating);
            }
            update_status(state);
            Task::none()
        }
        Message::LabelFilterToggled(label) => {
            if !state.filter.filter_labels.remove(&label) {
                state.filter.filter_labels.insert(label);
            }
            update_status(state);
            Task::none()
        }
        Message::FlagFilterToggled(flag) => {
            if !state.filter.filter_flags.remove(&flag) {
                state.filter.filter_flags.insert(flag);
            }
            update_status(state);
            Task::none()
        }

        Message::CyclePairVariant { reverse } => {
            let Some(selected_id) = state.selected else { return Task::none() };
            let Some(entry) = state.images.get(selected_id) else { return Task::none() };
            let shot_id = entry.shot_id;
            let Some(group) = state.shot_groups.get(&shot_id) else { return Task::none() };
            if group.len() <= 1 { return Task::none(); }
            let n = group.len();
            let pos = group.iter().position(|&id| id == selected_id).unwrap_or(0);
            let next_pos = if reverse { (pos + n - 1) % n } else { (pos + 1) % n };
            let next_id = group[next_pos];
            select_image(state, next_id)
        }
    }
}

fn select_image(state: &mut App, id: usize) -> Task<Message> {
    state.selected = Some(id);
    // preview_handle はリセットしない: 新画像が届くまで前の画像を表示し続ける

    let Some(path) = state.images.get(id).map(|e| e.path.clone()) else {
        return Task::none();
    };

    // Both RAW and non-RAW: load sidebar preview asynchronously.
    // RAW uses embedded IFD0 JPEG (~174 KB medium preview).
    let target_id = id;
    let preview_task = {
        let p = path.clone();
        Task::perform(
            async move {
                let handle = tokio::task::spawn_blocking(move || load_preview(&p))
                    .await
                    .ok()
                    .flatten();
                (target_id, handle)
            },
            |(id, handle)| Message::PreviewLoaded { id, handle },
        )
    };

    if state.viewer_mode {
        // Also load full-resolution image for the viewer.
        state.full_res_handle = None;
        let full_task = Task::perform(
            async move {
                tokio::task::spawn_blocking(move || load_full_res(&path))
                    .await
                    .ok()
                    .flatten()
            },
            Message::FullResLoaded,
        );
        Task::batch([preview_task, full_task])
    } else {
        preview_task
    }
}

fn load_preview(path: &std::path::Path) -> Option<ImageHandle> {
    if crate::thumbnail::is_raw(path) {
        // Camera RAW: try embedded IFD0 JPEG (~174 KB medium preview) first.
        if let Some(bytes) = crate::raw_thumb::extract(path, crate::raw_thumb::Quality::Preview) {
            if let Ok(img) = image::load_from_memory(&bytes) {
                let img = crate::thumbnail::apply_exif_orientation(img, path);
                return rgba_resized(img, PREVIEW_MAX_PX);
            }
        }
        // No embedded JPEG (e.g. DxO output DNG): fall through to platform decoder.
    }

    // macOS CGImageSource — handles JPEG/PNG/TIFF/DNG/HEIF with EXIF rotation
    #[cfg(target_os = "macos")]
    if let Some((w, h, pixels)) = crate::macos_thumb::create_thumbnail(path, PREVIEW_MAX_PX) {
        return Some(ImageHandle::from_rgba(w, h, pixels));
    }

    // Fallback: full decode via image crate
    let img = image::open(path).ok()?;
    let img = crate::thumbnail::apply_exif_orientation(img, path);
    rgba_resized(img, PREVIEW_MAX_PX)
}

fn load_full_res(path: &std::path::Path) -> Option<ImageHandle> {
    if crate::thumbnail::is_raw(path) {
        // Camera RAW: try IFD2 (~3 MB full-size JPEG), fall back to IFD0 (~174 KB).
        let bytes = crate::raw_thumb::extract(path, crate::raw_thumb::Quality::Full)
            .or_else(|| crate::raw_thumb::extract(path, crate::raw_thumb::Quality::Preview));
        if let Some(bytes) = bytes {
            if let Ok(img) = image::load_from_memory(&bytes) {
                let img = crate::thumbnail::apply_exif_orientation(img, path);
                return rgba_resized(img, FULL_MAX_PX);
            }
        }
        // No embedded JPEG (e.g. DxO output DNG): fall through to platform decoder.
    }

    // macOS CGImageSource — handles JPEG/PNG/TIFF/DNG/HEIF with no resize cap
    #[cfg(target_os = "macos")]
    if let Some((w, h, pixels)) = crate::macos_thumb::load_image(path, 0) {
        let long_edge = w.max(h);
        if long_edge <= FULL_MAX_PX {
            return Some(ImageHandle::from_rgba(w, h, pixels));
        }
        if let Some(dyn_img) = image::RgbaImage::from_raw(w, h, pixels)
            .map(image::DynamicImage::ImageRgba8)
        {
            return rgba_resized(dyn_img, FULL_MAX_PX);
        }
    }

    // Fallback: full decode via image crate
    let img = image::open(path).ok()?;
    let img = crate::thumbnail::apply_exif_orientation(img, path);
    rgba_resized(img, FULL_MAX_PX)
}

/// Resize `img` so its long edge ≤ `max_px`, returning an `ImageHandle`.
fn rgba_resized(img: image::DynamicImage, max_px: u32) -> Option<ImageHandle> {
    use image::GenericImageView;
    let (w, h) = img.dimensions();
    let resized = if w.max(h) > max_px {
        img.resize(max_px, max_px, image::imageops::FilterType::Triangle)
    } else {
        img
    };
    let rgba = resized.to_rgba8();
    let (rw, rh) = rgba.dimensions();
    Some(ImageHandle::from_rgba(rw, rh, rgba.into_raw()))
}

// ── Helpers ────────────────────────────────────────────────────────────────

/// Pop the next pending thumbnail from the queue and start its generation task.
fn dequeue_thumb(state: &mut App) -> Task<Message> {
    if let Some((id, path)) = state.thumb_queue.pop_front() {
        let db_path = state.db_path.clone();
        Task::perform(
            crate::thumbnail::generate(id, path, db_path),
            |r| match r {
                ThumbResult::Loaded { id, handle } => Message::ThumbnailLoaded { id, handle },
                ThumbResult::Failed(id) => Message::ThumbnailFailed(id),
            },
        )
    } else {
        Task::none()
    }
}

/// If this entry's pHash hasn't been attempted yet, spawn a compute task (subject
/// to PHASH_CONCURRENCY) or enqueue it for later.
fn maybe_spawn_phash(state: &mut App, id: usize) -> Task<Message> {
    if state.phash_attempted.contains(&id) {
        return Task::none();
    }
    let path = match state.images.get(id) {
        Some(e) => e.path.clone(),
        None => return Task::none(),
    };
    if state.phash_active < PHASH_CONCURRENCY {
        state.phash_active += 1;
        let db_path = state.db_path.clone();
        Task::perform(
            crate::phash::compute_phash_async(id, path, db_path),
            |(id, phash)| Message::PhashIndexed { id, phash },
        )
    } else {
        state.phash_queue.push_back((id, path));
        Task::none()
    }
}

/// Drain the pHash queue up to PHASH_CONCURRENCY active slots.
fn drain_phash_queue(state: &mut App) -> Task<Message> {
    let mut tasks = Vec::new();
    while state.phash_active < PHASH_CONCURRENCY {
        let Some((id, path)) = state.phash_queue.pop_front() else { break };
        if state.phash_attempted.contains(&id) {
            continue;
        }
        state.phash_active += 1;
        let db_path = state.db_path.clone();
        tasks.push(Task::perform(
            crate::phash::compute_phash_async(id, path, db_path),
            |(id, phash)| Message::PhashIndexed { id, phash },
        ));
    }
    Task::batch(tasks)
}

pub(crate) const DEVELOPED_SOFTWARE_KEYWORDS: &[&str] = &[
    "lightroom",
    "dxo",
    "capture one",
    "captureone",
    "photoshop",
    "camera raw",
    "topaz",
    "on1",
    "luminar",
    "affinity",
    "darktable",
    "rawtherapee",
];

fn is_developed(software: Option<&str>, xmp: Option<&XmpData>) -> bool {
    if xmp.map(|x| x.developed).unwrap_or(false) { return true; }
    let Some(s) = software else { return false };
    let lower = s.to_lowercase();
    DEVELOPED_SOFTWARE_KEYWORDS.iter().any(|kw| lower.contains(kw))
}

/// Returns the id of the entry that should represent its shot_id in the grid.
/// Tier 0: non-RAW confirmed developed (EXIF Software matches known tools)
/// Tier 1: other non-RAW (camera original JPG or EXIF not yet loaded)
/// Tier 2: RAW
/// Within each tier, the smallest id (scan order = newest-first) wins.
fn representative_id_of(
    group: &[usize],
    images: &[crate::scanner::ImageEntry],
    exif: &HashMap<usize, ExifData>,
    xmp:  &HashMap<usize, XmpData>,
) -> usize {
    let tier = |id: usize| -> u8 {
        let Some(e) = images.get(id) else { return 3 };
        if e.is_raw { return 2; }
        let sw = exif.get(&id).and_then(|ed| ed.software.as_deref());
        if is_developed(sw, xmp.get(&id)) { 0 } else { 1 }
    };
    group.iter().copied().min_by_key(|&id| (tier(id), id)).unwrap_or(group[0])
}

/// Returns true if this entry should be shown as the representative of its shot group.
fn is_representative(entry: &crate::scanner::ImageEntry, state: &App) -> bool {
    match state.shot_groups.get(&entry.shot_id) {
        Some(group) if group.len() > 1 => {
            representative_id_of(group, &state.images, &state.exif_data, &state.xmp_data) == entry.id
        }
        _ => true,
    }
}

fn filtered_ids(state: &App) -> Vec<usize> {
    state
        .images
        .iter()
        .filter(|e| {
            is_representative(e, state)
                && state.filter.passes(state.exif_data.get(&e.id), state.xmp_data.get(&e.id))
        })
        .map(|e| e.id)
        .collect()
}

fn navigate(ids: &[usize], current: Option<usize>, delta: i32) -> Option<usize> {
    if ids.is_empty() {
        return None;
    }
    let pos = current
        .and_then(|cur| ids.iter().position(|&id| id == cur))
        .unwrap_or(0);
    let new_pos = (pos as i32 + delta).rem_euclid(ids.len() as i32) as usize;
    Some(ids[new_pos])
}

/// Apply a single rating/label/flag key to `data`. Returns true if anything changed.
fn apply_rating_key(key: &str, data: &mut XmpData) -> bool {
    match key {
        "0" => {
            if data.rating.is_some() || data.flag.is_some() {
                data.rating = None;
                data.flag   = None;
                return true;
            }
        }
        "1" | "2" | "3" | "4" | "5" => {
            let n = key.parse::<u8>().unwrap();
            let changed = data.rating != Some(n) || data.flag.is_some();
            data.flag   = None;
            data.rating = Some(n);
            return changed;
        }
        "6" => return toggle_label(data, Label::Red),
        "7" => return toggle_label(data, Label::Yellow),
        "8" => return toggle_label(data, Label::Green),
        "9" => return toggle_label(data, Label::Blue),
        "p" | "P" => {
            let next = if data.flag == Some(Flag::Pick) { None } else { Some(Flag::Pick) };
            let changed = data.flag != next;
            data.flag = next;
            return changed;
        }
        "x" | "X" => {
            if data.flag == Some(Flag::Reject) {
                data.flag = None;
            } else {
                data.flag   = Some(Flag::Reject);
                data.rating = None;
            }
            return true;
        }
        _ => {}
    }
    false
}

fn toggle_label(data: &mut XmpData, label: Label) -> bool {
    let next = if data.label == Some(label) { None } else { Some(label) };
    let changed = data.label != next;
    data.label = next;
    changed
}

/// True once both EXIF and pHash have been fully indexed/attempted for all images,
/// which is the signal to run the final shot-group reindex.
fn should_reindex(state: &App) -> bool {
    !state.images.is_empty()
        && state.indexed_count >= state.images.len()
        && state.phash_attempted.len() >= state.images.len()
}

fn update_status(state: &mut App) {
    let lang = state.settings.language;
    let visible = filtered_ids(state).len();
    let total = state.images.len();
    let indexing = state.indexed_count < total;
    state.status = if state.filter.is_active() {
        i18n::format_count_filtering(lang, visible, total, indexing)
    } else if indexing {
        i18n::format_count_indexing(lang, total, state.indexed_count)
    } else {
        i18n::format_count(lang, total)
    };
}

fn filtered_count(state: &App) -> usize {
    filtered_ids(state).len()
}

// ── View ───────────────────────────────────────────────────────────────────

fn view(state: &App) -> Element<'_, Message> {
    if state.viewer_mode {
        return viewer_view(state);
    }
    if state.show_about {
        return about_view(state);
    }
    if state.show_settings {
        return settings_view(state);
    }

    let s = i18n::t(state.settings.language);

    let toolbar = row![
        text_input(s.toolbar_dir_placeholder, &state.dir_input)
            .on_input(Message::DirInputChanged)
            .on_submit(Message::OpenDirectory)
            .width(Length::Fill)
            .padding(spacing::SM),
        button(s.toolbar_open).on_press(Message::OpenDirectory).padding([spacing::SM, spacing::LG]),
        button(if state.show_filters { s.toolbar_filter_on } else { s.toolbar_filter_off })
            .on_press(Message::ToggleFilterPanel)
            .padding([spacing::SM, spacing::MD]),
        button(if state.show_grid { s.toolbar_grid_on } else { s.toolbar_grid_off })
            .on_press(Message::ToggleGridPanel)
            .padding([spacing::SM, spacing::MD]),
        button(if state.show_sidebar { s.toolbar_sidebar_on } else { s.toolbar_sidebar_off })
            .on_press(Message::ToggleSidebar)
            .padding([spacing::SM, spacing::MD]),
        button("⚙").on_press(Message::OpenSettings).padding([spacing::SM, spacing::MD]),
    ]
    .spacing(spacing::SM)
    .padding(spacing::MD)
    .align_y(Alignment::Center);

    let nav_hint = if state.selected.is_some() { s.nav_hint } else { "" };
    let status_bar = container(
        text(format!("{}{}", &state.status, nav_hint)).size(font_size::BODY)
    )
    .padding([spacing::XS, spacing::MD])
    .width(Length::Fill);

    let content_area: Element<'_, Message> = if state.images.is_empty() {
        let msg = if state.loading { s.loading } else { s.empty_prompt };
        container(text(msg).size(16))
            .width(Length::Fill)
            .height(Length::Fill)
            .center(Length::Fill)
            .into()
    } else {
        let mut panes: Vec<Element<'_, Message>> = Vec::new();
        if state.show_filters {
            panes.push(filter_panel(state));
        }
        if state.show_grid {
            panes.push(thumbnail_grid(state));
        }
        if state.show_sidebar {
            panes.push(sidebar(state));
        }
        if panes.is_empty() {
            panes.push(
                container(
                    text(s.all_panels_hidden)
                        .size(font_size::H3)
                        .style(|theme: &iced::Theme| crate::theme::faint_text_style(theme)),
                )
                .width(Length::Fill)
                .height(Length::Fill)
                .center(Length::Fill)
                .into(),
            );
        }
        row(panes).height(Length::Fill).into()
    };

    column![toolbar, status_bar, content_area]
        .height(Length::Fill)
        .into()
}

// ── Fullscreen viewer ──────────────────────────────────────────────────────

fn viewer_view(state: &App) -> Element<'_, Message> {
    let s = i18n::t(state.settings.language);

    let filename = state
        .selected
        .and_then(|id| state.images.get(id))
        .map(|e| e.filename.as_str())
        .unwrap_or("");

    let exif_summary: String = state
        .selected
        .and_then(|id| state.exif_data.get(&id))
        .map(|exif| {
            let mut parts: Vec<String> = Vec::new();
            if let Some(cam) = camera_name(exif) {
                parts.push(cam);
            }
            if let Some(f) = &exif.focal_length {
                parts.push(f.clone());
            }
            if let Some(f) = &exif.fnumber {
                parts.push(f.clone());
            }
            if let Some(e) = &exif.exposure_time {
                parts.push(e.clone());
            }
            if let Some(iso) = exif.iso {
                parts.push(format!("ISO {iso}"));
            }
            parts.join("  ")
        })
        .unwrap_or_default();

    let top_bar = container(
        row![
            button(text(s.viewer_close).size(font_size::BODY))
                .on_press(Message::ExitViewer)
                .padding([spacing::XS + 2.0, spacing::MD]),
            button(text("←").size(font_size::LABEL))
                .on_press(Message::NavigatePrev)
                .padding([spacing::XS + 2.0, spacing::MD]),
            button(text("→").size(font_size::LABEL))
                .on_press(Message::NavigateNext)
                .padding([spacing::XS + 2.0, spacing::MD]),
            column![
                text(filename).size(font_size::LABEL),
                text(exif_summary).size(font_size::CAPTION).style(|theme: &iced::Theme| {
                    crate::theme::muted_text_style(theme)
                }),
            ]
            .spacing(spacing::XS / 2.0)
            .width(Length::Fill),
        ]
        .spacing(spacing::SM)
        .padding([spacing::XS + 2.0, spacing::MD])
        .align_y(Alignment::Center),
    )
    .width(Length::Fill)
    .style(|theme: &iced::Theme| {
        let pal = theme.extended_palette();
        container::Style {
            background: Some(pal.background.strong.color.into()),
            border: iced::Border {
                color: pal.background.weak.color,
                width: 1.0,
                radius: iced::border::Radius::from(radius::NONE),
            },
            ..Default::default()
        }
    });

    let image_area: Element<'_, Message> = match &state.full_res_handle {
        Some(handle) => Image::new(handle.clone())
            .width(Length::Fill)
            .height(Length::Fill)
            .content_fit(ContentFit::Contain)
            .into(),
        None => container(
            text(s.viewer_loading).size(16),
        )
        .width(Length::Fill)
        .height(Length::Fill)
        .center(Length::Fill)
        .style(|_| container::Style {
            background: Some(iced::Background::Color(iced::Color::BLACK)),
            ..Default::default()
        })
        .into(),
    };

    let main_area = container(image_area)
        .width(Length::Fill)
        .height(Length::Fill)
        .style(|_| container::Style {
            background: Some(iced::Background::Color(iced::Color::BLACK)),
            ..Default::default()
        });

    column![top_bar, main_area]
        .height(Length::Fill)
        .into()
}

// ── Filter panel ───────────────────────────────────────────────────────────

fn filter_panel(state: &App) -> Element<'_, Message> {
    let tr = i18n::t(state.settings.language);
    let section = |s: &'static str| {
        text(s).size(font_size::CAPTION).style(|theme: &iced::Theme| iced::widget::text::Style {
            color: Some(theme.extended_palette().primary.base.color),
        })
    };
    let muted_style = |theme: &iced::Theme| crate::theme::faint_text_style(theme);

    // Camera checkboxes
    let mut cam_col: Vec<Element<'_, Message>> = vec![section(tr.filter_camera).into()];
    if state.available_cameras.is_empty() {
        cam_col.push(text(tr.filter_indexing).size(11).style(muted_style).into());
    } else {
        for cam in &state.available_cameras {
            let visible = !state.filter.excluded_cameras.contains(cam.as_str());
            let c1 = cam.clone();
            let c2 = cam.clone();
            cam_col.push(
                checkbox(visible)
                    .label(c1)
                    .on_toggle(move |v| Message::CameraVisibilityChanged(c2.clone(), v))
                    .size(14)
                    .text_size(11)
                    .into(),
            );
        }
    }

    let iso_row = row![
        text_input(tr.filter_min, &state.filter.iso_min)
            .on_input(Message::IsoMinChanged)
            .width(72).padding(spacing::XS),
        text("～").size(font_size::CAPTION + 1.0).style(muted_style),
        text_input(tr.filter_max, &state.filter.iso_max)
            .on_input(Message::IsoMaxChanged)
            .width(72).padding(spacing::XS),
    ]
    .spacing(spacing::XS)
    .align_y(Alignment::Center);

    let focal_row = row![
        text_input(tr.filter_min, &state.filter.focal_min)
            .on_input(Message::FocalMinChanged)
            .width(72).padding(spacing::XS),
        text("～").size(font_size::CAPTION + 1.0).style(muted_style),
        text_input(tr.filter_max, &state.filter.focal_max)
            .on_input(Message::FocalMaxChanged)
            .width(72).padding(spacing::XS),
    ]
    .spacing(spacing::XS)
    .align_y(Alignment::Center);

    let date_col = column![
        section(tr.filter_date),
        row![
            text(tr.filter_from).size(font_size::CAPTION).style(muted_style),
            text_input("YYYY-MM-DD", &state.filter.date_from)
                .on_input(Message::DateFromChanged)
                .width(Length::Fill).padding(spacing::XS),
        ]
        .spacing(spacing::XS)
        .align_y(Alignment::Center),
        row![
            text(tr.filter_to).size(font_size::CAPTION).style(muted_style),
            text_input("YYYY-MM-DD", &state.filter.date_to)
                .on_input(Message::DateToChanged)
                .width(Length::Fill).padding(spacing::XS),
        ]
        .spacing(spacing::XS)
        .align_y(Alignment::Center),
    ]
    .spacing(spacing::XS);

    // Rating filter (checkboxes: unrated / ★ / ★★ / ★★★ / ★★★★ / ★★★★★)
    let rating_entries: &[(u8, &str)] = &[
        (0, "—"),
        (1, "★"),
        (2, "★★"),
        (3, "★★★"),
        (4, "★★★★"),
        (5, "★★★★★"),
    ];
    let rating_checks: Vec<Element<'_, Message>> = rating_entries
        .iter()
        .map(|&(n, label)| {
            checkbox(state.filter.filter_ratings.contains(&n))
                .label(label)
                .on_toggle(move |_| Message::RatingFilterToggled(n))
                .size(13)
                .text_size(11)
                .into()
        })
        .collect();
    let rating_col = column(
        std::iter::once(section(tr.filter_rating).into())
            .chain(rating_checks)
            .collect::<Vec<_>>(),
    )
    .spacing(3);

    // Label filter (checkboxes: 5 colors)
    let label_entries: &[(Label, &str)] = &[
        (Label::Red,    "🔴 Red"),
        (Label::Yellow, "🟡 Yellow"),
        (Label::Green,  "🟢 Green"),
        (Label::Blue,   "🔵 Blue"),
        (Label::Purple, "🟣 Purple"),
    ];
    let label_checks: Vec<Element<'_, Message>> = label_entries
        .iter()
        .map(|&(lbl, name)| {
            checkbox(state.filter.filter_labels.contains(&lbl))
                .label(name)
                .on_toggle(move |_| Message::LabelFilterToggled(lbl))
                .size(13)
                .text_size(11)
                .into()
        })
        .collect();
    let label_col = column(
        std::iter::once(section(tr.filter_label).into())
            .chain(label_checks)
            .collect::<Vec<_>>(),
    )
    .spacing(3);

    // Flag filter (checkboxes: Pick / Reject)
    let flag_checks: Vec<Element<'_, Message>> = vec![
        checkbox(state.filter.filter_flags.contains(&Flag::Pick))
            .label("Pick")
            .on_toggle(|_| Message::FlagFilterToggled(Flag::Pick))
            .size(13)
            .text_size(11)
            .into(),
        checkbox(state.filter.filter_flags.contains(&Flag::Reject))
            .label("Reject")
            .on_toggle(|_| Message::FlagFilterToggled(Flag::Reject))
            .size(13)
            .text_size(11)
            .into(),
    ];
    let flag_col = column(
        std::iter::once(section(tr.filter_flag).into())
            .chain(flag_checks)
            .collect::<Vec<_>>(),
    )
    .spacing(3);

    let reset_label = if state.filter.is_active() {
        i18n::format_reset_with_count(state.settings.language, filtered_count(state))
    } else {
        tr.filter_reset.to_string()
    };
    let reset_btn = button(text(reset_label).size(font_size::CAPTION + 1.0))
        .on_press_maybe(state.filter.is_active().then_some(Message::FilterReset))
        .width(Length::Fill)
        .padding([spacing::XS + 1.0, 0.0]);

    let mut items: Vec<Element<'_, Message>> = Vec::new();
    items.extend(cam_col);
    items.push(thin_divider());
    items.push(column![section(tr.filter_iso), iso_row].spacing(spacing::XS).into());
    items.push(thin_divider());
    items.push(column![section(tr.filter_focal), focal_row].spacing(spacing::XS).into());
    items.push(thin_divider());
    items.push(date_col.into());
    items.push(thin_divider());
    items.push(rating_col.into());
    items.push(thin_divider());
    items.push(label_col.into());
    items.push(thin_divider());
    items.push(flag_col.into());
    items.push(thin_divider());
    items.push(reset_btn.into());

    container(scrollable(
        column(items).spacing(spacing::SM).padding(spacing::MD).width(Length::Fill),
    ))
    .width(FILTER_PANEL_WIDTH)
    .height(Length::Fill)
    .style(|theme: &iced::Theme| {
        let pal = theme.extended_palette();
        container::Style {
            background: Some(pal.background.weak.color.into()),
            border: iced::Border {
                color: pal.background.strong.color,
                width: 1.0,
                radius: iced::border::Radius::from(radius::NONE),
            },
            ..Default::default()
        }
    })
    .into()
}

// ── Thumbnail grid ─────────────────────────────────────────────────────────

fn thumbnail_grid(state: &App) -> Element<'_, Message> {
    let visible: Vec<&ImageEntry> = state
        .images
        .iter()
        .filter(|e| {
            is_representative(e, state)
                && state.filter.passes(state.exif_data.get(&e.id), state.xmp_data.get(&e.id))
        })
        .collect();

    if visible.is_empty() {
        return container(
            text(i18n::t(state.settings.language).no_match)
                .size(font_size::H3)
                .style(|theme: &iced::Theme| crate::theme::faint_text_style(theme)),
        )
        .width(Length::Fill)
        .height(Length::Fill)
        .center(Length::Fill)
        .into();
    }

    let rows: Vec<Element<'_, Message>> = visible
        .chunks(GRID_COLUMNS)
        .map(|chunk| {
            let cells: Vec<Element<'_, Message>> =
                chunk.iter().map(|e| thumb_cell(state, e)).collect();
            row(cells).spacing(spacing::XS).into()
        })
        .collect();

    scrollable(column(rows).spacing(spacing::XS).padding(spacing::MD))
        .width(Length::Fill)
        .height(Length::Fill)
        .into()
}

fn thumb_cell<'a>(state: &'a App, entry: &'a ImageEntry) -> Element<'a, Message> {
    let is_selected = state.selected == Some(entry.id);

    let thumb: Element<'a, Message> = match state.thumbnails.get(&entry.id) {
        Some(ThumbnailState::Loaded(handle)) => Image::new(handle.clone())
            .width(THUMB_DISPLAY)
            .height(THUMB_DISPLAY)
            .content_fit(ContentFit::Cover)
            .into(),
        Some(ThumbnailState::Failed) => container(
            text(if entry.is_raw { "RAW" } else { "!" }).size(13),
        )
        .width(THUMB_DISPLAY)
        .height(THUMB_DISPLAY)
        .center(Length::Fill)
        .style(|theme: &iced::Theme| container::Style {
            background: Some(theme.extended_palette().background.strong.color.into()),
            ..Default::default()
        })
        .into(),
        _ => container(text("…").size(13))
            .width(THUMB_DISPLAY)
            .height(THUMB_DISPLAY)
            .center(Length::Fill)
            .style(|theme: &iced::Theme| container::Style {
                background: Some(theme.extended_palette().background.weak.color.into()),
                ..Default::default()
            })
            .into(),
    };

    let label = text(truncate(&entry.filename, 20))
        .size(font_size::CAPTION)
        .width(THUMB_DISPLAY)
        .align_x(iced::alignment::Horizontal::Center);

    let cell = column![thumb, label]
        .spacing(spacing::XS)
        .align_x(Alignment::Center)
        .width(THUMB_DISPLAY + spacing::SM);

    let btn = button(container(cell).padding(spacing::XS / 2.0))
        .on_press(Message::ImageSelected(entry.id))
        .padding(spacing::XS / 2.0);

    if is_selected {
        container(btn)
            .style(|theme: &iced::Theme| container::Style {
                border: iced::Border {
                    color: theme.extended_palette().primary.strong.color,
                    width: 1.5,
                    radius: iced::border::Radius::from(radius::MD),
                },
                ..Default::default()
            })
            .into()
    } else {
        container(btn).into()
    }
}

// ── Variant badge helper ───────────────────────────────────────────────────

fn variant_badge_for(
    entry: &crate::scanner::ImageEntry,
    exif: Option<&crate::metadata::ExifData>,
    xmp:  Option<&XmpData>,
) -> (&'static str, fn(&iced::Theme) -> iced::Color) {
    if entry.is_raw {
        ("R", |t: &iced::Theme| t.extended_palette().danger.base.color)
    } else if is_developed(exif.and_then(|e| e.software.as_deref()), xmp) {
        ("D", |t: &iced::Theme| t.extended_palette().success.base.color)
    } else {
        ("J", |t: &iced::Theme| t.extended_palette().primary.base.color)
    }
}

// ── Sidebar ────────────────────────────────────────────────────────────────

fn sidebar(state: &App) -> Element<'_, Message> {
    let s = i18n::t(state.settings.language);
    let muted_style = |theme: &iced::Theme| crate::theme::faint_text_style(theme);
    let mut items: Vec<Element<'_, Message>> = Vec::new();

    if let Some(id) = state.selected {
        if let Some(entry) = state.images.get(id) {
            // ── Preview image ────────────────────────────────────────────
            let preview: Element<'_, Message> = if let Some(handle) = &state.preview_handle {
                Image::new(handle.clone())
                    .width(Length::Fill)
                    .height(220.0)
                    .content_fit(ContentFit::Contain)
                    .into()
            } else {
                container(
                    text(if entry.is_raw { s.sidebar_raw_no_preview } else { s.loading })
                        .size(font_size::CAPTION + 1.0)
                        .style(|theme: &iced::Theme| crate::theme::faint_text_style(theme))
                        .align_x(iced::alignment::Horizontal::Center),
                )
                .width(Length::Fill)
                .height(220.0)
                .center(Length::Fill)
                .style(|theme: &iced::Theme| container::Style {
                    background: Some(theme.extended_palette().background.strong.color.into()),
                    ..Default::default()
                })
                .into()
            };
            items.push(preview);
            items.push(
                button(text(s.sidebar_fullscreen).size(font_size::CAPTION))
                    .on_press(Message::EnterViewer)
                    .width(Length::Fill)
                    .padding([spacing::XS, spacing::SM])
                    .into(),
            );

            // ── Variant thumbnail strip (only for multi-entry shot groups) ──
            if let Some(group) = state.shot_groups.get(&entry.shot_id) {
                if group.len() > 1 {
                    let thumbs: Vec<Element<'_, Message>> = group
                        .iter()
                        .map(|&vid| {
                            let is_current = vid == id;
                            let v_entry = state.images.get(vid);
                            let v_exif = state.exif_data.get(&vid);
                            let v_xmp = state.xmp_data.get(&vid);

                            let image_el: Element<'_, Message> =
                                match state.thumbnails.get(&vid) {
                                    Some(ThumbnailState::Loaded(h)) => Image::new(h.clone())
                                        .width(50.0)
                                        .height(40.0)
                                        .content_fit(ContentFit::Cover)
                                        .into(),
                                    _ => container(Space::new())
                                        .width(50.0)
                                        .height(40.0)
                                        .style(|theme: &iced::Theme| container::Style {
                                            background: Some(
                                                theme.extended_palette().background.strong.color.into(),
                                            ),
                                            ..Default::default()
                                        })
                                        .into(),
                                };

                            let badge_overlay: Element<'_, Message> = if let Some(e) = v_entry {
                                let (letter, color_fn) = variant_badge_for(e, v_exif, v_xmp);
                                container(
                                    container(
                                        text(letter).size(font_size::CAPTION).style(|_: &iced::Theme| {
                                            iced::widget::text::Style {
                                                color: Some(iced::Color::WHITE),
                                            }
                                        }),
                                    )
                                    .padding([spacing::XS / 2.0, spacing::XS])
                                    .style(move |theme: &iced::Theme| container::Style {
                                        background: Some(color_fn(theme).into()),
                                        border: iced::Border {
                                            radius: iced::border::Radius::from(radius::SM),
                                            ..Default::default()
                                        },
                                        ..Default::default()
                                    }),
                                )
                                .width(Length::Fill)
                                .height(Length::Fill)
                                .align_x(iced::alignment::Horizontal::Right)
                                .align_y(iced::alignment::Vertical::Top)
                                .padding(spacing::XS / 2.0)
                                .into()
                            } else {
                                Space::new().into()
                            };

                            let stacked = iced::widget::stack![image_el, badge_overlay];

                            button(stacked)
                                .on_press(Message::ImageSelected(vid))
                                .padding(if is_current { spacing::XS / 2.0 } else { 1.0 })
                                .style(if is_current {
                                    button::primary
                                } else {
                                    button::secondary
                                })
                                .into()
                        })
                        .collect();
                    items.push(
                        Row::with_children(thumbs)
                            .spacing(spacing::XS)
                            .padding([spacing::XS, spacing::XS])
                            .into(),
                    );
                }
            }
            items.push(thin_divider());

            // ── File info ────────────────────────────────────────────────
            items.push(text(&entry.filename).size(font_size::BODY).into());

            // Variant position badge: "1/2 · RAW"
            if let Some(group) = state.shot_groups.get(&entry.shot_id) {
                if group.len() > 1 {
                    let pos = group.iter().position(|&vid| vid == id).unwrap_or(0) + 1;
                    let n = group.len();
                    let vtype = if entry.is_raw {
                        "RAW"
                    } else {
                        let sw = state.exif_data.get(&id).and_then(|e| e.software.as_deref());
                        let xm = state.xmp_data.get(&id);
                        if is_developed(sw, xm) { "DEV" } else { "JPG" }
                    };
                    items.push(
                        text(format!("{pos}/{n} · {vtype}"))
                            .size(font_size::CAPTION)
                            .style(muted_style)
                            .into(),
                    );
                }
            }

            items.push(
                text(i18n::format_file_size_kb(state.settings.language, entry.file_size))
                    .size(font_size::CAPTION)
                    .style(muted_style)
                    .into(),
            );
            items.push(thin_divider());

            // ── EXIF ─────────────────────────────────────────────────────
            // Always render 7 rows so the layout stays stable across selections.
            // Missing values render as a skeleton dash; loading state uses the
            // same dash so the row count never changes.
            let exif = state.exif_data.get(&id);
            let loaded = exif.is_some();
            let camera = exif.and_then(|e| camera_name(e));
            let datetime = exif.and_then(|e| e.datetime.clone()).map(|d| d.replacen(':', "/", 2));
            let exposure = exif.and_then(|e| e.exposure_time.clone());
            let fnumber = exif.and_then(|e| e.fnumber.clone());
            let iso = exif.and_then(|e| e.iso).map(|v| v.to_string());
            let focal = exif.and_then(|e| e.focal_length.clone());
            let resolution = exif.and_then(|e| match (e.width, e.height) {
                (Some(w), Some(h)) => Some(format!("{w} × {h}")),
                _ => None,
            });
            push_row_skeleton(&mut items, s.sidebar_camera, camera, loaded);
            push_row_skeleton(&mut items, s.sidebar_datetime, datetime, loaded);
            push_row_skeleton(&mut items, s.sidebar_exposure, exposure, loaded);
            push_row_skeleton(&mut items, s.sidebar_fnumber, fnumber, loaded);
            push_row_skeleton(&mut items, s.sidebar_iso, iso, loaded);
            push_row_skeleton(&mut items, s.sidebar_focal, focal, loaded);
            push_row_skeleton(&mut items, s.sidebar_resolution, resolution, loaded);

            // ── XMP / Rating ─────────────────────────────────────────────
            if let Some(xmp) = state.xmp_data.get(&id) {
                items.push(thin_divider());
                let stars = xmp.rating.unwrap_or(0);
                let stars_str: String =
                    (0..5).map(|i| if i < stars { '\u{2605}' } else { '\u{2606}' }).collect();
                push_row(&mut items, s.sidebar_rating, Some(stars_str));
                if let Some(label) = xmp.label {
                    push_row(&mut items, s.sidebar_label, Some(label.as_str().to_string()));
                }
                if let Some(flag) = xmp.flag {
                    push_row(&mut items, s.sidebar_flag, Some(flag.as_str().to_string()));
                }
            }
        }
    } else {
        items.push(
            container(
                text(s.select_hint)
                    .size(font_size::BODY)
                    .style(|theme: &iced::Theme| crate::theme::faint_text_style(theme))
                    .align_x(iced::alignment::Horizontal::Center),
            )
            .center(Length::Fill)
            .height(Length::Fill)
            .into(),
        );
    }

    container(scrollable(
        column(items).spacing(spacing::SM).padding(spacing::MD).width(Length::Fill),
    ))
    .width(SIDEBAR_WIDTH)
    .height(Length::Fill)
    .style(|theme: &iced::Theme| {
        let pal = theme.extended_palette();
        container::Style {
            background: Some(pal.background.weak.color.into()),
            border: iced::Border {
                color: pal.background.strong.color,
                width: 1.0,
                radius: iced::border::Radius::from(radius::NONE),
            },
            ..Default::default()
        }
    })
    .into()
}

// ── Shared helpers ─────────────────────────────────────────────────────────

fn truncate(s: &str, max: usize) -> &str {
    if s.len() <= max { s } else { &s[..max] }
}

fn camera_name(exif: &ExifData) -> Option<String> {
    match (&exif.make, &exif.model) {
        (Some(make), Some(model)) => Some(format!("{make} {model}")),
        (Some(make), None) => Some(make.clone()),
        (None, Some(model)) => Some(model.clone()),
        _ => None,
    }
}

fn thin_divider<'a>() -> Element<'a, Message> {
    container(text(""))
        .height(1.0)
        .width(Length::Fill)
        .style(|theme: &iced::Theme| container::Style {
            background: Some(theme.extended_palette().background.strong.color.into()),
            ..Default::default()
        })
        .into()
}

fn push_row<'a>(items: &mut Vec<Element<'a, Message>>, label: &'a str, value: Option<String>) {
    if let Some(v) = value {
        items.push(
            column![
                text(label).size(font_size::CAPTION)
                    .style(|theme: &iced::Theme| crate::theme::muted_text_style(theme)),
                text(v).size(font_size::BODY),
            ]
            .spacing(spacing::XS / 4.0)
            .into(),
        );
    }
}

/// Like `push_row` but always occupies the same vertical space.
/// When `loaded` is false the value is replaced by a muted dash (skeleton state).
/// When `loaded` is true and value is None, a dash is shown (field genuinely absent).
fn push_row_skeleton<'a>(
    items: &mut Vec<Element<'a, Message>>,
    label: &'a str,
    value: Option<String>,
    loaded: bool,
) {
    let display = value.unwrap_or_else(|| "—".to_string());
    let faint = !loaded || display == "—";
    items.push(
        column![
            text(label).size(font_size::CAPTION)
                .style(|theme: &iced::Theme| crate::theme::muted_text_style(theme)),
            text(display).size(font_size::BODY).style(move |theme: &iced::Theme| {
                if faint { crate::theme::disabled_text_style(theme) }
                else { iced::widget::text::Style::default() }
            }),
        ]
        .spacing(spacing::XS / 4.0)
        .into(),
    );
}

// ── Settings view ──────────────────────────────────────────────────────────

fn settings_view(state: &App) -> Element<'_, Message> {
    let s = i18n::t(state.settings.language);

    let theme_options: Vec<Element<'_, Message>> = ThemeChoice::ALL
        .iter()
        .map(|&t| {
            radio(t.label(), t, Some(state.settings_draft.theme), Message::SettingsThemeChanged)
                .size(16)
                .text_size(13)
                .into()
        })
        .collect();

    let lang_options: Vec<Element<'_, Message>> = Language::ALL
        .iter()
        .map(|&lang| {
            radio(lang.label(), lang, Some(state.settings_draft.language), Message::SettingsLanguageChanged)
                .size(16)
                .text_size(13)
                .into()
        })
        .collect();

    let hint_style = |theme: &iced::Theme| crate::theme::faint_text_style(theme);

    let form = column![
        text(s.settings_title).size(font_size::H2),
        thin_divider(),
        column![
            text(s.settings_default_path).size(font_size::LABEL),
            text_input(
                s.settings_default_path_hint,
                &state.settings_draft.default_path,
            )
            .on_input(Message::SettingsDefaultPathChanged)
            .padding(spacing::SM),
            text(s.settings_default_path_help).size(font_size::CAPTION).style(hint_style),
        ]
        .spacing(spacing::SM),
        thin_divider(),
        column![
            text(s.settings_language).size(font_size::LABEL),
            column(lang_options).spacing(spacing::SM),
        ]
        .spacing(spacing::MD),
        thin_divider(),
        column![
            text(s.settings_theme).size(font_size::LABEL),
            column(theme_options).spacing(spacing::SM),
        ]
        .spacing(spacing::MD),
        thin_divider(),
        row![
            button(s.settings_cancel)
                .on_press(Message::CloseSettings)
                .padding([spacing::SM, spacing::LG]),
            button(s.settings_save)
                .on_press(Message::SettingsSave)
                .padding([spacing::SM, spacing::LG]),
        ]
        .spacing(spacing::SM),
    ]
    .spacing(spacing::XL)
    .max_width(500)
    .padding([spacing::XL * 2.0, 0.0]);

    container(form)
        .width(Length::Fill)
        .height(Length::Fill)
        .center_x(Length::Fill)
        .into()
}

// ── About view ─────────────────────────────────────────────────────────────

fn about_view(state: &App) -> Element<'_, Message> {
    let s = i18n::t(state.settings.language);

    let muted = |theme: &iced::Theme| crate::theme::muted_text_style(theme);

    let content = column![
        // Icon placeholder (large monogram)
        container(
            text("B")
                .size(font_size::DISPLAY)
                .style(|theme: &iced::Theme| iced::widget::text::Style {
                    color: Some(theme.extended_palette().primary.strong.color),
                })
        )
        .width(90)
        .height(90)
        .center(Length::Fill)
        .style(|theme: &iced::Theme| {
            let pal = theme.extended_palette();
            container::Style {
                background: Some(pal.background.strong.color.into()),
                border: iced::Border {
                    radius: iced::border::Radius::from(radius::LG),
                    color: pal.background.weak.color,
                    width: 1.0,
                },
                ..Default::default()
            }
        }),
        text(s.about_title).size(font_size::H1),
        text(s.about_version).size(font_size::LABEL).style(muted),
        thin_divider(),
        text(s.about_desc).size(font_size::LABEL).align_x(iced::alignment::Horizontal::Center),
        thin_divider(),
        text("© 2024 bridge-lite contributors").size(font_size::CAPTION + 1.0).style(muted),
        button(s.about_close)
            .on_press(Message::CloseAbout)
            .padding([spacing::SM, spacing::XL]),
    ]
    .spacing(spacing::MD)
    .align_x(Alignment::Center)
    .max_width(360)
    .padding([spacing::XL * 2.0, 0.0]);

    container(content)
        .width(Length::Fill)
        .height(Length::Fill)
        .center_x(Length::Fill)
        .center_y(Length::Fill)
        .into()
}
