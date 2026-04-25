use iced::{Color, Element, Theme};

// ── Spacing tokens ────────────────────────────────────────────────────────
pub mod spacing {
    pub const XS: f32 = 4.0;
    pub const SM: f32 = 8.0;
    pub const MD: f32 = 12.0;
    pub const LG: f32 = 16.0;
    pub const XL: f32 = 24.0;
}

// ── Font size tokens ──────────────────────────────────────────────────────
pub mod font_size {
    pub const CAPTION: f32 = 10.0;
    pub const BODY: f32 = 12.0;
    pub const LABEL: f32 = 13.0;
    pub const H3: f32 = 16.0;
    pub const H2: f32 = 20.0;
    pub const H1: f32 = 26.0;
    pub const DISPLAY: f32 = 56.0;
}

// ── Border radius tokens ──────────────────────────────────────────────────
pub mod radius {
    pub const NONE: f32 = 0.0;
    pub const SM: f32 = 4.0;
    pub const MD: f32 = 8.0;
    pub const LG: f32 = 12.0;
    pub const PILL: f32 = 999.0;
}

// ── Alpha tokens ──────────────────────────────────────────────────────────
pub mod alpha {
    pub const DISABLED: f32 = 0.30;
    pub const MUTED: f32 = 0.45;
    pub const SUBTLE: f32 = 0.55;
}

// ── Color helpers ─────────────────────────────────────────────────────────

pub fn muted_color(theme: &Theme, a: f32) -> Color {
    let mut c = theme.extended_palette().background.base.text;
    c.a *= a;
    c
}

pub fn muted_text_style(theme: &Theme) -> iced::widget::text::Style {
    iced::widget::text::Style {
        color: Some(muted_color(theme, alpha::SUBTLE)),
    }
}

pub fn faint_text_style(theme: &Theme) -> iced::widget::text::Style {
    iced::widget::text::Style {
        color: Some(muted_color(theme, alpha::MUTED)),
    }
}

pub fn disabled_text_style(theme: &Theme) -> iced::widget::text::Style {
    iced::widget::text::Style {
        color: Some(muted_color(theme, alpha::DISABLED)),
    }
}

// ── Custom palettes ───────────────────────────────────────────────────────

pub fn bridge_dark() -> Theme {
    Theme::custom(
        "Bridge Dark",
        iced::theme::Palette {
            background: Color::from_rgb8(0x0E, 0x11, 0x16),
            text: Color::from_rgb8(0xE8, 0xEC, 0xF1),
            primary: Color::from_rgb8(0x62, 0xE0, 0xFF),
            success: Color::from_rgb8(0x5B, 0xD6, 0x8A),
            warning: Color::from_rgb8(0xFF, 0xC4, 0x55),
            danger: Color::from_rgb8(0xFF, 0x6B, 0x8A),
        },
    )
}

// ── SVG icon helper ───────────────────────────────────────────────────────

/// Render a bundled SVG icon, tinted to match the current theme's text color.
pub fn icon<'a, M: 'a>(bytes: &'static [u8], size: u16) -> Element<'a, M>
where
    M: Clone,
{
    iced::widget::svg(iced::widget::svg::Handle::from_memory(bytes))
        .width(size as f32)
        .height(size as f32)
        .style(|theme: &Theme, _| iced::widget::svg::Style {
            color: Some(theme.extended_palette().background.base.text),
        })
        .into()
}

// ── Bundled icon bytes ────────────────────────────────────────────────────

pub const ICON_SETTINGS: &[u8]       = include_bytes!("../assets/icons/settings.svg");
pub const ICON_X: &[u8]              = include_bytes!("../assets/icons/x.svg");
pub const ICON_CHEVRON_LEFT: &[u8]   = include_bytes!("../assets/icons/chevron-left.svg");
pub const ICON_CHEVRON_RIGHT: &[u8]  = include_bytes!("../assets/icons/chevron-right.svg");
pub const ICON_CHEVRON_UP: &[u8]     = include_bytes!("../assets/icons/chevron-up.svg");
pub const ICON_CHEVRON_DOWN: &[u8]   = include_bytes!("../assets/icons/chevron-down.svg");
pub const ICON_FILTER: &[u8]         = include_bytes!("../assets/icons/filter.svg");
pub const ICON_FOLDER: &[u8]         = include_bytes!("../assets/icons/folder.svg");
pub const ICON_IMAGE: &[u8]          = include_bytes!("../assets/icons/image.svg");
pub const ICON_INFO: &[u8]           = include_bytes!("../assets/icons/info.svg");
pub const ICON_STAR: &[u8]           = include_bytes!("../assets/icons/star.svg");
pub const ICON_FLAG: &[u8]           = include_bytes!("../assets/icons/flag.svg");
pub const ICON_TAG: &[u8]            = include_bytes!("../assets/icons/tag.svg");
pub const ICON_FULLSCREEN: &[u8]     = include_bytes!("../assets/icons/fullscreen.svg");

pub fn bridge_light() -> Theme {
    Theme::custom(
        "Bridge Light",
        iced::theme::Palette {
            background: Color::from_rgb8(0xF4, 0xF5, 0xF7),
            text: Color::from_rgb8(0x1A, 0x1D, 0x23),
            primary: Color::from_rgb8(0x00, 0x8B, 0xB2),
            success: Color::from_rgb8(0x1A, 0x8A, 0x4A),
            warning: Color::from_rgb8(0xB8, 0x6A, 0x00),
            danger: Color::from_rgb8(0xC0, 0x32, 0x58),
        },
    )
}

