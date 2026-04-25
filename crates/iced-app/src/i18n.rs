use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Language {
    Japanese,
    English,
}

impl Default for Language {
    fn default() -> Self {
        Language::Japanese
    }
}

impl Language {
    pub const ALL: &'static [Language] = &[Language::Japanese, Language::English];

    pub fn label(self) -> &'static str {
        match self {
            Language::Japanese => "日本語",
            Language::English => "English",
        }
    }
}

// ── String table ────────────────────────────────────────────────────────────

pub struct Strings {
    // Menu (custom MenuItem labels only; PredefinedMenuItems auto-localize on macOS)
    pub menu_file:            &'static str,
    pub menu_view:            &'static str,
    pub menu_help:            &'static str,
    pub menu_open_folder:     &'static str,
    pub menu_preferences:     &'static str,
    pub menu_toggle_filter:   &'static str,
    pub menu_toggle_grid:     &'static str,
    pub menu_toggle_sidebar:  &'static str,
    pub menu_about:           &'static str,

    // Toolbar
    pub toolbar_dir_placeholder: &'static str,
    pub toolbar_open:            &'static str,
    pub toolbar_filter_on:       &'static str,
    pub toolbar_filter_off:      &'static str,
    pub toolbar_grid_on:         &'static str,
    pub toolbar_grid_off:        &'static str,
    pub toolbar_sidebar_on:      &'static str,
    pub toolbar_sidebar_off:     &'static str,

    // Empty / placeholder states
    pub empty_prompt:       &'static str,
    pub all_panels_hidden:  &'static str,
    pub no_match:           &'static str,
    pub loading:            &'static str,
    pub nav_hint:           &'static str,
    pub select_hint:        &'static str,

    // Status
    pub scanning:           &'static str,
    // Format templates — use format_* helpers below for dynamic values
    pub images_indexing_suffix: &'static str, // appended to "{N} images/枚の画像 "

    // Filter panel
    pub filter_camera:      &'static str,
    pub filter_iso:         &'static str,
    pub filter_focal:       &'static str,
    pub filter_date:        &'static str,
    pub filter_from:        &'static str,
    pub filter_to:          &'static str,
    pub filter_min:         &'static str,
    pub filter_max:         &'static str,
    pub filter_indexing:    &'static str,
    pub filter_reset:       &'static str,

    // Rating / label / flag filters
    pub filter_rating:      &'static str,
    pub filter_label:       &'static str,
    pub filter_flag:        &'static str,

    // Sidebar
    pub sidebar_fullscreen:     &'static str,
    pub sidebar_raw_no_preview: &'static str,
    pub sidebar_camera:         &'static str,
    pub sidebar_datetime:       &'static str,
    pub sidebar_exposure:       &'static str,
    pub sidebar_fnumber:        &'static str,
    pub sidebar_iso:            &'static str,
    pub sidebar_focal:          &'static str,
    pub sidebar_resolution:     &'static str,
    pub sidebar_rating:         &'static str,
    pub sidebar_label:          &'static str,
    pub sidebar_flag:           &'static str,

    // Viewer
    pub viewer_close:   &'static str,
    pub viewer_loading: &'static str,

    // Settings
    pub settings_title:             &'static str,
    pub settings_default_path:      &'static str,
    pub settings_default_path_hint: &'static str,
    pub settings_default_path_help: &'static str,
    pub settings_theme:             &'static str,
    pub settings_language:          &'static str,
    pub settings_cancel:            &'static str,
    pub settings_save:              &'static str,

    // About
    pub about_title:    &'static str,
    pub about_version:  &'static str,
    pub about_desc:     &'static str,
    pub about_close:    &'static str,
}

// ── Japanese ────────────────────────────────────────────────────────────────

pub const JA: Strings = Strings {
    menu_file:           "ファイル",
    menu_view:           "表示",
    menu_help:           "ヘルプ",
    menu_open_folder:    "フォルダを開く…",
    menu_preferences:    "設定…",
    menu_toggle_filter:  "フィルタ",
    menu_toggle_grid:    "閲覧",
    menu_toggle_sidebar: "メタデータ",
    menu_about:          "bridge-lite について",

    toolbar_dir_placeholder: "ディレクトリパス…",
    toolbar_open:            "開く",
    toolbar_filter_on:       "フィルタ ▲",
    toolbar_filter_off:      "フィルタ ▼",
    toolbar_grid_on:         "閲覧 ▲",
    toolbar_grid_off:        "閲覧 ▼",
    toolbar_sidebar_on:      "メタデータ ▲",
    toolbar_sidebar_off:     "メタデータ ▼",

    empty_prompt:      "上のバーにディレクトリパスを入力して「開く」を押してください",
    all_panels_hidden: "すべてのパネルが非表示です",
    no_match:          "フィルタに一致する画像がありません",
    loading:           "読み込み中…",
    nav_hint:          "  ←→ で移動  Space でフルスクリーン  Tab でバリエーション切替",
    select_hint:       "画像をクリックすると\nプレビューとメタデータを表示します\n\n← → キーで移動",

    scanning:                "スキャン中…",
    images_indexing_suffix:  "(インデックス中…)",

    filter_camera:   "カメラ",
    filter_iso:      "ISO",
    filter_focal:    "焦点距離 (mm)",
    filter_date:     "撮影日",
    filter_from:     "From",
    filter_to:       "To  ",
    filter_min:      "最小",
    filter_max:      "最大",
    filter_indexing: "インデックス中…",
    filter_reset:    "リセット",

    filter_rating:     "評価",
    filter_label:      "ラベル",
    filter_flag:       "フラグ",

    sidebar_fullscreen:     "フルスクリーン表示 (Space)",
    sidebar_raw_no_preview: "RAW\nプレビューなし",
    sidebar_camera:         "カメラ",
    sidebar_datetime:       "撮影日時",
    sidebar_exposure:       "露出",
    sidebar_fnumber:        "F値",
    sidebar_iso:            "ISO",
    sidebar_focal:          "焦点距離",
    sidebar_resolution:     "解像度",
    sidebar_rating:         "評価",
    sidebar_label:          "ラベル",
    sidebar_flag:           "フラグ",

    viewer_close:   "✕ 閉じる",
    viewer_loading: "読み込み中…",

    settings_title:             "設定",
    settings_default_path:      "デフォルトパス",
    settings_default_path_hint: "例: /Users/you/Pictures （起動時に自動でフォルダを開く）",
    settings_default_path_help: "空のままにすると起動時にフォルダを開きません",
    settings_theme:             "テーマ",
    settings_language:          "言語",
    settings_cancel:            "キャンセル",
    settings_save:              "保存",

    about_title:   "bridge-lite",
    about_version: "バージョン 0.1.0",
    about_desc:    "軽量・高速な画像ビュワー\nAdobe Bridge の代替として設計されています",
    about_close:   "閉じる",
};

// ── English ──────────────────────────────────────────────────────────────────

pub const EN: Strings = Strings {
    menu_file:           "File",
    menu_view:           "View",
    menu_help:           "Help",
    menu_open_folder:    "Open Folder…",
    menu_preferences:    "Preferences…",
    menu_toggle_filter:  "Filter Panel",
    menu_toggle_grid:    "Grid",
    menu_toggle_sidebar: "Metadata",
    menu_about:          "About bridge-lite",

    toolbar_dir_placeholder: "Directory path…",
    toolbar_open:            "Open",
    toolbar_filter_on:       "Filter ▲",
    toolbar_filter_off:      "Filter ▼",
    toolbar_grid_on:         "Grid ▲",
    toolbar_grid_off:        "Grid ▼",
    toolbar_sidebar_on:      "Metadata ▲",
    toolbar_sidebar_off:     "Metadata ▼",

    empty_prompt:      "Enter a directory path above and click \"Open\"",
    all_panels_hidden: "All panels are hidden",
    no_match:          "No images match the current filter",
    loading:           "Loading…",
    nav_hint:          "  ←→ to navigate  Space for fullscreen  Tab to cycle variants",
    select_hint:       "Click an image to view its\npreview and metadata\n\n← → to navigate",

    scanning:               "Scanning…",
    images_indexing_suffix: "(indexing…)",

    filter_camera:   "Camera",
    filter_iso:      "ISO",
    filter_focal:    "Focal (mm)",
    filter_date:     "Date",
    filter_from:     "From",
    filter_to:       "To  ",
    filter_min:      "Min",
    filter_max:      "Max",
    filter_indexing: "Indexing…",
    filter_reset:    "Reset",

    filter_rating:     "Rating",
    filter_label:      "Label",
    filter_flag:       "Flag",

    sidebar_fullscreen:     "Full Screen (Space)",
    sidebar_raw_no_preview: "RAW\nNo preview",
    sidebar_camera:         "Camera",
    sidebar_datetime:       "Date",
    sidebar_exposure:       "Exposure",
    sidebar_fnumber:        "Aperture",
    sidebar_iso:            "ISO",
    sidebar_focal:          "Focal",
    sidebar_resolution:     "Resolution",
    sidebar_rating:         "Rating",
    sidebar_label:          "Label",
    sidebar_flag:           "Flag",

    viewer_close:   "✕ Close",
    viewer_loading: "Loading…",

    settings_title:             "Settings",
    settings_default_path:      "Default Path",
    settings_default_path_hint: "e.g. /Users/you/Pictures (opens automatically on launch)",
    settings_default_path_help: "Leave empty to not open a folder on launch",
    settings_theme:             "Theme",
    settings_language:          "Language",
    settings_cancel:            "Cancel",
    settings_save:              "Save",

    about_title:   "bridge-lite",
    about_version: "Version 0.1.0",
    about_desc:    "A lightweight, fast image viewer\nDesigned as an alternative to Adobe Bridge",
    about_close:   "Close",
};

// ── Accessor ─────────────────────────────────────────────────────────────────

pub fn t(lang: Language) -> &'static Strings {
    match lang {
        Language::Japanese => &JA,
        Language::English  => &EN,
    }
}

// ── Dynamic format helpers ───────────────────────────────────────────────────

pub fn format_dir_not_found(lang: Language, path: &std::path::Path) -> String {
    match lang {
        Language::Japanese => format!("ディレクトリが見つかりません: {}", path.display()),
        Language::English  => format!("Directory not found: {}", path.display()),
    }
}

pub fn format_images_header(lang: Language, total: usize) -> String {
    match lang {
        Language::Japanese => format!("{total} 枚の画像 {}", JA.images_indexing_suffix),
        Language::English  => format!("{total} images {}", EN.images_indexing_suffix),
    }
}

pub fn format_count(lang: Language, total: usize) -> String {
    match lang {
        Language::Japanese => format!("{total} 枚"),
        Language::English  => format!("{total} images"),
    }
}

pub fn format_count_indexing(lang: Language, total: usize, cur: usize) -> String {
    match lang {
        Language::Japanese => format!("{total} 枚  (インデックス中… {cur}/{total})"),
        Language::English  => format!("{total} images  (indexing… {cur}/{total})"),
    }
}

pub fn format_count_filtering(lang: Language, vis: usize, total: usize, indexing: bool) -> String {
    match lang {
        Language::Japanese => {
            if indexing {
                format!("{vis} / {total} 枚 (フィルタ中・インデックス中…)")
            } else {
                format!("{vis} / {total} 枚 (フィルタ中)")
            }
        }
        Language::English => {
            if indexing {
                format!("{vis} / {total} images (filtered · indexing…)")
            } else {
                format!("{vis} / {total} images (filtered)")
            }
        }
    }
}

pub fn format_reset_with_count(lang: Language, n: usize) -> String {
    let base = t(lang).filter_reset;
    match lang {
        Language::Japanese => format!("{base} ({n}件)"),
        Language::English  => format!("{base} ({n})"),
    }
}

pub fn format_file_size_kb(_lang: Language, bytes: u64) -> String {
    format!("{} KB", bytes / 1024)
}
